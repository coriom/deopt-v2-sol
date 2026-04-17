// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";
import {MarginEngine} from "../../../src/margin/MarginEngine.sol";
import {IRiskModule} from "../../../src/risk/IRiskModule.sol";
import {IMarginEngineTrade} from "../../../src/matching/IMarginEngineTrade.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../../../src/perp/PerpEngineTypes.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";

contract InvariantEngineERC20 is ERC20 {
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

contract InvariantEngineOracle is IOracle {
    function getPrice(address, address) external view returns (uint256 price, uint256 updatedAt) {
        return (2_000 * 1e8, block.timestamp);
    }

    function getPriceSafe(address, address) external view returns (uint256 price, uint256 updatedAt, bool ok) {
        return (2_000 * 1e8, block.timestamp, true);
    }
}

contract InvariantMarginRiskModule is IRiskModule {
    address public immutable override baseCollateralToken;
    uint8 public immutable override baseDecimals;
    uint256 public immutable override baseMaintenanceMarginPerContract;
    uint256 public immutable override imFactorBps;

    constructor(address baseToken_, uint8 baseDecimals_, uint256 baseMMPerContract_, uint256 imFactorBps_) {
        baseCollateralToken = baseToken_;
        baseDecimals = baseDecimals_;
        baseMaintenanceMarginPerContract = baseMMPerContract_;
        imFactorBps = imFactorBps_;
    }

    function computeAccountRisk(address) external pure returns (AccountRisk memory risk) {
        risk = AccountRisk({equityBase: 1_000_000_000 * 1e6, maintenanceMarginBase: 0, initialMarginBase: 0});
    }

    function computeFreeCollateral(address) external pure returns (int256 freeCollateralBase) {
        return 1_000_000_000 * 1e6;
    }

    function computeMarginRatioBps(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function computeAccountRiskBreakdown(address) external pure returns (AccountRiskBreakdown memory breakdown) {
        breakdown.equityBase = 1_000_000_000 * 1e6;
        breakdown.collateral = CollateralState({grossCollateralValueBase: 0, adjustedCollateralValueBase: 0});
        breakdown.products = computeProductRiskState(address(0));
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256 amount) {
        return type(uint256).max;
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;
        preview.maxWithdrawable = amount;
        preview.marginRatioBeforeBps = type(uint256).max;
        preview.marginRatioAfterBps = type(uint256).max;
    }

    function computeCollateralState(address) external pure returns (CollateralState memory state) {
        state = CollateralState({grossCollateralValueBase: 0, adjustedCollateralValueBase: 0});
    }

    function computeProductRiskState(address) public pure returns (ProductRiskState memory state) {
        state = ProductRiskState({
            unrealizedPnlBase: 0,
            fundingAccruedBase: 0,
            optionsInitialMarginBase: 0,
            optionsMaintenanceMarginBase: 0,
            perpsInitialMarginBase: 0,
            perpsMaintenanceMarginBase: 0,
            residualBadDebtBase: 0
        });
    }

    function getResidualBadDebt(address) external pure returns (uint256 amountBase) {
        return 0;
    }
}

contract InvariantPerpRiskModule is IPerpRiskModule {
    function computeAccountRisk(address) external pure returns (AccountRisk memory risk) {
        risk = AccountRisk({equityBase: 1_000_000_000 * 1e6, maintenanceMarginBase: 0, initialMarginBase: 0});
    }

    function computeFreeCollateral(address) external pure returns (int256 freeCollateralBase) {
        return 1_000_000_000 * 1e6;
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;
        preview.maxWithdrawable = amount;
        preview.marginRatioBeforeBps = type(uint256).max;
        preview.marginRatioAfterBps = type(uint256).max;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256 amount) {
        return type(uint256).max;
    }
}

contract PositionIndexInvariantHandler is Test {
    uint256 internal constant ACTOR_COUNT = 4;
    uint256 internal constant OPTION_COUNT = 2;
    uint256 internal constant MARKET_COUNT = 2;

    uint128 internal constant MAX_OPTION_QTY = 5;
    uint128 internal constant MAX_OPTION_PREMIUM = 50 * 1e6;
    uint128 internal constant MAX_PERP_SIZE = 5 * 1e8;

    CollateralVault internal immutable vault;
    InvariantEngineERC20 internal immutable usdc;
    MarginEngine internal immutable marginEngine;
    PerpEngine internal immutable perpEngine;
    address internal immutable MATCHING_ENGINE;

    address[] internal actors;
    uint256[] internal optionIds;
    uint256[] internal marketIds;

    constructor(
        CollateralVault vault_,
        InvariantEngineERC20 usdc_,
        MarginEngine marginEngine_,
        PerpEngine perpEngine_,
        address matchingEngine_,
        uint256[] memory optionIds_,
        uint256[] memory marketIds_
    ) {
        vault = vault_;
        usdc = usdc_;
        marginEngine = marginEngine_;
        perpEngine = perpEngine_;
        MATCHING_ENGINE = matchingEngine_;

        actors.push(address(0xA1));
        actors.push(address(0xB2));
        actors.push(address(0xC3));
        actors.push(address(0xD4));

        for (uint256 i = 0; i < optionIds_.length; i++) {
            optionIds.push(optionIds_[i]);
        }

        for (uint256 i = 0; i < marketIds_.length; i++) {
            marketIds.push(marketIds_[i]);
        }
    }

    function optionTrade(uint256 buyerSeed, uint256 sellerSeed, uint256 optionSeed, uint256 qtySeed, uint256 priceSeed)
        external
    {
        address buyer = _actor(buyerSeed);
        address seller = _distinctCounterparty(buyer, sellerSeed);
        uint256 optionId = _optionId(optionSeed);

        uint128 quantity = uint128(bound(qtySeed, 1, MAX_OPTION_QTY));
        uint128 premium = uint128(bound(priceSeed, 1, MAX_OPTION_PREMIUM));

        vm.prank(MATCHING_ENGINE);
        marginEngine.applyTrade(
            IMarginEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                optionId: optionId,
                quantity: quantity,
                price: premium,
                buyerIsMaker: (buyerSeed & 1) == 0
            })
        );
    }

    function optionFlatten(uint256 actorSeed, uint256 optionSeed) external {
        address actor = _actor(actorSeed);
        uint256 optionId = _optionId(optionSeed);
        int128 qty = marginEngine.getPositionQuantity(actor, optionId);
        if (qty == 0) return;

        address counterparty = _nextActor(actor);
        uint128 quantity = uint128(_absInt128(qty));
        uint128 premium = 1 * 1e6;

        IMarginEngineTrade.Trade memory t;
        if (qty > 0) {
            t = IMarginEngineTrade.Trade({
                buyer: counterparty,
                seller: actor,
                optionId: optionId,
                quantity: quantity,
                price: premium,
                buyerIsMaker: true
            });
        } else {
            t = IMarginEngineTrade.Trade({
                buyer: actor,
                seller: counterparty,
                optionId: optionId,
                quantity: quantity,
                price: premium,
                buyerIsMaker: true
            });
        }

        vm.prank(MATCHING_ENGINE);
        marginEngine.applyTrade(t);
    }

    function perpTrade(uint256 buyerSeed, uint256 sellerSeed, uint256 marketSeed, uint256 sizeSeed) external {
        address buyer = _actor(buyerSeed);
        address seller = _distinctCounterparty(buyer, sellerSeed);
        uint256 marketId = _marketId(marketSeed);
        uint128 sizeDelta1e8 = uint128(bound(sizeSeed, 1, MAX_PERP_SIZE));

        vm.prank(MATCHING_ENGINE);
        perpEngine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                marketId: marketId,
                sizeDelta1e8: sizeDelta1e8,
                executionPrice1e8: _tradePrice1e8(marketId),
                buyerIsMaker: (sellerSeed & 1) == 0
            })
        );
    }

    function perpFlatten(uint256 actorSeed, uint256 marketSeed) external {
        address actor = _actor(actorSeed);
        uint256 marketId = _marketId(marketSeed);
        int256 size1e8 = perpEngine.getPositionSize(actor, marketId);
        if (size1e8 == 0) return;

        address counterparty = _nextActor(actor);
        uint128 qty = uint128(_absInt256(size1e8));

        IPerpEngineTrade.Trade memory t;
        if (size1e8 > 0) {
            t = IPerpEngineTrade.Trade({
                buyer: counterparty,
                seller: actor,
                marketId: marketId,
                sizeDelta1e8: qty,
                executionPrice1e8: _tradePrice1e8(marketId),
                buyerIsMaker: true
            });
        } else {
            t = IPerpEngineTrade.Trade({
                buyer: actor,
                seller: counterparty,
                marketId: marketId,
                sizeDelta1e8: qty,
                executionPrice1e8: _tradePrice1e8(marketId),
                buyerIsMaker: true
            });
        }

        vm.prank(MATCHING_ENGINE);
        perpEngine.applyTrade(t);
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function optionIdAt(uint256 index) external view returns (uint256) {
        return optionIds[index];
    }

    function marketIdAt(uint256 index) external view returns (uint256) {
        return marketIds[index];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _nextActor(address actor) internal view returns (address) {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            if (actors[i] == actor) {
                return actors[(i + 1) % ACTOR_COUNT];
            }
        }
        revert("unknown-actor");
    }

    function _distinctCounterparty(address actor, uint256 seed) internal view returns (address) {
        address candidate = _actor(seed);
        if (candidate != actor) return candidate;
        return _nextActor(actor);
    }

    function _optionId(uint256 seed) internal view returns (uint256) {
        return optionIds[seed % OPTION_COUNT];
    }

    function _marketId(uint256 seed) internal view returns (uint256) {
        return marketIds[seed % MARKET_COUNT];
    }

    function _tradePrice1e8(uint256 marketId) internal view returns (uint128) {
        return marketId == marketIds[0] ? uint128(2_000 * 1e8) : uint128(30_000 * 1e8);
    }

    function _absInt128(int128 value) internal pure returns (uint256) {
        int256 widened = int256(value);
        return widened >= 0 ? SafeCast.toUint256(widened) : SafeCast.toUint256(-widened);
    }

    function _absInt256(int256 value) internal pure returns (uint256) {
        return value >= 0 ? SafeCast.toUint256(value) : SafeCast.toUint256(-value);
    }
}

