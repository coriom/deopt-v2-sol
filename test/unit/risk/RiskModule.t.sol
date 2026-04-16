// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ProtocolConstants} from "../../../src/ProtocolConstants.sol";
import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {RiskModule} from "../../../src/risk/RiskModule.sol";
import {IRiskModule} from "../../../src/risk/IRiskModule.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IMarginEngineState} from "../../../src/risk/IMarginEngineState.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";

contract MockERC20Decimals is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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
        prices[keccak256(abi.encode(baseAsset, quoteAsset))] = PriceData({
            price: price,
            updatedAt: updatedAt,
            ok: ok
        });
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

contract MockMarginEngineState is IMarginEngineState {
    mapping(address => mapping(uint256 => Position)) internal _positions;
    mapping(address => uint256[]) internal _seriesByTrader;
    mapping(address => mapping(uint256 => bool)) internal _isSeriesTracked;

    function setPosition(address trader, uint256 optionId, int128 quantity) external {
        _positions[trader][optionId] = Position({quantity: quantity});

        if (quantity != 0 && !_isSeriesTracked[trader][optionId]) {
            _isSeriesTracked[trader][optionId] = true;
            _seriesByTrader[trader].push(optionId);
        }
    }

    function totalShortContracts(address trader) external view returns (uint256 total) {
        uint256[] memory seriesIds = _seriesByTrader[trader];
        for (uint256 i = 0; i < seriesIds.length; i++) {
            int128 q = _positions[trader][seriesIds[i]].quantity;
            if (q < 0) {
                total += SafeCast.toUint256(-int256(q));
            }
        }
    }

    function positions(address trader, uint256 optionId) external view returns (Position memory) {
        return _positions[trader][optionId];
    }

    function getTraderSeries(address trader) external view returns (uint256[] memory) {
        uint256[] memory tracked = _seriesByTrader[trader];
        uint256 len = tracked.length;
        uint256 active;

        for (uint256 i = 0; i < len; i++) {
            if (_positions[trader][tracked[i]].quantity != 0) active++;
        }

        uint256[] memory seriesIds = new uint256[](active);
        uint256 cursor;
        for (uint256 i = 0; i < len; i++) {
            uint256 optionId = tracked[i];
            if (_positions[trader][optionId].quantity != 0) {
                seriesIds[cursor] = optionId;
                cursor++;
            }
        }

        return seriesIds;
    }

    function getTraderSeriesLength(address trader) external view returns (uint256) {
        return this.getTraderSeries(trader).length;
    }

    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory slice)
    {
        uint256[] memory seriesIds = this.getTraderSeries(trader);
        uint256 len = seriesIds.length;

        if (start >= len || start >= end) return new uint256[](0);
        if (end > len) end = len;

        slice = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            slice[i - start] = seriesIds[i];
        }
    }

    function optionRegistry() external pure returns (address) {
        return address(0);
    }

    function collateralVault() external pure returns (address) {
        return address(0);
    }

    function oracle() external pure returns (address) {
        return address(0);
    }

    function riskModule() external pure returns (address) {
        return address(0);
    }

    function getPositionQuantity(address trader, uint256 optionId) external view returns (int128) {
        return _positions[trader][optionId].quantity;
    }

    function isOpenSeries(address trader, uint256 optionId) external view returns (bool) {
        return _positions[trader][optionId].quantity != 0;
    }
}

