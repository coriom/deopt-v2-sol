// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IRiskModule} from "../../../src/risk/IRiskModule.sol";
import {IMarginEngineState} from "../../../src/risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../../../src/matching/IMarginEngineTrade.sol";
import {MarginEngine} from "../../../src/margin/MarginEngine.sol";
import {MarginEngineTypes} from "../../../src/margin/MarginEngineTypes.sol";

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
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => PriceData) internal prices;

    function setPrice(address baseAsset, address quoteAsset, uint256 price, uint256 updatedAt, bool ok) external {
        prices[keccak256(abi.encode(baseAsset, quoteAsset))] =
            PriceData({price: price, updatedAt: updatedAt, ok: ok});
    }

    function getPrice(address baseAsset, address quoteAsset) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = prices[keccak256(abi.encode(baseAsset, quoteAsset))];
        require(data.ok, "price-not-set");
        return (data.price, data.updatedAt);
    }

    function getPriceSafe(address baseAsset, address quoteAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt, bool ok)
    {
        PriceData memory data = prices[keccak256(abi.encode(baseAsset, quoteAsset))];
        return (data.price, data.updatedAt, data.ok);
    }
}

contract MockMarginRiskModule is IRiskModule {
    IMarginEngineState internal immutable marginState;
    address public immutable override baseCollateralToken;
    uint8 public immutable override baseDecimals;
    uint256 public immutable override baseMaintenanceMarginPerContract;
    uint256 public immutable override imFactorBps;

    mapping(address => int256) internal equityBaseByTrader;

    constructor(
        address marginState_,
        address baseCollateralToken_,
        uint8 baseDecimals_,
        uint256 baseMaintenanceMarginPerContract_,
        uint256 imFactorBps_
    ) {
        marginState = IMarginEngineState(marginState_);
        baseCollateralToken = baseCollateralToken_;
        baseDecimals = baseDecimals_;
        baseMaintenanceMarginPerContract = baseMaintenanceMarginPerContract_;
        imFactorBps = imFactorBps_;
    }

    function setEquityBase(address trader, int256 equityBase_) external {
        equityBaseByTrader[trader] = equityBase_;
    }

    function computeAccountRisk(address trader) public view returns (AccountRisk memory risk) {
        uint256 shortContracts = marginState.totalShortContracts(trader);
        uint256 mmBase = shortContracts * baseMaintenanceMarginPerContract;

        risk = AccountRisk({
            equityBase: equityBaseByTrader[trader],
            maintenanceMarginBase: mmBase,
            initialMarginBase: (mmBase * imFactorBps) / 10_000
        });
    }

    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase) {
        AccountRisk memory risk = computeAccountRisk(trader);
        return risk.equityBase - int256(risk.initialMarginBase);
    }

    function computeMarginRatioBps(address trader) external view returns (uint256) {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.maintenanceMarginBase == 0) return type(uint256).max;
        if (risk.equityBase <= 0) return 0;
        return (uint256(risk.equityBase) * 10_000) / risk.maintenanceMarginBase;
    }

    function computeAccountRiskBreakdown(address trader)
        external
        view
        returns (AccountRiskBreakdown memory breakdown)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        breakdown.equityBase = risk.equityBase;
        breakdown.maintenanceMarginBase = risk.maintenanceMarginBase;
        breakdown.initialMarginBase = risk.initialMarginBase;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256 amount) {
        return type(uint256).max;
    }

    function previewWithdrawImpact(address trader, address, uint256 amount)
        external
        view
        returns (WithdrawPreview memory preview)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        preview.requestedAmount = amount;
        preview.maxWithdrawable = type(uint256).max;
        preview.marginRatioBeforeBps = risk.maintenanceMarginBase == 0
            ? type(uint256).max
            : risk.equityBase <= 0 ? 0 : (uint256(risk.equityBase) * 10_000) / risk.maintenanceMarginBase;
        preview.marginRatioAfterBps = preview.marginRatioBeforeBps;
    }

    function computeCollateralState(address) external pure returns (CollateralState memory state) {
        return state;
    }

    function computeProductRiskState(address) external pure returns (ProductRiskState memory state) {
        return state;
    }

    function getResidualBadDebt(address) external pure returns (uint256 amountBase) {
        return amountBase;
    }
}

