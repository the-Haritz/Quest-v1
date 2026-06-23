// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/Token/BondManager.sol";
import "src/Token/QuestToken.sol";
import "src/Pool/RewardPool.sol";
import "src/Interfaces/IVaultManager.sol";
import "src/Interfaces/IDexRouter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mock USDC ============
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============ Mock Protocol Token ============
contract MockProtocolToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ============ Mock DEX Router ============
contract MockDexRouter is IDexRouter {
    IERC20 public protocolToken;
    IERC20 public usdc;
    uint256 public rate; // 1e6 scale, e.g. 1.25e6 = 1.25 USDC per token

    constructor(address _protocolToken, address _usdc) {
        protocolToken = IERC20(_protocolToken);
        usdc = IERC20(_usdc);
        rate = 1.25e6; // Default to 1.25x (profit)
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        // Transfer protocol token from msg.sender to router
        protocolToken.transferFrom(msg.sender, address(this), amountIn);

        // Calculate amountOut (6 decimals)
        // amountIn has 18 decimals, rate has 6 decimals.
        // amountOut = amountIn * rate / 1e18
        uint256 amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= amountOutMin, "Slippage exceeded");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;

        // Transfer USDC to recipient
        usdc.transfer(to, amountOut);
    }
}

// ============ BondManager Test Suite ============
contract BondManagerTest is Test {
    BondManager public bondManager;
    QuestToken public vault;
    RewardPool public rewardPool;
    MockUSDC public usdc;
    MockProtocolToken public protocolToken;
    MockDexRouter public dexRouter;

    address public owner = address(0x1);
    address public protocol = address(0x2);
    address public alice = address(0x3);

    uint256 public constant MIN_DEPOSIT = 100e6;      // 100 USDC
    uint256 public constant MAX_TVL = 10_000_000e6;    // 10M USDC
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;   // 1000 USDC

    event BondCreated(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 indexed protocolId,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint8 tier,
        uint64 discount,
        uint256 vestingDays
    );

    event TokensClaimed(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 indexed protocolId,
        uint256 amountClaimed,
        uint256 cumulativeClaimed,
        uint8 tier,
        uint256 vestingDays
    );

    function setUp() public {
        usdc = new MockUSDC();
        protocolToken = new MockProtocolToken("Mock Protocol", "MPT");
        dexRouter = new MockDexRouter(address(protocolToken), address(usdc));

        // Deploy vault
        vault = new QuestToken();
        vault.initialize(
            owner,
            IVaultManager(address(vault)),
            address(usdc),
            MAX_TVL,
            MIN_DEPOSIT
        );

        // Deploy reward pool
        rewardPool = new RewardPool();
        rewardPool.initialize(
            owner,
            IVaultManager(address(vault)),
            address(usdc)
        );

        // Deploy bond manager
        bondManager = new BondManager();
        bondManager.initialize(
            owner,
            IVaultManager(address(vault)),
            address(dexRouter),
            address(usdc)
        );

        // Register managers in vault and set max Bond TVL percent
        vm.startPrank(owner);
        vault.setManager(address(bondManager), true);
        vault.setManager(address(rewardPool), true);
        bondManager.setMaxBondTvlPercent(100);
        vm.stopPrank();

        // Fund user and vault
        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // Fund dexRouter with USDC for swap liquidity
        usdc.mint(address(dexRouter), 1_000_000e6);
    }

    // ============ INITIALIZATION ============

    function test_initialization() public view {
        assertEq(bondManager.owner(), owner);
        assertEq(address(bondManager.vault()), address(vault));
        assertEq(address(bondManager.dexRouter()), address(dexRouter));
        assertEq(address(bondManager.usdc()), address(usdc));
    }

    function test_initializeRevertsOnZeroAddress() public {
        BondManager newManager = new BondManager();
        vm.expectRevert(BondManager.ZeroAddress.selector);
        newManager.initialize(address(0), IVaultManager(address(vault)), address(dexRouter), address(usdc));
    }

    // ============ PROTOCOL REGISTRY ============

    function test_registerProtocol() public {
        vm.prank(owner);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        uint256 pId = bondManager.protocolRegistry(protocol);
        assertTrue(pId > 0);
        assertTrue(bondManager.protocolActive(pId));
    }

    function test_registerProtocolRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);
    }

    function test_deregisterProtocol() public {
        vm.startPrank(owner);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);
        bondManager.deregisterProtocol(protocol);
        vm.stopPrank();

        uint256 pId = bondManager.protocolRegistry(protocol);
        assertFalse(bondManager.protocolActive(pId));
    }

    // ============ BOND CREATION ============

    function test_createBond() public {
        // Alice deposits 1000 USDC into 30-day tier
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Admin registers protocol
        vm.startPrank(owner);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        // Admin creates bond (30% discount matches min discount tier 0)
        // 30 days lock = 30% discount
        bondManager.createBond(
            protocol,
            address(protocolToken),
            500e6, // USDC amount to deploy
            1000e18, // Vesting token amount
            0, // tier (30d)
            3000, // 30% discount
            30, // 30 days vesting
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();

        // Verify status
        assertEq(vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), 500e6);
        assertEq(usdc.balanceOf(protocol), 500e6); // USDC lent to protocol
    }

    function test_createBondRevertsOnExceedingProtocolLimit() public {
        // Set max TVL percent to 25%
        vm.prank(owner);
        bondManager.setMaxBondTvlPercent(25);

        // Deposit 1000 USDC
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.startPrank(owner);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        // Available capacity is 1000.
        // Default max per-protocol limit is 25% of tier capacity = 250 USDC.
        // Attempting to deploy 300 USDC to a single protocol should revert.
        vm.expectRevert(BondManager.InvalidConditions.selector);
        bondManager.createBond(
            protocol,
            address(protocolToken),
            300e6,
            1000e18,
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();
    }

    // ============ STATELESS FUZZING: VESTING MATH ============

    function testFuzz_vestingMath(uint256 elapsedSec) public {
        // Bound elapsed time to a reasonable range (0 to 60 days)
        elapsedSec = bound(elapsedSec, 0, 60 days);

        // Setup vault & create a 30-day bond
        vm.prank(alice);
        vault.deposit(10000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Increase max per protocol limit to allow full deployment
        vm.startPrank(owner);
        bondManager.setMaxBondTvlPercent(100);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        bondManager.createBond(
            protocol,
            address(protocolToken),
            5000e6,
            10000e18,
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();

        // Warp time
        vm.warp(block.timestamp + elapsedSec);

        uint256 vested = bondManager.getVestedAmount(1);
        uint256 claimable = bondManager.getClaimableAmount(1);

        if (elapsedSec >= 30 days) {
            assertEq(vested, 10000e18);
            assertEq(claimable, 10000e18);
        } else {
            uint256 expectedVested = (10000e18 * elapsedSec) / (30 days);
            assertEq(vested, expectedVested);
            assertEq(claimable, expectedVested);
        }
    }

    // ============ TOKEN CLAIMING & SWAPPING ============

    function test_claimAndSellTokens() public {
        // Setup deposit and bond
        vm.prank(alice);
        vault.deposit(10000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.startPrank(owner);
        bondManager.setMaxBondTvlPercent(100);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        bondManager.createBond(
            protocol,
            address(protocolToken),
            5000e6,
            10000e18, // 10,000 MPT tokens to vest
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();

        // Warp past 30 days (fully vested)
        vm.warp(block.timestamp + 31 days);

        // Mint MPT tokens to protocol address so they can be transferred during claim
        protocolToken.mint(protocol, 10000e18);

        // Approve BondManager to pull protocol tokens
        vm.prank(protocol);
        protocolToken.approve(address(bondManager), type(uint256).max);

        // Claim bond tokens
        vm.prank(owner);
        bondManager.claimBond(1, 10000e18);

        // Check tokens were claimed
        assertEq(protocolToken.balanceOf(address(bondManager)), 10000e18);
        assertEq(bondManager.getClaimableAmount(1), 0);

        // Sell claimed tokens (MockDexRouter returns 1.25x rate)
        // cost basis = 5000 USDC for 10000 MPT tokens
        // swap returns: 10000e18 * 1.25e6 / 1e18 = 12500e6 USDC (12,500 USDC)
        // profit = 12500 - 5000 = 7500 USDC
        uint256 usdcBeforePool = usdc.balanceOf(address(rewardPool));
        uint256 usdcBeforeVault = usdc.balanceOf(address(vault));

        vm.prank(owner);
        (uint256 usdcReceived, uint256 profit) = bondManager.sellBondTokens(1, 10000e18, 0, address(rewardPool));

        assertEq(usdcReceived, 12500e6);
        assertEq(profit, 7500e6);

        // Verify capital flows:
        // 7500 USDC profit sent to rewardPool
        assertEq(usdc.balanceOf(address(rewardPool)), usdcBeforePool + 7500e6);
        // 5000 USDC principal returned to vault (QuestToken)
        assertEq(usdc.balanceOf(address(vault)), usdcBeforeVault + 5000e6);

        // Verify bond is marked inactive and vault capacity is updated
        assertEq(vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), 0);
    }

    // ============ EMERGENCY EXIT ============

    function test_emergencyExit() public {
        vm.prank(alice);
        vault.deposit(10000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.startPrank(owner);
        bondManager.setMaxBondTvlPercent(100);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        bondManager.createBond(
            protocol,
            address(protocolToken),
            5000e6,
            10000e18,
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );

        // Execute emergency exit (mark bond inactive, return deployed tracking)
        bondManager.emergencyExitBond(1, 0, address(rewardPool));
        vm.stopPrank();

        // Verify status
        assertEq(vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), 0);
    }

    // ============ STATELESS FUZZ TESTS ============

    function testFuzz_sellBondTokensWithVariableRate(uint256 dexRate) public {
        // Rate range: 0.1x to 3.0x (covers loss, break-even, and profit scenarios)
        // Rate is in 6-decimal scale: 1e6 = 1.0 USDC per token
        dexRate = bound(dexRate, 0.1e6, 3e6);

        // Setup: deposit, create bond
        vm.prank(alice);
        vault.deposit(10000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.startPrank(owner);
        bondManager.setMaxBondTvlPercent(100);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        uint256 usdcDeployed = 5000e6;
        uint256 tokenAmount = 10000e18;

        bondManager.createBond(
            protocol,
            address(protocolToken),
            usdcDeployed,
            tokenAmount,
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();

        // Fully vest
        vm.warp(block.timestamp + 31 days);

        // Setup protocol tokens for claim
        protocolToken.mint(protocol, tokenAmount);
        vm.prank(protocol);
        protocolToken.approve(address(bondManager), type(uint256).max);

        // Claim all tokens
        vm.prank(owner);
        bondManager.claimBond(1, tokenAmount);

        // Set variable DEX rate
        dexRouter.setRate(dexRate);

        // Calculate expected outputs
        uint256 expectedUsdcReceived = (tokenAmount * dexRate) / 1e18;
        uint256 costBasis = (usdcDeployed * tokenAmount) / tokenAmount; // = usdcDeployed
        uint256 expectedProfit = expectedUsdcReceived > costBasis
            ? expectedUsdcReceived - costBasis
            : 0;
        uint256 expectedPrincipal = expectedUsdcReceived - expectedProfit;

        // Ensure DEX router has enough USDC
        usdc.mint(address(dexRouter), expectedUsdcReceived);

        uint256 poolBefore = usdc.balanceOf(address(rewardPool));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        // Sell all tokens
        vm.prank(owner);
        (uint256 usdcReceived, uint256 profit) = bondManager.sellBondTokens(
            1, tokenAmount, 0, address(rewardPool)
        );

        // Verify DEX output
        assertEq(usdcReceived, expectedUsdcReceived, "USDC received mismatch");
        assertEq(profit, expectedProfit, "Profit mismatch");

        // Verify capital flows
        assertEq(
            usdc.balanceOf(address(rewardPool)),
            poolBefore + expectedProfit,
            "RewardPool should receive profit"
        );
        assertEq(
            usdc.balanceOf(address(vault)),
            vaultBefore + expectedPrincipal,
            "Vault should receive principal"
        );

        // Bond should be inactive
        assertEq(vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), 0);

        // NOTE: In loss scenarios (dexRate < 0.5e6), the vault receives less USDC
        // than was deployed. vault.markReturned() releases the full deployment amount
        // from tracking, so the vault's accounting diverges from its actual balance.
        // This is a known design limitation documented in testing_deep_review.md.
    }

    function testFuzz_partialClaimAndSell(uint256 elapsedSec, uint256 claimPct, uint256 sellPct) public {
        // Bound elapsed to somewhere within the 30-day vesting window
        elapsedSec = bound(elapsedSec, 1, 30 days - 1);
        claimPct = bound(claimPct, 1, 100); // claim 1-100% of vested
        sellPct = bound(sellPct, 1, 100);   // sell 1-100% of claimed

        // Setup
        vm.prank(alice);
        vault.deposit(10000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.startPrank(owner);
        bondManager.setMaxBondTvlPercent(100);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        uint256 tokenAmount = 10000e18;

        bondManager.createBond(
            protocol,
            address(protocolToken),
            5000e6,
            tokenAmount,
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();

        // Partial vesting
        vm.warp(block.timestamp + elapsedSec);

        uint256 vested = bondManager.getVestedAmount(1);
        uint256 claimable = bondManager.getClaimableAmount(1);
        assertEq(claimable, vested, "Claimable should equal vested (nothing claimed yet)");

        if (vested == 0) return; // edge case: no time passed

        // Claim a fraction of vested
        uint256 claimAmt = (vested * claimPct) / 100;
        if (claimAmt == 0) return;

        protocolToken.mint(protocol, claimAmt);
        vm.prank(protocol);
        protocolToken.approve(address(bondManager), type(uint256).max);

        vm.prank(owner);
        bondManager.claimBond(1, claimAmt);

        // Verify claimed tracking
        BondManager.Bond memory bond = bondManager.getBondData(1);
        assertEq(bond.tokensClaimed, claimAmt, "tokensClaimed mismatch");
        assertTrue(bond.active, "Bond should still be active (not fully processed)");

        // Sell a fraction of claimed
        uint256 sellAmt = (claimAmt * sellPct) / 100;
        if (sellAmt == 0) return;

        usdc.mint(address(dexRouter), 100_000e6); // ensure liquidity

        vm.prank(owner);
        bondManager.sellBondTokens(1, sellAmt, 0, address(rewardPool));

        // Verify processed tracking
        bond = bondManager.getBondData(1);
        assertEq(bond.tokensProcessed, sellAmt, "tokensProcessed mismatch");

        // Bond should still be active (not all tokens processed)
        if (sellAmt < tokenAmount) {
            assertTrue(bond.active, "Bond should be active when partially processed");
        }
    }

    function testFuzz_createBondCapacity(uint256 depositAmt, uint256 bondAmt) public {
        // Bound deposit to reasonable range
        depositAmt = bound(depositAmt, MIN_DEPOSIT, 1_000_000e6);
        // Bond amount between 1 USDC and the full deposit
        bondAmt = bound(bondAmt, 1e6, depositAmt);

        usdc.mint(alice, depositAmt);

        vm.prank(alice);
        vault.deposit(depositAmt, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.startPrank(owner);
        bondManager.setMaxBondTvlPercent(100);
        bondManager.registerProtocol(protocol, BondManager.ProtocolType.LENDING);

        // Should succeed: bondAmt <= depositAmt (available capacity)
        bondManager.createBond(
            protocol,
            address(protocolToken),
            bondAmt,
            bondAmt * 2, // 2:1 token ratio (arbitrary)
            0,
            3000,
            30,
            BondManager.ProtocolType.LENDING
        );
        vm.stopPrank();

        // Verify deployment tracking
        assertEq(
            vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS),
            bondAmt,
            "Deployed amount mismatch"
        );
        assertEq(usdc.balanceOf(protocol), bondAmt, "Protocol didn't receive USDC");
        assertEq(bondManager.totalUsdcDeployed(), bondAmt, "totalUsdcDeployed mismatch");
    }
}
