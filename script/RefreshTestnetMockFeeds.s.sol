// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";

/// @notice Testnet-only helper for refreshing mock oracle source prices/timestamps.
/// @dev Requires TESTNET_MOCKS_ENABLED=true and refuses Base mainnet.
contract RefreshTestnetMockFeeds is Script {
    uint256 internal constant DEFAULT_ETH_USDC_PRICE_1E8 = 300_000_000_000;
    uint256 internal constant DEFAULT_BTC_USDC_PRICE_1E8 = 6_500_000_000_000;

    struct Feeds {
        address ethPrimary;
        address ethSecondary;
        address btcPrimary;
        address btcSecondary;
    }

    function run() external {
        _requireTestnetMockRun();

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 ethPrice1e8 = vm.envOr("ETH_USDC_MOCK_PRICE_1E8", DEFAULT_ETH_USDC_PRICE_1E8);
        uint256 btcPrice1e8 = vm.envOr("BTC_USDC_MOCK_PRICE_1E8", DEFAULT_BTC_USDC_PRICE_1E8);

        Feeds memory feeds = Feeds({
            ethPrimary: vm.envAddress("ETH_USDC_PRIMARY_SOURCE"),
            ethSecondary: vm.envAddress("ETH_USDC_SECONDARY_SOURCE"),
            btcPrimary: vm.envAddress("BTC_USDC_PRIMARY_SOURCE"),
            btcSecondary: vm.envAddress("BTC_USDC_SECONDARY_SOURCE")
        });
        _requireContract("ETH_USDC_PRIMARY_SOURCE", feeds.ethPrimary);
        _requireContract("BTC_USDC_PRIMARY_SOURCE", feeds.btcPrimary);

        vm.startBroadcast(deployerPrivateKey);

        MockPriceSource(feeds.ethPrimary).setPrice(ethPrice1e8);
        MockPriceSource(feeds.btcPrimary).setPrice(btcPrice1e8);
        if (feeds.ethSecondary != address(0)) {
            _requireContract("ETH_USDC_SECONDARY_SOURCE", feeds.ethSecondary);
            MockPriceSource(feeds.ethSecondary).setPrice(ethPrice1e8);
        }
        if (feeds.btcSecondary != address(0)) {
            _requireContract("BTC_USDC_SECONDARY_SOURCE", feeds.btcSecondary);
            MockPriceSource(feeds.btcSecondary).setPrice(btcPrice1e8);
        }

        vm.stopBroadcast();

        _logRefresh(feeds, ethPrice1e8, btcPrice1e8);
    }

    function _requireTestnetMockRun() internal view {
        if (!vm.envOr("TESTNET_MOCKS_ENABLED", false)) revert("TESTNET_MOCKS_ENABLED false");
        if (block.chainid == 8453) revert("Base mainnet not allowed");
        uint256 expectedChainId = vm.envOr("CHAIN_ID", block.chainid);
        if (expectedChainId != block.chainid) revert("CHAIN_ID mismatch");
    }

    function _requireContract(string memory label, address target) internal view {
        if (target == address(0)) revert(string.concat(label, " zero"));
        if (target.code.length == 0) revert(string.concat(label, " no code"));
    }

    function _logRefresh(Feeds memory feeds, uint256 ethPrice1e8, uint256 btcPrice1e8) internal view {
        console2.log("Testnet MockPriceSource refresh");
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
