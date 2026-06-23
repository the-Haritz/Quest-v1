// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/Token/QuestToken.sol";
import "src/Pool/RewardPool.sol";
import "src/Token/BondManager.sol";
import "src/Interfaces/IVaultManager.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title QuestHandler — Stateful Fuzzing Handler
/// @notice Exposes bounded actions for Foundry's invariant fuzzer.
///         Maintains ghost variables for strict accounting assertions.
contract QuestHandler is Test {

    // ============ SYSTEM UNDER TEST ============
    QuestToken public vault;
    RewardPool public rewardPool;
    MockUSDCHandler public usdc;
    address public owner;

    // ============ ACTORS ============
    address[] public actors;
    uint256 public constant NUM_ACTORS = 3;

    // ============ GHOST VARIABLES ============
    // Shadow accounting maintained by the handler to assert strict equalities
    // in the invariant contract.

    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalWithdrawn;
    uint256 public ghost_totalRewardsDeposited;
    uint256 public ghost_totalRewardsClaimed;

    // Per-actor tracking
    mapping(address => uint256) public ghost_userDeposited;
    mapping(address => uint256) public ghost_userWithdrawn;

    // Call counters (for debugging failed runs)
    uint256 public calls_deposit;
    uint256 public calls_withdraw;
    uint256 public calls_depositRewards;
    uint256 public calls_claimRewards;
    uint256 public calls_warpTime;

    constructor(
        QuestToken _vault,
        RewardPool _rewardPool,
        MockUSDCHandler _usdc,
        address _owner
    ) {
        vault = _vault;
        rewardPool = _rewardPool;
        usdc = _usdc;
        owner = _owner;

        // Create actors
        for (uint256 i = 0; i < NUM_ACTORS; i++) {
            address actor = address(uint160(0x1000 + i));
            actors.push(actor);

            // Fund actors with plenty of USDC
            usdc.mint(actor, 10_000_000e6);

            // Approve vault for deposits
            vm.prank(actor);
            usdc.approve(address(_vault), type(uint256).max);
        }
    }

    // ============ TARGET FUNCTIONS ============

    /// @notice Deposit a bounded amount into a bounded tier
    function handler_deposit(uint256 actorSeed, uint256 amount, uint8 tierRaw) external {
        address actor = actors[actorSeed % NUM_ACTORS];
        tierRaw = uint8(bound(tierRaw, 0, 2));
        IVaultManager.LockupPeriod tier = IVaultManager.LockupPeriod(tierRaw);

        uint256 minDep = vault.minDeposit();
        uint256 maxTvl = vault.maxTVL();
        uint256 currentTvl = vault.totalDeposited();

        // Skip if we can't deposit
        if (currentTvl >= maxTvl) return;

        uint256 maxDeposit = maxTvl - currentTvl;
        if (maxDeposit < minDep) return;

        amount = bound(amount, minDep, maxDeposit > 100_000e6 ? 100_000e6 : maxDeposit);

        vm.prank(actor);
        vault.deposit(amount, tier);

        ghost_totalDeposited += amount;
        ghost_userDeposited[actor] += amount;
        calls_deposit++;
    }

    /// @notice Withdraw available (expired) funds
    function handler_withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % NUM_ACTORS];

        uint256 withdrawable = vault.getWithdrawableAmount(actor);
        if (withdrawable == 0) return;

        amount = bound(amount, 1, withdrawable);

        vm.prank(actor);
        vault.withdraw(amount, actor);

        ghost_totalWithdrawn += amount;
        ghost_userWithdrawn[actor] += amount;
        calls_withdraw++;
    }

    /// @notice Deposit rewards to the pool (simulating BondManager profits)
    function handler_depositRewards(uint256 amount) external {
        uint256 totalWeight = vault.getTotalWeightedBalance();
        if (totalWeight == 0) return; // Can't deposit rewards without depositors

        amount = bound(amount, 1e6, 50_000e6);

        // Mint USDC directly into the reward pool
        usdc.mint(address(rewardPool), amount);

        vm.prank(owner);
        rewardPool.depositRewards(amount);

        ghost_totalRewardsDeposited += amount;
        calls_depositRewards++;
    }

    /// @notice Claim rewards for a random actor
    function handler_claimRewards(uint256 actorSeed) external {
        address actor = actors[actorSeed % NUM_ACTORS];

        uint256 claimable = rewardPool.getClaimableRewards(actor);
        if (claimable == 0) return;

        vm.prank(owner);
        uint256 claimed = rewardPool.claimRewards(actor);

        ghost_totalRewardsClaimed += claimed;
        calls_claimRewards++;
    }

    /// @notice Warp time forward (bounded)
    function handler_warpTime(uint256 secondsToWarp) external {
        secondsToWarp = bound(secondsToWarp, 1 hours, 100 days);
        vm.warp(block.timestamp + secondsToWarp);
        calls_warpTime++;
    }

    // ============ HELPERS ============

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function getActorCount() external view returns (uint256) {
        return actors.length;
    }
}

// ============ Mock USDC for Handler ============
contract MockUSDCHandler is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
