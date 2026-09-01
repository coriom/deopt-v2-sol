// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpMatchingEngine} from "../../src/matching/PerpMatchingEngine.sol";

/// @title MockPerpEngineTrade
/// @notice Trivial `IPerpEngineTrade` accepting every trade — the matching
///         engine is the unit under test; downstream engine behaviour is
///         out of scope.
contract MockPerpEngineTrade is IPerpEngineTrade {
    Trade internal _lastTrade;
    uint256 internal _applyCount;

    function applyTrade(Trade calldata t) external {
        _lastTrade = t;
        _applyCount++;
    }

    function applyCount() external view returns (uint256) {
        return _applyCount;
    }

    function lastTrade() external view returns (Trade memory t) {
        return _lastTrade;
    }
}

/// @title PerpMatchingEngineUserBoundsTest
/// @notice Behavioural coverage of PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1
///         Part B — user-signed inclusive execution-price bounds
///         (`maxExecutionPrice1e8` / `minExecutionPrice1e8`).
/// @dev
///  Semantics under test:
///   - Bound == 0 → strict legacy: `executionPrice1e8` must equal what was
///     signed (any tampering after signing breaks signature — no dedicated
///     revert on the price side).
///   - Bound  > 0 → inclusive check: violation reverts with the appropriate
///     side-specific custom error AFTER signatures verify.
///   - Buyer-side violation is checked before seller-side, so an
///     impossible-range trade (buyer max < seller min) reverts
///     `BuyerBoundExceeded` when the exec falls inside the seller's window.
///   - Legacy V1 EIP-712 signatures (10-field typehash) are REJECTED by the
///     V2 engine: their digest binds a different typehash, so signature
///     recovery no longer resolves to the trader — surfaced as
///     `InvalidSignature`.
contract PerpMatchingEngineUserBoundsTest is Test {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;
    bytes32 internal constant INTENT_ID = keccak256("bounds-test-intent");

    uint256 internal constant MARKET_ID = 7;
    uint128 internal constant SIZE_DELTA = 2e8;

    address internal OWNER;
    address internal BUYER;
    address internal SELLER;

    MockPerpEngineTrade internal perpEngine;
    PerpMatchingEngine internal matchingEngine;

    function setUp() external {
        OWNER = vm.addr(OWNER_PK);
        BUYER = vm.addr(BUYER_PK);
        SELLER = vm.addr(SELLER_PK);

        perpEngine = new MockPerpEngineTrade();
        matchingEngine = new PerpMatchingEngine(OWNER, address(perpEngine));
    }

    /*//////////////////////////////////////////////////////////////
                        BOTH BOUNDS ZERO (LEGACY)
    //////////////////////////////////////////////////////////////*/

    function testBothBoundsZeroExactPriceSucceeds() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 2_000e8, maxExecutionPrice1e8: 0, minExecutionPrice1e8: 0});

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
        assertEq(perpEngine.lastTrade().executionPrice1e8, 2_000e8);
    }

    function testBothBoundsZeroTamperedExecutionPriceRejectedAsInvalidSignature() external {
        // Sign against price 2_000e8, then attempt to submit at 2_500e8:
        // the matcher cannot forge a signature over the tampered price,
        // so signature verification fails.
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 2_000e8, maxExecutionPrice1e8: 0, minExecutionPrice1e8: 0});

        // Mutate the price WITHOUT resigning.
        t.executionPrice1e8 = 2_500e8;

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.InvalidSignature.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          BUYER BOUND SET
    //////////////////////////////////////////////////////////////*/

    function testBuyerBoundExecAtBoundSucceeds() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 2_000e8, maxExecutionPrice1e8: 2_000e8, minExecutionPrice1e8: 0});

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
    }

    function testBuyerBoundExecBelowBoundSucceeds() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 1_950e8, maxExecutionPrice1e8: 2_000e8, minExecutionPrice1e8: 0});

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
        assertEq(perpEngine.lastTrade().executionPrice1e8, 1_950e8);
    }

    function testBuyerBoundExecAboveBoundReverts() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 2_100e8, maxExecutionPrice1e8: 2_000e8, minExecutionPrice1e8: 0});

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.BuyerBoundExceeded.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 0);
        // Nonces are consumed AFTER bounds check, so they remain unchanged.
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         SELLER BOUND SET
    //////////////////////////////////////////////////////////////*/

    function testSellerBoundExecAtBoundSucceeds() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 2_000e8, maxExecutionPrice1e8: 0, minExecutionPrice1e8: 2_000e8});

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
    }

    function testSellerBoundExecAboveBoundSucceeds() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 2_050e8, maxExecutionPrice1e8: 0, minExecutionPrice1e8: 2_000e8});

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
        assertEq(perpEngine.lastTrade().executionPrice1e8, 2_050e8);
    }

    function testSellerBoundExecBelowBoundReverts() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) =
            _signedTrade({executionPrice1e8: 1_950e8, maxExecutionPrice1e8: 0, minExecutionPrice1e8: 2_000e8});

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.SellerBoundViolated.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 0);
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          BOTH BOUNDS SET
    //////////////////////////////////////////////////////////////*/

    function testBothBoundsExecInsideRangeSucceeds() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: 2_000e8,
            maxExecutionPrice1e8: 2_050e8,
            minExecutionPrice1e8: 1_950e8
        });

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
    }

    function testBothBoundsExecAboveBuyerRevertsBuyerFirst() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: 2_100e8,
            maxExecutionPrice1e8: 2_050e8,
            minExecutionPrice1e8: 1_950e8
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.BuyerBoundExceeded.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testBothBoundsExecBelowSellerRevertsSeller() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: 1_900e8,
            maxExecutionPrice1e8: 2_050e8,
            minExecutionPrice1e8: 1_950e8
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.SellerBoundViolated.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    /*//////////////////////////////////////////////////////////////
             IMPOSSIBLE RANGE (BUYER.MAX < SELLER.MIN)
    //////////////////////////////////////////////////////////////*/

    /// @notice Buyer signs `max = 1_800`, seller signs `min = 2_000`. Any
    ///         `executionPrice` satisfying seller's floor (>= 2_000)
    ///         automatically breaches buyer's ceiling. Matcher submits at
    ///         `2_000` (inside seller's window) — expect
    ///         `BuyerBoundExceeded` because the buyer check runs first.
    function testImpossibleRangeBuyerCheckFiresFirst() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade({
            executionPrice1e8: 2_000e8,
            maxExecutionPrice1e8: 1_800e8,
            minExecutionPrice1e8: 2_000e8
        });

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.BuyerBoundExceeded.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    /*//////////////////////////////////////////////////////////////
              TYPEHASH-BUMP SIG REPLAY REJECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice A V1-shaped (10-field) EIP-712 signature MUST be rejected by
    ///         the V2 engine. The V1 typehash differs from V2's, so the
    ///         digest under which the signature was produced no longer
    ///         corresponds to any V2 payload — ECDSA recovery yields a
    ///         different address than the claimed signer, surfacing as
    ///         `InvalidSignature`.
    function testLegacyV1SignaturesRejectedByV2Engine() external {
        // Construct a V2 payload with legacy strict bounds (0/0) so the
        // ONLY thing distinguishing it from a V1 payload is the typehash.
        PerpMatchingEngine.PerpTrade memory t = PerpMatchingEngine.PerpTrade({
            intentId: INTENT_ID,
            buyer: BUYER,
            seller: SELLER,
            marketId: MARKET_ID,
            sizeDelta1e8: SIZE_DELTA,
            executionPrice1e8: 2_000e8,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });

        // Compute a LEGACY-V1 digest (10 fields, old typehash string) as
        // it would have been signed pre-upgrade.
        bytes32 legacyDigest = _legacyV1Digest(t);
        bytes memory legacyBuyerSig = _sign(BUYER_PK, legacyDigest);
        bytes memory legacySellerSig = _sign(SELLER_PK, legacyDigest);

        // Sanity: legacy digest MUST differ from the V2 digest.
        bytes32 v2Digest = matchingEngine.hashTrade(t);
        assertTrue(legacyDigest != v2Digest, "V1 and V2 digests must differ");

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.InvalidSignature.selector);
        matchingEngine.executeTrade(t, legacyBuyerSig, legacySellerSig);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _signedTrade(uint128 executionPrice1e8, uint128 maxExecutionPrice1e8, uint128 minExecutionPrice1e8)
        internal
        view
        returns (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig)
    {
        t = PerpMatchingEngine.PerpTrade({
            intentId: INTENT_ID,
            buyer: BUYER,
            seller: SELLER,
            marketId: MARKET_ID,
            sizeDelta1e8: SIZE_DELTA,
            executionPrice1e8: executionPrice1e8,
            maxExecutionPrice1e8: maxExecutionPrice1e8,
            minExecutionPrice1e8: minExecutionPrice1e8,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 digest = matchingEngine.hashTrade(t);
        buyerSig = _sign(BUYER_PK, digest);
        sellerSig = _sign(SELLER_PK, digest);
    }

    /// @notice Reproduces the LEGACY V1 EIP-712 digest that pre-upgrade
    ///         signers would have produced: 10-field struct + old typehash.
    function _legacyV1Digest(PerpMatchingEngine.PerpTrade memory t) internal view returns (bytes32) {
        bytes32 legacyTypehash = keccak256(
            "PerpTrade(bytes32 intentId,address buyer,address seller,uint256 marketId,uint128 sizeDelta1e8,uint128 executionPrice1e8,bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                legacyTypehash,
                t.intentId,
                t.buyer,
                t.seller,
                t.marketId,
                t.sizeDelta1e8,
                t.executionPrice1e8,
                t.buyerIsMaker,
                t.buyerNonce,
                t.sellerNonce,
                t.deadline
            )
        );

        bytes32 domainSeparator = matchingEngine.domainSeparatorV4();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
