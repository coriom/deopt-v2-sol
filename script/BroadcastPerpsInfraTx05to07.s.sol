// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";

/// @notice PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL - TX-05..07.
///
///         Queues the 3 ProtocolTimelock operations (setMaxOracleDelay + two
///         setFeed) that were designed in the frozen manifest. Does NOT
///         execute them (execute is TX-08..10, only permitted after >= 24h
///         + a separate authorization).
///
///         Preconditions:
///           - TX-01..04 have already broadcast successfully.
///           - CH_ETH / CH_BTC / PY_ETH / PY_BTC env vars are set to the
///             deployed adapter addresses (see TX-01..04 output).
///           - Sender key matches the ProtocolTimelock proposer:
///             0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46
///
///         Invocation (must be run by the operator with the timelock proposer key):
///           CH_ETH=0x... CH_BTC=0x... PY_ETH=0x... PY_BTC=0x... \
///           forge script script/BroadcastPerpsInfraTx05to07.s.sol \
///             --rpc-url https://sepolia.base.org \
///             --broadcast \
///             --sender 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46 \
///             --keystore <path-to-tl-proposer-keystore>
///
///         Broadcast artefact:
///           broadcast/BroadcastPerpsInfraTx05to07.s.sol/84532/run-latest.json
contract BroadcastPerpsInfraTx05to07 is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    address internal constant ORACLE_ROUTER = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant PROTOCOL_TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant COLLATERAL_MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant ETH_MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BTC_MWBTC = 0x9D871aC7595E8Da271E866608E5145252047967c;

    address internal constant EXPECTED_TL_SIGNER = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;

    uint32 internal constant NEW_MAX_ORACLE_DELAY = 1500;
    uint32 internal constant NEW_PER_FEED_MAX_DELAY = 1500;
    uint16 internal constant NEW_MAX_DEVIATION_BPS = 100;
    uint256 internal constant ETA_SAFETY_MARGIN = 1 hours;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532 (Base Sepolia)");

        address chEth = vm.envAddress("CH_ETH");
        address chBtc = vm.envAddress("CH_BTC");
        address pyEth = vm.envAddress("PY_ETH");
        address pyBtc = vm.envAddress("PY_BTC");

        require(chEth != address(0), "CH_ETH env missing");
        require(chBtc != address(0), "CH_BTC env missing");
        require(pyEth != address(0), "PY_ETH env missing");
        require(pyBtc != address(0), "PY_BTC env missing");
        require(chEth.code.length > 0, "CH_ETH has no code");
        require(chBtc.code.length > 0, "CH_BTC has no code");
        require(pyEth.code.length > 0, "PY_ETH has no code");
        require(pyBtc.code.length > 0, "PY_BTC has no code");

        ProtocolTimelock tl = ProtocolTimelock(payable(PROTOCOL_TIMELOCK));
        uint256 minDelay = tl.minDelay();
        require(minDelay >= 86400, "timelock minDelay < 24h - halting");
        require(!tl.queuePaused(), "timelock queuePaused - halting");
        require(tl.proposers(EXPECTED_TL_SIGNER), "expected signer is not a proposer");

        uint256 eta = block.timestamp + minDelay + ETA_SAFETY_MARGIN;

        bytes memory dataSetDelay =
            abi.encodeWithSelector(OracleRouter.setMaxOracleDelay.selector, NEW_MAX_ORACLE_DELAY);
        bytes memory dataSetFeedEth = abi.encodeWithSelector(
            OracleRouter.setFeed.selector,
            ETH_MWETH,
            COLLATERAL_MUSDC,
            IPriceSource(chEth),
            IPriceSource(pyEth),
            NEW_PER_FEED_MAX_DELAY,
            NEW_MAX_DEVIATION_BPS,
            true
        );
        bytes memory dataSetFeedBtc = abi.encodeWithSelector(
            OracleRouter.setFeed.selector,
            BTC_MWBTC,
            COLLATERAL_MUSDC,
            IPriceSource(chBtc),
            IPriceSource(pyBtc),
            NEW_PER_FEED_MAX_DELAY,
            NEW_MAX_DEVIATION_BPS,
            true
        );

        bytes32 opHash5 = tl.hashOperationBytes(ORACLE_ROUTER, 0, dataSetDelay, eta);
        bytes32 opHash6 = tl.hashOperationBytes(ORACLE_ROUTER, 0, dataSetFeedEth, eta);
        bytes32 opHash7 = tl.hashOperationBytes(ORACLE_ROUTER, 0, dataSetFeedBtc, eta);

        console2.log("=================================================================");
        console2.log("BROADCAST PERPS INFRA TX-05..07 (timelock queue)");
        console2.log("=================================================================");
        console2.log("chain id                     :", block.chainid);
        console2.log("block number                 :", block.number);
        console2.log("block timestamp              :", block.timestamp);
        console2.log("timelock minDelay (s)        :", minDelay);
        console2.log("ETA safety margin (s)        :", ETA_SAFETY_MARGIN);
        console2.log("ETA (unix ts)                :", eta);
        console2.log("earliest executable ts       :", eta);
        console2.log("expected signer              :", EXPECTED_TL_SIGNER);
        console2.log("adapter CH_ETH               :", chEth);
        console2.log("adapter CH_BTC               :", chBtc);
        console2.log("adapter PY_ETH               :", pyEth);
        console2.log("adapter PY_BTC               :", pyBtc);
        console2.log("TX-05 predicted opHash       :");
        console2.logBytes32(opHash5);
        console2.log("TX-06 predicted opHash       :");
        console2.logBytes32(opHash6);
        console2.log("TX-07 predicted opHash       :");
        console2.logBytes32(opHash7);
        console2.log("TX-05 inner calldata         :");
        console2.logBytes(dataSetDelay);
        console2.log("TX-06 inner calldata         :");
        console2.logBytes(dataSetFeedEth);
        console2.log("TX-07 inner calldata         :");
        console2.logBytes(dataSetFeedBtc);

        vm.startBroadcast();

        require(tx.origin == EXPECTED_TL_SIGNER, "signer address is not the expected timelock proposer");

        tl.queueTransaction(ORACLE_ROUTER, 0, dataSetDelay, eta);
        console2.log("TX-05 queued (setMaxOracleDelay 1500)");

        tl.queueTransaction(ORACLE_ROUTER, 0, dataSetFeedEth, eta);
        console2.log("TX-06 queued (setFeed mWETH)");

        tl.queueTransaction(ORACLE_ROUTER, 0, dataSetFeedBtc, eta);
        console2.log("TX-07 queued (setFeed mWBTC)");

        vm.stopBroadcast();

        // Postcondition readback: verify the queued transactions are present.
        require(tl.queuedTransactions(opHash5), "TX-05 not in queue post-broadcast");
        require(tl.queuedTransactions(opHash6), "TX-06 not in queue post-broadcast");
        require(tl.queuedTransactions(opHash7), "TX-07 not in queue post-broadcast");

        console2.log("=================================================================");
        console2.log("All 3 timelock queues verified present.");
        console2.log("TX-08..10 execute NOT AUTHORIZED - separate directive required after eta.");
        console2.log("=================================================================");
    }
}
