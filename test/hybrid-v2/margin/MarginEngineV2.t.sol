// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginEngineV2} from "../../../src/hybrid-v2/margin/MarginEngineV2.sol";
import {IMarginEngine} from "../../../src/hybrid-v2/interfaces/IMarginEngine.sol";
import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {IOptionsRiskProvider} from "../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockOptionsRiskProvider} from "./harness/MockOptionsRiskProvider.sol";
import {MockOracleAdapter} from "./harness/MockOracleAdapter.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title MarginEngineV2Test
/// @notice `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` — unit + fuzz for the
///         WP-08 read-only orchestration boundary.
contract MarginEngineV2Test is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsRiskModuleV2 internal module;
    MarginEngineV2 internal engine;
    MockOptionsRiskProvider internal provider;
    MockOracleAdapter internal oracle;

    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal WETH_UNDERLYING;
    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal engineSettle = address(0xE2);
    address internal engineLiquidate = address(0xE3);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    uint16 internal constant MOD_VERSION = 1;
    uint256 internal constant MAX_STALE = 1 hours;

    // Frozen risk parameters for tests.
    uint64 internal constant SPOT_SHOCK_UP_BPS = 2500;
    uint64 internal constant SPOT_SHOCK_DOWN_BPS = 2500;
    uint128 internal constant BASE_MM_1E8 = 5e8; // 5 quote units per contract
    uint32 internal constant IM_FACTOR_BPS = 12_000; // 120%
    uint32 internal constant ORACLE_DOWN_MULT_BPS = 20_000; // 2x

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        provider = new MockOptionsRiskProvider();
        oracle = new MockOracleAdapter();
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        WETH_UNDERLYING = address(weth);

        uint256 nonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), nonce + 2);

        module = new OptionsRiskModuleV2(
            address(registry),
            predictedVault,
            predictedLedger,
            MOD_VERSION,
            address(provider),
            address(oracle),
            address(usdc),
            6,
            MAX_STALE
        );
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        engine = new MarginEngineV2(address(vault), 1);
        require(
            address(module) == predictedModule && address(vault) == predictedVault
                && address(ledger) == predictedLedger,
            "predict mismatch"
        );

        // Wire capabilities.
        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vault.setEngineCapability(engineSettle, Capabilities.CAP_SETTLE_OPTION, true);
        vault.setEngineCapability(engineLiquidate, Capabilities.CAP_LIQUIDATE_OPTIONS, true);
        vm.stopPrank();

        // Register owners.
        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerA);
        registry.registerNext(); // Account 2
        vm.prank(ownerB);
        registry.registerNext();

        // Configure risk provider for WETH options with USDC settlement.
        provider.setUnderlying(
            WETH_UNDERLYING,
            IOptionsRiskProvider.UnderlyingRiskView({
                spotShockDownBps: SPOT_SHOCK_DOWN_BPS,
                spotShockUpBps: SPOT_SHOCK_UP_BPS,
                volShockDownBps: 0,
                volShockUpBps: 0,
                isEnabled: true
            })
        );
        provider.setOptionsRiskConfig(
            WETH_UNDERLYING,
            IOptionsRiskProvider.OptionsRiskConfigView({
                baseMaintenanceMarginPerContract: BASE_MM_1E8,
                imFactorBps: IM_FACTOR_BPS,
                oracleDownMmMultiplierBps: ORACLE_DOWN_MULT_BPS,
                isConfigured: true
            })
        );

        // Seed WETH spot price @ 3000.
        oracle.setPrice(WETH_UNDERLYING, address(usdc), 3000e8, block.timestamp);
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    function _fund(address o, uint32 id, MockERC20 t, uint256 amt) internal {
        t.mint(o, amt);
        vm.prank(o);
        t.approve(address(vault), amt);
        vm.prank(o);
        vault.deposit(id, address(t), amt);
    }

    function _series(uint256 seriesId, address underlying_, uint64 strike1e8, bool isCall) internal {
        provider.setSeries(
            seriesId,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: underlying_,
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: strike1e8,
                contractSize1e8: 1e8,
                isCall: isCall,
                isActive: true,
                exists: true
            })
        );
    }

    function _fill(bytes32 sk, uint256 seriesId, uint8 side, uint128 q) internal {
        vm.prank(engineFill);
        ledger.applyFill(sk, seriesId, side, q, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_bindsAllReferences() public view {
        assertEq(engine.vault(), address(vault));
        assertEq(engine.riskModule(), address(module));
        assertEq(address(engine.REGISTRY()), address(registry));
        assertEq(address(engine.OPTIONS_LEDGER()), address(ledger));
        assertEq(address(engine.RISK_PROVIDER()), address(provider));
        assertEq(address(engine.ORACLE()), address(oracle));
        assertEq(engine.QUOTE_TOKEN(), address(usdc));
        assertEq(uint256(engine.QUOTE_DECIMALS()), 6);
        assertEq(uint256(engine.ENGINE_VERSION()), 1);
    }

    function test_constructor_rejectsZeroEngineVersion() public {
        vm.expectRevert(MarginEngineV2.InvalidEngineVersion.selector);
        new MarginEngineV2(address(vault), 0);
    }

    function test_constructor_rejectsZeroVault() public {
        // Inherited from VaultRiskModuleConsumer.
        vm.expectRevert();
        new MarginEngineV2(address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////
                          WITNESS VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_zeroSubKeyReverts() public {
        uint256[] memory empty;
        vm.expectRevert(IMarginEngine.SubKeyRequired.selector);
        engine.maintenanceMargin1e18(bytes32(0), empty);
    }

    function test_unknownSubaccountReverts() public {
        bytes32 fakeSk = keccak256("not-registered");
        uint256[] memory empty;
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.UnknownSubaccount.selector, fakeSk));
        engine.maintenanceMargin1e18(fakeSk, empty);
    }

    function test_incompleteWitnessReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8); // 1 short
        uint256[] memory empty; // missing the series
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.IncompleteActiveSeriesWitness.selector, sk));
        engine.maintenanceMargin1e18(sk, empty);
    }

    function test_extraSeriesInWitnessReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _series(2, WETH_UNDERLYING, 3100e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory extra = new uint256[](2);
        extra[0] = 1;
        extra[1] = 2;
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.IncompleteActiveSeriesWitness.selector, sk));
        engine.maintenanceMargin1e18(sk, extra);
    }

    function test_outOfOrderWitnessReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _series(2, WETH_UNDERLYING, 3100e8, true);
        _fill(sk, 1, 1, 1e8);
        _fill(sk, 2, 1, 1e8);
        uint256[] memory rev = new uint256[](2);
        rev[0] = 2;
        rev[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.IncompleteActiveSeriesWitness.selector, sk));
        engine.maintenanceMargin1e18(sk, rev);
    }

    function test_duplicateWitnessReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory dup = new uint256[](2);
        dup[0] = 1;
        dup[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(IMarginEngine.IncompleteActiveSeriesWitness.selector, sk));
        engine.maintenanceMargin1e18(sk, dup);
    }

    /*//////////////////////////////////////////////////////////////
                         MAINTENANCE / INITIAL MARGIN
    //////////////////////////////////////////////////////////////*/

    function test_zeroPortfolio_marginsAreZero() public view {
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory empty;
        assertEq(engine.maintenanceMargin1e18(sk, empty), 0);
        assertEq(engine.initialMargin1e18(sk, empty), 0);
    }

    function test_singleShortCallAtTheMoney_mm() public {
        bytes32 sk = _sk(ownerA, 1);
        // Series 1: ATM call, strike = spot = 3000.
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8); // 1 short contract

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        // spot=3000, strike=3000.
        // intrinsic call = 0.
        // stressed call = spot * (1 + 25%) - strike = 3750 - 3000 = 750.
        // floor = 5.
        // mm = max(0, 750, 5) = 750 (in 1e8).
        // Portfolio contribution = 1e8 * 750e8 / 1e8 = 750e8.
        // 1e18 = 750e8 * 1e10 = 750e18.
        assertEq(engine.maintenanceMargin1e18(sk, ids), 750e18);
    }

    function test_singleShortCall_im() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        // im = ceil(mm * 12_000 / 10_000) = ceil(750 * 1.2) = 900.
        assertEq(engine.initialMargin1e18(sk, ids), 900e18);
    }

    function test_longOnlyContributesZero() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 0, 5e8); // 5 LONG contracts
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertEq(engine.maintenanceMargin1e18(sk, ids), 0);
        assertEq(engine.initialMargin1e18(sk, ids), 0);
    }

    function test_shortPut_stressedIsDominant() public {
        bytes32 sk = _sk(ownerA, 1);
        // ATM put, strike = 3000.
        _series(1, WETH_UNDERLYING, 3000e8, false);
        _fill(sk, 1, 1, 1e8); // 1 short put
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // intrinsic put = max(3000 - 3000, 0) = 0.
        // stressed put = max(3000 - 3000*(1-25%), 0) = max(3000 - 2250, 0) = 750.
        // mm = 750.
        assertEq(engine.maintenanceMargin1e18(sk, ids), 750e18);
    }

    function test_stalePrice_usesOracleDownPath() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        vm.warp(block.timestamp + MAX_STALE + 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // Oracle-down path: base * oracleDownMult / BPS = 5 * 20_000/10_000 = 10 (in 1e8).
        // Portfolio: 1e8 * 10e8 / 1e8 = 10e8 → 10e18.
        assertEq(engine.maintenanceMargin1e18(sk, ids), 10e18);
    }

    function test_unknownSeriesFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        // Fill but do NOT set the series metadata.
        _fill(sk, 42, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 42;
        vm.expectRevert(IMarginEngine.RiskModuleUnavailable.selector);
        engine.maintenanceMargin1e18(sk, ids);
    }

    function test_inactiveSeriesFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        provider.setSeries(
            1,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: WETH_UNDERLYING,
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: 3000e8,
                contractSize1e8: 1e8,
                isCall: true,
                isActive: false, // <-- disabled
                exists: true
            })
        );
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(IMarginEngine.RiskModuleUnavailable.selector);
        engine.maintenanceMargin1e18(sk, ids);
    }

    function test_wrongSettlementAssetFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        provider.setSeries(
            1,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: WETH_UNDERLYING,
                settlementAsset: address(0xBEEF), // != QUOTE_TOKEN
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: 3000e8,
                contractSize1e8: 1e8,
                isCall: true,
                isActive: true,
                exists: true
            })
        );
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(IMarginEngine.RiskModuleUnavailable.selector);
        engine.maintenanceMargin1e18(sk, ids);
    }

    function test_invalidContractSizeFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        provider.setSeries(
            1,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: WETH_UNDERLYING,
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: 3000e8,
                contractSize1e8: 2e8, // wrong
                isCall: true,
                isActive: true,
                exists: true
            })
        );
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(IMarginEngine.RiskModuleUnavailable.selector);
        engine.maintenanceMargin1e18(sk, ids);
    }

    function test_imFactorBelowBpsFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        provider.setOptionsRiskConfig(
            WETH_UNDERLYING,
            IOptionsRiskProvider.OptionsRiskConfigView({
                baseMaintenanceMarginPerContract: BASE_MM_1E8,
                imFactorBps: 9_000, // < BPS
                oracleDownMmMultiplierBps: ORACLE_DOWN_MULT_BPS,
                isConfigured: true
            })
        );
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(IMarginEngine.RiskModuleUnavailable.selector);
        engine.maintenanceMargin1e18(sk, ids);
    }

    /*//////////////////////////////////////////////////////////////
                             MARGIN EXCESS / RATIO
    //////////////////////////////////////////////////////////////*/

    function test_marginExcess_healthyAccount() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 2000e6); // 2000 USDC → 2000e18
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8); // MM = 750e18
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // excess = 2000 - 750 = 1250e18.
        assertEq(engine.marginExcess1e18(sk, ids), 1250e18);
    }

    function test_marginExcess_undercollateralizedIsZero() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 500e6); // 500 USDC → 500e18
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8); // MM = 750e18 > 500
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertEq(engine.marginExcess1e18(sk, ids), 0);
    }

    function test_marginRatio_healthy() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 1500e6); // 1500e18
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8); // 750e18
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // ratio = 1500 * 1e18 / 750 = 2e18.
        assertEq(engine.marginRatio1e18(sk, ids), 2e18);
    }

    function test_marginRatio_zeroMmReturnsMax() public view {
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory empty;
        assertEq(engine.marginRatio1e18(sk, empty), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              IS HEALTHY
    //////////////////////////////////////////////////////////////*/

    function test_isHealthy_true() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 2000e6);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertTrue(engine.isHealthy(sk, ids));
    }

    function test_isHealthy_false_undercollateralized() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 500e6);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertFalse(engine.isHealthy(sk, ids));
    }

    function test_isHealthy_false_incompleteWitnessNoRevert() public {
        bytes32 sk = _sk(ownerA, 1);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory empty;
        // isHealthy MUST NOT revert on incomplete witness. Returns false.
        assertFalse(engine.isHealthy(sk, empty));
    }

    function test_isHealthy_false_unknownSubaccountNoRevert() public view {
        bytes32 fake = keccak256("nope");
        uint256[] memory empty;
        assertFalse(engine.isHealthy(fake, empty));
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION STATUS
    //////////////////////////////////////////////////////////////*/

    function test_liquidationStatus_healthy() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 2000e6);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertEq(uint8(engine.liquidationStatus(sk, ids)), uint8(LiquidationStatus.HEALTHY));
    }

    function test_liquidationStatus_eligible() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 500e6);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(sk, 1, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertEq(uint8(engine.liquidationStatus(sk, ids)), uint8(LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION));
    }

    function test_liquidationStatus_indeterminateReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        // Fill but don't set metadata → per-series resolution fails → revert.
        _fill(sk, 42, 1, 1e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 42;
        vm.expectRevert(IMarginEngine.RiskModuleUnavailable.selector);
        engine.liquidationStatus(sk, ids);
    }

    /*//////////////////////////////////////////////////////////////
                          SIBLING ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_siblingSubaccount_untouched() public {
        bytes32 skA1 = _sk(ownerA, 1);
        bytes32 skA2 = _sk(ownerA, 2);
        _fund(ownerA, 1, usdc, 1000e6);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(skA1, 1, 1, 1e8);

        // Account 1 has MM = 750e18, available 1000e18.
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertEq(engine.maintenanceMargin1e18(skA1, ids), 750e18);

        // Account 2 has zero portfolio + zero collateral.
        uint256[] memory empty;
        assertEq(engine.maintenanceMargin1e18(skA2, empty), 0);
        assertEq(engine.availableCollateral1e18(skA2, empty), 0);
    }

    function test_siblingOwner_untouched() public {
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        _fund(ownerA, 1, usdc, 1000e6);
        _series(1, WETH_UNDERLYING, 3000e8, true);
        _fill(skA, 1, 1, 1e8);

        uint256[] memory empty;
        assertEq(engine.maintenanceMargin1e18(skB, empty), 0);
        assertEq(engine.availableCollateral1e18(skB, empty), 0);
    }
}
