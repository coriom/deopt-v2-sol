// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IMarginEngineTrade} from "./IMarginEngineTrade.sol";

/// @title IMarginEngineRfqTrade
/// @notice V2G-O sibling interface to {IMarginEngineTrade} that exposes the
///         RFQ-flow entry point on the MarginEngine. Re-uses the existing
///         {IMarginEngineTrade.Trade} struct verbatim — the RFQ vs ORDERBOOK
///         distinction is purely the selector the executor calls, not the
///         per-trade payload shape.
///
/// @dev   V2G-O introduces this interface so that:
///        - the existing {IMarginEngineTrade.applyTrade} ABI is untouched
///          (its bytecode-equivalent ORDERBOOK semantics are preserved
///          even after the V2G-O internal helper refactor);
///        - {OptionMatchingEngine.executeRfqTrade} can cast the
///          MarginEngine reference to this sibling interface and call
///          {applyRfqTrade} without polluting the legacy ORDERBOOK
///          interface;
///        - mock harnesses and other matching engines remain free to
///          implement only the subset they need.
///
///        The deployed MarginEngine contract will implement BOTH
///        {IMarginEngineTrade} and {IMarginEngineRfqTrade} after the V2G-O
///        redeploy. Until that redeploy lands on chain, calling
///        `applyRfqTrade` against the live contract reverts — by design.
interface IMarginEngineRfqTrade {
    /// @notice RFQ-flow entrypoint. Same Trade payload as
    ///         {IMarginEngineTrade.applyTrade}; the difference is that
    ///         the V2 fee charge will pass {IFeesManagerV2.FlowKind.RFQ}
    ///         to {FeesManagerV2.consumeFees}, allowing the per-tier RFQ
    ///         discount profile to take effect.
    ///
    ///         The maker explicitly opts in to the RFQ fee schedule by
    ///         signing the dedicated {OptionMatchingEngine.OptionRfqTrade}
    ///         EIP-712 typehash — see {OptionMatchingEngine}.
    function applyRfqTrade(IMarginEngineTrade.Trade calldata t) external;
}
