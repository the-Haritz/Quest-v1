//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "src/Interfaces/IVaultManager.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BondManager is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    IERC20 public usdc;

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

    enum ProtocolType {
        LENDING,
        STAKING,
        YIELD,
        LAUNCHPAD
    }

    struct Bond {
        uint256 bondId;
        address protocol;
        uint256 protocolId;
        ProtocolType protocolType;
        address protocolToken;
        uint256 usdcProvided;
        uint64 discount;
        uint128 tokenAmount;
        uint64 tokensClaimed;
        uint64 tokensProcessed;
        uint256 tier;
        uint256 startTime;
        uint256 endTime;
        uint256 vestingDays;
        bool active;
    }

    error ZeroAddress();
    error InvalidProtocol();
    error InvalidProtocolType();
    error ProtocolExists();
    error InvalidTier();
    error InvalidBond();
    error InvalidConditions();

    mapping(address protocol => uint256 protocolId) public protocolRegistry; // protocol address → protocolId
    mapping(uint256 protocolId => ProtocolType) public protocolType; // protocolId → ProtocolType
    mapping(uint256 protocolId => uint256[] bondIds) public protocolBonds; // protocolId → [bondIds]
    mapping(uint256 bondId => Bond) public bonds; // bondId → Bond
    mapping(uint8 tier => uint256 minDiscount) public minDiscountPerTier;
    mapping(uint256 protocolId => uint256) public totalDeployedByProtocol; // Track deployment per protocol

    IVaultManager public vault; // Interface to interact with the VaultManager

    uint256 public bondCounter; // auto-increment bond IDs
    uint256 public protocolCounter; //auto increasing no of protocols
    uint256 public totalUsdcDeployed; // cumulative USDC sent
    uint256 public totalUsdcReturned; // cumulative USDC repaid
    uint256 public totalUsdcAvailable; // current USDC available for deployment
    uint256 public maxBondTvlPercent = 25;
    uint256 public minDiscount = 2000;

    function initialize(
        address initialOwner,
        IVaultManager _vault,
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
        minDiscountPerTier[0] = 3000; // 30 days: 30% min discount
        minDiscountPerTier[1] = 2500; // 60 days: 25% min discount
        minDiscountPerTier[2] = 2000; // 90 days: 20% min discount
    }

    function setVault(IVaultManager _newVault) external onlyOwner {
        if (address(_newVault) == address(0)) revert ZeroAddress();
        address oldVault = address(vault);
        vault = _newVault;
        emit VaultAddressUpdate(oldVault, address(_newVault));
    }

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

    function _registerProtocolInternal(
        address protocol,
        ProtocolType _protocolType
    ) internal {
        uint256 newProtocolId = ++protocolCounter;
        protocolRegistry[protocol] = newProtocolId;
        protocolType[newProtocolId] = _protocolType;
    }

    function createBond(
        address protocol,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint8 tier,
        uint64 discount,
        uint256 vestingDays,
        ProtocolType protocolType_
    ) external onlyOwner nonReentrant {
        // CHECKS (all validation upfront)
        if (address(protocol) == address(0)) revert ZeroAddress();
        if (usdcAmount == 0 || tokenAmount == 0) revert InvalidConditions();
        if (discount < minDiscountPerTier[tier]) revert InvalidConditions();
        if (vestingDays < 30) revert InvalidConditions();

        // Auto-register protocol if not already registered
        if (protocolRegistry[protocol] == 0) {
            _registerProtocolInternal(protocol, protocolType_);
        }

        uint8 computedTier = _vestingDaysToTier(vestingDays);
        if (computedTier != tier) revert InvalidTier();

        // Query vault for available capacity (before state changes)
        uint256 availableInTier = vault.getProtocolAvailableByTier(tier);
        uint256 maxPerProtocol = (availableInTier * maxBondTvlPercent) / 100;

        uint256 protocolId = protocolRegistry[protocol];
        // Check per-protocol cap
        if (totalDeployedByProtocol[protocolId] + usdcAmount > maxPerProtocol) {
            revert InvalidConditions();
        }

        // ========== EFFECTS (modify THIS contract state) ==========
        uint256 newBondId = ++bondCounter;

        Bond memory newBond = Bond({
            bondId: newBondId,
            protocol: protocol,
            protocolId: protocolId,
            protocolType: protocolType[protocolId],
            protocolToken: address(0),
            usdcProvided: usdcAmount,
            tokenAmount: uint128(tokenAmount),
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
        totalDeployedByProtocol[protocolId] += usdcAmount;
        totalUsdcDeployed += usdcAmount;
        totalUsdcAvailable -= usdcAmount;

        // ========== INTERACTIONS (external calls) ==========
        // Transfer first (most critical)
        usdc.safeTransferFrom(msg.sender, protocol, usdcAmount);

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

    function _vestingDaysToTier(
        uint256 vestingDays
    ) internal view returns (uint8) {
        if (vestingDays == 30) return 0;
        if (vestingDays == 60) return 1;
        if (vestingDays == 90) return 2;
        revert InvalidTier();
    }

    function max(
        address protocol,
        uint256 ProtocolId
    ) external onlyOwner returns (uint256) {}
}
