// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpEngine} from "../../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../src/perp/PerpEngineStorage.sol";

/// @title PerpEngineFundingV2Test
/// @notice Test suite for PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 Part E.
/// @dev
///  Covers the fixed premium computation in `_fundingRatePerInterval1e18`, the
///  keeper-published impact-mid oracle (`updateImpactMid` + freshness gate),
///  the extended `FundingConfig` validator, access control on the writer, and
///  governance surface for `impactMidSource`.
///
///  Naming mirrors the existing perp test files:
///    test/perp/PerpEngineExecutionPriceGuard.t.sol
///    test/unit/perp/PerpEngineFunding.t.sol
///
///  Non-live invariant: `FundingConfig.isEnabled` on production markets stays
///  OFF today. This suite creates its own market with `isEnabled=true` to
///  exercise the funding math in isolation; it does NOT flip any production
///  market flag.
contract MockERC20Decimals is ERC20 {
    uint8 private immutable _decimalsValue;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle is IOracle {
    function getPrice(address, address) external pure returns (uint256, uint256) {
        revert("unmocked");
    }

    function getPriceSafe(address, address) external pure returns (uint256, uint256, bool) {
        revert("unmocked");
    }
}

contract MockPerpRiskModule is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;

    mapping(address => AccountRisk) internal risks;

    constructor(address baseCollateralToken_, uint8 baseDecimals_) {
        baseCollateralToken = baseCollateralToken_;
        baseDecimals = baseDecimals_;
    }

    function setAccountRisk(address trader, int256 equityBase, uint256 maintenanceMarginBase, uint256 initialMarginBase)
        external
    {
        risks[trader] = AccountRisk({
            equityBase: equityBase,
            maintenanceMarginBase: maintenanceMarginBase,
            initialMarginBase: initialMarginBase
        });
    }

    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk) {
        risk = risks[trader];
    }

    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase) {
        AccountRisk memory risk = risks[trader];
        return risk.equityBase - int256(risk.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;
        preview.maxWithdrawable = amount;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256 amount) {
        return type(uint256).max;
    }
}

