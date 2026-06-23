// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/Token/QuestToken.sol";
import "src/Pool/RewardPool.sol";
import "src/Interfaces/IVaultManager.sol";
import "src/Interfaces/IRewardPool.sol";
import "./QuestHandler.sol";

/// @title QuestInvariants — Stateful Invariant Assertions
/// @notice Runs after each fuzzer sequence to verify system-wide health.
///         Uses ghost variables from QuestHandler for strict equality checks.
contract QuestInvariants is Test {
    QuestToken public vault;
    RewardPool public rewardPool;
    MockUSDCHandler public usdc;
    QuestHandler public handler;

    address public owner = address(0xABCD);

    function setUp() public {
        usdc = new MockUSDCHandler();

        // Deploy vault
        vault = new QuestToken();
        vault.initialize(
            owner,
            IVaultManager(address(vault)),
            address(usdc),
            10_000_000e6,  // 10M maxTVL
            100e6          // 100 USDC minDeposit
        );

        // Deploy reward pool
        rewardPool = new RewardPool();
        rewardPool.initialize(
            owner,
            IVaultManager(address(vault)),
            address(usdc)
        );

        // Wire contracts
        vm.startPrank(owner);
        vault.setManager(address(rewardPool), true);
        vault.setRewardPool(IRewardPool(address(rewardPool)));
        vm.stopPrank();

        // Deploy handler
        handler = new QuestHandler(vault, rewardPool, usdc, owner);

        // Target only the handler for fuzzing
        targetContract(address(handler));

        // Specify which functions the fuzzer can call
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = QuestHandler.handler_deposit.selector;
        selectors[1] = QuestHandler.handler_withdraw.selector;
        selectors[2] = QuestHandler.handler_depositRewards.selector;
        selectors[3] = QuestHandler.handler_claimRewards.selector;
        selectors[4] = QuestHandler.handler_warpTime.selector;

        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }

    // ============ INVARIANT 1: Vault USDC Balance ============
    // The vault's actual USDC balance must exactly equal:
    //   total deposited - total withdrawn
    // (Since we're not deploying bonds in the handler, no lending deductions)

    function invariant_vaultUsdcBalance() public view {
        uint256 expectedBalance = handler.ghost_totalDeposited() - handler.ghost_totalWithdrawn();
        uint256 actualBalance = usdc.balanceOf(address(vault));

        assertEq(
            actualBalance,
            expectedBalance,
            "INVARIANT VIOLATED: Vault USDC balance != deposits - withdrawals"
        );
    }

    // ============ INVARIANT 2: Weighted Supply Consistency ============
    // The global totalWeightedSupply must equal the sum of individual
    // weighted balances across all actors.

    function invariant_weightedSupplyConsistency() public view {
        uint256 sumOfWeights = 0;
        address[] memory actors = handler.getActors();

        for (uint256 i = 0; i < actors.length; i++) {
            sumOfWeights += vault.getWeightedBalance(actors[i]);
        }

        // Allow 1 wei rounding drift per deposit/withdrawal operation.
        // Math.mulDiv(amount, multiplier, 1e18) during deposit/withdraw can differ
        // from Math.mulDiv(multiplier, remainingAmount, 1e18) in getWeightedBalance
        // by up to 1 wei per operation due to integer floor division.
        uint256 totalOps = handler.calls_deposit() + handler.calls_withdraw();
        assertApproxEqAbs(
            vault.totalWeightedSupply(),
            sumOfWeights,
            totalOps + 1, // +1 for the zero-ops case
            "INVARIANT VIOLATED: totalWeightedSupply != sum of individual weights (beyond rounding tolerance)"
        );
    }

    // ============ INVARIANT 3: No Over-Deployment Per Tier ============
    // For each tier, deployed amount must never exceed locked amount.

    function invariant_noOverDeployment() public view {
        for (uint8 t = 0; t < 3; t++) {
            IVaultManager.LockupPeriod tier = IVaultManager.LockupPeriod(t);
            assertLe(
                vault.totalDeployedByTier(tier),
                vault.totalLockedByTier(tier),
                "INVARIANT VIOLATED: deployed > locked for a tier"
            );
        }
    }

    // ============ INVARIANT 4: Reward Pool Solvency ============
    // The reward pool's USDC balance must equal:
    //   total rewards deposited - total rewards claimed

    function invariant_rewardPoolSolvency() public view {
        uint256 expectedBalance = handler.ghost_totalRewardsDeposited() - handler.ghost_totalRewardsClaimed();
        uint256 actualBalance = usdc.balanceOf(address(rewardPool));

        assertEq(
            actualBalance,
            expectedBalance,
            "INVARIANT VIOLATED: RewardPool USDC balance != deposited - claimed"
        );
    }

    // ============ INVARIANT 5: QUEST Supply == totalDeposited ============
    // Since QUEST is minted 1:1 with USDC deposits and burned 1:1 on withdrawal,
    // the total supply must always equal totalDeposited.

    function invariant_questSupplyMatchesTotalDeposited() public view {
        assertEq(
            vault.totalSupply(),
            vault.totalDeposited(),
            "INVARIANT VIOLATED: QUEST totalSupply != totalDeposited"
        );
    }

    // ============ INVARIANT 6: No Double Claiming ============
    // Each user's total claimed must not exceed total rewards deposited.
    // (A strict per-user proportional bound is hard to express on-chain,
    // but this is a sanity ceiling.)

    function invariant_noOverClaiming() public view {
        address[] memory actors = handler.getActors();
        uint256 totalRewards = handler.ghost_totalRewardsDeposited();

        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(
                rewardPool.totalClaimedByUser(actors[i]),
                totalRewards,
                "INVARIANT VIOLATED: user claimed more than total rewards ever deposited"
            );
        }
    }

    // ============ INVARIANT 7: Sum of Locked Tiers == totalDeposited - totalWithdrawn ============
    // The sum of totalLockedByTier across all tiers must equal the current
    // totalDeposited (accounting for withdrawals that reduce locked amounts).

    function invariant_lockedTiersSumMatchesTotalDeposited() public view {
        uint256 sumLocked = 0;
        for (uint8 t = 0; t < 3; t++) {
            sumLocked += vault.totalLockedByTier(IVaultManager.LockupPeriod(t));
        }

        assertEq(
            sumLocked,
            vault.totalDeposited(),
            "INVARIANT VIOLATED: sum of totalLockedByTier != totalDeposited"
        );
    }

    // ============ CALL SUMMARY (debugging aid) ============

    function invariant_callSummary() public view {
        // This doesn't assert anything — it just logs call counts for debugging.
        // Foundry prints this after invariant runs if -vvv is set.
        console.log("--- Handler Call Summary ---");
        console.log("  deposits:       ", handler.calls_deposit());
        console.log("  withdrawals:    ", handler.calls_withdraw());
        console.log("  depositRewards: ", handler.calls_depositRewards());
        console.log("  claimRewards:   ", handler.calls_claimRewards());
        console.log("  warpTime:       ", handler.calls_warpTime());
        console.log("  ghost deposits: ", handler.ghost_totalDeposited());
        console.log("  ghost withdrawn:", handler.ghost_totalWithdrawn());
        console.log("  ghost rewards:  ", handler.ghost_totalRewardsDeposited());
        console.log("  ghost claimed:  ", handler.ghost_totalRewardsClaimed());
    }
}
