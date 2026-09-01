// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpMatchingEngine} from "../../src/matching/PerpMatchingEngine.sol";

/// @title PerpMatchingEngineTradeTypehashTest
/// @notice Wire-format lock: hard-codes the EXACT V2 EIP-712 type string for
///         `PerpTrade` and asserts the on-chain `TRADE_TYPEHASH` matches.
///         Any change to the signed payload will fail this test — forcing
///         backend/frontend mirrors to update in lockstep.
/// @dev Guards PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 Part B.
contract PerpMatchingEngineTradeTypehashTest is Test {
    /// @dev Zero-address mock engine placeholder is not acceptable because
    ///      the constructor rejects the zero address; deploy a trivial mock.
    address internal constant OWNER = address(0xA11CE);

    /// @notice EXPECTED canonical V2 EIP-712 type string for `PerpTrade`.
    ///         MUST match {PerpMatchingEngine.TRADE_TYPEHASH} verbatim.
    string internal constant EXPECTED_PERP_TRADE_TYPE_STRING =
        "PerpTrade(bytes32 intentId,address buyer,address seller,uint256 marketId,uint128 sizeDelta1e8,uint128 executionPrice1e8,uint128 maxExecutionPrice1e8,uint128 minExecutionPrice1e8,bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)";

    MinimalPerpEngine internal perpEngine;
    PerpMatchingEngine internal matchingEngine;

    function setUp() external {
        perpEngine = new MinimalPerpEngine();
        matchingEngine = new PerpMatchingEngine(OWNER, address(perpEngine));
    }

    function testTradeTypehashMatchesExpectedV2String() external view {
        bytes32 expected = keccak256(bytes(EXPECTED_PERP_TRADE_TYPE_STRING));
        assertEq(matchingEngine.TRADE_TYPEHASH(), expected, "V2 PerpTrade typehash drifted from canonical wire format");
    }
}

contract MinimalPerpEngine is IPerpEngineTrade {
    function applyTrade(Trade calldata) external pure {}
}
