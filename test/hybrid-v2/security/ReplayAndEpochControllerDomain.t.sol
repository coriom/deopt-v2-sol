// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ReplayAndEpochControllerHarness} from "./harness/ReplayAndEpochControllerHarness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title ReplayAndEpochControllerDomain
/// @notice L4 cross-domain isolation tests — every intentionally distinct context MUST
///         produce a distinct EIP-712 digest. Enforces INV-AUTH-02 + INV-MIG-07 +
///         AT-40 (cross-deployment signature rejection).
contract ReplayAndEpochControllerDomain is Test {
    SubaccountRegistry internal registryA;
    SubaccountRegistry internal registryB;
    ReplayAndEpochControllerHarness internal engineA1; // registryA, domain "EngineA", version "1"
    ReplayAndEpochControllerHarness internal engineA2; // registryA, domain "EngineB", version "1" (different engine name)
    ReplayAndEpochControllerHarness internal engineB1; // registryB, domain "EngineA", version "1" (different registry)
    ReplayAndEpochControllerHarness internal engineA1v2; // registryA, domain "EngineA", version "2"

    address internal ownerA = address(0xAA);
    address internal ownerB = address(0xAB);
    address internal signerA = address(0xBA);

    function setUp() public {
        registryA = new SubaccountRegistry(address(0xDEAD));
        registryB = new SubaccountRegistry(address(0xDEAD));
        engineA1 = new ReplayAndEpochControllerHarness(address(registryA), "EngineA", "1", address(0));
        engineA2 = new ReplayAndEpochControllerHarness(address(registryA), "EngineB", "1", address(0));
        engineB1 = new ReplayAndEpochControllerHarness(address(registryB), "EngineA", "1", address(0));
        engineA1v2 = new ReplayAndEpochControllerHarness(address(registryA), "EngineA", "2", address(0));

        vm.prank(ownerA);
        registryA.registerNext();
        vm.prank(ownerB);
        registryA.registerNext();
        vm.prank(ownerA);
        registryB.registerNext();
    }

    function _makeEnvelope(address engine, address owner, uint32 id, bytes32 registryAddr)
        internal
        view
        returns (IntentHash.SignedActionEnvelope memory e)
    {
        e.owner = owner;
        e.subaccountId = id;
        e.subKey = SubKey.derive(block.chainid, address(uint160(uint256(registryAddr))), owner, id);
        e.signer = signerA;
        e.engine = engine;
        e.action = keccak256("ACTION");
        e.architectureVersion = Versions.ARCHITECTURE_VERSION;
        e.nonce = 0;
        e.deadline = block.timestamp + 3600;
        e.ownerRecoveryEpoch = 0;
        e.subaccountRecoveryEpoch = 0;
        e.payloadHash = keccak256("payload");
    }

    /*//////////////////////////////////////////////////////////////
                       DOMAIN SEPARATOR DIVERGES
    //////////////////////////////////////////////////////////////*/

    function test_domainSeparator_distinctPerEngineAddress() public view {
        assertTrue(
            engineA1.domainSeparator() != engineB1.domainSeparator(),
            "distinct verifyingContract produces distinct domain"
        );
    }

    function test_domainSeparator_distinctPerDomainName() public view {
        assertTrue(engineA1.domainSeparator() != engineA2.domainSeparator(), "distinct name produces distinct domain");
    }

    function test_domainSeparator_distinctPerDomainVersion() public view {
        assertTrue(
            engineA1.domainSeparator() != engineA1v2.domainSeparator(), "distinct version produces distinct domain"
        );
    }

    function test_domainSeparator_distinctPerChainId() public {
        bytes32 originalSeparator = engineA1.domainSeparator();
        vm.chainId(999);
        bytes32 alternateSeparator = engineA1.domainSeparator();
        assertTrue(originalSeparator != alternateSeparator, "distinct chainId produces distinct domain");
    }

    /*//////////////////////////////////////////////////////////////
                    ENVELOPE DIGEST SEPARATES CONTEXTS
    //////////////////////////////////////////////////////////////*/

    function test_digest_separatesAcrossVerifyingContract() public view {
        // Same envelope fields, different engine address inside the envelope + verifying contract.
        IntentHash.SignedActionEnvelope memory eA =
            _makeEnvelope(address(engineA1), ownerA, 1, bytes32(uint256(uint160(address(registryA)))));
        IntentHash.SignedActionEnvelope memory eB =
            _makeEnvelope(address(engineB1), ownerA, 1, bytes32(uint256(uint160(address(registryB)))));
        bytes32 dA = engineA1.hashSignedActionEnvelopeDigest(eA);
        bytes32 dB = engineB1.hashSignedActionEnvelopeDigest(eB);
        assertTrue(dA != dB, "cross-engine digests must diverge");
    }

    function test_digest_separatesAcrossDomainName() public view {
        // Same envelope fields, computed under engineA1 (name "EngineA") vs engineA2 (name "EngineB").
        IntentHash.SignedActionEnvelope memory e =
            _makeEnvelope(address(engineA1), ownerA, 1, bytes32(uint256(uint160(address(registryA)))));
        // Rebind engine for the second digest.
        IntentHash.SignedActionEnvelope memory e2 = e;
        e2.engine = address(engineA2);
        bytes32 dA = engineA1.hashSignedActionEnvelopeDigest(e);
        bytes32 dA2 = engineA2.hashSignedActionEnvelopeDigest(e2);
        assertTrue(dA != dA2);
    }

    function test_digest_separatesAcrossDomainVersion() public view {
        IntentHash.SignedActionEnvelope memory e =
            _makeEnvelope(address(engineA1), ownerA, 1, bytes32(uint256(uint160(address(registryA)))));
        IntentHash.SignedActionEnvelope memory e2 = e;
        e2.engine = address(engineA1v2);
        bytes32 dA = engineA1.hashSignedActionEnvelopeDigest(e);
        bytes32 dAv2 = engineA1v2.hashSignedActionEnvelopeDigest(e2);
        assertTrue(dA != dAv2);
    }

    function test_digest_separatesAcrossChainId() public {
        IntentHash.SignedActionEnvelope memory e =
            _makeEnvelope(address(engineA1), ownerA, 1, bytes32(uint256(uint160(address(registryA)))));
        bytes32 originalDigest = engineA1.hashSignedActionEnvelopeDigest(e);
        vm.chainId(999);
        bytes32 alternateDigest = engineA1.hashSignedActionEnvelopeDigest(e);
        assertTrue(originalDigest != alternateDigest);
    }

    function test_digest_separatesAcrossOwner() public view {
        IntentHash.SignedActionEnvelope memory eA =
            _makeEnvelope(address(engineA1), ownerA, 1, bytes32(uint256(uint160(address(registryA)))));
        IntentHash.SignedActionEnvelope memory eB =
            _makeEnvelope(address(engineA1), ownerB, 1, bytes32(uint256(uint160(address(registryA)))));
        assertTrue(
            engineA1.hashSignedActionEnvelopeDigest(eA) != engineA1.hashSignedActionEnvelopeDigest(eB),
            "distinct owner produces distinct digest"
        );
    }

    function test_digest_separatesAcrossSubaccountId() public {
        vm.prank(ownerA);
        registryA.registerNext(); // ownerA now has Account 2
        IntentHash.SignedActionEnvelope memory e1 =
            _makeEnvelope(address(engineA1), ownerA, 1, bytes32(uint256(uint160(address(registryA)))));
        IntentHash.SignedActionEnvelope memory e2 =
            _makeEnvelope(address(engineA1), ownerA, 2, bytes32(uint256(uint160(address(registryA)))));
        assertTrue(engineA1.hashSignedActionEnvelopeDigest(e1) != engineA1.hashSignedActionEnvelopeDigest(e2));
    }

    /*//////////////////////////////////////////////////////////////
                     SUBKEY BINDING DEPLOYMENT SEPARATION
    //////////////////////////////////////////////////////////////*/

    function test_subKeyBinding_deploymentScoped() public view {
        // Same (owner, subaccountId) under two different registries yields distinct subKeys.
        bytes32 k1 = registryA.subKeyOf(ownerA, 1);
        bytes32 k2 = registryB.subKeyOf(ownerA, 1);
        assertTrue(k1 != k2, "distinct registry produces distinct subKey");
    }

    /*//////////////////////////////////////////////////////////////
                          FIELD SEPARATION FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_digest_separates(
        address owner1,
        uint32 id1,
        address signer1,
        uint256 nonce1,
        uint256 deadline1,
        bytes32 action1,
        address owner2,
        uint32 id2,
        address signer2,
        uint256 nonce2,
        uint256 deadline2,
        bytes32 action2
    ) public view {
        // Force divergence in at least one field (otherwise digests must match).
        vm.assume(owner1 != address(0) && owner2 != address(0) && id1 > 0 && id2 > 0);
        IntentHash.SignedActionEnvelope memory e1;
        e1.owner = owner1;
        e1.subaccountId = id1;
        e1.subKey = SubKey.deriveHere(address(registryA), owner1, id1);
        e1.signer = signer1;
        e1.engine = address(engineA1);
        e1.action = action1;
        e1.architectureVersion = Versions.ARCHITECTURE_VERSION;
        e1.nonce = nonce1;
        e1.deadline = deadline1;
        e1.ownerRecoveryEpoch = 0;
        e1.subaccountRecoveryEpoch = 0;
        e1.payloadHash = bytes32(0);

        IntentHash.SignedActionEnvelope memory e2;
        e2.owner = owner2;
        e2.subaccountId = id2;
        e2.subKey = SubKey.deriveHere(address(registryA), owner2, id2);
        e2.signer = signer2;
        e2.engine = address(engineA1);
        e2.action = action2;
        e2.architectureVersion = Versions.ARCHITECTURE_VERSION;
        e2.nonce = nonce2;
        e2.deadline = deadline2;
        e2.ownerRecoveryEpoch = 0;
        e2.subaccountRecoveryEpoch = 0;
        e2.payloadHash = bytes32(0);

        bytes32 d1 = engineA1.hashSignedActionEnvelopeDigest(e1);
        bytes32 d2 = engineA1.hashSignedActionEnvelopeDigest(e2);

        bool identical = owner1 == owner2 && id1 == id2 && signer1 == signer2 && nonce1 == nonce2
            && deadline1 == deadline2 && action1 == action2;
        if (identical) {
            assertEq(d1, d2);
        } else {
            assertTrue(d1 != d2);
        }
    }
}
