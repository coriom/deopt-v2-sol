// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_PRODUCTION_WIRING_PREFLIGHT_V1 §10 —
// production-realistic V2 close test.
//
// Purpose: prove that the production `PerpRiskModule`
// (src/perp/PerpRiskModule.sol) and the production
// `FeesManagerV2` (src/fees/FeesManagerV2.sol) can be
// wired to `PerpEngineV2` unchanged and produce the same
// Base-Sepolia mutual-close economic invariants that were
// already proven in `PerpEngineV2Cashflow.t.sol` (which
// used a mock risk + no fees), WITH the additional
// invariants that (a) tier-0 PERP fees ARE charged and
// (b) conservation still holds across a
// {trader_A, trader_B, clearing, feeRecipient} 4-account
// ledger.
//
// The independent reference in RefV2 (PnL arithmetic)
// and the fee ppm rounding are derived from the V2
// accounting equations and FeesManagerV2's public tier
// schedule — NOT from the V2 implementation under test.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {PerpClearingAccountV2} from "../../src/perp/PerpClearingAccountV2.sol";
import {PerpRiskModule} from "../../src/perp/PerpRiskModule.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";

contract _MockERC20 is ERC20 {
    uint8 private immutable _DEC;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _DEC = d;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract _MockOracle is IOracle {
    struct P {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => P) internal p;

    function setPrice(address base, address quote, uint256 price, uint256 updatedAt, bool ok) external {
        p[keccak256(abi.encode(base, quote))] = P(price, updatedAt, ok);
    }

    function getPrice(address base, address quote) external view returns (uint256, uint256) {
        P memory d = p[keccak256(abi.encode(base, quote))];
        require(d.ok, "no-price");
        return (d.price, d.updatedAt);
    }

    function getPriceSafe(address base, address quote) external view returns (uint256, uint256, bool) {
        P memory d = p[keccak256(abi.encode(base, quote))];
        return (d.price, d.updatedAt, d.ok);
    }
}

contract PerpEngineV2ProductionWiringTest is Test {
    // -------- Constants --------
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6; // mUSDC has 6 decimals
    uint128 internal constant ONE = 1e8;
    uint256 internal constant DEPOSIT = 100_000 * BASE_UNIT; // 100_000 mUSDC per trader — dwarfs 2.5M-native initial margin

    // Reproduces the Base-Sepolia mutual-close scenario also used by
    // PerpEngineV2Cashflow.t.sol and by the backend Anvil broadcast E2E.
    uint128 internal constant SIZE = 1_000_000; // 0.01 ETH at 1e8
    uint256 internal constant OPEN_PRICE_1E8 = 246_831_000_000; // ~$2_468.31
    uint256 internal constant CLOSE_PRICE_1E8 = 249_273_743_964; // ~$2_492.74

    // FeesManagerV2 tier-0 PERP schedule (from FeesManagerV2._installLaunchSchedules).
    // Untiered traders default to tier 0.
    uint256 internal constant TIER0_PERP_MAKER_PPM = 50;
    uint256 internal constant TIER0_PERP_TAKER_PPM = 300;
    uint256 internal constant PPM_DENOM = 1_000_000;

    // -------- Actors --------
    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING = address(0xBEEF); // pranked-as-matching-engine
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CLEARING_FUNDER = address(0xF00D);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    // -------- Contracts --------
    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngineV2 internal engine;
    _MockOracle internal oracle;
    PerpClearingAccountV2 internal clearing;
    PerpRiskModule internal risk; // PRODUCTION risk module (not mock)
    FeesManagerV2 internal feesManager; // PRODUCTION fees manager (not mock)

    _MockERC20 internal usdc;
    _MockERC20 internal weth;

    uint256 internal marketId;
    address internal CLEARING;

    function setUp() public {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new _MockOracle();

        usdc = new _MockERC20("Mock USDC", "mUSDC", 6);
        weth = new _MockERC20("Mock WETH", "mWETH", 18);

        engine = new PerpEngineV2(OWNER, address(registry), address(vault), address(oracle));

        // PRODUCTION PerpRiskModule (constructor: owner, vault, engine, oracle, baseCollateralToken)
        risk = new PerpRiskModule(OWNER, address(vault), address(engine), address(oracle), address(usdc));

        // PRODUCTION FeesManagerV2 (constructor: owner, feeRecipient) —
        // launch tier-0 schedules install automatically in the ctor.
        feesManager = new FeesManagerV2(OWNER, FEE_RECIPIENT);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);

        registry.setSettlementAssetAllowed(address(usdc), true);
        marketId = registry.createMarket(
            address(weth),
            address(usdc),
            address(0),
            bytes32("ETH-PERP-V2-PROD"),
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000,
                maintenanceMarginBps: 500,
                liquidationPenaltyBps: 500,
                maxPositionSize1e8: uint128(10_000 * ONE),
                maxOpenInterest1e8: uint128(100_000 * ONE),
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
        registry.setMaxExecutionDeviationBps(marketId, 10_000);

        engine.setMatchingEngine(MATCHING);
        engine.setRiskModule(address(risk));

        // FeesManagerV2 wiring: allow the engine to consume fees, then
        // enable the V2 fee path on the engine.
        feesManager.setFeeConsumer(address(engine), true);
        engine.setFeesManagerV2(address(feesManager));
        engine.setUseFeesManagerV2(true);
        vm.stopPrank();

        // Clearing account
        clearing = new PerpClearingAccountV2(address(vault));
        CLEARING = address(clearing);
        vm.prank(OWNER);
        engine.setClearingAccount(CLEARING);

        // Seal migration so the ordinary trading path is active.
        vm.prank(OWNER);
        engine.sealMigration(bytes32(uint256(0xC01D5EA1)));

        // Oracle mark near open price so the execution-price guard admits it.
        oracle.setPrice(address(weth), address(usdc), OPEN_PRICE_1E8, block.timestamp, true);

        _deposit(ALICE, DEPOSIT);
        _deposit(BOB, DEPOSIT);
        _fundClearing(1_000_000 * BASE_UNIT);
    }

    /// @notice PERPS_V2_PRODUCTION_WIRING_PREFLIGHT_V1 §10 — full
    ///         production-realistic close of the Base-Sepolia mutual
    ///         position with REAL PerpRiskModule + REAL FeesManagerV2.
    ///
    ///         Proves:
    ///           1. Realized PnL = ±244_274 raw mUSDC (matches
    ///              PerpEngineV2Cashflow.testBaseSepoliaMutualClose...).
    ///           2. Tier-0 PERP fees ARE charged (maker=50ppm,
    ///              taker=300ppm ceil-rounded on notional-native).
    ///           3. Fee recipient receives sum of both fees.
    ///           4. Clearing account net delta = 0.
    ///           5. Conservation: sum of all 4 vault deltas = 0.
    ///           6. Real PerpRiskModule accepts both open and close
    ///              (post-trade equity >= initial margin).
    function testProductionWiring_MutualClose_244274_WithTier0Fees() external {
        // ---- Open the paired position (this ALSO incurs open-side fees;
        //      they land BEFORE the snapshot so we isolate the close).
        _trade(ALICE, BOB, SIZE, OPEN_PRICE_1E8);

        // ---- Move oracle mark to close price.
        oracle.setPrice(address(weth), address(usdc), CLOSE_PRICE_1E8, block.timestamp, true);

        // ---- Snapshot BEFORE close.
        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));
        uint256 clearingBefore = vault.balances(CLEARING, address(usdc));
        uint256 recipientBefore = vault.balances(FEE_RECIPIENT, address(usdc));

        // ---- Close (buyer=BOB is taker because buyerIsMaker=false in _trade).
        _trade(BOB, ALICE, SIZE, CLOSE_PRICE_1E8);

        // ---- Positions must be flat.
        assertEq(engine.positions(ALICE, marketId).size1e8, 0, "alice not flat");
        assertEq(engine.positions(BOB, marketId).size1e8, 0, "bob not flat");

        // ---- Expected realized PnL, independently derived.
        // ALICE was long: profits by (close - open) * size = +244_274 native.
        // BOB was short: loses -244_274 native. Rounding rule: floor(abs * 10^dec / 1e8) with sign.
        int256 expectedAlicePnlNative = int256(244_274);
        int256 expectedBobPnlNative = -int256(244_274);

        // ---- Expected fees, independently derived from FeesManagerV2 tier 0.
        // notional_1e8 = SIZE * CLOSE_PRICE_1E8 / 1e8 = 2_492_737_439 (floor)
        // notional_native = 2_492_737_439 / 10^(1e8/1e6) = 24_927_374
        // FeesManagerV2 rounds fee ceil.
        uint256 notional1e8 = (uint256(SIZE) * CLOSE_PRICE_1E8) / PRICE_SCALE;
        uint256 notionalNative = notional1e8 / (PRICE_SCALE / BASE_UNIT); // 1e8 -> 1e6

        // On close _trade(BOB, ALICE, ...) with buyerIsMaker=false:
        //   buyer  = BOB   is TAKER (isMaker=false)
        //   seller = ALICE is MAKER (!buyerIsMaker=true)
        uint256 expectedBobFee = _feeCeil(notionalNative, TIER0_PERP_TAKER_PPM); // 7479
        uint256 expectedAliceFee = _feeCeil(notionalNative, TIER0_PERP_MAKER_PPM); // 1247

        // Sanity: expected fees are non-zero (the whole point of §10).
        assertGt(expectedBobFee, 0, "taker fee must be positive");
        assertGt(expectedAliceFee, 0, "maker fee must be positive");

        // ---- Assert deltas byte-for-byte.
        int256 aliceDelta = int256(vault.balances(ALICE, address(usdc))) - int256(aliceBefore);
        int256 bobDelta = int256(vault.balances(BOB, address(usdc))) - int256(bobBefore);
        int256 clearingDelta = int256(vault.balances(CLEARING, address(usdc))) - int256(clearingBefore);
        int256 recipientDelta = int256(vault.balances(FEE_RECIPIENT, address(usdc))) - int256(recipientBefore);

        assertEq(aliceDelta, expectedAlicePnlNative - int256(expectedAliceFee), "alice delta");
        assertEq(bobDelta, expectedBobPnlNative - int256(expectedBobFee), "bob delta");
        assertEq(clearingDelta, int256(0), "clearing delta must be zero");
        assertEq(recipientDelta, int256(expectedAliceFee + expectedBobFee), "recipient delta");

        // ---- Conservation across the 4-account ledger.
        assertEq(aliceDelta + bobDelta + clearingDelta + recipientDelta, int256(0), "conservation");

        // ---- Anti-value gate: assert we did NOT reproduce the V1 doubled 488_548 bug.
        assertTrue(
            _abs(aliceDelta) != 488_548 && _abs(bobDelta) != 488_548,
            "V1 double-transfer bug reproduced"
        );

        // ---- Funding contribution == 0 (funding disabled on this market).
        assertEq(engine.getPositionFundingAccrued(ALICE, marketId), 0, "alice funding non-zero");
        assertEq(engine.getPositionFundingAccrued(BOB, marketId), 0, "bob funding non-zero");

        // ---- Vault ERC20 supply unchanged (settlement is sub-ledger only).
        uint256 vaultERC20Before = clearingBefore + aliceBefore + bobBefore + recipientBefore;
        uint256 vaultERC20After = vault.balances(CLEARING, address(usdc))
            + vault.balances(ALICE, address(usdc)) + vault.balances(BOB, address(usdc))
            + vault.balances(FEE_RECIPIENT, address(usdc));
        assertEq(vaultERC20After, vaultERC20Before, "sub-ledger total drift");
    }

    // ---------------- helpers ----------------

    function _trade(address buyer, address seller, uint128 size, uint256 price) internal {
        vm.prank(MATCHING);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                marketId: marketId,
                sizeDelta1e8: size,
                executionPrice1e8: uint128(price),
                buyerIsMaker: false
            })
        );
    }

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _fundClearing(uint256 amount) internal {
        usdc.mint(CLEARING_FUNDER, amount);
        vm.startPrank(CLEARING_FUNDER);
        usdc.approve(address(clearing), amount);
        clearing.fundClearing(address(usdc), amount);
        vm.stopPrank();
    }

    function _feeCeil(uint256 basisNative, uint256 ppm) internal pure returns (uint256) {
        if (basisNative == 0 || ppm == 0) return 0;
        return (basisNative * ppm + (PPM_DENOM - 1)) / PPM_DENOM;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
