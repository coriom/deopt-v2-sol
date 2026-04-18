// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";
import {PerpEngineTypes} from "../../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";

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

contract MockPerpRiskModule is IPerpRiskModule {
    mapping(address => AccountRisk) internal risks;

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

contract PerpEngineFuzzTest is Test, PerpEngineTypes {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);

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

        riskModule = new MockPerpRiskModule();
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(oracle));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);

        registry.setSettlementAssetAllowed(address(usdc), true);
        marketId = registry.createMarket(
            address(weth),
            address(usdc),
            address(0),
            bytes32("ETH-PERP"),
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
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0
            })
        );

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), 2_000 * PRICE_SCALE, block.timestamp, true);

        _setHealthyRisk(ALICE);
        _setHealthyRisk(BOB);
        _setHealthyRisk(CAROL);

        _deposit(ALICE, 1_000_000 * BASE_UNIT);
        _deposit(BOB, 1_000_000 * BASE_UNIT);
        _deposit(CAROL, 1_000_000 * BASE_UNIT);
    }

    function testFuzz_randomPositionTransitionsNeverCorruptPositionAccounting(
        uint256 s0,
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 s4,
        uint256 s5
    ) external {
        Position memory expectedAlice;
        Position memory expectedBob;

        uint256[6] memory seeds = [s0, s1, s2, s3, s4, s5];

        for (uint256 i = 0; i < seeds.length; i++) {
            int256 targetAlice = _targetPositionFromSeed(seeds[i], expectedAlice.size1e8);
            uint256 executionPrice1e8 = _priceFromSeed(seeds[i] >> 64);

            if (targetAlice > expectedAlice.size1e8) {
                uint128 tradeSize = uint128(uint256(targetAlice - expectedAlice.size1e8));
                (expectedAlice, expectedBob,,) = _applyTradeRef(expectedAlice, expectedBob, tradeSize, executionPrice1e8);
                _trade(ALICE, BOB, tradeSize, executionPrice1e8);
            } else {
                uint128 tradeSize = uint128(uint256(expectedAlice.size1e8 - targetAlice));
                (expectedBob, expectedAlice,,) = _applyTradeRef(expectedBob, expectedAlice, tradeSize, executionPrice1e8);
                _trade(BOB, ALICE, tradeSize, executionPrice1e8);
            }

            _assertPositionEq(ALICE, expectedAlice);
            _assertPositionEq(BOB, expectedBob);
        }
    }

    function testFuzz_openInterestRemainsCoherentWithLivePositionsAfterTransitionSequences(
        uint256 s0,
        uint256 s1,
        uint256 s2,
        uint256 s3,
        uint256 s4,
        uint256 s5
    ) external {
        Position memory alicePos;
        Position memory bobPos;
        Position memory carolPos;

        uint256[6] memory seeds = [s0, s1, s2, s3, s4, s5];

        for (uint256 i = 0; i < seeds.length; i++) {
            uint256 pair = bound(seeds[i], 0, 2);
            bool firstIsBuyer = ((seeds[i] >> 8) & 1) == 0;
            uint128 tradeSize = uint128(bound(seeds[i] >> 16, 1, 3) * ONE);
            uint256 executionPrice1e8 = _priceFromSeed(seeds[i] >> 32);

            if (pair == 0) {
                if (firstIsBuyer) {
                    (alicePos, bobPos,,) = _applyTradeRef(alicePos, bobPos, tradeSize, executionPrice1e8);
                    _trade(ALICE, BOB, tradeSize, executionPrice1e8);
                } else {
                    (bobPos, alicePos,,) = _applyTradeRef(bobPos, alicePos, tradeSize, executionPrice1e8);
                    _trade(BOB, ALICE, tradeSize, executionPrice1e8);
                }
            } else if (pair == 1) {
                if (firstIsBuyer) {
                    (alicePos, carolPos,,) = _applyTradeRef(alicePos, carolPos, tradeSize, executionPrice1e8);
                    _trade(ALICE, CAROL, tradeSize, executionPrice1e8);
                } else {
                    (carolPos, alicePos,,) = _applyTradeRef(carolPos, alicePos, tradeSize, executionPrice1e8);
                    _trade(CAROL, ALICE, tradeSize, executionPrice1e8);
                }
            } else {
                if (firstIsBuyer) {
                    (bobPos, carolPos,,) = _applyTradeRef(bobPos, carolPos, tradeSize, executionPrice1e8);
                    _trade(BOB, CAROL, tradeSize, executionPrice1e8);
                } else {
                    (carolPos, bobPos,,) = _applyTradeRef(carolPos, bobPos, tradeSize, executionPrice1e8);
                    _trade(CAROL, BOB, tradeSize, executionPrice1e8);
                }
            }

            PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
            assertEq(state.longOpenInterest1e8, _sumLongs(alicePos, bobPos, carolPos));
            assertEq(state.shortOpenInterest1e8, _sumShorts(alicePos, bobPos, carolPos));
        }
    }

    function testFuzz_reducingOrClosingNeverIncreasesAbsoluteExposureUnexpectedly(
        bool startsLong,
        uint256 initialUnitsRaw,
        uint256 reduceUnitsRaw,
        uint256 openPriceRaw,
        uint256 reducePriceRaw
    ) external {
        uint128 initialSize = uint128(bound(initialUnitsRaw, 1, 5) * ONE);
        uint128 reduceSize = uint128(bound(reduceUnitsRaw, 1, initialSize / ONE) * ONE);
        uint256 openPrice1e8 = _priceFromSeed(openPriceRaw);
        uint256 reducePrice1e8 = _priceFromSeed(reducePriceRaw);

        if (startsLong) {
            _trade(ALICE, BOB, initialSize, openPrice1e8);
            int256 oldSize = engine.getPositionSize(ALICE, marketId);
            _trade(BOB, ALICE, reduceSize, reducePrice1e8);
            int256 newSize = engine.getPositionSize(ALICE, marketId);

            assertLe(_absPosition(newSize), _absPosition(oldSize));
            assertEq(_absPosition(newSize), _absPosition(oldSize) - reduceSize);
        } else {
            _trade(BOB, ALICE, initialSize, openPrice1e8);
            int256 oldSize = engine.getPositionSize(ALICE, marketId);
            _trade(ALICE, BOB, reduceSize, reducePrice1e8);
            int256 newSize = engine.getPositionSize(ALICE, marketId);

            assertLe(_absPosition(newSize), _absPosition(oldSize));
            assertEq(_absPosition(newSize), _absPosition(oldSize) - reduceSize);
        }
    }

    function testFuzz_realizedPnlPathsRemainFiniteAndCoherentUnderBoundedInputs(
        bool aliceStartsLong,
        uint256 initialUnitsRaw,
        uint256 secondTradeUnitsRaw,
        uint256 openPriceRaw,
        uint256 secondPriceRaw
    ) external {
        uint128 initialSize = uint128(bound(initialUnitsRaw, 1, 5) * ONE);
        uint128 secondTradeSize = uint128(bound(secondTradeUnitsRaw, 1, (initialSize / ONE) + 3) * ONE);
        uint256 openPrice1e8 = _priceFromSeed(openPriceRaw);
        uint256 secondPrice1e8 = _priceFromSeed(secondPriceRaw);

        Position memory alicePos;
        Position memory bobPos;

        if (aliceStartsLong) {
            (alicePos, bobPos,,) = _applyTradeRef(alicePos, bobPos, initialSize, openPrice1e8);
            _trade(ALICE, BOB, initialSize, openPrice1e8);
        } else {
            (bobPos, alicePos,,) = _applyTradeRef(bobPos, alicePos, initialSize, openPrice1e8);
            _trade(BOB, ALICE, initialSize, openPrice1e8);
        }

        uint256 aliceBefore = vault.balances(ALICE, address(usdc));
        uint256 bobBefore = vault.balances(BOB, address(usdc));

        int256 buyerRealized;
        int256 sellerRealized;
        if (aliceStartsLong) {
            (bobPos, alicePos, buyerRealized, sellerRealized) =
                _applyTradeRef(bobPos, alicePos, secondTradeSize, secondPrice1e8);
            _trade(BOB, ALICE, secondTradeSize, secondPrice1e8);
        } else {
            (alicePos, bobPos, buyerRealized, sellerRealized) =
                _applyTradeRef(alicePos, bobPos, secondTradeSize, secondPrice1e8);
            _trade(ALICE, BOB, secondTradeSize, secondPrice1e8);
        }

        _assertPositionEq(ALICE, alicePos);
        _assertPositionEq(BOB, bobPos);

        uint256 aliceAfter = vault.balances(ALICE, address(usdc));
        uint256 bobAfter = vault.balances(BOB, address(usdc));

        int256 netToBuyer1e8 = buyerRealized - sellerRealized;
        uint256 expectedTransferBase = _value1e8ToBaseNative(_absPosition(netToBuyer1e8));

        if (netToBuyer1e8 == 0) {
            assertEq(aliceAfter, aliceBefore);
            assertEq(bobAfter, bobBefore);
        } else if (aliceStartsLong) {
            if (netToBuyer1e8 > 0) {
                assertEq(bobAfter - bobBefore, expectedTransferBase);
                assertEq(aliceBefore - aliceAfter, expectedTransferBase);
            } else {
                assertEq(aliceAfter - aliceBefore, expectedTransferBase);
                assertEq(bobBefore - bobAfter, expectedTransferBase);
            }
        } else {
            if (netToBuyer1e8 > 0) {
                assertEq(aliceAfter - aliceBefore, expectedTransferBase);
                assertEq(bobBefore - bobAfter, expectedTransferBase);
            } else {
                assertEq(bobAfter - bobBefore, expectedTransferBase);
                assertEq(aliceBefore - aliceAfter, expectedTransferBase);
            }
        }
    }

    function testFuzz_traderWithResidualBadDebtCannotIncreaseExposureUnderTestedSequences(
        bool startsLong,
        uint256 initialUnitsRaw,
        uint256 reduceUnitsRaw,
        uint256 priceRaw,
        uint256 debtRaw
    ) external {
        uint128 initialSize = uint128(bound(initialUnitsRaw, 2, 5) * ONE);
        uint128 reduceSize = uint128(bound(reduceUnitsRaw, 1, (initialSize / ONE) - 1) * ONE);
        uint256 price1e8 = _priceFromSeed(priceRaw);
        uint256 badDebtBase = bound(debtRaw, 1, 50_000 * BASE_UNIT);

        if (startsLong) {
            _trade(ALICE, BOB, initialSize, price1e8);
        } else {
            _trade(BOB, ALICE, initialSize, price1e8);
        }

        vm.prank(OWNER);
        engine.recordResidualBadDebt(ALICE, badDebtBase);

        assertEq(engine.getResidualBadDebt(ALICE), badDebtBase);
        assertFalse(engine.canIncreaseExposure(ALICE));

        uint256 oldAbs = _absPosition(engine.getPositionSize(ALICE, marketId));
        if (startsLong) {
            _trade(BOB, ALICE, reduceSize, price1e8);
            assertEq(_absPosition(engine.getPositionSize(ALICE, marketId)), oldAbs - reduceSize);

            vm.prank(MATCHING_ENGINE);
            vm.expectRevert(abi.encodeWithSignature("BadDebtOutstanding(address,uint256)", ALICE, badDebtBase));
            engine.applyTrade(
                IPerpEngineTrade.Trade({
                    buyer: ALICE,
                    seller: BOB,
                    marketId: marketId,
                    sizeDelta1e8: ONE,
                    executionPrice1e8: uint128(price1e8),
                    buyerIsMaker: false
                })
            );
        } else {
            _trade(ALICE, BOB, reduceSize, price1e8);
            assertEq(_absPosition(engine.getPositionSize(ALICE, marketId)), oldAbs - reduceSize);

            vm.prank(MATCHING_ENGINE);
            vm.expectRevert(abi.encodeWithSignature("BadDebtOutstanding(address,uint256)", ALICE, badDebtBase));
            engine.applyTrade(
                IPerpEngineTrade.Trade({
                    buyer: BOB,
                    seller: ALICE,
                    marketId: marketId,
                    sizeDelta1e8: ONE,
                    executionPrice1e8: uint128(price1e8),
                    buyerIsMaker: false
                })
            );
        }
    }

    function _trade(address buyer, address seller, uint128 sizeDelta1e8, uint256 executionPrice1e8) internal {
        vm.prank(MATCHING_ENGINE);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                marketId: marketId,
                sizeDelta1e8: sizeDelta1e8,
                executionPrice1e8: uint128(executionPrice1e8),
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

    function _setHealthyRisk(address trader) internal {
        riskModule.setAccountRisk(trader, int256(1_000_000 * BASE_UNIT), 0, 0);
    }

    function _targetPositionFromSeed(uint256 seed, int256 currentSize1e8) internal pure returns (int256 targetSize1e8) {
        int256 units = int256(bound(seed, 0, 10)) - 5;
        targetSize1e8 = units * int256(uint256(ONE));

        if (targetSize1e8 == currentSize1e8) {
            if (targetSize1e8 < 5 * int256(uint256(ONE))) {
                return targetSize1e8 + int256(uint256(ONE));
            }
            return targetSize1e8 - int256(uint256(ONE));
        }
    }

    function _priceFromSeed(uint256 seed) internal pure returns (uint256 executionPrice1e8) {
        return bound(seed, 500, 5_000) * PRICE_SCALE;
    }

    function _applyTradeRef(Position memory buyerPos, Position memory sellerPos, uint128 sizeDelta1e8, uint256 price1e8)
        internal
        pure
        returns (Position memory newBuyer, Position memory newSeller, int256 buyerRealized, int256 sellerRealized)
    {
        (newBuyer, buyerRealized) = _computeNextPositionRef(buyerPos, int256(uint256(sizeDelta1e8)), price1e8, 0);
        (newSeller, sellerRealized) = _computeNextPositionRef(sellerPos, -int256(uint256(sizeDelta1e8)), price1e8, 0);
    }

    function _computeNextPositionRef(
        Position memory oldPos,
        int256 deltaSize1e8,
        uint256 executionPrice1e8,
        int256 currentFunding1e18
    ) internal pure returns (Position memory nextPos, int256 realizedPnl1e8) {
        int256 oldSize = oldPos.size1e8;
        int256 oldOpenNotional = oldPos.openNotional1e8;
        int256 newSize = oldSize + deltaSize1e8;

        nextPos.size1e8 = newSize;

        if (oldSize == 0 || _sameSignNonZeroRef(oldSize, deltaSize1e8)) {
            nextPos.openNotional1e8 = oldOpenNotional + _signedNotionalRef(deltaSize1e8, executionPrice1e8);
            nextPos.lastCumulativeFundingRate1e18 =
                oldSize == 0 ? currentFunding1e18 : _carryForwardFundingCheckpointForIncreaseRef(oldPos, newSize, 0);
            return (nextPos, 0);
        }

        uint256 absOld = _absInt256(oldSize);
        uint256 absDelta = _absInt256(deltaSize1e8);
        uint256 closeAbs = absOld < absDelta ? absOld : absDelta;

        int256 closeSizeSigned = oldSize > 0 ? int256(closeAbs) : -int256(closeAbs);
        int256 removedBasis1e8 = (oldOpenNotional * int256(closeAbs)) / int256(absOld);
        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        int256 closedFunding1e8 = _closedFundingPortion1e8Ref(oldPos, closeAbs, currentFunding1e18);

        realizedPnl1e8 = closedMarkValue1e8 - removedBasis1e8 - closedFunding1e8;

        if (newSize == 0) {
            nextPos.openNotional1e8 = 0;
            nextPos.lastCumulativeFundingRate1e18 = 0;
            return (nextPos, realizedPnl1e8);
        }

        if (_sameSignNonZeroRef(oldSize, newSize)) {
            nextPos.openNotional1e8 = oldOpenNotional - removedBasis1e8;
            nextPos.lastCumulativeFundingRate1e18 = oldPos.lastCumulativeFundingRate1e18;
            return (nextPos, realizedPnl1e8);
        }

        nextPos.openNotional1e8 = _signedNotionalRef(newSize, executionPrice1e8);
        nextPos.lastCumulativeFundingRate1e18 = currentFunding1e18;
    }

    function _carryForwardFundingCheckpointForIncreaseRef(
        Position memory oldPos,
        int256 newSize1e8,
        int256 currentFunding1e18
    ) internal pure returns (int256 nextCheckpoint1e18) {
        int256 accruedFunding1e8 = _accruedFundingOnPositionRef(oldPos, currentFunding1e18);
        if (accruedFunding1e8 == 0) return currentFunding1e18;

        int256 deltaRate1e18 = (accruedFunding1e8 * int256(FUNDING_SCALE_1E18)) / newSize1e8;
        nextCheckpoint1e18 = currentFunding1e18 - deltaRate1e18;
    }

    function _accruedFundingOnPositionRef(Position memory oldPos, int256 currentFunding1e18)
        internal
        pure
        returns (int256 funding1e8)
    {
        if (oldPos.size1e8 == 0) return 0;
        return _fundingPayment1e8(oldPos.size1e8, currentFunding1e18, oldPos.lastCumulativeFundingRate1e18);
    }

    function _closedFundingPortion1e8Ref(Position memory oldPos, uint256 closeAbs, int256 currentFunding1e18)
        internal
        pure
        returns (int256 closedFunding1e8)
    {
        if (oldPos.size1e8 == 0 || closeAbs == 0) return 0;

        uint256 absOld = _absInt256(oldPos.size1e8);
        int256 totalAccruedFunding1e8 = _accruedFundingOnPositionRef(oldPos, currentFunding1e18);
        closedFunding1e8 = (totalAccruedFunding1e8 * int256(closeAbs)) / int256(absOld);
    }

    function _sumLongs(Position memory alicePos, Position memory bobPos, Position memory carolPos)
        internal
        pure
        returns (uint256 total)
    {
        total += alicePos.size1e8 > 0 ? uint256(alicePos.size1e8) : 0;
        total += bobPos.size1e8 > 0 ? uint256(bobPos.size1e8) : 0;
        total += carolPos.size1e8 > 0 ? uint256(carolPos.size1e8) : 0;
    }

    function _sumShorts(Position memory alicePos, Position memory bobPos, Position memory carolPos)
        internal
        pure
        returns (uint256 total)
    {
        total += alicePos.size1e8 < 0 ? uint256(-alicePos.size1e8) : 0;
        total += bobPos.size1e8 < 0 ? uint256(-bobPos.size1e8) : 0;
        total += carolPos.size1e8 < 0 ? uint256(-carolPos.size1e8) : 0;
    }

    function _value1e8ToBaseNative(uint256 amount1e8) internal pure returns (uint256 amountBase) {
        amountBase = amount1e8 / 100;
    }

    function _absPosition(int256 size1e8) internal pure returns (uint256) {
        return size1e8 >= 0 ? uint256(size1e8) : uint256(-size1e8);
    }

    function _sameSignNonZeroRef(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _signedNotionalRef(int256 size1e8, uint256 executionPrice1e8) internal pure returns (int256) {
        return _signedMarkValue1e8(size1e8, executionPrice1e8);
    }

    function _assertPositionEq(address trader, Position memory expected) internal view {
        Position memory actual = engine.positions(trader, marketId);
        assertEq(actual.size1e8, expected.size1e8);
        assertEq(actual.openNotional1e8, expected.openNotional1e8);
        assertEq(actual.lastCumulativeFundingRate1e18, expected.lastCumulativeFundingRate1e18);
    }
}
