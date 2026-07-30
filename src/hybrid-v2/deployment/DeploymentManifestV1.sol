// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {IEscapeController} from "../interfaces/IEscapeController.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {Capabilities} from "../libraries/Capabilities.sol";
import {Versions} from "../libraries/Versions.sol";

/// @dev Minimal accessor for the concrete `OptionsRiskModuleV2` immutables that are
///      not exposed via `IRiskModule`. Kept local to avoid coupling the manifest
///      to the concrete Risk module class.
interface IOptionsRiskModuleV2Manifest {
    function REGISTRY() external view returns (address);
    function VAULT() external view returns (address);
    function OPTIONS_LEDGER() external view returns (address);
    function RISK_PROVIDER() external view returns (address);
    function ORACLE() external view returns (address);
    function QUOTE_TOKEN() external view returns (address);
    function ARCHITECTURE_VERSION() external view returns (uint256);
    function SUPPORTED_STORAGE_VERSION() external view returns (uint16);
    function MODULE_VERSION() external view returns (uint16);
}

/// @dev Minimal accessor for the concrete `MarginEngineV2` immutables.
interface IMarginEngineV2Manifest {
    function REGISTRY() external view returns (address);
    function OPTIONS_LEDGER() external view returns (address);
    function RISK_PROVIDER() external view returns (address);
    function ORACLE() external view returns (address);
    function QUOTE_TOKEN() external view returns (address);
    function ENGINE_VERSION() external view returns (uint16);
    function vault() external view returns (address);
    function riskModule() external view returns (address);
}

/// @dev Minimal accessor for the concrete `OptionMatchingEngineV2` immutables.
interface IOptionMatchingEngineV2Manifest {
    function VAULT() external view returns (address);
    function RISK_MODULE() external view returns (address);
    function OPTIONS_LEDGER() external view returns (address);
    function MARGIN_ENGINE() external view returns (address);
    function RISK_PROVIDER() external view returns (address);
    function QUOTE_TOKEN() external view returns (address);
    function ENGINE_VERSION() external view returns (uint16);
}

/// @dev Minimal accessor for `EscapeControllerV1` immutables.
interface IEscapeControllerV1Manifest {
    function REGISTRY() external view returns (address);
    function GOVERNANCE() external view returns (address);
    function ACTIVATION_DELAY() external view returns (uint64);
    function PAUSE_MAX_DURATION_BLOCKS() external view returns (uint64);
    function recoveryFinalizer() external view returns (address);
}

/// @dev Minimal accessor for `RecoveryFinalizerV1` immutables.
interface IRecoveryFinalizerV1Manifest {
    function REGISTRY() external view returns (address);
    function VAULT() external view returns (address);
    function ESCAPE_CONTROLLER() external view returns (address);
    function POSITIONS_LEDGER() external view returns (address);
}

/// @dev Minimal accessor for the concrete `OptionsPositionsLedger` immutables that
///      are not part of `IOptionsPositionsLedger`.
interface IOptionsPositionsLedgerManifest {
    function REGISTRY() external view returns (address);
    function CAPABILITY_AUTHORITY() external view returns (address);
    function maxActiveSeriesPerSubaccount() external view returns (uint32);
}

/// @dev Minimal accessor for concrete `SubaccountRegistry` immutables.
interface ISubaccountRegistryManifest {
    function capabilityAuthority() external view returns (address);
    function deploymentChainId() external view returns (uint256);
    function deploymentBlock() external view returns (uint64);
}

