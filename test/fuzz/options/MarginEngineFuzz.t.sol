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

contract FuzzOptionERC20 is ERC20 {
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

contract FuzzOptionOracle is IOracle {
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

contract FuzzMarginRiskModule is IRiskModule {
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
        uint256 ratio = risk.maintenanceMarginBase == 0
            ? type(uint256).max
            : risk.equityBase <= 0 ? 0 : (uint256(risk.equityBase) * 10_000) / risk.maintenanceMarginBase;

        preview.requestedAmount = amount;
        preview.maxWithdrawable = type(uint256).max;
        preview.marginRatioBeforeBps = ratio;
        preview.marginRatioAfterBps = ratio;
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

contract MarginEngineFuzzTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint256 internal constant BASE_MM_PER_CONTRACT = 10 * BASE_UNIT;
    uint256 internal constant IM_FACTOR_BPS = 12_000;
    uint256 internal constant HEALTHY_EQUITY = 1_000_000 * BASE_UNIT;
    uint256 internal constant LIQUIDATABLE_EQUITY = 1;
    uint128 internal constant MAX_TRADE_QTY = 5;
    uint128 internal constant MAX_PREMIUM_PER_CONTRACT = 50 * 1e6;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant DAVE = address(0xD4);

    CollateralVault internal vault;
    OptionProductRegistry internal registry;
    MarginEngine internal engine;
    FuzzOptionOracle internal oracle;
    FuzzMarginRiskModule internal riskModule;
    FuzzOptionERC20 internal usdc;
    FuzzOptionERC20 internal weth;

    address[] internal actors;
    uint256[] internal optionIds;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new OptionProductRegistry(OWNER);
        oracle = new FuzzOptionOracle();
        engine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));

        usdc = new FuzzOptionERC20("Mock USDC", "mUSDC", 6);
        weth = new FuzzOptionERC20("Mock WETH", "mWETH", 18);

        riskModule = new FuzzMarginRiskModule(address(engine), address(usdc), 6, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);

        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);
        actors.push(DAVE);

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

        optionIds.push(
            registry.createSeries(
                address(weth), address(usdc), uint64(block.timestamp + 30 days), uint64(1_900 * PRICE_SCALE), true, true
            )
        );
        optionIds.push(
            registry.createSeries(
                address(weth), address(usdc), uint64(block.timestamp + 45 days), uint64(2_100 * PRICE_SCALE), false, true
            )
        );

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));
        engine.syncRiskParamsFromRiskModule();
        engine.setLiquidationParams(10_050, 500);
        engine.setLiquidationHardenParams(5_000, 0);
        engine.setLiquidationPricingParams(0, 0);
        engine.setLiquidationOracleMaxDelay(600);
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), 2_000 * PRICE_SCALE, block.timestamp, true);

        for (uint256 i = 0; i < actors.length; i++) {
            _setHealthyEquity(actors[i]);
            _deposit(actors[i], 2_000_000 * BASE_UNIT);
        }
    }

    function testFuzz_randomOptionPositionTransitionsNeverCorruptTraderSeriesIndexing(
        uint256 s0,
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 s4,
        uint256 s5,
        uint256 s6,
        uint256 s7
    ) external {
        uint256[8] memory seeds = [s0, s1, s2, s3, s4, s5, s6, s7];

        for (uint256 i = 0; i < seeds.length; i++) {
            _applyBoundedAction(seeds[i]);
            _assertAllTraderSeriesIndexesCoherent();
        }
    }

    function testFuzz_zeroQuantityPositionsAreNeverKeptInActiveSeriesLists(
        uint256 openSeed0,
        uint256 openSeed1,
        uint256 openSeed2,
        uint256 closeSeed0,
        uint256 closeSeed1,
        uint256 closeSeed2
    ) external {
        uint256[3] memory opens = [openSeed0, openSeed1, openSeed2];
        uint256[3] memory closes = [closeSeed0, closeSeed1, closeSeed2];

        for (uint256 i = 0; i < opens.length; i++) {
            _openPositionForActor(opens[i]);
            _assertAllTraderSeriesIndexesCoherent();
        }

        for (uint256 j = 0; j < closes.length; j++) {
            address actor = _actor(closes[j]);
            uint256 optionId = _seriesId(closes[j] >> 8);
            _flattenPosition(actor, optionId);

            assertEq(engine.getPositionQuantity(actor, optionId), 0);
            assertFalse(engine.isOpenSeries(actor, optionId));
            _assertSeriesAbsentFromList(actor, optionId);
            _assertAllTraderSeriesIndexesCoherent();
        }
    }

    function testFuzz_totalShortExposureRemainsCoherentWithLiveShortPositionsUnderTestedSequences(
        uint256 s0,
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 s4,
        uint256 s5,
        uint256 s6,
        uint256 s7
    ) external {
        uint256[8] memory seeds = [s0, s1, s2, s3, s4, s5, s6, s7];

        for (uint256 i = 0; i < seeds.length; i++) {
            _applyBoundedAction(seeds[i]);

            for (uint256 actorIndex = 0; actorIndex < actors.length; actorIndex++) {
                address actor = actors[actorIndex];
                assertEq(engine.totalShortContracts(actor), _expectedTotalShort(actor));
            }
        }
    }

    function testFuzz_reducingOrClosingOptionPositionsNeverIncreasesShortExposureUnexpectedly(
        uint256 openSeed0,
        uint256 openSeed1,
        uint256 openSeed2,
        uint256 reduceSeed0,
        uint256 reduceSeed1,
        uint256 reduceSeed2,
        uint256 reduceSeed3
    ) external {
        _openPositionForActor(openSeed0);
        _openPositionForActor(openSeed1);
        _openPositionForActor(openSeed2);

        uint256[4] memory reduceSeeds = [reduceSeed0, reduceSeed1, reduceSeed2, reduceSeed3];

        for (uint256 i = 0; i < reduceSeeds.length; i++) {
            address actor = _actor(reduceSeeds[i]);
            uint256 optionId = _seriesId(reduceSeeds[i] >> 8);
            int128 beforeQty = engine.getPositionQuantity(actor, optionId);
            uint256 beforeShort = engine.totalShortContracts(actor);

            if (beforeQty == 0) {
                _flattenPosition(actor, optionId);
                assertEq(engine.totalShortContracts(actor), beforeShort);
                continue;
            }

            _reducePosition(actor, optionId, reduceSeeds[i] >> 16);

            uint256 afterShort = engine.totalShortContracts(actor);
            if (beforeQty < 0) {
                assertLe(afterShort, beforeShort);
            } else {
                assertEq(afterShort, beforeShort);
            }

            _assertAllTraderSeriesIndexesCoherent();
        }
    }

    function testFuzz_settlementLifecycleGuardsRemainCoherentUnderBoundedRandomInputs(
        uint256 strikeSeed,
        uint256 premiumSeed,
        uint256 qtySeed,
        uint256 settlementSeed
    ) external {
        uint256 optionId = _createSeries(
            uint64(block.timestamp + bound(strikeSeed, 1 days, 10 days)),
            bound(strikeSeed >> 32, 1_500 * PRICE_SCALE, 2_500 * PRICE_SCALE),
            (strikeSeed & 1) == 0
        );

        uint128 quantity = uint128(bound(qtySeed, 1, MAX_TRADE_QTY));
        uint128 premium = uint128(bound(premiumSeed, 1, MAX_PREMIUM_PER_CONTRACT));
        uint256 settlementPrice = bound(settlementSeed, 1_000 * PRICE_SCALE, 3_000 * PRICE_SCALE);

        _trade(ALICE, BOB, optionId, quantity, premium);

        vm.prank(OWNER);
        registry.setSeriesActive(optionId, false);

        vm.expectRevert(MarginEngineTypes.SeriesNotActiveCloseOnly.selector);
        _tradeExpectRevert(ALICE, CAROL, optionId, quantity, premium);

        _trade(BOB, ALICE, optionId, quantity, premium);

        vm.expectRevert(MarginEngineTypes.NotExpired.selector);
        engine.settleAccount(optionId, ALICE);

        vm.warp(registry.getSeries(optionId).expiry);

        vm.expectRevert(MarginEngineTypes.SettlementNotSet.selector);
        engine.settleAccount(optionId, ALICE);

        vm.prank(OWNER);
        registry.setSettlementPrice(optionId, settlementPrice);

        engine.settleAccount(optionId, ALICE);

        vm.expectRevert(MarginEngineTypes.SettlementAlreadyProcessed.selector);
        engine.settleAccount(optionId, ALICE);

        vm.expectRevert(MarginEngineTypes.SeriesExpired.selector);
        _tradeExpectRevert(CAROL, DAVE, optionId, 1, premium);
    }

    function testFuzz_liquidationSizingRemainsBoundedAndDoesNotCreateImpossiblePositionStates(
        uint256 qtySeed0,
        uint256 qtySeed1,
        uint256 liqSeed0,
        uint256 liqSeed1
    ) external {
        uint128 shortQty0 = uint128(bound(qtySeed0, 1, 3));
        uint128 shortQty1 = uint128(bound(qtySeed1, 1, 3));

        _trade(ALICE, BOB, optionIds[0], shortQty0, 10 * 1e6);
        _trade(ALICE, BOB, optionIds[1], shortQty1, 12 * 1e6);

        riskModule.setEquityBase(BOB, int256(LIQUIDATABLE_EQUITY));
        oracle.setPrice(address(weth), address(usdc), 2_000 * PRICE_SCALE, block.timestamp, true);

        int128 traderBefore0 = engine.getPositionQuantity(BOB, optionIds[0]);
        int128 traderBefore1 = engine.getPositionQuantity(BOB, optionIds[1]);
        uint256 totalShortBefore = engine.totalShortContracts(BOB);
        uint256 maxClose = (totalShortBefore * 5_000) / 10_000;
        if (maxClose == 0) maxClose = 1;

        uint256[] memory ids = new uint256[](2);
        uint128[] memory quantities = new uint128[](2);
        ids[0] = optionIds[0];
        ids[1] = optionIds[1];
        quantities[0] = uint128(bound(liqSeed0, 1, 10));
        quantities[1] = uint128(bound(liqSeed1, 1, 10));

        vm.prank(CAROL);
        engine.liquidate(BOB, ids, quantities);

        int128 traderAfter0 = engine.getPositionQuantity(BOB, optionIds[0]);
        int128 traderAfter1 = engine.getPositionQuantity(BOB, optionIds[1]);
        int128 liquidatorAfter0 = engine.getPositionQuantity(CAROL, optionIds[0]);
        int128 liquidatorAfter1 = engine.getPositionQuantity(CAROL, optionIds[1]);

        assertLe(traderAfter0, 0);
        assertLe(traderAfter1, 0);
        assertLe(liquidatorAfter0, 0);
        assertLe(liquidatorAfter1, 0);

        uint256 closed0 = _absInt128(traderBefore0) - _absInt128(traderAfter0);
        uint256 closed1 = _absInt128(traderBefore1) - _absInt128(traderAfter1);
        uint256 totalClosed = closed0 + closed1;

        assertLe(totalClosed, maxClose);
        assertEq(_absInt128(liquidatorAfter0), closed0);
        assertEq(_absInt128(liquidatorAfter1), closed1);
        assertEq(engine.totalShortContracts(BOB), totalShortBefore - totalClosed);
        assertEq(engine.totalShortContracts(CAROL), totalClosed);
        _assertAllTraderSeriesIndexesCoherent();
    }

    function _applyBoundedAction(uint256 seed) internal {
        uint256 action = seed % 3;
        if (action == 0) {
            _openPositionForActor(seed);
        } else if (action == 1) {
            _reducePosition(_actor(seed), _seriesId(seed >> 8), seed >> 16);
        } else {
            _flattenPosition(_actor(seed), _seriesId(seed >> 8));
        }
    }

    function _openPositionForActor(uint256 seed) internal {
        address actor = _actor(seed);
        address counterparty = _nextActor(actor);
        uint256 optionId = _seriesId(seed >> 8);
        uint128 quantity = uint128(bound(seed >> 16, 1, MAX_TRADE_QTY));
        uint128 premium = uint128(bound(seed >> 32, 1, MAX_PREMIUM_PER_CONTRACT));
        bool actorBuys = ((seed >> 48) & 1) == 0;

        if (actorBuys) {
            _trade(actor, counterparty, optionId, quantity, premium);
        } else {
            _trade(counterparty, actor, optionId, quantity, premium);
        }
    }

    function _reducePosition(address actor, uint256 optionId, uint256 seed) internal {
        int128 qty = engine.getPositionQuantity(actor, optionId);
        if (qty == 0) return;

        uint128 quantity = uint128(bound(seed, 1, _absInt128(qty)));
        address counterparty = _nextActor(actor);
        uint128 premium = uint128(bound(seed >> 16, 1, MAX_PREMIUM_PER_CONTRACT));

        if (qty > 0) {
            _trade(counterparty, actor, optionId, quantity, premium);
        } else {
            _trade(actor, counterparty, optionId, quantity, premium);
        }
    }

    function _flattenPosition(address actor, uint256 optionId) internal {
        int128 qty = engine.getPositionQuantity(actor, optionId);
        if (qty == 0) return;

        address counterparty = _nextActor(actor);
        uint128 quantity = uint128(_absInt128(qty));
        uint128 premium = 1 * 1e6;

        if (qty > 0) {
            _trade(counterparty, actor, optionId, quantity, premium);
        } else {
            _trade(actor, counterparty, optionId, quantity, premium);
        }
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

    function _tradeExpectRevert(
        address buyer,
        address seller,
        uint256 optionId,
        uint128 quantity,
        uint128 premiumPerContract
    ) internal {
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

    function _createSeries(uint64 expiry, uint256 strike, bool isCall) internal returns (uint256 optionId) {
        vm.prank(OWNER);
        optionId = registry.createSeries(address(weth), address(usdc), expiry, uint64(strike), isCall, true);
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

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _nextActor(address actor) internal view returns (address) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (actors[i] == actor) {
                return actors[(i + 1) % actors.length];
            }
        }
        revert("unknown-actor");
    }

    function _seriesId(uint256 seed) internal view returns (uint256) {
        return optionIds[seed % optionIds.length];
    }

    function _expectedTotalShort(address trader) internal view returns (uint256 totalShort) {
        for (uint256 i = 0; i < optionIds.length; i++) {
            int128 qty = engine.getPositionQuantity(trader, optionIds[i]);
            if (qty < 0) totalShort += _absInt128(qty);
        }
    }

    function _assertAllTraderSeriesIndexesCoherent() internal view {
        for (uint256 actorIndex = 0; actorIndex < actors.length; actorIndex++) {
            address trader = actors[actorIndex];
            uint256 expectedOpenCount = 0;
            uint256[] memory series = engine.getTraderSeries(trader);

            for (uint256 i = 0; i < optionIds.length; i++) {
                uint256 optionId = optionIds[i];
                int128 qty = engine.getPositionQuantity(trader, optionId);
                bool shouldBeOpen = qty != 0;

                if (shouldBeOpen) {
                    expectedOpenCount++;
                }

                assertEq(engine.isOpenSeries(trader, optionId), shouldBeOpen);
                assertEq(_countInList(series, optionId), shouldBeOpen ? 1 : 0);
            }

            assertEq(engine.getTraderSeriesLength(trader), expectedOpenCount);
            assertEq(series.length, expectedOpenCount);
        }
    }

    function _assertSeriesAbsentFromList(address trader, uint256 optionId) internal view {
        uint256[] memory series = engine.getTraderSeries(trader);
        assertEq(_countInList(series, optionId), 0);
    }

    function _countInList(uint256[] memory values, uint256 needle) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == needle) count++;
        }
    }

    function _absInt128(int128 value) internal pure returns (uint256) {
        return value >= 0 ? uint256(uint128(value)) : uint256(uint128(-value));
    }
}
