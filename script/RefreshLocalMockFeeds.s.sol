// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";

/// @notice Local-only helper for refreshing Anvil mock feed timestamps.
/// @dev Run immediately before VerifyDeployment when feed maxDelay is tight.
contract RefreshLocalMockFeeds is Script {
    uint256 internal constant DEFAULT_ETH_USDC_PRICE_1E8 = 300_000_000_000;
    uint256 internal constant DEFAULT_BTC_USDC_PRICE_1E8 = 6_500_000_000_000;

    struct LocalFeeds {
        address ethPrimary;
        address ethSecondary;
        address btcPrimary;
        address btcSecondary;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 ethPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", DEFAULT_ETH_USDC_PRICE_1E8);
        uint256 btcPrice1e8 = vm.envOr("BTC_USDC_MOCK_PRICE_1E8", DEFAULT_BTC_USDC_PRICE_1E8);

        LocalFeeds memory feeds = LocalFeeds({
            ethPrimary: vm.envAddress("ETH_USDC_PRIMARY_SOURCE"),
            ethSecondary: vm.envAddress("ETH_USDC_SECONDARY_SOURCE"),
            btcPrimary: vm.envAddress("BTC_USDC_PRIMARY_SOURCE"),
            btcSecondary: vm.envAddress("BTC_USDC_SECONDARY_SOURCE")
        });
        _requireDeployed(feeds);

        vm.startBroadcast(deployerPrivateKey);

        MockPriceSource(feeds.ethPrimary).setPrice(ethPrice1e8);
        MockPriceSource(feeds.ethSecondary).setPrice(ethPrice1e8);
        MockPriceSource(feeds.btcPrimary).setPrice(btcPrice1e8);
        MockPriceSource(feeds.btcSecondary).setPrice(btcPrice1e8);

        vm.stopBroadcast();

        _logRefresh(feeds, ethPrice1e8, btcPrice1e8);
    }

    function _requireDeployed(LocalFeeds memory feeds) internal view {
        _requireContract("ETH_USDC_PRIMARY_SOURCE", feeds.ethPrimary);
        _requireContract("ETH_USDC_SECONDARY_SOURCE", feeds.ethSecondary);
        _requireContract("BTC_USDC_PRIMARY_SOURCE", feeds.btcPrimary);
        _requireContract("BTC_USDC_SECONDARY_SOURCE", feeds.btcSecondary);
    }

    function _requireContract(string memory label, address target) internal view {
        if (target == address(0)) revert(string.concat(label, " zero"));
        if (target.code.length == 0) revert(string.concat(label, " no code"));
    }

    function _logRefresh(LocalFeeds memory feeds, uint256 ethPrice1e8, uint256 btcPrice1e8) internal view {
        console2.log("Local MockPriceSource refresh");
        console2.log("chainId", block.chainid);
        console2.log("updatedAt", block.timestamp);
        console2.log("ETH_USDC_PRIMARY_SOURCE", feeds.ethPrimary);
        console2.log("ETH_USDC_SECONDARY_SOURCE", feeds.ethSecondary);
        console2.log("ETH_USDC_PRICE_1E8", ethPrice1e8);
        console2.log("BTC_USDC_PRIMARY_SOURCE", feeds.btcPrimary);
        console2.log("BTC_USDC_SECONDARY_SOURCE", feeds.btcSecondary);
        console2.log("BTC_USDC_PRICE_1E8", btcPrice1e8);
    }
}
