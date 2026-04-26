// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";

/// @notice Local-only helper for deploying ETH/BTC mock oracle sources on Anvil.
/// @dev Do not use this script for testnet, staging, or production deployments.
contract DeployLocalMockFeeds is Script {
    uint256 internal constant DEFAULT_ETH_USDC_PRICE_1E8 = 300_000_000_000;
    uint256 internal constant DEFAULT_BTC_USDC_PRICE_1E8 = 6_500_000_000_000;

    struct LocalFeeds {
        address ethPrimary;
        address ethSecondary;
        address btcPrimary;
        address btcSecondary;
    }

    function run() external returns (LocalFeeds memory feeds) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 ethPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", DEFAULT_ETH_USDC_PRICE_1E8);
        uint256 btcPrice1e8 = vm.envOr("BTC_USDC_MOCK_PRICE_1E8", DEFAULT_BTC_USDC_PRICE_1E8);

        vm.startBroadcast(deployerPrivateKey);

        feeds.ethPrimary = address(new MockPriceSource(ethPrice1e8, block.timestamp));
        feeds.ethSecondary = address(new MockPriceSource(ethPrice1e8, block.timestamp));
        feeds.btcPrimary = address(new MockPriceSource(btcPrice1e8, block.timestamp));
        feeds.btcSecondary = address(new MockPriceSource(btcPrice1e8, block.timestamp));

        vm.stopBroadcast();

        _logEnvLines(feeds, ethPrice1e8, btcPrice1e8);
    }

    function _logEnvLines(LocalFeeds memory feeds, uint256 ethPrice1e8, uint256 btcPrice1e8) internal view {
        console2.log("Local MockPriceSource deployment");
        console2.log("chainId", block.chainid);
        console2.log("ETH_USDC_MOCK_PRICE_1E8", ethPrice1e8);
        console2.log("BTC_USDC_MOCK_PRICE_1E8", btcPrice1e8);
        console2.log("");
        console2.log("Copy these lines into .env.local:");
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
