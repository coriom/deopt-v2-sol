// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";

/// @notice PERPS_BASE_SEPOLIA_SAFE_QUEUE_PACKAGE_V1 — Stage B derivation.
///
/// READ-ONLY. No `vm.startBroadcast`, no `vm.broadcast`, no state change.
///
/// Given the 4 real adapter addresses produced by Stage A
/// (`CH_ETH`, `CH_BTC`, `PY_ETH`, `PY_BTC` env vars), emits the exact
/// Safe-transaction payloads required to queue TX-05, TX-06 and TX-07
/// through the OPS_MULTISIG Safe (2-of-3, v1.4.1) at
/// `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, calling
/// `ProtocolTimelock.queueTransaction(...)` for each of the three
/// operations frozen in `PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL.md`.
///
/// The ETA is deterministic and frozen at derivation time:
///   ETA = block.timestamp + timelock.minDelay() + 6 hours
///
/// Both a separate-tx layout and a MultiSendCallOnly-batched layout are
/// emitted. The operator picks one (see the accompanying markdown package).
///
/// Invocation:
///   CH_ETH=0x... CH_BTC=0x... PY_ETH=0x... PY_BTC=0x... \
///   forge script script/DerivePerpsInfraSafeQueuePackage.s.sol \
///     --rpc-url https://sepolia.base.org --sig "run()" -vv
contract DerivePerpsInfraSafeQueuePackage is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // Protocol addresses (from FINAL manifest 5f93e199, unchanged)
    address internal constant ORACLE_ROUTER      = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant PROTOCOL_TIMELOCK  = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant OPS_MULTISIG       = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address internal constant COLLATERAL_MUSDC   = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant ETH_MWETH          = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BTC_MWBTC          = 0x9D871aC7595E8Da271E866608E5145252047967c;

    // Canonical Safe MultiSend contracts on Base Sepolia (v1.4.1)
    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    // Frozen router-config values
    uint32 internal constant NEW_MAX_ORACLE_DELAY   = 1500;
    uint32 internal constant NEW_PER_FEED_MAX_DELAY = 1500;
    uint16 internal constant NEW_MAX_DEVIATION_BPS  = 100;

    // ETA policy: minDelay (24h) + 6h operational margin. See Part D of the
    // accompanying package doc for justification.
    uint256 internal constant ETA_SAFETY_MARGIN = 6 hours;

    function run() external view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532 (Base Sepolia)");

        address chEth = vm.envAddress("CH_ETH");
        address chBtc = vm.envAddress("CH_BTC");
        address pyEth = vm.envAddress("PY_ETH");
        address pyBtc = vm.envAddress("PY_BTC");

        require(chEth != address(0), "CH_ETH env missing");
        require(chBtc != address(0), "CH_BTC env missing");
        require(pyEth != address(0), "PY_ETH env missing");
        require(pyBtc != address(0), "PY_BTC env missing");
        require(chEth.code.length > 0, "CH_ETH has no code (Stage A not done or wrong address)");
        require(chBtc.code.length > 0, "CH_BTC has no code");
        require(pyEth.code.length > 0, "PY_ETH has no code");
        require(pyBtc.code.length > 0, "PY_BTC has no code");

        ProtocolTimelock tl = ProtocolTimelock(payable(PROTOCOL_TIMELOCK));
        uint256 minDelay = tl.minDelay();
        require(minDelay >= 86400, "timelock minDelay < 24h - halting");
        require(!tl.queuePaused(), "timelock queuePaused - halting");
        require(tl.proposers(OPS_MULTISIG), "Safe is not a proposer");

        uint256 eta = block.timestamp + minDelay + ETA_SAFETY_MARGIN;

        // Inner router calls (what the Timelock will execute after ETA)
        bytes memory innerSetDelay =
            abi.encodeWithSelector(OracleRouter.setMaxOracleDelay.selector, NEW_MAX_ORACLE_DELAY);
        bytes memory innerSetFeedEth = abi.encodeWithSelector(
            OracleRouter.setFeed.selector,
            ETH_MWETH, COLLATERAL_MUSDC,
            IPriceSource(chEth), IPriceSource(pyEth),
            NEW_PER_FEED_MAX_DELAY, NEW_MAX_DEVIATION_BPS, true
        );
        bytes memory innerSetFeedBtc = abi.encodeWithSelector(
            OracleRouter.setFeed.selector,
            BTC_MWBTC, COLLATERAL_MUSDC,
            IPriceSource(chBtc), IPriceSource(pyBtc),
            NEW_PER_FEED_MAX_DELAY, NEW_MAX_DEVIATION_BPS, true
        );

        // Outer Timelock queue calls (what the Safe will call)
        bytes memory outerTx05 = abi.encodeWithSelector(
            ProtocolTimelock.queueTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetDelay, eta
        );
        bytes memory outerTx06 = abi.encodeWithSelector(
            ProtocolTimelock.queueTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetFeedEth, eta
        );
        bytes memory outerTx07 = abi.encodeWithSelector(
            ProtocolTimelock.queueTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetFeedBtc, eta
        );

        // Predicted timelock operation hashes (must match on-chain after queue)
        bytes32 opHash5 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetDelay, eta);
        bytes32 opHash6 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetFeedEth, eta);
        bytes32 opHash7 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetFeedBtc, eta);

        // -----------------------------------------------------------------
        // Header
        // -----------------------------------------------------------------
        console2.log("=================================================================");
        console2.log("PERPS_BASE_SEPOLIA_SAFE_QUEUE_PACKAGE_V1 - Stage B derivation");
        console2.log("=================================================================");
        console2.log("chain id                    :", block.chainid);
        console2.log("block number                :", block.number);
        console2.log("current block.timestamp     :", block.timestamp);
        console2.log("timelock minDelay (s)       :", minDelay);
        console2.log("ETA safety margin (s)       :", ETA_SAFETY_MARGIN);
        console2.log("frozen ETA (unix)           :", eta);
        console2.log("earliest legal execute time :", eta);
        console2.log("Safe (OPS_MULTISIG)         :", OPS_MULTISIG);
        console2.log("ProtocolTimelock            :", PROTOCOL_TIMELOCK);
        console2.log("Adapter CH_ETH              :", chEth);
        console2.log("Adapter CH_BTC              :", chBtc);
        console2.log("Adapter PY_ETH              :", pyEth);
        console2.log("Adapter PY_BTC              :", pyBtc);
        console2.log("");

        // -----------------------------------------------------------------
        // Layout A - three separate Safe transactions
        // -----------------------------------------------------------------
        console2.log("========== LAYOUT A - THREE SEPARATE SAFE TXS ==========");
        console2.log("Each requires an independent 2-of-3 signing round.");
        console2.log("Safe nonces will be assigned sequentially: 4, 5, 6.");
        console2.log("");

        _printSeparateSafeTx("TX-05  queue setMaxOracleDelay(1500)", outerTx05, opHash5, innerSetDelay);
        _printSeparateSafeTx("TX-06  queue setFeed(mWETH,mUSDC,chEth,pyEth,1500,100,true)", outerTx06, opHash6, innerSetFeedEth);
        _printSeparateSafeTx("TX-07  queue setFeed(mWBTC,mUSDC,chBtc,pyBtc,1500,100,true)", outerTx07, opHash7, innerSetFeedBtc);

        // -----------------------------------------------------------------
        // Layout B - single MultiSendCallOnly batch
        // -----------------------------------------------------------------
        // MultiSend transaction packing:
        //   operation (1 byte, 0 = CALL) + to (20 bytes) + value (32 bytes)
        //   + dataLength (32 bytes) + data (variable)
        bytes memory pack = abi.encodePacked(
            uint8(0), PROTOCOL_TIMELOCK, uint256(0), outerTx05.length, outerTx05,
            uint8(0), PROTOCOL_TIMELOCK, uint256(0), outerTx06.length, outerTx06,
            uint8(0), PROTOCOL_TIMELOCK, uint256(0), outerTx07.length, outerTx07
        );
        bytes memory multiSendData = abi.encodeWithSignature("multiSend(bytes)", pack);

        console2.log("========== LAYOUT B - SINGLE MULTISENDCALLONLY BATCH ==========");
        console2.log("Single 2-of-3 signing round. Atomic all-or-nothing.");
        console2.log("Safe nonce will be assigned: 4.");
        console2.log("");
        console2.log("Safe.to        :", MULTISEND_CALL_ONLY, " (MultiSendCallOnly v1.4.1)");
        console2.log("Safe.value     : 0");
        console2.log("Safe.operation : 1 (DELEGATECALL - required by MultiSend contract)");
        console2.log("Safe.data      :");
        console2.logBytes(multiSendData);
        console2.log("");
        console2.log("(operation=DELEGATECALL against MultiSendCallOnly is safe by construction:");
        console2.log(" the callee itself only performs CALL operations, never DELEGATECALL.)");
        console2.log("");
        console2.log("Expected inner op hashes (identical to Layout A):");
        console2.logBytes32(opHash5);
        console2.logBytes32(opHash6);
        console2.logBytes32(opHash7);
        console2.log("");

        // -----------------------------------------------------------------
        // Post-queue verification commands
        // -----------------------------------------------------------------
        console2.log("========== POST-QUEUE VERIFICATION ==========");
        console2.log("After the Safe tx lands, run (values below are copy/paste):");
        console2.log("");
        console2.log("cast call", PROTOCOL_TIMELOCK, "'queuedTransactions(bytes32)(bool)' <opHash5> --rpc-url https://sepolia.base.org");
        console2.log("cast call", PROTOCOL_TIMELOCK, "'queuedTransactions(bytes32)(bool)' <opHash6> --rpc-url https://sepolia.base.org");
        console2.log("cast call", PROTOCOL_TIMELOCK, "'queuedTransactions(bytes32)(bool)' <opHash7> --rpc-url https://sepolia.base.org");
        console2.log("(all three must return true)");
    }

    function _printSeparateSafeTx(string memory tag, bytes memory outer, bytes32 opHash, bytes memory inner) internal view {
        console2.log(tag);
        console2.log("  Safe.to        :", PROTOCOL_TIMELOCK);
        console2.log("  Safe.value     : 0");
        console2.log("  Safe.operation : 0 (CALL)");
        console2.log("  Safe.data (queueTransaction outer):");
        console2.logBytes(outer);
        console2.log("  inner timelock calldata (for reference):");
        console2.logBytes(inner);
        console2.log("  predicted timelock op hash:");
        console2.logBytes32(opHash);
        console2.log("");
    }
}
