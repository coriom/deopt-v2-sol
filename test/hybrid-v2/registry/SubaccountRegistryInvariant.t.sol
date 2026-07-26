// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";

import {MockCapabilityAuthority} from "./mocks/MockCapabilityAuthority.sol";
import {SubaccountRegistryHandler} from "./handlers/SubaccountRegistryHandler.sol";

/// @title SubaccountRegistryInvariants
/// @notice Foundry invariant suite proving REG-I1..REG-I7 for the WP-02 registry.
/// @dev REG-I1: no owner ever has a registered Account 0.
///      REG-I2: registered ids form a contiguous [1, lastRegisteredId] range per owner.
///      REG-I3: no two distinct (owner, subaccountId) identities collide within the tested domain.
///      REG-I4: a registered identity never becomes unregistered.
///      REG-I5: registration never rewrites the canonical owner of a prior identity.
///      REG-I6: the registry never accumulates native balance / never mutates token state.
///      REG-I7: the event-observable registration count matches canonical registry state.
///
///      Fuzz budget is tuned locally because REG-I3 walks the ghost set in O(n^2). The
///      chosen runs/depth still yield thousands of exercised handler calls per invariant
///      while keeping wall-clock bounded.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
contract SubaccountRegistryInvariants is StdInvariant, Test {
    SubaccountRegistry internal registry;
    MockCapabilityAuthority internal authority;
    SubaccountRegistryHandler internal handler;

    function setUp() external {
        authority = new MockCapabilityAuthority();
        registry = new SubaccountRegistry(address(authority));

        handler = new SubaccountRegistryHandler(registry, authority);

        // Wire capability grants for handler engines.
        // Handler declares engine[0] and engine[1] authorized; engine[2] unauthorized.
        authority.setBits(address(0xE001), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);
        authority.setBits(address(0xE002), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.registerNext.selector;
        selectors[1] = handler.registerLazyDefault.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I1                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I1: no actor ever gains a registered Account 0.
    function invariant_reg_i1_accountZeroNeverRegistered() external view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actorAt(i);
            assertFalse(registry.existsOf(actor, uint32(0)), "Account 0 must never be registered");
        }
        // Also assert for a few adversarial addresses outside the handler set.
        assertFalse(registry.existsOf(address(0), uint32(0)));
        assertFalse(registry.existsOf(address(this), uint32(0)));
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I2                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I2: registered ids per owner are exactly [1, lastRegisteredId] (no holes; no reuse).
    function invariant_reg_i2_registeredIdsContiguous() external view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actorAt(i);
            uint32 next = registry.nextIdFor(actor);
            if (next == 1) {
                // Never registered; nothing to check.
                continue;
            }
            // Every id in [1, next) must exist.
            for (uint32 id = 1; id < next; id++) {
                assertTrue(registry.existsOf(actor, id), "gap detected in registered range");
            }
            // The id at `next` must NOT exist yet.
            assertFalse(registry.existsOf(actor, next), "next id must not yet exist");
        }
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I3                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I3: within the tested domain, no two distinct (owner, id) collide onto the same subKey.
    /// @dev Bounded O(n^2) over the ghost set of registered subKeys.
    function invariant_reg_i3_subKeysDistinctWithinDomain() external view {
        uint256 n = handler.ghostSubKeyCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 keyI = handler.ghostSubKeyAt(i);
            for (uint256 j = i + 1; j < n; j++) {
                bytes32 keyJ = handler.ghostSubKeyAt(j);
                assertTrue(keyI != keyJ, "distinct identities must not collide on subKey");
            }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I4                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I4: registered identities never become unregistered.
    function invariant_reg_i4_registeredIdentitiesNeverUnregister() external view {
        uint256 n = handler.ghostSubKeyCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 key = handler.ghostSubKeyAt(i);
            address expectedOwner = handler.ghostOwnerOf(key);
            uint32 expectedId = handler.ghostSubaccountIdOf(key);
            assertTrue(registry.existsOf(expectedOwner, expectedId), "registered id must remain registered");
        }
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I5                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I5: the canonical owner of a prior identity is never rewritten.
    function invariant_reg_i5_ownerNeverRewritten() external view {
        uint256 n = handler.ghostSubKeyCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 key = handler.ghostSubKeyAt(i);
            assertEq(registry.ownerOf(key), handler.ghostOwnerOf(key), "owner must never change");
            assertEq(registry.subaccountIdOf(key), handler.ghostSubaccountIdOf(key), "subaccountId must never change");
        }
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I6                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I6: the registry never accumulates value nor mutates token state.
    /// @dev Native balance check is structural — the registry has no payable path.
    ///      Token state coverage is negative (there is no token deployment in this suite).
    function invariant_reg_i6_registryHoldsNoValue() external view {
        assertEq(address(registry).balance, uint256(0), "registry MUST NOT hold native balance");
    }

    /* ---------------------------------------------------------------------- */
    /* REG-I7                                                                 */
    /* ---------------------------------------------------------------------- */

    /// @notice REG-I7: the sum of per-owner registered counts equals the total number of successful registrations.
    function invariant_reg_i7_totalCountMatchesStorage() external view {
        uint256 storageCount = 0;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address actor = handler.actorAt(i);
            uint32 next = registry.nextIdFor(actor);
            storageCount += next == 1 ? 0 : uint256(next - 1);
        }
        assertEq(
            storageCount, handler.ghostRegistrationCount(), "storage-derived count must match tracked registrations"
        );
    }
}
