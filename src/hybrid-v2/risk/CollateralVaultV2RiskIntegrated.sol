// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVaultV2} from "../vault/CollateralVaultV2.sol";
import {CollateralVaultV2Core} from "../vault/CollateralVaultV2Core.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {Versions} from "../libraries/Versions.sol";

/// @dev Narrowing interface used to cross-check a concrete RiskModule's
///      canonical Registry against the Vault's own Registry. Concrete
///      `RiskModuleV2` inheritors expose `REGISTRY` as a public immutable
///      whose selector matches this view. See `RiskModuleV2.sol` for the
///      symmetric check performed on the RiskModule side at construction.
interface IRiskModuleRegistryScoped {
    function REGISTRY() external view returns (address);
}

/// @dev Narrowing interface exposing the RiskModule's supported architecture
///      version and canonical storage-version compatibility check.
///      Concrete `RiskModuleV2` inheritors expose `ARCHITECTURE_VERSION` as
///      a public immutable.
interface IRiskModuleArchitectureScoped {
    function ARCHITECTURE_VERSION() external view returns (uint256);
}

/// @title CollateralVaultV2RiskIntegrated
/// @notice Abstract Vault inheritor that wires the WP-04B risk hooks
///         (`_requireWithdrawalAllowed`, `_requireInternalTransferAllowed`) to a
///         concrete `IRiskModule`.
/// @dev
///  Bridges WP-04B's abstract Vault risk-hook boundary and the WP-07 abstract
///  RiskModule. Production Vault deployments inherit THIS contract (instead of
///  `CollateralVaultV2` directly) plus a concrete `_requireOrphanedReleaseProof`
///  override from WP-10.
///
///  Compatibility gates (constructor):
///   - RiskModule address non-zero;
///   - RiskModule's canonical Registry equals Vault's Registry;
///   - RiskModule's architecture version equals `Versions.ARCHITECTURE_VERSION`;
///   - RiskModule's `supportsCanonicalStorageVersion(Versions.STORAGE_VERSION)`
///     returns true.
///
///  Fail-closed model:
///   - `withdrawalAllowed(subKey, token, amount) != true` reverts `UnsafeWithdrawal`.
///     Any revert from the RiskModule is caught and translated into
///     `UnsafeWithdrawal` too (fail-closed on module failure).
///   - Symmetric for `transferAllowed(sourceSubKey, token, amount)` +
///     `UnsafeTransfer`.
///   - Vault mutation happens AFTER the risk hook clears (WP-04B's own CEI
///     order), so rejection produces zero partial mutation and the enclosing
///     transaction reverts atomically.
///
///  This contract remains ABSTRACT because the WP-04B abstract
///  `_requireOrphanedReleaseProof` hook is owned by WP-10 (escape controller).
///  A test-only concrete inheritor lives under `test/hybrid-v2/risk/harness/`.
abstract contract CollateralVaultV2RiskIntegrated is CollateralVaultV2 {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Immutable RiskModule reference. Set at construction. Replacement
    ///         requires a full Vault redeploy — spec 06 §C-01 permits this as a
    ///         fresh-deployment cutover in V1 (`RISK_MODULE_SLOT_DEFERRED_TO_MARGIN_ENGINE_V2`).
    IRiskModule public immutable RISK_MODULE;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor argument `riskModule_` is the zero address.
    error InvalidRiskModule();

    /// @notice The RiskModule's Registry reference does not match this Vault's.
    error RiskModuleRegistryMismatch(address expected, address provided);

    /// @notice The RiskModule's architecture version does not match Vault's
    ///         canonical architecture version.
    error RiskModuleArchitectureMismatch(uint256 expected, uint256 provided);

    /// @notice The RiskModule does not support the Vault's canonical storage version.
    error RiskModuleStorageVersionUnsupported(uint16 storageVersion);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param riskModule_ Concrete RiskModuleV2 deployment. MUST NOT be zero.
    constructor(address riskModule_) {
        if (riskModule_ == address(0)) revert InvalidRiskModule();

        address moduleRegistry = IRiskModuleRegistryScoped(riskModule_).REGISTRY();
        address vaultRegistry = address(REGISTRY);
        if (moduleRegistry != vaultRegistry) {
            revert RiskModuleRegistryMismatch(vaultRegistry, moduleRegistry);
        }
        uint256 moduleArchitecture = IRiskModuleArchitectureScoped(riskModule_).ARCHITECTURE_VERSION();
        if (moduleArchitecture != Versions.ARCHITECTURE_VERSION) {
            revert RiskModuleArchitectureMismatch(Versions.ARCHITECTURE_VERSION, moduleArchitecture);
        }
        if (!IRiskModule(riskModule_).supportsCanonicalStorageVersion(Versions.STORAGE_VERSION)) {
            revert RiskModuleStorageVersionUnsupported(Versions.STORAGE_VERSION);
        }

        RISK_MODULE = IRiskModule(riskModule_);
    }

    /*//////////////////////////////////////////////////////////////
                          WP-04B RISK-HOOK OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc CollateralVaultV2
    /// @dev Fail closed: any `false` return OR any revert from the RiskModule
    ///      surfaces as `UnsafeWithdrawal` and unwinds the Vault mutation.
    function _requireWithdrawalAllowed(bytes32 subKey, address token, uint256 amount) internal view override {
        try RISK_MODULE.withdrawalAllowed(subKey, token, amount) returns (bool ok) {
            if (!ok) revert UnsafeWithdrawal();
        } catch {
            revert UnsafeWithdrawal();
        }
    }

    /// @inheritdoc CollateralVaultV2
    /// @dev Fail closed: any `false` return OR any revert from the RiskModule
    ///      surfaces as `UnsafeTransfer` and unwinds the Vault mutation.
    function _requireInternalTransferAllowed(bytes32 sourceSubKey, address token, uint256 amount)
        internal
        view
        override
    {
        try RISK_MODULE.transferAllowed(sourceSubKey, token, amount) returns (bool ok) {
            if (!ok) revert UnsafeTransfer();
        } catch {
            revert UnsafeTransfer();
        }
    }
}
