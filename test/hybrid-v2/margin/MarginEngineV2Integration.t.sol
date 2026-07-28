// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginEngineV2} from "../../../src/hybrid-v2/margin/MarginEngineV2.sol";
import {IMarginEngine} from "../../../src/hybrid-v2/interfaces/IMarginEngine.sol";
import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {IOptionsRiskProvider} from "../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockOptionsRiskProvider} from "./harness/MockOptionsRiskProvider.sol";
import {MockOracleAdapter} from "./harness/MockOracleAdapter.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title MarginEngineV2Integration
/// @notice `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` — worst-case integration:
///         32 active series × 8 collateral tokens; full stack of Registry +
///         Vault + Ledger + RiskModule + MarginEngine.
contract MarginEngineV2Integration is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsRiskModuleV2 internal module;
    MarginEngineV2 internal engine;
    MockOptionsRiskProvider internal provider;
    MockOracleAdapter internal oracle;

    MockERC20 internal usdc;
    MockERC20[7] internal alts; // 7 non-quote collateral tokens (universe hits 8 total)

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
        for (uint256 i = 0; i < 7; i++) {
            alts[i] = new MockERC20("ALT", "ALT", uint8(6 + (i % 3) * 6));
        }

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

        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        for (uint256 i = 0; i < 7; i++) {
            vault.addSupportedToken(address(alts[i]));
        }
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.stopPrank();

        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();

        // Underlying + option risk config for a single WETH-like underlying used
        // by every series in the 32-series test.
        provider.setUnderlying(
            address(usdc), // trivial: underlying = quote → spot = 1
            IOptionsRiskProvider.UnderlyingRiskView({
                spotShockDownBps: 2000, spotShockUpBps: 2000, volShockDownBps: 0, volShockUpBps: 0, isEnabled: true
            })
        );
        provider.setOptionsRiskConfig(
            address(usdc),
            IOptionsRiskProvider.OptionsRiskConfigView({
                baseMaintenanceMarginPerContract: 1e8, // 1 quote unit floor
                imFactorBps: 12_000,
                oracleDownMmMultiplierBps: 20_000,
                isConfigured: true
            })
        );

        // Per-alt collateral haircut config (varying).
        for (uint256 i = 0; i < 7; i++) {
            provider.setCollateralRisk(
                address(alts[i]),
                IOptionsRiskProvider.CollateralRiskView({
                    creditFactorBps: uint16(5_000 + i * 500), // 50%, 55%, ..., 80%
                    isConfigured: true
                })
            );
            oracle.setPrice(address(alts[i]), address(usdc), 100e8, block.timestamp);
        }
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

    function _seriesAtm(uint256 seriesId) internal {
        provider.setSeries(
            seriesId,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: address(usdc), // spot = 1e8
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: 1e8, // ATM
                contractSize1e8: 1e8,
                isCall: true,
                isActive: true,
                exists: true
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                        WORST-CASE PORTFOLIO WALK
    //////////////////////////////////////////////////////////////*/

    function test_thirtyTwoSeriesEnumerable() public {
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory ids = new uint256[](32);
        // Configure 32 ATM call series with tiny quantities.
        for (uint256 i = 0; i < 32; i++) {
            uint256 seriesId = i + 1;
            _seriesAtm(seriesId);
            vm.prank(engineFill);
            ledger.applyFill(sk, seriesId, 1, 1e8, 100e8); // 1 short each
            ids[i] = seriesId;
        }
        assertEq(ledger.activeSeriesCount(sk), 32);
        // Each series contributes: intrinsic 0 (spot=strike=1), stressed = 1 * 0.2 = 0.2 (in 1e8: 20_000_000), floor 1e8.
        // mm per contract = max(0, 0.2, 1) = 1 (in 1e8).
        // contribution = 1e8 * 1e8 / 1e8 = 1e8. 32 series → 32e8 → 32e18.
        assertEq(engine.maintenanceMargin1e18(sk, ids), 32e18);
    }

    function test_eightCollateralTokensEnumerable() public {
        bytes32 sk = _sk(ownerA, 1);
        // Deposit 100 USDC (numeraire) + 1 of each alt.
        _fund(ownerA, 1, usdc, 100e6);
        for (uint256 i = 0; i < 7; i++) {
            // Use each token's native decimals.
            uint256 amt = 10 ** uint256(alts[i].decimals());
            _fund(ownerA, 1, alts[i], amt);
        }
        assertEq(vault.collateralTokenCount(), 8);

        uint256[] memory empty;
        uint256 available = engine.availableCollateral1e18(sk, empty);
        // USDC: 100 * 1e18 = 100e18.
        // Alt i: price 100, quantity 1 (native), credit i-th. Contribution = 100 * credit(i)/BPS * 1e18.
        // Sum alt = 100 * sum(5000..8000)/10000 = 100 * 45500/10000 * 1e18 = 455 * 1e18.
        // Total = 100e18 + 455e18 = 555e18.
        assertEq(available, 555e18);
    }

    function test_disabledTokenBalanceStillCounted() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, alts[0], 1e6);
        vm.prank(governance);
        vault.removeSupportedToken(address(alts[0]));
        uint256[] memory empty;
        // alts[0] has 6 decimals, price 100, credit 50%.
        // value1e8 = 1e6 * 100e8 / 1e6 = 100e8.
        // credited1e8 = 100e8 * 5000 / 10000 = 50e8.
        // 1e18 = 50e8 * 1e10 = 50e18.
        assertEq(engine.availableCollateral1e18(sk, empty), 50e18);
    }

    function test_donationExcluded() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6);
        // Donate directly.
        usdc.mint(ownerA, 500e6);
        vm.prank(ownerA);
        usdc.transfer(address(vault), 500e6);
        uint256[] memory empty;
        assertEq(engine.availableCollateral1e18(sk, empty), 100e18);
    }

    function test_worstCase32Series8Tokens_marginRatio() public {
        bytes32 sk = _sk(ownerA, 1);
        // Fund with USDC only.
        _fund(ownerA, 1, usdc, 1000e6); // 1000e18 available.
        uint256[] memory ids = new uint256[](32);
        for (uint256 i = 0; i < 32; i++) {
            uint256 seriesId = i + 1;
            _seriesAtm(seriesId);
            vm.prank(engineFill);
            ledger.applyFill(sk, seriesId, 1, 1e8, 100e8);
            ids[i] = seriesId;
        }
        // MM = 32e18, available = 1000e18 → ratio = 1000/32 * 1e18.
        uint256 ratio = engine.marginRatio1e18(sk, ids);
        assertEq(ratio, (1000e18 * 1e18) / 32e18);
    }

    /*//////////////////////////////////////////////////////////////
                            NO-MUTATION
    //////////////////////////////////////////////////////////////*/

    function test_noEconomicStateMutationDuringViewSweep() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 500e6);
        _seriesAtm(1);
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 1, 1e8, 100e8);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        uint256 balBefore = vault.balanceOf(sk, address(usdc));
        uint32 countBefore = ledger.activeSeriesCount(sk);
        uint256 lockedBefore = vault.lockedOf(sk, address(usdc));
        address ownerBefore = registry.ownerOf(sk);

        engine.maintenanceMargin1e18(sk, ids);
        engine.initialMargin1e18(sk, ids);
        engine.availableCollateral1e18(sk, ids);
        engine.marginRatio1e18(sk, ids);
        engine.isHealthy(sk, ids);

        assertEq(vault.balanceOf(sk, address(usdc)), balBefore);
        assertEq(uint256(ledger.activeSeriesCount(sk)), uint256(countBefore));
        assertEq(vault.lockedOf(sk, address(usdc)), lockedBefore);
        assertEq(registry.ownerOf(sk), ownerBefore);
    }

    /*//////////////////////////////////////////////////////////////
                       RM-1 SINGLE-MODULE POSTURE
    //////////////////////////////////////////////////////////////*/

    function test_engineAndVaultUseSameRiskModule() public view {
        assertEq(engine.riskModule(), address(module));
        assertEq(address(vault.RISK_MODULE()), address(module));
    }

    /*//////////////////////////////////////////////////////////////
                     RISK-REDUCING FLOW REMAINS OPEN
    //////////////////////////////////////////////////////////////*/

    function test_undercollateralizedAccountCannotBecomeHealthy_untilCollateralAdded() public {
        bytes32 sk = _sk(ownerA, 1);
        _fund(ownerA, 1, usdc, 100e6); // 100e18 available
        // Configure a series with a big MM (deep OTM put shocked hard).
        provider.setSeries(
            1,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: address(usdc), // spot = 1e8 = 1
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: 1000e8, // very deep ITM put
                contractSize1e8: 1e8,
                isCall: false,
                isActive: true,
                exists: true
            })
        );
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 1, 1e8, 100e8);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertFalse(engine.isHealthy(sk, ids));
        // Add collateral (risk-reducing: raises available margin).
        _fund(ownerA, 1, usdc, 5000e6);
        assertTrue(engine.isHealthy(sk, ids));
    }
}
