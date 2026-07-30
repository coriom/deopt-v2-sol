// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeploymentManifestV1} from "../../../src/hybrid-v2/deployment/DeploymentManifestV1.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {MarginEngineV2} from "../../../src/hybrid-v2/margin/MarginEngineV2.sol";
import {OptionMatchingEngineV2} from "../../../src/hybrid-v2/options/OptionMatchingEngineV2.sol";
import {EscapeControllerV1} from "../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {RecoveryFinalizerV1} from "../../../src/hybrid-v2/recovery/RecoveryFinalizerV1.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockOptionsRiskProvider} from "../margin/harness/MockOptionsRiskProvider.sol";
import {MockOracleAdapter} from "../margin/harness/MockOracleAdapter.sol";
import {MockOptionExecutionFeeHook} from "../options/harness/MockOptionExecutionFeeHook.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title DeploymentManifestV1TestBase
/// @notice Shared fixture that spins up a fully-wired Hybrid V2 stack —
///         Registry ↔ Vault ↔ Ledger ↔ RiskModule ↔ MarginEngine ↔ Options
///         engine ↔ EscapeController ↔ RecoveryFinalizer — with every
///         one-shot init already run. Any test suite that needs a valid
///         `DeploymentManifestV1` builds from this base.
abstract contract DeploymentManifestV1TestBase is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsRiskModuleV2 internal riskModule;
    MarginEngineV2 internal marginEngine;
    OptionMatchingEngineV2 internal optionMatchingEngine;
    EscapeControllerV1 internal escape;
    RecoveryFinalizerV1 internal finalizer;

    MockOptionsRiskProvider internal provider;
    MockOracleAdapter internal oracle;
    MockOptionExecutionFeeHook internal feeHook;
    MockERC20 internal usdc;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal deployer = address(this);
    address internal protocolFeeOwner = address(0xF001);
    address internal rebateBudgetOwner = address(0xF002);
    address internal insuranceFundOwner = address(0xF003);
    address internal timelock = address(0xC001);

    uint16 internal constant MOD_VERSION = 1;
    uint16 internal constant ENGINE_VERSION = 1;
    uint256 internal constant MAX_STALE = 1 hours;
    uint64 internal constant ESCAPE_DELAY = 3600;
    uint64 internal constant ESCAPE_PAUSE_MAX_BLOCKS = 3600;

    function setUp() public virtual {
        provider = new MockOptionsRiskProvider();
        oracle = new MockOracleAdapter();
        usdc = new MockERC20("USDC", "USDC", 6);
        feeHook = new MockOptionExecutionFeeHook();

        _deployStack();
        _governanceWire();
    }

    /// @dev Deploys the core stack with fully cross-consistent immutables.
    ///      Uses `vm.computeCreateAddress` because Registry / Vault / Ledger
    ///      are mutually referential via constructor arguments.
    function _deployStack() internal {
        uint256 n = vm.getNonce(address(this));
        // Position 0: RiskModule. Needs (registry, vault, ledger) predicted.
        address predRiskModule = vm.computeCreateAddress(address(this), n + 0);
        address predVault = vm.computeCreateAddress(address(this), n + 1);
        address predRegistry = vm.computeCreateAddress(address(this), n + 2);
        address predLedger = vm.computeCreateAddress(address(this), n + 3);

        riskModule = new OptionsRiskModuleV2(
            predRegistry,
            predVault,
            predLedger,
            MOD_VERSION,
            address(provider),
            address(oracle),
            address(usdc),
            6,
            MAX_STALE
        );
        require(address(riskModule) == predRiskModule, "predict RM");

        vault = new RiskAwareVaultHarness(predRegistry, governance, guardian, address(riskModule));
        require(address(vault) == predVault, "predict Vault");

        registry = new SubaccountRegistry(address(vault));
        require(address(registry) == predRegistry, "predict Reg");

        ledger = new OptionsPositionsLedger(address(registry), address(vault));
        require(address(ledger) == predLedger, "predict Ledger");

        escape = new EscapeControllerV1(address(registry), governance, ESCAPE_DELAY, ESCAPE_PAUSE_MAX_BLOCKS);
        finalizer = new RecoveryFinalizerV1(address(registry), address(vault), address(escape), address(ledger));
        marginEngine = new MarginEngineV2(address(vault), ENGINE_VERSION);
        optionMatchingEngine = new OptionMatchingEngineV2(
            address(vault), address(marginEngine), address(feeHook), guardian, governance, ENGINE_VERSION
        );
    }

    function _governanceWire() internal {
        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        vault.initializeProtocolSubaccounts(protocolFeeOwner, 1, rebateBudgetOwner, 1, insuranceFundOwner, 1);
        vault.initializeEscapeController(address(escape));
        vault.initializeRecoveryFinalizer(address(finalizer));
        escape.initializeRecoveryFinalizer(address(finalizer));
        vm.stopPrank();
    }

    function _defaultParams() internal view returns (DeploymentManifestV1.ManifestParams memory p) {
        p = DeploymentManifestV1.ManifestParams({
            environmentTag: bytes32("local"),
            deploymentVersion: 1,
            subaccountRegistry: address(registry),
            collateralVault: address(vault),
            optionsPositionsLedger: address(ledger),
            riskModule: address(riskModule),
            marginEngine: address(marginEngine),
            optionMatchingEngine: address(optionMatchingEngine),
            escapeController: address(escape),
            recoveryFinalizer: address(finalizer),
            oracleAdapter: address(oracle),
            optionsRiskProvider: address(provider),
            quoteToken: address(usdc),
            feesManagerV2: address(0),
            optionExecutionFeeAdapter: address(feeHook),
            protocolTimelock: address(0),
            governance: governance,
            guardian: guardian
        });
    }
}
