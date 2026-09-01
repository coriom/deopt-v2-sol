// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";

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
            equityBase: equityBase, maintenanceMarginBase: maintenanceMarginBase, initialMarginBase: initialMarginBase
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

contract PerpEngineFundingTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    int256 internal constant HUGE_EQUITY_BASE = 1_000_000 * 1e6;
    bytes32 internal constant ETH_PERP_SYMBOL = 0x4554482d50455250000000000000000000000000000000000000000000000000;

    uint128 internal constant ONE = 1e8;
    uint32 internal constant FUNDING_INTERVAL = 1 hours;
    uint32 internal constant DEFAULT_FUNDING_CAP_BPS = 5_000;
    /// @dev PERPS-FUNDING-V2 impact-mid keeper freshness gate used by these
    ///      tests. Set to `MAX_IMPACT_MID_MAX_DELAY` (1 hour) so a sample
    ///      published immediately after each `vm.warp` is still fresh.
    uint32 internal constant DEFAULT_IMPACT_MID_MAX_DELAY = 3600;

    uint128 internal constant PRICE_2K = 2_000 * 1e8;
    uint128 internal constant PRICE_2010 = 2_010 * 1e8;
    uint128 internal constant PRICE_2020 = 2_020 * 1e8;
    uint128 internal constant PRICE_1980 = 1_980 * 1e8;
    uint128 internal constant PRICE_2200 = 2_200 * 1e8;

    int256 internal constant DELTA_POSITIVE_PREMIUM_1PCT = 1e16;
    int256 internal constant DELTA_NEGATIVE_PREMIUM_1PCT = -1e16;
    int256 internal constant DELTA_CAPPED_50_BPS = 5e15;
    int256 internal constant ACCRUED_LONG_2X_1PCT = 2e6;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    /// @dev PERPS-FUNDING-V2 off-chain keeper source used by these tests.
    address internal constant IMPACT_MID_SOURCE = address(0xC1EE);

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    MockOracle internal oracle;
    MockPerpRiskModule internal riskModule;

    MockERC20Decimals internal usdc;
    MockERC20Decimals internal weth;

    uint256 internal marketId;

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
                closeFactorBps: 5_000, priceSpreadBps: 100, minImprovementBps: 50, oracleMaxDelay: 60
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
        // Configure the per-market execution-price deviation guard (fail-closed by default).
        // Wide 100% band to preserve pre-existing test behavior; new dedicated tests exercise
        // tight bands separately (see test/perp/PerpEngineExecutionPriceGuard.t.sol).
        registry.setMaxExecutionDeviationBps(marketId, 10_000);

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));
        // PERPS-FUNDING-V2: wire the trusted keeper source so `updateImpactMid`
        // can publish samples used by the funding premium computation.
        engine.setImpactMidSource(IMPACT_MID_SOURCE);
        vm.stopPrank();

        _setHealthyRisk(ALICE);
        _setHealthyRisk(BOB);
        _deposit(ALICE, 100_000 * BASE_UNIT);
        _deposit(BOB, 100_000 * BASE_UNIT);
    }

    function testUpdateFundingInitializesLastFundingTimestampOnFirstCall() external {
        PerpEngineTypes.MarketState memory beforeState = engine.marketState(marketId);
        assertEq(beforeState.lastFundingTimestamp, 0);

        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory afterState = engine.marketState(marketId);
        assertEq(delta, 0);
        assertEq(nextCumulative, 0);
        assertEq(afterState.lastFundingTimestamp, block.timestamp);
        assertEq(afterState.cumulativeFundingRate1e18, 0);
    }

    function testUpdateFundingReturnsZeroDeltaWhenFundingIsDisabled() external {
        engine.updateFunding(marketId);

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
        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(delta, 0);
        assertEq(nextCumulative, 0);
        assertEq(state.cumulativeFundingRate1e18, 0);
        assertEq(state.lastFundingTimestamp, block.timestamp);
    }

    function testUpdateFundingReturnsZeroDeltaWhenNoTimeElapsed() external {
        engine.updateFunding(marketId);

        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(delta, 0);
        assertEq(nextCumulative, 0);
        assertEq(state.cumulativeFundingRate1e18, 0);
        assertEq(state.lastFundingTimestamp, block.timestamp);
    }

    function testPositivePremiumProducesPositiveFundingRateDelta() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockSafePrices(PRICE_2020, PRICE_2K);

        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(delta, DELTA_POSITIVE_PREMIUM_1PCT);
        assertEq(nextCumulative, DELTA_POSITIVE_PREMIUM_1PCT);
        assertEq(state.cumulativeFundingRate1e18, DELTA_POSITIVE_PREMIUM_1PCT);
    }

    function testNegativePremiumProducesNegativeFundingRateDelta() external {
        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockSafePrices(PRICE_1980, PRICE_2K);

        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(delta, DELTA_NEGATIVE_PREMIUM_1PCT);
        assertEq(nextCumulative, DELTA_NEGATIVE_PREMIUM_1PCT);
        assertEq(state.cumulativeFundingRate1e18, DELTA_NEGATIVE_PREMIUM_1PCT);
    }

    function testFundingDeadbandSuppressesSmallPremiumDeviations() external {
        vm.prank(OWNER);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: DEFAULT_FUNDING_CAP_BPS,
                maxSkewFundingBps: 0,
                oracleClampBps: 75,
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );

        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockSafePrices(PRICE_2010, PRICE_2K);

        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(delta, 0);
        assertEq(nextCumulative, 0);
        assertEq(state.cumulativeFundingRate1e18, 0);
    }

    function testFundingCapClampsTheFundingRateCorrectly() external {
        vm.prank(OWNER);
        registry.setFundingConfig(
            marketId,
            PerpMarketRegistry.FundingConfig({
                isEnabled: true,
                fundingInterval: FUNDING_INTERVAL,
                maxFundingRateBps: 50,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY
            })
        );

        engine.updateFunding(marketId);
        vm.warp(block.timestamp + FUNDING_INTERVAL);

        _mockSafePrices(PRICE_2200, PRICE_2K);

        (int256 delta, int256 nextCumulative) = engine.updateFunding(marketId);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(delta, DELTA_CAPPED_50_BPS);
        assertEq(nextCumulative, DELTA_CAPPED_50_BPS);
        assertEq(state.cumulativeFundingRate1e18, DELTA_CAPPED_50_BPS);
    }

    function testAccruedFundingOnAnOpenPositionIsReflectedCorrectlyAfterFundingUpdate() external {
        // Mock the oracle to return `PRICE_2K` before the trade so the execution-price
        // deviation guard (`_enforceExecutionPriceGuard`) has a fresh reference.
        _mockSafePrices(PRICE_2K, PRICE_2K);
        _trade(ALICE, BOB, 2 * ONE, PRICE_2K);

        vm.warp(block.timestamp + FUNDING_INTERVAL);
        _mockSafePrices(PRICE_2020, PRICE_2K);

        engine.updateFunding(marketId);

        assertEq(engine.getPositionFundingAccrued(ALICE, marketId), ACCRUED_LONG_2X_1PCT);
        assertEq(engine.getPositionFundingAccrued(BOB, marketId), -ACCRUED_LONG_2X_1PCT);
    }

    function _trade(address buyer, address seller, uint128 sizeDelta1e8, uint128 executionPrice1e8) internal {
        vm.prank(MATCHING_ENGINE);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                marketId: marketId,
                sizeDelta1e8: sizeDelta1e8,
                executionPrice1e8: executionPrice1e8,
                buyerIsMaker: false
            })
        );
    }

    /// @dev PERPS-FUNDING-V2 test helper.
    ///  - `marketRefPrice1e8` is published to the engine via `updateImpactMid`
    ///    and used as the "market reference" (impact-mid) in the funding
    ///    premium formula.
    ///  - `indexPrice1e8` is mocked on the oracle and used as the "index" side.
    ///
    ///  The function name preserves compatibility with the pre-V2 test signature
    ///  (which used to feed two return values into a double-read of the oracle)
    ///  but the semantics now match the fixed funding math: distinct source per
    ///  price side (keeper vs oracle).
    function _mockSafePrices(uint128 marketRefPrice1e8, uint128 indexPrice1e8) internal {
        bytes memory callData = abi.encodeWithSignature("getPriceSafe(address,address)", address(weth), address(usdc));
        vm.mockCall(address(oracle), callData, abi.encode(uint256(indexPrice1e8), block.timestamp, true));

        if (marketRefPrice1e8 != 0) {
            vm.prank(IMPACT_MID_SOURCE);
            engine.updateImpactMid(marketId, marketRefPrice1e8);
        }
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