/// @title DeploymentManifestV1
/// @notice `ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-DEPLOYMENT-MANIFEST-V1` (WP-11)
///         canonical immutable post-deployment record for one Hybrid V2
///         instance.
/// @dev
///  Model (Part K — `IMMUTABLE_POST_DEPLOYMENT_MANIFEST_MODEL_RESOLVED`):
///   - Deployed LAST, after every core module is live and every one-shot
///     init (protocol subaccounts, escape controller, recovery finalizer)
///     has run.
///   - Core modules NEVER depend on the manifest — the manifest is a
///     read-only witness that observes the completed wiring.
///   - No setter, no governance, no upgrade path.
///   - Any change to a critical field requires a new deployment + a new
///     manifest instance (a distinct address + a distinct manifest hash).
///
///  Validation posture (Part N — `DEPLOYMENT_MANIFEST_WIRING_VALIDATED`):
///   Constructor performs every objective on-chain wiring check and reverts
///   on any mismatch. Once construction succeeds, the observed identity is
///   frozen in immutables and re-checkable off-chain by re-computing the
///   canonical hash from public views.
///
///  Safety (Part Q — `BASE_SEPOLIA_ONLY_MANIFEST_SAFETY_VALIDATED`):
///   Base mainnet (chainId 8453) is explicitly forbidden as an experimental
///   deployment target — constructor reverts on chainId 8453. Base Sepolia
///   (chainId 84532) and any dev / local chain id are accepted.
///
///  Hash model (Part M — `DEPLOYMENT_MANIFEST_HASH_CANONICAL_AND_DETERMINISTIC`):
///   Three distinct canonical hashes are computed at construction:
///     1. `moduleAddressesHash` — abi-encoded ordered core module addresses;
///     2. `criticalConfigHash` — abi-encoded chain identity + version block +
///        protocol subKeys + frozen bounds + capability mask;
///     3. `manifestHash` — abi-encoded environment tag + module hash +
///        config hash + block/timestamp of instantiation.
///   Every hash uses `abi.encode` (never packed) with an explicit type tag
///   as the first argument, so no ambiguity is possible.
///
///  Non-goals (frozen):
///   - No proxy pattern, no upgrade admin, no mutable authority.
///   - No RPC / secret / signer / off-chain endpoint storage.
///   - No deployment broadcast — manifest instantiation is a plain
///     Solidity contract deployment observed by the deployer's script.
///   - No on-chain manifest hash publication registry — a single manifest
///     instance IS the manifest publication.
contract DeploymentManifestV1 {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Base mainnet chain id. Rejected outright by this experimental manifest.
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;

    /// @notice Base Sepolia chain id. Accepted (the intended experimental target).
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Structural version of THIS manifest schema. Frozen at 1 in V1.
    ///         Bumped only when the manifest struct or hash schema changes.
    uint16 public constant MANIFEST_SCHEMA_VERSION = 1;

    /// @notice Frozen count of module slots recorded in the manifest.
    uint8 public constant MODULE_COUNT = 16;

    // Canonical module identifiers. Zero-based, dense, append-only.
    uint8 public constant MODULE_SUBACCOUNT_REGISTRY = 0;
    uint8 public constant MODULE_COLLATERAL_VAULT = 1;
    uint8 public constant MODULE_OPTIONS_POSITIONS_LEDGER = 2;
    uint8 public constant MODULE_RISK_MODULE = 3;
    uint8 public constant MODULE_MARGIN_ENGINE = 4;
    uint8 public constant MODULE_OPTION_MATCHING_ENGINE = 5;
    uint8 public constant MODULE_ESCAPE_CONTROLLER = 6;
    uint8 public constant MODULE_RECOVERY_FINALIZER = 7;
    uint8 public constant MODULE_ORACLE_ADAPTER = 8;
    uint8 public constant MODULE_OPTIONS_RISK_PROVIDER = 9;
    uint8 public constant MODULE_QUOTE_TOKEN = 10;
    uint8 public constant MODULE_FEES_MANAGER_V2 = 11;
    uint8 public constant MODULE_OPTION_EXECUTION_FEE_ADAPTER = 12;
    uint8 public constant MODULE_PROTOCOL_TIMELOCK = 13;
    uint8 public constant MODULE_GOVERNANCE = 14;
    uint8 public constant MODULE_GUARDIAN = 15;

    // Canonical hash type tags. Bound into each hash's first slot so a
    // consumer can never conflate one hash for another.
    bytes32 public constant MANIFEST_TYPE_HASH = keccak256("DeploymentManifestV1(hybridV2)");
    bytes32 public constant MODULE_ADDRESSES_TYPE_HASH = keccak256("DeploymentManifestV1.ModuleAddresses(hybridV2)");
    bytes32 public constant CRITICAL_CONFIG_TYPE_HASH = keccak256("DeploymentManifestV1.CriticalConfig(hybridV2)");

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BaseMainnetForbidden(uint256 chainId);
    error ZeroAddress(uint8 moduleId);
    error NoCode(uint8 moduleId, address addr);
    error DuplicateModuleAddress(uint8 moduleIdA, uint8 moduleIdB, address addr);
    error RegistryMismatch(address expected, address actual);
    error VaultMismatch(address expected, address actual);
    error LedgerMismatch(address expected, address actual);
    error RiskModuleMismatch(address expected, address actual);
    error MarginEngineMismatch(address expected, address actual);
    error EscapeControllerMismatch(address expected, address actual);
    error RecoveryFinalizerMismatch(address expected, address actual);
    error OracleMismatch(address expected, address actual);
    error RiskProviderMismatch(address expected, address actual);
    error QuoteTokenMismatch(address expected, address actual);
    error CapabilityAuthorityMismatch(address expected, address actual);
    error ProtocolSubaccountsNotInitialized();
    error EscapeControllerNotInitialized();
    error RecoveryFinalizerNotInitialized();
    error ProtocolFeeSubKeyZero();
    error RebateBudgetSubKeyZero();
    error InsuranceFundSubKeyZero();
    error MaxCollateralTokensMismatch(uint256 expected, uint256 actual);
    error MaxActiveSeriesMismatch(uint32 expected, uint32 actual);
    error CapabilityMaskMismatch(uint256 expected, uint256 actual);
    error ArchitectureVersionMismatch(uint256 expected, uint256 actual);
    error StorageVersionUnsupported(uint16 storageVersion);
    error DeploymentVersionZero();
    error ChainIdMismatch(uint256 expected, uint256 actual);
    error DeploymentBlockInFuture(uint64 deploymentBlock, uint256 chainBlock);
    error ModuleIndexOutOfRange(uint8 moduleId, uint8 maxModuleId);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot emitted at construction. Reconstructs the canonical
    ///         manifest identity from a single log with no dependency on
    ///         any subsequent event or contract call.
    event DeploymentManifestDeclared(
        bytes32 indexed manifestHash,
        uint256 indexed chainId,
        address indexed deployer,
        bytes32 environmentTag,
        uint16 architectureVersion,
        uint16 deploymentVersion,
        uint16 manifestSchemaVersion,
        bytes32 moduleAddressesHash,
        bytes32 criticalConfigHash,
        uint64 deploymentBlock,
        uint64 deploymentTimestamp,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR PARAMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor parameter struct. Avoids the classic stack-too-deep
    ///         and forces callers to be explicit about every field.
    struct ManifestParams {
        bytes32 environmentTag;
        uint16 deploymentVersion;
        // Core modules (all required).
        address subaccountRegistry;
        address collateralVault;
        address optionsPositionsLedger;
        address riskModule;
        address marginEngine;
        address optionMatchingEngine;
        address escapeController;
        address recoveryFinalizer;
        // External dependencies (required, external to hybrid-v2).
        address oracleAdapter;
        address optionsRiskProvider;
        address quoteToken;
        // Optional modules (may be zero; if non-zero, must contain code).
        address feesManagerV2;
        address optionExecutionFeeAdapter;
        address protocolTimelock;
        address governance;
        address guardian;
    }

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLE STATE
    //////////////////////////////////////////////////////////////*/

    // Chain / protocol identity.
    uint256 public immutable CHAIN_ID;
    uint16 public immutable ARCHITECTURE_VERSION;
    uint16 public immutable STORAGE_VERSION;
    uint16 public immutable EVENT_VERSION;
    uint16 public immutable DEPLOYMENT_VERSION;
    bytes32 public immutable ENVIRONMENT_TAG;
    uint64 public immutable DEPLOYMENT_BLOCK;
    uint64 public immutable DEPLOYMENT_TIMESTAMP;
    address public immutable DEPLOYER;

    // Core module addresses (required).
    address public immutable SUBACCOUNT_REGISTRY;
    address public immutable COLLATERAL_VAULT;
    address public immutable OPTIONS_POSITIONS_LEDGER;
    address public immutable RISK_MODULE;
    address public immutable MARGIN_ENGINE;
    address public immutable OPTION_MATCHING_ENGINE;
    address public immutable ESCAPE_CONTROLLER;
    address public immutable RECOVERY_FINALIZER;

    // External / shared references (required).
    address public immutable ORACLE_ADAPTER;
    address public immutable OPTIONS_RISK_PROVIDER;
    address public immutable QUOTE_TOKEN;

    // Optional modules (may be zero).
    address public immutable FEES_MANAGER_V2;
    address public immutable OPTION_EXECUTION_FEE_ADAPTER;
    address public immutable PROTOCOL_TIMELOCK;
    address public immutable GOVERNANCE;
    address public immutable GUARDIAN;

    // Protocol identities.
    bytes32 public immutable PROTOCOL_FEE_SUBKEY;
    bytes32 public immutable REBATE_BUDGET_SUBKEY;
    bytes32 public immutable INSURANCE_FUND_SUBKEY;

    // Frozen bounds.
    uint8 public immutable MAX_COLLATERAL_TOKENS_SNAPSHOT;
    uint32 public immutable MAX_ACTIVE_SERIES_PER_SUBACCOUNT_SNAPSHOT;
    uint256 public immutable ALL_CAPABILITIES_SNAPSHOT;
    uint64 public immutable RECOVERY_ACTIVATION_DELAY_SECONDS;
    uint64 public immutable RECOVERY_PAUSE_MAX_DURATION_BLOCKS;

    // Canonical hashes.
    bytes32 public immutable MODULE_ADDRESSES_HASH;
    bytes32 public immutable CRITICAL_CONFIG_HASH;
    bytes32 public immutable MANIFEST_HASH;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Records the completed Hybrid V2 deployment and performs every
    ///         objective wiring check before freezing the manifest.
    /// @dev
    ///  Order of operations:
    ///   1. Reject Base mainnet outright.
    ///   2. Reject deployment version = 0.
    ///   3. Reject any zero required address and any address without code.
    ///   4. Reject duplicate addresses across distinct required slots.
    ///   5. Cross-check module wiring (registry ↔ vault, vault ↔ ledger,
    ///      vault ↔ risk module, engines ↔ their dependencies, escape/finalizer
    ///      binding).
    ///   6. Cross-check protocol subaccount initialisation + non-zero
    ///      subKeys.
    ///   7. Cross-check frozen bounds (max tokens = 8, max series = 32,
    ///      capability mask width).
    ///   8. Cross-check risk module version block (architecture, storage).
    ///   9. Snapshot escape-controller delay + pause bounds.
    ///  10. Compute the three canonical hashes and emit
    ///      `DeploymentManifestDeclared`.
    constructor(ManifestParams memory p) {
        if (block.chainid == BASE_MAINNET_CHAIN_ID) revert BaseMainnetForbidden(block.chainid);
        if (p.deploymentVersion == 0) revert DeploymentVersionZero();

        // Required addresses — non-zero + has code.
        _requireRequired(MODULE_SUBACCOUNT_REGISTRY, p.subaccountRegistry);
        _requireRequired(MODULE_COLLATERAL_VAULT, p.collateralVault);
        _requireRequired(MODULE_OPTIONS_POSITIONS_LEDGER, p.optionsPositionsLedger);
        _requireRequired(MODULE_RISK_MODULE, p.riskModule);
        _requireRequired(MODULE_MARGIN_ENGINE, p.marginEngine);
        _requireRequired(MODULE_OPTION_MATCHING_ENGINE, p.optionMatchingEngine);
        _requireRequired(MODULE_ESCAPE_CONTROLLER, p.escapeController);
        _requireRequired(MODULE_RECOVERY_FINALIZER, p.recoveryFinalizer);
        _requireRequired(MODULE_ORACLE_ADAPTER, p.oracleAdapter);
        _requireRequired(MODULE_OPTIONS_RISK_PROVIDER, p.optionsRiskProvider);
        _requireRequired(MODULE_QUOTE_TOKEN, p.quoteToken);

        // Optional CONTRACT slots — allow zero, require code when non-zero.
        _requireOptional(MODULE_FEES_MANAGER_V2, p.feesManagerV2);
        _requireOptional(MODULE_OPTION_EXECUTION_FEE_ADAPTER, p.optionExecutionFeeAdapter);
        _requireOptional(MODULE_PROTOCOL_TIMELOCK, p.protocolTimelock);
        // Governance + Guardian may be EOAs (multisig-signer keys or plain
        // addresses in dev). Non-zero is not enforced; a governance-less
        // deployment is a valid experimental configuration.

        // Reject duplicate addresses across required core-module slots.
        _requireNoDuplicates(p);

        // Wiring: Registry ↔ Vault.
        {
            address regAuthority = ISubaccountRegistryManifest(p.subaccountRegistry).capabilityAuthority();
            if (regAuthority != p.collateralVault) revert CapabilityAuthorityMismatch(p.collateralVault, regAuthority);
            uint256 regChainId = ISubaccountRegistryManifest(p.subaccountRegistry).deploymentChainId();
            if (regChainId != block.chainid) revert ChainIdMismatch(block.chainid, regChainId);
        }

        // Wiring: Vault ↔ Registry + protocol init + escape + finalizer.
        {
            ICollateralVault vault = ICollateralVault(p.collateralVault);
            if (!vault.protocolSubaccountsInitialized()) revert ProtocolSubaccountsNotInitialized();
            if (!vault.escapeControllerInitialized()) revert EscapeControllerNotInitialized();
            if (!vault.recoveryFinalizerInitialized()) revert RecoveryFinalizerNotInitialized();
            if (vault.escapeController() != p.escapeController) {
                revert EscapeControllerMismatch(p.escapeController, vault.escapeController());
            }
            if (vault.recoveryFinalizer() != p.recoveryFinalizer) {
                revert RecoveryFinalizerMismatch(p.recoveryFinalizer, vault.recoveryFinalizer());
            }
            if (vault.maxCollateralTokens() != 8) {
                revert MaxCollateralTokensMismatch(8, vault.maxCollateralTokens());
            }
            if (vault.protocolFeeVaultSubKey() == bytes32(0)) revert ProtocolFeeSubKeyZero();
            if (vault.rebateBudgetSubKey() == bytes32(0)) revert RebateBudgetSubKeyZero();
            if (vault.insuranceFundSubKey() == bytes32(0)) revert InsuranceFundSubKeyZero();
        }

        // Wiring: Ledger ↔ Registry + Vault + max active series bound.
        {
            IOptionsPositionsLedgerManifest ledger = IOptionsPositionsLedgerManifest(p.optionsPositionsLedger);
            if (ledger.REGISTRY() != p.subaccountRegistry) {
                revert RegistryMismatch(p.subaccountRegistry, ledger.REGISTRY());
            }
            if (ledger.CAPABILITY_AUTHORITY() != p.collateralVault) {
                revert VaultMismatch(p.collateralVault, ledger.CAPABILITY_AUTHORITY());
            }
            uint32 maxSeries = ledger.maxActiveSeriesPerSubaccount();
            if (maxSeries != 32) revert MaxActiveSeriesMismatch(32, maxSeries);
        }

        // Wiring: RiskModule (concrete OptionsRiskModuleV2).
        {
            IOptionsRiskModuleV2Manifest rm = IOptionsRiskModuleV2Manifest(p.riskModule);
            if (rm.REGISTRY() != p.subaccountRegistry) revert RegistryMismatch(p.subaccountRegistry, rm.REGISTRY());
            if (rm.VAULT() != p.collateralVault) revert VaultMismatch(p.collateralVault, rm.VAULT());
            if (rm.OPTIONS_LEDGER() != p.optionsPositionsLedger) {
                revert LedgerMismatch(p.optionsPositionsLedger, rm.OPTIONS_LEDGER());
            }
            if (rm.RISK_PROVIDER() != p.optionsRiskProvider) {
                revert RiskProviderMismatch(p.optionsRiskProvider, rm.RISK_PROVIDER());
            }
            if (rm.ORACLE() != p.oracleAdapter) revert OracleMismatch(p.oracleAdapter, rm.ORACLE());
            if (rm.QUOTE_TOKEN() != p.quoteToken) revert QuoteTokenMismatch(p.quoteToken, rm.QUOTE_TOKEN());
            uint256 rmArch = rm.ARCHITECTURE_VERSION();
            if (rmArch != Versions.ARCHITECTURE_VERSION) {
                revert ArchitectureVersionMismatch(Versions.ARCHITECTURE_VERSION, rmArch);
            }
            uint16 rmStorage = rm.SUPPORTED_STORAGE_VERSION();
            if (rmStorage != Versions.STORAGE_VERSION) revert StorageVersionUnsupported(rmStorage);
        }

        // Wiring: MarginEngine.
        {
            IMarginEngineV2Manifest me = IMarginEngineV2Manifest(p.marginEngine);
            if (me.REGISTRY() != p.subaccountRegistry) revert RegistryMismatch(p.subaccountRegistry, me.REGISTRY());
            if (me.OPTIONS_LEDGER() != p.optionsPositionsLedger) {
                revert LedgerMismatch(p.optionsPositionsLedger, me.OPTIONS_LEDGER());
            }
            if (me.RISK_PROVIDER() != p.optionsRiskProvider) {
                revert RiskProviderMismatch(p.optionsRiskProvider, me.RISK_PROVIDER());
            }
            if (me.ORACLE() != p.oracleAdapter) revert OracleMismatch(p.oracleAdapter, me.ORACLE());
            if (me.QUOTE_TOKEN() != p.quoteToken) revert QuoteTokenMismatch(p.quoteToken, me.QUOTE_TOKEN());
            if (me.vault() != p.collateralVault) revert VaultMismatch(p.collateralVault, me.vault());
            if (me.riskModule() != p.riskModule) revert RiskModuleMismatch(p.riskModule, me.riskModule());
        }

        // Wiring: OptionMatchingEngine.
        {
            IOptionMatchingEngineV2Manifest ome = IOptionMatchingEngineV2Manifest(p.optionMatchingEngine);
            if (ome.VAULT() != p.collateralVault) revert VaultMismatch(p.collateralVault, ome.VAULT());
            if (ome.RISK_MODULE() != p.riskModule) revert RiskModuleMismatch(p.riskModule, ome.RISK_MODULE());
            if (ome.OPTIONS_LEDGER() != p.optionsPositionsLedger) {
                revert LedgerMismatch(p.optionsPositionsLedger, ome.OPTIONS_LEDGER());
            }
            if (ome.MARGIN_ENGINE() != p.marginEngine) {
                revert MarginEngineMismatch(p.marginEngine, ome.MARGIN_ENGINE());
            }
            if (ome.RISK_PROVIDER() != p.optionsRiskProvider) {
                revert RiskProviderMismatch(p.optionsRiskProvider, ome.RISK_PROVIDER());
            }
            if (ome.QUOTE_TOKEN() != p.quoteToken) revert QuoteTokenMismatch(p.quoteToken, ome.QUOTE_TOKEN());
        }

        // Wiring: EscapeController.
        {
            IEscapeControllerV1Manifest esc = IEscapeControllerV1Manifest(p.escapeController);
            if (esc.REGISTRY() != p.subaccountRegistry) revert RegistryMismatch(p.subaccountRegistry, esc.REGISTRY());
            if (esc.recoveryFinalizer() != p.recoveryFinalizer) {
                revert RecoveryFinalizerMismatch(p.recoveryFinalizer, esc.recoveryFinalizer());
            }
        }

        // Wiring: RecoveryFinalizer.
        {
            IRecoveryFinalizerV1Manifest fin = IRecoveryFinalizerV1Manifest(p.recoveryFinalizer);
            if (fin.REGISTRY() != p.subaccountRegistry) revert RegistryMismatch(p.subaccountRegistry, fin.REGISTRY());
            if (fin.VAULT() != p.collateralVault) revert VaultMismatch(p.collateralVault, fin.VAULT());
            if (fin.ESCAPE_CONTROLLER() != p.escapeController) {
                revert EscapeControllerMismatch(p.escapeController, fin.ESCAPE_CONTROLLER());
            }
            if (fin.POSITIONS_LEDGER() != p.optionsPositionsLedger) {
                revert LedgerMismatch(p.optionsPositionsLedger, fin.POSITIONS_LEDGER());
            }
        }

        // Snapshot escape-controller frozen bounds.
        uint64 recoveryDelay;
        uint64 recoveryPauseMax;
        {
            IEscapeControllerV1Manifest esc = IEscapeControllerV1Manifest(p.escapeController);
            recoveryDelay = esc.ACTIVATION_DELAY();
            recoveryPauseMax = esc.PAUSE_MAX_DURATION_BLOCKS();
        }

        // Bind immutables now that every check has passed.
        CHAIN_ID = block.chainid;
        ARCHITECTURE_VERSION = uint16(Versions.ARCHITECTURE_VERSION);
        STORAGE_VERSION = Versions.STORAGE_VERSION;
        EVENT_VERSION = Versions.EVENT_VERSION;
        DEPLOYMENT_VERSION = p.deploymentVersion;
        ENVIRONMENT_TAG = p.environmentTag;
        DEPLOYMENT_BLOCK = uint64(block.number);
        DEPLOYMENT_TIMESTAMP = uint64(block.timestamp);
        DEPLOYER = msg.sender;

        SUBACCOUNT_REGISTRY = p.subaccountRegistry;
        COLLATERAL_VAULT = p.collateralVault;
        OPTIONS_POSITIONS_LEDGER = p.optionsPositionsLedger;
        RISK_MODULE = p.riskModule;
        MARGIN_ENGINE = p.marginEngine;
        OPTION_MATCHING_ENGINE = p.optionMatchingEngine;
        ESCAPE_CONTROLLER = p.escapeController;
        RECOVERY_FINALIZER = p.recoveryFinalizer;

        ORACLE_ADAPTER = p.oracleAdapter;
        OPTIONS_RISK_PROVIDER = p.optionsRiskProvider;
        QUOTE_TOKEN = p.quoteToken;

        FEES_MANAGER_V2 = p.feesManagerV2;
        OPTION_EXECUTION_FEE_ADAPTER = p.optionExecutionFeeAdapter;
        PROTOCOL_TIMELOCK = p.protocolTimelock;
        GOVERNANCE = p.governance;
        GUARDIAN = p.guardian;

        // Snapshot protocol subKeys from vault views (single source of truth).
        {
            ICollateralVault vault = ICollateralVault(p.collateralVault);
            PROTOCOL_FEE_SUBKEY = vault.protocolFeeVaultSubKey();
            REBATE_BUDGET_SUBKEY = vault.rebateBudgetSubKey();
            INSURANCE_FUND_SUBKEY = vault.insuranceFundSubKey();
        }

        MAX_COLLATERAL_TOKENS_SNAPSHOT = 8;
        MAX_ACTIVE_SERIES_PER_SUBACCOUNT_SNAPSHOT = 32;
        ALL_CAPABILITIES_SNAPSHOT = Capabilities.ALL_CAPABILITIES;
        RECOVERY_ACTIVATION_DELAY_SECONDS = recoveryDelay;
        RECOVERY_PAUSE_MAX_DURATION_BLOCKS = recoveryPauseMax;

        // Canonical hashes — abi.encode with explicit type-hash prefixes.
        bytes32 addrHash = keccak256(
            abi.encode(
                MODULE_ADDRESSES_TYPE_HASH,
                p.subaccountRegistry,
                p.collateralVault,
                p.optionsPositionsLedger,
                p.riskModule,
                p.marginEngine,
                p.optionMatchingEngine,
                p.escapeController,
                p.recoveryFinalizer,
                p.oracleAdapter,
                p.optionsRiskProvider,
                p.quoteToken,
                p.feesManagerV2,
                p.optionExecutionFeeAdapter,
                p.protocolTimelock,
                p.governance,
                p.guardian
            )
        );
        MODULE_ADDRESSES_HASH = addrHash;

        bytes32 configHash = keccak256(
            abi.encode(
                CRITICAL_CONFIG_TYPE_HASH,
                block.chainid,
                uint16(Versions.ARCHITECTURE_VERSION),
                Versions.STORAGE_VERSION,
                Versions.EVENT_VERSION,
                p.deploymentVersion,
                MANIFEST_SCHEMA_VERSION,
                PROTOCOL_FEE_SUBKEY,
                REBATE_BUDGET_SUBKEY,
                INSURANCE_FUND_SUBKEY,
                uint8(8),
                uint32(32),
                Capabilities.ALL_CAPABILITIES,
                recoveryDelay,
                recoveryPauseMax
            )
        );
        CRITICAL_CONFIG_HASH = configHash;

        bytes32 mHash = keccak256(
            abi.encode(
                MANIFEST_TYPE_HASH,
                p.environmentTag,
                addrHash,
                configHash,
                uint64(block.number),
                uint64(block.timestamp)
            )
        );
        MANIFEST_HASH = mHash;

        emit DeploymentManifestDeclared(
            mHash,
            block.chainid,
            msg.sender,
            p.environmentTag,
            uint16(Versions.ARCHITECTURE_VERSION),
            p.deploymentVersion,
            MANIFEST_SCHEMA_VERSION,
            addrHash,
            configHash,
            uint64(block.number),
            uint64(block.timestamp),
            Versions.EVENT_VERSION
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address recorded for `moduleId` (0..MODULE_COUNT-1). Returns
    ///         zero if the module slot is optional and was not populated.
    function moduleAddressOf(uint8 moduleId) external view returns (address) {
        if (moduleId >= MODULE_COUNT) revert ModuleIndexOutOfRange(moduleId, MODULE_COUNT - 1);
        if (moduleId == MODULE_SUBACCOUNT_REGISTRY) return SUBACCOUNT_REGISTRY;
        if (moduleId == MODULE_COLLATERAL_VAULT) return COLLATERAL_VAULT;
        if (moduleId == MODULE_OPTIONS_POSITIONS_LEDGER) return OPTIONS_POSITIONS_LEDGER;
        if (moduleId == MODULE_RISK_MODULE) return RISK_MODULE;
        if (moduleId == MODULE_MARGIN_ENGINE) return MARGIN_ENGINE;
        if (moduleId == MODULE_OPTION_MATCHING_ENGINE) return OPTION_MATCHING_ENGINE;
        if (moduleId == MODULE_ESCAPE_CONTROLLER) return ESCAPE_CONTROLLER;
        if (moduleId == MODULE_RECOVERY_FINALIZER) return RECOVERY_FINALIZER;
        if (moduleId == MODULE_ORACLE_ADAPTER) return ORACLE_ADAPTER;
        if (moduleId == MODULE_OPTIONS_RISK_PROVIDER) return OPTIONS_RISK_PROVIDER;
        if (moduleId == MODULE_QUOTE_TOKEN) return QUOTE_TOKEN;
        if (moduleId == MODULE_FEES_MANAGER_V2) return FEES_MANAGER_V2;
        if (moduleId == MODULE_OPTION_EXECUTION_FEE_ADAPTER) return OPTION_EXECUTION_FEE_ADAPTER;
        if (moduleId == MODULE_PROTOCOL_TIMELOCK) return PROTOCOL_TIMELOCK;
        if (moduleId == MODULE_GOVERNANCE) return GOVERNANCE;
        return GUARDIAN;
    }

    /// @notice Ordered dense array of every module slot address (including
    ///         zero-valued optional slots). Bounded length = `MODULE_COUNT`.
    function moduleAddresses() external view returns (address[] memory addrs) {
        addrs = new address[](MODULE_COUNT);
        addrs[MODULE_SUBACCOUNT_REGISTRY] = SUBACCOUNT_REGISTRY;
        addrs[MODULE_COLLATERAL_VAULT] = COLLATERAL_VAULT;
        addrs[MODULE_OPTIONS_POSITIONS_LEDGER] = OPTIONS_POSITIONS_LEDGER;
        addrs[MODULE_RISK_MODULE] = RISK_MODULE;
        addrs[MODULE_MARGIN_ENGINE] = MARGIN_ENGINE;
        addrs[MODULE_OPTION_MATCHING_ENGINE] = OPTION_MATCHING_ENGINE;
        addrs[MODULE_ESCAPE_CONTROLLER] = ESCAPE_CONTROLLER;
        addrs[MODULE_RECOVERY_FINALIZER] = RECOVERY_FINALIZER;
        addrs[MODULE_ORACLE_ADAPTER] = ORACLE_ADAPTER;
        addrs[MODULE_OPTIONS_RISK_PROVIDER] = OPTIONS_RISK_PROVIDER;
        addrs[MODULE_QUOTE_TOKEN] = QUOTE_TOKEN;
        addrs[MODULE_FEES_MANAGER_V2] = FEES_MANAGER_V2;
        addrs[MODULE_OPTION_EXECUTION_FEE_ADAPTER] = OPTION_EXECUTION_FEE_ADAPTER;
        addrs[MODULE_PROTOCOL_TIMELOCK] = PROTOCOL_TIMELOCK;
        addrs[MODULE_GOVERNANCE] = GOVERNANCE;
        addrs[MODULE_GUARDIAN] = GUARDIAN;
    }

    /// @notice Convenience: re-computes and returns the canonical manifest
    ///         hash from the current immutable state. Equal to
    ///         `MANIFEST_HASH` by construction; callable by tooling to
    ///         verify a suspected manifest instance without trusting its
    ///         stored value.
    function recomputeManifestHash() external view returns (bytes32) {
        bytes32 addrHash = _recomputeModuleAddressesHash();
        bytes32 configHash = _recomputeCriticalConfigHash();
        return keccak256(
            abi.encode(
                MANIFEST_TYPE_HASH, ENVIRONMENT_TAG, addrHash, configHash, DEPLOYMENT_BLOCK, DEPLOYMENT_TIMESTAMP
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireRequired(uint8 moduleId, address addr) internal view {
        if (addr == address(0)) revert ZeroAddress(moduleId);
        if (addr.code.length == 0) revert NoCode(moduleId, addr);
    }

    function _requireOptional(uint8 moduleId, address addr) internal view {
        if (addr == address(0)) return;
        if (addr.code.length == 0) revert NoCode(moduleId, addr);
    }

    function _requireNoDuplicates(ManifestParams memory p) internal pure {
        address[11] memory required = [
            p.subaccountRegistry,
            p.collateralVault,
            p.optionsPositionsLedger,
            p.riskModule,
            p.marginEngine,
            p.optionMatchingEngine,
            p.escapeController,
            p.recoveryFinalizer,
            p.oracleAdapter,
            p.optionsRiskProvider,
            p.quoteToken
        ];
        // Canonical module id lookup matches the array order above.
        uint8[11] memory ids = [
            MODULE_SUBACCOUNT_REGISTRY,
            MODULE_COLLATERAL_VAULT,
            MODULE_OPTIONS_POSITIONS_LEDGER,
            MODULE_RISK_MODULE,
            MODULE_MARGIN_ENGINE,
            MODULE_OPTION_MATCHING_ENGINE,
            MODULE_ESCAPE_CONTROLLER,
            MODULE_RECOVERY_FINALIZER,
            MODULE_ORACLE_ADAPTER,
            MODULE_OPTIONS_RISK_PROVIDER,
            MODULE_QUOTE_TOKEN
        ];
        for (uint256 i = 0; i < required.length; i++) {
            for (uint256 j = i + 1; j < required.length; j++) {
                if (required[i] == required[j]) revert DuplicateModuleAddress(ids[i], ids[j], required[i]);
            }
        }
    }

    function _recomputeModuleAddressesHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                MODULE_ADDRESSES_TYPE_HASH,
                SUBACCOUNT_REGISTRY,
                COLLATERAL_VAULT,
                OPTIONS_POSITIONS_LEDGER,
                RISK_MODULE,
                MARGIN_ENGINE,
                OPTION_MATCHING_ENGINE,
                ESCAPE_CONTROLLER,
                RECOVERY_FINALIZER,
                ORACLE_ADAPTER,
                OPTIONS_RISK_PROVIDER,
                QUOTE_TOKEN,
                FEES_MANAGER_V2,
                OPTION_EXECUTION_FEE_ADAPTER,
                PROTOCOL_TIMELOCK,
                GOVERNANCE,
                GUARDIAN
            )
        );
    }

    function _recomputeCriticalConfigHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                CRITICAL_CONFIG_TYPE_HASH,
                CHAIN_ID,
                ARCHITECTURE_VERSION,
                STORAGE_VERSION,
                EVENT_VERSION,
                DEPLOYMENT_VERSION,
                MANIFEST_SCHEMA_VERSION,
                PROTOCOL_FEE_SUBKEY,
                REBATE_BUDGET_SUBKEY,
                INSURANCE_FUND_SUBKEY,
                MAX_COLLATERAL_TOKENS_SNAPSHOT,
                MAX_ACTIVE_SERIES_PER_SUBACCOUNT_SNAPSHOT,
                ALL_CAPABILITIES_SNAPSHOT,
                RECOVERY_ACTIVATION_DELAY_SECONDS,
                RECOVERY_PAUSE_MAX_DURATION_BLOCKS
            )
        );
    }
}
