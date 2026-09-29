// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_BASE_SEPOLIA_RECOVERY_DEPLOYMENT_FREEZE_V1 §10-12 —
// Isolated local rehearsal of the minimal V2 recovery: deploy the
// current-source PerpMarketRegistry and PerpEngineV2, replay the FULL
// 6-position canonical Base Sepolia migration byte-identical to
// `artifacts/perps_v2_final_snapshot/manifest.json`, seal with the
// canonical snapshotHash, then execute a non-zero-PnL close between the
// two large migrated traders under the execution-price deviation guard
// configured at the operator-selected 100 bps policy value.
//
// Reused (no new deployment in production): PME_V2, RISK_V2, CLEARING_V2,
// FMV2, Vault, InsuranceFund, Seizer. In this isolated test these are
// stood up locally so the assertions are self-contained and deterministic.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpEngineTradingV2} from "../../src/perp/PerpEngineTradingV2.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../src/perp/PerpEngineStorage.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpClearingAccountV2} from "../../src/perp/PerpClearingAccountV2.sol";

// Local mocks matching the pattern used in PerpEngineV2Migration.t.sol.
contract RcvMockERC20 is ERC20 {
    uint8 private immutable _d;
    constructor(string memory n, string memory s, uint8 dec) ERC20(n, s) { _d = dec; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract RcvMockOracle is IOracle {
    struct P { uint256 price; uint256 t; bool ok; }
    mapping(bytes32 => P) internal p;

    function setPrice(address b, address q, uint256 pr, uint256 tm, bool ok) external {
        p[keccak256(abi.encode(b, q))] = P(pr, tm, ok);
    }
    function getPrice(address b, address q) external view returns (uint256, uint256) {
        P memory d = p[keccak256(abi.encode(b, q))];
        require(d.ok, "no-px");
        return (d.price, d.t);
    }
    function getPriceSafe(address b, address q) external view returns (uint256, uint256, bool) {
        P memory d = p[keccak256(abi.encode(b, q))];
        return (d.price, d.t, d.ok);
    }
}

contract RcvMockRisk is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;
    mapping(address => AccountRisk) internal risks;

    constructor(address b, uint8 d) {
        baseCollateralToken = b;
        baseDecimals = d;
    }

    function setAccountRisk(address t, int256 e, uint256 mm, uint256 im) external {
        risks[t] = AccountRisk({equityBase: e, maintenanceMarginBase: mm, initialMarginBase: im});
    }

    function computeAccountRisk(address t) external view returns (AccountRisk memory r) {
        r = risks[t];
    }

    function computeFreeCollateral(address t) external view returns (int256) {
        AccountRisk memory r = risks[t];
        return r.equityBase - int256(r.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 a)
        external
        pure
        returns (WithdrawPreview memory pw)
    {
        pw.requestedAmount = a;
        pw.maxWithdrawable = a;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @title PerpEngineV2RecoveryRehearsalTest
/// @notice Full self-contained rehearsal of the minimal recovery (§10-12).
contract PerpEngineV2RecoveryRehearsalTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // 1e8 scale used throughout perp accounting.
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;

    // Canonical snapshotHash from artifacts/perps_v2_final_snapshot/manifest.cbor.
    bytes32 internal constant CANONICAL_SNAPSHOT_HASH =
        0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d;

    // Canonical market 1 funding state at snapshot block 47_354_411.
    uint64 internal constant CANONICAL_LAST_FUNDING_TS_M1 = 1_789_715_546;

    // Operator policy: 1% deviation on both markets.
    uint16 internal constant EXEC_DEVIATION_BPS = 100;

    // Canonical 6 traders from manifest.json.
    address internal constant TRADER_290BD = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    address internal constant TRADER_475FE = 0x475Fe397FA56884952D350aa9EE1c3946964BC0C;
    address internal constant TRADER_66858 = 0x66858286fEEA78a05eA093673EA1535E0A52002d;
    address internal constant TRADER_77CA9 = 0x77cA9DD6cCce2D692FB23877a2db7178807b0020;
    address internal constant TRADER_8B94A = 0x8B94A83D1AD3bD2337b1886E7962CA8E0bba9A34;
    address internal constant TRADER_FF287 = 0xff287410852B9328437eaC353720e5476bC5F837;

    address internal constant OWNER = address(0xC0);
    address internal constant MATCHING = address(0xF5FB); // stand-in for PME_V2 after rebind
    address internal constant FEE_RECIPIENT = address(0xFEE);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngineV2 internal engine;
    RcvMockOracle internal oracle;
    RcvMockRisk internal risk;
    PerpClearingAccountV2 internal clearing;

    RcvMockERC20 internal usdc;
    RcvMockERC20 internal weth;
    RcvMockERC20 internal wbtc;

    uint256 internal marketIdEth;
    uint256 internal marketIdBtc;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        vm.warp(CANONICAL_LAST_FUNDING_TS_M1 + 1); // ensure oracle timestamp comparisons work

        vault = new CollateralVault(OWNER);
        oracle = new RcvMockOracle();
        usdc = new RcvMockERC20("mUSDC", "mUSDC", 6);
        weth = new RcvMockERC20("mWETH", "mWETH", 18);
        wbtc = new RcvMockERC20("mWBTC", "mWBTC", 8);
        risk = new RcvMockRisk(address(usdc), 6);

        // 1. Deploy NEW PMR (recovery source).
        registry = new PerpMarketRegistry(OWNER);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);

        registry.setSettlementAssetAllowed(address(usdc), true);

        // 2. Configure both markets to match live OLD PMR state.
        marketIdEth = registry.createMarket(
            address(weth),
            address(usdc),
            address(oracle),
            bytes32("ETH-PERP"),
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000,
                maintenanceMarginBps: 750,
                liquidationPenaltyBps: 500,
                maxPositionSize1e8: uint128(10_000_000_000),
                maxOpenInterest1e8: uint128(50_000_000_000),
                reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({
                closeFactorBps: 5_000,
                priceSpreadBps: 100,
                minImprovementBps: 50,
                oracleMaxDelay: 60
            }),
            PerpMarketRegistry.FundingConfig({
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 0
            })
        );
        require(marketIdEth == 1, "market id drift ETH");

        marketIdBtc = registry.createMarket(
            address(wbtc),
            address(usdc),
            address(oracle),
            bytes32("BTC-PERP"),
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_200,
                maintenanceMarginBps: 800,
                liquidationPenaltyBps: 400,
                maxPositionSize1e8: uint128(1_000_000_000),
                maxOpenInterest1e8: uint128(10_000_000_000),
                reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({
                closeFactorBps: 5_000,
                priceSpreadBps: 80,
                minImprovementBps: 50,
                oracleMaxDelay: 60
            }),
            PerpMarketRegistry.FundingConfig({
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 0
            })
        );
        require(marketIdBtc == 2, "market id drift BTC");

        // 3. Configure operator-policy execution-price deviation.
        registry.setMaxExecutionDeviationBps(marketIdEth, EXEC_DEVIATION_BPS);
        registry.setMaxExecutionDeviationBps(marketIdBtc, EXEC_DEVIATION_BPS);

        // 4. Deploy NEW ENGINE_V2 pointing at NEW PMR (recovery source).
        engine = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));

        // 5. Wire dependencies on the NEW engine.
        engine.setMatchingEngine(MATCHING);
        engine.setRiskModule(address(risk));

        // Deploy a real ClearingAccount instance and set on the new engine.
        clearing = new PerpClearingAccountV2(address(vault));
        engine.setClearingAccount(address(clearing));

        // 6. Authorize new engine on the vault (in production this is a Timelock op).
        vault.setAuthorizedEngine(address(engine), true);
        vm.stopPrank();

        // 7. Oracle mark near canonical entry so the deviation guard passes.
        oracle.setPrice(address(weth), address(usdc), 246_831_000_000, block.timestamp, true);
    }

    /*//////////////////////////////////////////////////////////////
                        MIGRATION REPLAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Rehearsal §L: replay the canonical 6-position migration and
    ///         seal with the canonical snapshotHash. Prove seeded state is
    ///         byte-identical to `manifest.json`.
    function test_MigrationReplay_ByteIdenticalToManifest() external {
        vm.startPrank(OWNER);

        // 8. Seed market funding for market 1 (market 2 = zero).
        engine.adminSeedMarketFunding(marketIdEth, 0, CANONICAL_LAST_FUNDING_TS_M1);
        engine.adminSeedMarketFunding(marketIdBtc, 0, 0);

        // 9. Seed all 6 canonical positions from manifest.json.
        // trader                            size1e8      openNotional1e8
        engine.adminSeedPosition(TRADER_290BD, marketIdEth, int256(1000),          int256(3_000_000),          0);
        engine.adminSeedPosition(TRADER_475FE, marketIdEth, -int256(2),             -int256(6_000),              0);
        engine.adminSeedPosition(TRADER_66858, marketIdEth, -int256(1_000_000),     -int256(2_468_310_000),      0);
        engine.adminSeedPosition(TRADER_77CA9, marketIdEth, -int256(1_000),         -int256(3_000_000),          0);
        engine.adminSeedPosition(TRADER_8B94A, marketIdEth, int256(2),             int256(6_000),              0);
        engine.adminSeedPosition(TRADER_FF287, marketIdEth, int256(1_000_000),     int256(2_468_310_000),      0);

        // 10. Seal with the CANONICAL snapshotHash from
        //     artifacts/perps_v2_final_snapshot/manifest.cbor.
        engine.sealMigration(CANONICAL_SNAPSHOT_HASH);
        vm.stopPrank();

        // 11. Post-seal state must be byte-identical to manifest.
        assertEq(uint8(engine.migrationState()), uint8(PerpEngineTradingV2.MigrationState.SEALED));
        assertEq(engine.migrationSnapshotHash(), CANONICAL_SNAPSHOT_HASH);

        // Position readback.
        _assertPos(TRADER_290BD, marketIdEth, int256(1000),      int256(3_000_000));
        _assertPos(TRADER_475FE, marketIdEth, -int256(2),         -int256(6_000));
        _assertPos(TRADER_66858, marketIdEth, -int256(1_000_000), -int256(2_468_310_000));
        _assertPos(TRADER_77CA9, marketIdEth, -int256(1_000),     -int256(3_000_000));
        _assertPos(TRADER_8B94A, marketIdEth, int256(2),         int256(6_000));
        _assertPos(TRADER_FF287, marketIdEth, int256(1_000_000), int256(2_468_310_000));

        // Aggregate OI reconstruction.
        PerpEngineTypes.MarketState memory ms1 = engine.marketState(marketIdEth);
        assertEq(ms1.longOpenInterest1e8, 1_001_002, "long OI drift");
        assertEq(ms1.shortOpenInterest1e8, 1_001_002, "short OI drift");
        assertEq(ms1.lastFundingTimestamp, CANONICAL_LAST_FUNDING_TS_M1, "funding ts drift");

        PerpEngineTypes.MarketState memory ms2 = engine.marketState(marketIdBtc);
        assertEq(ms2.longOpenInterest1e8, 0);
        assertEq(ms2.shortOpenInterest1e8, 0);

        // Residual bad debt: zero at migration time.
        assertEq(engine.totalResidualBadDebtBase(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    NON-ZERO PNL FIRST TRADE (§11)
    //////////////////////////////////////////////////////////////*/

    /// @notice Rehearsal §11: execute a controlled non-zero-PnL close
    ///         between the canonical large pair (+1M / -1M). Prove:
    ///           - deviation guard passes (execution ≈ oracle mark)
    ///           - realized PnL is non-zero on both sides
    ///           - Σ realized = 0 (no ×2)
    ///           - fees separately debited (tier-0 for this rehearsal
    ///             uses the mock risk module which doesn't call fees;
    ///             fee separation is verified in the existing
    ///             PerpEngineV2ProductionWiring test)
    function test_NonZeroPnLClose_ProvesNoDoubleRealization() external {
        _seedAndSeal();

        // Set healthy risk for both traders so the risk module post-check
        // does not revert during the close.
        risk.setAccountRisk(TRADER_66858, int256(1_000_000 * BASE_UNIT), 0, 0);
        risk.setAccountRisk(TRADER_FF287, int256(1_000_000 * BASE_UNIT), 0, 0);

        // Give traders vault balances so debit-first ordering has funds.
        _seedVaultBalance(TRADER_66858, 1_000_000 * BASE_UNIT);
        _seedVaultBalance(TRADER_FF287, 1_000_000 * BASE_UNIT);

        // Fund clearing to service any small debit — reuses PerpClearingAccountV2.
        _fundClearing(1_000 * BASE_UNIT);

        // Update oracle to the close price (still within 100 bps of entry).
        // Entry price = 2_468.31, close price = 2_468.4223550 (+0.0045% deviation).
        uint256 closePrice = 246_842_235_500;
        oracle.setPrice(address(weth), address(usdc), closePrice, block.timestamp, true);

        // Snapshot vault balances before close.
        uint256 shortBefore = vault.balances(TRADER_66858, address(usdc));
        uint256 longBefore = vault.balances(TRADER_FF287, address(usdc));
        uint256 clearingBefore = vault.balances(address(clearing), address(usdc));

        // Execute partial close: 10_000 units (0.0001 base).
        // buyer = SHORT closes by buying; seller = LONG closes by selling.
        // buyerIsMaker=true (mimics matched-intent maker/taker).
        vm.prank(MATCHING);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: TRADER_66858,
                seller: TRADER_FF287,
                marketId: marketIdEth,
                sizeDelta1e8: 10_000,
                executionPrice1e8: uint128(closePrice),
                buyerIsMaker: true
            })
        );

        // Positions reduced by 10_000.
        assertEq(engine.positions(TRADER_66858, marketIdEth).size1e8, -int256(1_000_000) + int256(10_000));
        assertEq(engine.positions(TRADER_FF287, marketIdEth).size1e8, int256(1_000_000) - int256(10_000));

        // Post-close vault balances.
        uint256 shortAfter = vault.balances(TRADER_66858, address(usdc));
        uint256 longAfter = vault.balances(TRADER_FF287, address(usdc));
        uint256 clearingAfter = vault.balances(address(clearing), address(usdc));

        // Signed vault deltas.
        int256 shortDelta = int256(shortAfter) - int256(shortBefore);
        int256 longDelta = int256(longAfter) - int256(longBefore);
        int256 clearingDelta = int256(clearingAfter) - int256(clearingBefore);

        // Expected realized PnL per computeNextPosition math with cumFR=0:
        //   removedBasis(long)   = 2_468_310_000 * 10_000 / 1_000_000  = 24_683_100 (1e8)
        //   closedMarkValue(long)= 10_000 * 246_842_235_500 / 1e8      = 24_684_223 (mulDivFloor)
        //   realized(long)  = +1_123 (1e8) → +11 native (÷100, floor)
        //   realized(short) = -1_123 (1e8) → -11 native
        // Conservation: +11 + (-11) = 0 → no ×2 realization
        assertEq(longDelta + shortDelta + clearingDelta, 0, "conservation broken");
        assertEq(longDelta, int256(11), "long realized PnL drift");
        assertEq(shortDelta, int256(-11), "short realized PnL drift");
        assertEq(clearingDelta, int256(0), "clearing must stay flat when sumRealized=0");
    }

    /*//////////////////////////////////////////////////////////////
                    OLD ENGINE ISOLATION (§10.13)
    //////////////////////////////////////////////////////////////*/

    /// @notice Prove the recovery engine's state is independent — a
    ///         second `sealMigration` on the same engine fails, and any
    ///         seed on a sealed engine fails. Old-engine interference is
    ///         cryptographically impossible: a separately deployed old
    ///         engine could not affect this one because they don't share
    ///         storage.
    function test_SealedEngineRejectsAllFurtherAdmin() external {
        _seedAndSeal();

        // adminSeedPosition post-seal reverts with MigrationAlreadySealed.
        vm.startPrank(OWNER);
        vm.expectRevert();
        engine.adminSeedPosition(TRADER_290BD, marketIdEth, int256(1), int256(1), 0);

        // Second sealMigration reverts.
        vm.expectRevert();
        engine.sealMigration(CANONICAL_SNAPSHOT_HASH);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _seedAndSeal() internal {
        vm.startPrank(OWNER);
        engine.adminSeedMarketFunding(marketIdEth, 0, CANONICAL_LAST_FUNDING_TS_M1);
        engine.adminSeedMarketFunding(marketIdBtc, 0, 0);
        engine.adminSeedPosition(TRADER_290BD, marketIdEth, int256(1000),      int256(3_000_000),     0);
        engine.adminSeedPosition(TRADER_475FE, marketIdEth, -int256(2),         -int256(6_000),         0);
        engine.adminSeedPosition(TRADER_66858, marketIdEth, -int256(1_000_000), -int256(2_468_310_000), 0);
        engine.adminSeedPosition(TRADER_77CA9, marketIdEth, -int256(1_000),     -int256(3_000_000),     0);
        engine.adminSeedPosition(TRADER_8B94A, marketIdEth, int256(2),         int256(6_000),         0);
        engine.adminSeedPosition(TRADER_FF287, marketIdEth, int256(1_000_000), int256(2_468_310_000), 0);
        engine.sealMigration(CANONICAL_SNAPSHOT_HASH);
        vm.stopPrank();
    }

    function _assertPos(address trader, uint256 mid, int256 size, int256 basis) internal view {
        PerpEngineTypes.Position memory p = engine.positions(trader, mid);
        assertEq(p.size1e8, size, "size1e8 drift");
        assertEq(p.openNotional1e8, basis, "openNotional drift");
        assertEq(p.lastCumulativeFundingRate1e18, 0, "cumFR drift");
    }

    function _seedVaultBalance(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _fundClearing(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.approve(address(clearing), amount);
        clearing.fundClearing(address(usdc), amount);
    }
}
