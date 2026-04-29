// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice Simple mintable ERC20 for testnet-only deployment rehearsals.
/// @dev Do not use this token for production, mainnet, or economic assumptions.
contract TestnetMockERC20 is ERC20 {
    address public owner;
    uint8 private immutable _tokenDecimals;

    error NotOwner();
    error ZeroAddress();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_) ERC20(name_, symbol_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        _tokenDecimals = decimals_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }
}

/// @notice Testnet-only helper for deploying mock USDC and optional mock underlyings.
/// @dev Requires TESTNET_MOCKS_ENABLED=true and refuses Base mainnet.
contract DeployTestnetAssets is Script {
    struct Assets {
        address mockUsdc;
        address mockEth;
        address mockBtc;
    }

    function run() external returns (Assets memory assets) {
        _requireTestnetMockRun();

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address mintReceiver = vm.envOr("TESTNET_MOCK_MINT_RECEIVER", deployer);
        address tokenOwner = vm.envOr("TESTNET_MOCK_TOKEN_OWNER", deployer);

        bool deployUsdc = vm.envOr("DEPLOY_TESTNET_MOCK_USDC", true);
        bool deployEth = vm.envOr("DEPLOY_TESTNET_MOCK_ETH", true);
        bool deployBtc = vm.envOr("DEPLOY_TESTNET_MOCK_BTC", true);

        vm.startBroadcast(deployerPrivateKey);

        if (deployUsdc) {
            assets.mockUsdc = _deployAndMint(
                "Mock USDC",
                "mUSDC",
                6,
                deployer,
                tokenOwner,
                mintReceiver,
                vm.envOr("TESTNET_MOCK_USDC_MINT_AMOUNT", uint256(0))
            );
        }
        if (deployEth) {
            assets.mockEth = _deployAndMint(
                "Mock WETH",
                "mWETH",
                18,
                deployer,
                tokenOwner,
                mintReceiver,
                vm.envOr("TESTNET_MOCK_ETH_MINT_AMOUNT", uint256(0))
            );
        }
        if (deployBtc) {
            assets.mockBtc = _deployAndMint(
                "Mock WBTC",
                "mWBTC",
                8,
                deployer,
                tokenOwner,
                mintReceiver,
                vm.envOr("TESTNET_MOCK_BTC_MINT_AMOUNT", uint256(0))
            );
        }

        vm.stopBroadcast();

        _logEnvLines(assets, deployer, tokenOwner, mintReceiver);
    }

    function _deployAndMint(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        address deployer,
        address tokenOwner,
        address mintReceiver,
        uint256 mintAmount
    ) internal returns (address token) {
        token = address(new TestnetMockERC20(name, symbol, decimals_, deployer));
        if (mintAmount != 0) TestnetMockERC20(token).mint(mintReceiver, mintAmount);
        TestnetMockERC20(token).transferOwnership(tokenOwner);
    }

    function _requireTestnetMockRun() internal view {
        if (!vm.envOr("TESTNET_MOCKS_ENABLED", false)) revert("TESTNET_MOCKS_ENABLED false");
        if (block.chainid == 8453) revert("Base mainnet not allowed");
        uint256 expectedChainId = vm.envOr("CHAIN_ID", block.chainid);
        if (expectedChainId != block.chainid) revert("CHAIN_ID mismatch");
    }

    function _logEnvLines(Assets memory assets, address deployer, address tokenOwner, address mintReceiver)
        internal
        view
    {
        console2.log("Testnet mock asset deployment");
        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("tokenOwner", tokenOwner);
        console2.log("mintReceiver", mintReceiver);
        console2.log("");
        console2.log("Copy deployed mock addresses into .env.base-sepolia as needed:");
        if (assets.mockUsdc != address(0)) {
            console2.log(string.concat("BASE_COLLATERAL_TOKEN=", vm.toString(assets.mockUsdc)));
            console2.log(string.concat("COLLATERAL_TOKENS=", vm.toString(assets.mockUsdc)));
        }
        if (assets.mockEth != address(0)) console2.log(string.concat("ETH_UNDERLYING=", vm.toString(assets.mockEth)));
        if (assets.mockBtc != address(0)) console2.log(string.concat("BTC_UNDERLYING=", vm.toString(assets.mockBtc)));
    }
}
