//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "src/Interfaces/IBondManager.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BondManager is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    event BondCreated(
        uint256 indexed protocolId,
        uint256 amount,
        uint256 indexed tier
    );

    enum ProtocolType {
        LENDING,
        STAKING,
        YIELD,
        LAUNCHPAD
    }

    struct Bond {
        uint256 bondId;
        uint256 protocolId;
        ProtocolType protocolType;
        address protocolToken;
        uint256 amount;
        uint256 tier;
        uint256 startTime;
        uint256 endTime;
        bool active;
    }

    error InvalidProtocolType();
    error InvalidTier();
    error InvalidBond();

    mapping(ProtocolType => uint256) public protocolIds;
    mapping(uint256 => Bond) public bonds;
    IBondManager public bondManager;

    function initialize(address initialOwner, address _bondManager) external initializer {
}