contract PositionIndexInvariantsTest is StdInvariant, Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);

    uint256 internal constant ACTOR_COUNT = 4;
    uint256 internal constant OPTION_COUNT = 2;
    uint256 internal constant MARKET_COUNT = 2;
    uint256 internal constant INITIAL_USDC_BALANCE = 1_000_000_000 * 1e6;
    bytes32 internal constant ETH_PERP_SYMBOL = "ETH-PERP";
    bytes32 internal constant BTC_PERP_SYMBOL = "BTC-PERP";
    address internal constant ACTOR_A = address(0xA1);
    address internal constant ACTOR_B = address(0xB2);
    address internal constant ACTOR_C = address(0xC3);
    address internal constant ACTOR_D = address(0xD4);

    CollateralVault internal vault;
    OptionProductRegistry internal optionRegistry;
    MarginEngine internal marginEngine;
    PerpMarketRegistry internal perpRegistry;
    PerpEngine internal perpEngine;

    InvariantEngineERC20 internal usdc;
    InvariantEngineERC20 internal weth;
    InvariantEngineERC20 internal wbtc;
    InvariantEngineOracle internal oracle;
    InvariantMarginRiskModule internal marginRiskModule;
    InvariantPerpRiskModule internal perpRiskModule;

    PositionIndexInvariantHandler internal handler;

    uint256[] internal optionIds;
    uint256[] internal marketIds;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        optionRegistry = new OptionProductRegistry(OWNER);
        marginEngine = new MarginEngine(OWNER, address(optionRegistry), address(vault), address(new InvariantEngineOracle()));
        perpRegistry = new PerpMarketRegistry(OWNER);
        oracle = new InvariantEngineOracle();
        perpEngine = new PerpEngine(OWNER, address(perpRegistry), address(vault), address(oracle));

        usdc = new InvariantEngineERC20("Mock USDC", "mUSDC", 6);
        weth = new InvariantEngineERC20("Mock WETH", "mWETH", 18);
        wbtc = new InvariantEngineERC20("Mock WBTC", "mWBTC", 8);

        marginRiskModule = new InvariantMarginRiskModule(address(usdc), 6, 10 * 1e6, 12_000);
        perpRiskModule = new InvariantPerpRiskModule();

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(marginEngine), true);
        vault.setAuthorizedEngine(address(perpEngine), true);
        vault.setMarginEngine(address(marginEngine));

        optionRegistry.setSettlementAssetAllowed(address(usdc), true);
        optionRegistry.setUnderlyingConfig(
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
        optionRegistry.setUnderlyingConfig(
            address(wbtc),
            OptionProductRegistry.UnderlyingConfig({
                oracle: address(oracle),
                spotShockDownBps: 2_500,
                spotShockUpBps: 2_500,
                volShockDownBps: 0,
                volShockUpBps: 1_500,
                isEnabled: true
            })
        );
        optionRegistry.setOptionRiskConfig(
            address(weth),
            OptionProductRegistry.OptionRiskConfig({
                baseMaintenanceMarginPerContract: 10 * 1e6,
                imFactorBps: 12_000,
                oracleDownMmMultiplierBps: 20_000,
                isConfigured: true
            })
        );
        optionRegistry.setOptionRiskConfig(
            address(wbtc),
            OptionProductRegistry.OptionRiskConfig({
                baseMaintenanceMarginPerContract: 8 * 1e6,
                imFactorBps: 11_000,
                oracleDownMmMultiplierBps: 20_000,
                isConfigured: true
            })
        );

        optionIds.push(
            optionRegistry.createSeries(address(weth), address(usdc), uint64(block.timestamp + 30 days), 2_000 * 1e8, true, true)
        );
        optionIds.push(
            optionRegistry.createSeries(address(wbtc), address(usdc), uint64(block.timestamp + 45 days), 30_000 * 1e8, false, true)
        );

        marginEngine.setMatchingEngine(MATCHING_ENGINE);
        marginEngine.setRiskModule(address(marginRiskModule));
        marginEngine.setRiskParams(address(usdc), 10 * 1e6, 12_000);

        perpRegistry.setSettlementAssetAllowed(address(usdc), true);
        marketIds.push(
            perpRegistry.createMarket(
                address(weth),
                address(usdc),
                address(0),
                ETH_PERP_SYMBOL,
                PerpMarketRegistry.RiskConfig({
                    initialMarginBps: 1_000,
                    maintenanceMarginBps: 500,
                    liquidationPenaltyBps: 500,
                    maxPositionSize1e8: type(uint128).max,
                    maxOpenInterest1e8: type(uint128).max,
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
                    oracleClampBps: 0
                })
            )
        );
        marketIds.push(
            perpRegistry.createMarket(
                address(wbtc),
                address(usdc),
                address(0),
                BTC_PERP_SYMBOL,
                PerpMarketRegistry.RiskConfig({
                    initialMarginBps: 1_000,
                    maintenanceMarginBps: 500,
                    liquidationPenaltyBps: 400,
                    maxPositionSize1e8: type(uint128).max,
                    maxOpenInterest1e8: type(uint128).max,
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
                    oracleClampBps: 0
                })
            )
        );

        perpEngine.setMatchingEngine(MATCHING_ENGINE);
        perpEngine.setRiskModule(address(perpRiskModule));
        vm.stopPrank();

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            address actor = _bootstrapActor(i);
            usdc.mint(actor, INITIAL_USDC_BALANCE);

            vm.startPrank(actor);
            IERC20(address(usdc)).approve(address(vault), INITIAL_USDC_BALANCE);
            vault.deposit(address(usdc), INITIAL_USDC_BALANCE);
            vm.stopPrank();
        }

        handler =
            new PositionIndexInvariantHandler(vault, usdc, marginEngine, perpEngine, MATCHING_ENGINE, optionIds, marketIds);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.optionTrade.selector;
        selectors[1] = handler.optionFlatten.selector;
        selectors[2] = handler.perpTrade.selector;
        selectors[3] = handler.perpFlatten.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_nonZeroOptionPositionImpliesActiveSeriesIndexPresence() external view {
        for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
            address actor = _actor(actorIndex);
            uint256[] memory active = marginEngine.getTraderSeries(actor);

            for (uint256 optionIndex = 0; optionIndex < OPTION_COUNT; optionIndex++) {
                uint256 optionId = optionIds[optionIndex];
                int128 qty = marginEngine.getPositionQuantity(actor, optionId);
                if (qty != 0) {
                    assertTrue(marginEngine.isOpenSeries(actor, optionId));
                    assertTrue(_contains(active, optionId));
                }
            }
        }
    }

    function invariant_zeroOptionPositionImpliesAbsenceFromActiveSeriesIndex() external view {
        for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
            address actor = _actor(actorIndex);
            uint256[] memory active = marginEngine.getTraderSeries(actor);

            for (uint256 optionIndex = 0; optionIndex < OPTION_COUNT; optionIndex++) {
                uint256 optionId = optionIds[optionIndex];
                if (marginEngine.getPositionQuantity(actor, optionId) == 0) {
                    assertFalse(marginEngine.isOpenSeries(actor, optionId));
                    assertFalse(_contains(active, optionId));
                }
            }
        }
    }

    function invariant_nonZeroPerpPositionImpliesActiveMarketIndexPresence() external view {
        for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
            address actor = _actor(actorIndex);
            uint256[] memory active = perpEngine.getTraderMarkets(actor);

            for (uint256 marketIndex = 0; marketIndex < MARKET_COUNT; marketIndex++) {
                uint256 marketId = marketIds[marketIndex];
                int256 size1e8 = perpEngine.getPositionSize(actor, marketId);
                if (size1e8 != 0) {
                    assertTrue(perpEngine.isOpenMarket(actor, marketId));
                    assertTrue(_contains(active, marketId));
                }
            }
        }
    }

    function invariant_zeroPerpPositionImpliesAbsenceFromActiveMarketIndex() external view {
        for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
            address actor = _actor(actorIndex);
            uint256[] memory active = perpEngine.getTraderMarkets(actor);

            for (uint256 marketIndex = 0; marketIndex < MARKET_COUNT; marketIndex++) {
                uint256 marketId = marketIds[marketIndex];
                if (perpEngine.getPositionSize(actor, marketId) == 0) {
                    assertFalse(perpEngine.isOpenMarket(actor, marketId));
                    assertFalse(_contains(active, marketId));
                }
            }
        }
    }

    function invariant_noDuplicateActiveSeriesOrMarketEntriesCanAppearForTrader() external view {
        for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
            address actor = _actor(actorIndex);

            uint256[] memory activeSeries = marginEngine.getTraderSeries(actor);
            _assertUnique(activeSeries);
            for (uint256 i = 0; i < activeSeries.length; i++) {
                assertTrue(marginEngine.getPositionQuantity(actor, activeSeries[i]) != 0);
            }

            uint256[] memory activeMarkets = perpEngine.getTraderMarkets(actor);
            _assertUnique(activeMarkets);
            for (uint256 i = 0; i < activeMarkets.length; i++) {
                assertTrue(perpEngine.getPositionSize(actor, activeMarkets[i]) != 0);
            }
        }
    }

    function invariant_openInterestRemainsCoherentWithAggregateLivePerpPositionsUnderTestedSequences() external view {
        for (uint256 marketIndex = 0; marketIndex < MARKET_COUNT; marketIndex++) {
            uint256 marketId = marketIds[marketIndex];
            uint256 aggregateLong;
            uint256 aggregateShort;

            for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
                int256 size1e8 = perpEngine.getPositionSize(_actor(actorIndex), marketId);
                if (size1e8 > 0) {
                    aggregateLong += SafeCast.toUint256(size1e8);
                } else if (size1e8 < 0) {
                    aggregateShort += SafeCast.toUint256(-size1e8);
                }
            }

            PerpEngineTypes.MarketState memory state = perpEngine.marketState(marketId);
            assertEq(state.longOpenInterest1e8, aggregateLong);
            assertEq(state.shortOpenInterest1e8, aggregateShort);
        }
    }

    function _actor(uint256 index) internal view returns (address) {
        return handler.actorAt(index);
    }

    function _bootstrapActor(uint256 index) internal pure returns (address) {
        if (index == 0) return ACTOR_A;
        if (index == 1) return ACTOR_B;
        if (index == 2) return ACTOR_C;
        return ACTOR_D;
    }

    function _contains(uint256[] memory values, uint256 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == needle) return true;
        }
        return false;
    }

    function _assertUnique(uint256[] memory values) internal pure {
        for (uint256 i = 0; i < values.length; i++) {
            for (uint256 j = i + 1; j < values.length; j++) {
                assertTrue(values[i] != values[j]);
            }
        }
    }
}
