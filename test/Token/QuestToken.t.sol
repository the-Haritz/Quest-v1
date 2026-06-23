// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/Token/QuestToken.sol";
import "src/Interfaces/IVaultManager.sol";
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

// ============ QuestToken Tests ============
contract QuestTokenTest is Test {
    QuestToken public vault;
    MockUSDC public usdc;

    // Mirror events for expectEmit
    event Deposited(address indexed user, uint256 assets, IVaultManager.LockupPeriod lockupPeriod, uint256 lockupEnd);
    event Withdrawn(address indexed user, address indexed receiver, uint256 assets);

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    uint256 public constant MIN_DEPOSIT = 100e6;      // 100 USDC
    uint256 public constant MAX_TVL = 10_000_000e6;    // 10M USDC
    uint256 public constant DEPOSIT_AMOUNT = 1000e6;   // 1000 USDC

    function setUp() public {
        usdc = new MockUSDC();

        // Deploy vault as a proxy (use initializer)
        vault = new QuestToken();
        vault.initialize(
            owner,
            IVaultManager(address(vault)), // self-reference for manager
            address(usdc),
            MAX_TVL,
            MIN_DEPOSIT
        );

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        // Approve vault
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ INITIALIZATION TESTS ============

    function test_initialization() public view {
        assertEq(vault.name(), "Quest Token");
        assertEq(vault.symbol(), "QUEST");
        assertEq(vault.decimals(), 6);
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(vault.minDeposit(), MIN_DEPOSIT);
        assertEq(vault.maxTVL(), MAX_TVL);
        assertEq(vault.totalDeposited(), 0);
        assertEq(vault.totalWeightedSupply(), 0);
    }

    function test_initializeRevertsOnZeroOwner() public {
        QuestToken newVault = new QuestToken();
        vm.expectRevert(QuestToken.ZeroAddress.selector);
        newVault.initialize(
            address(0),
            IVaultManager(address(newVault)),
            address(usdc),
            MAX_TVL,
            MIN_DEPOSIT
        );
    }

    function test_initializeRevertsOnZeroUsdc() public {
        QuestToken newVault = new QuestToken();
        vm.expectRevert(QuestToken.ZeroAddress.selector);
        newVault.initialize(
            owner,
            IVaultManager(address(newVault)),
            address(0),
            MAX_TVL,
            MIN_DEPOSIT
        );
    }

    // ============ DEPOSIT TESTS ============

    function test_deposit30Days() public {
        vm.prank(alice);
        uint256 minted = vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        assertEq(minted, DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
        assertEq(vault.totalDeposited(), DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT);

        // Check deposit receipt
        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits.length, 1);
        assertEq(deposits[0].amount, DEPOSIT_AMOUNT);
        assertEq(uint8(deposits[0].tier), uint8(IVaultManager.LockupPeriod.THIRTY_DAYS));
        assertEq(deposits[0].lockupEnd, block.timestamp + 30 days);
        assertEq(deposits[0].rewardDebt, 0);
    }

    function test_deposit60Days() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.SIXTY_DAYS);

        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits[0].lockupEnd, block.timestamp + 60 days);
        assertEq(uint8(deposits[0].tier), uint8(IVaultManager.LockupPeriod.SIXTY_DAYS));
    }

    function test_deposit90Days() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.NINETY_DAYS);

        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits[0].lockupEnd, block.timestamp + 90 days);
        assertEq(uint8(deposits[0].tier), uint8(IVaultManager.LockupPeriod.NINETY_DAYS));
    }

    function test_depositUpdatesWeightedSupply() public {
        // 30-day deposit: multiplier = 1.0x
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        uint256 weight30 = vault.totalWeightedSupply();
        assertEq(weight30, DEPOSIT_AMOUNT); // 1000 * 1.0 = 1000

        // 60-day deposit: multiplier = 1.5x
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.SIXTY_DAYS);
        uint256 weight60 = vault.totalWeightedSupply() - weight30;
        assertEq(weight60, (DEPOSIT_AMOUNT * 15e17) / 1e18); // 1000 * 1.5 = 1500
    }

    function test_depositUpdatesLockedByTier() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        assertEq(vault.totalLockedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), DEPOSIT_AMOUNT);

        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.SIXTY_DAYS);
        assertEq(vault.totalLockedByTier(IVaultManager.LockupPeriod.SIXTY_DAYS), DEPOSIT_AMOUNT);
    }

    function test_multipleDeposits() public {
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        vault.deposit(2000e6, IVaultManager.LockupPeriod.SIXTY_DAYS);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT + 2000e6);
        assertEq(vault.totalDeposited(), DEPOSIT_AMOUNT + 2000e6);

        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits.length, 2);
        assertEq(deposits[0].amount, DEPOSIT_AMOUNT);
        assertEq(deposits[1].amount, 2000e6);
    }

    function test_depositRevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(QuestToken.InvalidAmount.selector);
        vault.deposit(0, IVaultManager.LockupPeriod.THIRTY_DAYS);
    }

    function test_depositRevertsOnBelowMinDeposit() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuestToken.MinDepositNotMet.selector, MIN_DEPOSIT, 50e6));
        vault.deposit(50e6, IVaultManager.LockupPeriod.THIRTY_DAYS);
    }

    function test_depositRevertsOnExceedMaxTvl() public {
        // Set a small max TVL
        vm.prank(owner);
        vault.setMaxTVL(500e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuestToken.MaxTVLExceeded.selector, 500e6, DEPOSIT_AMOUNT));
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
    }

    function test_depositRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pauseDeposits();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
    }

    function test_depositEmitsEvent() public {
        uint256 expectedLockupEnd = block.timestamp + 30 days;

        vm.prank(alice);
        vm.expectEmit(true, false, false, true);
        emit Deposited(alice, DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS, expectedLockupEnd);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
    }

    // ============ WITHDRAWAL TESTS ============

    function test_withdrawAfterLockupExpiry() public {
        // Deposit
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Fast forward past lockup
        vm.warp(block.timestamp + 31 days);

        // Withdraw
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(DEPOSIT_AMOUNT, alice);

        assertEq(burned, DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + DEPOSIT_AMOUNT);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalDeposited(), 0);
    }

    // ============ WITHDRAWAL FIFO & ROBUSTNESS ============

    function test_withdrawPartial() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        vault.withdraw(500e6, alice);

        assertEq(vault.balanceOf(alice), 500e6);
        assertEq(vault.totalDeposited(), 500e6);

        // Check receipt updated
        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits[0].amount, 500e6); // Reduced by 500
    }

    function test_withdrawToOtherAddress() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.warp(block.timestamp + 31 days);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, bob);

        assertEq(usdc.balanceOf(bob), bobUsdcBefore + DEPOSIT_AMOUNT);
    }

    function test_withdrawRevertsBeforeLockupExpiry() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Only 15 days passed (not enough)
        vm.warp(block.timestamp + 15 days);

        vm.prank(alice);
        vm.expectRevert(QuestToken.InsufficientBalance.selector);
        vault.withdraw(DEPOSIT_AMOUNT, alice);
    }

    function test_withdrawRevertsOnZeroAmount() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        vm.expectRevert(QuestToken.InvalidAmount.selector);
        vault.withdraw(0, alice);
    }

    // ============ WITHDRAWAL REVERTS ============

    function test_withdrawRevertsOnZeroReceiver() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        vm.expectRevert(QuestToken.ZeroAddress.selector);
        vault.withdraw(DEPOSIT_AMOUNT, address(0));
    }

    function test_withdrawUpdatesWeightedSupply() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.SIXTY_DAYS);
        uint256 weightBefore = vault.totalWeightedSupply();

        vm.warp(block.timestamp + 61 days);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice);

        assertEq(vault.totalWeightedSupply(), 0);
        assertTrue(weightBefore > 0);
    }

    function test_withdrawFIFOFromMultipleDeposits() public {
        // Alice makes two deposits with different lockups
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        vault.deposit(2000e6, IVaultManager.LockupPeriod.SIXTY_DAYS);
        vm.stopPrank();

        // Warp past 30 days but not 60
        vm.warp(block.timestamp + 31 days);

        // Can only withdraw 30-day deposit
        uint256 withdrawable = vault.getWithdrawableAmount(alice);
        assertEq(withdrawable, DEPOSIT_AMOUNT);

        vm.prank(alice);
        vault.withdraw(DEPOSIT_AMOUNT, alice);

        // First deposit fully withdrawn, second still locked
        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits[0].amount, 0);
        assertEq(deposits[1].amount, 2000e6);
    }

    function test_withdrawEmitsEvent() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.warp(block.timestamp + 31 days);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(alice, alice, DEPOSIT_AMOUNT);
        vault.withdraw(DEPOSIT_AMOUNT, alice);
    }

    // ============ WITHDRAWABLE AMOUNT QUERIES ============

    function test_getWithdrawableAmount() public {
        uint256 startTime = block.timestamp;
        vm.startPrank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        vault.deposit(2000e6, IVaultManager.LockupPeriod.SIXTY_DAYS);
        vm.stopPrank();

        // Nothing withdrawable initially
        assertEq(vault.getWithdrawableAmount(alice), 0);

        // After 30 days, first deposit is withdrawable
        vm.warp(startTime + 31 days);
        assertEq(vault.getWithdrawableAmount(alice), DEPOSIT_AMOUNT);

        // After 60 days, both withdrawable
        vm.warp(startTime + 61 days); // Now at 61 days total
        assertEq(vault.getWithdrawableAmount(alice), DEPOSIT_AMOUNT + 2000e6);
    }

    // ============ WEIGHTED BALANCE TESTS ============

    function test_getWeightedBalance() public {
        // 30-day: 1.0x
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        assertEq(vault.getWeightedBalance(alice), DEPOSIT_AMOUNT); // 1000 * 1.0

        // 90-day: 2.0x
        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.NINETY_DAYS);
        assertEq(vault.getWeightedBalance(bob), DEPOSIT_AMOUNT * 2); // 1000 * 2.0
    }

    function test_getTotalWeightedBalance() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS); // 1000 * 1.0 = 1000

        vm.prank(bob);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.NINETY_DAYS); // 1000 * 2.0 = 2000

        assertEq(vault.getTotalWeightedBalance(), DEPOSIT_AMOUNT + (DEPOSIT_AMOUNT * 2));
    }

    // ============ ADMIN CONTROLS ============

    function test_setMinDeposit() public {
        vm.prank(owner);
        vault.setMinDeposit(500e6);
        assertEq(vault.minDeposit(), 500e6);
    }

    // ============ MAX TVL TESTS ============

    function test_setMaxTvl() public {
        vm.prank(owner);
        vault.setMaxTVL(20_000_000e6);
        assertEq(vault.maxTVL(), 20_000_000e6);
    }

    function test_setMaxTvlRevertsIfBelowCurrentDeposits() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(QuestToken.MaxTVLExceeded.selector, 500e6, DEPOSIT_AMOUNT));
        vault.setMaxTVL(500e6);
    }

    function test_pauseAndUnpause() public {
        vm.prank(owner);
        vault.pauseDeposits();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(owner);
        vault.unpauseDeposits();

        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT);
    }

    function test_setVaultManager() public {
        address newManager = address(0x999);
        vm.prank(owner);
        vault.setVaultManager(IVaultManager(newManager));
        assertEq(address(vault.vaultManager()), newManager);
    }

    function test_setVaultManagerRevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(QuestToken.ZeroAddress.selector);
        vault.setVaultManager(IVaultManager(address(0)));
    }

    // ============ MANAGER AUTHORIZATION ============

    function test_isManager() public view {
        assertTrue(vault.isManager(owner));
        assertFalse(vault.isManager(alice));
    }

    // ============ MARK DEPLOYED / RETURNED ============

    function test_markDeployedAndReturned() public {
        // Deposit first
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Mark deployed (as owner / manager)
        vm.prank(owner);
        vault.markDeployed(0, 500e6); // Deploy 500 from 30-day tier

        assertEq(vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), 500e6);

        // Mark returned
        vm.prank(owner);
        vault.markReturned(0, 500e6);

        assertEq(vault.totalDeployedByTier(IVaultManager.LockupPeriod.THIRTY_DAYS), 0);
    }

    function test_markDeployedRevertsIfExceedsAvailable() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Try to deploy more than locked
        vm.prank(owner);
        vm.expectRevert(QuestToken.InsufficientBalance.selector);
        vault.markDeployed(0, DEPOSIT_AMOUNT + 1);
    }

    // ============ REWARD DEBT UPDATE ============

    function test_updateRewardDebt() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(owner);
        vault.updateRewardDebt(alice, 0, 500);

        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertEq(deposits[0].rewardDebt, 500);
    }

    function test_updateRewardDebtRevertsForNonOwner() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(alice);
        vm.expectRevert("Only owner or manager can update reward debt");
        vault.updateRewardDebt(alice, 0, 500);
    }

    // ============ TIER AVAILABILITY QUERIES ============

    // ============ REWARD DEPLOYMENT METRICS ============

    function test_getUserAvailableByTier() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Before lockup expiry: 0 available
        assertEq(vault.getUserAvailableByTier(alice, 0), 0);

        // After lockup expiry
        vm.warp(block.timestamp + 31 days);
        assertEq(vault.getUserAvailableByTier(alice, 0), DEPOSIT_AMOUNT);
    }

    function test_getProtocolAvailableByTier() public {
        vm.prank(alice);
        vault.deposit(DEPOSIT_AMOUNT, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Full amount available for deployment
        vm.prank(owner);
        assertEq(vault.getProtocolAvailableByTier(0), DEPOSIT_AMOUNT);

        // After marking some as deployed
        vm.prank(owner);
        vault.markDeployed(0, 400e6);

        vm.prank(owner);
        assertEq(vault.getProtocolAvailableByTier(0), 600e6);
    }

    // ============ STATELESS FUZZ TESTS ============

    function testFuzz_deposit(uint256 amount, uint8 tierRaw) public {
        // Bound tier to valid range (0, 1, 2)
        tierRaw = uint8(bound(tierRaw, 0, 2));
        IVaultManager.LockupPeriod tier = IVaultManager.LockupPeriod(tierRaw);

        // Bound amount between minDeposit and a reasonable max (avoid hitting maxTVL)
        amount = bound(amount, MIN_DEPOSIT, 50_000e6);

        // Fund alice with enough
        usdc.mint(alice, amount);

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 totalDepositedBefore = vault.totalDeposited();
        uint256 totalWeightedBefore = vault.totalWeightedSupply();
        uint256 lockedByTierBefore = vault.totalLockedByTier(tier);
        uint256 aliceQtkBefore = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 minted = vault.deposit(amount, tier);

        // QUEST minted 1:1 with USDC
        assertEq(minted, amount, "QUEST minted should equal deposit amount");
        assertEq(vault.balanceOf(alice), aliceQtkBefore + amount, "Alice QUEST balance mismatch");

        // Vault received USDC
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore + amount, "Vault USDC balance mismatch");

        // Global accounting
        assertEq(vault.totalDeposited(), totalDepositedBefore + amount, "totalDeposited mismatch");
        assertEq(vault.totalLockedByTier(tier), lockedByTierBefore + amount, "totalLockedByTier mismatch");

        // Weighted supply: amount * multiplier / 1e18
        uint256 expectedMultiplier;
        if (tierRaw == 0) expectedMultiplier = 1e18;
        else if (tierRaw == 1) expectedMultiplier = 15e17;
        else expectedMultiplier = 2e18;

        uint256 expectedWeightIncrease = (amount * expectedMultiplier) / 1e18;
        assertEq(
            vault.totalWeightedSupply(),
            totalWeightedBefore + expectedWeightIncrease,
            "Weighted supply mismatch"
        );

        // Deposit receipt recorded
        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(alice);
        assertGt(deposits.length, 0, "No deposits recorded");
        uint256 lastIdx = deposits.length - 1;
        assertEq(deposits[lastIdx].amount, amount, "Receipt amount mismatch");
        assertEq(uint8(deposits[lastIdx].tier), tierRaw, "Receipt tier mismatch");
    }

    function testFuzz_depositAndWithdraw(uint256 depositAmt, uint256 withdrawFraction, uint8 tierRaw) public {
        // Bound inputs
        tierRaw = uint8(bound(tierRaw, 0, 2));
        IVaultManager.LockupPeriod tier = IVaultManager.LockupPeriod(tierRaw);
        depositAmt = bound(depositAmt, MIN_DEPOSIT, 50_000e6);
        // Withdraw between 1 wei and the full deposit
        withdrawFraction = bound(withdrawFraction, 1, depositAmt);

        // Fund alice
        usdc.mint(alice, depositAmt);

        // Deposit
        vm.prank(alice);
        vault.deposit(depositAmt, tier);

        uint256 weightedBefore = vault.totalWeightedSupply();

        // Warp past lockup (max lockup is 90 days)
        vm.warp(block.timestamp + 91 days);

        // Withdraw fraction
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(withdrawFraction, alice);

        // QUEST burned == amount withdrawn
        assertEq(burned, withdrawFraction, "Burned amount mismatch");

        // USDC transferred to alice
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + withdrawFraction, "USDC not received");

        // Remaining QUEST balance
        assertEq(vault.balanceOf(alice), depositAmt - withdrawFraction, "Remaining QUEST mismatch");

        // totalDeposited reduced
        assertEq(vault.totalDeposited(), depositAmt - withdrawFraction, "totalDeposited mismatch");

        // Weighted supply reduced by correct amount
        uint256 expectedMultiplier;
        if (tierRaw == 0) expectedMultiplier = 1e18;
        else if (tierRaw == 1) expectedMultiplier = 15e17;
        else expectedMultiplier = 2e18;

        uint256 expectedWeightReduction = (withdrawFraction * expectedMultiplier) / 1e18;
        assertEq(
            vault.totalWeightedSupply(),
            weightedBefore - expectedWeightReduction,
            "Weighted supply not properly reduced"
        );
    }

    function testFuzz_multipleDepositsWeightedSupply(uint256 amt30, uint256 amt60, uint256 amt90) public {
        // Bound amounts to reasonable range (ensure total doesn't exceed maxTVL)
        amt30 = bound(amt30, MIN_DEPOSIT, 1_000_000e6);
        amt60 = bound(amt60, MIN_DEPOSIT, 1_000_000e6);
        amt90 = bound(amt90, MIN_DEPOSIT, 1_000_000e6);

        // Fund alice generously
        usdc.mint(alice, amt30 + amt60 + amt90);

        vm.startPrank(alice);
        vault.deposit(amt30, IVaultManager.LockupPeriod.THIRTY_DAYS);
        vault.deposit(amt60, IVaultManager.LockupPeriod.SIXTY_DAYS);
        vault.deposit(amt90, IVaultManager.LockupPeriod.NINETY_DAYS);
        vm.stopPrank();

        // Expected: amt30 * 1.0 + amt60 * 1.5 + amt90 * 2.0
        uint256 expectedWeight = amt30
            + (amt60 * 15e17) / 1e18
            + (amt90 * 2e18) / 1e18;

        assertEq(vault.totalWeightedSupply(), expectedWeight, "Multi-tier weighted supply mismatch");

        // Individual weighted balance should match
        assertEq(vault.getWeightedBalance(alice), expectedWeight, "User weighted balance mismatch");

        // totalDeposited should be simple sum
        assertEq(vault.totalDeposited(), amt30 + amt60 + amt90, "totalDeposited mismatch");
    }
}