contract MarginEngineTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint256 internal constant STRIKE = 2_000 * PRICE_SCALE;
    uint128 internal constant PREMIUM_PER_CONTRACT = 100 * 1e6;
    uint256 internal constant BASE_MM_PER_CONTRACT = 10 * BASE_UNIT;
    uint256 internal constant IM_FACTOR_BPS = 12_000;
    uint256 internal constant HEALTHY_EQUITY = 1_000_000 * BASE_UNIT;
    uint256 internal constant LIQUIDATABLE_EQUITY = 9 * BASE_UNIT;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant DAVE = address(0xD4);
    address internal constant GUARDIAN = address(0x1234);

    CollateralVault internal vault;
    OptionProductRegistry internal registry;
    MarginEngine internal engine;
    MockOracle internal oracle;
    MockMarginRiskModule internal riskModule;

    MockERC20Decimals internal usdc;
    MockERC20Decimals internal weth;

    uint256 internal callOptionId;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new OptionProductRegistry(OWNER);
        oracle = new MockOracle();
        engine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));

        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        weth = new MockERC20Decimals("Mock WETH", "mWETH", 18);

        riskModule =
            new MockMarginRiskModule(address(engine), address(usdc), 6, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setMarginEngine(address(engine));

        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth),
            OptionProductRegistry.UnderlyingConfig({
                oracle: address(oracle),
                spotShockDownBps: 3_000,
                spotShockUpBps: 3_000,
                volShockDownBps: 0,
                volShockUpBps: 2_000,
                isEnabled: true
            })
        );

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));
        engine.syncRiskParamsFromRiskModule();
        engine.setLiquidationParams(10_050, 500);
        engine.setLiquidationHardenParams(10_000, 1);
        engine.setLiquidationPricingParams(0, 0);
        engine.setLiquidationOracleMaxDelay(600);
        vm.stopPrank();

        vm.prank(OWNER);
        callOptionId = registry.createSeries(
            address(weth),
            address(usdc),
            uint64(block.timestamp + 7 days),
            uint64(STRIKE),
            true,
            true
        );

        oracle.setPrice(address(weth), address(usdc), STRIKE, block.timestamp, true);

        _setHealthyEquity(ALICE);
        _setHealthyEquity(BOB);
        _setHealthyEquity(CAROL);
        _setHealthyEquity(DAVE);

        _deposit(ALICE, 10_000 * BASE_UNIT);
        _deposit(BOB, 10_000 * BASE_UNIT);
        _deposit(CAROL, 10_000 * BASE_UNIT);
        _deposit(DAVE, 10_000 * BASE_UNIT);
    }

    function testOpeningPositionUpdatesTraderSeriesCorrectly() external {
        _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

        uint256[] memory aliceSeries = engine.getTraderSeries(ALICE);
        uint256[] memory bobSeries = engine.getTraderSeries(BOB);

        assertEq(aliceSeries.length, 1);
        assertEq(aliceSeries[0], callOptionId);
        assertTrue(engine.isOpenSeries(ALICE, callOptionId));

        assertEq(bobSeries.length, 1);
        assertEq(bobSeries[0], callOptionId);
        assertTrue(engine.isOpenSeries(BOB, callOptionId));
    }

    function testClosingPositionRemovesItFromActiveSeries() external {
        _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
        _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);

        assertEq(engine.getTraderSeriesLength(ALICE), 0);
        assertEq(engine.getTraderSeriesLength(BOB), 0);
        assertFalse(engine.isOpenSeries(ALICE, callOptionId));
        assertFalse(engine.isOpenSeries(BOB, callOptionId));
        assertEq(engine.positions(ALICE, callOptionId).quantity, 0);
        assertEq(engine.positions(BOB, callOptionId).quantity, 0);
    }

    function testTotalShortExposureIsUpdatedCorrectlyOnOpenAndClose() external {
        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);
        assertEq(engine.totalShortContracts(BOB), 2);
        assertEq(engine.seriesShortOpenInterest(callOptionId), 2);

        _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);
        assertEq(engine.totalShortContracts(BOB), 1);
        assertEq(engine.seriesShortOpenInterest(callOptionId), 1);

        _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);
        assertEq(engine.totalShortContracts(BOB), 0);
        assertEq(engine.seriesShortOpenInterest(callOptionId), 0);
    }

    function testSeriesShortOpenInterestCapBlocksNewShortExposureAboveCap() external {
        vm.prank(OWNER);
        engine.setSeriesShortOpenInterestCap(callOptionId, 2);

        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

        vm.prank(MATCHING_ENGINE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarginEngineTypes.SeriesShortOpenInterestCapExceeded.selector,
                callOptionId,
                3,
                2
            )
        );
        engine.applyTrade(
            IMarginEngineTrade.Trade({
                buyer: ALICE,
                seller: CAROL,
                optionId: callOptionId,
                quantity: 1,
                price: PREMIUM_PER_CONTRACT,
                buyerIsMaker: true
            })
        );

        assertEq(engine.seriesShortOpenInterest(callOptionId), 2);
        assertEq(engine.positions(CAROL, callOptionId).quantity, 0);
    }

    function testLoweredSeriesShortOpenInterestCapStillAllowsReduction() external {
        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

        vm.prank(OWNER);
        engine.setSeriesShortOpenInterestCap(callOptionId, 1);

        _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);

        assertEq(engine.seriesShortOpenInterest(callOptionId), 1);
        assertEq(engine.totalShortContracts(BOB), 1);
    }

    function testSeriesEmergencyCloseOnlyBlocksOpeningWithoutGlobalTradingPause() external {
        _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

        vm.prank(OWNER);
        engine.setSeriesEmergencyCloseOnly(callOptionId, true);

        assertFalse(engine.tradingPaused());
        assertTrue(engine.seriesEmergencyCloseOnly(callOptionId));

        vm.expectRevert(MarginEngineTypes.SeriesNotActiveCloseOnly.selector);
        _trade(ALICE, CAROL, callOptionId, 1, PREMIUM_PER_CONTRACT);

        assertEq(engine.positions(ALICE, callOptionId).quantity, 1);
        assertEq(engine.positions(CAROL, callOptionId).quantity, 0);
    }

    function testGuardianSeriesEmergencyCloseOnlyStillAllowsTwoSidedClose() external {
        vm.prank(OWNER);
        engine.setGuardian(GUARDIAN);

        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

        vm.prank(GUARDIAN);
        engine.setSeriesEmergencyCloseOnly(callOptionId, true);

        _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);

        assertEq(engine.positions(ALICE, callOptionId).quantity, 1);
        assertEq(engine.positions(BOB, callOptionId).quantity, -1);
        assertEq(engine.seriesShortOpenInterest(callOptionId), 1);
    }

    function testPremiumTransferBetweenBuyerAndSellerIsCorrect() external {
        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));

        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

        assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - (2 * PREMIUM_PER_CONTRACT));
        assertEq(vault.balances(BOB, address(usdc)), bobBefore + (2 * PREMIUM_PER_CONTRACT));
    }

    function testSettlementProducesCorrectPayoffAtExpiry() external {
        _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));

        vm.warp(block.timestamp + 8 days);
        vm.prank(OWNER);
        registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

        engine.settleAccount(callOptionId, BOB);
        engine.settleAccount(callOptionId, ALICE);

        assertEq(vault.balances(ALICE, address(usdc)), aliceBefore + (500 * BASE_UNIT));
        assertEq(vault.balances(BOB, address(usdc)), bobBefore - (500 * BASE_UNIT));
        assertEq(engine.positions(ALICE, callOptionId).quantity, 0);
        assertEq(engine.positions(BOB, callOptionId).quantity, 0);
    }

    function testExpiredOptionCannotBeExercisedTwice() external {
        _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

        vm.warp(block.timestamp + 8 days);
        vm.prank(OWNER);
        registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

        engine.settleAccount(callOptionId, ALICE);

        vm.expectRevert(MarginEngineTypes.SettlementAlreadyProcessed.selector);
        engine.settleAccount(callOptionId, ALICE);
    }

    function testLiquidationReducesPositionSizeCorrectly() external {
        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);
        riskModule.setEquityBase(BOB, int256(LIQUIDATABLE_EQUITY));
        oracle.setPrice(address(weth), address(usdc), 1_900 * PRICE_SCALE, block.timestamp, true);

        uint256[] memory optionIds = new uint256[](1);
        uint128[] memory quantities = new uint128[](1);
        optionIds[0] = callOptionId;
        quantities[0] = 1;

        vm.prank(CAROL);
        engine.liquidate(BOB, optionIds, quantities);

        assertEq(engine.positions(BOB, callOptionId).quantity, -1);
        assertEq(engine.positions(CAROL, callOptionId).quantity, -1);
        assertEq(engine.totalShortContracts(BOB), 1);
    }

    function testPreviewLiquidationBreaksDownRequestedCloseAndCash() external {
        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);
        riskModule.setEquityBase(BOB, int256(LIQUIDATABLE_EQUITY));
        oracle.setPrice(address(weth), address(usdc), 2_500 * PRICE_SCALE, block.timestamp, true);

        uint256[] memory optionIds = new uint256[](1);
        uint128[] memory quantities = new uint128[](1);
        optionIds[0] = callOptionId;
        quantities[0] = 2;

        MarginEngine.OptionsLiquidationPreview memory preview = engine.previewLiquidation(BOB, optionIds, quantities);

        assertTrue(preview.liquidatable);
        assertEq(preview.equityBeforeBase, int256(LIQUIDATABLE_EQUITY));
        assertEq(preview.maintenanceMarginBeforeBase, 2 * BASE_MM_PER_CONTRACT);
        assertEq(preview.initialMarginBeforeBase, (2 * BASE_MM_PER_CONTRACT * IM_FACTOR_BPS) / 10_000);
        assertEq(preview.totalShortContracts, 2);
        assertEq(preview.maxCloseContracts, 2);
        assertEq(preview.totalContractsPreviewed, 2);
        assertEq(preview.executedQuantities[0], 2);
        assertEq(preview.pricePerContract[0], 500 * BASE_UNIT);
        assertEq(preview.cashAssetCount, 1);
        assertEq(preview.settlementAssets[0], address(usdc));
        assertEq(preview.cashRequestedByAsset[0], 1_000 * BASE_UNIT);
        assertEq(preview.penaltyBase, (2 * BASE_MM_PER_CONTRACT * 500) / 10_000);
    }

    function testSeriesEmergencyCloseOnlyStillAllowsLiquidation() external {
        _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);
        riskModule.setEquityBase(BOB, int256(LIQUIDATABLE_EQUITY));
        oracle.setPrice(address(weth), address(usdc), 1_900 * PRICE_SCALE, block.timestamp, true);

        vm.prank(OWNER);
        engine.setSeriesEmergencyCloseOnly(callOptionId, true);

        uint256[] memory optionIds = new uint256[](1);
        uint128[] memory quantities = new uint128[](1);
        optionIds[0] = callOptionId;
        quantities[0] = 1;

        vm.prank(CAROL);
        engine.liquidate(BOB, optionIds, quantities);

        assertEq(engine.positions(BOB, callOptionId).quantity, -1);
        assertEq(engine.positions(CAROL, callOptionId).quantity, -1);
        assertEq(engine.totalShortContracts(BOB), 1);
    }

    function testLiquidationRespectsPenaltyLogic() external {
        _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
        riskModule.setEquityBase(BOB, int256(LIQUIDATABLE_EQUITY));
        oracle.setPrice(address(weth), address(usdc), 1_900 * PRICE_SCALE, block.timestamp, true);

        uint256 bobBefore = vault.balances(BOB, address(usdc));
        uint256 carolBefore = vault.balances(CAROL, address(usdc));

        uint256[] memory optionIds = new uint256[](1);
        uint128[] memory quantities = new uint128[](1);
        optionIds[0] = callOptionId;
        quantities[0] = 1;

        vm.prank(CAROL);
        engine.liquidate(BOB, optionIds, quantities);

        uint256 expectedPenalty = (BASE_MM_PER_CONTRACT * 500) / 10_000;
        assertEq(vault.balances(BOB, address(usdc)), bobBefore - expectedPenalty);
        assertEq(vault.balances(CAROL, address(usdc)), carolBefore + expectedPenalty);
    }

    function testAccountWithNoPositionsReturnsEmptySeriesAndZeroExposure() external {
        uint256[] memory series = engine.getTraderSeries(DAVE);
        MarginEngine.AccountState memory state = engine.getAccountState(DAVE);

        assertEq(series.length, 0);
        assertEq(engine.getTraderSeriesLength(DAVE), 0);
        assertEq(engine.totalShortContracts(DAVE), 0);
        assertEq(state.openSeriesCount, 0);
        assertEq(state.totalShortOpenContracts, 0);
    }

    function _trade(address buyer, address seller, uint256 optionId, uint128 quantity, uint128 premiumPerContract)
        internal
    {
        vm.prank(MATCHING_ENGINE);
        engine.applyTrade(
            IMarginEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                optionId: optionId,
                quantity: quantity,
                price: premiumPerContract,
                buyerIsMaker: true
            })
        );
    }

    function _deposit(address trader, uint256 amount) internal {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _setHealthyEquity(address trader) internal {
        riskModule.setEquityBase(trader, int256(HEALTHY_EQUITY));
    }
}
