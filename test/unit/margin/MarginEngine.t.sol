// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {FeesManager} from "../../../src/fees/FeesManager.sol";
import {FeesManagerV2} from "../../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../../src/fees/IFeesManagerV2.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IRiskModule} from "../../../src/risk/IRiskModule.sol";
import {IMarginEngineState} from "../../../src/risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../../../src/matching/IMarginEngineTrade.sol";
import {MarginEngineLens} from "../../../src/lens/MarginEngineLens.sol";
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
        prices[keccak256(abi.encode(baseAsset, quoteAsset))] = PriceData({price: price, updatedAt: updatedAt, ok: ok});
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

    function computeAccountRiskBreakdown(address trader) external view returns (AccountRiskBreakdown memory breakdown) {
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
        uint256 internal constant V2_VOLUME_28D = 25_000_000 * BASE_UNIT;
        uint32 internal constant V2_VOLUME_SHARE_PPM = 50_000;
        uint256 internal constant V2_STAKED_DEOPT = 250_000e8;

        CollateralVault internal vault;
        OptionProductRegistry internal registry;
        MarginEngine internal engine;
        MarginEngineLens internal lens;
        MockOracle internal oracle;
        MockMarginRiskModule internal riskModule;
        FeesManager internal feesManagerV1;
        FeesManagerV2 internal feesManagerV2;

        MockERC20Decimals internal usdc;
        MockERC20Decimals internal weth;

        uint256 internal callOptionId;

        function setUp() external {
            vault = new CollateralVault(OWNER);
            registry = new OptionProductRegistry(OWNER);
            oracle = new MockOracle();
            engine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));
            lens = new MarginEngineLens();

            usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
            weth = new MockERC20Decimals("Mock WETH", "mWETH", 18);

            riskModule = new MockMarginRiskModule(
                address(engine), address(usdc), 6, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS
            );

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
                address(weth), address(usdc), uint64(block.timestamp + 7 days), uint64(STRIKE), true, true
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
                    MarginEngineTypes.SeriesShortOpenInterestCapExceeded.selector, callOptionId, 3, 2
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

            vm.expectEmit(true, false, false, true);
            emit MarginEngineTypes.SeriesEmergencyCloseOnlySet(callOptionId, false, true);
            vm.expectEmit(true, true, false, true);
            emit MarginEngineTypes.SeriesEmergencyCloseOnlyUpdated(OWNER, callOptionId, false, true);
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

        function testRestrictedSeriesActivationBlocksOpeningButAllowsReduction() external {
            _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

            vm.expectEmit(true, false, false, true);
            emit MarginEngineTypes.SeriesActivationStateSet(callOptionId, 0, 1);
            vm.prank(OWNER);
            engine.setSeriesActivationState(callOptionId, 1);

            vm.expectRevert(MarginEngineTypes.SeriesNotActiveCloseOnly.selector);
            _trade(ALICE, CAROL, callOptionId, 1, PREMIUM_PER_CONTRACT);

            _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);

            assertEq(engine.seriesActivationState(callOptionId), 1);
            assertEq(engine.positions(ALICE, callOptionId).quantity, 1);
            assertEq(engine.positions(BOB, callOptionId).quantity, -1);
            assertEq(engine.positions(CAROL, callOptionId).quantity, 0);
            assertEq(engine.seriesShortOpenInterest(callOptionId), 1);
        }

        function testInactiveSeriesActivationAllowsOnlyStrictCloseToZero() external {
            _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

            vm.expectEmit(true, false, false, true);
            emit MarginEngineTypes.SeriesActivationStateSet(callOptionId, 0, 2);
            vm.prank(OWNER);
            engine.setSeriesActivationState(callOptionId, 2);

            vm.expectRevert(MarginEngineTypes.SeriesNotActiveCloseOnly.selector);
            _trade(BOB, ALICE, callOptionId, 1, PREMIUM_PER_CONTRACT);

            vm.expectRevert(MarginEngineTypes.SeriesNotActiveCloseOnly.selector);
            _trade(ALICE, CAROL, callOptionId, 1, PREMIUM_PER_CONTRACT);

            _trade(BOB, ALICE, callOptionId, 2, PREMIUM_PER_CONTRACT);

            assertEq(engine.seriesActivationState(callOptionId), 2);
            assertEq(engine.positions(ALICE, callOptionId).quantity, 0);
            assertEq(engine.positions(BOB, callOptionId).quantity, 0);
            assertEq(engine.positions(CAROL, callOptionId).quantity, 0);
            assertEq(engine.seriesShortOpenInterest(callOptionId), 0);
        }

        function testPremiumTransferBetweenBuyerAndSellerIsCorrect() external {
            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));

            _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - (2 * PREMIUM_PER_CONTRACT));
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + (2 * PREMIUM_PER_CONTRACT));
        }

        function testFeesManagerV1BehaviorUnchangedWhenV2Disabled() external {
            _configureV1Fees();
            _configureV2Fees(false);

            assertFalse(engine.useFeesManagerV2());

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

            uint256 makerFeeV1 = 40_000;
            uint256 takerFeeV1 = 60_000;

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT - makerFeeV1);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV1);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + makerFeeV1 + takerFeeV1);
        }

        function testFeesManagerV2AdminControls() external {
            feesManagerV2 = new FeesManagerV2(OWNER, DAVE);

            vm.prank(OWNER);
            vm.expectRevert(MarginEngineTypes.ZeroAddress.selector);
            engine.setUseFeesManagerV2(true);

            vm.prank(OWNER);
            engine.setFeesManagerV2(address(feesManagerV2));

            assertEq(address(engine.feesManagerV2()), address(feesManagerV2));
            assertFalse(engine.useFeesManagerV2());

            vm.prank(OWNER);
            engine.setUseFeesManagerV2(true);

            assertTrue(engine.useFeesManagerV2());
        }

        function testFeesManagerV2PositiveOptionFeesTransferAndPositionsUpdate() external {
            _configureV2Fees(true);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            vm.recordLogs();
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            uint256 makerFeeV2 = 5_000;
            uint256 takerFeeV2 = 25_000;

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT - makerFeeV2);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + makerFeeV2 + takerFeeV2);
            assertEq(engine.positions(ALICE, callOptionId).quantity, 1);
            assertEq(engine.positions(BOB, callOptionId).quantity, -1);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 2);
        }

        function testFeesManagerV2MakerRebateTransfersFromFundingAccount() external {
            _configureV2Fees(true);
            _claimV2Tier(ALICE, 4);

            vm.prank(OWNER);
            feesManagerV2.fundRebateBudget(address(usdc), 10_000);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 carolBefore = vault.balances(CAROL, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            vm.recordLogs();
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            uint256 makerRebate = 5_000;
            uint256 takerFeeV2 = 25_000;

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT + makerRebate);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2);
            assertEq(vault.balances(CAROL, address(usdc)), carolBefore - makerRebate);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + takerFeeV2);
            assertEq(feesManagerV2.rebateBudget(address(usdc)), 5_000);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeRebatedV2Topic()), 1);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 1);
        }

        function testFeesManagerV2InsufficientRebateBudgetRevertsTrade() external {
            _configureV2Fees(true);
            _claimV2Tier(ALICE, 4);

            vm.prank(OWNER);
            feesManagerV2.fundRebateBudget(address(usdc), 4_999);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 carolBefore = vault.balances(CAROL, address(usdc));

            vm.expectRevert(
                abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, address(usdc), 4_999, 5_000)
            );
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore);
            assertEq(vault.balances(CAROL, address(usdc)), carolBefore);
            assertEq(engine.positions(ALICE, callOptionId).quantity, 0);
            assertEq(engine.positions(BOB, callOptionId).quantity, 0);
            assertEq(feesManagerV2.rebateBudget(address(usdc)), 4_999);
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

        function testWinningLongSettlementEmitsShortfallInsuranceAndBadDebtEvents() external {
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

            vm.prank(OWNER);
            engine.setInsuranceFund(DAVE);

            vm.prank(address(engine));
            vault.transferBetweenAccounts(address(usdc), DAVE, CAROL, 9_700 * BASE_UNIT);

            vm.warp(block.timestamp + 8 days);
            vm.prank(OWNER);
            registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

            vm.expectEmit(true, true, true, true);
            emit MarginEngineTypes.AccountSettlementResolved(
                ALICE,
                callOptionId,
                address(usdc),
                1,
                2_500 * PRICE_SCALE,
                500 * BASE_UNIT,
                int256(500 * BASE_UNIT),
                500 * BASE_UNIT
            );
            vm.expectEmit(true, true, false, true);
            emit MarginEngineTypes.SettlementInsuranceCoverage(ALICE, callOptionId, 500 * BASE_UNIT, 300 * BASE_UNIT);
            vm.expectEmit(true, true, false, true);
            emit MarginEngineTypes.SettlementShortfall(
                ALICE, callOptionId, 500 * BASE_UNIT, 300 * BASE_UNIT, 200 * BASE_UNIT
            );
            vm.expectEmit(true, true, false, true);
            emit MarginEngineTypes.SettlementBadDebtRecorded(ALICE, callOptionId, 200 * BASE_UNIT);

            engine.settleAccount(callOptionId, ALICE);
        }

        function testShortSettlementEmitsCollectionShortfallAndBadDebtEvents() external {
            _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

            vm.prank(address(engine));
            vault.transferBetweenAccounts(address(usdc), BOB, CAROL, 9_800 * BASE_UNIT);

            vm.warp(block.timestamp + 8 days);
            vm.prank(OWNER);
            registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

            vm.expectEmit(true, true, true, true);
            emit MarginEngineTypes.AccountSettlementResolved(
                BOB,
                callOptionId,
                address(usdc),
                -2,
                2_500 * PRICE_SCALE,
                500 * BASE_UNIT,
                -int256(1_000 * BASE_UNIT),
                1_000 * BASE_UNIT
            );
            vm.expectEmit(true, true, false, true);
            emit MarginEngineTypes.SettlementCollectionShortfall(
                BOB, callOptionId, 1_000 * BASE_UNIT, 400 * BASE_UNIT, 600 * BASE_UNIT
            );
            vm.expectEmit(true, true, false, true);
            emit MarginEngineTypes.SettlementBadDebtRecorded(BOB, callOptionId, 600 * BASE_UNIT);

            engine.settleAccount(callOptionId, BOB);
        }

        function testPreviewDetailedSettlementShowsInsuranceCoverageForWinningLong() external {
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

            vm.prank(OWNER);
            engine.setInsuranceFund(DAVE);

            vm.prank(address(engine));
            vault.transferBetweenAccounts(address(usdc), DAVE, CAROL, 9_700 * BASE_UNIT);

            vm.warp(block.timestamp + 8 days);
            vm.prank(OWNER);
            registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

            MarginEngineLens.DetailedSettlementPreview memory preview =
                lens.previewDetailedSettlement(address(engine), callOptionId, ALICE);

            assertTrue(preview.seriesExpired);
            assertTrue(preview.settlementPriceSet);
            assertTrue(preview.settlementReady);
            assertFalse(preview.accountSettled);
            assertEq(preview.positionQuantity, 1);
            assertEq(preview.payoffPerContract, 500 * BASE_UNIT);
            assertEq(preview.grossSettlementAmount, 500 * BASE_UNIT);
            assertFalse(preview.isShortLiability);
            assertEq(preview.shortLiabilityAmount, 0);
            assertEq(preview.settlementSinkBalance, 300 * BASE_UNIT);
            assertEq(preview.collateralCoveragePreview, 0);
            assertEq(preview.insuranceCoveragePreview, 300 * BASE_UNIT);
            assertEq(preview.residualShortfallPreview, 200 * BASE_UNIT);
            assertEq(preview.residualBadDebtPreview, 200 * BASE_UNIT);
            assertTrue(preview.grossSettlementAmountBaseAvailable);
            assertEq(preview.grossSettlementAmountBase, 500 * BASE_UNIT);
            assertTrue(preview.accountCashflowDeltaBaseAvailable);
            assertEq(preview.accountCashflowDeltaBase, int256(300 * BASE_UNIT));
            assertEq(preview.riskBefore.equityBase, int256(HEALTHY_EQUITY));
            assertEq(preview.riskBefore.maintenanceMarginBase, 0);
            assertEq(preview.riskBefore.initialMarginBase, 0);
            assertEq(preview.riskBefore.marginRatioBps, type(uint256).max);
            assertTrue(preview.riskAfterAvailable);
            assertEq(preview.riskAfter.equityBase, int256(HEALTHY_EQUITY + (300 * BASE_UNIT)));
            assertEq(preview.riskAfter.maintenanceMarginBase, 0);
            assertEq(preview.riskAfter.initialMarginBase, 0);
            assertEq(preview.riskAfter.marginRatioBps, type(uint256).max);
        }

        function testPreviewDetailedSettlementShowsShortLiabilityCoverageAndRiskRelease() external {
            _trade(ALICE, BOB, callOptionId, 2, PREMIUM_PER_CONTRACT);

            vm.prank(address(engine));
            vault.transferBetweenAccounts(address(usdc), BOB, CAROL, 9_800 * BASE_UNIT);

            vm.warp(block.timestamp + 8 days);
            vm.prank(OWNER);
            registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

            MarginEngineLens.DetailedSettlementPreview memory preview =
                lens.previewDetailedSettlement(address(engine), callOptionId, BOB);

            assertTrue(preview.seriesExpired);
            assertTrue(preview.settlementPriceSet);
            assertTrue(preview.settlementReady);
            assertEq(preview.positionQuantity, -2);
            assertEq(preview.payoffPerContract, 500 * BASE_UNIT);
            assertEq(preview.pnl, -int256(1_000 * BASE_UNIT));
            assertEq(preview.grossSettlementAmount, 1_000 * BASE_UNIT);
            assertTrue(preview.isShortLiability);
            assertEq(preview.shortLiabilityAmount, 1_000 * BASE_UNIT);
            assertEq(preview.traderSettlementAssetBalance, 400 * BASE_UNIT);
            assertEq(preview.collateralCoveragePreview, 400 * BASE_UNIT);
            assertEq(preview.insuranceCoveragePreview, 0);
            assertEq(preview.residualShortfallPreview, 600 * BASE_UNIT);
            assertEq(preview.residualBadDebtPreview, 600 * BASE_UNIT);
            assertTrue(preview.grossSettlementAmountBaseAvailable);
            assertEq(preview.grossSettlementAmountBase, 1_000 * BASE_UNIT);
            assertTrue(preview.accountCashflowDeltaBaseAvailable);
            assertEq(preview.accountCashflowDeltaBase, -int256(400 * BASE_UNIT));
            assertEq(preview.riskBefore.equityBase, int256(HEALTHY_EQUITY));
            assertEq(preview.riskBefore.maintenanceMarginBase, 2 * BASE_MM_PER_CONTRACT);
            assertEq(preview.riskBefore.initialMarginBase, (2 * BASE_MM_PER_CONTRACT * IM_FACTOR_BPS) / 10_000);
            assertTrue(preview.riskAfterAvailable);
            assertEq(preview.riskAfter.equityBase, int256(HEALTHY_EQUITY - (400 * BASE_UNIT)));
            assertEq(preview.riskAfter.maintenanceMarginBase, 0);
            assertEq(preview.riskAfter.initialMarginBase, 0);
            assertEq(preview.riskAfter.marginRatioBps, type(uint256).max);
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

            MarginEngineLens.OptionsLiquidationPreview memory preview =
                lens.previewLiquidation(address(engine), BOB, optionIds, quantities);

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
            MarginEngineLens.AccountState memory state = lens.getAccountState(address(engine), DAVE);

            assertEq(series.length, 0);
            assertEq(engine.getTraderSeriesLength(DAVE), 0);
            assertEq(engine.totalShortContracts(DAVE), 0);
            assertEq(state.openSeriesCount, 0);
            assertEq(state.totalShortOpenContracts, 0);
        }

        function testLensDetailedSettlementPreviewDoesNotMutateProtocolState() external {
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

            vm.warp(block.timestamp + 8 days);
            vm.prank(OWNER);
            registry.setSettlementPrice(callOptionId, 2_500 * PRICE_SCALE);

            int128 aliceQtyBefore = engine.positions(ALICE, callOptionId).quantity;
            bool settledBefore = engine.isAccountSettled(callOptionId, ALICE);
            uint256 aliceBalanceBefore = vault.balances(ALICE, address(usdc));
            uint256 seriesPaidBefore = engine.seriesPaid(callOptionId);

            MarginEngineLens.DetailedSettlementPreview memory preview =
                lens.previewDetailedSettlement(address(engine), callOptionId, ALICE);

            assertEq(preview.payoffPerContract, 500 * BASE_UNIT);
            assertEq(engine.positions(ALICE, callOptionId).quantity, aliceQtyBefore);
            assertEq(engine.isAccountSettled(callOptionId, ALICE), settledBefore);
            assertEq(vault.balances(ALICE, address(usdc)), aliceBalanceBefore);
            assertEq(engine.seriesPaid(callOptionId), seriesPaidBefore);
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

        function _configureV1Fees() internal {
            feesManagerV1 = new FeesManager(
                OWNER,
                2, // maker notional
                4, // maker premium cap
                5, // taker notional
                6, // taker premium cap
                100 // fee cap
            );

            vm.startPrank(OWNER);
            engine.setFeesManager(address(feesManagerV1));
            engine.setFeeRecipient(DAVE);
            vm.stopPrank();
        }

        function _configureV2Fees(bool enable) internal {
            feesManagerV2 = new FeesManagerV2(OWNER, DAVE);

            vm.startPrank(OWNER);
            feesManagerV2.setFeeConsumer(address(engine), true);
            feesManagerV2.setRebateFundingAccount(CAROL);
            engine.setFeesManagerV2(address(feesManagerV2));
            if (enable) {
                engine.setUseFeesManagerV2(true);
            }
            vm.stopPrank();
        }

        function _claimV2Tier(address account, uint8 tier) internal {
            uint64 validFrom = uint64(block.timestamp);
            uint64 validUntil = uint64(block.timestamp + 1 days);
            bytes32 root = feesManagerV2.hashTierLeaf(
                account, tier, V2_VOLUME_28D, V2_VOLUME_SHARE_PPM, V2_STAKED_DEOPT, validFrom, validUntil
            );

            vm.prank(OWNER);
            feesManagerV2.setMerkleRoot(root, validFrom, validUntil);

            vm.prank(account);
            feesManagerV2.claimTier(
                account,
                tier,
                V2_VOLUME_28D,
                V2_VOLUME_SHARE_PPM,
                V2_STAKED_DEOPT,
                validFrom,
                validUntil,
                new bytes32[](0)
            );
        }

        function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 topic0)
            internal
            pure
            returns (uint256 count)
        {
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                    ++count;
                }
            }
        }

        function _feeChargedV2Topic() internal pure returns (bytes32) {
            return keccak256("FeeChargedV2(address,address,address,address,uint8,uint8,bool,int32,uint256,uint256)");
        }

        function _feeRebatedV2Topic() internal pure returns (bytes32) {
            return keccak256("FeeRebatedV2(address,address,address,address,uint8,uint8,int32,uint256,uint256)");
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

        /*//////////////////////////////////////////////////////////////
                       V2G-O — RFQ flow wiring coverage
        //////////////////////////////////////////////////////////////*/

        /// @dev V2G-O helper mirror of {_trade} for the RFQ-flow entry
        ///      point. Same authorisation flow (matching-engine prank)
        ///      so the call passes the `onlyMatchingEngine` modifier.
        function _tradeRfq(
            address buyer,
            address seller,
            uint256 optionId,
            uint128 quantity,
            uint128 premiumPerContract,
            bool buyerIsMaker
        ) internal {
            vm.prank(MATCHING_ENGINE);
            engine.applyRfqTrade(
                IMarginEngineTrade.Trade({
                    buyer: buyer,
                    seller: seller,
                    optionId: optionId,
                    quantity: quantity,
                    price: premiumPerContract,
                    buyerIsMaker: buyerIsMaker
                })
            );
        }

        /// V2G-O: ORDERBOOK trade through {applyTrade} is bytecode-
        /// equivalent to the pre-V2G-O behaviour. The V2G-O refactor
        /// extracted the body into `_applyTradeWithFlow` parameterised
        /// on flow; ORDERBOOK callers must observe identical token
        /// movements + identical FeeChargedV2 emission count.
        function testV2GO_OrderbookApplyTradeBehavesIdenticallyToPreRefactor() external {
            _configureV2Fees(true);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            vm.recordLogs();
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Same maker/taker amounts as the pre-V2G-O Tier-0 reference
            // (`testFeesManagerV2PositiveOptionFeesTransferAndPositionsUpdate`).
            uint256 makerFeeV2 = 5_000;
            uint256 takerFeeV2 = 25_000;

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT - makerFeeV2);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + makerFeeV2 + takerFeeV2);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 2);
        }

        /// V2G-O: RFQ trade at Tier 0 must equal ORDERBOOK because the
        /// Tier 0 RFQ discount profile is 0% on both legs (V2G-N).
        function testV2GO_RfqTier0EqualsOrderbookFromMarginEnginePerspective() external {
            _configureV2Fees(true);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            vm.recordLogs();
            _tradeRfq(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT, true);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            uint256 makerFeeV2 = 5_000;
            uint256 takerFeeV2 = 25_000;

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT - makerFeeV2);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + makerFeeV2 + takerFeeV2);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 2);
        }

        /// V2G-O: the FeeChargedV2 events emitted by an RFQ trade carry
        /// the RFQ flowKind in their data payload. Pins the
        /// `flowKind=1` invariant that the V2G-N backend decoder reads.
        function testV2GO_RfqTradeEmitsFeeChargedV2WithFlowKindOne() external {
            _configureV2Fees(true);

            vm.recordLogs();
            _tradeRfq(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT, true);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            bytes32 chargedTopic = _feeChargedV2Topic();
            uint256 rfqLegs;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(feesManagerV2) || logs[i].topics.length == 0) continue;
                if (logs[i].topics[0] != chargedTopic) continue;
                // FeeChargedV2 data layout (non-indexed):
                // (address settlementAsset, uint8 productKind, uint8 flowKind, bool isMaker,
                //  int32 feePpm, uint256 basisAmount, uint256 feeAmount).
                (, uint8 productKindRaw, uint8 flowKindRaw,,,,) =
                    abi.decode(logs[i].data, (address, uint8, uint8, bool, int32, uint256, uint256));
                assertEq(productKindRaw, uint8(IFeesManagerV2.ProductKind.OPTION), "productKind=OPTION");
                assertEq(flowKindRaw, uint8(IFeesManagerV2.FlowKind.RFQ), "flowKind=RFQ");
                ++rfqLegs;
            }
            assertEq(rfqLegs, 2, "both legs emit FeeChargedV2 with flowKind=RFQ");
        }

        /// V2G-O: Tier 4 RFQ maker rebate stays at the canonical -50 ppm
        /// (rebateAmount = floor(premium * 50 / 1e6)) — the V2G-N
        /// Design-Option-A negative-ppm preservation invariant carried
        /// through the new applyRfqTrade entry.
        function testV2GO_RfqTier4MakerRebatePreservedThroughMarginEngine() external {
            _configureV2Fees(true);
            _claimV2Tier(ALICE, 4);

            vm.prank(OWNER);
            feesManagerV2.fundRebateBudget(address(usdc), 10_000);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 carolBefore = vault.balances(CAROL, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            vm.recordLogs();
            _tradeRfq(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT, true);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // Maker rebate (Tier 4 maker): -50 ppm, floor(premium * 50 / 1e6) =
            // floor(100_000_000 * 50 / 1e6) = 5_000. Unchanged from ORDERBOOK.
            uint256 makerRebate = 5_000;
            // Taker (Tier 0 default) RFQ has 0% discount → 250 ppm:
            // ceil(100_000_000 * 250 / 1e6) = 25_000. Unchanged from ORDERBOOK
            // since Tier 0 has zero RFQ taker discount.
            uint256 takerFeeV2 = 25_000;

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT + makerRebate);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2);
            assertEq(vault.balances(CAROL, address(usdc)), carolBefore - makerRebate);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + takerFeeV2);
            assertEq(feesManagerV2.rebateBudget(address(usdc)), 10_000 - makerRebate);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeRebatedV2Topic()), 1);
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 1);
        }

        /// V2G-O: a Tier 2 RFQ taker (both maker + taker on Tier 2) bills
        /// the V2G-N canonical 94 ppm taker fee (25% RFQ discount on
        /// 125 ppm) instead of the ORDERBOOK 125 ppm. Exercises a
        /// non-zero RFQ discount on the taker leg.
        function testV2GO_RfqTier2TakerLegPicksUpDiscountedFee() external {
            _configureV2Fees(true);
            _claimV2Tier(ALICE, 2);
            _claimV2Tier(BOB, 2);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(DAVE, address(usdc));

            // Tier 2 maker rebate is -10 ppm. Fund enough to cover it.
            vm.prank(OWNER);
            feesManagerV2.fundRebateBudget(address(usdc), 10_000);
            uint256 carolBefore = vault.balances(CAROL, address(usdc));

            // RFQ trade — ALICE = buyer = maker (rebate leg). BOB =
            // seller = taker (Tier 2 RFQ discount 25% applied to 125
            // ppm => 94 ppm).
            _tradeRfq(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT, true);

            uint256 makerRebate = 1_000; // floor(100_000_000 * 10 / 1e6)
            uint256 takerFeeV2Discounted = 9_400; // ceil(100_000_000 * 94 / 1e6)

            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT + makerRebate);
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2Discounted);
            assertEq(vault.balances(CAROL, address(usdc)), carolBefore - makerRebate);
            assertEq(vault.balances(DAVE, address(usdc)), recipientBefore + takerFeeV2Discounted);
        }

        /// V2G-O: the RFQ entry point is gated by the same
        /// `onlyMatchingEngine` modifier as the ORDERBOOK path.
        function testV2GO_RfqApplyTradeRequiresAuthorizedMatchingEngine() external {
            _configureV2Fees(true);

            vm.expectRevert(MarginEngineTypes.NotAuthorized.selector);
            // Not pranked as MATCHING_ENGINE.
            engine.applyRfqTrade(
                IMarginEngineTrade.Trade({
                    buyer: ALICE,
                    seller: BOB,
                    optionId: callOptionId,
                    quantity: 1,
                    price: PREMIUM_PER_CONTRACT,
                    buyerIsMaker: true
                })
            );
        }
    }
