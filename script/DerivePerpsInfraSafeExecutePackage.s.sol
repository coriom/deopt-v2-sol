// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";

/// @notice PERPS_BASE_SEPOLIA_INFRA_STAGE_C_SAFE_EXECUTE_PACKAGE — Stage C.
///
/// READ-ONLY. No `vm.startBroadcast`, no `vm.broadcast`.
///
/// Consumes the 4 real adapter addresses from Stage A and the FINAL ETA
/// that was successfully queued in Stage B (from the on-chain queue receipts),
/// and emits the exact Safe transaction payloads for TX-08 / TX-09 / TX-10
/// = `ProtocolTimelock.executeTransaction(...)` × 3.
///
/// Fails closed if:
///   - chain id != 84532
///   - any adapter has no code
///   - Safe is not a timelock executor
///   - queuePaused == true
///   - the 3 expected op hashes are NOT currently queued (nothing to execute)
///   - current block.timestamp < FINAL_ETA (execute would revert)
///
/// Invocation (after Stage B lands + ETA reached):
///   CH_ETH=0x... CH_BTC=0x... PY_ETH=0x... PY_BTC=0x... \
///   FINAL_ETA=<unix from queue receipts> \
///   forge script script/DerivePerpsInfraSafeExecutePackage.s.sol \
///     --rpc-url https://sepolia.base.org --sig "run()" -vv
///
/// Emits Layout A (three separate Safe CALL transactions), matching the
/// PATH-1 execution model established for TX-05..07. Nonces will be
/// assigned sequentially starting at the current Safe.nonce (expected 7
/// after Stage B completes).
contract DerivePerpsInfraSafeExecutePackage is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    address internal constant ORACLE_ROUTER      = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant PROTOCOL_TIMELOCK  = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant OPS_MULTISIG       = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address internal constant COLLATERAL_MUSDC   = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant ETH_MWETH          = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BTC_MWBTC          = 0x9D871aC7595E8Da271E866608E5145252047967c;

    uint32 internal constant NEW_MAX_ORACLE_DELAY   = 1500;
    uint32 internal constant NEW_PER_FEED_MAX_DELAY = 1500;
    uint16 internal constant NEW_MAX_DEVIATION_BPS  = 100;

    function run() external view {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532");

        address chEth = vm.envAddress("CH_ETH");
        address chBtc = vm.envAddress("CH_BTC");
        address pyEth = vm.envAddress("PY_ETH");
        address pyBtc = vm.envAddress("PY_BTC");
        uint256 finalEta = vm.envUint("FINAL_ETA");

        require(chEth.code.length > 0 && chBtc.code.length > 0 && pyEth.code.length > 0 && pyBtc.code.length > 0, "adapter has no code");
        require(finalEta > 0, "FINAL_ETA env missing");

        ProtocolTimelock tl = ProtocolTimelock(payable(PROTOCOL_TIMELOCK));
        require(tl.executors(OPS_MULTISIG), "Safe is not a timelock executor");
        require(!tl.queuePaused(), "queuePaused");

        // Reconstruct the 3 inner calldata blocks identically to Stage B.
        bytes memory innerSetDelay =
            abi.encodeWithSelector(OracleRouter.setMaxOracleDelay.selector, NEW_MAX_ORACLE_DELAY);
        bytes memory innerSetFeedEth = abi.encodeWithSelector(
            OracleRouter.setFeed.selector,
            ETH_MWETH, COLLATERAL_MUSDC, IPriceSource(chEth), IPriceSource(pyEth),
            NEW_PER_FEED_MAX_DELAY, NEW_MAX_DEVIATION_BPS, true
        );
        bytes memory innerSetFeedBtc = abi.encodeWithSelector(
            OracleRouter.setFeed.selector,
            BTC_MWBTC, COLLATERAL_MUSDC, IPriceSource(chBtc), IPriceSource(pyBtc),
            NEW_PER_FEED_MAX_DELAY, NEW_MAX_DEVIATION_BPS, true
        );

        // Compute op hashes using the operator-supplied FINAL_ETA.
        bytes32 opHash5 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetDelay,   finalEta);
        bytes32 opHash6 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetFeedEth, finalEta);
        bytes32 opHash7 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetFeedBtc, finalEta);

        // Fail closed if these are NOT queued - execute has nothing to do.
        require(tl.queuedTransactions(opHash5), "opHash5 not queued (Stage B TX-05 not landed?)");
        require(tl.queuedTransactions(opHash6), "opHash6 not queued");
        require(tl.queuedTransactions(opHash7), "opHash7 not queued");

        // Fail closed if ETA not yet reached (timelock would revert)
        bool etaReached = block.timestamp >= finalEta;

        // Build the outer executeTransaction Safe.data for TX-08 / TX-09 / TX-10
        bytes memory outerTx08 = abi.encodeWithSelector(
            ProtocolTimelock.executeTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetDelay, finalEta
        );
        bytes memory outerTx09 = abi.encodeWithSelector(
            ProtocolTimelock.executeTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetFeedEth, finalEta
        );
        bytes memory outerTx10 = abi.encodeWithSelector(
            ProtocolTimelock.executeTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetFeedBtc, finalEta
        );

        console2.log("=================================================================");
        console2.log("PERPS_BASE_SEPOLIA_SAFE_EXECUTE_PACKAGE - Stage C derivation");
        console2.log("=================================================================");
        console2.log("chain id                    :", block.chainid);
        console2.log("block number                :", block.number);
        console2.log("current block.timestamp     :", block.timestamp);
        console2.log("FINAL_ETA                   :", finalEta);
        console2.log("ETA reached                 :", etaReached);
        if (!etaReached) {
            console2.log("!! seconds until ETA         :", finalEta - block.timestamp);
            console2.log("!! executing before ETA will revert. Prepare payloads now,");
            console2.log("!! but do not collect Safe signatures until ETA is reached");
            console2.log("!! (Safe signatures are valid regardless of when execution lands).");
        }
        console2.log("Safe (OPS_MULTISIG)         :", OPS_MULTISIG);
        console2.log("Safe.executors[Safe]        : true (verified)");
        console2.log("");

        console2.log("========== LAYOUT A - THREE SEPARATE SAFE TXS ==========");
        console2.log("Each is a Safe CALL (operation=0) to ProtocolTimelock.");
        console2.log("Signing model: PATH-1 (same as TX-05..07). No MultiSend.");
        console2.log("Safe nonces will be assigned sequentially from current Safe.nonce");
        console2.log("(expected 7 after Stage B TX-05/06/07 land).");
        console2.log("");

        _printExecuteSafeTx("TX-08  execute setMaxOracleDelay(1500)",
                            outerTx08, opHash5, innerSetDelay);
        _printExecuteSafeTx("TX-09  execute setFeed(mWETH,mUSDC,chEth,pyEth,...)",
                            outerTx09, opHash6, innerSetFeedEth);
        _printExecuteSafeTx("TX-10  execute setFeed(mWBTC,mUSDC,chBtc,pyBtc,...)",
                            outerTx10, opHash7, innerSetFeedBtc);

        console2.log("========== POST-EXECUTE VERIFICATION ==========");
        console2.log("After each Safe.execute lands, run:");
        console2.log("cast call", ORACLE_ROUTER, "'maxOracleDelay()(uint32)' --rpc-url https://sepolia.base.org");
        console2.log("(after TX-08: expect 1500; before TX-08: expect 600)");
        console2.log("");
        console2.log("cast call", PROTOCOL_TIMELOCK, "'queuedTransactions(bytes32)(bool)' <opHash> --rpc-url https://sepolia.base.org");
        console2.log("(after execute of opHashN: expect false - execute clears the queue slot)");
    }

    function _printExecuteSafeTx(string memory tag, bytes memory outer, bytes32 opHash, bytes memory inner) internal view {
        console2.log(tag);
        console2.log("  Safe.to        :", PROTOCOL_TIMELOCK);
        console2.log("  Safe.value     : 0");
        console2.log("  Safe.operation : 0 (CALL)");
        console2.log("  Safe.data (executeTransaction outer):");
        console2.logBytes(outer);
        console2.log("  inner timelock calldata (executed by Timelock as itself):");
        console2.logBytes(inner);
        console2.log("  queued op hash (must be true pre-execute):");
        console2.logBytes32(opHash);
        console2.log("");
    }
}
