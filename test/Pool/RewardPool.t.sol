// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/Pool/RewardPool.sol";
import "src/Token/QuestToken.sol";
import "src/Interfaces/IVaultManager.sol";
import "src/Interfaces/IRewardPool.sol";
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

// ============ RewardPool Tests ============
contract RewardPoolTest is Test {
    RewardPool public rewardPool;
    QuestToken public vault;
    MockUSDC public usdc;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);

    uint256 public constant MIN_DEPOSIT = 100e6;
    uint256 public constant MAX_TVL = 10_000_000e6;

    // Mirror events for expectEmit
    event RewardClaimed(address indexed user, uint256 amount);
    event RewardsDeposited(address indexed manager, uint256 amount);

    function setUp() public {
        usdc = new MockUSDC();

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

        // Authorize rewardPool as manager in vault
        vm.startPrank(owner);
        vault.setManager(address(rewardPool), true);
        // Wire RewardPool reference so deposit() initializes rewardDebt correctly
        vault.setRewardPool(IRewardPool(address(rewardPool)));
        vm.stopPrank();

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);

        // Fund reward pool (simulating BondManager profits)
        usdc.mint(owner, 1_000_000e6);

        // Approve vault for user deposits
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(vault), type(uint256).max);

        // Owner approves reward pool for depositing rewards
        vm.prank(owner);
        usdc.approve(address(rewardPool), type(uint256).max);
    }

    // ============ INITIALIZATION TESTS ============

    function test_initialization() public view {
        assertEq(address(rewardPool.usdc()), address(usdc));
        assertEq(address(rewardPool.vault()), address(vault));
        assertEq(rewardPool.rewardIndex(), 0);
        assertEq(rewardPool.totalRewardsAccumulated(), 0);
    }

    function test_initializeRevertsOnZeroVault() public {
        RewardPool newPool = new RewardPool();
        vm.expectRevert(RewardPool.ZeroAddress.selector);
        newPool.initialize(owner, IVaultManager(address(0)), address(usdc));
    }

    function test_initializeRevertsOnZeroUsdc() public {
        RewardPool newPool = new RewardPool();
        vm.expectRevert(RewardPool.ZeroAddress.selector);
        newPool.initialize(owner, IVaultManager(address(vault)), address(0));
    }

    // ============ DEPOSIT REWARDS TESTS ============

    function test_depositRewards() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        assertTrue(rewardPool.rewardIndex() > 0);
        assertEq(rewardPool.totalRewardsAccumulated(), 100e6);
    }

    function test_depositRewardsUpdatesIndex() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        uint256 totalWeight = vault.getTotalWeightedBalance();
        assertEq(totalWeight, 1000e6);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        uint256 expectedIndex = (100e6 * 1e18) / totalWeight;
        assertEq(rewardPool.rewardIndex(), expectedIndex);
    }

    function test_depositRewardsRevertsOnZeroAmount() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(owner);
        vm.expectRevert(RewardPool.InvalidWeight.selector);
        rewardPool.depositRewards(0);
    }

    function test_depositRewardsRevertsForNonManager() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(alice);
        vm.expectRevert(RewardPool.UnauthorizedCaller.selector);
        rewardPool.depositRewards(100e6);
    }

    function test_depositRewardsRevertsOnZeroWeightedSupply() public {
        vm.prank(owner);
        vm.expectRevert(RewardPool.InvalidWeight.selector);
        rewardPool.depositRewards(100e6);
    }

    function test_depositRewardsEmitsEvent() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardsDeposited(owner, 100e6);
        rewardPool.depositRewards(100e6);
    }

    // ============ CLAIM REWARDS TESTS ============

    function test_claimRewardsAfterLockupExpiry() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        vm.warp(block.timestamp + 31 days);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(owner);
        uint256 claimed = rewardPool.claimRewards(alice);

        assertEq(claimed, 100e6);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 100e6);
        assertEq(rewardPool.totalClaimedByUser(alice), 100e6);
    }

    function test_claimRewardsRevertsBeforeLockupExpiry() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        vm.prank(owner);
        vm.expectRevert(RewardPool.InsufficientRewards.selector);
        rewardPool.claimRewards(alice);
    }

    function test_claimRewardsProportionalDistribution() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(bob);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.NINETY_DAYS);

        usdc.mint(address(rewardPool), 300e6);
        vm.prank(owner);
        rewardPool.depositRewards(300e6);

        vm.warp(block.timestamp + 91 days);

        vm.prank(owner);
        uint256 aliceClaimed = rewardPool.claimRewards(alice);
        assertEq(aliceClaimed, 100e6);

        vm.prank(owner);
        uint256 bobClaimed = rewardPool.claimRewards(bob);
        assertEq(bobClaimed, 200e6);
    }

    function test_claimRewardsPreventDoubleClaim() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        vm.warp(block.timestamp + 31 days);

        vm.prank(owner);
        rewardPool.claimRewards(alice);

        vm.prank(owner);
        vm.expectRevert(RewardPool.InsufficientRewards.selector);
        rewardPool.claimRewards(alice);
    }

    function test_claimRewardsAfterMultipleDeposits() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        vm.warp(block.timestamp + 31 days);

        vm.prank(owner);
        rewardPool.claimRewards(alice);

        usdc.mint(address(rewardPool), 200e6);
        vm.prank(owner);
        rewardPool.depositRewards(200e6);

        vm.prank(owner);
        uint256 claimed = rewardPool.claimRewards(alice);
        assertEq(claimed, 200e6);
    }

    function test_claimRewardsRevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RewardPool.ZeroAddress.selector);
        rewardPool.claimRewards(address(0));
    }

    function test_claimRewardsEmitsEvent() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        vm.warp(block.timestamp + 31 days);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(alice, 100e6);
        rewardPool.claimRewards(alice);
    }

    // ============ GETCLAIMABLEREWARDS TESTS ============

    function test_getClaimableRewardsBeforeExpiry() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        assertEq(rewardPool.getClaimableRewards(alice), 0);
    }

    function test_getClaimableRewardsAfterExpiry() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        vm.warp(block.timestamp + 31 days);
        assertEq(rewardPool.getClaimableRewards(alice), 100e6);
    }

    function test_getClaimableRewardsRevertsOnZeroAddress() public {
        vm.expectRevert(RewardPool.ZeroAddress.selector);
        rewardPool.getClaimableRewards(address(0));
    }

    // ============ WEIGHT CALCULATION TESTS ============

    function test_tierMultipliers() public {
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        vm.prank(bob);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.SIXTY_DAYS);

        vm.prank(charlie);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.NINETY_DAYS);

        assertEq(vault.getTotalWeightedBalance(), 4500e6);

        usdc.mint(address(rewardPool), 450e6);
        vm.prank(owner);
        rewardPool.depositRewards(450e6);

        vm.warp(block.timestamp + 91 days);

        assertEq(rewardPool.getClaimableRewards(alice), 100e6);
        assertEq(rewardPool.getClaimableRewards(bob), 150e6);
        assertEq(rewardPool.getClaimableRewards(charlie), 200e6);
    }

    // ============ LATE-DEPOSITOR PROTECTION TEST ============
    // Critical test proving the rewardDebt fix works.
    // Before the fix, Bob could claim rewards that accrued before he deposited.

    function test_lateDepositorGetsNoOldRewards() public {
        // Step 1: Alice deposits BEFORE rewards
        vm.prank(alice);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Step 2: Rewards deposited (100 USDC). Only Alice was present.
        usdc.mint(address(rewardPool), 100e6);
        vm.prank(owner);
        rewardPool.depositRewards(100e6);

        // rewardIndex is now > 0
        uint256 indexAfterFirstReward = rewardPool.rewardIndex();
        assertGt(indexAfterFirstReward, 0, "rewardIndex should be positive");

        // Step 3: Bob deposits AFTER rewards (late depositor)
        // With the fix, his rewardDebt is initialized to rewardIndex * weight / 1e18
        vm.prank(bob);
        vault.deposit(1000e6, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Verify Bob's rewardDebt was initialized (not zero!)
        IVaultManager.DepositReceipt[] memory bobDeposits = vault.getMyDeposits(bob);
        assertGt(bobDeposits[0].rewardDebt, 0, "Bob rewardDebt should be non-zero (snapshotted at deposit)");

        // Step 4: More rewards deposited (200 USDC). Both present.
        usdc.mint(address(rewardPool), 200e6);
        vm.prank(owner);
        rewardPool.depositRewards(200e6);

        // Step 5: Warp past lockup
        vm.warp(block.timestamp + 31 days);

        // Step 6: Alice claims — ALL of round 1 (100) + her share of round 2
        // Round 2: 200 USDC split across weight 2000 (alice 1000 + bob 1000) = 100 each
        // Alice total: 100 + 100 = 200 USDC
        vm.prank(owner);
        uint256 aliceClaimed = rewardPool.claimRewards(alice);
        assertEq(aliceClaimed, 200e6, "Alice should get 100 (round 1) + 100 (round 2)");

        // Step 7: Bob claims — ONLY his share of round 2
        // Round 2: 100 USDC (his half of the 200)
        // He should NOT get any of round 1's 100 USDC
        vm.prank(owner);
        uint256 bobClaimed = rewardPool.claimRewards(bob);
        assertEq(bobClaimed, 100e6, "Bob should ONLY get 100 (round 2), nothing from round 1");

        // Step 8: Total claimed should equal total rewards deposited
        assertEq(aliceClaimed + bobClaimed, 300e6, "Total claimed should equal total rewards");
    }

    // ============ STATELESS FUZZ TESTS ============

    function testFuzz_rewardDistribution(uint256 deposit1, uint256 deposit2, uint256 rewardAmount) public {
        deposit1 = bound(deposit1, MIN_DEPOSIT, 1_000_000e6);
        deposit2 = bound(deposit2, MIN_DEPOSIT, 1_000_000e6);
        rewardAmount = bound(rewardAmount, 1e6, 500_000e6);

        usdc.mint(alice, deposit1);
        usdc.mint(bob, deposit2);

        vm.prank(alice);
        vault.deposit(deposit1, IVaultManager.LockupPeriod.THIRTY_DAYS);
        vm.prank(bob);
        vault.deposit(deposit2, IVaultManager.LockupPeriod.THIRTY_DAYS);

        usdc.mint(address(rewardPool), rewardAmount);
        vm.prank(owner);
        rewardPool.depositRewards(rewardAmount);

        vm.warp(block.timestamp + 31 days);

        uint256 aliceClaimable = rewardPool.getClaimableRewards(alice);
        uint256 bobClaimable = rewardPool.getClaimableRewards(bob);

        // Total should equal rewards within rounding
        assertApproxEqAbs(aliceClaimable + bobClaimable, rewardAmount, 2, "Total claimable != rewards");

        // Proportionality: aliceClaimable / bobClaimable ≈ deposit1 / deposit2
        // Integer division in rewardIndex computation causes rounding drift
        // proportional to the ratio between deposits. The maximum absolute rounding error is bounded by maxDeposit.
        if (aliceClaimable > 0 && bobClaimable > 0) {
            uint256 lhs = aliceClaimable * deposit2;
            uint256 rhs = bobClaimable * deposit1;
            uint256 larger = lhs > rhs ? lhs : rhs;
            uint256 maxDeposit = deposit1 > deposit2 ? deposit1 : deposit2;
            // Tolerance: 0.1% of the larger value + maximum possible rounding drift (maxDeposit)
            uint256 tolerance = larger / 1000 + maxDeposit;
            assertApproxEqAbs(lhs, rhs, tolerance, "Reward ratio != deposit ratio");
        }
    }

    function testFuzz_rewardDistributionMixedTiers(uint256 amt30, uint256 amt90, uint256 rewardAmt) public {
        amt30 = bound(amt30, MIN_DEPOSIT, 1_000_000e6);
        amt90 = bound(amt90, MIN_DEPOSIT, 1_000_000e6);
        rewardAmt = bound(rewardAmt, 1e6, 500_000e6);

        usdc.mint(alice, amt30);
        usdc.mint(bob, amt90);

        vm.prank(alice);
        vault.deposit(amt30, IVaultManager.LockupPeriod.THIRTY_DAYS);
        vm.prank(bob);
        vault.deposit(amt90, IVaultManager.LockupPeriod.NINETY_DAYS);

        usdc.mint(address(rewardPool), rewardAmt);
        vm.prank(owner);
        rewardPool.depositRewards(rewardAmt);

        vm.warp(block.timestamp + 91 days);

        uint256 aliceClaimable = rewardPool.getClaimableRewards(alice);
        uint256 bobClaimable = rewardPool.getClaimableRewards(bob);

        assertApproxEqAbs(aliceClaimable + bobClaimable, rewardAmt, 2, "Total mismatch");

        // Bob weight = amt90 * 2, Alice weight = amt30 * 1
        if (aliceClaimable > 0 && bobClaimable > 0) {
            uint256 lhs = uint256(bobClaimable) * amt30;
            uint256 rhs = uint256(aliceClaimable) * amt90 * 2;
            uint256 larger = lhs > rhs ? lhs : rhs;
            uint256 maxWeight = amt30 > amt90 * 2 ? amt30 : amt90 * 2;
            // Tolerance: 0.1% of the larger value + maximum possible rounding drift (maxWeight)
            uint256 tolerance = larger / 1000 + maxWeight;
            assertApproxEqAbs(lhs, rhs, tolerance, "Mixed tier ratio mismatch");
        }
    }

    function testFuzz_lateDepositorProtection(uint256 earlyAmt, uint256 lateAmt, uint256 reward1, uint256 reward2) public {
        earlyAmt = bound(earlyAmt, MIN_DEPOSIT, 1_000_000e6);
        lateAmt = bound(lateAmt, MIN_DEPOSIT, 1_000_000e6);
        reward1 = bound(reward1, 1e6, 500_000e6);
        reward2 = bound(reward2, 1e6, 500_000e6);

        usdc.mint(alice, earlyAmt);
        usdc.mint(bob, lateAmt);

        // Alice deposits first
        vm.prank(alice);
        vault.deposit(earlyAmt, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // First reward round (only Alice present)
        usdc.mint(address(rewardPool), reward1);
        vm.prank(owner);
        rewardPool.depositRewards(reward1);

        // Bob deposits late
        vm.prank(bob);
        vault.deposit(lateAmt, IVaultManager.LockupPeriod.THIRTY_DAYS);

        // Second reward round (both present)
        usdc.mint(address(rewardPool), reward2);
        vm.prank(owner);
        rewardPool.depositRewards(reward2);

        vm.warp(block.timestamp + 31 days);

        uint256 aliceClaimable = rewardPool.getClaimableRewards(alice);
        uint256 bobClaimable = rewardPool.getClaimableRewards(bob);

        // Bob should NOT get any of reward1
        uint256 totalWeight = earlyAmt + lateAmt;
        uint256 bobMaxFromRound2 = (reward2 * lateAmt) / totalWeight;

        // Allow 1 USDC rounding tolerance
        assertApproxEqAbs(bobClaimable, bobMaxFromRound2, 1e6, "Bob should only get round 2 rewards");

        // Alice should get ALL of reward1 + her share of reward2
        uint256 aliceExpected = reward1 + (reward2 * earlyAmt) / totalWeight;
        assertApproxEqAbs(aliceClaimable, aliceExpected, 1e6, "Alice should get round1 + share of round2");
    }
}
