//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "src/Interfaces/IVaultManager.sol";
import "src/Interfaces/IDexRouter.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title BondManager - Quest Protocol Partnerships
/// @author Quest Team
/// @notice Manages protocol partnerships, capital deployment via bonds, vesting, and profit extraction
/// @dev Implements bond lifecycle: register → create → vest → claim → sell → return capital.
/// Profits are extracted from token appreciation and sent to RewardPool for user distribution.
contract BondManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    IERC20 public usdc;

    // ============ EVENTS ============

    event VaultAddressUpdate(address oldVault, address vault);
    event BondCreated(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 protocolId,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 tier,
        uint256 vestingDays
    );
    event TokensClaimed(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 protocolId,
        uint256 amountClaimed,
        uint256 totalClaimed,
        uint256 tier,
        uint256 vestingDays
    );
    event TokensSold(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 protocolId,
        uint256 tokenAmount,
        uint256 totalSold,
        uint256 usdcReceived,
        uint256 tier,
        uint256 vestingDays
    );
    event BondExited(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 protocolId,
        uint256 totalUsdcReturned
    );
    event ProtocolRegistered(
        uint256 indexed protocolId,
        address indexed protocol,
        ProtocolType protocolType
    );
    event ProtocolDeRegistered(
        uint256 indexed protocolId,
        address indexed protocol,
        ProtocolType protocolType
    );

    // ============ ENUMS ============

    /// @notice Protocol classification for discount tier validation
    enum ProtocolType {
        LENDING,    // 0: Borrowing protocols (Aave, Compound)
        STAKING,    // 1: Staking platforms (Lido, Rocket)
        YIELD,      // 2: Yield farms (PancakeSwap, Uniswap)
        LAUNCHPAD   // 3: Token launches (IDO platforms)
    }

    // ============ STRUCTS ============

    /// @notice Complete bond lifecycle data
    /// @dev Tracks deployment, vesting, claims, and sales for profit calculation
    struct Bond {
        uint256 bondId;                // Unique bond identifier
        address protocol;              // Protocol address (counterparty)
        uint256 protocolId;            // Protocol registry ID
        ProtocolType protocolType;     // Protocol classification
        address protocolToken;         // Token protocol will provide
        uint256 usdcProvided;          // USDC capital sent to protocol
        uint64 discount;               // Discount percentage applied (e.g., 2000 = 20%)
        uint256 tokenAmount;           // Total tokens protocol will provide
        uint256 tokensClaimed;         // Tokens claimed from protocol so far
        uint256 tokensProcessed;       // Tokens sold/processed so far
        uint8 tier;                    // Lockup tier (0=30d, 1=60d, 2=90d)
        uint256 startTime;             // Bond creation timestamp
        uint256 endTime;               // Vesting end timestamp
        uint256 vestingDays;           // Vesting duration
        bool active;                   // Bond lifecycle status
    }

    /// @notice Protocol metadata
    struct Protocol {
        address protocol;              // Protocol address
        ProtocolType protocolType;     // Protocol type
    }

    // ============ ERRORS ============

    error ZeroAddress();
    error InvalidProtocol();
    error InvalidProtocolType();
    error ProtocolExists();
    error InactiveProtocol();
    error InvalidTier();
    error InvalidBond();
    error InvalidConditions();

    // ============ STATE VARIABLES ============

    /// @notice Protocol address → protocol ID mapping (registry)
    mapping(address protocol => uint256 protocolId) public protocolRegistry;

    /// @notice Protocol ID → protocol type
    mapping(uint256 protocolId => ProtocolType) public protocolType;

    /// @notice Protocol ID → active status
    mapping(uint256 protocolId => bool isActive) public protocolActive;

    /// @notice Protocol ID → array of bond IDs
    mapping(uint256 protocolId => uint256[] bondIds) public protocolBonds;

    /// @notice Bond ID → bond struct
    mapping(uint256 bondId => Bond) public bonds;

    /// @notice Minimum discount percentage required for each tier (bps, e.g., 2000 = 20%)
    mapping(uint8 tier => uint256 minDiscount) public minDiscountPerTier;

    /// @notice Current USDC deployed per protocol (for concentration limits)
    mapping(uint256 protocolId => uint256) public currentDeployedByProtocol;

    /// @notice Vault reference (for capital queries and deployment tracking)
    IVaultManager public vault;

    /// @notice DEX router for token swaps (Uniswap/PancakeSwap interface)
    IDexRouter public dexRouter;

    /// @notice Auto-incrementing bond ID counter
    uint256 public bondCounter;

    /// @notice Auto-incrementing protocol ID counter
    uint256 public protocolCounter;

    /// @notice Total USDC deployed across all bonds (audit trail)
    uint256 public totalUsdcDeployed;

    /// @notice Total USDC returned from completed bonds (audit trail)
    uint256 public totalUsdcReturned;

    /// @notice Maximum % of available tier capacity per protocol (default 25%)
    /// @dev Prevents single protocol from monopolizing a tier
    uint256 public maxBondTvlPercent = 25;

    /// @notice Global minimum discount across all tiers (20%)
    uint256 public minDiscount = 2000;

    // ============ INITIALIZATION ============

    /// @notice Initialize BondManager with vault, DEX, and token references
    /// @dev Sets up tier-specific discount minimums: 30%, 25%, 20% respectively
    /// @param initialOwner Owner address (can create/manage bonds)
    /// @param _vault IVaultManager contract (QVToken) for capital queries
    /// @param _dexRouter DEX router contract for token swaps
    /// @param _usdc USDC token contract address
    /// @custom:precondition All addresses must be non-zero
    function initialize(
        address initialOwner,
        IVaultManager _vault,
        address _dexRouter,
        address _usdc
    ) external initializer {
        if (
            initialOwner == address(0) ||
            address(_vault) == address(0) ||
            _usdc == address(0)
        ) {
            revert ZeroAddress();
        }

        __Ownable_init(initialOwner);
        __Pausable_init();

        usdc = IERC20(_usdc);
        vault = _vault;
        dexRouter = IDexRouter(_dexRouter);

        minDiscountPerTier[0] = 3000; // 30 days: 30% min discount
        minDiscountPerTier[1] = 2500; // 60 days: 25% min discount
        minDiscountPerTier[2] = 2000; // 90 days: 20% min discount
    }

    // ============ VAULT MANAGEMENT ============

    /// @notice Update vault reference (admin only)
    /// @param _newVault New IVaultManager address
    function setVault(IVaultManager _newVault) external onlyOwner {
        if (address(_newVault) == address(0)) revert ZeroAddress();
        address oldVault = address(vault);
        vault = _newVault;
        emit VaultAddressUpdate(oldVault, address(_newVault));
    }

    // ============ PROTOCOL REGISTRATION ============

    /// @notice Register new protocol as partnership candidate (admin only)
    /// @dev Whitelists protocol for bond creation
    /// @param protocol Protocol address
    /// @param _protocolType Classification (LENDING, STAKING, YIELD, LAUNCHPAD)
    /// @custom:precondition Protocol must not already be registered
    /// @custom:postcondition Protocol is whitelisted and active
    function registerProtocol(
        address protocol,
        ProtocolType _protocolType
    ) external onlyOwner {
        if (address(protocol) == address(0)) revert ZeroAddress();
        if (protocolRegistry[protocol] != 0) revert ProtocolExists();

        _registerProtocolInternal(protocol, _protocolType);
        emit ProtocolRegistered(
            protocolRegistry[protocol],
            protocol,
            _protocolType
        );
    }

    /// @notice Internal protocol registration logic
    function _registerProtocolInternal(
        address protocol,
        ProtocolType _protocolType
    ) internal {
        uint256 newProtocolId = ++protocolCounter;
        protocolRegistry[protocol] = newProtocolId;
        protocolType[newProtocolId] = _protocolType;
        protocolActive[newProtocolId] = true;
    }

    /// @notice Internal protocol deregistration logic
    function _deRegisterProtocol(
        address protocol,
        ProtocolType _protocolType
    ) internal {
        if (address(protocol) == address(0)) revert ZeroAddress();
        uint256 protocolId = protocolRegistry[protocol];
        protocolActive[protocolId] = false;

        emit ProtocolDeRegistered(
            protocolRegistry[protocol],
            protocol,
            _protocolType
        );
    }

    /// @notice Deregister protocol (remove from partnerships) (admin only)
    /// @param protocol Protocol address to deregister
    function deregisterProtocol(address protocol) external onlyOwner {
        if (address(protocol) == address(0)) revert ZeroAddress();
        if (protocolRegistry[protocol] == 0) revert InvalidProtocol();

        uint256 protocolId = protocolRegistry[protocol];
        ProtocolType pType = protocolType[protocolId];
        _deRegisterProtocol(protocol, pType);
    }

    // ============ BOND LIFECYCLE ============

    /// @notice Create bond with protocol: deploy capital, start vesting
    /// @dev Uses CHECKS-EFFECTS-INTERACTIONS pattern:
    /// 1. Validate all conditions (discount, tier, capacity)
    /// 2. Create bond record and update state
    /// 3. Transfer USDC and update vault deployment tracking
    /// @param protocol Protocol address (auto-registers if not already)
    /// @param protocolToken Token that protocol will provide
    /// @param usdcAmount USDC to deploy (6 decimals)
    /// @param tokenAmount Total tokens protocol will provide
    /// @param tier Lockup tier: 0=30d (30% disc), 1=60d (25%), 2=90d (20%)
    /// @param discount Discount percentage in bps (2000 = 20%)
    /// @param vestingDays Vesting duration (30/60/90 required)
    /// @param protocolType_ Protocol type (for auto-registration only)
    /// @custom:precondition discount >= minDiscountPerTier[tier]
    /// @custom:precondition vestingDays must be 30, 60, or 90
    /// @custom:precondition Available tier capacity >= usdcAmount
    /// @custom:precondition currentDeployed[protocol] + usdcAmount <= maxPerProtocol
    /// @custom:postcondition Bond created with startTime=now, endTime=now+vestingDays*1day
    /// @custom:postcondition USDC transferred from vault to protocol
    /// @custom:postcondition totalDeployedByTier[tier] increases by usdcAmount
    function createBond(
        address protocol,
        address protocolToken,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint8 tier,
        uint64 discount,
        uint256 vestingDays,
        ProtocolType protocolType_
    ) external onlyOwner nonReentrant {
        // CHECKS (all validation upfront)
        if (address(protocol) == address(0)) revert ZeroAddress();
        if (address(protocolToken) == address(0)) revert ZeroAddress();
        if (usdcAmount == 0 || tokenAmount == 0) revert InvalidConditions();
        if (discount < minDiscountPerTier[tier]) revert InvalidConditions();
        if (vestingDays < 30) revert InvalidConditions();

        // Auto-register protocol if not already registered
        if (protocolRegistry[protocol] == 0) {
            _registerProtocolInternal(protocol, protocolType_);
        }

        uint256 protocolId = protocolRegistry[protocol];
        if (!protocolActive[protocolId]) revert InactiveProtocol();

        uint8 computedTier = _vestingDaysToTier(vestingDays);
        if (computedTier != tier) revert InvalidTier();

        // Query vault for available capacity (before state changes)
        uint256 availableInTier = vault.getProtocolAvailableByTier(tier);
        uint256 maxPerProtocol = (availableInTier * maxBondTvlPercent) / 100;

        // Check per-protocol cap (overall counterparty concentration)
        if (
            currentDeployedByProtocol[protocolId] + usdcAmount > maxPerProtocol
        ) {
            revert InvalidConditions();
        }

        // ========== EFFECTS (modify THIS contract state) ==========
        uint256 newBondId = ++bondCounter;

        Bond memory newBond = Bond({
            bondId: newBondId,
            protocol: protocol,
            protocolId: protocolId,
            protocolType: protocolType[protocolId],
            protocolToken: protocolToken,
            usdcProvided: usdcAmount,
            tokenAmount: uint256(tokenAmount),
            discount: discount,
            tokensClaimed: 0,
            tokensProcessed: 0,
            tier: computedTier,
            startTime: block.timestamp,
            endTime: block.timestamp + (vestingDays * 1 days),
            vestingDays: vestingDays,
            active: true
        });

        // Store bond before any external calls
        bonds[newBondId] = newBond;
        protocolBonds[protocolId].push(newBondId);
        currentDeployedByProtocol[protocolId] += usdcAmount;
        totalUsdcDeployed += usdcAmount;

        // ========== INTERACTIONS (external calls) ==========
        vault.lendUSDC(protocol, usdcAmount);

        // Update vault state after transfer succeeds
        vault.markDeployed(tier, usdcAmount);

        // ========== EVENT ==========
        emit BondCreated(
            newBondId,
            protocol,
            protocolId,
            usdcAmount,
            tokenAmount,
            tier,
            vestingDays
        );
    }

    /// @notice Convert vesting days to tier index
    /// @param vestingDays Number of days (must be 30, 60, or 90)
    /// @return Tier index: 0=30d, 1=60d, 2=90d
    function _vestingDaysToTier(
        uint256 vestingDays
    ) internal pure returns (uint8) {
        if (vestingDays == 30) return 0;
        if (vestingDays == 60) return 1;
        if (vestingDays == 90) return 2;
        revert InvalidTier();
    }

    // ============ BOND QUERIES ============

    /// @notice Query complete bond data
    /// @param bondId Bond ID to query
    /// @return Bond struct with all lifecycle data
    function getBondData(uint256 bondId) external view returns (Bond memory) {
        return bonds[bondId];
    }

    /// @notice Query all bond IDs for a protocol
    /// @param protocol Protocol address
    /// @return Array of bond IDs where protocol is counterparty
    function getProtocolActiveBonds(
        address protocol
    ) external view returns (uint256[] memory) {
        if (address(protocol) == address(0)) revert ZeroAddress();
        uint256 protocolId = protocolRegistry[protocol];

        return protocolBonds[protocolId];
    }

    /// @notice Calculate amount of tokens that have vested so far (linear schedule)
    /// @dev Vesting = tokenAmount * elapsedTime / vestingPeriod
    /// @param bondId Bond ID to query
    /// @return Vested tokens (max = tokenAmount at endTime)
    function getVestedAmount(uint256 bondId) public view returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();

        uint256 elapsed = block.timestamp - bond.startTime;
        uint256 vestingPeriod = bond.vestingDays * 1 days;

        if (elapsed >= vestingPeriod) return bond.tokenAmount;
        return Math.mulDiv(bond.tokenAmount, elapsed, vestingPeriod);
    }

    /// @notice Calculate tokens available to claim (vested - already claimed)
    /// @param bondId Bond ID to query
    /// @return Claimable tokens (0 if all vested tokens already claimed)
    function getClaimableAmount(uint256 bondId) public view returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();

        uint256 claimableAmount = getVestedAmount(bondId) - bond.tokensClaimed;
        return claimableAmount;
    }

    /// @notice Query complete bond status (vesting progress, remaining time)
    /// @param bondId Bond ID to query
    /// @return vestedAmount Tokens vested so far
    /// @return claimableAmount Tokens ready to claim (not yet claimed)
    /// @return vestingPercentage Completion percentage (0-100)
    /// @return daysRemaining Days until vesting ends (0 if ended)
    function getBondStatus(
        uint256 bondId
    )
        external
        view
        returns (
            uint256 vestedAmount,
            uint256 claimableAmount,
            uint256 vestingPercentage,
            uint256 daysRemaining
        )
    {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();

        vestedAmount = getVestedAmount(bondId);
        claimableAmount = getClaimableAmount(bondId);

        uint256 vestingPeriod = bond.vestingDays * 1 days;
        uint256 elapsed = block.timestamp - bond.startTime;

        vestingPercentage = elapsed >= vestingPeriod
            ? 100
            : Math.mulDiv(elapsed, 100, vestingPeriod);

        daysRemaining = block.timestamp >= bond.endTime
            ? 0
            : (bond.endTime - block.timestamp) / 1 days;
    }

    // ============ TOKEN CLAIMING ============

    /// @notice Claim vested tokens from protocol (admin only)
    /// @dev Transfers tokens FROM protocol TO this contract
    /// @param bondId Bond ID to claim from
    /// @param amount Tokens to claim (must be <= getClaimableAmount)
    /// @return amount Tokens claimed
    /// @custom:postcondition tokensClaimed increases by amount
    function claimBond(
        uint256 bondId,
        uint256 amount
    ) external onlyOwner nonReentrant returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();
        if (amount == 0) revert InvalidConditions();

        uint256 claimableAmount = getClaimableAmount(bondId);
        if (amount > claimableAmount) revert InvalidConditions();

        bond.tokensClaimed += amount;

        IERC20(bond.protocolToken).safeTransferFrom(
            bond.protocol,
            address(this),
            amount
        );

        emit TokensClaimed(
            bondId,
            bond.protocol,
            bond.protocolId,
            amount,
            bond.tokensClaimed,
            bond.tier,
            bond.vestingDays
        );

        return amount;
    }

    // ============ PROFIT EXTRACTION ============

    /// @notice Set maximum % of tier capacity per protocol (admin only)
    /// @param newPercent Percentage (0-100, default 25%)
    function setMaxBondTvlPercent(uint256 newPercent) public onlyOwner {
        if (newPercent == 0 || newPercent > 100) revert InvalidConditions();
        maxBondTvlPercent = newPercent;
    }

    /// @notice Sell claimed tokens on DEX for profit, route to RewardPool
    /// @dev Calculates profit = salePrice - (costBasis * amountSold).
    /// If all tokens are sold, marks bond as inactive and returns capital to vault.
    /// @param bondId Bond ID to sell tokens from
    /// @param amount Tokens to sell (must be <= tokensProcessed - already sold)
    /// @param minUsdcOut Minimum USDC expected from swap (slippage protection)
    /// @param rewardPool RewardPool address (receives profit)
    /// @return usdcReceived USDC received from sale
    /// @return profit Profit extracted (salePrice - costBasis)
    /// @custom:precondition amount <= getClaimableAmount (claimed but not yet sold)
    /// @custom:precondition rewardPool must be non-zero
    /// @custom:postcondition If all tokens sold: bond marked inactive, markReturned called
    /// @custom:postcondition Profit transferred to rewardPool
    function sellBondTokens(
        uint256 bondId,
        uint256 amount,
        uint256 minUsdcOut,
        address rewardPool
    )
        external
        onlyOwner
        nonReentrant
        returns (uint256 usdcReceived, uint256 profit)
    {
        // CHECKS
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();
        if (amount == 0) revert InvalidConditions();
        if (rewardPool == address(0)) revert ZeroAddress();

        // amount must not exceed claimed but unprocessed tokens
        uint256 availableToSell = bond.tokensClaimed - bond.tokensProcessed;
        if (amount > availableToSell) revert InvalidConditions();

        // EFFECTS
        bond.tokensProcessed += amount;

        // Mark bond inactive if fully processed
        if (bond.tokensProcessed == bond.tokenAmount) {
            bond.active = false;
            currentDeployedByProtocol[bond.protocolId] -= bond.usdcProvided;
            totalUsdcReturned += bond.usdcProvided;
            vault.markReturned(bond.tier, bond.usdcProvided);
        }

        // INTERACTIONS - approve router and swap
        IERC20(bond.protocolToken).safeIncreaseAllowance(
            address(dexRouter),
            amount
        );

        address[] memory path = new address[](2);
        path[0] = bond.protocolToken;
        path[1] = address(usdc);

        uint256[] memory amounts = dexRouter.swapExactTokensForTokens(
            amount,
            minUsdcOut,
            path,
            address(this),
            block.timestamp + 300
        );

        usdcReceived = amounts[amounts.length - 1];

        // PROFIT CALCULATION
        // cost basis per token = bond.usdcProvided / bond.tokenAmount
        // cost of tokens sold = amount * costBasisPerToken
        // profit = usdcReceived - costOfTokensSold
        // use Math.mulDiv to avoid overflow
        uint256 costOfTokensSold = Math.mulDiv(
            bond.usdcProvided,
            amount,
            bond.tokenAmount
        );
        profit = usdcReceived > costOfTokensSold
            ? usdcReceived - costOfTokensSold
            : 0;

        // Send profit to RewardPool for user distribution
        if (profit > 0) {
            usdc.safeTransfer(rewardPool, profit);
        }

        emit TokensSold(
            bondId,
            bond.protocol,
            bond.protocolId,
            amount,
            bond.tokensProcessed,
            usdcReceived,
            bond.tier,
            bond.vestingDays
        );
    }

    // ============ EMERGENCY EXIT ============

    /// @notice Emergency exit from bond: recover vested but unclaimed tokens (admin only)
    /// @dev Does NOT force sell tokens. Owner must call sellBondTokens separately if desired.
    /// Marks bond as inactive and returns capital to vault.
    /// @param bondId Bond ID to exit
    /// @param minUsdcOut Unused (for compatibility)
    /// @param rewardPool RewardPool address (for compatibility)
    /// @custom:postcondition Bond marked inactive
    /// @custom:postcondition markReturned called to update vault
    /// @custom:postcondition Vested but unclaimed tokens recovered to this contract
    function emergencyExitBond(uint256 bondId, uint256 minUsdcOut, address rewardPool) external onlyOwner nonReentrant {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();
        if (rewardPool == address(0)) revert ZeroAddress();
        
        // Only recover tokens that HAVE VESTED but haven't been CLAIMED
        uint256 vestedAmount = getVestedAmount(bondId);
        uint256 unclaimedVested = vestedAmount - bond.tokensClaimed;
        bond.tokensClaimed += unclaimedVested;
    
        bond.active = false;
        
        if (unclaimedVested > 0) {
            IERC20(bond.protocolToken).safeTransferFrom(
                bond.protocol,
                address(this),
                unclaimedVested
            );
        }
        
        // Update deployment tracking (protocol no longer owes USDC interest)
        currentDeployedByProtocol[bond.protocolId] -= bond.usdcProvided;
        vault.markReturned(bond.tier, bond.usdcProvided);
    
        emit BondExited(
            bond.bondId,
            bond.protocol,
            bond.protocolId,
            bond.usdcProvided
        );
    }
}
