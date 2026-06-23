//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/Interfaces/IVaultManager.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RewardPool - Fair Reward Distribution
/// @author Quest Team
/// @notice Implements index-based reward distribution ensuring fair allocation across all users
/// @dev Uses accumulating global rewardIndex pattern: when profits arrive, index increases proportional
/// to total weighted supply. Users claim by calculating (rewardIndex * userWeight) - rewardDebt.
/// This prevents double-claiming and ensures perfect fairness regardless of claim timing.
contract RewardPool is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    
    // ============ ERRORS ============
    
    error InsufficientRewards();
    error InvalidWeight();
    error UnauthorizedCaller();
    error InsufficientWeight();
    error ZeroAddress();
    
    // ============ STATE VARIABLES ============
    
    /// @notice USDC token (6 decimals, the reward token being distributed)
    IERC20 public usdc;
    
    /// @notice Vault reference (QuestToken) for user weight and deposit queries
    IVaultManager public vault;
    
    /// @notice Global accumulating reward index (in wei)
    /// @dev Increases as profits arrive: rewardIndex += (profit * 1e18) / totalWeightedSupply
    /// Per-user claimable = (rewardIndex * userWeight) / 1e18 - userRewardDebt
    uint256 public rewardIndex;
    
    /// @notice Total USDC distributed so far (audit trail)
    uint256 public totalRewardsAccumulated;

    /// @notice Total USDC claimed per user (audit trail)
    mapping(address => uint256) public totalClaimedByUser;

    // ============ EVENTS ============

    event RewardClaimed(
        address indexed user, 
        uint256 amount
    );
    
    event RewardsDeposited(
        address indexed manager,
        uint256 amount
    );

    // ============ INITIALIZATION ============

    /// @notice Initialize reward pool with vault, USDC, and owner
    /// @dev Sets up references for weight calculation and reward distribution
    /// @param initialOwner Owner address (manages pause, treasury functions)
    /// @param _vault IVaultManager contract (QuestToken) for deposit/weight queries
    /// @param _usdc USDC token contract (reward token to distribute)
    /// @custom:precondition All addresses must be non-zero
    function initialize(
        address initialOwner,
        IVaultManager _vault,
        address _usdc
    ) external initializer {
        if(
            address(initialOwner) == address(0) || 
            address (_vault) == address(0) ||
            address(_usdc) == address(0)
        ) {
            revert ZeroAddress();
        }

        __Ownable_init(initialOwner);
        __Pausable_init();

        usdc = IERC20(_usdc);
        vault = _vault;
    }

    // ============ REWARD QUERIES ============

    /// @notice Query claimable rewards for user (view-only, includes only EXPIRED deposits)
    /// @dev Calculates sum of claimable rewards across all user's expired deposits
    /// Only counts deposits where lockupEnd <= now
    /// @param user Address to query
    /// @return totalClaimable Total USDC claimable (sum of all expired deposits' shares)
    /// @custom:important Only expired deposits are included (by design for V1)
    function getClaimableRewards(address user) external view returns(uint256 totalClaimable) {
        if (address(user) == address(0)) revert ZeroAddress();

        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(user);

        uint256 length = deposits.length;
        for(uint256 i = 0; i < length; i++) {
            // Only count expired deposits (lockupEnd <= now)
            if(deposits[i].amount > 0 && block.timestamp >= deposits[i].lockupEnd) {
                // Calculate weight for this deposit
                uint256 weight = _calculateWeight(deposits[i].amount, uint8(deposits[i].tier));

                // Calculate accumulated rewards (rewardIndex * weight / 1e18)
                uint256 accumulated = Math.mulDiv(rewardIndex, weight, 1e18);

                // Calculate claimable (accumulated - already claimed)
                uint256 debt = deposits[i].rewardDebt;
                uint256 claimable = accumulated > debt ? accumulated - debt : 0;
                totalClaimable += claimable;
            }
        }        

        return totalClaimable;
    }

    // ============ REWARD CLAIMING ============

    /// @notice Claim all available rewards (iterates expired deposits, updates reward debt)
    /// @dev Reentrancy-safe. Iterates user's deposits, sums claimable, transfers USDC, updates state.
    /// Updates rewardDebt for each deposit to prevent double-claiming on future claims.
    /// @param user Address claiming rewards
    /// @return totalClaimed Total USDC transferred to user
    /// @custom:precondition User must have at least one expired deposit with claimable > 0
    /// @custom:precondition totalClaimed > 0 (reverts if nothing claimable)
    /// @custom:postcondition User receives USDC = totalClaimed
    /// @custom:postcondition totalClaimedByUser[user] increases by totalClaimed
    /// @custom:postcondition rewardDebt updated for each deposit claimed from
    /// @custom:important Claim can be called multiple times without double-claiming
    function claimRewards(address user) external nonReentrant returns(uint256 totalClaimed) {
        if (address(user) == address(0)) revert ZeroAddress();
        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(user);

        uint256 length = deposits.length;
        for(uint256 i = 0; i < length; i++) {

            // Only process expired deposits (lockupEnd <= now)
            if(deposits[i].amount > 0 && block.timestamp >= deposits[i].lockupEnd) {
                // Calculate weight for this deposit
                uint256 weight = _calculateWeight(deposits[i].amount, uint8(deposits[i].tier));

                // Calculate accumulated rewards (rewardIndex * weight / 1e18)
                uint256 accumulated = Math.mulDiv(rewardIndex, weight, 1e18);

                // Get previous debt (last snapshot)
                uint256 debt = deposits[i].rewardDebt;

                // Calculate claimable (accumulated - debt)
                uint256 claimable = accumulated > debt ? accumulated - debt : 0;   

                // Sum up total to transfer
                totalClaimed += claimable;

                // Update rewardDebt to current accumulated amount
                // This prevents double-claiming when rewardIndex increases next time
                vault.updateRewardDebt(user, i, accumulated);
            }
        }
        
        // Revert if no rewards to claim
        if(totalClaimed == 0) revert InsufficientRewards();

        // Transfer USDC to user
        usdc.safeTransfer(user, totalClaimed);

        // Audit trail: track total claimed by user
        totalClaimedByUser[user] += totalClaimed;

        // Emit event for off-chain tracking
        emit RewardClaimed(user, totalClaimed);

        return totalClaimed;

    }

    // ============ REWARD DEPOSITS ============

    /// @notice Deposit profits to pool, update global reward index (manager only)
    /// @dev Called by BondManager after selling bond tokens for profit.
    /// Updates rewardIndex proportional to total weighted supply: 
    /// rewardIndex += (amount * 1e18) / totalWeightedSupply
    /// @param amount USDC amount being deposited as profits (6 decimals)
    /// @return amount Amount deposited (for compatibility)
    /// @custom:precondition msg.sender must be authorized manager (vault.isManager)
    /// @custom:precondition amount > 0
    /// @custom:precondition totalWeightedSupply > 0 (must have active deposits)
    /// @custom:postcondition rewardIndex increases by: (amount * 1e18) / totalWeightedSupply
    /// @custom:postcondition totalRewardsAccumulated increases by amount
    /// @custom:important This is what enables fair distribution:
    ///  - Each profit deposit increases rewardIndex proportionally
    ///  - Users claiming later get access to accumulated profits via higher rewardIndex
    ///  - Their rewardDebt prevents claiming the same period twice
    function depositRewards(uint256 amount) external nonReentrant returns(uint256) {
        if (amount == 0) revert InvalidWeight();
        
        // Only managers (BondManager) can deposit profits
        if (!vault.isManager(msg.sender)) {
            revert UnauthorizedCaller();
        }
        
        // Must have active deposits to distribute to
        uint256 totalWeight = vault.getTotalWeightedBalance();
        if (totalWeight == 0) revert InvalidWeight();

        // Update global rewardIndex: accumulates as profits arrive
        rewardIndex += Math.mulDiv(amount, 1e18, totalWeight);
        
        // Track total (audit trail)
        totalRewardsAccumulated += amount;

        // Emit event for tracking
        emit RewardsDeposited(msg.sender, amount);

        return amount;
    }

    // ============ WEIGHT CALCULATIONS ============

    /// @notice Calculate weighted reward contribution for a deposit
    /// @dev Weight = amount * tier_multiplier / 1e18
    /// Longer lockups get higher multipliers: 30d=1.0x, 60d=1.5x, 90d=2.0x
    /// @param amount USDC deposit amount (6 decimals)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @return Deposit weight (in wei, divided by 1e18 when needed)
    function _calculateWeight(uint256 amount, uint8 tier) internal pure returns(uint256) {
        return Math.mulDiv(amount, _getTierMultiplier(tier), 1e18);
    }

    /// @notice Get reward weight multiplier for lockup tier
    /// @dev Longer lockups earn higher reward shares:
    /// - THIRTY_DAYS (0):  1.0x (1e18)
    /// - SIXTY_DAYS (1):   1.5x (15e17)
    /// - NINETY_DAYS (2):  2.0x (2e18)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @return Multiplier in wei (e.g., 15e17 = 1.5 when divided by 1e18)
    function _getTierMultiplier(uint8 tier) internal pure returns(uint256) {
        if (tier == 0) return 1e18;      // 30 days: 1.0x
        if (tier == 1) return 15e17;     // 60 days: 1.5x
        if (tier == 2) return 2e18;      // 90 days: 2.0x
        revert InvalidWeight();
    }
}
