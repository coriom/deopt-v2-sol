// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ChainlinkPriceSource} from "../src/oracle/ChainlinkPriceSource.sol";
import {PythPriceSource} from "../src/oracle/PythPriceSource.sol";
import {IPriceSource} from "../src/oracle/IPriceSource.sol";

/// @notice PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL - TX-01..04.
///
///         Deploys the 4 oracle adapters (Chainlink ETH/USD, Chainlink BTC/USD,
///         Pyth ETH/USD, Pyth BTC/USD) from the deployer EOA on Base Sepolia
///         chain 84532. Nothing else - no router mutation, no timelock queue,
///         no executor rotation.
///
///         Invocation (must be run by the operator with the deployer key):
///           forge script script/BroadcastPerpsInfraTx01to04.s.sol \
///             --rpc-url https://sepolia.base.org \
///             --broadcast \
///             --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
///             --keystore <path-to-deployer-keystore>
///
///         Broadcast artefact:
///           broadcast/BroadcastPerpsInfraTx01to04.s.sol/84532/run-latest.json
contract BroadcastPerpsInfraTx01to04 is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    address internal constant CHAINLINK_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant CHAINLINK_BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address internal constant PYTH_CORE = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    bytes32 internal constant PYTH_ETH_USD_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_BTC_USD_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    address internal constant EXPECTED_DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532 (Base Sepolia)");

        console2.log("=================================================================");
        console2.log("BROADCAST PERPS INFRA TX-01..04 (adapter deploys)");
        console2.log("=================================================================");
        console2.log("chain id           :", block.chainid);
        console2.log("block number       :", block.number);
        console2.log("block timestamp    :", block.timestamp);
        console2.log("expected deployer  :", EXPECTED_DEPLOYER);

        vm.startBroadcast();

        require(tx.origin == EXPECTED_DEPLOYER, "signer address is not the expected deployer");

        ChainlinkPriceSource chEth = new ChainlinkPriceSource(CHAINLINK_ETH_USD);
        console2.log("TX-01 ChainlinkPriceSource(ETH/USD) deployed:", address(chEth));

        ChainlinkPriceSource chBtc = new ChainlinkPriceSource(CHAINLINK_BTC_USD);
        console2.log("TX-02 ChainlinkPriceSource(BTC/USD) deployed:", address(chBtc));

        PythPriceSource pyEth = new PythPriceSource(PYTH_CORE, PYTH_ETH_USD_FEED);
        console2.log("TX-03 PythPriceSource(ETH/USD)      deployed:", address(pyEth));

        PythPriceSource pyBtc = new PythPriceSource(PYTH_CORE, PYTH_BTC_USD_FEED);
        console2.log("TX-04 PythPriceSource(BTC/USD)      deployed:", address(pyBtc));

        vm.stopBroadcast();

        // Post-deploy readbacks (view calls; no state change).
        _readback("chEth", address(chEth));
        _readback("chBtc", address(chBtc));
        _readback("pyEth", address(pyEth));
        _readback("pyBtc", address(pyBtc));

        console2.log("=================================================================");
        console2.log("For TX-05..07 invocation, export the following env vars:");
        console2.log("  export CH_ETH=", address(chEth));
        console2.log("  export CH_BTC=", address(chBtc));
        console2.log("  export PY_ETH=", address(pyEth));
        console2.log("  export PY_BTC=", address(pyBtc));
        console2.log("=================================================================");
    }

    function _readback(string memory label, address adapter) internal view {
        try IPriceSource(adapter).getLatestPrice() returns (uint256 price, uint256 updatedAt) {
            console2.log(label, "price(1e8) :", price);
            console2.log(label, "updatedAt  :", updatedAt);
        } catch {
            console2.log(label, "getLatestPrice() reverted (adapter may still be valid; router will handle)");
        }
    }
}
