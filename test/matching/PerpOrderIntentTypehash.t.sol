// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpMatchingEngine} from "../../src/matching/PerpMatchingEngine.sol";

/// @title PerpOrderIntentTypehashTest
/// @notice Wire-format lock for the ADDITIVE Part D `PerpOrderIntent`
///         EIP-712 payload. Hard-codes the canonical type string and asserts
///         it hashes to {PerpMatchingEngine.ORDER_INTENT_TYPEHASH}. Any drift
///         in the on-chain typehash — field re-ordering, rename, or type
///         change — fails this test, forcing the backend and frontend
///         mirrors to update in lockstep with the contract.
/// @dev Guards PERPS-FULLSTACK-RUNTIME-INTEGRATION-V1 Part D.
contract PerpOrderIntentTypehashTest is Test {
    address internal constant OWNER = address(0xA11CE);

    /// @notice EXPECTED canonical EIP-712 type string for `PerpOrderIntent`.
    ///         MUST match {PerpMatchingEngine.ORDER_INTENT_TYPEHASH} verbatim.
    string internal constant EXPECTED_ORDER_INTENT_TYPE_STRING =
        "PerpOrderIntent(bytes32 intentId,address trader,uint32 subaccountId,uint256 marketId,uint8 side,uint128 size1e8,uint128 limitPrice1e8,uint128 maxExecPrice1e8,uint128 minExecPrice1e8,uint256 nonce,uint256 deadline)";

    /// @notice EXPECTED typehash digest — pinned so an accidental identical
    ///         re-ordering of the type string that produces a different hash
    ///         is caught even if the string comparison passes elsewhere.
    bytes32 internal constant EXPECTED_ORDER_INTENT_TYPEHASH =
        0xeeaf370e4195f568ccb783efe23803dd5bf3c859aef9d0c3e3f211c2da2d5d1c;

    _MinimalPerpEngine internal perpEngine;
    PerpMatchingEngine internal matchingEngine;

    function setUp() external {
        perpEngine = new _MinimalPerpEngine();
        matchingEngine = new PerpMatchingEngine(OWNER, address(perpEngine));
    }

    function testOrderIntentTypehashMatchesExpectedString() external view {
        bytes32 expected = keccak256(bytes(EXPECTED_ORDER_INTENT_TYPE_STRING));
        assertEq(
            matchingEngine.ORDER_INTENT_TYPEHASH(),
            expected,
            "PerpOrderIntent typehash drifted from canonical wire format"
        );
    }

    function testOrderIntentTypehashMatchesExpectedDigest() external view {
        assertEq(
            matchingEngine.ORDER_INTENT_TYPEHASH(),
            EXPECTED_ORDER_INTENT_TYPEHASH,
            "PerpOrderIntent typehash digest drifted from pinned value"
        );
    }

    function testOrderIntentTypehashDoesNotCollideWithTradeTypehash() external view {
        assertTrue(
            matchingEngine.ORDER_INTENT_TYPEHASH() != matchingEngine.TRADE_TYPEHASH(),
            "ORDER_INTENT_TYPEHASH and TRADE_TYPEHASH must not collide"
        );
    }
}

contract _MinimalPerpEngine is IPerpEngineTrade {
    function applyTrade(Trade calldata) external pure {}
}
