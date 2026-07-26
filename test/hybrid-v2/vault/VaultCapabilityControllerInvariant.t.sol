// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";

import {VaultCapabilityControllerHarness} from "./harness/VaultCapabilityControllerHarness.sol";
import {VaultCapabilityControllerHandler} from "./handlers/VaultCapabilityControllerHandler.sol";

/// @title VaultCapabilityControllerInvariants
/// @notice Foundry invariant suite proving CAP-I1..CAP-I8 for the WP-03 subsystem.
/// @dev
///  CAP-I1 subset-of-ALL_CAPABILITIES
///  CAP-I2 non-governance never grows bitmap
///  CAP-I3 guardian never grows bitmap
///  CAP-I4 engine never mutates its own bitmap
///  CAP-I5 guardian revoke never touches registry identities or harness reservations
///  CAP-I6 hasCapabilities is exactly all-of subset semantics
///  CAP-I7 event-derived bitmap == storage bitmap (reconstruction)
///  CAP-I8 engine without CAP_REGISTER_DEFAULT_ACCOUNT cannot lazy-register a NEW owner
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
contract VaultCapabilityControllerInvariants is StdInvariant, Test {
    VaultCapabilityControllerHarness internal controller;
    SubaccountRegistry internal registry;
    VaultCapabilityControllerHandler internal handler;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);

    function setUp() external {
        controller = new VaultCapabilityControllerHarness(GOVERNANCE, GUARDIAN);
        registry = new SubaccountRegistry(address(controller));
        handler = new VaultCapabilityControllerHandler(controller, registry);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.governanceGrant.selector;
        selectors[1] = handler.governanceRevoke.selector;
        selectors[2] = handler.guardianRevoke.selector;
        selectors[3] = handler.attackerTryGrant.selector;
        selectors[4] = handler.attackerTryGuardianRevoke.selector;
        selectors[5] = handler.engineTrySelfGrant.selector;
        selectors[6] = handler.engineTryLazyRegister.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I1                                                           */
    /* ---------------------------------------------------------------- */

    function invariant_cap_i1_bitmapAlwaysSubsetOfAllCapabilities() external view {
        uint256 n = handler.engineCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 bits = controller.engineCapabilityBits(handler.engineAt(i));
            assertEq(bits & ~Capabilities.ALL_CAPABILITIES, uint256(0), "reserved bits leaked into storage");
        }
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I2 + CAP-I4 combined via ghost mirror                        */
    /* ---------------------------------------------------------------- */

    /// @notice Storage bitmap must ALWAYS equal the governance-driven ghost mirror.
    ///         If any unauthorized caller (attacker, engine self-grant, guardian
    ///         trying to grant) had succeeded, the mirror would lag storage.
    ///         Since the mirror only updates on successful governance/guardian
    ///         actions, this proves CAP-I2 (non-governance never grows) AND
    ///         CAP-I4 (engine cannot self-modify).
    function invariant_cap_i2_and_i4_ghostMirrorMatchesStorage() external view {
        uint256 n = handler.engineCount();
        for (uint256 i = 0; i < n; i++) {
            address engine = handler.engineAt(i);
            assertEq(
                controller.engineCapabilityBits(engine),
                handler.ghostBits(engine),
                "storage bitmap deviated from governance-tracked ghost"
            );
        }
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I3                                                           */
    /* ---------------------------------------------------------------- */

    /// @notice Guardian actions can only DECREASE the bitmap. The ghost mirror
    ///         only grows on successful governance grants; guardian revocations
    ///         zero the mirror. Therefore for every engine, current storage bits
    ///         must be a SUBSET of the union of all governance-granted bits.
    /// @dev    Equivalent CAP-I3 assertion: storage bits ⊆ ghostBits (ghostBits
    ///         is the frontier of "governance-authorized" bits). Because the ghost
    ///         updates on both grants + revocations, storage == ghost is a stronger
    ///         claim already proved by CAP-I2. We assert the subset here for clarity.
    function invariant_cap_i3_storageIsSubsetOfGhost() external view {
        uint256 n = handler.engineCount();
        for (uint256 i = 0; i < n; i++) {
            address engine = handler.engineAt(i);
            uint256 stored = controller.engineCapabilityBits(engine);
            uint256 ghost = handler.ghostBits(engine);
            assertEq(stored & ~ghost, uint256(0), "storage has bits that governance never granted");
        }
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I5                                                           */
    /* ---------------------------------------------------------------- */

    /// @notice Registry identities are inert w.r.t. capability mutations. This is
    ///         structural (registry has no admin path from the controller), but
    ///         re-asserted here for defense-in-depth.
    function invariant_cap_i5_registryAndReservationsIntact() external view {
        // Any engine that has been successfully lazy-registered for an owner must
        // still be visible in the registry (no capability mutation erased it).
        uint256 nOwners = handler.ownerCount();
        for (uint256 i = 0; i < nOwners; i++) {
            address owner = handler.ownerAt(i);
            if (handler.ghostLazyRegistered(owner)) {
                assertTrue(registry.existsOf(owner, 1), "lazy-registered account MUST remain registered");
            }
        }

        // Harness reservation counter is never touched by the abstract itself.
        uint256 nEngines = handler.engineCount();
        for (uint256 i = 0; i < nEngines; i++) {
            address engine = handler.engineAt(i);
            // We only need to prove the abstract never wrote here. Since only
            // `testSeedReservation` can write, and neither the handler nor the
            // controller calls it during fuzzing, the value MUST equal zero.
            assertEq(controller.testReservationOf(engine), uint256(0), "capability layer must not touch reservations");
        }
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I6                                                           */
    /* ---------------------------------------------------------------- */

    /// @notice `hasCapabilities` returns true iff every bit of the required
    ///         mask is a defined bit AND is present in the engine's bitmap.
    function invariant_cap_i6_hasCapabilitiesIsAllOfSubset() external view {
        uint256 n = handler.engineCount();
        for (uint256 i = 0; i < n; i++) {
            address engine = handler.engineAt(i);
            uint256 bits = controller.engineCapabilityBits(engine);

            // Empty mask always false.
            assertFalse(controller.hasCapabilities(engine, 0));

            // Reserved-bit mask always false.
            assertFalse(controller.hasCapabilities(engine, 1 << 15));

            // Every currently-present bit taken alone must satisfy the check.
            for (uint8 b = 0; b <= Capabilities.HIGHEST_ASSIGNED_BIT; b++) {
                uint256 singleBit = uint256(1) << b;
                bool expected = (bits & singleBit) != 0;
                assertEq(controller.hasCapabilities(engine, singleBit), expected, "single-bit hasCapabilities mismatch");
            }

            // Whole engine bitmap must satisfy itself iff non-empty.
            if (bits != 0) {
                assertTrue(controller.hasCapabilities(engine, bits));
            } else {
                assertFalse(controller.hasCapabilities(engine, bits));
            }
        }
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I7                                                           */
    /* ---------------------------------------------------------------- */

    /// @notice Storage bitmap must equal the mirror derived from the emitted
    ///         `EngineCapabilityChanged` add/remove masks. This proves the event
    ///         stream is sufficient for off-chain indexers to reconstruct state.
    function invariant_cap_i7_eventDerivedBitmapMatchesStorage() external view {
        uint256 n = handler.engineCount();
        for (uint256 i = 0; i < n; i++) {
            address engine = handler.engineAt(i);
            assertEq(
                controller.engineCapabilityBits(engine),
                handler.ghostBitsFromEvents(engine),
                "event-derived reconstruction diverged from storage"
            );
        }
    }

    /* ---------------------------------------------------------------- */
    /* CAP-I8                                                           */
    /* ---------------------------------------------------------------- */

    /// @notice For every engine without CAP_REGISTER_DEFAULT_ACCOUNT, invoking
    ///         `registerLazyDefault` for a NEVER-registered owner MUST revert
    ///         with `NotAuthorized`. We select a fresh, out-of-band owner
    ///         address per invariant tick.
    function invariant_cap_i8_revokedEngineCannotLazyRegister() external {
        uint256 n = handler.engineCount();
        for (uint256 i = 0; i < n; i++) {
            address engine = handler.engineAt(i);
            uint256 bits = controller.engineCapabilityBits(engine);
            if ((bits & Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT) != 0) continue;

            // Deterministic fresh owner address: derived from engine + block to
            // avoid colliding with owners already lazy-registered in the run.
            address freshOwner = address(uint160(uint256(keccak256(abi.encode("cap-i8", engine, block.timestamp)))));
            if (registry.existsOf(freshOwner, 1)) continue;

            vm.prank(engine);
            (bool ok, bytes memory ret) =
                address(registry).call(abi.encodeWithSignature("registerLazyDefault(address)", freshOwner));
            assertFalse(ok, "revoked engine must not succeed at lazy registration");
            // Decode revert selector.
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 32))
            }
            assertEq(sel, bytes4(keccak256("NotAuthorized()")), "wrong revert selector");
        }
    }
}
