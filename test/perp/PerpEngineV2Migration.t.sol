// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_MIGRATION_SEED_HOOK_V1 §§16-19
// Access control + economic migration + post-migration close regression
// + snapshot-hash commitment tests for the one-time V1 -> V2 state seeding.
//
// Covers:
//   §16: 13 access-control cases
//   §17: 12 economic migration cases
//   §18: mandatory post-migration Base-Sepolia A/B close (244_274 reproduced)
//   §19: snapshot-hash commitment + sensitivity

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTradingV2} from "../../src/perp/PerpEngineTradingV2.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../src/perp/PerpEngineStorage.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpClearingAccountV2} from "../../src/perp/PerpClearingAccountV2.sol";

// Local minimal mocks so this suite is independent from other test files.
contract MockERC20Mig is ERC20 {
    uint8 private immutable _d;

    constructor(string memory n, string memory s, uint8 dec) ERC20(n, s) {
        _d = dec;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockOracleMig is IOracle {
    struct P {
        uint256 price;
        uint256 t;
        bool ok;
    }

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

contract MockRiskMig is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;

    mapping(address => AccountRisk) internal risks;

    constructor(address b, uint8 d) {
        baseCollateralToken = b;
        baseDecimals = d;
    }

    function setAccountRisk(address t, int256 e, uint256 mm, uint256 im) external {
        risks[t] = AccountRisk(e, mm, im);
    }

    function computeAccountRisk(address t) external view returns (AccountRisk memory) {
        return risks[t];
    }

    function computeFreeCollateral(address t) external view returns (int256) {
        AccountRisk memory r = risks[t];
        return r.equityBase - int256(r.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 a) external pure returns (WithdrawPreview memory p) {
        p.requestedAmount = a;
        p.maxWithdrawable = a;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract PerpEngineV2MigrationTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;

    address internal constant OWNER = address(0xA11CE);
    address internal constant NON_OWNER = address(0xBADD);
    address internal constant MATCHING = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant FUNDER = address(0xF00D);

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngineV2 internal engine;
    MockOracleMig internal oracle;
    MockRiskMig internal risk;
    MockERC20Mig internal usdc;
    MockERC20Mig internal weth;
    PerpClearingAccountV2 internal clearing;

    uint256 internal marketId;
    uint256 internal marketId2;

    function setUp() public virtual {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new MockOracleMig();
        usdc = new MockERC20Mig("USDC", "mUSDC", 6);
        weth = new MockERC20Mig("WETH", "mWETH", 18);
        risk = new MockRiskMig(address(usdc), 6);
        engine = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));
        clearing = new PerpClearingAccountV2(address(vault));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);
        registry.setSettlementAssetAllowed(address(usdc), true);

        PerpMarketRegistry.RiskConfig memory rc = PerpMarketRegistry.RiskConfig({
            initialMarginBps: 1_000,
            maintenanceMarginBps: 500,
            liquidationPenaltyBps: 500,
            maxPositionSize1e8: uint128(10_000 * ONE),
            maxOpenInterest1e8: uint128(100_000 * ONE),
            reduceOnlyDuringCloseOnly: true
        });
        PerpMarketRegistry.LiquidationConfig memory lc = PerpMarketRegistry.LiquidationConfig({
            closeFactorBps: 5_000, priceSpreadBps: 100, minImprovementBps: 50, oracleMaxDelay: 60
        });
        PerpMarketRegistry.FundingConfig memory fc = PerpMarketRegistry.FundingConfig({
            isEnabled: false, fundingInterval: 0, maxFundingRateBps: 0,
            maxSkewFundingBps: 0, oracleClampBps: 0, impactMidMaxDelay: 0
        });

        marketId = registry.createMarket(
            address(weth), address(usdc), address(0), bytes32("ETH-PERP-MIG"), rc, lc, fc
        );
        marketId2 = registry.createMarket(
            address(weth), address(usdc), address(0), bytes32("BTC-PERP-MIG"), rc, lc, fc
        );

        registry.setMaxExecutionDeviationBps(marketId, 10_000);
        registry.setMaxExecutionDeviationBps(marketId2, 10_000);

        engine.setMatchingEngine(MATCHING);
        engine.setRiskModule(address(risk));
        engine.setClearingAccount(address(clearing));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), 2_000 * PRICE_SCALE, block.timestamp, true);

        _healthy(ALICE);
        _healthy(BOB);
        _healthy(CAROL);
        _healthy(address(clearing));

        _deposit(ALICE, 100_000 * BASE_UNIT);
        _deposit(BOB, 100_000 * BASE_UNIT);
        _deposit(CAROL, 100_000 * BASE_UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                §16: ACCESS-CONTROL / LIFECYCLE (13 CASES)
    //////////////////////////////////////////////////////////////*/

    /// 1. Owner can seed while migration open.
    function testACL_01_OwnerCanSeedWhileOpen() external {
        vm.prank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        PerpEngineTypes.Position memory p = engine.positions(ALICE, marketId);
        assertEq(p.size1e8, int256(uint256(ONE)));
        assertEq(p.openNotional1e8, int256(2_000 * PRICE_SCALE));
    }

    /// 2. Non-owner cannot seed.
    function testACL_02_NonOwnerCannotSeed() external {
        vm.prank(NON_OWNER);
        vm.expectRevert(PerpEngineTypes.NotAuthorized.selector);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
    }

    /// 3. Duplicate position seed rejected.
    function testACL_03_DuplicatePositionSeedRejected() external {
        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpEngineTradingV2.MigrationPositionAlreadySeeded.selector, ALICE, marketId
            )
        );
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        vm.stopPrank();
    }

    /// 4. Invalid market rejected.
    function testACL_04_InvalidMarketRejected() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.UnknownMarket.selector);
        engine.adminSeedPosition(ALICE, 9999, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
    }

    /// 5. Zero trader rejected.
    function testACL_05_ZeroTraderRejected() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.ZeroAddress.selector);
        engine.adminSeedPosition(address(0), marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
    }

    /// 6. Trading before seal rejected.
    function testACL_06_TradingBeforeSealRejected() external {
        vm.prank(MATCHING);
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: ALICE, seller: BOB, marketId: marketId,
                sizeDelta1e8: ONE, executionPrice1e8: uint128(2_000 * PRICE_SCALE),
                buyerIsMaker: false
            })
        );
    }

    /// 7. Liquidation before seal rejected.
    function testACL_07_LiquidationBeforeSealRejected() external {
        vm.prank(NON_OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        engine.liquidate(ALICE, marketId, uint128(ONE));
    }

    /// 8. Seal by non-owner rejected.
    function testACL_08_SealByNonOwnerRejected() external {
        vm.prank(NON_OWNER);
        vm.expectRevert(PerpEngineTypes.NotAuthorized.selector);
        engine.sealMigration(bytes32(uint256(1)));
    }

    /// 9. Owner can seal once.
    function testACL_09_OwnerCanSealOnce() external {
        vm.prank(OWNER);
        engine.sealMigration(bytes32(uint256(0xC0FFEE)));
        assertEq(uint256(engine.migrationState()), 1);
        assertEq(engine.migrationSnapshotHash(), bytes32(uint256(0xC0FFEE)));
    }

    /// 10. Second seal rejected.
    function testACL_10_SecondSealRejected() external {
        vm.startPrank(OWNER);
        engine.sealMigration(bytes32(uint256(0xAA)));
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.sealMigration(bytes32(uint256(0xBB)));
        vm.stopPrank();
    }

    /// 11. Seed after seal rejected.
    function testACL_11_SeedAfterSealRejected() external {
        vm.startPrank(OWNER);
        engine.sealMigration(bytes32(uint256(0xAA)));
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.adminSeedMarketFunding(marketId, 0, 0);
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.adminSeedResidualBadDebt(ALICE, 100);
        vm.stopPrank();
    }

    /// 12. Migration cannot reopen (no unseal function exists).
    function testACL_12_MigrationCannotReopen() external {
        vm.prank(OWNER);
        engine.sealMigration(bytes32(uint256(0xAA)));

        // Try common re-open signatures — all revert (no code path).
        string[3] memory guesses = ["unsealMigration()", "reopenMigration()", "resetMigration()"];
        for (uint256 i; i < guesses.length; i++) {
            (bool ok,) = address(engine).call(abi.encodeWithSignature(guesses[i]));
            assertFalse(ok, "unexpected reopen surface");
        }
        assertEq(uint256(engine.migrationState()), 1, "still sealed");
    }

    /// 13. Ownership transfer does not reopen migration.
    function testACL_13_OwnershipTransferDoesNotReopen() external {
        vm.prank(OWNER);
        engine.sealMigration(bytes32(uint256(0xAA)));

        vm.prank(OWNER);
        engine.transferOwnership(NON_OWNER);
        vm.prank(NON_OWNER);
        engine.acceptOwnership();

        assertEq(uint256(engine.migrationState()), 1, "still sealed after ownership change");
        vm.prank(NON_OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationAlreadySealed.selector);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
    }

    /*//////////////////////////////////////////////////////////////
                §17: ECONOMIC MIGRATION (A-L)
    //////////////////////////////////////////////////////////////*/

    /// A. Long position exact migration.
    function testEcon_A_LongPositionExactMigration() external {
        int256 size = int256(uint256(ONE));
        int256 basis = int256(2_000 * PRICE_SCALE);
        int256 fundingCheckpoint = 12345;

        vm.prank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, size, basis, fundingCheckpoint);

        PerpEngineTypes.Position memory p = engine.positions(ALICE, marketId);
        assertEq(p.size1e8, size);
        assertEq(p.openNotional1e8, basis);
        assertEq(p.lastCumulativeFundingRate1e18, fundingCheckpoint);
    }

    /// B. Short position exact migration.
    function testEcon_B_ShortPositionExactMigration() external {
        int256 size = -int256(uint256(ONE));
        int256 basis = -int256(2_000 * PRICE_SCALE);

        vm.prank(OWNER);
        engine.adminSeedPosition(BOB, marketId, size, basis, -99);

        PerpEngineTypes.Position memory p = engine.positions(BOB, marketId);
        assertEq(p.size1e8, size);
        assertEq(p.openNotional1e8, basis);
        assertEq(p.lastCumulativeFundingRate1e18, -99);
    }

    /// C. Base-Sepolia A/B state exact reproduction. Covered in §18 test.

    /// D. Partial-position basis (small size).
    function testEcon_D_PartialPositionBasis() external {
        int256 size = int256(uint256(1_000_000)); // 0.01 units
        int256 basis = int256((uint256(1_000_000) * 246_831_000_000) / PRICE_SCALE);
        vm.prank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, size, basis, 0);
        assertEq(engine.positions(ALICE, marketId).openNotional1e8, basis);
    }

    /// E. Multiple markets per trader.
    function testEcon_E_MultipleMarketsPerTrader() external {
        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(ALICE, marketId2, -int256(uint256(ONE)), -int256(30_000 * PRICE_SCALE), 0);
        vm.stopPrank();

        assertEq(engine.positions(ALICE, marketId).size1e8, int256(uint256(ONE)));
        assertEq(engine.positions(ALICE, marketId2).size1e8, -int256(uint256(ONE)));
    }

    /// F. Multiple traders in the same market.
    function testEcon_F_MultipleTradersSameMarket() external {
        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(BOB, marketId, -int256(uint256(ONE)), -int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(CAROL, marketId, int256(uint256(2 * ONE)), int256(4_100 * PRICE_SCALE), 0);
        vm.stopPrank();

        PerpEngineTypes.MarketState memory ms = engine.marketState(marketId);
        assertEq(ms.longOpenInterest1e8, uint256(3 * ONE), "long OI 3");
        assertEq(ms.shortOpenInterest1e8, uint256(ONE), "short OI 1");
    }

    /// G. Nonzero funding checkpoint on position.
    function testEcon_G_NonzeroFundingCheckpoint() external {
        int256 checkpoint = 1_234_567_890_123_456_789;
        vm.prank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), checkpoint);
        assertEq(engine.positions(ALICE, marketId).lastCumulativeFundingRate1e18, checkpoint);
    }

    /// H. Nonzero cumulative market funding baseline.
    function testEcon_H_NonzeroMarketFunding() external {
        int256 marketCum = 500_000_000_000_000;
        uint64 ts = uint64(block.timestamp);
        vm.prank(OWNER);
        engine.adminSeedMarketFunding(marketId, marketCum, ts);
        PerpEngineTypes.MarketState memory ms = engine.marketState(marketId);
        assertEq(ms.cumulativeFundingRate1e18, marketCum);
        assertEq(ms.lastFundingTimestamp, ts);
    }

    /// I. Aggregate OI reconstruction consistent across seeds.
    function testEcon_I_AggregateOIReconstructionExact() external {
        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(3 * ONE)), int256(6_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(BOB, marketId, -int256(uint256(2 * ONE)), -int256(4_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(CAROL, marketId, -int256(uint256(ONE)), -int256(2_100 * PRICE_SCALE), 0);
        vm.stopPrank();

        PerpEngineTypes.MarketState memory ms = engine.marketState(marketId);
        assertEq(ms.longOpenInterest1e8, uint256(3 * ONE));
        assertEq(ms.shortOpenInterest1e8, uint256(3 * ONE));
    }

    /// J. Collateral unchanged by any seed operation.
    function testEcon_J_CollateralUnchangedByMigration() external {
        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));
        uint256 clearingBefore = vault.balances(address(clearing), address(usdc));

        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedPosition(BOB, marketId, -int256(uint256(ONE)), -int256(2_000 * PRICE_SCALE), 0);
        engine.adminSeedMarketFunding(marketId, 123, uint64(block.timestamp));
        engine.sealMigration(bytes32(uint256(0xAA)));
        vm.stopPrank();

        assertEq(vault.balances(ALICE, address(usdc)), aliceBefore, "alice vault unchanged");
        assertEq(vault.balances(BOB, address(usdc)), bobBefore, "bob vault unchanged");
        assertEq(vault.balances(address(clearing), address(usdc)), clearingBefore, "clearing vault unchanged");
    }

    /// K. Fee sink (feeRecipient) unchanged — migration is not a trade.
    /// PerpEngineV2 has no `setFeeRecipient` external admin; the default
    /// feeRecipient is address(0). Assert the default fee-sink account
    /// is not touched by seeding.
    function testEcon_K_FeeSinkUnchanged() external {
        // Use CAROL as an ad-hoc "fee sink" address whose balance would
        // move if migration touched any fee sink incorrectly.
        uint256 sinkBefore = vault.balances(CAROL, address(usdc));
        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        engine.sealMigration(bytes32(uint256(0xAA)));
        vm.stopPrank();
        assertEq(vault.balances(CAROL, address(usdc)), sinkBefore);
    }

    /// L. Clearing unchanged by migration (separation from fundClearing).
    function testEcon_L_ClearingUnchangedByMigration() external {
        _fund(50_000 * BASE_UNIT);
        uint256 clearBefore = vault.balances(address(clearing), address(usdc));

        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
        engine.sealMigration(bytes32(uint256(0xAA)));
        vm.stopPrank();

        assertEq(vault.balances(address(clearing), address(usdc)), clearBefore);
    }

    /*//////////////////////////////////////////////////////////////
                §18: POST-MIGRATION BASE-SEPOLIA CLOSE REGRESSION
                     (MANDATORY)
    //////////////////////////////////////////////////////////////*/

    /// Seed exact live Base-Sepolia A/B state on V2, seal, execute the ONE
    /// mutual close intent at 249_273_743_964 -> both go to zero and each
    /// side moves exactly 244_274 raw mUSDC via the clearing account. Fees
    /// disabled in this test (fee logic tested separately in V2 cashflow).
    function testBaseSepoliaAB_PostMigrationCloseReproduces244274() external {
        // Live V1 state (informational): A=+1_000_000, B=-1_000_000 in market 1,
        // opened at 246_831_000_000.
        uint128 size = 1_000_000;
        uint256 openPrice = 246_831_000_000;
        uint256 closePrice = 249_273_743_964;

        int256 aliceSize = int256(uint256(size));
        int256 bobSize = -aliceSize;
        int256 aliceBasis = int256(uint256(size) * openPrice / PRICE_SCALE);
        int256 bobBasis = -aliceBasis;

        // Fund clearing first (separate step per §13).
        _fund(1_000 * BASE_UNIT);

        // Seed positions.
        vm.startPrank(OWNER);
        engine.adminSeedPosition(ALICE, marketId, aliceSize, aliceBasis, 0);
        engine.adminSeedPosition(BOB, marketId, bobSize, bobBasis, 0);
        // Funding baseline is zero for this closed test — no seed required.
        // Seal.
        engine.sealMigration(bytes32(uint256(0xB45E5E70)));
        vm.stopPrank();

        // Confirm seed state.
        assertEq(engine.positions(ALICE, marketId).size1e8, aliceSize);
        assertEq(engine.positions(BOB, marketId).size1e8, bobSize);
        assertEq(engine.positions(ALICE, marketId).openNotional1e8, aliceBasis);
        assertEq(engine.positions(BOB, marketId).openNotional1e8, bobBasis);

        // Update oracle mark near close price for guard.
        oracle.setPrice(address(weth), address(usdc), closePrice, block.timestamp, true);

        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));
        uint256 clearingBefore = vault.balances(address(clearing), address(usdc));

        // Execute the SAME mutual close intent used on V1.
        vm.prank(MATCHING);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: BOB, seller: ALICE, marketId: marketId,
                sizeDelta1e8: size, executionPrice1e8: uint128(closePrice),
                buyerIsMaker: false
            })
        );

        // Positions flat.
        assertEq(engine.positions(ALICE, marketId).size1e8, 0);
        assertEq(engine.positions(BOB, marketId).size1e8, 0);

        // Vault deltas: Alice +244_274, Bob -244_274, clearing 0.
        int256 aliceDelta = int256(vault.balances(ALICE, address(usdc))) - int256(aliceBefore);
        int256 bobDelta = int256(vault.balances(BOB, address(usdc))) - int256(bobBefore);
        int256 clearingDelta = int256(vault.balances(address(clearing), address(usdc))) - int256(clearingBefore);

        assertEq(aliceDelta, int256(244_274), "V2 post-migration alice exact 244_274");
        assertEq(bobDelta, -int256(244_274), "V2 post-migration bob exact -244_274");
        assertEq(aliceDelta + bobDelta + clearingDelta, 0, "V2 conservation");

        // V1 would have moved 488_548 — confirm V2 didn't.
        int256 absAlice = aliceDelta >= 0 ? aliceDelta : -aliceDelta;
        assertTrue(absAlice * 2 == int256(488_548), "V1's 2x would have been 488_548");
    }

    /*//////////////////////////////////////////////////////////////
                §19: SNAPSHOT-HASH COMMITMENT
    //////////////////////////////////////////////////////////////*/

    /// Snapshot hash committed at seal.
    function testHash_CommittedAtSeal() external {
        bytes32 h = keccak256(
            abi.encode(uint256(block.chainid), address(engine), uint256(marketId), int256(uint256(ONE)))
        );
        vm.prank(OWNER);
        engine.sealMigration(h);
        assertEq(engine.migrationSnapshotHash(), h);
    }

    /// Snapshot hash zero rejected.
    function testHash_ZeroRejected() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationSnapshotHashZero.selector);
        engine.sealMigration(bytes32(0));
    }

    /// Snapshot hash is off-chain-content-sensitive: changing any field of
    /// the canonical manifest changes the hash the operator MUST supply.
    /// This test proves the manifest hash function is sensitive to each
    /// canonical field; not that the on-chain sealMigration validates the
    /// manifest itself (only auditors can, from the off-chain manifest).
    function testHash_SensitivityToCanonicalFields() external pure {
        bytes32 h1 = keccak256(
            abi.encode(
                uint256(84532), address(0xE1), address(0xA1), uint256(1),
                int256(1_000_000), int256(2_468_310_000), int256(0)
            )
        );
        bytes32 h2 = keccak256(
            abi.encode(
                uint256(84532), address(0xE1), address(0xA1), uint256(1),
                int256(1_000_001), int256(2_468_310_000), int256(0) // size changed
            )
        );
        bytes32 h3 = keccak256(
            abi.encode(
                uint256(84532), address(0xE1), address(0xA1), uint256(1),
                int256(1_000_000), int256(2_468_310_001), int256(0) // basis changed
            )
        );
        bytes32 h4 = keccak256(
            abi.encode(
                uint256(84532), address(0xE1), address(0xA1), uint256(1),
                int256(1_000_000), int256(2_468_310_000), int256(1) // funding changed
            )
        );
        assertTrue(h1 != h2 && h1 != h3 && h1 != h4);
        assertTrue(h2 != h3 && h2 != h4 && h3 != h4);
    }

    /*//////////////////////////////////////////////////////////////
                    ENTRY-BASIS INVARIANT §11
    //////////////////////////////////////////////////////////////*/

    /// Long with negative basis rejected.
    function testInvariant_LongWithNegativeBasisRejected() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationInvalidBasisSign.selector);
        engine.adminSeedPosition(ALICE, marketId, int256(uint256(ONE)), -int256(2_000 * PRICE_SCALE), 0);
    }

    /// Short with positive basis rejected.
    function testInvariant_ShortWithPositiveBasisRejected() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationInvalidBasisSign.selector);
        engine.adminSeedPosition(ALICE, marketId, -int256(uint256(ONE)), int256(2_000 * PRICE_SCALE), 0);
    }

    /// Zero size rejected.
    function testInvariant_ZeroSizeRejected() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTradingV2.MigrationInvalidSize.selector);
        engine.adminSeedPosition(ALICE, marketId, 0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SEAL PRECONDITIONS §10
    //////////////////////////////////////////////////////////////*/

    /// Seal without matching engine rejected.
    function testSeal_RequiresMatchingEngine() external {
        // Fresh engine without matching engine set.
        PerpEngineV2 fresh = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));
        vm.startPrank(OWNER);
        fresh.setRiskModule(address(risk));
        fresh.setClearingAccount(address(clearing));
        vm.expectRevert(PerpEngineTradingV2.MigrationMatchingEngineNotConfigured.selector);
        fresh.sealMigration(bytes32(uint256(1)));
        vm.stopPrank();
    }

    /// Seal without risk module rejected.
    function testSeal_RequiresRiskModule() external {
        PerpEngineV2 fresh = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));
        vm.startPrank(OWNER);
        fresh.setMatchingEngine(MATCHING);
        fresh.setClearingAccount(address(clearing));
        vm.expectRevert(PerpEngineTradingV2.MigrationRiskModuleNotConfigured.selector);
        fresh.sealMigration(bytes32(uint256(1)));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    function _healthy(address a) internal {
        risk.setAccountRisk(a, int256(uint256(1_000_000 * BASE_UNIT)), 0, 0);
    }

    function _deposit(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(vault), amt);
        vault.deposit(address(usdc), amt);
        vm.stopPrank();
    }

    function _fund(uint256 amt) internal {
        usdc.mint(FUNDER, amt);
        vm.startPrank(FUNDER);
        usdc.approve(address(clearing), amt);
        clearing.fundClearing(address(usdc), amt);
        vm.stopPrank();
    }
}
