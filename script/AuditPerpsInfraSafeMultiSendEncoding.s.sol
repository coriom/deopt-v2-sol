// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";

/// @notice PERPS_SAFE_MULTISEND_ENCODING_AND_OPERATION audit.
///
/// READ-ONLY. Independently reconstructs the frozen Safe transaction from
/// first principles, distinguishes and proves the TWO distinct byte
/// sequences that operators must NOT confuse, and validates the
/// operation-type requirement by simulating both DELEGATECALL and CALL
/// against the live ProtocolTimelock on a Base Sepolia fork.
///
/// Invocation (fork mode — no broadcast possible):
///   CH_ETH=0x09BC... CH_BTC=0x78BF... PY_ETH=0x1a63... PY_BTC=0x6908... \
///   forge script script/AuditPerpsInfraSafeMultiSendEncoding.s.sol \
///     --fork-url https://sepolia.base.org --sig "run()" -vv
contract AuditPerpsInfraSafeMultiSendEncoding is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    address internal constant ORACLE_ROUTER      = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant PROTOCOL_TIMELOCK  = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant OPS_MULTISIG       = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address internal constant COLLATERAL_MUSDC   = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant ETH_MWETH          = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BTC_MWBTC          = 0x9D871aC7595E8Da271E866608E5145252047967c;

    address internal constant MULTISEND_CALL_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    uint32 internal constant NEW_MAX_ORACLE_DELAY   = 1500;
    uint32 internal constant NEW_PER_FEED_MAX_DELAY = 1500;
    uint16 internal constant NEW_MAX_DEVIATION_BPS  = 100;

    // Frozen values from the ratified derivation
    uint256 internal constant FROZEN_ETA = 1_789_028_048;
    bytes32 internal constant FROZEN_SAFE_DATA_KECCAK =
        0x49952570e0547262591952d88fb9fd91188896ddd4d277cd1423d359679087f8;
    bytes32 internal constant FROZEN_OP_HASH_5 =
        0xcf3bb80c4d29eb3dc1c34da170e6932e0ccd55c28784f75f896de31af9829ead;
    bytes32 internal constant FROZEN_OP_HASH_6 =
        0x6b6dc2415dd1fe163cfa7d6c814cdb905c676d7e46da97686671e1c06c7af83a;
    bytes32 internal constant FROZEN_OP_HASH_7 =
        0x05ad4de62478e8175efd321e22dca2eb87ba6082e1b3791aa6c7909de8ffd7c7;

    bytes4 internal constant MULTISEND_SELECTOR = bytes4(0x8d80ff0a); // multiSend(bytes)

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532");

        address chEth = vm.envAddress("CH_ETH");
        address chBtc = vm.envAddress("CH_BTC");
        address pyEth = vm.envAddress("PY_ETH");
        address pyBtc = vm.envAddress("PY_BTC");
        require(chEth.code.length > 0 && chBtc.code.length > 0 && pyEth.code.length > 0 && pyBtc.code.length > 0, "adapter has no code");

        ProtocolTimelock tl = ProtocolTimelock(payable(PROTOCOL_TIMELOCK));

        // ------------------------------------------------------------------
        // 1. Build the three inner Timelock calldata items (bit-for-bit)
        // ------------------------------------------------------------------
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

        // ------------------------------------------------------------------
        // 2. Wrap each inner into a Timelock.queueTransaction outer call
        // ------------------------------------------------------------------
        bytes memory outerTx05 = abi.encodeWithSelector(
            ProtocolTimelock.queueTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetDelay, FROZEN_ETA
        );
        bytes memory outerTx06 = abi.encodeWithSelector(
            ProtocolTimelock.queueTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetFeedEth, FROZEN_ETA
        );
        bytes memory outerTx07 = abi.encodeWithSelector(
            ProtocolTimelock.queueTransaction.selector,
            ORACLE_ROUTER, uint256(0), innerSetFeedBtc, FROZEN_ETA
        );

        // ------------------------------------------------------------------
        // 3. Verify each op hash matches the frozen values
        // ------------------------------------------------------------------
        bytes32 opHash5 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetDelay,   FROZEN_ETA);
        bytes32 opHash6 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetFeedEth, FROZEN_ETA);
        bytes32 opHash7 = tl.hashOperationBytes(ORACLE_ROUTER, 0, innerSetFeedBtc, FROZEN_ETA);
        require(opHash5 == FROZEN_OP_HASH_5, "opHash5 mismatch");
        require(opHash6 == FROZEN_OP_HASH_6, "opHash6 mismatch");
        require(opHash7 == FROZEN_OP_HASH_7, "opHash7 mismatch");

        // ------------------------------------------------------------------
        // 4. Build MULTISEND_INNER_TRANSACTIONS_BYTES (packed sub-tx encoding)
        //    Format per sub-tx: operation(1) + to(20) + value(32) + dataLen(32) + data
        // ------------------------------------------------------------------
        bytes memory sub05 = abi.encodePacked(uint8(0), PROTOCOL_TIMELOCK, uint256(0), outerTx05.length, outerTx05);
        bytes memory sub06 = abi.encodePacked(uint8(0), PROTOCOL_TIMELOCK, uint256(0), outerTx06.length, outerTx06);
        bytes memory sub07 = abi.encodePacked(uint8(0), PROTOCOL_TIMELOCK, uint256(0), outerTx07.length, outerTx07);
        bytes memory multiSendInner = abi.encodePacked(sub05, sub06, sub07);
        bytes32 multiSendInnerKeccak = keccak256(multiSendInner);

        // ------------------------------------------------------------------
        // 5. Build SAFE_FULL_CALLDATA = 0x8d80ff0a || abi.encode(multiSendInner)
        //    Two independent constructions; assert they are byte-identical.
        // ------------------------------------------------------------------
        bytes memory safeFullCalldataA =
            abi.encodeWithSelector(MULTISEND_SELECTOR, multiSendInner);
        bytes memory safeFullCalldataB =
            abi.encodeCall(IMultiSend.multiSend, (multiSendInner));
        require(keccak256(safeFullCalldataA) == keccak256(safeFullCalldataB),
                "encodeWithSelector != encodeCall");

        bytes memory safeFullCalldata = safeFullCalldataA;
        bytes32 safeFullCalldataKeccak = keccak256(safeFullCalldata);

        // ------------------------------------------------------------------
        // 6. Assert the reconstructed Safe.data matches the FROZEN hash
        // ------------------------------------------------------------------
        require(safeFullCalldataKeccak == FROZEN_SAFE_DATA_KECCAK, "SAFE_FULL_CALLDATA keccak != frozen");
        require(bytes4(safeFullCalldata[0]) | (bytes4(safeFullCalldata[1]) >> 8)
                | (bytes4(safeFullCalldata[2]) >> 16) | (bytes4(safeFullCalldata[3]) >> 24)
                == MULTISEND_SELECTOR, "selector != 0x8d80ff0a");

        // ------------------------------------------------------------------
        // 7. Print BOTH distinct byte sequences with clear labels
        // ------------------------------------------------------------------
        console2.log("========================================================================");
        console2.log("PERPS_SAFE_MULTISEND_ENCODING_AND_OPERATION_VALIDATED");
        console2.log("========================================================================");
        console2.log("chain                       : Base Sepolia (84532)");
        console2.log("Safe                        :", OPS_MULTISIG);
        console2.log("MultiSendCallOnly           :", MULTISEND_CALL_ONLY);
        console2.log("ProtocolTimelock            :", PROTOCOL_TIMELOCK);
        console2.log("frozen ETA                  :", FROZEN_ETA);
        console2.log("");
        console2.log("-------- MULTISEND_INNER_TRANSACTIONS_BYTES --------");
        console2.log("  Paste this into the `transactions` (bytes) parameter of `multiSend`");
        console2.log("  when the Safe UI form asks for the ABI argument.");
        console2.log("  DO NOT include the 0x8d80ff0a selector or any outer ABI-encoded");
        console2.log("  offset/length prefix.");
        console2.log("  length (bytes)            :", multiSendInner.length);
        console2.log("  keccak256                 :");
        console2.logBytes32(multiSendInnerKeccak);
        console2.log("  hex value                 :");
        console2.logBytes(multiSendInner);
        console2.log("");
        console2.log("-------- SAFE_FULL_CALLDATA --------");
        console2.log("  This is what the Safe actually sends to MultiSendCallOnly.");
        console2.log("  Use this in RAW forms (e.g., safe-cli --data, EIP-712 review).");
        console2.log("  DO NOT paste this into an ABI-encoded `bytes` form field, or the");
        console2.log("  Safe UI will double-encode it and the resulting hash will differ.");
        console2.log("  length (bytes)            :", safeFullCalldata.length);
        console2.log("  keccak256                 :");
        console2.logBytes32(safeFullCalldataKeccak);
        console2.log("  frozen keccak (expected)  :");
        console2.logBytes32(FROZEN_SAFE_DATA_KECCAK);
        console2.log("  match?                    :", safeFullCalldataKeccak == FROZEN_SAFE_DATA_KECCAK);
        console2.log("  hex value                 :");
        console2.logBytes(safeFullCalldata);
        console2.log("");
        console2.log("-------- DECODED 3 INNER CALLS --------");
        console2.log("  1) ProtocolTimelock.queueTransaction(");
        console2.log("       target=", ORACLE_ROUTER);
        console2.log("       value= 0");
        console2.log("       data=  setMaxOracleDelay(uint32=1500)");
        console2.log("       eta=  ", FROZEN_ETA);
        console2.log("     )  -> op hash:"); console2.logBytes32(opHash5);
        console2.log("  2) ProtocolTimelock.queueTransaction(");
        console2.log("       target=", ORACLE_ROUTER);
        console2.log("       value= 0");
        console2.log("       data=  setFeed(mWETH, mUSDC, chEth, pyEth, 1500, 100, true)");
        console2.log("         chEth=", chEth);
        console2.log("         pyEth=", pyEth);
        console2.log("       eta=  ", FROZEN_ETA);
        console2.log("     )  -> op hash:"); console2.logBytes32(opHash6);
        console2.log("  3) ProtocolTimelock.queueTransaction(");
        console2.log("       target=", ORACLE_ROUTER);
        console2.log("       value= 0");
        console2.log("       data=  setFeed(mWBTC, mUSDC, chBtc, pyBtc, 1500, 100, true)");
        console2.log("         chBtc=", chBtc);
        console2.log("         pyBtc=", pyBtc);
        console2.log("       eta=  ", FROZEN_ETA);
        console2.log("     )  -> op hash:"); console2.logBytes32(opHash7);
        console2.log("");

        // ------------------------------------------------------------------
        // 8. Prove operation=DELEGATECALL is required (not merely preferred)
        //
        //    We simulate both operation modes by pranking msg.sender to the
        //    address that would be seen by Timelock in each case:
        //      DELEGATECALL: Safe delegatecalls MultiSendCallOnly; MSCO's
        //        inner CALL executes in Safe's context -> Timelock sees
        //        msg.sender = Safe.
        //      CALL: Safe calls MultiSendCallOnly; MSCO's inner CALL
        //        executes in MSCO's context -> Timelock sees
        //        msg.sender = MultiSendCallOnly.
        // ------------------------------------------------------------------
        console2.log("-------- OPERATION-TYPE PROOF --------");
        console2.log("");
        console2.log("Case 1: DELEGATECALL (correct)  -> Timelock sees msg.sender = Safe");
        vm.prank(OPS_MULTISIG);
        (bool queueOK, bytes memory queueRet) = PROTOCOL_TIMELOCK.call(outerTx05);
        console2.log("  Safe -> Timelock.queueTransaction(TX-05) success:", queueOK);
        if (queueOK) {
            bytes32 retOpHash = abi.decode(queueRet, (bytes32));
            console2.log("    returned op hash:"); console2.logBytes32(retOpHash);
            require(retOpHash == FROZEN_OP_HASH_5, "queue return != frozen op hash");
        }
        console2.log("");
        console2.log("Case 2: CALL (wrong)  -> Timelock sees msg.sender = MultiSendCallOnly");
        vm.prank(MULTISEND_CALL_ONLY);
        (bool msCallOk, ) = PROTOCOL_TIMELOCK.call(outerTx05);
        console2.log("  MSCO -> Timelock.queueTransaction(TX-05) success:", msCallOk);
        console2.log("  (must be false - MSCO is not a Timelock proposer, so the call");
        console2.log("   reverts with onlyProposer. CALL mode would therefore fail atomically.)");
        require(!msCallOk, "MSCO-as-sender should NOT be a proposer");
        console2.log("");
        console2.log("Conclusion: Safe.operation MUST be 1 (DELEGATECALL). CALL (0) will revert.");
        console2.log("");
    }
}

interface IMultiSend {
    function multiSend(bytes calldata transactions) external payable;
}
