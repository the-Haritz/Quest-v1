//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "src/Interfaces/IVaultManager.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RewardPool is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    
    error InsufficientRewards();
    error InvalidWeight();
    error ZeroAddress();
    
    IERC20 public usdc;
    IVaultManager public vault;
    uint256 public rewardIndex;
    uint256 public totalRewardsAccumulated;

    mapping(address => uint256) public totalClaimedByUser;

    event RewardClaimed(
        address indexed user, 
        uint256 amount
    );

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

    function getClaimableRewards(address user) external view returns(uint256 totalClaimable) {
        if (address(user) == address(0)) revert ZeroAddress();

        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(user);

        uint256 length = deposits.length;
        for(uint256 i = 0; i < length; i++) {
            if(deposits[i].amount > 0 && block.timestamp < deposits[i].lockupEnd) {
                uint256 weight = _calculateWeight(deposits[i].amount, uint8(deposits[i].tier));

                uint256 accumulated = Math.mulDiv(rewardIndex, weight, 1e18);

                uint256 debt = deposits[i].rewardDebt;
                uint256 claimable = accumulated > debt ? accumulated - debt : 0;
                totalClaimable += claimable;
            }
        }        

        return totalClaimable;
    }

    function claimRewards(address user) external nonReentrant returns(uint256 totalClaimed) {
        if (address(user) == address(0)) revert ZeroAddress();
        IVaultManager.DepositReceipt[] memory deposits = vault.getMyDeposits(user);

        uint256 length = deposits.length;
        for(uint256 i = 0; i < length; i++) {

            if(deposits[i].amount > 0 && block.timestamp >= deposits[i].lockupEnd) {
                uint256 weight = _calculateWeight(deposits[i].amount, uint8(deposits[i].tier));

                uint256 accumulated = Math.mulDiv(rewardIndex, weight, 1e18);

                uint256 debt = deposits[i].rewardDebt;

                uint256 claimable = accumulated > debt ? accumulated - debt : 0;   

                totalClaimed += claimable;

                vault.updateRewardDebt(user, i, accumulated);
            }
        }
        if(totalClaimed == 0) revert InsufficientRewards();

        usdc.safeTransfer(user, totalClaimed);

        totalClaimedByUser[user] += totalClaimed;

        emit RewardClaimed(user, totalClaimed);

        return totalClaimed;

    }

    function depositRewards(uint256 amount) external nonReentrant onlyOwner returns(uint256) {
        if (amount == 0) revert InvalidWeight();
        
        uint256 totalWeight = vault.getTotalWeightedBalance();
        if (totalWeight == 0) revert InvalidWeight();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        rewardIndex += Math.mulDiv(amount, 1e18, totalWeight);
        totalRewardsAccumulated += amount;

        return amount;
    }

    function _calculateWeight(uint256 amount, uint8 tier) internal view returns(uint256) {
        return Math.mulDiv(amount, _getTierMultiplier(tier), 1e18);
    }

    function _getTierMultiplier(uint8 tier) internal pure returns(uint256) {
        if (tier == 0) return 1e18;      // 30 days: 1.0x
        if (tier == 1) return 15e17;     // 60 days: 1.5x
        if (tier == 2) return 2e18;      // 90 days: 2.0x
        revert InvalidWeight();
    }
}