contract RiskModuleTest is Test {
    uint256 internal constant PRICE_SCALE = ProtocolConstants.PRICE_SCALE;
    uint256 internal constant BPS = ProtocolConstants.BPS;

    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xB0B);
    address internal constant BOB = address(0xCAFE);
    address internal constant CAROL = address(0xD00D);
    address internal constant DAVE = address(0xE0E0);
    address internal constant ERIN = address(0xF001);
    address internal constant FRANK = address(0xF002);

    uint256 internal constant USDC_UNIT = 1e6;
    uint256 internal constant WETH_UNIT = 1e18;
    uint256 internal constant WBTC_UNIT = 1e8;

    uint256 internal constant WETH_USDC_PRICE = 2_000 * PRICE_SCALE;
    uint256 internal constant WBTC_USDC_PRICE = 30_000 * PRICE_SCALE;
    uint256 internal constant CALL_STRIKE = 1_900 * PRICE_SCALE;

    uint256 internal constant CALL_INTRINSIC_BASE = 100 * USDC_UNIT;
    uint256 internal constant CALL_MM_BASE = 100 * USDC_UNIT;
    uint256 internal constant CALL_IM_BASE = 120 * USDC_UNIT;

    CollateralVault internal vault;
    OptionProductRegistry internal registry;
    MockMarginEngineState internal marginEngine;
    MockOracle internal oracle;
    RiskModule internal riskModule;

    MockERC20Decimals internal usdc;
    MockERC20Decimals internal weth;
    MockERC20Decimals internal wbtc;

    uint256 internal callOptionId;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new OptionProductRegistry(OWNER);
        marginEngine = new MockMarginEngineState();
        oracle = new MockOracle();
        riskModule = new RiskModule(
            OWNER, address(vault), address(registry), address(marginEngine), address(oracle)
        );

        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        weth = new MockERC20Decimals("Mock WETH", "mWETH", 18);
        wbtc = new MockERC20Decimals("Mock WBTC", "mWBTC", 8);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setCollateralToken(address(weth), true, 18, 10_000);
        vault.setCollateralToken(address(wbtc), true, 8, 10_000);

        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth),
            OptionProductRegistry.UnderlyingConfig({
                oracle: address(0),
                spotShockDownBps: 0,
                spotShockUpBps: 0,
                volShockDownBps: 0,
                volShockUpBps: 0,
                isEnabled: true
            })
        );
        registry.setOptionRiskConfig(
            address(weth),
            OptionProductRegistry.OptionRiskConfig({
                baseMaintenanceMarginPerContract: uint128(10 * USDC_UNIT),
                imFactorBps: uint32(12_000),
                oracleDownMmMultiplierBps: uint32(20_000),
                isConfigured: true
            })
        );

        riskModule.setRiskParams(address(usdc), 10 * USDC_UNIT, 12_000);
        riskModule.setCollateralConfig(address(weth), 8_000, true);
        riskModule.setCollateralConfig(address(wbtc), 8_500, true);
        riskModule.syncCollateralTokensFromVault();
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), WETH_USDC_PRICE, block.timestamp, true);
        oracle.setPrice(address(wbtc), address(usdc), WBTC_USDC_PRICE, block.timestamp, true);

        vm.prank(OWNER);
        callOptionId =
            registry.createSeries(address(weth), address(usdc), uint64(block.timestamp + 7 days), uint64(CALL_STRIKE), true, true);

        _mintAndDeposit(address(usdc), ALICE, 250 * USDC_UNIT);
        _mintAndDeposit(address(usdc), BOB, 200 * USDC_UNIT);
        _mintAndDeposit(address(usdc), CAROL, 150 * USDC_UNIT);
        _mintAndDeposit(address(usdc), DAVE, 500 * USDC_UNIT);
        _mintAndDeposit(address(weth), ERIN, 1 * WETH_UNIT);
        _mintAndDeposit(address(usdc), FRANK, 100 * USDC_UNIT);
        _mintAndDeposit(address(weth), FRANK, 1 * WETH_UNIT);
        _mintAndDeposit(address(wbtc), FRANK, WBTC_UNIT / 10);

        marginEngine.setPosition(ALICE, callOptionId, -1);
        marginEngine.setPosition(BOB, callOptionId, -1);
        marginEngine.setPosition(CAROL, callOptionId, -1);
    }

    function testComputeAccountRiskReturnsConsistentEquityAndMarginValues() external view {
        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(ALICE);
        IRiskModule.AccountRiskBreakdown memory breakdown = riskModule.computeAccountRiskBreakdown(ALICE);

        assertEq(uint256(risk.equityBase), 150 * USDC_UNIT);
        assertEq(risk.maintenanceMarginBase, CALL_MM_BASE);
        assertEq(risk.initialMarginBase, CALL_IM_BASE);

        assertEq(uint256(breakdown.equityBase), uint256(risk.equityBase));
        assertEq(breakdown.maintenanceMarginBase, risk.maintenanceMarginBase);
        assertEq(breakdown.initialMarginBase, risk.initialMarginBase);
        assertEq(breakdown.collateral.adjustedCollateralValueBase, 250 * USDC_UNIT);
        assertEq(breakdown.products.optionsMaintenanceMarginBase, CALL_MM_BASE);
        assertEq(breakdown.products.optionsInitialMarginBase, CALL_IM_BASE);
    }

    function testMarginRatioCalculationIsCorrectAboveEqualAndBelowThreshold() external view {
        assertEq(riskModule.computeMarginRatioBps(ALICE), 15_000);
        assertEq(riskModule.computeMarginRatioBps(BOB), BPS);
        assertEq(riskModule.computeMarginRatioBps(CAROL), 5_000);
    }

    function testAccountWithZeroPositionsReturnsZeroMargins() external view {
        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(DAVE);

        assertEq(risk.equityBase, SafeCast.toInt256(500 * USDC_UNIT));
        assertEq(risk.maintenanceMarginBase, 0);
        assertEq(risk.initialMarginBase, 0);
    }

    function testCollateralWeightsCorrectlyAdjustBaseValue() external view {
        IRiskModule.CollateralState memory state = riskModule.computeCollateralState(ERIN);
        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(ERIN);

        assertEq(state.grossCollateralValueBase, 2_000 * USDC_UNIT);
        assertEq(state.adjustedCollateralValueBase, 1_600 * USDC_UNIT);
        assertEq(risk.equityBase, SafeCast.toInt256(1_600 * USDC_UNIT));
    }

    function testMultipleCollateralAggregationIsCorrect() external view {
        IRiskModule.CollateralState memory state = riskModule.computeCollateralState(FRANK);
        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(FRANK);

        assertEq(state.grossCollateralValueBase, 5_100 * USDC_UNIT);
        assertEq(state.adjustedCollateralValueBase, 4_250 * USDC_UNIT);
        assertEq(risk.equityBase, SafeCast.toInt256(4_250 * USDC_UNIT));
    }

    function testFreeCollateralComputationIsConsistentWithEquityMinusInitialMargin() external view {
        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(ALICE);
        int256 freeCollateralBase = riskModule.computeFreeCollateral(ALICE);

        assertEq(freeCollateralBase, risk.equityBase - SafeCast.toInt256(risk.initialMarginBase));
        assertEq(freeCollateralBase, SafeCast.toInt256(30 * USDC_UNIT));
    }

    function testLiquidationConditionTriggersCorrectlyWhenMarginRatioBelowBps() external view {
        uint256 ratioBelow = riskModule.computeMarginRatioBps(CAROL);
        uint256 ratioAtThreshold = riskModule.computeMarginRatioBps(BOB);

        assertLt(ratioBelow, BPS);
        assertEq(ratioAtThreshold, BPS);
        assertTrue(ratioBelow < BPS);
        assertFalse(ratioAtThreshold < BPS);
    }

    function _mintAndDeposit(address token, address user, uint256 amount) internal {
        MockERC20Decimals(token).mint(user, amount);

        vm.startPrank(user);
        ERC20(token).approve(address(vault), amount);
        vault.deposit(token, amount);
        vm.stopPrank();
    }
}
