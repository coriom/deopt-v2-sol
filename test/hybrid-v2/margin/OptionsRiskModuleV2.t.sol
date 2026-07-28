// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {RiskModuleV2} from "../../../src/hybrid-v2/risk/RiskModuleV2.sol";
import {IOptionsRiskProvider} from "../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockOptionsRiskProvider} from "./harness/MockOptionsRiskProvider.sol";
import {MockOracleAdapter} from "./harness/MockOracleAdapter.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title OptionsRiskModuleV2Test
/// @notice `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` — unit + fuzz for the
///         concrete WP-08 Options RiskModule provider (Part E-I).
contract OptionsRiskModuleV2Test is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsRiskModuleV2 internal module;
    MockOptionsRiskProvider internal provider;
    MockOracleAdapter internal oracle;

    MockERC20 internal usdc; // quote token, 6 decimals
    MockERC20 internal weth; // volatile collateral, 18 decimals
    MockERC20 internal wbtc; // volatile collateral, 8 decimals

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    uint16 internal constant MOD_VERSION = 1;
    uint256 internal constant MAX_STALE = 1 hours;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        provider = new MockOptionsRiskProvider();
        oracle = new MockOracleAdapter();
        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        wbtc = new MockERC20("WBTC", "WBTC", 8);

        // Predict module → vault → ledger addresses from the CURRENT nonce.
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
            6, // quoteDecimals
            MAX_STALE
        );
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        require(
            address(module) == predictedModule && address(vault) == predictedVault
                && address(ledger) == predictedLedger,
            "predict mismatch"
        );

        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        vault.addSupportedToken(address(weth));
        vault.addSupportedToken(address(wbtc));
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.stopPrank();

        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();

        // Configure collateral risk views.
        provider.setCollateralRisk(
            address(weth), IOptionsRiskProvider.CollateralRiskView({creditFactorBps: 8_000, isConfigured: true})
        );
        provider.setCollateralRisk(
            address(wbtc), IOptionsRiskProvider.CollateralRiskView({creditFactorBps: 7_500, isConfigured: true})
        );

        // Seed prices.
        oracle.setPrice(address(weth), address(usdc), 3_000e8, block.timestamp);
        oracle.setPrice(address(wbtc), address(usdc), 60_000e8, block.timestamp);
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

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_rejectsZeroProvider() public {
        vm.expectRevert(OptionsRiskModuleV2.InvalidRiskProvider.selector);
        new OptionsRiskModuleV2(
            address(registry), address(vault), address(ledger), 1, address(0), address(oracle), address(usdc), 6, 3600
        );
    }

    function test_constructor_rejectsZeroOracle() public {
        vm.expectRevert(OptionsRiskModuleV2.InvalidOracleAdapter.selector);
        new OptionsRiskModuleV2(
            address(registry), address(vault), address(ledger), 1, address(provider), address(0), address(usdc), 6, 3600
        );
    }

    function test_constructor_rejectsZeroQuoteToken() public {
        vm.expectRevert(OptionsRiskModuleV2.InvalidQuoteToken.selector);
        new OptionsRiskModuleV2(
            address(registry),
            address(vault),
            address(ledger),
            1,
            address(provider),
            address(oracle),
            address(0),
            6,
            3600
        );
    }

    function test_constructor_rejectsZeroStale() public {
        vm.expectRevert(OptionsRiskModuleV2.InvalidStalenessBound.selector);
        new OptionsRiskModuleV2(
            address(registry),
            address(vault),
            address(ledger),
            1,
            address(provider),
            address(oracle),
            address(usdc),
            6,
            0
        );
    }

    function test_constructor_rejectsZeroQuoteDecimals() public {
        vm.expectRevert(OptionsRiskModuleV2.InvalidQuoteDecimals.selector);
        new OptionsRiskModuleV2(
            address(registry),
            address(vault),
            address(ledger),
            1,
            address(provider),
            address(oracle),
            address(usdc),
            0,
            3600
        );
    }

    function test_constructor_bindsImmutables() public view {
        assertEq(address(module.RISK_PROVIDER()), address(provider));
        assertEq(address(module.ORACLE()), address(oracle));
        assertEq(module.QUOTE_TOKEN(), address(usdc));
        assertEq(uint256(module.QUOTE_DECIMALS()), 6);
        assertEq(module.MAX_ORACLE_STALE_SECONDS(), MAX_STALE);
    }

    /*//////////////////////////////////////////////////////////////
                        _computeMarginRequirement
    //////////////////////////////////////////////////////////////*/

    function test_marginRequirement_zeroPortfolioReturnsZero() public view {
        bytes32 sk = _sk(ownerA, 1);
        // No active series → 0 exactly (deterministic).
        assertEq(module.marginRequirement(sk), 0);
    }

    function test_marginRequirement_nonZeroPortfolioFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 0, 10, 100e8); // 1 long series
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.marginRequirement(sk);
    }

    function test_marginHealthy_zeroPortfolioIsHealthy() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertTrue(module.marginHealthy(sk));
    }

    function test_marginHealthy_activeSeriesReturnsFalse() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 1, 10, 100e8); // short → active
        assertFalse(module.marginHealthy(sk));
    }

    /*//////////////////////////////////////////////////////////////
                          _computeAvailableMargin
    //////////////////////////////////////////////////////////////*/

    function test_availableMargin_quoteTokenBalance() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6); // 100 USDC
        // 100 USDC × 100% credit → 100 quote units → 1e8 in 1e8 → 100e18 in 1e18
        assertEq(module.availableMargin(sk), 100e18);
    }

    function test_availableMargin_multipleTokens() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6); // 100 USDC → 100e18
        _fund(ownerA, 1, weth, 1e18); // 1 WETH @ 3000, 80% credit → 2400 → 2400e18
        _fund(ownerA, 1, wbtc, 1e8); // 1 WBTC @ 60000, 75% credit → 45000 → 45000e18
        uint256 total = module.availableMargin(sk);
        assertEq(total, (100 + 2400 + 45000) * 1e18);
    }

    function test_availableMargin_unconfiguredTokenFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        // WETH is deposited but its haircut is UNCONFIGURED at test setup time.
        // Reconfigure by unsetting.
        provider.setCollateralRisk(
            address(weth), IOptionsRiskProvider.CollateralRiskView({creditFactorBps: 0, isConfigured: false})
        );
        _fund(ownerA, 1, weth, 1e18);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.availableMargin(sk);
    }

    function test_availableMargin_stalePriceFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, weth, 1e18);
        // Warp forward beyond the freshness bound.
        vm.warp(block.timestamp + MAX_STALE + 1);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.availableMargin(sk);
    }

    function test_availableMargin_futureTimestampFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, weth, 1e18);
        oracle.setPrice(address(weth), address(usdc), 3_000e8, block.timestamp + 100);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.availableMargin(sk);
    }

    function test_availableMargin_priceZeroFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, weth, 1e18);
        oracle.setPrice(address(weth), address(usdc), 0, block.timestamp);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.availableMargin(sk);
    }

    function test_availableMargin_oracleUnavailableFailsClosed() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, weth, 1e18);
        oracle.setUnavailable(address(weth), address(usdc));
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.availableMargin(sk);
    }

    function test_availableMargin_donationExcluded() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6);
        // Donate directly to the vault contract (bypass deposit accounting).
        usdc.mint(ownerA, 500e6);
        vm.prank(ownerA);
        usdc.transfer(address(vault), 500e6);
        // Available margin still reflects only accounted balance (100 USDC).
        assertEq(module.availableMargin(sk), 100e18);
    }

    function test_availableMargin_disabledTokenStillValued() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, weth, 1e18);
        // Disable WETH for new deposits — balance remains + isKnown stays true.
        vm.prank(governance);
        vault.removeSupportedToken(address(weth));
        assertEq(module.availableMargin(sk), 2400 * 1e18);
    }

    function test_availableMargin_zeroBalanceEverywhereReturnsZero() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertEq(module.availableMargin(sk), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             withdrawalAllowed
    //////////////////////////////////////////////////////////////*/

    function test_withdrawalAllowed_happyPath() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6);
        // Withdrawing 50 USDC → post = 50 USDC = 50e18 >= 0 required → allowed.
        assertTrue(module.withdrawalAllowed(sk, address(usdc), 50e6));
    }

    function test_withdrawalAllowed_exceedsAvailableRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6);
        assertFalse(module.withdrawalAllowed(sk, address(usdc), 200e6));
    }

    function test_withdrawalAllowed_activeSeriesRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6);
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 1, 10, 100e8); // short → active
        // Fail-closed because _computeMarginRequirement returns (0, false).
        assertFalse(module.withdrawalAllowed(sk, address(usdc), 50e6));
    }

    function test_withdrawalAllowed_zeroSubKeyRejected() public view {
        assertFalse(module.withdrawalAllowed(bytes32(0), address(usdc), 1));
    }

    function test_withdrawalAllowed_zeroAmountRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6);
        assertFalse(module.withdrawalAllowed(sk, address(usdc), 0));
    }

    function test_withdrawalAllowed_zeroTokenRejected() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertFalse(module.withdrawalAllowed(sk, address(0), 1));
    }

    function test_withdrawalAllowed_unsupportedTokenRejected() public view {
        bytes32 sk = _sk(ownerA, 1);
        // Random address (not enabled in vault).
        assertFalse(module.withdrawalAllowed(sk, address(0xDEADBEEF), 1));
    }

    /*//////////////////////////////////////////////////////////////
                           collateralValue1e18
    //////////////////////////////////////////////////////////////*/

    function test_collateralValue_publicHelper() public view {
        (uint256 v, bool ok) = module.collateralValue1e18(address(usdc), 100e6);
        assertTrue(ok);
        assertEq(v, 100e18);
    }

    function test_collateralValue_zeroBalanceIsOkTrue() public view {
        (uint256 v, bool ok) = module.collateralValue1e18(address(usdc), 0);
        assertTrue(ok);
        assertEq(v, 0);
    }

    function test_collateralValue_unknownTokenFailsClosed() public view {
        (uint256 v, bool ok) = module.collateralValue1e18(address(0xDEAD), 1e18);
        assertFalse(ok);
        assertEq(v, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_availableMargin_usdcOnly(uint128 amount) public {
        vm.assume(amount > 0 && amount < 1e30);
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, amount);
        // 1 USDC (native 1e6) → 1e10 in 1e8 → 1e20 in 1e18. Actually:
        // amount = X native units of a 6-dec token, price = 1e8.
        // value1e8 = X * 1e8 / 1e6 = X * 100.
        // credit = X * 100 (100% credit).
        // 1e18 = credit * 1e10 = X * 100 * 1e10 = X * 1e12.
        assertEq(module.availableMargin(sk), uint256(amount) * 1e12);
    }
}
