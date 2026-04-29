// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";

/// @notice Testnet-only helper for deploying mock ETH/BTC oracle sources.
/// @dev Requires TESTNET_MOCKS_ENABLED=true and refuses Base mainnet.
contract DeployTestnetMockFeeds is Script {
    uint256 internal constant DEFAULT_ETH_USDC_PRICE_1E8 = 300_000_000_000;
    uint256 internal constant DEFAULT_BTC_USDC_PRICE_1E8 = 6_500_000_000_000;

    struct Feeds {
        address ethPrimary;
        address ethSecondary;
        address btcPrimary;
        address btcSecondary;
    }

    function run() external returns (Feeds memory feeds) {
        _requireTestnetMockRun();

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 ethPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", DEFAULT_ETH_USDC_PRICE_1E8);
        uint256 btcPrice1e8 = vm.envOr("BTC_USDC_MOCK_PRICE_1E8", DEFAULT_BTC_USDC_PRICE_1E8);
        bool deploySecondaryFeeds = vm.envOr("DEPLOY_TESTNET_SECONDARY_FEEDS", true);

        vm.startBroadcast(deployerPrivateKey);

        feeds.ethPrimary = address(new MockPriceSource(ethPrice1e8, block.timestamp));
        feeds.btcPrimary = address(new MockPriceSource(btcPrice1e8, block.timestamp));
        if (deploySecondaryFeeds) {
            feeds.ethSecondary = address(new MockPriceSource(ethPrice1e8, block.timestamp));
            feeds.btcSecondary = address(new MockPriceSource(btcPrice1e8, block.timestamp));
        }

        vm.stopBroadcast();

        _logEnvLines(feeds, ethPrice1e8, btcPrice1e8);
    }

    function _requireTestnetMockRun() internal view {
        if (!vm.envOr("TESTNET_MOCKS_ENABLED", false)) revert("TESTNET_MOCKS_ENABLED false");
        if (block.chainid == 8453) revert("Base mainnet not allowed");
        uint256 expectedChainId = vm.envOr("CHAIN_ID", block.chainid);
        if (expectedChainId != block.chainid) revert("CHAIN_ID mismatch");
    }

    function _logEnvLines(Feeds memory feeds, uint256 ethPrice1e8, uint256 btcPrice1e8) internal view {
        console2.log("Testnet MockPriceSource deployment");
        console2.log("chainId", block.chainid);
        console2.log("ETH_USDC_MOCK_PRICE_1E8", ethPrice1e8);
        console2.log("BTC_USDC_MOCK_PRICE_1E8", btcPrice1e8);
        console2.log("");
        console2.log("Copy these lines into .env.base-sepolia:");
        console2.log(string.concat("ETH_USDC_PRIMARY_SOURCE=", vm.toString(feeds.ethPrimary)));
        console2.log(string.concat("ETH_USDC_SECONDARY_SOURCE=", vm.toString(feeds.ethSecondary)));
        console2.log(string.concat("BTC_USDC_PRIMARY_SOURCE=", vm.toString(feeds.btcPrimary)));
        console2.log(string.concat("BTC_USDC_SECONDARY_SOURCE=", vm.toString(feeds.btcSecondary)));
        console2.log(string.concat("ETH_OPTION_ORACLE=", vm.toString(feeds.ethPrimary)));
        console2.log(string.concat("BTC_OPTION_ORACLE=", vm.toString(feeds.btcPrimary)));

        if (vm.envExists("ORACLE_ROUTER")) {
            address oracleRouter = vm.envAddress("ORACLE_ROUTER");
            if (oracleRouter != address(0) && oracleRouter.code.length != 0) {
                console2.log(string.concat("ETH_PERP_ORACLE=", vm.toString(oracleRouter)));
                console2.log(string.concat("BTC_PERP_ORACLE=", vm.toString(oracleRouter)));
                return;
            }
        }

        console2.log("Set ETH_PERP_ORACLE and BTC_PERP_ORACLE to ORACLE_ROUTER after DeployCore.");
    }
}
