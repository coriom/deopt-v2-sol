// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";

/// @title SubKeyTest
/// @notice Pure derivation tests for the canonical subKey formula.
/// @dev Exercises INV-ID-02 (deterministic id) + confirms abi.encode semantics.
contract SubKeyTest is Test {
    address internal constant REGISTRY_A = address(0xAAA1);
    address internal constant REGISTRY_B = address(0xBBB2);
    address internal constant OWNER_A = address(0xC0DE);
    address internal constant OWNER_B = address(0xD0DE);

    /* ---------------------------------------------------------------------- */
    /* Canonical formula                                                      */
    /* ---------------------------------------------------------------------- */

    function test_derive_matchesCanonicalFormula() external pure {
        uint256 chainId = 84532; // Base Sepolia
        address registry = REGISTRY_A;
        address owner = OWNER_A;
        uint32 subaccountId = 1;

        bytes32 expected = keccak256(abi.encode(chainId, registry, owner, subaccountId));
        bytes32 actual = SubKey.derive(chainId, registry, owner, subaccountId);

        assertEq(actual, expected, "derive must match keccak256(abi.encode(...))");
    }

    function test_derive_notEqualToPackedForm() external pure {
        // Regression guard: abi.encode MUST differ from abi.encodePacked.
        uint256 chainId = 84532;
        address registry = REGISTRY_A;
        address owner = OWNER_A;
        uint32 subaccountId = 1;

        bytes32 encoded = SubKey.derive(chainId, registry, owner, subaccountId);
        bytes32 packed = keccak256(abi.encodePacked(chainId, registry, owner, subaccountId));

        assertTrue(encoded != packed, "abi.encode result MUST NOT equal abi.encodePacked result");
    }

    /* ---------------------------------------------------------------------- */
    /* Field-order determinism                                                */
    /* ---------------------------------------------------------------------- */

    function test_derive_differentChainIdsProduceDifferentKeys() external pure {
        bytes32 a = SubKey.derive(84532, REGISTRY_A, OWNER_A, 1);
        bytes32 b = SubKey.derive(8453, REGISTRY_A, OWNER_A, 1);
        assertTrue(a != b, "chain id must be part of derivation");
    }

    function test_derive_differentRegistriesProduceDifferentKeys() external pure {
        bytes32 a = SubKey.derive(84532, REGISTRY_A, OWNER_A, 1);
        bytes32 b = SubKey.derive(84532, REGISTRY_B, OWNER_A, 1);
        assertTrue(a != b, "registry must be part of derivation");
    }

    function test_derive_differentOwnersProduceDifferentKeys() external pure {
        bytes32 a = SubKey.derive(84532, REGISTRY_A, OWNER_A, 1);
        bytes32 b = SubKey.derive(84532, REGISTRY_A, OWNER_B, 1);
        assertTrue(a != b, "owner must be part of derivation");
    }

    function test_derive_differentSubaccountIdsProduceDifferentKeys() external pure {
        bytes32 a = SubKey.derive(84532, REGISTRY_A, OWNER_A, 1);
        bytes32 b = SubKey.derive(84532, REGISTRY_A, OWNER_A, 2);
        assertTrue(a != b, "subaccount id must be part of derivation");
    }

    /* ---------------------------------------------------------------------- */
    /* deriveHere binds block.chainid                                         */
    /* ---------------------------------------------------------------------- */

    function test_deriveHere_matchesExplicitCurrentChain() external {
        vm.chainId(84532);

        bytes32 explicit_ = SubKey.derive(84532, REGISTRY_A, OWNER_A, 1);
        bytes32 here = SubKey.deriveHere(REGISTRY_A, OWNER_A, 1);

        assertEq(here, explicit_, "deriveHere must match derive using block.chainid");
    }

    function test_deriveHere_reactsToChainIdChange() external {
        vm.chainId(84532);
        bytes32 sepolia = SubKey.deriveHere(REGISTRY_A, OWNER_A, 1);

        vm.chainId(8453);
        bytes32 mainnet = SubKey.deriveHere(REGISTRY_A, OWNER_A, 1);

        assertTrue(sepolia != mainnet, "deriveHere must reflect chain id change");
    }

    /* ---------------------------------------------------------------------- */
    /* Zero-owner + Account-0 semantics remain the caller's responsibility    */
    /* ---------------------------------------------------------------------- */

    function test_derive_zeroOwnerIsHashable() external pure {
        // The library does NOT filter zero owner; registry enforces validity.
        // This test documents that the pure helper accepts the value; downstream
        // registry MUST reject with InvalidOwner().
        bytes32 key = SubKey.derive(84532, REGISTRY_A, address(0), 1);
        assertTrue(key != bytes32(0), "derivation must succeed even for a value the registry will reject");
    }

    function test_derive_accountZeroIsHashable() external pure {
        // The library does NOT filter subaccountId == 0; registry enforces validity.
        bytes32 key = SubKey.derive(84532, REGISTRY_A, OWNER_A, 0);
        assertTrue(key != bytes32(0), "derivation must succeed even for account 0 (registry rejects)");
    }

    /* ---------------------------------------------------------------------- */
    /* Fuzz                                                                   */
    /* ---------------------------------------------------------------------- */

    function testFuzz_derive_deterministic(uint256 chainId, address registry, address owner, uint32 subaccountId)
        external
        pure
    {
        bytes32 a = SubKey.derive(chainId, registry, owner, subaccountId);
        bytes32 b = SubKey.derive(chainId, registry, owner, subaccountId);
        assertEq(a, b, "derivation must be deterministic under identical inputs");
    }

    function testFuzz_derive_differentSubaccountIdsCollisionResistant(
        uint256 chainId,
        address registry,
        address owner,
        uint32 idA,
        uint32 idB
    ) external pure {
        vm.assume(idA != idB);
        bytes32 a = SubKey.derive(chainId, registry, owner, idA);
        bytes32 b = SubKey.derive(chainId, registry, owner, idB);
        assertTrue(a != b, "distinct subaccount ids must yield distinct subKeys");
    }
}
