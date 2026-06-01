// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {PreflightOptionRfqEntryPoints} from "../../../script/PreflightOptionRfqEntryPoints.s.sol";

/// @notice V2G-P1 unit tests for the read-only RFQ selector probe.
/// @dev    Uses deliberately-stubby contracts so the test does not
///         depend on the full MarginEngine / OptionMatchingEngine
///         deployment surface — we only care that the probe maps
///         "function exists but reverted" → `Exposed` and "selector
///         falls through to the dispatch sink" → `NotExposed`.
contract PreflightOptionRfqEntryPointsTest is Test {
    PreflightOptionRfqEntryPoints internal preflight;

    bytes4 internal constant APPLY_RFQ_TRADE_SELECTOR = 0x1ccdd23f;
    bytes4 internal constant EXECUTE_RFQ_TRADE_SELECTOR = 0xb52ce6f5;
    bytes4 internal constant APPLY_TRADE_SELECTOR = 0xb022e608;
    bytes4 internal constant EXECUTE_TRADE_SELECTOR = 0x031f77b3;

    function setUp() public {
        preflight = new PreflightOptionRfqEntryPoints();
    }

    function test_probe_reportsNotConfiguredWhenAddressesAreZero() public view {
        PreflightOptionRfqEntryPoints.Report memory report = preflight.probe(address(0), address(0));

        assertEq(report.marginEngine, address(0));
        assertEq(report.optionMatchingEngine, address(0));
        assertEq(uint256(report.applyRfqTrade), uint256(PreflightOptionRfqEntryPoints.SelectorStatus.NotConfigured));
        assertEq(uint256(report.executeRfqTrade), uint256(PreflightOptionRfqEntryPoints.SelectorStatus.NotConfigured));
    }

    function test_probe_reportsTargetHasNoCodeForEoaAddress() public view {
        PreflightOptionRfqEntryPoints.Report memory report = preflight.probe(address(0x1234), address(0x5678));

        assertEq(uint256(report.applyRfqTrade), uint256(PreflightOptionRfqEntryPoints.SelectorStatus.TargetHasNoCode));
        assertEq(uint256(report.executeRfqTrade), uint256(PreflightOptionRfqEntryPoints.SelectorStatus.TargetHasNoCode));
    }

    function test_probe_reportsExposedForV2GOMatchingEngineStub() public {
        StubMarginEngineV2GO marginStub = new StubMarginEngineV2GO();
        StubOptionMatchingEngineV2GO optionStub = new StubOptionMatchingEngineV2GO();

        PreflightOptionRfqEntryPoints.Report memory report = preflight.probe(address(marginStub), address(optionStub));

        assertEq(
            uint256(report.applyRfqTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.Exposed),
            "V2G-O margin stub must expose applyRfqTrade"
        );
        assertEq(
            uint256(report.applyTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.Exposed),
            "V2G-O margin stub must still expose applyTrade"
        );
        assertEq(
            uint256(report.executeRfqTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.Exposed),
            "V2G-O matching stub must expose executeRfqTrade"
        );
        assertEq(
            uint256(report.executeTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.Exposed),
            "V2G-O matching stub must still expose executeTrade"
        );
    }

    function test_probe_reportsNotExposedForLegacyMatchingEngineStub() public {
        StubMarginEngineLegacy legacyMargin = new StubMarginEngineLegacy();
        StubOptionMatchingEngineLegacy legacyOption = new StubOptionMatchingEngineLegacy();

        PreflightOptionRfqEntryPoints.Report memory report =
            preflight.probe(address(legacyMargin), address(legacyOption));

        assertEq(
            uint256(report.applyRfqTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.NotExposed),
            "legacy margin stub must NOT expose applyRfqTrade"
        );
        assertEq(
            uint256(report.applyTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.Exposed),
            "legacy margin stub must still expose applyTrade"
        );
        assertEq(
            uint256(report.executeRfqTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.NotExposed),
            "legacy option matching stub must NOT expose executeRfqTrade"
        );
        assertEq(
            uint256(report.executeTrade),
            uint256(PreflightOptionRfqEntryPoints.SelectorStatus.Exposed),
            "legacy option matching stub must still expose executeTrade"
        );
    }
}

/* ------------------------------------------------------------------ */
/*                                STUBS                                */
/* ------------------------------------------------------------------ */

contract StubMarginEngineV2GO {
    error ApplyTradeNotAuthorized();
    error ApplyRfqTradeNotAuthorized();

    function applyTrade(StubTrade calldata) external pure {
        revert ApplyTradeNotAuthorized();
    }

    function applyRfqTrade(StubTrade calldata) external pure {
        revert ApplyRfqTradeNotAuthorized();
    }
}

contract StubMarginEngineLegacy {
    error ApplyTradeNotAuthorized();

    function applyTrade(StubTrade calldata) external pure {
        revert ApplyTradeNotAuthorized();
    }
}

contract StubOptionMatchingEngineV2GO {
    error ExecuteTradeNotAuthorized();
    error ExecuteRfqTradeNotAuthorized();

    function executeTrade(StubOptionTrade calldata, bytes calldata, bytes calldata) external pure {
        revert ExecuteTradeNotAuthorized();
    }

    function executeRfqTrade(StubOptionTrade calldata, bytes calldata, bytes calldata) external pure {
        revert ExecuteRfqTradeNotAuthorized();
    }
}

contract StubOptionMatchingEngineLegacy {
    error ExecuteTradeNotAuthorized();

    function executeTrade(StubOptionTrade calldata, bytes calldata, bytes calldata) external pure {
        revert ExecuteTradeNotAuthorized();
    }
}

struct StubTrade {
    address buyer;
    address seller;
    uint256 optionId;
    uint128 quantity;
    uint128 price;
    bool buyerIsMaker;
}

struct StubOptionTrade {
    bytes32 intentId;
    address buyer;
    address seller;
    uint256 optionId;
    address underlying;
    address settlementAsset;
    uint64 expiry;
    uint64 strike1e8;
    bool isCall;
    uint128 contractSize1e8;
    uint128 quantity;
    uint128 premiumPerContract;
    bool buyerIsMaker;
    uint256 buyerNonce;
    uint256 sellerNonce;
    uint256 deadline;
}
