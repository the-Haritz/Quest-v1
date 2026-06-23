//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultManager {
    enum LockupPeriod {
        THIRTY_DAYS,
        SIXTY_DAYS,
        NINETY_DAYS
    }

    struct DepositReceipt {
        uint256 amount;
        LockupPeriod tier;
        uint256 lockupEnd;
        bool expiryCounted;
        uint256 rewardDebt;
    }

    function isManager(address account) external view returns (bool);

    function getUserAvailableByTier(
        address user,
        uint8 tier
    ) external view returns (uint256);

    function getProtocolAvailableByTier(
        uint8 tier
    ) external view returns (uint256);

    function getWeightedBalance(address user) external view returns (uint256);

    function getTotalWeightedBalance() external view returns (uint256);

    function getMyDeposits(address user) external view returns (DepositReceipt[] memory);

    function updateRewardDebt(
        address user,
        uint256 depositIndex,
        uint256 newRewardDebt
    ) external;

    function markDeployed(uint8 tier, uint256 amount) external;

    function markReturned(uint8 tier, uint256 amount) external;

    function lendUSDC(address protocol, uint256 amount) external;
}
