//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRewardPool {
    /// @notice Returns the current global reward index
    /// @dev Used by QuestToken to snapshot rewardDebt at deposit time
    function rewardIndex() external view returns (uint256);
}
