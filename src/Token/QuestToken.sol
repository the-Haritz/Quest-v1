//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "src/Interfaces/IVaultManager.sol";
import "src/Interfaces/IRewardPool.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title QuestToken - Quest Vault Token
/// @author Quest Team
/// @notice ERC20 deposit vault accepting USDC with tiered lockups (30/60/90 days) earning weighted rewards
/// @dev Implements upgradeable ERC20 vault with:
/// - Tiered deposit system with lockup periods (30/60/90 days)
/// - Weighted reward distribution via RewardPool (1.0x/1.5x/2.0x multipliers by tier)
/// - Capital deployment tracking for BondManager partnerships
/// - Pausable emergency controls
contract QuestToken is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IVaultManager
{
    using SafeERC20 for IERC20;

    // ============ ERRORS ============
    error ZeroAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error InvalidLockupPeriod();
    error MinDepositNotMet(uint256 required, uint256 provided);
    error MaxTVLExceeded(uint256 maxTVL, uint256 attemptedTVL);
    error FundsLockedUntil(uint256 unlockTimestamp);

    // ============ STATE VARIABLES ============

    /// @notice USDC token contract (6 decimals, underlying collateral)
    IERC20 public usdc;
    
    /// @notice Self-reference for manager authorization (used by BondManager and RewardPool)
    IVaultManager public vaultManager;
    
    /// @notice Total USDC deposited by all users (sum of all userDeposits[*].amount)
    /// @dev Used as denominator for proportional reward calculations
    uint256 public totalDeposited;
    
    /// @notice Sum of (deposit_amount * tier_multiplier) across all active deposits
    /// @dev Weighted supply = sum of (amount * multiplier) for each deposit
    /// Used by RewardPool to calculate per-user reward shares
    uint256 public totalWeightedSupply;
    
    /// @notice Minimum USDC required per single deposit (in 6 decimals)
    uint256 public minDeposit;
    
    /// @notice Maximum cumulative USDC that can be locked in vault (in 6 decimals)
    uint256 public maxTVL;

    /// @notice User's deposit records array (one per deposit made)
    /// @dev Deposits are never deleted; withdrawn amounts have amount=0
    /// RewardDebt tracks the user's claim state for fair distribution
    mapping(address => DepositReceipt[]) public userDeposits;
    
    /// @notice Total USDC locked (not deployed) per lockup tier
    /// @dev Key: LockupPeriod enum (THIRTY_DAYS=0, SIXTY_DAYS=1, NINETY_DAYS=2)
    /// Available per tier = totalLockedByTier[tier] - totalDeployedByTier[tier]
    mapping(LockupPeriod => uint256) public totalLockedByTier;
    
    /// @notice Total USDC currently deployed to protocols per tier (via BondManager)
    /// @dev Subtracted from totalLockedByTier to get available capacity
    /// Updated when bonds are created (marked deployed) or completed (marked returned)
    mapping(LockupPeriod => uint256) public totalDeployedByTier;

    /// @notice Maps account to authorization state as manager
    mapping(address => bool) public managers;

    /// @notice RewardPool reference for snapshotting rewardDebt at deposit time
    /// @dev If set, deposit() queries rewardPool.rewardIndex() to initialize rewardDebt
    /// preventing late depositors from claiming rewards accrued before their deposit
    IRewardPool public rewardPool;

    // ============ EVENTS ============

    event Deposited(
        address indexed user,
        uint256 assets,
        LockupPeriod lockupPeriod,
        uint256 lockupEnd
    );

    event Withdrawn(
        address indexed user,
        address indexed receiver,
        uint256 assets
    );

    event MinDepositUpdated(uint256 oldMinDeposit, uint256 newMinDeposit);
    event MaxTVLUpdated(uint256 oldMaxTVL, uint256 newMaxTVL);
    event VaultManagerUpdated(
        address indexed oldVaultManager,
        address indexed newVaultManager
    );
    event ManagerUpdated(address indexed manager, bool state);
    event RewardPoolUpdated(address indexed oldRewardPool, address indexed newRewardPool);

    // ============ INITIALIZATION ============

    /// @notice Initialize vault with owner, constraints, and token references
    /// @dev Can only be called once (initializer guard enforced by Upgradeable pattern).
    /// Sets up ERC20 token "Quest Token" (QUEST), ownership, and pausable state.
    /// @param initialOwner Address that will own the vault (controls pause, TVL, discount adjustments)
    /// @param _vaultManager Vault manager reference (used for manager authorization checks)
    /// @param _usdc USDC token contract address (6 decimals, the deposit collateral)
    /// @param _maxTVL Maximum total USDC that can ever be deposited (in 6 decimals)
    /// @param _minDeposit Minimum USDC amount per deposit (in 6 decimals, e.g., 1e8 = 100 USDC)
    /// @custom:precondition initialOwner, _vaultManager, and _usdc must all be non-zero addresses
    function initialize(
        address initialOwner,
        IVaultManager _vaultManager,
        address _usdc,
        uint256 _maxTVL,
        uint256 _minDeposit
    ) external initializer {
        if (
            initialOwner == address(0) ||
            address(_vaultManager) == address(0) ||
            _usdc == address(0)
        ) {
            revert ZeroAddress();
        }

        __ERC20_init("Quest Token", "QUEST");
        __Ownable_init(initialOwner);
        __Pausable_init();

        usdc = IERC20(_usdc);
        vaultManager = _vaultManager;
        maxTVL = _maxTVL;
        minDeposit = _minDeposit;
    }

    // ============ ERC20 OVERRIDES ============

    /// @notice Returns ERC20 token decimals (fixed at 6 to match USDC)
    /// @return uint8 Always returns 6
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ============ DEPOSIT / WITHDRAWAL ============

    /// @notice Deposit USDC into vault with chosen lockup tier, mint QUEST 1:1
    /// @dev Creates a new DepositReceipt with lockup timestamp calculated from current block time.
    /// Tier multiplier determines reward weight: THIRTY_DAYS=1.0x, SIXTY_DAYS=1.5x, NINETY_DAYS=2.0x.
    /// Enforces min/max deposit constraints and updates global weighted supply.
    /// @param assets Amount of USDC to deposit (6 decimals, e.g., 1e8 = 100 USDC)
    /// @param lockupPeriod Enum selection: THIRTY_DAYS (0), SIXTY_DAYS (1), or NINETY_DAYS (2)
    /// @return questMinted Amount of QUEST minted to caller (equals assets due to 1:1 ratio)
    /// @custom:precondition Caller has called usdc.approve(this, assets) first
    /// @custom:precondition assets >= minDeposit and assets > 0
    /// @custom:precondition totalDeposited + assets <= maxTVL
    /// @custom:precondition Deposits must not be paused
    /// @custom:postcondition User's weighted balance increases by: assets * multiplier[tier]
    /// @custom:postcondition totalWeightedSupply increases accordingly
    /// @custom:postcondition New DepositReceipt created with lockupEnd = block.timestamp + duration[tier]
    /// @custom:postcondition Caller receives QUEST equal to assets
    function deposit(
        uint256 assets,
        LockupPeriod lockupPeriod
    ) external whenNotPaused nonReentrant returns (uint256 questMinted) {
        if (assets == 0) revert InvalidAmount();
        if (assets < minDeposit) revert MinDepositNotMet(minDeposit, assets);

        uint256 newTVL = totalDeposited + assets;
        if (newTVL > maxTVL) revert MaxTVLExceeded(maxTVL, newTVL);

        // Calculate initial rewardDebt to prevent late-depositor reward theft
        // This snapshots the current rewardIndex so the depositor can only claim
        // rewards that accrue AFTER their deposit, not before
        uint256 weight = Math.mulDiv(assets, _multiplier(lockupPeriod), 1e18);
        uint256 initialRewardDebt = 0;
        if (address(rewardPool) != address(0)) {
            uint256 currentIndex = rewardPool.rewardIndex();
            initialRewardDebt = Math.mulDiv(currentIndex, weight, 1e18);
        }

        uint256 lockupEnd = block.timestamp + _lockupDuration(lockupPeriod);
        userDeposits[msg.sender].push(
            DepositReceipt({
                amount: assets,
                tier: lockupPeriod,
                lockupEnd: lockupEnd,
                expiryCounted: false,
                rewardDebt: initialRewardDebt
            })
        );
        totalLockedByTier[lockupPeriod] += assets;

        usdc.safeTransferFrom(msg.sender, address(this), assets);

        questMinted = assets;
        _mint(msg.sender, questMinted);
        totalDeposited = newTVL;
        totalWeightedSupply += weight;

        emit Deposited(msg.sender, assets, lockupPeriod, lockupEnd);

        return questMinted;
    }

    /// @notice Return withdrawable amount for a user (sum of expired deposits)
    /// @dev Queries all deposits and returns total amount where lockupEnd <= now
    /// @param user Address to query
    /// @return withdrawableAmount Total USDC available to withdraw (expired only)
    function getWithdrawableAmount(
        address user
    ) external view returns (uint256 withdrawableAmount) {
        DepositReceipt[] storage deposits = userDeposits[user];

        for (uint256 i = 0; i < deposits.length; i++) {
            if (
                block.timestamp >= deposits[i].lockupEnd &&
                deposits[i].amount > 0
            ) {
                withdrawableAmount += deposits[i].amount;
            }
        }

        return withdrawableAmount;
    }

    /// @notice Withdraw USDC from vault, burn QUEST, update weighted supply
    /// @dev Implements FIFO withdrawal from expired deposits only. Correctly tracks weight reduction
    /// by summing the actual tier multipliers of withdrawn deposits (not using a parameter).
    /// @param assets Amount of USDC to withdraw (6 decimals)
    /// @param receiver Address to receive the USDC
    /// @return questBurned Amount of QUEST burned (equals assets)
    /// @custom:precondition assets <= getWithdrawableAmount(caller)
    /// @custom:precondition assets > 0
    /// @custom:precondition Caller must have at least assets QUEST
    /// @custom:precondition Withdrawals must not be paused
    /// @custom:postcondition QUEST burned from caller = assets
    /// @custom:postcondition USDC transferred to receiver = assets
    /// @custom:postcondition totalWeightedSupply reduced by sum of (withdrawn_amount * tier_multiplier)
    /// @custom:postcondition Deposit records updated (amount set to 0 for fully withdrawn)
    function withdraw(
        uint256 assets,
        address receiver
    ) external whenNotPaused nonReentrant returns (uint256 questBurned) {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        DepositReceipt[] storage deposits = userDeposits[msg.sender];
        uint256 len = deposits.length;

        uint256 withdrawableAmount = 0;
        uint256 amountToWithdraw = assets;
        uint256 weightToReduce = 0;

        // Calculate total withdrawable first
        for (uint256 i = 0; i < len; ++i) {
            if (block.timestamp >= deposits[i].lockupEnd && deposits[i].amount > 0) {
                withdrawableAmount += deposits[i].amount;
            }
        }

        if (assets > withdrawableAmount) revert InsufficientBalance();

        // SINGLE LOOP - track actual weight deduction based on each deposit's tier
        for (uint256 i = 0; i < len; ++i) {
            DepositReceipt storage userDeposit = deposits[i];

            // Skip locked deposits (allow withdrawal from expired ones only)
            if (block.timestamp < userDeposit.lockupEnd) {
                continue;
            }

            // Mark as withdrawn (deduct from receipt, FIFO style)
            if (amountToWithdraw > 0 && userDeposit.amount > 0) {
                uint256 deductFromThisDeposit = userDeposit.amount > amountToWithdraw
                    ? amountToWithdraw
                    : userDeposit.amount;

                // Track weight reduction for THIS specific deposit's tier (not parameter-based)
                weightToReduce += Math.mulDiv(deductFromThisDeposit, _multiplier(userDeposit.tier), 1e18);

                userDeposit.amount -= deductFromThisDeposit;
                totalLockedByTier[userDeposit.tier] -= deductFromThisDeposit;
                amountToWithdraw -= deductFromThisDeposit;
            }
        }

        questBurned = assets;
        _burn(msg.sender, questBurned);
        totalDeposited -= assets;
        totalWeightedSupply -= weightToReduce;
        usdc.safeTransfer(receiver, assets);

        emit Withdrawn(msg.sender, receiver, assets);

        return questBurned;
    }

    // ============ USER QUERIES ============

    /// @notice Query user's available USDC by specific lockup tier
    /// @dev Only returns unlocked amounts (lockupEnd <= now) for given tier
    /// @param user Address to query
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @return available Total USDC available to withdraw in this tier
    function getUserAvailableByTier(
        address user,
        uint8 tier
    ) external view returns (uint256 available) {
        LockupPeriod lockupTier = LockupPeriod(tier);
        DepositReceipt[] storage deposits = userDeposits[user];
        for (uint256 i = 0; i < deposits.length; i++) {
            if (
                deposits[i].tier == lockupTier &&
                block.timestamp >= deposits[i].lockupEnd &&
                deposits[i].amount > 0
            ) {
                available += deposits[i].amount;
            }
        }
        return available;
    }

    // ============ ADMIN QUERIES ============

    /// @notice Query total USDC locked in specified tier (admin only)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @return Total USDC locked in tier (not yet deployed)
    function getProtocolLockedByTier(
        uint8 tier
    ) external view returns (uint256) {
        LockupPeriod lockupTier = LockupPeriod(tier);
        return totalLockedByTier[lockupTier];
    }

    /// @notice Query total USDC deployed to protocols in specified tier (admin only)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @return Total USDC deployed via BondManager in tier
    function getProtocolDeployedByTier(
        uint8 tier
    ) external view returns (uint256) {
        LockupPeriod lockupTier = LockupPeriod(tier);
        return totalDeployedByTier[lockupTier];
    }

    /// @notice Query available USDC for new deployments in specified tier (admin only)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @return Available USDC = locked - deployed (capacity for new bonds)
    function getProtocolAvailableByTier(
        uint8 tier
    ) external view returns (uint256) {
        LockupPeriod lockupTier = LockupPeriod(tier);
        return totalLockedByTier[lockupTier] - totalDeployedByTier[lockupTier];
    }

    // ============ BOND MANAGER CALLS (manager-only) ============

    /// @notice Track USDC being deployed to external protocol (called by BondManager)
    /// @dev Increases totalDeployedByTier, reducing available capacity
    /// Only callable by authorized manager (via isManager check)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @param amount USDC amount being deployed (6 decimals)
    /// @custom:precondition msg.sender must pass isManager() check
    /// @custom:precondition deployed + amount <= locked (sufficient capacity)
    /// @custom:postcondition totalDeployedByTier[tier] increases by amount
    function markDeployed(uint8 tier, uint256 amount) external {
        require(vaultManager.isManager(msg.sender), "Not authorized");
        LockupPeriod lockupTier = LockupPeriod(tier);
        if (amount > totalLockedByTier[lockupTier] - totalDeployedByTier[lockupTier])
            revert InsufficientBalance();
        totalDeployedByTier[lockupTier] += amount;
    }

    /// @notice Track USDC being returned from external protocol (called by BondManager)
    /// @dev Decreases totalDeployedByTier, freeing up capacity for new deployments
    /// Only callable by authorized manager (via isManager check)
    /// @param tier Lockup period: 0=30d, 1=60d, 2=90d
    /// @param amount USDC amount being returned (6 decimals)
    /// @custom:precondition msg.sender must pass isManager() check
    /// @custom:precondition amount <= deployed (cannot undershoot)
    /// @custom:postcondition totalDeployedByTier[tier] decreases by amount
    function markReturned(uint8 tier, uint256 amount) external {
        require(vaultManager.isManager(msg.sender), "Not authorized");
        LockupPeriod lockupTier = LockupPeriod(tier);
        if (totalDeployedByTier[lockupTier] >= amount) {
            totalDeployedByTier[lockupTier] -= amount;
        } else {
            revert InsufficientBalance();
        }
    }

    /// @notice Transfer USDC to external protocol (called by BondManager for deployment)
    /// @dev Only callable by authorized manager (via isManager check)
    /// @param to Protocol address receiving USDC
    /// @param amount USDC amount to transfer (6 decimals)
    /// @custom:precondition msg.sender must pass isManager() check
    /// @custom:precondition Vault must have sufficient USDC balance
    function lendUSDC(address to, uint256 amount) external {
        require(vaultManager.isManager(msg.sender), "Not authorized");
        usdc.safeTransfer(to, amount);
    }

    // ============ AUTHORIZATION ============

    /// @notice Check if account is authorized manager (used by BondManager and RewardPool)
    /// @dev Allows owner and accounts explicitly set in managers mapping
    /// @param account Address to check
    /// @return bool True if account is authorized manager
    function isManager(address account) external view returns (bool) {
        return account == owner() || managers[account];
    }

    // ============ REWARD POOL CALLS ============

    /// @notice Get user's deposits array (called by RewardPool for reward calculation)
    /// @param user Address to query
    /// @return DepositReceipt[] array of all deposits (including empty/withdrawn ones)
    function getMyDeposits(
        address user
    ) external view returns (DepositReceipt[] memory) {
        return userDeposits[user];
    }

    /// @notice Update user's reward debt after claim (called by RewardPool)
    /// @dev Persists the user's current accumulated reward state to prevent double-claiming
    /// Only callable by owner or authorized manager/RewardPool
    /// @param user Address whose reward debt to update
    /// @param depositIndex Index in userDeposits[user] array
    /// @param newRewardDebt New rewardIndex snapshot for this deposit
    /// @custom:precondition msg.sender must be owner or authorized manager
    /// @custom:precondition depositIndex must be valid index in userDeposits[user]
    /// @custom:postcondition userDeposits[user][depositIndex].rewardDebt = newRewardDebt
    function updateRewardDebt(
        address user,
        uint256 depositIndex,
        uint256 newRewardDebt
    ) external {
        require(msg.sender == owner() || managers[msg.sender], "Only owner or manager can update reward debt");
        require(depositIndex < userDeposits[user].length, "Invalid deposit index");
        userDeposits[user][depositIndex].rewardDebt = newRewardDebt;
    }

    // ============ ADMIN CONTROLS ============

    /// @notice Set authorization state for a manager address (owner only)
    /// @param manager Address to update
    /// @param state True to authorize, false to revoke
    function setManager(address manager, bool state) external onlyOwner {
        if (manager == address(0)) revert ZeroAddress();
        managers[manager] = state;
        emit ManagerUpdated(manager, state);
    }

    /// @notice Set minimum deposit amount (admin only)
    /// @param newMinDeposit New minimum USDC per deposit (6 decimals)
    function setMinDeposit(uint256 newMinDeposit) external onlyOwner {
        uint256 oldMinDeposit = minDeposit;
        minDeposit = newMinDeposit;
        emit MinDepositUpdated(oldMinDeposit, newMinDeposit);
    }

    /// @notice Set maximum total value locked (admin only)
    /// @dev New maxTVL must be >= current totalDeposited
    /// @param newMaxTVL New maximum USDC that can be locked (6 decimals)
    function setMaxTVL(uint256 newMaxTVL) external onlyOwner {
        if (newMaxTVL < totalDeposited)
            revert MaxTVLExceeded(newMaxTVL, totalDeposited);
        uint256 oldMaxTVL = maxTVL;
        maxTVL = newMaxTVL;
        emit MaxTVLUpdated(oldMaxTVL, newMaxTVL);
    }

    /// @notice Update vault manager reference (admin only)
    /// @param newVaultManager New IVaultManager contract address
    function setVaultManager(IVaultManager newVaultManager) external onlyOwner {
        if (address(newVaultManager) == address(0)) revert ZeroAddress();
        address oldVaultManager = address(vaultManager);
        vaultManager = newVaultManager;
        emit VaultManagerUpdated(oldVaultManager, address(newVaultManager));
    }

    /// @notice Emergency pause deposits (admin only)
    function pauseDeposits() external onlyOwner {
        _pause();
    }

    /// @notice Resume deposits after emergency pause (admin only)
    function unpauseDeposits() external onlyOwner {
        _unpause();
    }

    /// @notice Set reward pool reference for rewardDebt initialization (admin only)
    /// @dev Must be set after RewardPool is deployed so deposit() can snapshot rewardIndex
    /// @param _rewardPool Address of the RewardPool contract
    function setRewardPool(IRewardPool _rewardPool) external onlyOwner {
        address oldRewardPool = address(rewardPool);
        rewardPool = _rewardPool;
        emit RewardPoolUpdated(oldRewardPool, address(_rewardPool));
    }

    // ============ WEIGHT / REWARD CALCULATIONS ============

    /// @notice Calculate user's total weighted balance across all deposits
    /// @dev Weighted balance = sum of (deposit_amount * tier_multiplier) for all active deposits
    /// Used by RewardPool to determine user's share of rewards
    /// @param user Address to query
    /// @return weightedBalance Total weight (numerator for reward share calculation)
    function getWeightedBalance(
        address user
    ) external view returns (uint256 weightedBalance) {
        DepositReceipt[] storage deposits = userDeposits[user];
        for (uint256 i = 0; i < deposits.length; i++) {
            uint256 mult = _multiplier(deposits[i].tier);
            weightedBalance += Math.mulDiv(mult, deposits[i].amount, 1e18);
        }
        return weightedBalance;
    }

    /// @notice Get total weighted supply across all users
    /// @return Total weighted balance of entire vault (denominator for reward share calculation)
    function getTotalWeightedBalance() external view returns (uint256) {
        return totalWeightedSupply;
    }

    // ============ INTERNAL HELPERS ============

    /// @notice Calculate lockup duration in seconds for given tier
    /// @param lockupPeriod Enum: THIRTY_DAYS (0), SIXTY_DAYS (1), NINETY_DAYS (2)
    /// @return Duration in seconds (30 days = 2592000, 60 days = 5184000, 90 days = 7776000)
    function _lockupDuration(
        LockupPeriod lockupPeriod
    ) internal pure returns (uint256) {
        if (lockupPeriod == LockupPeriod.THIRTY_DAYS) return 30 days;
        if (lockupPeriod == LockupPeriod.SIXTY_DAYS) return 60 days;
        if (lockupPeriod == LockupPeriod.NINETY_DAYS) return 90 days;
        revert InvalidLockupPeriod();
    }

    /// @notice Calculate reward weight multiplier for given tier
    /// @dev Longer lockups earn higher reward shares:
    /// - THIRTY_DAYS (0):  1.0x (1e18)
    /// - SIXTY_DAYS (1):   1.5x (15e17)
    /// - NINETY_DAYS (2):  2.0x (2e18)
    /// @param tier Enum: THIRTY_DAYS (0), SIXTY_DAYS (1), NINETY_DAYS (2)
    /// @return Multiplier in wei format (e.g., 15e17 = 1.5 when divided by 1e18)
    function _multiplier(LockupPeriod tier) internal pure returns (uint256) {
        if (tier == LockupPeriod.THIRTY_DAYS) return 1e18;      // 1.0x
        if (tier == LockupPeriod.SIXTY_DAYS) return 15e17;     // 1.5x
        if (tier == LockupPeriod.NINETY_DAYS) return 2e18;      // 2.0x
        revert InvalidLockupPeriod();
    }
}
