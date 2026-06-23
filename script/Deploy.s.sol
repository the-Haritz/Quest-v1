// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "src/Token/QuestToken.sol";
import "src/Pool/RewardPool.sol";
import "src/Token/BondManager.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============ Mock USDC (For local deployments only) ============
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// ============ Mock Dex Router (For local deployments only) ============
contract MockDexRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOutMin;
    }
}

contract DeployScript is Script {
    // Config variables
    address public usdcAddress;
    address public dexRouterAddress;
    address public ownerAddress;

    uint256 public constant MIN_DEPOSIT = 100e6;       // 100 USDC
    uint256 public constant MAX_TVL = 10_000_000e6;     // 10M USDC

    function setUp() public {
        // Load network config or fallback to defaults
        usdcAddress = vm.envOr("USDC_ADDRESS", address(0));
        dexRouterAddress = vm.envOr("DEX_ROUTER_ADDRESS", address(0));
        ownerAddress = vm.envOr("OWNER_ADDRESS", msg.sender);
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0));

        if (deployerPrivateKey == 0) {
            vm.startBroadcast();
        } else {
            vm.startBroadcast(deployerPrivateKey);
        }

        // 1. Deploy Mocks if on local chain
        if (block.chainid == 31337 || usdcAddress == address(0)) {
            console.log("Deploying local Mock USDC...");
            MockUSDC mockUsdc = new MockUSDC();
            usdcAddress = address(mockUsdc);
            console.log("Mock USDC deployed at:", usdcAddress);
        }

        if (block.chainid == 31337 || dexRouterAddress == address(0)) {
            console.log("Deploying local Mock Dex Router...");
            MockDexRouter mockRouter = new MockDexRouter();
            dexRouterAddress = address(mockRouter);
            console.log("Mock Dex Router deployed at:", dexRouterAddress);
        }

        address deployer = msg.sender;
        console.log("Deployer address:", deployer);
        console.log("Designated Owner address:", ownerAddress);

        // 2. Deploy Implementation Contracts
        console.log("Deploying implementation contracts...");
        QuestToken questTokenImpl = new QuestToken();
        RewardPool rewardPoolImpl = new RewardPool();
        BondManager bondManagerImpl = new BondManager();

        console.log("QuestToken Impl:", address(questTokenImpl));
        console.log("RewardPool Impl:", address(rewardPoolImpl));
        console.log("BondManager Impl:", address(bondManagerImpl));

        // 3. Deploy QuestToken Proxy
        // To construct the initialization call, we use abi.encodeWithSelector
        // Note: _vaultManager is set to deployer temporarily (non-zero)
        bytes memory questTokenInitData = abi.encodeWithSelector(
            QuestToken.initialize.selector,
            deployer,
            IVaultManager(deployer), // Temporary non-zero reference, will be updated to self-address below
            usdcAddress,
            MAX_TVL,
            MIN_DEPOSIT
        );

        console.log("Deploying QuestToken Proxy...");
        ERC1967Proxy questTokenProxy = new ERC1967Proxy(
            address(questTokenImpl),
            questTokenInitData
        );
        QuestToken questToken = QuestToken(address(questTokenProxy));
        console.log("QuestToken Proxy deployed at:", address(questToken));

        // Set the self-vaultManager reference correctly
        questToken.setVaultManager(IVaultManager(address(questToken)));
        console.log("QuestToken self-reference vault manager set.");

        // 4. Deploy RewardPool Proxy
        bytes memory rewardPoolInitData = abi.encodeWithSelector(
            RewardPool.initialize.selector,
            deployer,
            IVaultManager(address(questToken)),
            usdcAddress
        );

        console.log("Deploying RewardPool Proxy...");
        ERC1967Proxy rewardPoolProxy = new ERC1967Proxy(
            address(rewardPoolImpl),
            rewardPoolInitData
        );
        RewardPool rewardPool = RewardPool(address(rewardPoolProxy));
        console.log("RewardPool Proxy deployed at:", address(rewardPool));

        // 5. Deploy BondManager Proxy
        bytes memory bondManagerInitData = abi.encodeWithSelector(
            BondManager.initialize.selector,
            deployer,
            IVaultManager(address(questToken)),
            dexRouterAddress,
            usdcAddress
        );

        console.log("Deploying BondManager Proxy...");
        ERC1967Proxy bondManagerProxy = new ERC1967Proxy(
            address(bondManagerImpl),
            bondManagerInitData
        );
        BondManager bondManager = BondManager(address(bondManagerProxy));
        console.log("BondManager Proxy deployed at:", address(bondManager));

        // 6. Complete Protocol Wiring
        console.log("Wiring contract managers and authorizations...");

        // Authorize RewardPool in QuestToken
        questToken.setManager(address(rewardPool), true);
        console.log("RewardPool authorized as manager in QuestToken.");

        // Authorize BondManager in QuestToken
        questToken.setManager(address(bondManager), true);
        console.log("BondManager authorized as manager in QuestToken.");

        // Set RewardPool address in QuestToken
        questToken.setRewardPool(IRewardPool(address(rewardPool)));
        console.log("RewardPool linked to QuestToken.");

        // Set Max Bond TVL Percent in BondManager (Default to 100%)
        bondManager.setMaxBondTvlPercent(100);
        console.log("BondManager Max Bond TVL Percent set to 100%.");

        // 7. Transfer Ownership to Designated Owner if different
        if (ownerAddress != deployer) {
            console.log("Transferring ownership to designated owner address...");
            questToken.transferOwnership(ownerAddress);
            rewardPool.transferOwnership(ownerAddress);
            bondManager.transferOwnership(ownerAddress);
            console.log("Ownership transferred.");
        }

        console.log("Quest Protocol deployment completed successfully!");
        console.log("--- Summary of Proxy Addresses ---");
        console.log("QuestToken Vault (Proxy):", address(questToken));
        console.log("RewardPool (Proxy):       ", address(rewardPool));
        console.log("BondManager (Proxy):      ", address(bondManager));
        console.log("USDC Address used:        ", usdcAddress);
        console.log("DEX Router Address used:  ", dexRouterAddress);

        vm.stopBroadcast();
    }
}
