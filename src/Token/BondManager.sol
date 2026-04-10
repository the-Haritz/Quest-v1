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
        uint256 tokenAmount;
        uint256 tokensClaimed;
        uint256 tokensProcessed;
        uint8 tier;
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
    mapping(uint256 protocolId => uint256) public currentDeployedByProtocol; // Current active deployment per protocol

    IVaultManager public vault; // Interface to interact with the VaultManager

    uint256 public bondCounter; // auto-increment bond IDs
    uint256 public protocolCounter; //auto increasing no of protocols
    uint256 public totalUsdcDeployed; // cumulative USDC sent
    uint256 public totalUsdcReturned; // cumulative USDC repaid
    uint256 public maxBondTvlPercent = 25;
    uint256 public minDiscount = 2000; // 20% minimum discount

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

        uint8 computedTier = _vestingDaysToTier(vestingDays);
        if (computedTier != tier) revert InvalidTier();

        // Query vault for available capacity (before state changes)
        uint256 availableInTier = vault.getProtocolAvailableByTier(tier);
        uint256 maxPerProtocol = (availableInTier * maxBondTvlPercent) / 100;

        uint256 protocolId = protocolRegistry[protocol];
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

    function _vestingDaysToTier(
        uint256 vestingDays
    ) internal pure returns (uint8) {
        if (vestingDays == 30) return 0;
        if (vestingDays == 60) return 1;
        if (vestingDays == 90) return 2;
        revert InvalidTier();
    }

    function getBondData(uint256 bondId) external view returns (Bond memory) {
        return bonds[bondId];
    }

    function getProtocolActiveBonds(
        address protocol
    ) external view returns (uint256[] memory) {
        uint256 protocolId = protocolRegistry[protocol];

        return protocolBonds[protocolId];
    }

    function getVestedAmount(uint256 bondId) public view returns (uint256) {
        Bond storage bond = bonds[bondId];
        uint256 elapsed = block.timestamp - bond.startTime;
        uint256 vestingPeriod = bond.vestingDays * 1 days;

        if (elapsed >= vestingPeriod) return bond.tokenAmount;
        return Math.mulDiv(bond.tokenAmount, elapsed, vestingPeriod);
    }

    function getClaimableAmount(uint256 bondId) public view returns (uint256) {
        Bond storage bond = bonds[bondId];

        uint256 claimableAmount = getVestedAmount(bondId) - bond.tokensClaimed;
        return claimableAmount;
    }

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

    function claimBond(
        uint256 bondId,
        uint256 amount
    ) external onlyOwner nonReentrant returns (uint256) {
        Bond storage bond = bonds[bondId];
        if (bond.bondId == 0 || !bond.active) revert InvalidBond();

        uint256 claimableAmount = getClaimableAmount(bondId);
        if (claimableAmount >= amount) revert InvalidBond();

        bond.totalClaimed += amount;

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
}
