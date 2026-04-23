// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";

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

contract PerpEngineTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);
    address internal constant CAROL = address(0xC3);
    address internal constant GUARDIAN = address(0x1234);

    uint256 internal constant ENTRY_PRICE_1 = 2_000 * PRICE_SCALE;
    uint256 internal constant ENTRY_PRICE_2 = 2_500 * PRICE_SCALE;
    uint256 internal constant BAD_DEBT_BASE = 50 * BASE_UNIT;

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

        oracle.setPrice(address(weth), address(usdc), ENTRY_PRICE_1, block.timestamp, true);

        _setHealthyRisk(ALICE);
        _setHealthyRisk(BOB);
        _setHealthyRisk(CAROL);

        _deposit(ALICE, 100_000 * BASE_UNIT);
        _deposit(BOB, 100_000 * BASE_UNIT);
        _deposit(CAROL, 100_000 * BASE_UNIT);
    }

    function testOpeningLongPositionUpdatesBuyerAndSellerPositionsCorrectly() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        PerpEngineTypes.Position memory alicePos = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory bobPos = engine.positions(BOB, marketId);

        assertEq(alicePos.size1e8, int256(uint256(2 * ONE)));
        assertEq(alicePos.openNotional1e8, int256(4_000 * PRICE_SCALE));
        assertEq(bobPos.size1e8, -int256(uint256(2 * ONE)));
        assertEq(bobPos.openNotional1e8, -int256(4_000 * PRICE_SCALE));
    }

    function testOpeningShortOffsettingSideUpdatesOpenInterestCorrectly() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);
        _trade(BOB, ALICE, 1 * ONE, ENTRY_PRICE_1);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);

        assertEq(state.longOpenInterest1e8, 1 * ONE);
        assertEq(state.shortOpenInterest1e8, 1 * ONE);
    }

    function testIncreasingExistingPositionOnSameSideUpdatesSizeAndOpenNotionalCorrectly() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);
        _trade(ALICE, CAROL, 1 * ONE, ENTRY_PRICE_2);

        PerpEngineTypes.Position memory alicePos = engine.positions(ALICE, marketId);

        assertEq(alicePos.size1e8, int256(uint256(3 * ONE)));
        assertEq(alicePos.openNotional1e8, int256(6_500 * PRICE_SCALE));
    }

    function testLaunchOpenInterestCapBlocksExposureIncreaseAboveCap() external {
        vm.prank(OWNER);
        engine.setLaunchOpenInterestCap(marketId, 2 * ONE);

        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        vm.prank(MATCHING_ENGINE);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpEngineTypes.LaunchOpenInterestCapExceeded.selector,
                marketId,
                3 * ONE,
                2 * ONE
            )
        );
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: ALICE,
                seller: CAROL,
                marketId: marketId,
                sizeDelta1e8: ONE,
                executionPrice1e8: uint128(ENTRY_PRICE_1),
                buyerIsMaker: false
            })
        );

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(state.longOpenInterest1e8, 2 * ONE);
        assertEq(state.shortOpenInterest1e8, 2 * ONE);
        assertEq(engine.positions(CAROL, marketId).size1e8, 0);
    }

    function testLoweredLaunchOpenInterestCapStillAllowsExposureReduction() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        vm.prank(OWNER);
        engine.setLaunchOpenInterestCap(marketId, ONE);

        _trade(BOB, ALICE, ONE, ENTRY_PRICE_1);

        PerpEngineTypes.MarketState memory state = engine.marketState(marketId);
        assertEq(state.longOpenInterest1e8, ONE);
        assertEq(state.shortOpenInterest1e8, ONE);
        assertEq(engine.positions(ALICE, marketId).size1e8, int256(uint256(ONE)));
        assertEq(engine.positions(BOB, marketId).size1e8, -int256(uint256(ONE)));
    }

    function testReducingExistingPositionRealizesPnlCorrectly() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        uint256 aliceBalanceBefore = vault.balances(ALICE, address(usdc));
        uint256 carolBalanceBefore = vault.balances(CAROL, address(usdc));

        _trade(CAROL, ALICE, 1 * ONE, ENTRY_PRICE_2);

        PerpEngineTypes.Position memory alicePos = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory bobPos = engine.positions(BOB, marketId);
        PerpEngineTypes.Position memory carolPos = engine.positions(CAROL, marketId);

        assertEq(alicePos.size1e8, int256(uint256(ONE)));
        assertEq(alicePos.openNotional1e8, int256(2_000 * PRICE_SCALE));
        assertEq(bobPos.size1e8, -int256(uint256(2 * ONE)));
        assertEq(bobPos.openNotional1e8, -int256(4_000 * PRICE_SCALE));
        assertEq(carolPos.size1e8, int256(uint256(ONE)));
        assertEq(carolPos.openNotional1e8, int256(2_500 * PRICE_SCALE));

        assertEq(vault.balances(ALICE, address(usdc)), aliceBalanceBefore + (500 * BASE_UNIT));
        assertEq(vault.balances(CAROL, address(usdc)), carolBalanceBefore - (500 * BASE_UNIT));
    }

    function testFullyClosingPositionResetsSizeAndOpenNotionalToZero() external {
        _trade(ALICE, BOB, 1 * ONE, ENTRY_PRICE_1);
        _trade(BOB, ALICE, 1 * ONE, 2_200 * PRICE_SCALE);

        PerpEngineTypes.Position memory alicePos = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory bobPos = engine.positions(BOB, marketId);

        assertEq(alicePos.size1e8, 0);
        assertEq(alicePos.openNotional1e8, 0);
        assertEq(bobPos.size1e8, 0);
        assertEq(bobPos.openNotional1e8, 0);
    }

    function testFlippingPositionResetsBasisCorrectlyForTheNewSide() external {
        _trade(ALICE, BOB, 1 * ONE, ENTRY_PRICE_1);
        _trade(BOB, ALICE, 2 * ONE, ENTRY_PRICE_2);

        PerpEngineTypes.Position memory alicePos = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory bobPos = engine.positions(BOB, marketId);

        assertEq(alicePos.size1e8, -int256(uint256(ONE)));
        assertEq(alicePos.openNotional1e8, -int256(2_500 * PRICE_SCALE));
        assertEq(bobPos.size1e8, int256(uint256(ONE)));
        assertEq(bobPos.openNotional1e8, int256(2_500 * PRICE_SCALE));
    }

    function testTraderWithResidualBadDebtCannotIncreaseExposure() external {
        vm.prank(OWNER);
        engine.recordResidualBadDebt(ALICE, BAD_DEBT_BASE);

        vm.prank(MATCHING_ENGINE);
        vm.expectRevert(abi.encodeWithSignature("BadDebtOutstanding(address,uint256)", ALICE, BAD_DEBT_BASE));
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: ALICE,
                seller: BOB,
                marketId: marketId,
                sizeDelta1e8: ONE,
                executionPrice1e8: uint128(ENTRY_PRICE_1),
                buyerIsMaker: false
            })
        );
    }

    function testResidualBadDebtLifecycleEmitsUpdateEvents() external {
        vm.expectEmit(true, true, false, true);
        emit PerpEngineTypes.ResidualBadDebtUpdated(OWNER, ALICE, 0, BAD_DEBT_BASE, 0, BAD_DEBT_BASE);
        vm.prank(OWNER);
        engine.recordResidualBadDebt(ALICE, BAD_DEBT_BASE);

        vm.expectEmit(true, true, false, true);
        emit PerpEngineTypes.ResidualBadDebtUpdated(OWNER, ALICE, BAD_DEBT_BASE, 20 * BASE_UNIT, BAD_DEBT_BASE, 20 * BASE_UNIT);
        vm.prank(OWNER);
        engine.reduceResidualBadDebt(ALICE, 30 * BASE_UNIT);

        vm.expectEmit(true, true, false, true);
        emit PerpEngineTypes.ResidualBadDebtUpdated(OWNER, ALICE, 20 * BASE_UNIT, 0, 20 * BASE_UNIT, 0);
        vm.prank(OWNER);
        engine.clearResidualBadDebt(ALICE);
    }

    function testReduceOnlyTransitionIsStillAllowedWhenResidualBadDebtExists() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        vm.prank(OWNER);
        engine.recordResidualBadDebt(ALICE, BAD_DEBT_BASE);

        _trade(BOB, ALICE, 1 * ONE, ENTRY_PRICE_1);

        PerpEngineTypes.Position memory alicePos = engine.positions(ALICE, marketId);

        assertEq(alicePos.size1e8, int256(uint256(ONE)));
        assertEq(alicePos.openNotional1e8, int256(2_000 * PRICE_SCALE));
        assertEq(engine.getResidualBadDebt(ALICE), BAD_DEBT_BASE);
    }

    function testMarketEmergencyCloseOnlyBlocksExposureIncreaseWithoutGlobalTradingPause() external {
        _trade(ALICE, BOB, ONE, ENTRY_PRICE_1);

        vm.expectEmit(true, false, false, true);
        emit PerpEngineTypes.MarketEmergencyCloseOnlySet(marketId, false, true);
        vm.expectEmit(true, true, false, true);
        emit PerpEngineTypes.MarketEmergencyCloseOnlyUpdated(OWNER, marketId, false, true);
        vm.prank(OWNER);
        engine.setMarketEmergencyCloseOnly(marketId, true);

        assertFalse(engine.tradingPaused());
        assertTrue(engine.marketEmergencyCloseOnly(marketId));

        vm.expectRevert(abi.encodeWithSelector(PerpEngineTypes.ReduceOnlyViolation.selector));
        _trade(ALICE, CAROL, ONE, ENTRY_PRICE_1);

        assertEq(engine.positions(ALICE, marketId).size1e8, int256(uint256(ONE)));
        assertEq(engine.positions(CAROL, marketId).size1e8, 0);
    }

    function testGuardianMarketEmergencyCloseOnlyStillAllowsTwoSidedReduction() external {
        vm.prank(OWNER);
        engine.setGuardian(GUARDIAN);

        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        vm.prank(GUARDIAN);
        engine.setMarketEmergencyCloseOnly(marketId, true);

        _trade(BOB, ALICE, ONE, ENTRY_PRICE_1);

        assertEq(engine.positions(ALICE, marketId).size1e8, int256(uint256(ONE)));
        assertEq(engine.positions(BOB, marketId).size1e8, -int256(uint256(ONE)));
    }

    function testRestrictedActivationBlocksExposureIncreaseButStillAllowsReduction() external {
        _trade(ALICE, BOB, 2 * ONE, ENTRY_PRICE_1);

        vm.expectEmit(true, false, false, true);
        emit PerpEngineTypes.MarketActivationStateSet(marketId, 0, 1);
        vm.prank(OWNER);
        engine.setMarketActivationState(marketId, 1);

        vm.expectRevert(abi.encodeWithSelector(PerpEngineTypes.ReduceOnlyViolation.selector));
        _trade(ALICE, CAROL, ONE, ENTRY_PRICE_1);

        _trade(BOB, ALICE, ONE, ENTRY_PRICE_1);

        assertEq(engine.marketActivationState(marketId), 1);
        assertEq(engine.positions(ALICE, marketId).size1e8, int256(uint256(ONE)));
        assertEq(engine.positions(BOB, marketId).size1e8, -int256(uint256(ONE)));
        assertEq(engine.positions(CAROL, marketId).size1e8, 0);
    }

    function testInactiveActivationAllowsOnlyStrictCloseToZero() external {
        _trade(ALICE, BOB, ONE, ENTRY_PRICE_1);

        vm.expectEmit(true, false, false, true);
        emit PerpEngineTypes.MarketActivationStateSet(marketId, 0, 2);
        vm.prank(OWNER);
        engine.setMarketActivationState(marketId, 2);

        vm.expectRevert(abi.encodeWithSelector(PerpEngineTypes.ReduceOnlyViolation.selector));
        _trade(BOB, ALICE, ONE / 2, ENTRY_PRICE_1);

        vm.expectRevert(abi.encodeWithSelector(PerpEngineTypes.ReduceOnlyViolation.selector));
        _trade(ALICE, CAROL, ONE, ENTRY_PRICE_1);

        _trade(BOB, ALICE, ONE, ENTRY_PRICE_1);

        assertEq(engine.marketActivationState(marketId), 2);
        assertEq(engine.positions(ALICE, marketId).size1e8, 0);
        assertEq(engine.positions(BOB, marketId).size1e8, 0);
        assertEq(engine.positions(CAROL, marketId).size1e8, 0);
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
}
