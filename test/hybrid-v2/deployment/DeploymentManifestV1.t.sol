// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {DeploymentManifestV1TestBase} from "./DeploymentManifestV1TestBase.sol";

import {DeploymentManifestV1} from "../../../src/hybrid-v2/deployment/DeploymentManifestV1.sol";
import {EscapeControllerV1} from "../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {RecoveryFinalizerV1} from "../../../src/hybrid-v2/recovery/RecoveryFinalizerV1.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {MarginEngineV2} from "../../../src/hybrid-v2/margin/MarginEngineV2.sol";
import {OptionMatchingEngineV2} from "../../../src/hybrid-v2/options/OptionMatchingEngineV2.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title DeploymentManifestV1Tests
/// @notice `ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-DEPLOYMENT-MANIFEST-V1` (WP-11)
///         unit + fuzz coverage for the immutable post-deployment manifest.
///         Covers `DEPLOYMENT_MANIFEST_WIRING_VALIDATED`,
///         `DEPLOYMENT_MANIFEST_HASH_CANONICAL_AND_DETERMINISTIC`, and
///         `BASE_SEPOLIA_ONLY_MANIFEST_SAFETY_VALIDATED`.
contract DeploymentManifestV1Tests is DeploymentManifestV1TestBase {
    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_construction_happyPath_setsImmutablesAndEmitsEvent() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        vm.recordLogs();
        DeploymentManifestV1 m = new DeploymentManifestV1(p);

        assertEq(m.CHAIN_ID(), block.chainid);
        assertEq(m.ARCHITECTURE_VERSION(), uint16(Versions.ARCHITECTURE_VERSION));
        assertEq(m.STORAGE_VERSION(), Versions.STORAGE_VERSION);
        assertEq(m.EVENT_VERSION(), Versions.EVENT_VERSION);
        assertEq(m.DEPLOYMENT_VERSION(), 1);
        assertEq(m.MANIFEST_SCHEMA_VERSION(), 1);
        assertEq(m.ENVIRONMENT_TAG(), bytes32("local"));
        assertEq(m.DEPLOYMENT_BLOCK(), uint64(block.number));
        assertEq(m.DEPLOYMENT_TIMESTAMP(), uint64(block.timestamp));
        assertEq(m.DEPLOYER(), address(this));

        assertEq(m.SUBACCOUNT_REGISTRY(), address(registry));
        assertEq(m.COLLATERAL_VAULT(), address(vault));
        assertEq(m.OPTIONS_POSITIONS_LEDGER(), address(ledger));
        assertEq(m.RISK_MODULE(), address(riskModule));
        assertEq(m.MARGIN_ENGINE(), address(marginEngine));
        assertEq(m.OPTION_MATCHING_ENGINE(), address(optionMatchingEngine));
        assertEq(m.ESCAPE_CONTROLLER(), address(escape));
        assertEq(m.RECOVERY_FINALIZER(), address(finalizer));

        assertEq(m.ORACLE_ADAPTER(), address(oracle));
        assertEq(m.OPTIONS_RISK_PROVIDER(), address(provider));
        assertEq(m.QUOTE_TOKEN(), address(usdc));

        assertEq(m.FEES_MANAGER_V2(), address(0));
        assertEq(m.OPTION_EXECUTION_FEE_ADAPTER(), address(feeHook));
        assertEq(m.PROTOCOL_TIMELOCK(), address(0));
        assertEq(m.GOVERNANCE(), governance);
        assertEq(m.GUARDIAN(), guardian);

        assertEq(m.PROTOCOL_FEE_SUBKEY(), vault.protocolFeeVaultSubKey());
        assertEq(m.REBATE_BUDGET_SUBKEY(), vault.rebateBudgetSubKey());
        assertEq(m.INSURANCE_FUND_SUBKEY(), vault.insuranceFundSubKey());

        assertEq(m.MAX_COLLATERAL_TOKENS_SNAPSHOT(), 8);
        assertEq(m.MAX_ACTIVE_SERIES_PER_SUBACCOUNT_SNAPSHOT(), 32);
        assertEq(m.ALL_CAPABILITIES_SNAPSHOT(), Capabilities.ALL_CAPABILITIES);
        assertEq(m.RECOVERY_ACTIVATION_DELAY_SECONDS(), ESCAPE_DELAY);
        assertEq(m.RECOVERY_PAUSE_MAX_DURATION_BLOCKS(), ESCAPE_PAUSE_MAX_BLOCKS);

        // Hashes match re-computed values.
        assertEq(m.recomputeManifestHash(), m.MANIFEST_HASH());
        assertTrue(m.MANIFEST_HASH() != bytes32(0));
        assertTrue(m.MODULE_ADDRESSES_HASH() != bytes32(0));
        assertTrue(m.CRITICAL_CONFIG_HASH() != bytes32(0));
        assertTrue(m.MANIFEST_HASH() != m.MODULE_ADDRESSES_HASH());
        assertTrue(m.MANIFEST_HASH() != m.CRITICAL_CONFIG_HASH());
        assertTrue(m.MODULE_ADDRESSES_HASH() != m.CRITICAL_CONFIG_HASH());

        // Event contains the manifest hash.
        (bytes32[] memory topics,) = _findLog(address(m), DeploymentManifestV1.DeploymentManifestDeclared.selector);
        assertEq(topics[1], m.MANIFEST_HASH());
        assertEq(uint256(topics[2]), block.chainid);
        assertEq(address(uint160(uint256(topics[3]))), address(this));
    }

    function test_view_moduleAddressOf_returnsEachSlot() external {
        DeploymentManifestV1 m = new DeploymentManifestV1(_defaultParams());
        assertEq(m.moduleAddressOf(m.MODULE_SUBACCOUNT_REGISTRY()), address(registry));
        assertEq(m.moduleAddressOf(m.MODULE_COLLATERAL_VAULT()), address(vault));
        assertEq(m.moduleAddressOf(m.MODULE_OPTIONS_POSITIONS_LEDGER()), address(ledger));
        assertEq(m.moduleAddressOf(m.MODULE_RISK_MODULE()), address(riskModule));
        assertEq(m.moduleAddressOf(m.MODULE_MARGIN_ENGINE()), address(marginEngine));
        assertEq(m.moduleAddressOf(m.MODULE_OPTION_MATCHING_ENGINE()), address(optionMatchingEngine));
        assertEq(m.moduleAddressOf(m.MODULE_ESCAPE_CONTROLLER()), address(escape));
        assertEq(m.moduleAddressOf(m.MODULE_RECOVERY_FINALIZER()), address(finalizer));
        assertEq(m.moduleAddressOf(m.MODULE_ORACLE_ADAPTER()), address(oracle));
        assertEq(m.moduleAddressOf(m.MODULE_OPTIONS_RISK_PROVIDER()), address(provider));
        assertEq(m.moduleAddressOf(m.MODULE_QUOTE_TOKEN()), address(usdc));
        assertEq(m.moduleAddressOf(m.MODULE_FEES_MANAGER_V2()), address(0));
        assertEq(m.moduleAddressOf(m.MODULE_OPTION_EXECUTION_FEE_ADAPTER()), address(feeHook));
        assertEq(m.moduleAddressOf(m.MODULE_PROTOCOL_TIMELOCK()), address(0));
        assertEq(m.moduleAddressOf(m.MODULE_GOVERNANCE()), governance);
        assertEq(m.moduleAddressOf(m.MODULE_GUARDIAN()), guardian);
    }

    function test_view_moduleAddresses_returnsDenseArray() external {
        DeploymentManifestV1 m = new DeploymentManifestV1(_defaultParams());
        address[] memory a = m.moduleAddresses();
        assertEq(a.length, m.MODULE_COUNT());
        assertEq(a[0], address(registry));
        assertEq(a[15], guardian);
    }

    function test_view_moduleAddressOf_rejectsOutOfRange() external {
        DeploymentManifestV1 m = new DeploymentManifestV1(_defaultParams());
        vm.expectRevert(
            abi.encodeWithSelector(DeploymentManifestV1.ModuleIndexOutOfRange.selector, uint8(16), uint8(15))
        );
        m.moduleAddressOf(16);
    }

    /*//////////////////////////////////////////////////////////////
                    BASE MAINNET / DEPLOYMENT VERSION
    //////////////////////////////////////////////////////////////*/

    function test_construction_rejectsBaseMainnet() external {
        vm.chainId(8453);
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.BaseMainnetForbidden.selector, uint256(8453)));
        new DeploymentManifestV1(p);
    }

    function test_construction_acceptsBaseSepoliaChainId() external {
        // Base Sepolia chain id is not itself special-cased; the check is
        // "not Base mainnet". Confirm construction works on 84532.
        vm.chainId(84532);
        DeploymentManifestV1 m = new DeploymentManifestV1(_defaultParamsWithRegistryOnChainId(84532));
        assertEq(m.CHAIN_ID(), 84532);
    }

    function test_construction_rejectsDeploymentVersionZero() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.deploymentVersion = 0;
        vm.expectRevert(DeploymentManifestV1.DeploymentVersionZero.selector);
        new DeploymentManifestV1(p);
    }

    /*//////////////////////////////////////////////////////////////
                        REQUIRED-ADDRESS CHECKS
    //////////////////////////////////////////////////////////////*/

    function test_construction_rejectsZeroSubaccountRegistry() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.subaccountRegistry = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(0)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroVault() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.collateralVault = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(1)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroLedger() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.optionsPositionsLedger = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(2)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroRiskModule() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.riskModule = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(3)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroMarginEngine() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.marginEngine = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(4)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroOptionMatchingEngine() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.optionMatchingEngine = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(5)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroEscape() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.escapeController = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(6)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroFinalizer() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.recoveryFinalizer = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(7)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroOracle() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.oracleAdapter = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(8)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroRiskProvider() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.optionsRiskProvider = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(9)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsZeroQuoteToken() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.quoteToken = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.ZeroAddress.selector, uint8(10)));
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsEoaRegistry() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.subaccountRegistry = address(0xBADC0DE);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.NoCode.selector, uint8(0), address(0xBADC0DE)));
        new DeploymentManifestV1(p);
    }

    function test_construction_acceptsEoaGovernanceAndGuardian() external {
        // Governance / guardian may be EOAs (multisig signers, dev keys).
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.governance = address(0xB0B0B0B0);
        p.guardian = address(0xB1B1B1B1);
        DeploymentManifestV1 m = new DeploymentManifestV1(p);
        assertEq(m.GOVERNANCE(), address(0xB0B0B0B0));
        assertEq(m.GUARDIAN(), address(0xB1B1B1B1));
    }

    function test_construction_rejectsEoaProtocolTimelock() external {
        // The timelock, when supplied, MUST be a contract.
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.protocolTimelock = address(0xB0B0B0B0);
        vm.expectRevert(abi.encodeWithSelector(DeploymentManifestV1.NoCode.selector, uint8(13), address(0xB0B0B0B0)));
        new DeploymentManifestV1(p);
    }

    function test_construction_acceptsZeroOptionalSlot() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.governance = address(0);
        p.guardian = address(0);
        p.protocolTimelock = address(0);
        p.feesManagerV2 = address(0);
        p.optionExecutionFeeAdapter = address(0);
        DeploymentManifestV1 m = new DeploymentManifestV1(p);
        assertEq(m.GOVERNANCE(), address(0));
        assertEq(m.GUARDIAN(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        DUPLICATE-ADDRESS CHECK
    //////////////////////////////////////////////////////////////*/

    function test_construction_rejectsDuplicateVaultAndRegistry() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.subaccountRegistry = address(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentManifestV1.DuplicateModuleAddress.selector, uint8(0), uint8(1), address(vault)
            )
        );
        new DeploymentManifestV1(p);
    }

    /*//////////////////////////////////////////////////////////////
                          WIRING MISMATCHES
    //////////////////////////////////////////////////////////////*/

    function test_construction_rejectsRegistryPointingElsewhere() external {
        // Deploy an alternate registry whose capabilityAuthority is a random
        // valid contract (usdc), then swap it into the params.
        SubaccountRegistry badRegistry = new SubaccountRegistry(address(usdc));
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.subaccountRegistry = address(badRegistry);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentManifestV1.CapabilityAuthorityMismatch.selector, address(vault), address(usdc)
            )
        );
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsUninitializedEscapeControllerBinding() external {
        // Rebuild a stack where escape controller is never bound to the vault.
        _rebuildWithoutEscapeInit();
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        vm.expectRevert(DeploymentManifestV1.EscapeControllerNotInitialized.selector);
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsUninitializedFinalizerBinding() external {
        _rebuildWithoutFinalizerInit();
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        vm.expectRevert(DeploymentManifestV1.RecoveryFinalizerNotInitialized.selector);
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsUninitializedProtocolSubaccounts() external {
        _rebuildWithoutProtocolInit();
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        vm.expectRevert(DeploymentManifestV1.ProtocolSubaccountsNotInitialized.selector);
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsMismatchedEscapeController() external {
        // Deploy a totally separate escape controller — it references the same
        // registry but the vault + finalizer bindings still point at `escape`.
        EscapeControllerV1 rogue =
            new EscapeControllerV1(address(registry), governance, ESCAPE_DELAY, ESCAPE_PAUSE_MAX_BLOCKS);
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.escapeController = address(rogue);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentManifestV1.EscapeControllerMismatch.selector, address(rogue), address(escape)
            )
        );
        new DeploymentManifestV1(p);
    }

    function test_construction_rejectsMismatchedRecoveryFinalizer() external {
        RecoveryFinalizerV1 rogue =
            new RecoveryFinalizerV1(address(registry), address(vault), address(escape), address(ledger));
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.recoveryFinalizer = address(rogue);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeploymentManifestV1.RecoveryFinalizerMismatch.selector, address(rogue), address(finalizer)
            )
        );
        new DeploymentManifestV1(p);
    }

    /*//////////////////////////////////////////////////////////////
                          HASH DETERMINISM
    //////////////////////////////////////////////////////////////*/

    function test_hash_deterministicForSameParams() external {
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();

        vm.roll(100);
        vm.warp(1_800_000_000);
        DeploymentManifestV1 m1 = new DeploymentManifestV1(p);
        bytes32 h1 = m1.MANIFEST_HASH();

        // Same block + timestamp + same params → same manifest hash despite
        // being a different contract address.
        DeploymentManifestV1 m2 = new DeploymentManifestV1(p);
        bytes32 h2 = m2.MANIFEST_HASH();

        assertEq(h1, h2, "manifest hash should be deterministic for identical inputs");
        assertEq(m1.MODULE_ADDRESSES_HASH(), m2.MODULE_ADDRESSES_HASH());
        assertEq(m1.CRITICAL_CONFIG_HASH(), m2.CRITICAL_CONFIG_HASH());
    }

    function test_hash_changesWhenDeploymentVersionChanges() external {
        DeploymentManifestV1.ManifestParams memory p1 = _defaultParams();
        DeploymentManifestV1.ManifestParams memory p2 = _defaultParams();
        p2.deploymentVersion = 2;

        DeploymentManifestV1 m1 = new DeploymentManifestV1(p1);
        DeploymentManifestV1 m2 = new DeploymentManifestV1(p2);

        assertTrue(m1.MANIFEST_HASH() != m2.MANIFEST_HASH());
        assertTrue(m1.CRITICAL_CONFIG_HASH() != m2.CRITICAL_CONFIG_HASH());
        assertEq(m1.MODULE_ADDRESSES_HASH(), m2.MODULE_ADDRESSES_HASH(), "addr hash unaffected by version");
    }

    function test_hash_changesWhenEnvironmentTagChanges() external {
        DeploymentManifestV1.ManifestParams memory p1 = _defaultParams();
        DeploymentManifestV1.ManifestParams memory p2 = _defaultParams();
        p2.environmentTag = bytes32("base-sepolia");

        DeploymentManifestV1 m1 = new DeploymentManifestV1(p1);
        DeploymentManifestV1 m2 = new DeploymentManifestV1(p2);
        assertTrue(m1.MANIFEST_HASH() != m2.MANIFEST_HASH());
        // Environment tag is a manifest-level field — not part of critical
        // config or module-address hashes.
        assertEq(m1.MODULE_ADDRESSES_HASH(), m2.MODULE_ADDRESSES_HASH());
        assertEq(m1.CRITICAL_CONFIG_HASH(), m2.CRITICAL_CONFIG_HASH());
    }

    function test_hash_changesWhenOptionalSlotChanges() external {
        DeploymentManifestV1.ManifestParams memory p1 = _defaultParams();
        DeploymentManifestV1.ManifestParams memory p2 = _defaultParams();
        // Any real contract address flips the module-addresses hash; usdc is
        // already deployed and satisfies the code check.
        p2.protocolTimelock = address(usdc);

        DeploymentManifestV1 m1 = new DeploymentManifestV1(p1);
        DeploymentManifestV1 m2 = new DeploymentManifestV1(p2);
        assertTrue(m1.MODULE_ADDRESSES_HASH() != m2.MODULE_ADDRESSES_HASH());
        assertTrue(m1.MANIFEST_HASH() != m2.MANIFEST_HASH());
    }

    /*//////////////////////////////////////////////////////////////
                          RECOMPUTE ROUND-TRIP
    //////////////////////////////////////////////////////////////*/

    function testFuzz_recomputeMatchesStored(uint16 dv, bytes32 tag) external {
        vm.assume(dv > 0);
        DeploymentManifestV1.ManifestParams memory p = _defaultParams();
        p.deploymentVersion = dv;
        p.environmentTag = tag;
        DeploymentManifestV1 m = new DeploymentManifestV1(p);
        assertEq(m.recomputeManifestHash(), m.MANIFEST_HASH());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _findLog(address emitter, bytes32 topic0) internal returns (bytes32[] memory topics, bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return (logs[i].topics, logs[i].data);
            }
        }
        revert("log not found");
    }

    function _defaultParamsWithRegistryOnChainId(uint256 chainId_)
        internal
        returns (DeploymentManifestV1.ManifestParams memory p)
    {
        // Rebuild the stack while `vm.chainId` is active so registry captures
        // the correct chain id in its immutable.
        vm.chainId(chainId_);
        _deployStack();
        _governanceWire();
        p = _defaultParams();
    }

    function _rebuildWithoutEscapeInit() internal {
        _deployStack();
        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        vault.initializeProtocolSubaccounts(protocolFeeOwner, 1, rebateBudgetOwner, 1, insuranceFundOwner, 1);
        // Deliberately skip: vault.initializeEscapeController.
        // We cannot init the finalizer if the escape isn't bound to it either — skip both.
        vm.stopPrank();
    }

    function _rebuildWithoutFinalizerInit() internal {
        _deployStack();
        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        vault.initializeProtocolSubaccounts(protocolFeeOwner, 1, rebateBudgetOwner, 1, insuranceFundOwner, 1);
        vault.initializeEscapeController(address(escape));
        escape.initializeRecoveryFinalizer(address(finalizer));
        // Deliberately skip: vault.initializeRecoveryFinalizer.
        vm.stopPrank();
    }

    function _rebuildWithoutProtocolInit() internal {
        _deployStack();
        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        // Deliberately skip: vault.initializeProtocolSubaccounts.
        vm.stopPrank();
    }
}
