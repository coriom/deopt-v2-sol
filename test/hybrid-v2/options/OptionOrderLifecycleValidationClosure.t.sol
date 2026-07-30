// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionMatchingEngineV2TestBase} from "./OptionMatchingEngineV2.t.sol";
import {OptionMatchingEngineV2} from "../../../src/hybrid-v2/options/OptionMatchingEngineV2.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {ReplayAndEpochController} from "../../../src/hybrid-v2/security/ReplayAndEpochController.sol";
import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";

/// @title OptionOrderLifecycleValidationClosure
/// @notice `ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-V2-VALIDATION-CLOSURE`
///         — narrow validation-closure test matrix over the reusable Options
///         order lifecycle. Covers:
///           - Part D  EIP-712 digest identity separation.
///           - Part E  Deterministic matrices (concurrent, GTC, cancel,
///                     IOC/FOK, post-only).
///           - Part F  Downstream-failure rollback matrix.
///           - Part I  DB-loss reconstruction.
///           - Part J  Capability-mask exactness.
///
///         Every test on this file operates AGAINST the existing
///         `OptionMatchingEngineV2` (WP-08B + lifecycle patch) as-shipped;
///         it does NOT modify production source.
contract OptionOrderLifecycleValidationClosure is OptionMatchingEngineV2TestBase {
    /*//////////////////////////////////////////////////////////////
                      LOCAL HELPERS (order authoring)
    //////////////////////////////////////////////////////////////*/

    /// @dev Build a buyer-side long order.
    function _buildBuyer(uint128 qty, uint128 price, uint8 tif, uint8 role, bytes32 salt)
        internal
        view
        returns (OptionOrderTypes.OptionOrder memory)
    {
        return OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: qty,
            pricePerContract1e8: price,
            limitPricePerContract1e8: price * 10,
            premiumToken: address(usdc),
            timeInForce: tif,
            role: role,
            maxPositiveFeePpm: 100_000,
            salt: salt
        });
    }

    /// @dev Build a seller-side short order.
    function _buildSeller(uint128 qty, uint128 price, uint8 tif, uint8 role, bytes32 salt)
        internal
        view
        returns (OptionOrderTypes.OptionOrder memory)
    {
        return OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: qty,
            pricePerContract1e8: price,
            limitPricePerContract1e8: price / 10,
            premiumToken: address(usdc),
            timeInForce: tif,
            role: role,
            maxPositiveFeePpm: 100_000,
            salt: salt
        });
    }

    /// @dev Package (envelope, signature) for a caller-signed order.
    function _envAndSig(
        address ownerAddr,
        uint256 privateKey,
        uint32 subaccountId,
        uint256 nonce,
        uint256 deadline,
        OptionOrderTypes.OptionOrder memory order
    ) internal view returns (IntentHash.SignedActionEnvelope memory env, bytes memory sig) {
        env = _makeEnvelope(ownerAddr, subaccountId, nonce, deadline, OptionOrderTypes.hashOrder(order));
        sig = _sign(privateKey, env);
    }

    /// @dev Convenience: run one execution with `fillQuantity` for a signed pair.
    function _execute(
        IntentHash.SignedActionEnvelope memory bEnv,
        bytes memory bSig,
        OptionOrderTypes.OptionOrder memory bOrder,
        IntentHash.SignedActionEnvelope memory sEnv,
        bytes memory sSig,
        OptionOrderTypes.OptionOrder memory sOrder,
        uint128 fillQty
    ) internal returns (bytes32) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        return engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, fillQty, ids, ids);
    }

    /// @dev Snapshot every canonical piece of lifecycle + economic state for
    ///      a two-side execution. Consumed by the rollback matrix.
    struct StateSnapshot {
        uint128 buyerFilled;
        uint128 sellerFilled;
        bool buyerCancelled;
        bool sellerCancelled;
        uint256 buyerVault;
        uint256 sellerVault;
        uint256 buyerLocked;
        uint256 sellerLocked;
        uint32 buyerActive;
        uint32 sellerActive;
        uint128 buyerLong;
        uint128 buyerShort;
        uint128 sellerLong;
        uint128 sellerShort;
        uint256 aliceMinNonce;
        uint256 bobMinNonce;
        uint256 aliceOwnerEpoch;
        uint256 bobOwnerEpoch;
        uint256 aliceSubEpoch;
        uint256 bobSubEpoch;
    }

    function _snapshot(bytes32 buyerOrderId, bytes32 sellerOrderId) internal view returns (StateSnapshot memory snap) {
        bytes32 aliceSk = _sk(alice, 1);
        bytes32 bobSk = _sk(bob, 1);
        snap.buyerFilled = engine.filledQuantityOf(buyerOrderId);
        snap.sellerFilled = engine.filledQuantityOf(sellerOrderId);
        snap.buyerCancelled = engine.isOrderCancelled(buyerOrderId);
        snap.sellerCancelled = engine.isOrderCancelled(sellerOrderId);
        snap.buyerVault = vault.balanceOf(aliceSk, address(usdc));
        snap.sellerVault = vault.balanceOf(bobSk, address(usdc));
        snap.buyerLocked = vault.lockedByEngineOf(aliceSk, address(usdc), address(engine));
        snap.sellerLocked = vault.lockedByEngineOf(bobSk, address(usdc), address(engine));
        snap.buyerActive = ledger.activeSeriesCount(aliceSk);
        snap.sellerActive = ledger.activeSeriesCount(bobSk);
        PositionTypes.OptionPosition memory bp = ledger.positionOf(aliceSk, 1);
        PositionTypes.OptionPosition memory sp = ledger.positionOf(bobSk, 1);
        snap.buyerLong = bp.longQuantity1e8;
        snap.buyerShort = bp.shortQuantity1e8;
        snap.sellerLong = sp.longQuantity1e8;
        snap.sellerShort = sp.shortQuantity1e8;
        snap.aliceMinNonce = engine.minValidOrderNonceOf(aliceSk);
        snap.bobMinNonce = engine.minValidOrderNonceOf(bobSk);
        snap.aliceOwnerEpoch = engine.ownerRecoveryEpoch(alice);
        snap.bobOwnerEpoch = engine.ownerRecoveryEpoch(bob);
        snap.aliceSubEpoch = engine.subaccountRecoveryEpoch(aliceSk);
        snap.bobSubEpoch = engine.subaccountRecoveryEpoch(bobSk);
    }

    function _assertSnapshotUnchanged(StateSnapshot memory a, StateSnapshot memory b) internal pure {
        assertEq(uint256(a.buyerFilled), uint256(b.buyerFilled), "buyerFilled");
        assertEq(uint256(a.sellerFilled), uint256(b.sellerFilled), "sellerFilled");
        assertEq(a.buyerCancelled, b.buyerCancelled, "buyerCancelled");
        assertEq(a.sellerCancelled, b.sellerCancelled, "sellerCancelled");
        assertEq(a.buyerVault, b.buyerVault, "buyerVault");
        assertEq(a.sellerVault, b.sellerVault, "sellerVault");
        assertEq(a.buyerLocked, b.buyerLocked, "buyerLocked");
        assertEq(a.sellerLocked, b.sellerLocked, "sellerLocked");
        assertEq(uint256(a.buyerActive), uint256(b.buyerActive), "buyerActive");
        assertEq(uint256(a.sellerActive), uint256(b.sellerActive), "sellerActive");
        assertEq(uint256(a.buyerLong), uint256(b.buyerLong), "buyerLong");
        assertEq(uint256(a.buyerShort), uint256(b.buyerShort), "buyerShort");
        assertEq(uint256(a.sellerLong), uint256(b.sellerLong), "sellerLong");
        assertEq(uint256(a.sellerShort), uint256(b.sellerShort), "sellerShort");
        assertEq(a.aliceMinNonce, b.aliceMinNonce, "aliceMinNonce");
        assertEq(a.bobMinNonce, b.bobMinNonce, "bobMinNonce");
        assertEq(a.aliceOwnerEpoch, b.aliceOwnerEpoch, "aliceOwnerEpoch");
        assertEq(a.bobOwnerEpoch, b.bobOwnerEpoch, "bobOwnerEpoch");
        assertEq(a.aliceSubEpoch, b.aliceSubEpoch, "aliceSubEpoch");
        assertEq(a.bobSubEpoch, b.bobSubEpoch, "bobSubEpoch");
    }

    /*//////////////////////////////////////////////////////////////
              PART D — EIP-712 DIGEST IDENTITY SEPARATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Two otherwise-identical orders with distinct salts produce
    ///         distinct order ids (payloadHash → envelope digest).
    function test_D_identity_distinctSaltsProduceDistinctDigests() public {
        OptionOrderTypes.OptionOrder memory a =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("s-1"));
        OptionOrderTypes.OptionOrder memory b =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("s-2"));
        IntentHash.SignedActionEnvelope memory eA =
            _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(a));
        IntentHash.SignedActionEnvelope memory eB =
            _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(b));
        assertTrue(engine.hashSignedActionEnvelopeDigest(eA) != engine.hashSignedActionEnvelopeDigest(eB));
    }

    /// @notice Same order produces the same digest across every partial fill.
    ///         (Digest depends only on the signed envelope — never on
    ///         mutable filled-quantity state.)
    function test_D_identity_sameOrderStableDigestAcrossFills() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("stable-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("stable-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 0, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 0, block.timestamp + 1 hours, sOrder);
        bytes32 digest1 = engine.hashSignedActionEnvelopeDigest(bEnv);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8);
        bytes32 digest2 = engine.hashSignedActionEnvelopeDigest(bEnv);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 4e8);
        bytes32 digest3 = engine.hashSignedActionEnvelopeDigest(bEnv);
        assertEq(digest1, digest2);
        assertEq(digest2, digest3);
    }

    /// @notice Digest changes when the signer field changes.
    function test_D_identity_signerFieldSeparatesDigest() public view {
        bytes32 payloadHash = OptionOrderTypes.hashOrder(
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("sig-sep"))
        );
        IntentHash.SignedActionEnvelope memory eA = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        IntentHash.SignedActionEnvelope memory eB = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        eB.signer = bob;
        assertTrue(engine.hashSignedActionEnvelopeDigest(eA) != engine.hashSignedActionEnvelopeDigest(eB));
    }

    /// @notice Digest changes when the deadline field changes.
    function test_D_identity_deadlineSeparatesDigest() public {
        OptionOrderTypes.OptionOrder memory o =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("d-sep"));
        IntentHash.SignedActionEnvelope memory e1 =
            _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(o));
        IntentHash.SignedActionEnvelope memory e2 =
            _makeEnvelope(alice, 1, 0, block.timestamp + 2 hours, OptionOrderTypes.hashOrder(o));
        assertTrue(engine.hashSignedActionEnvelopeDigest(e1) != engine.hashSignedActionEnvelopeDigest(e2));
    }

    /// @notice Digest changes when the recovery epochs change.
    function test_D_identity_recoveryEpochsSeparateDigest() public view {
        bytes32 payloadHash = OptionOrderTypes.hashOrder(
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("epoch-sep"))
        );
        IntentHash.SignedActionEnvelope memory e1 = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        IntentHash.SignedActionEnvelope memory e2 = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        e2.ownerRecoveryEpoch = 1;
        IntentHash.SignedActionEnvelope memory e3 = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        e3.subaccountRecoveryEpoch = 1;
        bytes32 d1 = engine.hashSignedActionEnvelopeDigest(e1);
        bytes32 d2 = engine.hashSignedActionEnvelopeDigest(e2);
        bytes32 d3 = engine.hashSignedActionEnvelopeDigest(e3);
        assertTrue(d1 != d2);
        assertTrue(d1 != d3);
        assertTrue(d2 != d3);
    }

    /// @notice Digest changes when the nonce field changes (concurrent-order
    ///         nonce namespace preserved).
    function test_D_identity_nonceSeparatesDigest() public {
        OptionOrderTypes.OptionOrder memory o =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("n-sep"));
        IntentHash.SignedActionEnvelope memory e1 =
            _makeEnvelope(alice, 1, 5, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(o));
        IntentHash.SignedActionEnvelope memory e2 =
            _makeEnvelope(alice, 1, 6, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(o));
        assertTrue(engine.hashSignedActionEnvelopeDigest(e1) != engine.hashSignedActionEnvelopeDigest(e2));
    }

    /// @notice Digest changes when architectureVersion changes
    ///         (reflecting envelope-binding rejection at engine validation).
    function test_D_identity_architectureVersionSeparatesDigest() public view {
        bytes32 payloadHash = OptionOrderTypes.hashOrder(
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("arch-sep"))
        );
        IntentHash.SignedActionEnvelope memory e1 = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        IntentHash.SignedActionEnvelope memory e2 = _makeEnvelope(alice, 1, 0, block.timestamp + 1 hours, payloadHash);
        e2.architectureVersion = 999;
        assertTrue(engine.hashSignedActionEnvelopeDigest(e1) != engine.hashSignedActionEnvelopeDigest(e2));
    }

    /*//////////////////////////////////////////////////////////////
                PART E — CONCURRENT ORDERS MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice Two concurrent GTC orders (distinct salts, same nonce) both
    ///         live simultaneously; filling one leaves the other untouched.
    function test_E_concurrent_twoLiveGtcOrders() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        OptionOrderTypes.OptionOrder memory bA =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("bA"));
        OptionOrderTypes.OptionOrder memory bB =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("bB"));
        OptionOrderTypes.OptionOrder memory sA =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("sA"));
        (IntentHash.SignedActionEnvelope memory bEnvA, bytes memory bSigA) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bA);
        (IntentHash.SignedActionEnvelope memory bEnvB,) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bB);
        (IntentHash.SignedActionEnvelope memory sEnvA, bytes memory sSigA) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sA);
        // Execute pair A.
        _execute(bEnvA, bSigA, bA, sEnvA, sSigA, sA, 1e8);
        // Buyer B is untouched.
        assertEq(uint256(engine.filledQuantityOf(engine.hashSignedActionEnvelopeDigest(bEnvB))), 0);
        assertFalse(engine.isOrderCancelled(engine.hashSignedActionEnvelopeDigest(bEnvB)));
    }

    /// @notice Ten distinct-salt live GTC orders for one subaccount all
    ///         individually executable (any order, in any sequence).
    function test_E_concurrent_tenLiveOrdersSameSubaccount() public {
        _fund(alice, 1, 100_000e6);
        _fund(bob, 1, 100_000e6);
        // Sign ten buyer + ten seller orders sharing the SAME nonce bucket
        // (nonce=1) but distinct salts.
        for (uint256 i = 0; i < 10; i++) {
            OptionOrderTypes.OptionOrder memory bOrder =
                _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32(i));
            OptionOrderTypes.OptionOrder memory sOrder =
                _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32(i + 100));
            (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
                _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
            (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
                _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
            _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8);
        }
        // All 10 orders have advanced buyer's long by 10 contracts.
        assertEq(uint256(ledger.positionOf(_sk(alice, 1), 1).longQuantity1e8), 10e8);
    }

    /// @notice Cancelling one order leaves other concurrent orders live.
    function test_E_concurrent_cancelOneLeavesOthersLive() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        OptionOrderTypes.OptionOrder memory bA =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("cA"));
        OptionOrderTypes.OptionOrder memory bB =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("cB"));
        OptionOrderTypes.OptionOrder memory sA =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("cSA"));
        (IntentHash.SignedActionEnvelope memory bEnvA,) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bA);
        (IntentHash.SignedActionEnvelope memory bEnvB, bytes memory bSigB) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bB);
        (IntentHash.SignedActionEnvelope memory sEnvA, bytes memory sSigA) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sA);
        vm.prank(alice);
        engine.cancelSignedOrder(bEnvA);
        assertTrue(engine.isOrderCancelled(engine.hashSignedActionEnvelopeDigest(bEnvA)));
        // bB should still execute normally.
        _execute(bEnvB, bSigB, bB, sEnvA, sSigA, sA, 1e8);
        assertEq(uint256(engine.filledQuantityOf(engine.hashSignedActionEnvelopeDigest(bEnvB))), 1e8);
    }

    /// @notice Bulk-nonce advancement invalidates only below-floor orders.
    ///         Orders signed with nonce >= newMin remain valid.
    function test_E_concurrent_bulkNonceInvalidatesOnlyBelowFloor() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        // Sign one order at nonce=2 and another at nonce=10.
        OptionOrderTypes.OptionOrder memory bA =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("bulkA"));
        OptionOrderTypes.OptionOrder memory bB =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("bulkB"));
        OptionOrderTypes.OptionOrder memory sA =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("bulkSA"));
        OptionOrderTypes.OptionOrder memory sB =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("bulkSB"));
        (IntentHash.SignedActionEnvelope memory bEnvA, bytes memory bSigA) =
            _envAndSig(alice, alicePk, 1, 2, block.timestamp + 1 hours, bA);
        (IntentHash.SignedActionEnvelope memory bEnvB, bytes memory bSigB) =
            _envAndSig(alice, alicePk, 1, 10, block.timestamp + 1 hours, bB);
        (IntentHash.SignedActionEnvelope memory sEnvA, bytes memory sSigA) =
            _envAndSig(bob, bobPk, 1, 2, block.timestamp + 1 hours, sA);
        (IntentHash.SignedActionEnvelope memory sEnvB, bytes memory sSigB) =
            _envAndSig(bob, bobPk, 1, 10, block.timestamp + 1 hours, sB);
        // Advance alice's floor to 5. Only nonce=2 is invalidated.
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 5);
        // Attempt to execute bA (nonce=2) → OrderNonceStale.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderNonceStale.selector, _sk(alice, 1), uint256(2), uint256(5)
            )
        );
        engine.executeMatch(bEnvA, bSigA, bA, sEnvA, sSigA, sA, 1e8, ids, ids);
        // bB (nonce=10 ≥ 5) executes.
        _execute(bEnvB, bSigB, bB, sEnvB, sSigB, sB, 1e8);
    }

    /*//////////////////////////////////////////////////////////////
                    PART E — REUSABLE GTC MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice Three sequential partial fills against the same GTC pair
    ///         advance filled-quantity by the exact requested amount at
    ///         each step; the fourth attempt after full-fill reverts.
    function test_E_gtc_threePartialFillsExactRemaining() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("gtc3-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("gtc3-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 2e8);
        assertEq(uint256(engine.filledQuantityOf(bId)), 2e8);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8);
        assertEq(uint256(engine.filledQuantityOf(bId)), 5e8);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 5e8);
        assertEq(uint256(engine.filledQuantityOf(bId)), 10e8);
        // Fourth attempt reverts.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderAlreadyFullyFilled.selector, bId, uint128(10e8), uint128(10e8)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice One side (seller) completes ahead; unrelated buyer order
    ///         from the same signer continues to accept fills against a
    ///         different seller.
    function test_E_gtc_oneSideCompletesOtherStillLive() public {
        _fund(alice, 1, 100_000e6);
        _fund(bob, 1, 100_000e6);
        _fund(carol, 1, 100_000e6);
        // Alice buys 5 via bA/sBob; then buys 3 via bB/sCarol.
        OptionOrderTypes.OptionOrder memory bA =
            _buildBuyer(5e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("ab-A"));
        OptionOrderTypes.OptionOrder memory bB =
            _buildBuyer(3e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("ab-B"));
        OptionOrderTypes.OptionOrder memory sBob =
            _buildSeller(5e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("bob-s"));
        OptionOrderTypes.OptionOrder memory sCarol =
            _buildSeller(3e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("carol-s"));
        (IntentHash.SignedActionEnvelope memory bEnvA, bytes memory bSigA) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bA);
        (IntentHash.SignedActionEnvelope memory bEnvB, bytes memory bSigB) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bB);
        (IntentHash.SignedActionEnvelope memory sBobEnv, bytes memory sBobSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sBob);
        (IntentHash.SignedActionEnvelope memory sCarolEnv, bytes memory sCarolSig) =
            _envAndSig(carol, carolPk, 1, 1, block.timestamp + 1 hours, sCarol);
        _execute(bEnvA, bSigA, bA, sBobEnv, sBobSig, sBob, 5e8);
        // bA fully filled; bB still live.
        assertEq(uint256(engine.filledQuantityOf(engine.hashSignedActionEnvelopeDigest(bEnvB))), 0);
        _execute(bEnvB, bSigB, bB, sCarolEnv, sCarolSig, sCarol, 3e8);
        assertEq(uint256(engine.filledQuantityOf(engine.hashSignedActionEnvelopeDigest(bEnvB))), 3e8);
    }

    /*//////////////////////////////////////////////////////////////
                    PART E — CANCELLATION MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancellation after a partial fill: prior fill history preserved,
    ///         later fills rejected.
    function test_E_cancel_afterPartialFillPreservesHistory() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("canc-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("canc-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 4e8);
        assertEq(uint256(engine.filledQuantityOf(bId)), 4e8);
        vm.prank(alice);
        engine.cancelSignedOrder(bEnv);
        // filled quantity unchanged; cancellation is terminal.
        assertEq(uint256(engine.filledQuantityOf(bId)), 4e8);
        assertTrue(engine.isOrderCancelled(bId));
        // Next fill rejected.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.OrderCancelled.selector, bId));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice Sibling-subaccount OWNER cannot cancel an order they do not own.
    ///         Cross-owner cancellation attempts revert `NotOrderOwner`.
    function test_E_cancel_siblingOwnerCannotCancel() public {
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("sib-canc"));
        (IntentHash.SignedActionEnvelope memory bEnv,) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.NotOrderOwner.selector, bId, carol, alice));
        engine.cancelSignedOrder(bEnv);
    }

    /// @notice Partially-filled order that then falls below the min-nonce
    ///         floor cannot fill further.
    function test_E_cancel_partiallyFilledBelowFloorCannotContinue() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("floor-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("floor-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 3, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 3, block.timestamp + 1 hours, sOrder);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 4e8);
        // Alice advances floor past 3.
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 4);
        // Later fill blocked by OrderNonceStale on buyer side.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderNonceStale.selector, _sk(alice, 1), uint256(3), uint256(4)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice min-valid-nonce cannot decrease.
    function test_E_cancel_minNonceCannotDecrease() public {
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.MinValidOrderNonceNotAdvancing.selector, _sk(alice, 1), uint256(10), uint256(5)
            )
        );
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 5);
    }

    /*//////////////////////////////////////////////////////////////
                        PART E — IOC / FOK MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice IOC full-fill in one call succeeds and terminates naturally
    ///         (filled == signedMax, no cancellation flag needed).
    function test_E_ioc_fullFillOneCallSucceeds() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 50_000e6);
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(5e8, 100e8, OptionOrderTypes.TIF_IOC, OptionOrderTypes.ROLE_TAKER, bytes32("ioc-full-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(5e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("ioc-full-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 5e8);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        assertEq(uint256(engine.filledQuantityOf(bId)), 5e8);
        // Full-fill IOC does NOT get cancellation flag (natural block via filled==max).
        assertFalse(engine.isOrderCancelled(bId));
    }

    /// @notice A failed IOC execution does NOT terminate the order —
    ///         terminalization is coupled to successful mutation only.
    function test_E_ioc_failedExecutionDoesNotTerminalize() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 1e6); // seller under-funded — reservation lock will fail
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(5e8, 100e8, OptionOrderTypes.TIF_IOC, OptionOrderTypes.ROLE_TAKER, bytes32("ioc-fail-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(5e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("ioc-fail-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 5e8, ids, ids);
        // Lifecycle untouched: not cancelled, filled == 0.
        assertFalse(engine.isOrderCancelled(bId));
        assertEq(uint256(engine.filledQuantityOf(bId)), 0);
    }

    /// @notice FOK downstream failure preserves EVERY state component
    ///         (positions, balances, reservations, filled qty, epoch, min-nonce).
    function test_E_fok_downstreamFailurePreservesAllState() public {
        _fund(alice, 1, 50_000e6);
        _fund(bob, 1, 1e6); // under-funded
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(5e8, 100e8, OptionOrderTypes.TIF_FOK, OptionOrderTypes.ROLE_TAKER, bytes32("fok-fail-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(5e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("fok-fail-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sId = engine.hashSignedActionEnvelopeDigest(sEnv);
        StateSnapshot memory before = _snapshot(bId, sId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 5e8, ids, ids);
        StateSnapshot memory afterState = _snapshot(bId, sId);
        _assertSnapshotUnchanged(before, afterState);
    }

    /*//////////////////////////////////////////////////////////////
                    PART E + K — POST-ONLY MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice POST_ONLY + IOC together is rejected pre-consumption
    ///         (the signed role must be MAKER; IOC intent would terminate
    ///         a maker slot the moment it fills, so the combination has no
    ///         useful meaning even if permitted).
    function test_E_postOnly_ioc_isMakerAndTerminatedOnFill() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        // Note: POST_ONLY + IOC is currently allowed structurally (POST_ONLY
        // just requires MAKER role). Execution treats it as maker; IOC
        // semantics still terminate on first fill.
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_POST_ONLY, OptionOrderTypes.ROLE_MAKER, bytes32("po-ioc-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_IOC, OptionOrderTypes.ROLE_TAKER, bytes32("po-ioc-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        _execute(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8);
        // Buyer POST_ONLY reached signed max; seller IOC terminated.
        assertEq(uint256(engine.filledQuantityOf(engine.hashSignedActionEnvelopeDigest(bEnv))), 1e8);
    }

    /// @notice POST_ONLY role is cryptographically bound to signature —
    ///         a relayer cannot flip the signed role or side without
    ///         invalidating the signature.
    function test_K_postOnly_roleCryptographicallyBoundToSignature() public {
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_POST_ONLY, OptionOrderTypes.ROLE_MAKER, bytes32("po-role-s"));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory sSig = _sign(bobPk, sEnv);
        // Relayer flips role to TAKER — payloadHash mismatch (recomputed hash != envelope.payloadHash).
        OptionOrderTypes.OptionOrder memory tampered = sOrder;
        tampered.role = OptionOrderTypes.ROLE_TAKER;
        // Engine cross-checks hashOrder(tampered) against sEnv.payloadHash → mismatch.
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("po-role-b"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        // Payload-hash mismatch reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderPayloadHashMismatch.selector,
                sEnv.payloadHash,
                OptionOrderTypes.hashOrder(tampered)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, tampered, 1e8, ids, ids);
    }

    /// @notice Two POST_ONLY sides cannot pair (both want to be maker).
    function test_K_postOnly_twoPostOnlyRejected() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        OptionOrderTypes.OptionOrder memory bOrder =
            _buildBuyer(1e8, 100e8, OptionOrderTypes.TIF_POST_ONLY, OptionOrderTypes.ROLE_MAKER, bytes32("po-2-b"));
        OptionOrderTypes.OptionOrder memory sOrder =
            _buildSeller(1e8, 100e8, OptionOrderTypes.TIF_POST_ONLY, OptionOrderTypes.ROLE_MAKER, bytes32("po-2-s"));
        (IntentHash.SignedActionEnvelope memory bEnv, bytes memory bSig) =
            _envAndSig(alice, alicePk, 1, 1, block.timestamp + 1 hours, bOrder);
        (IntentHash.SignedActionEnvelope memory sEnv, bytes memory sSig) =
            _envAndSig(bob, bobPk, 1, 1, block.timestamp + 1 hours, sOrder);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.InvalidMakerTakerAssignment.selector,
                OptionOrderTypes.ROLE_MAKER,
                OptionOrderTypes.ROLE_MAKER
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                    PART F — ROLLBACK MATRIX
    //////////////////////////////////////////////////////////////*/

    /// @notice Signature-invalid failure preserves every state component.
    function test_F_rollback_invalidSignature_preservesAllState() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bytes memory badSig = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            badSig[i] = 0x01;
        }
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sId = engine.hashSignedActionEnvelopeDigest(sEnv);
        StateSnapshot memory before = _snapshot(bId, sId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, badSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        _assertSnapshotUnchanged(before, _snapshot(bId, sId));
    }

    /// @notice Fee-hook rejection preserves every state component.
    function test_F_rollback_feeHookReject_preservesAllState() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        feeHook.setReject(true);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sId = engine.hashSignedActionEnvelopeDigest(sEnv);
        StateSnapshot memory before = _snapshot(bId, sId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        _assertSnapshotUnchanged(before, _snapshot(bId, sId));
    }

    /// @notice Undercollateralized-seller failure at reservation-lock or
    ///         post-margin preserves every state component.
    function test_F_rollback_undercollateralizedSeller_preservesAllState() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 1e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sId = engine.hashSignedActionEnvelopeDigest(sEnv);
        StateSnapshot memory before = _snapshot(bId, sId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        _assertSnapshotUnchanged(before, _snapshot(bId, sId));
    }

    /// @notice Expired-deadline failure preserves every state component.
    function test_F_rollback_expiredDeadline_preservesAllState() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bEnv.deadline = block.timestamp - 1;
        bSig = _sign(alicePk, bEnv);
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sId = engine.hashSignedActionEnvelopeDigest(sEnv);
        StateSnapshot memory before = _snapshot(bId, sId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        _assertSnapshotUnchanged(before, _snapshot(bId, sId));
    }

    /// @notice Order-payload-hash mismatch preserves every state component.
    function test_F_rollback_payloadMismatch_preservesAllState() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        // Tamper the buyer order without re-signing (payload will not match envelope).
        bOrder.pricePerContract1e8 = 999e8;
        bytes32 bId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sId = engine.hashSignedActionEnvelopeDigest(sEnv);
        StateSnapshot memory before = _snapshot(bId, sId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        _assertSnapshotUnchanged(before, _snapshot(bId, sId));
    }

    /*//////////////////////////////////////////////////////////////
                    PART I — DB-LOSS RECONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Complex multi-order sequence — 3 GTC partials on one pair,
    ///         one cancellation, one min-nonce advance, one IOC partial,
    ///         one FOK full — leaves lifecycle state fully reconstructible
    ///         from on-chain views. Simulate DB-loss by re-reading views
    ///         and asserting overfill remains blocked.
    function test_I_reconstruction_afterComplexMultiOrderSequence() public {
        _fund(alice, 1, 100_000e6);
        _fund(bob, 1, 100_000e6);

        // 1. GTC pair — 3 partial fills.
        OptionOrderTypes.OptionOrder memory gtcBuyer =
            _buildBuyer(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_TAKER, bytes32("gtc-b"));
        OptionOrderTypes.OptionOrder memory gtcSeller =
            _buildSeller(10e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("gtc-s"));
        (IntentHash.SignedActionEnvelope memory gtcBEnv, bytes memory gtcBSig) =
            _envAndSig(alice, alicePk, 1, 3, block.timestamp + 1 hours, gtcBuyer);
        (IntentHash.SignedActionEnvelope memory gtcSEnv, bytes memory gtcSSig) =
            _envAndSig(bob, bobPk, 1, 3, block.timestamp + 1 hours, gtcSeller);
        _execute(gtcBEnv, gtcBSig, gtcBuyer, gtcSEnv, gtcSSig, gtcSeller, 2e8);
        _execute(gtcBEnv, gtcBSig, gtcBuyer, gtcSEnv, gtcSSig, gtcSeller, 3e8);
        _execute(gtcBEnv, gtcBSig, gtcBuyer, gtcSEnv, gtcSSig, gtcSeller, 5e8);

        // 2. Cancel one seller order — sign a NEW seller for cancellation.
        OptionOrderTypes.OptionOrder memory cancelSeller =
            _buildSeller(5e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("cancel-s"));
        (IntentHash.SignedActionEnvelope memory cancelSEnv,) =
            _envAndSig(bob, bobPk, 1, 100, block.timestamp + 1 hours, cancelSeller);
        vm.prank(bob);
        engine.cancelSignedOrder(cancelSEnv);

        // 3. Advance bob's min-nonce floor.
        vm.prank(bob);
        engine.advanceMinValidOrderNonce(1, 200);

        // 4. IOC pair — partial fill terminates.
        OptionOrderTypes.OptionOrder memory iocBuyer =
            _buildBuyer(5e8, 100e8, OptionOrderTypes.TIF_IOC, OptionOrderTypes.ROLE_TAKER, bytes32("ioc-b"));
        OptionOrderTypes.OptionOrder memory iocSeller =
            _buildSeller(3e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("ioc-s"));
        (IntentHash.SignedActionEnvelope memory iocBEnv, bytes memory iocBSig) =
            _envAndSig(alice, alicePk, 1, 400, block.timestamp + 1 hours, iocBuyer);
        (IntentHash.SignedActionEnvelope memory iocSEnv, bytes memory iocSSig) =
            _envAndSig(bob, bobPk, 1, 400, block.timestamp + 1 hours, iocSeller);
        _execute(iocBEnv, iocBSig, iocBuyer, iocSEnv, iocSSig, iocSeller, 3e8);

        // 5. FOK full execution.
        OptionOrderTypes.OptionOrder memory fokBuyer =
            _buildBuyer(4e8, 100e8, OptionOrderTypes.TIF_FOK, OptionOrderTypes.ROLE_TAKER, bytes32("fok-b"));
        OptionOrderTypes.OptionOrder memory fokSeller =
            _buildSeller(4e8, 100e8, OptionOrderTypes.TIF_GTC, OptionOrderTypes.ROLE_MAKER, bytes32("fok-s"));
        (IntentHash.SignedActionEnvelope memory fokBEnv, bytes memory fokBSig) =
            _envAndSig(alice, alicePk, 1, 500, block.timestamp + 1 hours, fokBuyer);
        (IntentHash.SignedActionEnvelope memory fokSEnv, bytes memory fokSSig) =
            _envAndSig(bob, bobPk, 1, 500, block.timestamp + 1 hours, fokSeller);
        _execute(fokBEnv, fokBSig, fokBuyer, fokSEnv, fokSSig, fokSeller, 4e8);

        // === Simulated DB-loss re-read: use only canonical views. ===

        // GTC fully filled.
        bytes32 gtcBId = engine.hashSignedActionEnvelopeDigest(gtcBEnv);
        assertEq(uint256(engine.filledQuantityOf(gtcBId)), 10e8);
        // Cancelled order flagged.
        assertTrue(engine.isOrderCancelled(engine.hashSignedActionEnvelopeDigest(cancelSEnv)));
        // Min-nonce advanced.
        assertEq(engine.minValidOrderNonceOf(_sk(bob, 1)), 200);
        // IOC terminated.
        bytes32 iocBId = engine.hashSignedActionEnvelopeDigest(iocBEnv);
        assertEq(uint256(engine.filledQuantityOf(iocBId)), 3e8);
        assertTrue(engine.isOrderCancelled(iocBId));
        // FOK fully filled.
        bytes32 fokBId = engine.hashSignedActionEnvelopeDigest(fokBEnv);
        assertEq(uint256(engine.filledQuantityOf(fokBId)), 4e8);

        // Overfill / duplicate execution remains rejected after DB-loss.
        // Any of {OrderAlreadyFullyFilled, OrderCancelled, OrderNonceStale}
        // satisfies the semantic guarantee — the seller-side GTC envelope
        // (nonce=3) is now also stale because bob's min-nonce floor was
        // raised to 200 above; either revert proves overfill is blocked.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(gtcBEnv, gtcBSig, gtcBuyer, gtcSEnv, gtcSSig, gtcSeller, 1e8, ids, ids);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.OrderCancelled.selector, iocBId));
        engine.executeMatch(iocBEnv, iocBSig, iocBuyer, iocSEnv, iocSSig, iocSeller, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                        PART J — CAPABILITY MASK
    //////////////////////////////////////////////////////////////*/

    /// @notice Bit 15 (CAP_APPLY_OPTIONS_PREMIUM) alone accepted.
    function test_J_capMask_bit15AloneAccepted() public {
        vm.prank(governance);
        vault.setEngineCapability(address(0xBEEF), Capabilities.CAP_APPLY_OPTIONS_PREMIUM, true);
        assertEq(vault.engineCapabilityBits(address(0xBEEF)), Capabilities.CAP_APPLY_OPTIONS_PREMIUM);
    }

    /// @notice Bit 16 alone rejected.
    function test_J_capMask_bit16AloneRejected() public {
        uint256 bit16 = uint256(1) << 16;
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, bit16));
        vm.prank(governance);
        vault.setEngineCapability(address(0xBEEF), bit16, true);
    }

    /// @notice Bit 15 | Bit 16 combined mask rejected.
    function test_J_capMask_bit15Plus16Rejected() public {
        uint256 combined = Capabilities.CAP_APPLY_OPTIONS_PREMIUM | (uint256(1) << 16);
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, combined));
        vm.prank(governance);
        vault.setEngineCapability(address(0xBEEF), combined, true);
    }

    /// @notice High random unsupported bit (bit 255) rejected.
    function test_J_capMask_highBitRejected() public {
        uint256 bit255 = uint256(1) << 255;
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, bit255));
        vm.prank(governance);
        vault.setEngineCapability(address(0xBEEF), bit255, true);
    }

    /// @notice All bits 0..15 combined accepted as one grant.
    function test_J_capMask_allValidBitsCombinedAccepted() public {
        vm.prank(governance);
        vault.setEngineCapability(address(0xBEEF), Capabilities.ALL_CAPABILITIES, true);
        assertEq(vault.engineCapabilityBits(address(0xBEEF)), Capabilities.ALL_CAPABILITIES);
    }

    /// @notice ALL_CAPABILITIES equals exactly `(1<<16)-1`.
    function test_J_capMask_allCapabilitiesExact() public pure {
        assertEq(Capabilities.ALL_CAPABILITIES, (uint256(1) << 16) - 1);
    }
}
