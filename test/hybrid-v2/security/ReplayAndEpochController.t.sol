// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ReplayAndEpochControllerHarness} from "./harness/ReplayAndEpochControllerHarness.sol";
import {ReplayAndEpochController} from "../../../src/hybrid-v2/security/ReplayAndEpochController.sol";
import {IReplayAndEpochController} from "../../../src/hybrid-v2/security/IReplayAndEpochController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {EIP712Types} from "../../../src/hybrid-v2/libraries/EIP712Types.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title ReplayAndEpochControllerUnitFuzz
/// @notice L1 unit + L3 fuzz suite covering the WP-05 replay + epoch foundation.
contract ReplayAndEpochControllerUnitFuzz is Test {
    ReplayAndEpochControllerHarness internal controller;
    SubaccountRegistry internal registry;

    address internal governance = address(0xA1);
    address internal recoveryAuthority = address(0xA2);

    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);
    address internal signerA = address(0xC1);
    address internal signerB = address(0xC2);

    string internal constant DOMAIN_NAME = "DeOptV2-TestEngine";
    string internal constant DOMAIN_VERSION = "1";

    function setUp() public {
        // Registry needs a non-zero capabilityAuthority; use a placeholder — we do not
        // exercise `registerLazyDefault` in the controller tests.
        registry = new SubaccountRegistry(address(0xDEAD));
        controller =
            new ReplayAndEpochControllerHarness(address(registry), DOMAIN_NAME, DOMAIN_VERSION, recoveryAuthority);

        vm.prank(ownerA);
        registry.registerNext(); // Account 1
        vm.prank(ownerA);
        registry.registerNext(); // Account 2
        vm.prank(ownerB);
        registry.registerNext(); // Account 1
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR + IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    function test_constructor_recordsImmutables() public view {
        assertEq(controller.registry(), address(registry), "registry immutable");
        assertEq(controller.architectureVersion(), Versions.ARCHITECTURE_VERSION, "architecture immutable");
    }

    function test_constructor_rejectsZeroRegistry() public {
        vm.expectRevert(ReplayAndEpochController.InvalidRegistry.selector);
        new ReplayAndEpochControllerHarness(address(0), DOMAIN_NAME, DOMAIN_VERSION, recoveryAuthority);
    }

    /*//////////////////////////////////////////////////////////////
                              NONCES
    //////////////////////////////////////////////////////////////*/

    function test_nonces_initialZero() public view {
        assertEq(controller.nonces(signerA), 0);
        assertEq(controller.nonces(signerB), 0);
    }

    function test_consumeNonce_advancesSequentially() public {
        controller.consumeNonce(signerA, 0);
        assertEq(controller.nonces(signerA), 1);
        controller.consumeNonce(signerA, 1);
        assertEq(controller.nonces(signerA), 2);
    }

    function test_consumeNonce_wrongExpectedReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.BadNonce.selector, signerA, 0, 5));
        controller.consumeNonce(signerA, 5);
    }

    function test_consumeNonce_zeroSignerReverts() public {
        vm.expectRevert(ReplayAndEpochController.SignerZero.selector);
        controller.consumeNonce(address(0), 0);
    }

    function test_consumeNonce_distinctSignersIsolated() public {
        controller.consumeNonce(signerA, 0);
        controller.consumeNonce(signerA, 1);
        assertEq(controller.nonces(signerA), 2);
        assertEq(controller.nonces(signerB), 0);
        controller.consumeNonce(signerB, 0);
        assertEq(controller.nonces(signerB), 1);
        assertEq(controller.nonces(signerA), 2);
    }

    function test_cancelNextNonce_advancesByOne() public {
        vm.prank(signerA);
        controller.cancelNextNonce();
        assertEq(controller.nonces(signerA), 1);
    }

    function test_cancelNextNonce_emitsNonceCancelled() public {
        vm.expectEmit(true, false, false, true);
        emit IReplayAndEpochController.NonceCancelled(signerA, 0, 1, signerA, Versions.EVENT_VERSION);
        vm.prank(signerA);
        controller.cancelNextNonce();
    }

    function test_cancelNoncesUpTo_setsFloor() public {
        vm.prank(signerA);
        controller.cancelNoncesUpTo(7);
        assertEq(controller.nonces(signerA), 7);
    }

    function test_cancelNoncesUpTo_belowCurrentReverts() public {
        vm.prank(signerA);
        controller.cancelNoncesUpTo(5);
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.NonceCancelNoOp.selector, signerA, 5, 3));
        vm.prank(signerA);
        controller.cancelNoncesUpTo(3);
    }

    function test_cancelNoncesUpTo_equalCurrentReverts() public {
        vm.prank(signerA);
        controller.cancelNoncesUpTo(5);
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.NonceCancelNoOp.selector, signerA, 5, 5));
        vm.prank(signerA);
        controller.cancelNoncesUpTo(5);
    }

    function test_consumeNonce_overflowReverts() public {
        // Warp nonce to max via cancelNoncesUpTo, then attempt to consume.
        vm.prank(signerA);
        controller.cancelNoncesUpTo(type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ReplayAndEpochController.NonceOverflow.selector, signerA, type(uint256).max)
        );
        controller.consumeNonce(signerA, type(uint256).max);
    }

    function test_cancelNextNonce_overflowReverts() public {
        vm.prank(signerA);
        controller.cancelNoncesUpTo(type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(ReplayAndEpochController.NonceOverflow.selector, signerA, type(uint256).max)
        );
        vm.prank(signerA);
        controller.cancelNextNonce();
    }

    /*//////////////////////////////////////////////////////////////
                         INTENT-HASH CONSUMPTION
    //////////////////////////////////////////////////////////////*/

    function test_consumeIntent_marksConsumedAndEmits() public {
        bytes32 h = keccak256("intent-1");
        bytes32 action = keccak256("SUBMIT_OPTION_ORDER");
        vm.expectEmit(true, true, true, true);
        emit IReplayAndEpochController.IntentConsumed(h, signerA, address(controller), action, Versions.EVENT_VERSION);
        controller.consumeIntent(h, signerA, action);
        assertTrue(controller.isIntentConsumed(h));
    }

    function test_consumeIntent_duplicateReverts() public {
        bytes32 h = keccak256("intent-1");
        controller.consumeIntent(h, signerA, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.IntentReplayed.selector, h));
        controller.consumeIntent(h, signerA, bytes32(0));
    }

    function test_consumeIntent_zeroReverts() public {
        vm.expectRevert(ReplayAndEpochController.ZeroIntentHash.selector);
        controller.consumeIntent(bytes32(0), signerA, bytes32(0));
    }

    function test_consumeIntent_distinctHashesIndependent() public {
        bytes32 h1 = keccak256("intent-1");
        bytes32 h2 = keccak256("intent-2");
        controller.consumeIntent(h1, signerA, bytes32(0));
        controller.consumeIntent(h2, signerA, bytes32(0));
        assertTrue(controller.isIntentConsumed(h1));
        assertTrue(controller.isIntentConsumed(h2));
    }

    /*//////////////////////////////////////////////////////////////
                        RECOVERY EPOCH: OWNER PATH
    //////////////////////////////////////////////////////////////*/

    function test_advanceMyOwnerRecoveryEpoch_incrementsAndEmits() public {
        assertEq(controller.ownerRecoveryEpoch(ownerA), 0);
        vm.expectEmit(true, false, false, true);
        emit IReplayAndEpochController.OwnerRecoveryEpochAdvanced(ownerA, 0, 1, ownerA, Versions.EVENT_VERSION);
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        assertEq(controller.ownerRecoveryEpoch(ownerA), 1);
    }

    function test_advanceMyOwnerRecoveryEpoch_isMonotonic() public {
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        assertEq(controller.ownerRecoveryEpoch(ownerA), 2);
    }

    function test_advanceMyOwnerRecoveryEpoch_siblingsIndependent() public {
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        assertEq(controller.ownerRecoveryEpoch(ownerA), 1);
        assertEq(controller.ownerRecoveryEpoch(ownerB), 0);
    }

    function test_advanceMySubaccountRecoveryEpoch_incrementsAndEmits() public {
        bytes32 subKey = registry.subKeyOf(ownerA, 1);
        assertEq(controller.subaccountRecoveryEpoch(subKey), 0);
        vm.expectEmit(true, true, false, true);
        emit IReplayAndEpochController.SubaccountRecoveryEpochAdvanced(
            subKey, ownerA, 1, 0, 1, ownerA, Versions.EVENT_VERSION
        );
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);
        assertEq(controller.subaccountRecoveryEpoch(subKey), 1);
    }

    function test_advanceMySubaccountRecoveryEpoch_siblingSubaccountUnaffected() public {
        bytes32 subKey1 = registry.subKeyOf(ownerA, 1);
        bytes32 subKey2 = registry.subKeyOf(ownerA, 2);
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);
        assertEq(controller.subaccountRecoveryEpoch(subKey1), 1);
        assertEq(controller.subaccountRecoveryEpoch(subKey2), 0);
    }

    function test_advanceMySubaccountRecoveryEpoch_zeroIdReverts() public {
        vm.prank(ownerA);
        vm.expectRevert(ReplayAndEpochController.InvalidSubaccountId.selector);
        controller.advanceMySubaccountRecoveryEpoch(0);
    }

    function test_advanceMySubaccountRecoveryEpoch_nonexistentReverts() public {
        vm.prank(ownerA);
        vm.expectRevert(
            abi.encodeWithSelector(ReplayAndEpochController.SubaccountNotFoundForOwner.selector, ownerA, 99)
        );
        controller.advanceMySubaccountRecoveryEpoch(99);
    }

    function test_advanceMySubaccountRecoveryEpoch_wrongOwnerRejected() public {
        // ownerA has subaccount 1; ownerB does not. ownerB cannot advance ownerA's epoch.
        vm.prank(ownerB);
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.SubaccountNotFoundForOwner.selector, ownerB, 2));
        controller.advanceMySubaccountRecoveryEpoch(2); // ownerB only has 1
    }

    /*//////////////////////////////////////////////////////////////
                    RECOVERY EPOCH: AUTHORITY PATH
    //////////////////////////////////////////////////////////////*/

    function test_authorityAdvanceOwnerRecoveryEpoch_authorized() public {
        vm.prank(recoveryAuthority);
        controller.authorityAdvanceOwnerRecoveryEpoch(ownerA);
        assertEq(controller.ownerRecoveryEpoch(ownerA), 1);
    }

    function test_authorityAdvanceOwnerRecoveryEpoch_unauthorizedReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayAndEpochControllerHarness.UnauthorizedRecoveryActor.selector, recoveryAuthority, address(this)
            )
        );
        controller.authorityAdvanceOwnerRecoveryEpoch(ownerA);
    }

    function test_authorityAdvanceSubaccountRecoveryEpoch_authorized() public {
        bytes32 subKey = registry.subKeyOf(ownerA, 1);
        vm.prank(recoveryAuthority);
        controller.authorityAdvanceSubaccountRecoveryEpoch(subKey, ownerA, 1);
        assertEq(controller.subaccountRecoveryEpoch(subKey), 1);
    }

    function test_authorityAdvanceSubaccountRecoveryEpoch_unauthorizedReverts() public {
        bytes32 subKey = registry.subKeyOf(ownerA, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayAndEpochControllerHarness.UnauthorizedRecoveryActor.selector, recoveryAuthority, address(this)
            )
        );
        controller.authorityAdvanceSubaccountRecoveryEpoch(subKey, ownerA, 1);
    }

    /*//////////////////////////////////////////////////////////////
                          DEADLINE VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_deadlineValidation_futureAccepted() public view {
        controller.requireDeadlineNotExpired(block.timestamp + 1);
    }

    function test_deadlineValidation_currentBlockAccepted() public view {
        controller.requireDeadlineNotExpired(block.timestamp);
    }

    function test_deadlineValidation_pastReverts() public {
        vm.warp(1000);
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.DeadlineExpired.selector, 999, 1000));
        controller.requireDeadlineNotExpired(999);
    }

    function test_deadlineValidation_zeroRejectedAtNonZeroTime() public {
        vm.warp(100);
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.DeadlineExpired.selector, 0, 100));
        controller.requireDeadlineNotExpired(0);
    }

    /*//////////////////////////////////////////////////////////////
                     ENVELOPE BINDING + EPOCH FRESHNESS
    //////////////////////////////////////////////////////////////*/

    function _makeEnvelope() internal view returns (IntentHash.SignedActionEnvelope memory e) {
        e.owner = ownerA;
        e.subaccountId = 1;
        e.subKey = registry.subKeyOf(ownerA, 1);
        e.signer = signerA;
        e.engine = address(controller);
        e.action = keccak256("SUBMIT_OPTION_ORDER");
        e.architectureVersion = Versions.ARCHITECTURE_VERSION;
        e.nonce = 0;
        e.deadline = block.timestamp + 3600;
        e.ownerRecoveryEpoch = 0;
        e.subaccountRecoveryEpoch = 0;
        e.payloadHash = keccak256(abi.encode("payload"));
    }

    function test_envelopeBindingValid_accepts() public view {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        controller.requireEnvelopeBindingValid(e);
    }

    function test_envelopeBindingValid_wrongEngineReverts() public {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        e.engine = address(0xEEE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayAndEpochController.InvalidEngineBinding.selector, address(controller), address(0xEEE)
            )
        );
        controller.requireEnvelopeBindingValid(e);
    }

    function test_envelopeBindingValid_wrongArchitectureVersionReverts() public {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        e.architectureVersion = 2;
        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayAndEpochController.InvalidArchitectureVersion.selector, Versions.ARCHITECTURE_VERSION, 2
            )
        );
        controller.requireEnvelopeBindingValid(e);
    }

    function test_envelopeBindingValid_zeroSubaccountReverts() public {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        e.subaccountId = 0;
        vm.expectRevert(ReplayAndEpochController.InvalidSubaccountId.selector);
        controller.requireEnvelopeBindingValid(e);
    }

    function test_envelopeBindingValid_zeroOwnerReverts() public {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        e.owner = address(0);
        vm.expectRevert(ReplayAndEpochController.InvalidOwnerAddress.selector);
        controller.requireEnvelopeBindingValid(e);
    }

    function test_envelopeBindingValid_wrongSubKeyReverts() public {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        bytes32 expected = e.subKey;
        e.subKey = bytes32(uint256(0xdeadbeef));
        vm.expectRevert(
            abi.encodeWithSelector(
                ReplayAndEpochController.SubKeyMismatch.selector, expected, bytes32(uint256(0xdeadbeef))
            )
        );
        controller.requireEnvelopeBindingValid(e);
    }

    function test_epochsFresh_matchingAccepted() public view {
        controller.requireEpochsFresh(ownerA, registry.subKeyOf(ownerA, 1), 0, 0);
    }

    function test_epochsFresh_staleOwnerReverts() public {
        bytes32 subKey = registry.subKeyOf(ownerA, 1);
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch(); // owner epoch = 1
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.StaleOwnerRecoveryEpoch.selector, ownerA, 1, 0));
        controller.requireEpochsFresh(ownerA, subKey, 0, 0);
    }

    function test_epochsFresh_staleSubaccountReverts() public {
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1); // sub epoch = 1
        bytes32 subKey = registry.subKeyOf(ownerA, 1);
        vm.expectRevert(
            abi.encodeWithSelector(ReplayAndEpochController.StaleSubaccountRecoveryEpoch.selector, subKey, 1, 0)
        );
        controller.requireEpochsFresh(ownerA, subKey, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       DIGEST + DOMAIN SEPARATION
    //////////////////////////////////////////////////////////////*/

    function test_digest_deterministic() public view {
        IntentHash.SignedActionEnvelope memory e = _makeEnvelope();
        bytes32 d1 = controller.hashSignedActionEnvelopeDigest(e);
        bytes32 d2 = controller.hashSignedActionEnvelopeDigest(e);
        assertEq(d1, d2);
    }

    function test_digest_changesWithNonce() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.nonce = 1;
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_digest_changesWithDeadline() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.deadline += 1;
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_digest_changesWithOwnerRecoveryEpoch() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.ownerRecoveryEpoch = 1;
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_digest_changesWithSubaccountRecoveryEpoch() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.subaccountRecoveryEpoch = 1;
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_digest_changesWithSigner() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.signer = signerB;
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_digest_changesWithAction() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.action = keccak256("DIFFERENT_ACTION");
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_digest_changesWithPayloadHash() public view {
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory b = _makeEnvelope();
        b.payloadHash = keccak256("different");
        assertTrue(controller.hashSignedActionEnvelopeDigest(a) != controller.hashSignedActionEnvelopeDigest(b));
    }

    function test_typeHash_matchesTypeString() public pure {
        bytes32 fromConst = EIP712Types.SIGNED_ACTION_ENVELOPE_TYPEHASH;
        bytes32 fromString = keccak256(bytes(EIP712Types.SIGNED_ACTION_ENVELOPE_TYPE));
        assertEq(fromConst, fromString);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_nonces_isolatedPerSigner(address a, address b) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        controller.consumeNonce(a, 0);
        assertEq(controller.nonces(a), 1);
        assertEq(controller.nonces(b), 0);
    }

    function testFuzz_epochsMonotonic(uint8 rounds) public {
        vm.assume(rounds > 0 && rounds < 32);
        uint256 startOwner = controller.ownerRecoveryEpoch(ownerA);
        for (uint256 i = 0; i < rounds; i++) {
            vm.prank(ownerA);
            controller.advanceMyOwnerRecoveryEpoch();
        }
        assertEq(controller.ownerRecoveryEpoch(ownerA), startOwner + rounds);
    }

    function testFuzz_digestChanges_arbitraryFields(uint256 nonce, uint256 deadline, uint256 oe, uint256 se)
        public
        view
    {
        IntentHash.SignedActionEnvelope memory base = _makeEnvelope();
        IntentHash.SignedActionEnvelope memory a = _makeEnvelope();
        a.nonce = nonce;
        a.deadline = deadline;
        a.ownerRecoveryEpoch = oe;
        a.subaccountRecoveryEpoch = se;
        bytes32 baseDigest = controller.hashSignedActionEnvelopeDigest(base);
        bytes32 aDigest = controller.hashSignedActionEnvelopeDigest(a);
        // Any change other than exactly identical (nonce=0, deadline=default, oe=0, se=0) MUST produce different digest.
        bool changed = nonce != base.nonce || deadline != base.deadline || oe != base.ownerRecoveryEpoch
            || se != base.subaccountRecoveryEpoch;
        if (changed) {
            assertTrue(baseDigest != aDigest);
        } else {
            assertEq(baseDigest, aDigest);
        }
    }

    function testFuzz_intentConsumption_duplicateRejected(bytes32 h) public {
        vm.assume(h != bytes32(0));
        controller.consumeIntent(h, signerA, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.IntentReplayed.selector, h));
        controller.consumeIntent(h, signerA, bytes32(0));
    }
}
