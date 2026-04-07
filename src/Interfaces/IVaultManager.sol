//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IVaultManager {
    function isManager(address account) external view returns (bool);

    function getUserAvailableByTier(
        address user,
        uint8 tier
    ) external view returns (uint256);

    function getProtocolAvailableByTier(
        uint8 tier
    ) external view returns (uint256);

    function markDeployed(uint8 tier, uint256 amount) external;

    function markReturned(uint8 tier, uint256 amount) external;
}
