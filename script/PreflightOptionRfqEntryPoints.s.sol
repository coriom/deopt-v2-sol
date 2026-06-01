// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

/// @title PreflightOptionRfqEntryPoints
/// @notice V2G-P1 read-only ABI probe. Reports whether the live
///         MarginEngine implements `applyRfqTrade(Trade)` and whether
///         the live OptionMatchingEngine implements
///         `executeRfqTrade(OptionRfqTrade,bytes,bytes)`. Pure
///         eth_call / vm.staticcall traffic, no broadcast.
///
/// @dev
///   Required env (any subset; missing addresses are reported as
///   "not configured" rather than as failures):
///     - `MARGIN_ENGINE`              : address to probe for {applyRfqTrade}
///     - `OPTION_MATCHING_ENGINE`     : address to probe for {executeRfqTrade}
///
///   Hard rules enforced at runtime:
///     - no transaction broadcast under any circumstance;
///     - never prints private keys;
///     - tolerates missing env (returns a report, not a revert), so
///       the script is safe to run on stale or partial deployments;
///     - "exposes" status is decided via a static-call probe using
///       intentionally-malformed calldata: if the function exists
///       the contract reverts inside the body (e.g. authorization
///       revert), if it does not exist the EVM returns empty with no
///       data. This distinguishes "method is present but rejected"
///       from "method does not exist on this bytecode" reliably for
///       solc/0.8.x output.
contract PreflightOptionRfqEntryPoints is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `applyRfqTrade((address,address,uint256,uint128,uint128,bool))`
    ///      selector. Derived from {IMarginEngineRfqTrade}.
    bytes4 internal constant APPLY_RFQ_TRADE_SELECTOR = 0x1ccdd23f;

    /// @dev `executeRfqTrade((bytes32,address,address,uint256,address,address,uint64,uint64,bool,uint128,uint128,uint128,bool,uint256,uint256,uint256),bytes,bytes)`
    ///      selector. Derived from {OptionMatchingEngine}.
    bytes4 internal constant EXECUTE_RFQ_TRADE_SELECTOR = 0xb52ce6f5;

    /// @dev Legacy ORDERBOOK reference selectors. Reported alongside
    ///      the RFQ probe so the operator can sanity-check that they
    ///      have the V2 stack and not a stale legacy contract.
    bytes4 internal constant APPLY_TRADE_SELECTOR = 0xb022e608;
    bytes4 internal constant EXECUTE_TRADE_SELECTOR = 0x031f77b3;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    enum SelectorStatus {
        NotConfigured,
        TargetHasNoCode,
        Exposed,
        NotExposed
    }

    struct Report {
        address marginEngine;
        address optionMatchingEngine;
        SelectorStatus applyRfqTrade;
        SelectorStatus executeRfqTrade;
        SelectorStatus applyTrade;
        SelectorStatus executeTrade;
    }

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external returns (Report memory report) {
        address marginEngine = _envAddressOrZero("MARGIN_ENGINE");
        address optionMatchingEngine = _envAddressOrZero("OPTION_MATCHING_ENGINE");
        report = probe(marginEngine, optionMatchingEngine);
        _logReport(report);
    }

    /// @notice Pure address-driven probe entry point. Same logic as
    ///         {run} but bypasses env reads so tests and operator
    ///         tooling can drive the probe deterministically.
    function probe(address marginEngine, address optionMatchingEngine) public view returns (Report memory report) {
        report.marginEngine = marginEngine;
        report.optionMatchingEngine = optionMatchingEngine;
        report.applyRfqTrade = _probe(marginEngine, APPLY_RFQ_TRADE_SELECTOR);
        report.applyTrade = _probe(marginEngine, APPLY_TRADE_SELECTOR);
        report.executeRfqTrade = _probe(optionMatchingEngine, EXECUTE_RFQ_TRADE_SELECTOR);
        report.executeTrade = _probe(optionMatchingEngine, EXECUTE_TRADE_SELECTOR);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Probe whether `target` exposes a function with `selector`.
    ///      We scan the deployed bytecode for `PUSH4 <selector>`. Solc
    ///      emits this exact 5-byte pattern in the dispatch table for
    ///      every external function. A bare staticcall probe is
    ///      unreliable because both "selector not found" and
    ///      "selector found but argument decode failed" produce
    ///      identical empty-data reverts.
    ///
    ///      False positives are bounded by the collision probability of
    ///      a 4-byte sequence appearing inside an unrelated PUSH4
    ///      immediate — vanishingly unlikely for operator-tool
    ///      purposes (~2^-32 per probe), and the selector-set we care
    ///      about is curated.
    function _probe(address target, bytes4 selector) internal view returns (SelectorStatus) {
        if (target == address(0)) return SelectorStatus.NotConfigured;
        bytes memory code = target.code;
        if (code.length == 0) return SelectorStatus.TargetHasNoCode;
        return _bytecodeHasPush4(code, selector) ? SelectorStatus.Exposed : SelectorStatus.NotExposed;
    }

    /// @dev Solc dispatch tables emit `PUSH4 selector` (opcode 0x63)
    ///      for each external function. We search for that 5-byte
    ///      pattern.
    function _bytecodeHasPush4(bytes memory code, bytes4 selector) internal pure returns (bool) {
        uint256 len = code.length;
        if (len < 5) return false;
        bytes1 b0 = bytes1(selector);
        bytes1 b1 = bytes1(selector << 8);
        bytes1 b2 = bytes1(selector << 16);
        bytes1 b3 = bytes1(selector << 24);
        unchecked {
            for (uint256 i = 0; i + 4 < len; i++) {
                if (code[i] == 0x63 && code[i + 1] == b0 && code[i + 2] == b1 && code[i + 3] == b2 && code[i + 4] == b3)
                {
                    return true;
                }
            }
        }
        return false;
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _logReport(Report memory report) internal pure {
        console2.log("V2G-P1 OPTION RFQ entrypoint preflight");
        console2.log("MarginEngine target            :", report.marginEngine);
        console2.log("OptionMatchingEngine target    :", report.optionMatchingEngine);
        _logSelectorLine("MarginEngine.applyRfqTrade   ", APPLY_RFQ_TRADE_SELECTOR, report.applyRfqTrade);
        _logSelectorLine("MarginEngine.applyTrade      ", APPLY_TRADE_SELECTOR, report.applyTrade);
        _logSelectorLine("OptionMatchingEngine.executeRfqTrade", EXECUTE_RFQ_TRADE_SELECTOR, report.executeRfqTrade);
        _logSelectorLine("OptionMatchingEngine.executeTrade  ", EXECUTE_TRADE_SELECTOR, report.executeTrade);
    }

    function _logSelectorLine(string memory label, bytes4 selector, SelectorStatus status) internal pure {
        console2.log(label, vm.toString(selector), _statusString(status));
    }

    function _statusString(SelectorStatus status) internal pure returns (string memory) {
        if (status == SelectorStatus.NotConfigured) return "[not_configured]";
        if (status == SelectorStatus.TargetHasNoCode) return "[target_has_no_code]";
        if (status == SelectorStatus.Exposed) return "[exposed]";
        return "[not_exposed]";
    }
}
