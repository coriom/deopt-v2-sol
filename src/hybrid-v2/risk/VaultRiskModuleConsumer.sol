// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {CollateralVaultV2RiskIntegrated} from "./CollateralVaultV2RiskIntegrated.sol";
import {Versions} from "../libraries/Versions.sol";

/// @dev Narrow scoped interface: read the architecture version pin from a
///      concrete `RiskModuleV2` (which exposes it as `public immutable
///      uint256 ARCHITECTURE_VERSION`). Symmetric with the check performed by
///      `CollateralVaultV2RiskIntegrated` on the Vault side.
interface IRiskModuleArchitectureScopedForConsumer {
    function ARCHITECTURE_VERSION() external view returns (uint256);
}

/// @title VaultRiskModuleConsumer
/// @notice Production enforcement boundary for the RM-1 posture
///         (`SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT`). Downstream
///         economic engines (WP-08 MarginEngineV2, WP-10 EscapeController,
///         and any future consumer of Vault-driven risk decisions) MUST
///         inherit this abstract instead of accepting an independent
///         `riskModule_` constructor argument.
/// @dev
///  Rationale (see
///  `ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH.md`
///  §Part J):
///   - RM-1 requires every consumer of Vault-driven risk decisions to bind
///     the SAME `IRiskModule` the Vault binds. Prior to this patch this rule
///     lived only in documentation + test-only reference consumers, which is
///     not enforceable against a future WP-08 that could still take a
///     `constructor(address vault, address independentRiskModule)`.
///   - This abstract makes divergence impossible AT COMPILE TIME: the
///     constructor signature accepts ONLY the Vault. The RiskModule is
///     canonically sourced from `CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE()`
///     and stored as `immutable`. No setter exists. No rotation surface exists.
///
///  Guarantees (constructor):
///   - `vault_` non-zero.
///   - Vault's `RISK_MODULE` non-zero.
///   - Vault's `RISK_MODULE.ARCHITECTURE_VERSION()` equals
///     `Versions.ARCHITECTURE_VERSION`.
///   - Vault's `RISK_MODULE.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION)`
///     returns `true`.
///
///  Post-construction:
///   - `VAULT` + `RISK_MODULE` are `public immutable`. Solidity guarantees
///     they cannot be reassigned. No admin surface exposed.
///   - Replacement policy remains "fresh consumer redeploy = fresh cutover"
///     (spec 06 §C-01), inherited from the Vault-side RM-1 posture.
///
///  Non-scope:
///   - This abstract does NOT authorize any economic action. It only pins
///     the canonical risk-view source. Concrete inheritors (WP-08+) still
///     hold whatever capabilities the Vault grants them.
///   - It does not enforce that WP-08's own logic actually CONSULTS the
///     RiskModule — that is a WP-08 correctness property (covered by
///     WP-08's own tests + invariants when it lands). This abstract just
///     ensures the consulted module IS the Vault's module.
abstract contract VaultRiskModuleConsumer {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical Vault this consumer is bound to. Immutable.
    ICollateralVault public immutable VAULT;

    /// @notice Canonical RiskModule sourced FROM the Vault. Immutable.
    ///         Same address every consumer of the same Vault sees.
    IRiskModule public immutable RISK_MODULE;

    /// @notice Architecture version pinned at construction. Compare against
    ///         `Versions.ARCHITECTURE_VERSION` to detect cross-architecture
    ///         wiring attempts in downstream tooling.
    uint256 public immutable ARCHITECTURE_VERSION;

    /// @notice Canonical storage version this consumer compiles against.
    uint16 public immutable SUPPORTED_STORAGE_VERSION;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor argument `vault_` is the zero address.
    error InvalidVault();

    /// @notice The Vault's `RISK_MODULE()` returned the zero address —
    ///         canonical binding is missing.
    error RiskModuleNotBoundOnVault();

    /// @notice The Vault's RiskModule reports an architecture version that
    ///         does not match this consumer's canonical
    ///         `Versions.ARCHITECTURE_VERSION`.
    error RiskModuleArchitectureMismatch(uint256 expected, uint256 provided);

    /// @notice The Vault's RiskModule does not support this consumer's
    ///         canonical storage version.
    error RiskModuleStorageVersionUnsupported(uint16 storageVersion);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param vault_ The canonical `CollateralVaultV2RiskIntegrated` (or any
    ///        concrete inheritor thereof). Constructor reads
    ///        `vault_.RISK_MODULE()` and stores it as the canonical
    ///        `RISK_MODULE` immutable. Any attempt to accept a second
    ///        independent module argument would require modifying this
    ///        abstract itself, which is intentional.
    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidVault();

        // Canonical binding: read the Vault's own RiskModule reference. The
        // Vault's `RISK_MODULE` slot is `public immutable`, set at Vault
        // construction with its own set of compatibility checks. Reading it
        // here means this consumer CANNOT diverge from what the Vault uses
        // for `_requireWithdrawalAllowed` / `_requireInternalTransferAllowed`.
        IRiskModule module = CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE();
        if (address(module) == address(0)) revert RiskModuleNotBoundOnVault();

        // Defence in depth: re-verify architecture + storage compatibility
        // on the consumer side. The Vault already did these checks at its
        // own construction, but re-verifying here protects against a future
        // Vault variant that changed / relaxed the semantics.
        uint256 arch = IRiskModuleArchitectureScopedForConsumer(address(module)).ARCHITECTURE_VERSION();
        if (arch != Versions.ARCHITECTURE_VERSION) {
            revert RiskModuleArchitectureMismatch(Versions.ARCHITECTURE_VERSION, arch);
        }
        if (!module.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION)) {
            revert RiskModuleStorageVersionUnsupported(Versions.STORAGE_VERSION);
        }

        VAULT = ICollateralVault(vault_);
        RISK_MODULE = module;
        ARCHITECTURE_VERSION = Versions.ARCHITECTURE_VERSION;
        SUPPORTED_STORAGE_VERSION = Versions.STORAGE_VERSION;
    }
}
