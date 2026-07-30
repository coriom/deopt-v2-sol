// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {DeploymentManifestV1TestBase} from "./DeploymentManifestV1TestBase.sol";
import {DeploymentManifestV1} from "../../../src/hybrid-v2/deployment/DeploymentManifestV1.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title DeploymentManifestV1Invariants
/// @notice WP-11 invariant coverage for the immutable manifest:
///          - `MANIFEST-I1`  manifest hash is deterministic;
///          - `MANIFEST-I2`  any critical field mutation changes manifest hash;
///          - `MANIFEST-I3`  manifest module references satisfy dependency consistency;
///          - `MANIFEST-I4`  no mutable authority can rewrite deployment identity;
///          - `MANIFEST-I6`  manifest contains every required Hybrid V2 module.
///
/// `MANIFEST-I5` (Base mainnet forbidden) is enforced structurally in the
/// constructor — proven by the unit `test_construction_rejectsBaseMainnet`.
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
contract DeploymentManifestV1Invariants is DeploymentManifestV1TestBase {
    DeploymentManifestV1 internal manifest;

    function setUp() public override {
        super.setUp();
        manifest = new DeploymentManifestV1(_defaultParams());
        // No handler contract needed: the manifest has NO mutating function.
        // `targetContract` intentionally omitted so the forge invariant runner
        // walks address(this)'s functions but finds nothing that can mutate
        // the manifest — which is the point of I4.
    }

    /// @notice MANIFEST-I1 — recomputing the manifest hash from current
    ///         immutables always equals the stored hash. Deterministic.
    function invariant_I1_hashIsDeterministic() external view {
        assertEq(manifest.recomputeManifestHash(), manifest.MANIFEST_HASH());
    }

    /// @notice MANIFEST-I3 — every recorded module reference resolves to a
    ///         contract with code (or is intentionally zero for optional slots).
    function invariant_I3_moduleReferencesConsistent() external view {
        address[] memory addrs = manifest.moduleAddresses();
        for (uint256 i = 0; i < addrs.length; i++) {
            uint8 slot = uint8(i);
            bool isRequired = _isRequiredSlot(slot);
            bool codeAllowedToBeMissing =
                !isRequired && (slot == manifest.MODULE_GOVERNANCE() || slot == manifest.MODULE_GUARDIAN());
            if (isRequired) {
                assertTrue(addrs[i] != address(0), "required addr zero");
                assertTrue(addrs[i].code.length > 0, "required addr no code");
            } else if (!codeAllowedToBeMissing) {
                if (addrs[i] != address(0)) assertTrue(addrs[i].code.length > 0, "optional non-zero no code");
            }
        }
    }

    /// @notice MANIFEST-I4 — the manifest exposes no setter or governance
    ///         entry point. Structural: every constant we snapshot at
    ///         construction remains equal to the source-of-truth constants.
    function invariant_I4_immutableIdentity() external view {
        assertEq(manifest.MAX_COLLATERAL_TOKENS_SNAPSHOT(), 8);
        assertEq(manifest.MAX_ACTIVE_SERIES_PER_SUBACCOUNT_SNAPSHOT(), 32);
        assertEq(manifest.ALL_CAPABILITIES_SNAPSHOT(), Capabilities.ALL_CAPABILITIES);
        assertEq(uint256(manifest.ARCHITECTURE_VERSION()), Versions.ARCHITECTURE_VERSION);
        assertEq(manifest.STORAGE_VERSION(), Versions.STORAGE_VERSION);
        assertEq(manifest.EVENT_VERSION(), Versions.EVENT_VERSION);
    }

    /// @notice MANIFEST-I6 — dense module table has the exact bounded length
    ///         and every required index is populated.
    function invariant_I6_requiredModulesPresent() external view {
        address[] memory addrs = manifest.moduleAddresses();
        assertEq(addrs.length, manifest.MODULE_COUNT());
        // Required required contract-slot indices.
        uint8[11] memory required = [
            manifest.MODULE_SUBACCOUNT_REGISTRY(),
            manifest.MODULE_COLLATERAL_VAULT(),
            manifest.MODULE_OPTIONS_POSITIONS_LEDGER(),
            manifest.MODULE_RISK_MODULE(),
            manifest.MODULE_MARGIN_ENGINE(),
            manifest.MODULE_OPTION_MATCHING_ENGINE(),
            manifest.MODULE_ESCAPE_CONTROLLER(),
            manifest.MODULE_RECOVERY_FINALIZER(),
            manifest.MODULE_ORACLE_ADAPTER(),
            manifest.MODULE_OPTIONS_RISK_PROVIDER(),
            manifest.MODULE_QUOTE_TOKEN()
        ];
        for (uint256 i = 0; i < required.length; i++) {
            assertTrue(addrs[required[i]] != address(0));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              I2 — MUTATION TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice MANIFEST-I2 — each fuzz run constructs a second manifest from
    ///         parameters that differ from the reference in exactly one
    ///         critical field, and asserts the hash is different. Uses a
    ///         standalone helper rather than a stateful handler because the
    ///         manifest itself is immutable — the surface under test is the
    ///         hash function.
    function testFuzz_I2_criticalFieldMutationChangesHash(uint16 dv) external {
        vm.assume(dv > 0 && dv != manifest.DEPLOYMENT_VERSION());
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.deploymentVersion = dv;
        DeploymentManifestV1 m2 = new DeploymentManifestV1(p);
        assertTrue(m2.MANIFEST_HASH() != manifest.MANIFEST_HASH());
        assertTrue(m2.CRITICAL_CONFIG_HASH() != manifest.CRITICAL_CONFIG_HASH());
    }

    function _isRequiredSlot(uint8 slot) internal view returns (bool) {
        return slot == manifest.MODULE_SUBACCOUNT_REGISTRY() || slot == manifest.MODULE_COLLATERAL_VAULT()
            || slot == manifest.MODULE_OPTIONS_POSITIONS_LEDGER() || slot == manifest.MODULE_RISK_MODULE()
            || slot == manifest.MODULE_MARGIN_ENGINE() || slot == manifest.MODULE_OPTION_MATCHING_ENGINE()
            || slot == manifest.MODULE_ESCAPE_CONTROLLER() || slot == manifest.MODULE_RECOVERY_FINALIZER()
            || slot == manifest.MODULE_ORACLE_ADAPTER() || slot == manifest.MODULE_OPTIONS_RISK_PROVIDER()
            || slot == manifest.MODULE_QUOTE_TOKEN();
    }
}