contract PerpEngineFundingV2Test is Test {
    // ----- Constants -----
    bytes32 internal constant ETH_PERP_SYMBOL = 0x4554482d50455250000000000000000000000000000000000000000000000000;
    uint256 internal constant BASE_UNIT = 1e6;
    int256 internal constant HUGE_EQUITY_BASE = 1_000_000 * 1e6;
    uint128 internal constant ONE = 1e8;

    uint32 internal constant FUNDING_INTERVAL = 1 hours;
    uint32 internal constant DEFAULT_FUNDING_CAP_BPS = 5_000;
    /// @dev == MAX_IMPACT_MID_MAX_DELAY. A sample published immediately after a
    /// `vm.warp` of `FUNDING_INTERVAL` is exactly on the boundary of freshness.
    uint32 internal constant DEFAULT_IMPACT_MID_MAX_DELAY = 3600;

    uint128 internal constant PRICE_2K = 2_000 * 1e8;
    uint128 internal constant PRICE_2010 = 2_010 * 1e8;
    uint128 internal constant PRICE_2020 = 2_020 * 1e8;
    uint128 internal constant PRICE_1980 = 1_980 * 1e8;
    uint128 internal constant PRICE_2200 = 2_200 * 1e8;

    int256 internal constant DELTA_POSITIVE_PREMIUM_1PCT = 1e16;
    int256 internal constant DELTA_NEGATIVE_PREMIUM_1PCT = -1e16;
    int256 internal constant DELTA_CAPPED_50_BPS = 5e15;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant IMPACT_MID_SOURCE = address(0xC1EE);
    address internal constant OUTSIDER = address(0xDEAD);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);

    // ----- State -----
    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    MockOracle internal oracle;
    MockPerpRiskModule internal riskModule;

    MockERC20Decimals internal usdc;
    MockERC20Decimals internal weth;

    uint256 internal marketId;

    // ----- Events (mirrored from source) -----
    event ImpactMidSourceSet(address indexed oldSource, address indexed newSource);
    event ImpactMidUpdated(uint256 indexed marketId, uint128 mid1e8, uint64 updatedAt);

    // ----- setUp -----
    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new MockOracle();
        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        weth = new MockERC20Decimals("Mock WETH", "mWETH", 18);

        riskModule = new MockPerpRiskModule(address(usdc), 6);
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(oracle));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);

        registry.setSettlementAssetAllowed(address(usdc), true);
        marketId = registry.createMarket(
            address(weth),
            address(usdc),
            address(0),
            ETH_PERP_SYMBOL,
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000,
                maintenanceMarginBps: 500,
                liquidationPenaltyBps: 500,
                maxPositionSize1e8: uint128(100 * ONE),
                maxOpenInterest1e8: uint128(1_000 * ONE),
                reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({
                closeFactorBps: 5_000,
                priceSpreadBps: 100,
                minImprovementBps: 50,
                oracleMaxDelay: 60
            }),
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: DEFAULT_FUNDING_CAP_BPS,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );
        registry.setMaxExecutionDeviationBps(marketId, 10_000);

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));
        engine.setImpactMidSource(IMPACT_MID_SOURCE);
        vm.stopPrank();

        _setHealthyRisk(ALICE);
        _setHealthyRisk(BOB);
        _deposit(ALICE, 100_000 * BASE_UNIT);
        _deposit(BOB, 100_000 * BASE_UNIT);
    }

    /*//////////////////////////////////////////////////////////////
                        BUG FIX + DIRECTIONAL TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression: pre-V2 the two-call bug forced funding to 0 even
    /// with a materially non-zero impact-mid vs index premium. Post-fix, an
    /// impact-mid ABOVE the index MUST produce a strictly positive rate.
    function testFuzz_bugFixRegression_impactAboveIndex_producesPositiveRate() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(PRICE_2K);
        _publishImpactMid(PRICE_2020);

        (int256 delta,) = engine.updateFunding(marketId);
        assertGt(delta, 0, "positive premium must produce positive funding rate");
        assertEq(delta, DELTA_POSITIVE_PREMIUM_1PCT, "1% premium == 1e16 rate for FUNDING_INTERVAL == interval");
    }

    /// @notice Direction correctness: impactMid < index MUST produce a negative rate.
    function testDirectionCorrectness_impactBelowIndex_producesNegativeRate() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(PRICE_2K);
        _publishImpactMid(PRICE_1980);

        (int256 delta,) = engine.updateFunding(marketId);
        assertLt(delta, 0, "negative premium must produce negative funding rate");
        assertEq(delta, DELTA_NEGATIVE_PREMIUM_1PCT);
    }

    /*//////////////////////////////////////////////////////////////
                        DEADBAND + CAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Premium strictly below `oracleClampBps` MUST accrue 0.
    function testDeadbandSuppressesPremiumBelowThreshold() external {
        vm.prank(OWNER);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: DEFAULT_FUNDING_CAP_BPS,
                maxSkewFundingBps: 0,
                oracleClampBps: 75, // 0.75% deadband
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );

        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(PRICE_2K);
        _publishImpactMid(PRICE_2010); // 0.5% premium — below the 0.75% deadband

        (int256 delta,) = engine.updateFunding(marketId);
        assertEq(delta, 0, "premium under deadband must accrue 0");
    }

    /// @notice Premium well above `maxFundingRateBps` MUST be clamped exactly.
    function testCapClampsFundingRate() external {
        vm.prank(OWNER);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: 50, // 0.5% cap
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );

        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(PRICE_2K);
        _publishImpactMid(PRICE_2200); // 10% premium — should saturate the 0.5% cap

        (int256 delta,) = engine.updateFunding(marketId);
        assertEq(delta, DELTA_CAPPED_50_BPS, "cap must clamp exactly at maxFundingRateBps");
    }

    /*//////////////////////////////////////////////////////////////
                    KEEPER OUTAGE / MISSING SAMPLE
    //////////////////////////////////////////////////////////////*/

    /// @notice A stale keeper sample (older than `impactMidMaxDelay`) MUST
    /// produce 0 rate — fail-CLOSED to a no-op, NOT a revert. A revert here
    /// would brick trading because `applyTrade` calls `updateFunding`.
    function testKeeperSampleStaleFailsClosedToZero() external {
        engine.updateFunding(marketId);
        _mockIndex(PRICE_2K);
        _publishImpactMid(PRICE_2020);

        // Warp beyond the freshness gate.
        vm.warp(block.timestamp + FUNDING_INTERVAL + DEFAULT_IMPACT_MID_MAX_DELAY + 1);

        // Re-mock the index so the oracle read continues to succeed.
        _mockIndex(PRICE_2K);

        (int256 delta,) = engine.updateFunding(marketId);
        assertEq(delta, 0, "stale impact-mid must fail-closed to 0 (not revert)");
    }

    /// @notice A market with no impact-mid sample ever published MUST produce
    /// 0 rate — same rationale as the stale case.
    function testKeeperNeverSeededProducesZeroRate() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockIndex(PRICE_2K);
        // Deliberately: no `_publishImpactMid` call.

        (int256 delta,) = engine.updateFunding(marketId);
        assertEq(delta, 0, "missing impact-mid sample must fail-closed to 0");
    }

    /*//////////////////////////////////////////////////////////////
                            DISABLED CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice `isEnabled=false` MUST produce 0 with no oracle call.
    /// @dev We deliberately do NOT mock the oracle here. If the funding path
    /// reads it, the mock will revert on `unmocked` — the test would fail.
    function testDisabledConfigShortCircuitsWithoutOracleCall() external {
        engine.updateFunding(marketId); // initialize timestamp

        vm.prank(OWNER);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 0
            })
        );

        vm.warp(block.timestamp + FUNDING_INTERVAL);

        (int256 delta, int256 nextCum) = engine.updateFunding(marketId);
        assertEq(delta, 0, "disabled funding must accrue 0");
        assertEq(nextCum, 0, "cumulative rate must remain 0");
    }

    /*//////////////////////////////////////////////////////////////
                    INDEX ORACLE UNAVAILABLE (REVERTS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Index oracle failure MUST REVERT — this is different from a
    /// missing keeper sample. The index is required infrastructure, not a
    /// keeper channel.
    function testIndexOracleUnavailableReverts() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        // Publish a fresh impact-mid so we exercise the index-side failure.
        _publishImpactMid(PRICE_2020);

        // Force the oracle to return an unusable price (px == 0, safeOk == false).
        bytes memory callData = abi.encodeWithSignature(
            "getPriceSafe(address,address)", address(weth), address(usdc)
        );
        vm.mockCall(address(oracle), callData, abi.encode(uint256(0), block.timestamp, false));

        vm.expectRevert(PerpEngineTypes.OraclePriceUnavailable.selector);
        engine.updateFunding(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Non-source callers MUST be rejected with `NotImpactMidSource`.
    function testOnlyImpactMidSourceCanUpdate() external {
        vm.prank(OUTSIDER);
        vm.expectRevert(PerpEngineTypes.NotImpactMidSource.selector);
        engine.updateImpactMid(marketId, PRICE_2020);

        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.NotImpactMidSource.selector);
        engine.updateImpactMid(marketId, PRICE_2020);
    }

    /// @notice `updateImpactMid(_, 0)` MUST revert; the keeper cannot force a
    /// zero sample to short-circuit the freshness gate.
    function testUpdateImpactMidRejectsZeroValue() external {
        vm.prank(IMPACT_MID_SOURCE);
        vm.expectRevert(PerpEngineTypes.OraclePriceUnavailable.selector);
        engine.updateImpactMid(marketId, 0);
    }

    /// @notice `updateImpactMid` on an unknown market MUST revert.
    function testUpdateImpactMidRejectsUnknownMarket() external {
        vm.prank(IMPACT_MID_SOURCE);
        vm.expectRevert(PerpEngineTypes.UnknownMarket.selector);
        engine.updateImpactMid(marketId + 1_000, PRICE_2020);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Only `owner` may set `impactMidSource`.
    function testOnlyOwnerCanSetImpactMidSource() external {
        vm.prank(OUTSIDER);
        vm.expectRevert(PerpEngineTypes.NotAuthorized.selector);
        engine.setImpactMidSource(address(0xFEED));
    }

    /// @notice `setImpactMidSource` MUST reject the zero address.
    function testSetImpactMidSourceRejectsZeroAddress() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpEngineTypes.InvalidImpactMidSource.selector);
        engine.setImpactMidSource(address(0));
    }

    /// @notice Happy-path governance rotation emits the audit event.
    function testSetImpactMidSourceEmitsRotationEvent() external {
        address next = address(0xFACE);

        vm.expectEmit(true, true, false, true, address(engine));
        emit ImpactMidSourceSet(IMPACT_MID_SOURCE, next);

        vm.prank(OWNER);
        engine.setImpactMidSource(next);
    }

    /*//////////////////////////////////////////////////////////////
                        FUNDING CONFIG VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Disabled + non-zero `impactMidMaxDelay` MUST fail validation.
    function testValidatorRejectsDelayWhenFundingDisabled() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpMarketRegistry.InvalidFundingConfig.selector);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 1
            })
        );
    }

    /// @notice Enabled + zero `impactMidMaxDelay` MUST fail validation
    /// (production configs cannot disable the staleness gate).
    function testValidatorRejectsZeroDelayWhenFundingEnabled() external {
        vm.prank(OWNER);
        vm.expectRevert(PerpMarketRegistry.InvalidFundingConfig.selector);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: DEFAULT_FUNDING_CAP_BPS,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 0
            })
        );
    }

    /// @notice Enabled + `impactMidMaxDelay > MAX_IMPACT_MID_MAX_DELAY` MUST fail.
    function testValidatorRejectsDelayAboveMaximum() external {
        // Pre-read the constant BEFORE `vm.expectRevert`. If we inline
        // `registry.MAX_IMPACT_MID_MAX_DELAY()` inside the struct literal,
        // that external staticcall consumes the expectRevert first (returning
        // a valid uint32) and the actual `setFundingConfig` never gets the
        // expectRevert coverage.
        uint32 aboveMax = registry.MAX_IMPACT_MID_MAX_DELAY() + 1;

        vm.prank(OWNER);
        vm.expectRevert(PerpMarketRegistry.InvalidFundingConfig.selector);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: DEFAULT_FUNDING_CAP_BPS,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: aboveMax
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MANIPULATION / FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Manipulation attack: a huge one-off impact-mid delta between
    /// funding intervals MUST be capped by `maxFundingRateBps`.
    /// @dev Fuzzed over a wide range of ABOVE-cap premiums; the invariant is
    /// `|rate| <= capAbs1e18` and the rate is exactly `capAbs1e18` (positive)
    /// when the premium sits above cap + deadband.
    function testFuzz_manipulationBoundedByCap(uint128 impactMid1e8, uint32 capBps, uint32 deadbandBps) external {
        // Bound inputs into meaningful ranges.
        capBps = uint32(bound(uint256(capBps), 1, 5_000)); // 0.01% .. 50%
        deadbandBps = uint32(bound(uint256(deadbandBps), 0, 100)); // 0..1% deadband
        // Make sure impact-mid produces a premium well above the cap so we
        // deterministically hit the clamp.
        uint256 minMid = uint256(PRICE_2K) + (uint256(PRICE_2K) * (uint256(capBps) + uint256(deadbandBps) + 200)) / 10_000;
        uint256 maxMid = uint256(PRICE_2K) * 3; // 3x is 20_000 bps premium — always above cap
        if (minMid >= maxMid) return;
        impactMid1e8 = uint128(bound(uint256(impactMid1e8), minMid, maxMid));

        vm.prank(OWNER);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: capBps,
                maxSkewFundingBps: 0,
                oracleClampBps: deadbandBps,
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );

        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);
        _mockIndex(PRICE_2K);
        _publishImpactMid(impactMid1e8);

        (int256 delta,) = engine.updateFunding(marketId);
        int256 capAbs1e18 = int256((uint256(capBps) * 1e18) / 10_000);
        int256 absDelta = delta >= 0 ? delta : -delta;
        assertLe(absDelta, capAbs1e18, "|rate| must not exceed configured cap");
        // The premium is definitively above cap+deadband, so the clamp saturates.
        assertEq(delta, capAbs1e18, "premium above cap must clamp exactly");
    }

    /*//////////////////////////////////////////////////////////////
                        FRESH-SAMPLE STATE READ
    //////////////////////////////////////////////////////////////*/

    /// @notice `updateImpactMid` emits the audit event with the exact ts.
    function testUpdateImpactMidEmitsAuditEvent() external {
        uint64 ts = uint64(block.timestamp);

        vm.expectEmit(true, false, false, true, address(engine));
        emit ImpactMidUpdated(marketId, PRICE_2020, ts);

        vm.prank(IMPACT_MID_SOURCE);
        engine.updateImpactMid(marketId, PRICE_2020);
    }

    /*//////////////////////////////////////////////////////////////
                    RUNTIME — RESTART + DUPLICATE WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Solidity storage IS the "process state" for funding —
    /// there is no ephemeral cache to lose across process restarts.
    /// This test pins the invariant explicitly: after seeding the
    /// impact-mid sample and warping past the interval, funding accrues
    /// even when the FIRST call for the market since deploy is the one
    /// that observes the sample. Behaviour matches a hot-restart where
    /// the keeper resumes publishing after downtime.
    function testFundingResumesAfterKeeperGapWithoutInMemoryState() external {
        // 1. First `updateFunding` seeds `lastFundingTimestamp` and
        //    returns 0 (no elapsed interval yet).
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        // 2. Keeper publishes a fresh sample.
        _mockIndex(PRICE_2K);
        _publishImpactMid(PRICE_2020);

        // 3. Second `updateFunding` picks it up and produces a non-zero
        //    delta. Storage is the only carrier — no in-memory state
        //    would survive a restart, but Solidity storage does.
        (int256 delta,) = engine.updateFunding(marketId);
        assertGt(delta, 0, "funding must resume after keeper gap");
        assertEq(delta, DELTA_POSITIVE_PREMIUM_1PCT);
    }

    /// @notice Two `updateImpactMid` calls in the SAME block for the
    /// same market → the last write wins (single-slot overwrite; no
    /// dedup, no queueing). Pins the semantics so a keeper double-tick
    /// (idempotent by design in the off-chain worker) cannot corrupt
    /// on-chain state.
    function testDuplicateImpactMidUpdateSameBlockLastWriteWins() external {
        // Seed lastFundingTimestamp — the first call always returns 0
        // by design; the interval delta emerges only from the SECOND
        // call after warping.
        engine.updateFunding(marketId);

        // Both writes at the same timestamp. Second write overwrites
        // the first (single-slot semantics, no queueing / dedup).
        vm.prank(IMPACT_MID_SOURCE);
        engine.updateImpactMid(marketId, PRICE_2010);
        vm.prank(IMPACT_MID_SOURCE);
        engine.updateImpactMid(marketId, PRICE_2020);

        // Advance past the interval, mock index, and read the funding
        // rate — it MUST reflect the second write (PRICE_2020 → 1%
        // premium → +1e16) NOT the first (PRICE_2010 → 0.5% premium →
        // a different, smaller magnitude). With `oracleClampBps=0`
        // both would produce non-zero deltas, so the assertion is
        // magnitude-specific.
        vm.warp(block.timestamp + FUNDING_INTERVAL);
        _mockIndex(PRICE_2K);
        (int256 delta,) = engine.updateFunding(marketId);
        assertGt(delta, 0, "second write must survive");
        assertEq(
            delta,
            DELTA_POSITIVE_PREMIUM_1PCT,
            "delta must match the 1% premium of the second write, not the 0.5% of the first"
        );
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mockIndex(uint128 indexPrice1e8) internal {
        bytes memory callData = abi.encodeWithSignature(
            "getPriceSafe(address,address)", address(weth), address(usdc)
        );
        vm.mockCall(address(oracle), callData, abi.encode(uint256(indexPrice1e8), block.timestamp, true));
    }

    function _publishImpactMid(uint128 mid1e8) internal {
        vm.prank(IMPACT_MID_SOURCE);
        engine.updateImpactMid(marketId, mid1e8);
    }

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _setHealthyRisk(address trader) internal {
        riskModule.setAccountRisk(trader, HUGE_EQUITY_BASE, 0, 0);
    }
}
