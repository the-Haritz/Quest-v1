//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

/// @title BondManager
/// @notice Manages protocol partnerships through bonds: capital deployment, vesting, and profit extraction
/// @dev Core contract for Quest Protocol V1 MVP. Orchestrates capital deployment to external protocols,
///      token vesting schedules, and profit recovery through token swaps on DEX.
///
///      Bond Lifecycle:
///      1. Protocol Registration: Owner registers protocol with type (LENDING/STAKING/YIELD/LAUNCHPAD)
///      2. Bond Creation: Deploy USDC to protocol, receive vesting tokens in return (30/60/90 day vesting)
///      3. Token Claiming: As tokens vest linearly, claim from protocol (pull tokens in)
///      4. Profit Extraction: Swap claimed tokens on DEX for USDC, extract profit to RewardPool
///      5. Bond Completion: When all tokens claimed+processed, mark inactive and release capital
///      6. Emergency Exit: If protocol goes dark, emergency exit releases capital without full recovery
///
///      Capital Deployment Model:
///      - Vault tracks available USDC per tier (totalLockedByTier - totalDeployedByTier)
///      - BondManager deploys capital from available pool via vault.lendUSDC()
///      - Marks deployment via vault.markDeployed(tier, amount) to reduce available capacity
///      - Returns capital via vault.markReturned(tier, amount) when bond completes
///      - Per-protocol concentration limit: max 25% of tier capacity to single protocol
///
///      Profit Extraction:
///      - Cost basis per token = usdcProvided / tokenAmount
///      - Profit = usdcReceived - (costBasis * tokenAmount)
///      - Example: Deploy 1000 USDC at 20% discount, get 1000 tokens valued at 1250.
///        Sell for 1200 USDC = 200 USDC profit routed to RewardPool for distribution.
///
///      Design Patterns:
///      - CHECKS-EFFECTS-INTERACTIONS: Validate → Update state → External calls
///      - Reentrancy Guards: nonReentrant on all state-changing functions
///      - Access Control: onlyOwner for all critical operations
contract BondManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    
    //============================================================================
    // STATE VARIABLES
    //============================================================================
    
    /// @notice USDC token (6 decimals) used for deployments and profit swaps
    IERC20 public usdc;
    
    /// @notice VaultManager interface for capacity queries and deployment tracking
    IVaultManager public vault;
    
    /// @notice DEX router interface (Uniswap/PancakeSwap compatible) for token→USDC swaps
    IDexRouter public dexRouter;
    
    //============================================================================
    // PROTOCOL REGISTRY
    //============================================================================
    
    /// @notice Maps protocol address → unique protocol ID (assigned during registration)
    mapping(address protocol => uint256 protocolId) public protocolRegistry;
    
    /// @notice Maps protocol ID → protocol type (LENDING/STAKING/YIELD/LAUNCHPAD)
    mapping(uint256 protocolId => ProtocolType) public protocolType;
    
    /// @notice Maps protocol ID → active flag (true=can create bonds, false=deregistered)
    mapping(uint256 protocolId => bool isActive) public protocolActive;
    
    /// @notice Maps protocol ID → array of all bond IDs associated with protocol
    mapping(uint256 protocolId => uint256[] bondIds) public protocolBonds;
    
    //============================================================================
    // BOND STATE
    //============================================================================
    
    /// @notice Maps bond ID → complete bond state (deployment, vesting, claims)
    mapping(uint256 bondId => Bond) public bonds;
    
    /// @notice Maps tier (0/1/2) → minimum discount percentage required for that tier
    /// @dev Tier 0 (30d): 30% min, Tier 1 (60d): 25% min, Tier 2 (90d): 20% min
    mapping(uint8 tier => uint256 minDiscount) public minDiscountPerTier;
    
    /// @notice Maps protocol ID → current USDC deployed in active bonds
    /// @dev Used to enforce per-protocol concentration limits (max 25% of tier capacity)
    mapping(uint256 protocolId => uint256) public currentDeployedByProtocol;
    
    //============================================================================
    // METRICS & CONFIG
    //============================================================================
    
    /// @notice Auto-incrementing bond ID counter (starts from 1)
    uint256 public bondCounter;
    
    /// @notice Auto-incrementing protocol ID counter (starts from 1)
    uint256 public protocolCounter;
    
    /// @notice Cumulative USDC deployed across all bonds (lifetime metric)
    uint256 public totalUsdcDeployed;
    
    /// @notice Cumulative USDC returned when bonds completed or exited (lifetime metric)
    uint256 public totalUsdcReturned;
    
    /// @notice Maximum deployment per protocol as % of available tier capacity (default 25%)
    /// @dev Example: If tier has 10k USDC available, max per protocol = 2.5k USDC
    uint256 public maxBondTvlPercent = 25;
    
    /// @notice Fallback minimum discount (unused, tier-based minimums take precedence)
    uint256 public minDiscount = 2000;

    //============================================================================
    // ENUMS & STRUCTS
    //============================================================================
    
    /// @notice Protocol category for classification and risk management
    enum ProtocolType {
        LENDING,    // Lending protocols (Aave, Compound, etc)
        STAKING,    // Staking protocols (Lido, Rocket Pool, etc)
        YIELD,      // Yield farming (Curve, Balancer, etc)
        LAUNCHPAD   // Token launch/IDO platforms
    }

    /// @notice Complete bond state: deployment, vesting, claims, and lifecycle
    /// @dev Lifecycle: ACTIVE (on create) → INACTIVE (when fully processed or emergency exited)
    ///      State transitions:
    ///      - Created: tokensClaimed=0, tokensProcessed=0, active=true
    ///      - After claimBond(): tokensClaimed increases
    ///      - After sellBondTokens(): tokensProcessed increases
    ///      - When tokensProcessed==tokenAmount: active=false (bond complete)
    ///      - Emergency exit: active=false (capital released, tokens recoverable)
    struct Bond {
        /// @notice Unique bond identifier (auto-incrementing from 1)
        uint256 bondId;
        
        /// @notice Protocol contract receiving USDC deployment
        address protocol;
        
        /// @notice Internal protocol registry ID
        uint256 protocolId;
        
        /// @notice Cached protocol type for efficient event emitting
        ProtocolType protocolType;
        
        /// @notice Protocol's native ERC20 token being vested to us
        address protocolToken;
        
        /// @notice USDC deployed to protocol (6 decimals, fixed at creation)
        uint256 usdcProvided;
        
        /// @notice Discount applied at creation (e.g., 3000 = 30%)
        uint64 discount;
        
        /// @notice Total protocol tokens received during full vesting (fixed at creation)
        uint256 tokenAmount;
        
        /// @notice Protocol tokens claimed so far (increments via claimBond)
        uint256 tokensClaimed;
        
        /// @notice Protocol tokens swapped for USDC (increments via sellBondTokens)
        uint256 tokensProcessed;
        
        /// @notice Lockup tier: 0=30d, 1=60d, 2=90d (tier→discount mapping)
        uint8 tier;
        
        /// @notice Timestamp bond created (vesting start)
        uint256 startTime;
        
        /// @notice Timestamp vesting completes (startTime + vestingDays * 1 days)
        uint256 endTime;
        
        /// @notice Total vesting period in days (30, 60, or 90 only)
        uint256 vestingDays;
        
        /// @notice Bond active status: true=deployed capital tracked, false=capital released
        bool active;
    }
    
    /// @notice Protocol registration record
    struct Protocol {
        /// @notice Protocol contract address
        address protocol;
        
        /// @notice Protocol category (LENDING/STAKING/YIELD/LAUNCHPAD)
        ProtocolType protocolType;
    }

    //============================================================================
    // ERRORS
    //============================================================================
    
    error ZeroAddress();
    error InvalidProtocol();
    error InvalidProtocolType();
    error ProtocolExists();
    error InactiveProtocol();
    error InvalidTier();
    error InvalidBond();
    error InvalidConditions();

    //============================================================================
    // EVENTS
    //============================================================================

    /// @notice Emitted when vault address updated (typically never, used for migration)
    /// @param oldVault Previous vault address
    /// @param vault New vault address
    event VaultAddressUpdate(address indexed oldVault, address indexed vault);
    
    /// @notice Emitted when bond created (capital deployed to protocol)
    /// @param bondId Unique bond identifier
    /// @param protocol Protocol receiving deployment
    /// @param protocolId Internal protocol registry ID
    /// @param usdcAmount USDC deployed (6 decimals)
    /// @param tokenAmount Protocol tokens to vest over period
    /// @param tier Lockup tier (0=30d, 1=60d, 2=90d)
    /// @param vestingDays Total vesting period in days
    event BondCreated(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 indexed protocolId,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 tier,
        uint256 vestingDays
    );
    
    /// @notice Emitted when protocol tokens claimed from protocol during vesting
    /// @param bondId Bond being claimed
    /// @param protocol Protocol address
    /// @param protocolId Internal protocol ID
    /// @param amountClaimed Amount of tokens claimed in this transaction
    /// @param totalClaimed Cumulative tokens claimed across all claims for this bond
    /// @param tier Lockup tier
    /// @param vestingDays Vesting period
    event TokensClaimed(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 indexed protocolId,
        uint256 amountClaimed,
        uint256 totalClaimed,
        uint256 tier,
        uint256 vestingDays
    );
    
    /// @notice Emitted when claimed tokens swapped for USDC via DEX, profit extracted
    /// @param bondId Bond tokens sold
    /// @param protocol Protocol address
    /// @param protocolId Internal protocol ID
    /// @param tokenAmount Protocol tokens swapped in this transaction
    /// @param totalSold Cumulative tokens processed (claimed and swapped) for this bond
    /// @param usdcReceived USDC obtained from DEX swap
    /// @param tier Lockup tier
    /// @param vestingDays Vesting period
    event TokensSold(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 indexed protocolId,
        uint256 tokenAmount,
        uint256 totalSold,
        uint256 usdcReceived,
        uint256 tier,
        uint256 vestingDays
    );
    
    /// @notice Emitted when bond emergency exited (marked inactive, deployment released)
    /// @param bondId Bond exited
    /// @param protocol Protocol address
    /// @param protocolId Internal protocol ID
    /// @param totalUsdcReturned USDC marked as returned (released from deployed tracking)
    event BondExited(
        uint256 indexed bondId,
        address indexed protocol,
        uint256 indexed protocolId,
        uint256 totalUsdcReturned
    );
    
    /// @notice Emitted when new protocol registered and activated
    /// @param protocolId Internal protocol ID assigned
    /// @param protocol Protocol address
    /// @param protocolType Category of protocol
    event ProtocolRegistered(
        uint256 indexed protocolId,
        address indexed protocol,
        ProtocolType indexed protocolType
    );
    
    /// @notice Emitted when protocol deactivated (no new bonds allowed)
    /// @param protocolId Internal protocol ID
    /// @param protocol Protocol address
    /// @param protocolType Protocol category
    event ProtocolDeRegistered(
        uint256 indexed protocolId,
        address indexed protocol,
        ProtocolType indexed protocolType
    );

    //============================================================================
    // INITIALIZATION
    //============================================================================

    /// @notice Initialize BondManager with vault, DEX router, and USDC references
    /// @dev Sets up tier-based minimum discount requirements and prepares for bond operations
    /// @param initialOwner Address with owner privileges (bonds, protocols, config)
    /// @param _vault IVaultManager for capacity queries, deployment tracking, USDC transfers
    /// @param _dexRouter IDexRouter (Uniswap/PancakeSwap compatible) for token→USDC swaps
    /// @param _usdc USDC token address (6 decimals, stable coin)
    /// @custom:precondition All addresses must be non-zero
    /// @custom:postcondition Tier minimums set (30d=30%, 60d=25%, 90d=20%), ready for operations
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

    //============================================================================
    // VAULT MANAGEMENT
    //============================================================================

    /// @notice Update vault reference (typically for migration, rarely called)
    /// @dev Can update to new vault without redeployment
    /// @param _newVault New vault address
    /// @custom:precondition _newVault must be non-zero
    /// @custom:postcondition Vault reference updated, VaultAddressUpdate event emitted
    function setVault(IVaultManager _newVault) external onlyOwner {
        if (address(_newVault) == address(0)) revert ZeroAddress();
        address oldVault = address(vault);
        vault = _newVault;
        emit VaultAddressUpdate(oldVault, address(_newVault));
    }

    //============================================================================
    // PROTOCOL MANAGEMENT
    //============================================================================

    /// @notice Register new protocol for capital deployment partnerships
    /// @dev Protocol immediately activated; can be deregistered later.
    ///      Auto-registration also occurs during createBond() for convenience.
    /// @param protocol Protocol contract address
    /// @param _protocolType Protocol category (LENDING/STAKING/YIELD/LAUNCHPAD)
    /// @custom:precondition protocol must be non-zero; not already registered
    /// @custom:postcondition Protocol ID assigned and activated, ProtocolRegistered emitted
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

    /// @notice Internal helper to register protocol and assign auto-incrementing ID
    /// @dev Called by registerProtocol() and createBond() (auto-register)
    /// @param protocol Protocol address
    /// @param _protocolType Protocol category
    /// @custom:postcondition protocolRegistry, protocolType, protocolActive updated
    function _registerProtocolInternal(
        address protocol,
        ProtocolType _protocolType
    ) internal {
        uint256 newProtocolId = ++protocolCounter;
        protocolRegistry[protocol] = newProtocolId;
        protocolType[newProtocolId] = _protocolType;
        protocolActive[newProtocolId] = true;
    }

    /// @notice Deactivate protocol (prevents new bonds, existing bonds unaffected)
    /// @dev Sets active flag false; existing bonds still tracked but no new bonds allowed
    /// @param protocol Protocol address
    /// @param _protocolType Protocol category (for event)
    /// @custom:postcondition protocolActive set to false, ProtocolDeRegistered emitted
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

    /// @notice Deregister active protocol
    /// @dev Prevents new bonds with this protocol; existing bonds track state normally
    /// @param protocol Protocol address
    /// @custom:precondition protocol must be registered
    /// @custom:postcondition Protocol marked inactive
    function deregisterProtocol(address protocol) external onlyOwner {
        if (address(protocol) == address(0)) revert ZeroAddress();
        if (protocolRegistry[protocol] == 0) revert InvalidProtocol();

        uint256 protocolId = protocolRegistry[protocol];
        ProtocolType pType = protocolType[protocolId];
        _deRegisterProtocol(protocol, pType);
    }

    //============================================================================
    // BOND CREATION & DEPLOYMENT
    //============================================================================

    /// @notice Create bond: deploy USDC to protocol, receive vesting tokens in return
    /// @dev Implements CHECKS-EFFECTS-INTERACTIONS pattern for safety:
    ///      1. CHECKS: Validate tier, discount, capacity constraints upfront
    ///      2. EFFECTS: Update bond storage, deployment tracking, counters
    ///      3. INTERACTIONS: Execute vault transfers and state updates
    ///      Ensures state consistency even if external calls fail
    ///
    ///      Vesting: Linear over vestingDays (30/60/90 only). Tier→discount mapping:
    ///      - 30 days (tier 0): 30% discount minimum
    ///      - 60 days (tier 1): 25% discount minimum
    ///      - 90 days (tier 2): 20% discount minimum
    ///
    ///      Capacity & Concentration:
    ///      - Queries availableTierCapacity from vault
    ///      - Per-protocol limit = availableCapacity * maxBondTvlPercent / 100
    ///      - Default maxBondTvlPercent=25%, so max 25% of tier capacity to single protocol
    ///      - Prevents counterparty concentration risk
    ///
    /// @param protocol Protocol receiving USDC (auto-registered if not exists)
    /// @param protocolToken ERC20 token protocol vests to us
    /// @param usdcAmount USDC to deploy (6 decimals)
    /// @param tokenAmount Total protocol tokens to vest
    /// @param tier Lockup tier (0=30d, 1=60d, 2=90d) must match vestingDays
    /// @param discount Discount applied (e.g., 3000=30%, must meet tier minimum)
    /// @param vestingDays Total days until fully vested (30, 60, or 90 only)
    /// @param protocolType_ Protocol category if new registration needed
    ///
    /// @custom:important Bond created with ID=bondCounter; BondCreated event emitted
    ///
    /// @custom:precondition protocol and protocolToken must be non-zero
    /// @custom:precondition usdcAmount and tokenAmount > 0
    /// @custom:precondition discount >= minDiscountPerTier[tier]
    /// @custom:precondition vestingDays in {30, 60, 90} and matches tier
    /// @custom:precondition availableInTier >= usdcAmount (vault capacity check)
    /// @custom:precondition currentDeployedByProtocol[id] + usdcAmount <= maxPerProtocol
    /// @custom:postcondition Bond created marked active; vault.markDeployed called
    /// @custom:postcondition totalUsdcDeployed and currentDeployedByProtocol incremented
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

    //============================================================================
    // HELPERS & QUERIES
    //============================================================================

    /// @notice Convert vesting days to tier index
    /// @dev Only accepts 30, 60, 90 days (no arbitrary values)
    /// @param vestingDays Vesting period in days
    /// @return tier Tier index: 0=30d, 1=60d, 2=90d
    function _vestingDaysToTier(
        uint256 vestingDays
    ) internal pure returns (uint8) {
        if (vestingDays == 30) return 0;
        if (vestingDays == 60) return 1;
        if (vestingDays == 90) return 2;
        revert InvalidTier();
    }

    /// @notice Fetch complete bond details
    /// @param bondId Bond ID
    /// @return Bond struct with all state (deployment, vesting, claims, lifecycle)
    function getBondData(uint256 bondId) external view returns (Bond memory) {
        return bonds[bondId];
    }

    /// @notice Fetch all bond IDs for a protocol
    /// @param protocol Protocol address
    /// @return Array of bond IDs associated with protocol
    function getProtocolActiveBonds(
        address protocol
    ) external view returns (uint256[] memory) {
        if (address(protocol) == address(0)) revert ZeroAddress();
        uint256 protocolId = protocolRegistry[protocol];

        return protocolBonds[protocolId];
    }

    //============================================================================
    // VESTING & CLAIMING QUERIES
    //============================================================================

    /// @notice Query amount of tokens vested on bond at current time
    /// @dev Linear vesting: vestedAmount = tokenAmount * (now - startTime) / vestingDays
    ///      Returns full tokenAmount if vesting complete (now >= endTime)
    /// @param bondId Bond ID
    /// @return Tokens vested and eligibile to claim (may not all be claimed yet)
    /// @custom:precondition Bond must exist and be active
    function getVestedAmount(uint256 bondId) public view returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();

        uint256 elapsed = block.timestamp - bond.startTime;
        uint256 vestingPeriod = bond.vestingDays * 1 days;

        if (elapsed >= vestingPeriod) return bond.tokenAmount;
        return Math.mulDiv(bond.tokenAmount, elapsed, vestingPeriod);
    }

    /// @notice Query amount of vested tokens not yet claimed
    /// @dev Returns (vested - claimed), which is available to claim from protocol
    /// @param bondId Bond ID
    /// @return Tokens available to claim from protocol
    /// @custom:precondition Bond must exist and be active
    function getClaimableAmount(uint256 bondId) public view returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();

        uint256 claimableAmount = getVestedAmount(bondId) - bond.tokensClaimed;
        return claimableAmount;
    }

    /// @notice Get comprehensive bond status snapshot
    /// @dev Returns vesting progress, claimable amount, and time remaining
    /// @param bondId Bond ID
    /// @return vestedAmount Tokens vested so far
    /// @return claimableAmount Tokens vested but not claimed
    /// @return vestingPercentage Current vesting progress (0-100%)
    /// @return daysRemaining Days until vesting complete
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

    //============================================================================
    // TOKEN CLAIMING
    //============================================================================

    /// @notice Claim vested tokens from protocol during vesting
    /// @dev Called to pull protocol tokens into BondManager as they vest.
    ///      This is the "token reception" step. Claimed tokens can then be
    ///      swapped via sellBondTokens() to extract profit.
    ///
    /// @param bondId Bond ID
    /// @param amount Amount of tokens to claim from protocol (must be <= claimable)
    /// @return Amount actually claimed
    /// @custom:precondition amount must be <= getClaimableAmount(bondId)
    /// @custom:postcondition bond.tokensClaimed incremented, tokens transferred from protocol
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

    //============================================================================
    // PROFIT EXTRACTION & CONFIGURATION
    //============================================================================

    /// @notice Update maximum deployment per protocol as % of tier capacity
    /// @param newPercent Percentage (1-100), default 25%
    function setMaxBondTvlPercent(uint256 newPercent) public onlyOwner {
        if (newPercent == 0 || newPercent > 100) revert InvalidConditions();
        maxBondTvlPercent = newPercent;
    }

    /// @notice Sell claimed bond tokens for USDC and extract profit to RewardPool
    /// @dev Core profit extraction mechanism. Profit calculated using cost basis:
    ///      costBasisPerToken = usdcProvided / tokenAmount
    ///      costOfTokensSold = amount * costBasisPerToken
    ///      profit = usdcReceived - costOfTokensSold
    ///
    ///      Example:
    ///      - Deploy 1000 USDC at 20% discount (bond terms)
    ///      - Receive 1000 tokens (cost basis = 1 USDC per token)
    ///      - Token market price rises to 1.25 USDC (arbitrage opportunity)
    ///      - Sell 1000 tokens for 1250 USDC (if fully appreciated)
    ///      - Cost of tokens = (1000 * 1000) / 1000 = 1000 USDC
    ///      - Profit = 1250 - 1000 = 250 USDC → routed to RewardPool
    ///
    ///      Bond Lifecycle:
    ///      - When tokensProcessed == tokenAmount: mark bond inactive
    ///      - Release USDC from deployed tracking (calls vault.markReturned)
    ///      - Capital now available for new deployments or user withdrawals
    ///
    /// @param bondId Bond ID
    /// @param amount Amount of claimed tokens to swap (must be <= claimed - processed)
    /// @param minUsdcOut Slippage tolerance for DEX swap (minimum USDC expected)
    /// @param rewardPool RewardPool address to receive profit
    /// @return usdcReceived USDC obtained from DEX swap
    /// @return profit Profit extracted and routed to RewardPool (0 if no profit)
    ///
    /// @custom:precondition amount must be > 0 and <= (tokensClaimed - tokensProcessed)
    /// @custom:precondition rewardPool must be non-zero
    /// @custom:postcondition tokensProcessed incremented
    /// @custom:postcondition If fully processed: bond marked inactive, vault.markReturned called
    /// @custom:postcondition USDC transferred to rewardPool, TokensSold event emitted
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

        // Calculate profit using cost basis
        // costBasis = usdcProvided / tokenAmount (per token)
        // costOfTokensSold = amount * costBasis = (usdcProvided * amount) / tokenAmount
        // profit = usdcReceived - costOfTokensSold (0 if no profit)
        uint256 costOfTokensSold = Math.mulDiv(
            bond.usdcProvided,
            amount,
            bond.tokenAmount
        );
        profit = usdcReceived > costOfTokensSold
            ? usdcReceived - costOfTokensSold
            : 0;

        // Send profit to RewardPool
        if (profit > 0) {
            usdc.safeTransfer(rewardPool, profit);
        }

        // Send principal back to Vault
        uint256 principalReturned = usdcReceived > profit ? usdcReceived - profit : 0;
        if (principalReturned > 0) {
            usdc.safeTransfer(address(vault), principalReturned);
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
    
    //============================================================================
    // EMERGENCY OPERATIONS
    //============================================================================

    /// @notice Emergency exit bond: mark inactive and release deployment tracking
    /// @dev Used when protocol goes dark, partnership terminates, or recovery needed.
    ///      Allows claiming any vested but unclaimed tokens and releasing USDC from
    ///      deployed tracking. Tokens can be manually recovered via sellBondTokens()
    ///      or left in contract for manual recovery if profitable later.
    ///
    ///      Capital Release:
    ///      - Calls vault.markReturned() to release USDC from deployed tracking
    ///      - Makes capital available for new deployments or user withdrawals
    ///      - Does NOT increase totalUsdcReturned (not a normal completion)
    ///
    /// @param bondId Bond ID
    /// @param minUsdcOut Slippage tolerance (reserved for future token swap logic)
    /// @param rewardPool RewardPool address (reserved for future profit routing)
    /// @custom:precondition Bond must be active
    /// @custom:postcondition Bond marked inactive, deployment released, BondExited emitted
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
            
            // Owner can call sellBondTokens() separately to swap for profit
        }
        
        // Release deployment tracking (capital no longer committed)
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
