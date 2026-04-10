//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "src/Interfaces/IVaultManager.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract QVToken is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidAmount();
    error InsufficientBalance();
    error InvalidLockupPeriod();
    error MinDepositNotMet(uint256 required, uint256 provided);
    error MaxTVLExceeded(uint256 maxTVL, uint256 attemptedTVL);
    error FundsLockedUntil(uint256 unlockTimestamp);

    enum LockupPeriod {
        THIRTY_DAYS,
        SIXTY_DAYS,
        NINETY_DAYS
    }

    IERC20 public usdc;
    IVaultManager public vaultManager;

    uint256 public totalDeposited;
    uint256 public minDeposit;
    uint256 public maxTVL;

    struct DepositReceipt {
        uint256 amount;
        LockupPeriod tier;
        uint256 lockupEnd;
        bool expiryCounted;
    }

    mapping(address => DepositReceipt[]) public userDeposits; // a user's total deposits
    mapping(LockupPeriod => uint256) public totalLockedByTier; // total capital locked per tier
    mapping(LockupPeriod => uint256) public totalDeployedByTier; // total capital deployed per tier

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

        __ERC20_init("Quantum Token", "QTK");
        __Ownable_init(initialOwner);
        __Pausable_init();

        usdc = IERC20(_usdc);
        vaultManager = _vaultManager;
        maxTVL = _maxTVL;
        minDeposit = _minDeposit;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function deposit(
        uint256 assets,
        LockupPeriod lockupPeriod
    ) external whenNotPaused nonReentrant returns (uint256 qtkMinted) {
        if (assets == 0) revert InvalidAmount();
        if (assets < minDeposit) revert MinDepositNotMet(minDeposit, assets);

        uint256 newTVL = totalDeposited + assets;
        if (newTVL > maxTVL) revert MaxTVLExceeded(maxTVL, newTVL);

        uint256 lockupEnd = block.timestamp + _lockupDuration(lockupPeriod);
        userDeposits[msg.sender].push(
            DepositReceipt({
                amount: assets,
                tier: lockupPeriod,
                lockupEnd: lockupEnd,
                expiryCounted: false
            })
        );
        totalLockedByTier[lockupPeriod] += assets;

        usdc.safeTransferFrom(msg.sender, address(this), assets);

        qtkMinted = assets;
        _mint(msg.sender, qtkMinted);
        totalDeposited = newTVL;

        emit Deposited(msg.sender, assets, lockupPeriod, lockupEnd);

        return qtkMinted;
    }

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

    function withdraw(
        uint256 assets,
        address receiver
    ) external whenNotPaused nonReentrant returns (uint256 qtkBurned) {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        DepositReceipt[] storage deposits = userDeposits[msg.sender];
        uint256 len = deposits.length;

        uint256 withdrawableAmount = 0;
        uint256 amountToWithdraw = assets;

        // SINGLE LOOP - do everything in one pass
        for (uint256 i = 0; i < len; ++i) {
            DepositReceipt storage userDeposit = deposits[i];

            // 1. Skip locked deposits (allow withdrawal from expired ones only)
            if (block.timestamp < userDeposit.lockupEnd) {
                continue;
            }

            // 3. Sum withdrawable (expired deposits with funds)
            if (userDeposit.amount > 0) {
                withdrawableAmount += userDeposit.amount;
            }

            // 4. Mark as withdrawn (deduct from receipt, FIFO style)
            if (amountToWithdraw > 0 && userDeposit.amount > 0) {
                uint256 deductFromThisDeposit = userDeposit.amount >
                    amountToWithdraw
                    ? amountToWithdraw
                    : userDeposit.amount;

                userDeposit.amount -= deductFromThisDeposit;
                totalLockedByTier[userDeposit.tier] -= deductFromThisDeposit;
                amountToWithdraw -= deductFromThisDeposit;
            }
        }

        if (assets > withdrawableAmount) revert InsufficientBalance();

        qtkBurned = assets;
        _burn(msg.sender, qtkBurned);
        totalDeposited -= assets;
        usdc.safeTransfer(receiver, assets);

        emit Withdrawn(msg.sender, receiver, assets);

        return qtkBurned;
    }

    function setMinDeposit(uint256 newMinDeposit) external onlyOwner {
        uint256 oldMinDeposit = minDeposit;
        minDeposit = newMinDeposit;
        emit MinDepositUpdated(oldMinDeposit, newMinDeposit);
    }

    function setMaxTVL(uint256 newMaxTVL) external onlyOwner {
        if (newMaxTVL < totalDeposited)
            revert MaxTVLExceeded(newMaxTVL, totalDeposited);
        uint256 oldMaxTVL = maxTVL;
        maxTVL = newMaxTVL;
        emit MaxTVLUpdated(oldMaxTVL, newMaxTVL);
    }

    // PUBLIC - user can query their deposits by tier
    function getUserAvailableByTier(
        address user,
        LockupPeriod tier
    ) external view returns (uint256 available) {
        DepositReceipt[] storage deposits = userDeposits[user];
        for (uint256 i = 0; i < deposits.length; i++) {
            if (
                deposits[i].tier == tier &&
                block.timestamp >= deposits[i].lockupEnd &&
                deposits[i].amount > 0
            ) {
                available += deposits[i].amount;
            }
        }
        return available;
    }

    // ADMIN - protocol-level queries
    function getProtocolLockedByTier(
        LockupPeriod tier
    ) external view onlyOwner returns (uint256) {
        return totalLockedByTier[tier];
    }

    function getProtocolDeployedByTier(
        LockupPeriod tier
    ) external view onlyOwner returns (uint256) {
        return totalDeployedByTier[tier];
    }

    function getProtocolAvailableByTier(
        LockupPeriod tier
    ) external view onlyOwner returns (uint256) {
        return totalLockedByTier[tier] - totalDeployedByTier[tier];
    }

    // STATE-MUTATING - for BondManager
    function markDeployed(LockupPeriod tier, uint256 amount) external {
        require(vaultManager.isManager(msg.sender), "Not authorized");
        if (amount > totalLockedByTier[tier] - totalDeployedByTier[tier])
            revert InsufficientBalance();
        totalDeployedByTier[tier] += amount;
    }

    function markReturned(LockupPeriod tier, uint256 amount) external {
        require(vaultManager.isManager(msg.sender), "Not authorized");
        if (totalDeployedByTier[tier] >= amount) {
            totalDeployedByTier[tier] -= amount;
            //available shouldn't increase by returned cause available is meant to be deployed and people might want to withdraw upon lock expiry...guess i have to resort to a reserve ratio being maintained and checked by the BondManager
        } else {
            revert InsufficientBalance();
        }
    }

    function lendUSDC(address to, uint256 amount) external {
        require(vaultManager.isManager(msg.sender), "Not authorized");
        usdc.safeTransfer(to, amount);
    }

    function getMyDeposits(
        address user
    ) external view returns (DepositReceipt[] memory) {
        return userDeposits[user];
    }

    function setVaultManager(IVaultManager newVaultManager) external onlyOwner {
        if (address(newVaultManager) == address(0)) revert ZeroAddress();
        address oldVaultManager = address(vaultManager);
        vaultManager = newVaultManager;
        emit VaultManagerUpdated(oldVaultManager, address(newVaultManager));
    }

    function pauseDeposits() external onlyOwner {
        _pause();
    }

    function unpauseDeposits() external onlyOwner {
        _unpause();
    }

    function _lockupDuration(
        LockupPeriod lockupPeriod
    ) internal pure returns (uint256) {
        if (lockupPeriod == LockupPeriod.THIRTY_DAYS) return 30 days;
        if (lockupPeriod == LockupPeriod.SIXTY_DAYS) return 60 days;
        if (lockupPeriod == LockupPeriod.NINETY_DAYS) return 90 days;
        revert InvalidLockupPeriod();
    }

    function _multiplier(LockupPeriod tier) internal pure returns (uint256) {
        if (tier == LockupPeriod.THIRTY_DAYS) return 1e18;
        if (tier == LockupPeriod.SIXTY_DAYS) return 15e17;
        if (tier == LockupPeriod.NINETY_DAYS) return 2e18;
        revert InvalidLockupPeriod();
    }

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

    //my idea to make it such that users always have skin in the game by making sure that if a user seeks to withdraw >= 50% of principal, they must have an equivalent percentage of rewards immediately added to withdrawn falls apart, as said user could just reinvest the withdrawn rewards and a circular redundant path is created...
}
