// SPDX-License-Identifier: MIT
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
import {ICollateralSeizer} from "../../../src/liquidation/ICollateralSeizer.sol";

contract MockERC20Decimals is ERC20 {
    uint8 private immutable _DECIMALS_VALUE;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS_VALUE = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS_VALUE;
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
    address public immutable BASE_COLLATERAL_TOKEN;
    uint8 public immutable BASE_DECIMALS;

    mapping(address => AccountRisk) internal risks;

    constructor(address baseCollateralToken_, uint8 baseDecimals_) {
        BASE_COLLATERAL_TOKEN = baseCollateralToken_;
        BASE_DECIMALS = baseDecimals_;
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

    function baseCollateralToken() external view returns (address) {
        return BASE_COLLATERAL_TOKEN;
    }

    function baseDecimals() external view returns (uint8) {
        return BASE_DECIMALS;
    }
}

contract MockCollateralSeizer is ICollateralSeizer {
    struct Preview {
        uint256 valueBaseFloor;
        uint256 effectiveBaseFloor;
        bool ok;
    }

    address[] internal _tokensOut;
    uint256[] internal _amountsOut;
    uint256 internal _baseCovered;
    mapping(bytes32 => Preview) internal _previews;

    function setPlan(address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered) external {
        delete _tokensOut;
        delete _amountsOut;

        for (uint256 i = 0; i < tokensOut.length; i++) {
            _tokensOut.push(tokensOut[i]);
            _amountsOut.push(amountsOut[i]);
        }

        _baseCovered = baseCovered;
    }

    function setPreview(address token, uint256 amountToken, uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok)
        external
    {
        _previews[keccak256(abi.encode(token, amountToken))] = Preview({
            valueBaseFloor: valueBaseFloor,
            effectiveBaseFloor: effectiveBaseFloor,
            ok: ok
        });
    }

    function computeSeizurePlan(address, uint256)
        external
        view
        returns (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered)
    {
        tokensOut = new address[](_tokensOut.length);
        amountsOut = new uint256[](_amountsOut.length);

        for (uint256 i = 0; i < _tokensOut.length; i++) {
            tokensOut[i] = _tokensOut[i];
            amountsOut[i] = _amountsOut[i];
        }

        baseCovered = _baseCovered;
    }

    function tokenDiscountBps(address) external pure returns (uint256 discountBps) {
        return 10_000;
    }

    function previewEffectiveBaseValue(address token, uint256 amountToken)
        external
        view
        returns (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok)
    {
        Preview memory preview = _previews[keccak256(abi.encode(token, amountToken))];
        return (preview.valueBaseFloor, preview.effectiveBaseFloor, preview.ok);
    }
}

contract MockInsuranceFund {
    CollateralVault public immutable VAULT;

    constructor(address vault_) {
        VAULT = CollateralVault(vault_);
    }

    function depositToVault(address token, uint256 amount) external {
        ERC20(token).approve(address(VAULT), amount);
        VAULT.deposit(token, amount);
    }

    function coverVaultShortfall(address token, address toAccount, uint256 requestedAmount)
        external
        returns (uint256 paidAmount)
    {
        uint256 available = VAULT.balances(address(this), token);
        paidAmount = requestedAmount <= available ? requestedAmount : available;

        if (paidAmount != 0) {
            VAULT.transferBetweenAccounts(token, address(this), toAccount, paidAmount);
        }
    }
}

contract PerpEngineLiquidationTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;
    int256 internal constant LIQUIDATABLE_EQUITY = 90 * 1e6;
    uint256 internal constant LIQUIDATABLE_MM = 100 * 1e6;
    int256 internal constant IMPROVED_EQUITY = 100 * 1e6;
    uint256 internal constant IMPROVED_MM = 90 * 1e6;
    int256 internal constant NOT_IMPROVED_EQUITY = 90 * 1e6;
    uint256 internal constant NOT_IMPROVED_MM = 100 * 1e6;

    uint128 internal constant ONE = 1e8;
    uint128 internal constant TWO = 2e8;
    uint128 internal constant FOUR = 4e8;

    uint128 internal constant ENTRY_PRICE = 2_000 * 1e8;
    uint256 internal constant MARK_PRICE = 2_000 * 1e8;
    uint256 internal constant LIQ_PRICE_LONG = 1_980 * 1e8;
    uint256 internal constant CLOSED_NOTIONAL_BASE_ONE = 1_980 * 1e6;
    uint256 internal constant PENALTY_BASE_ONE = 99 * 1e6;
    uint256 internal constant REALIZED_TRANSFER_BASE_ONE = 40 * 1e6;
    uint256 internal constant PENALTY_BASE_TWO = 198 * 1e6;
    uint256 internal constant REALIZED_TRANSFER_BASE_TWO = 80 * 1e6;
    uint256 internal constant SEIZER_COVER_BASE = 30 * 1e6;
    uint256 internal constant INSURANCE_COVER_BASE = 69 * 1e6;
    uint256 internal constant RESIDUAL_BAD_DEBT_BASE = 29 * 1e6;
    bytes32 internal constant ETH_PERP_SYMBOL = 0x4554482d50455250000000000000000000000000000000000000000000000000;

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
    MockCollateralSeizer internal seizer;
    MockInsuranceFund internal insuranceFund;

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
        seizer = new MockCollateralSeizer();
        insuranceFund = new MockInsuranceFund(address(vault));
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(oracle));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setCollateralToken(address(weth), true, 18, 10_000);
        vault.setAuthorizedEngine(address(engine), true);
        vault.setAuthorizedEngine(address(insuranceFund), true);

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
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0
            })
        );

        engine.setMatchingEngine(MATCHING_ENGINE);
        engine.setRiskModule(address(riskModule));
        engine.setCollateralSeizer(address(seizer));
        engine.setInsuranceFund(address(insuranceFund));
        vm.stopPrank();

        oracle.setPrice(address(weth), address(usdc), MARK_PRICE, block.timestamp, true);

        riskModule.setAccountRisk(ALICE, HEALTHY_EQUITY, 0, 0);
        riskModule.setAccountRisk(BOB, HEALTHY_EQUITY, 0, 0);
        riskModule.setAccountRisk(CAROL, HEALTHY_EQUITY, 0, 0);
    }

    function testHealthyAccountCannotBeLiquidated() external {
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);

        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSignature("NotLiquidatable()"));
        engine.liquidate(ALICE, marketId, ONE);
    }

    function testLiquidatableAccountCanBePartiallyLiquidated() external {
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingLiquidationRisk(ALICE);

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, ONE);

        PerpEngineTypes.Position memory traderPos = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory liquidatorPos = engine.positions(CAROL, marketId);

        assertEq(traderPos.size1e8, int256(uint256(ONE)));
        assertEq(liquidatorPos.size1e8, int256(uint256(ONE)));
        assertEq(engine.getResidualBadDebt(ALICE), 0);
    }

    function testLiquidationRespectsCloseFactor() external {
        _depositUsdc(ALICE, 2_000 * BASE_UNIT);
        _openLong(ALICE, BOB, FOUR);
        _mockImprovingLiquidationRisk(ALICE);

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, FOUR);

        PerpEngineTypes.Position memory traderPos = engine.positions(ALICE, marketId);
        PerpEngineTypes.Position memory liquidatorPos = engine.positions(CAROL, marketId);

        assertEq(traderPos.size1e8, int256(uint256(TWO)));
        assertEq(liquidatorPos.size1e8, int256(uint256(TWO)));
    }

    function testLiquidationTransfersCreditsPenaltyCorrectlyWhenCollateralIsSufficient() external {
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingLiquidationRisk(ALICE);

        vm.prank(OWNER);
        engine.clearCollateralSeizer();

        uint256 traderBefore = vault.balances(ALICE, address(usdc));
        uint256 liquidatorBefore = vault.balances(CAROL, address(usdc));

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, ONE);

        assertEq(vault.balances(ALICE, address(usdc)), traderBefore - REALIZED_TRANSFER_BASE_ONE - PENALTY_BASE_ONE);
        assertEq(
            vault.balances(CAROL, address(usdc)), liquidatorBefore + REALIZED_TRANSFER_BASE_ONE + PENALTY_BASE_ONE
        );
    }

    function testLiquidationUsesCollateralSeizerPlanWhenConfigured() external {
        _depositUsdc(ALICE, REALIZED_TRANSFER_BASE_ONE);
        _depositWeth(ALICE, 1 ether);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingLiquidationRisk(ALICE);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(weth);
        amounts[0] = 1 ether;

        seizer.setPlan(tokens, amounts, PENALTY_BASE_ONE);
        seizer.setPreview(address(weth), 1 ether, PENALTY_BASE_ONE, PENALTY_BASE_ONE, true);

        vm.expectCall(
            address(seizer), abi.encodeWithSelector(ICollateralSeizer.computeSeizurePlan.selector, ALICE, PENALTY_BASE_ONE)
        );

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, ONE);

        assertEq(vault.balances(ALICE, address(weth)), 0);
        assertEq(vault.balances(CAROL, address(weth)), 1 ether);
    }

    function testLiquidationUsesInsuranceFundWhenSeizedCollateralIsInsufficient() external {
        _depositUsdc(ALICE, REALIZED_TRANSFER_BASE_ONE);
        _depositWeth(ALICE, 1 ether);
        _fundInsurance(INSURANCE_COVER_BASE);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingLiquidationRisk(ALICE);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(weth);
        amounts[0] = 1 ether;

        seizer.setPlan(tokens, amounts, SEIZER_COVER_BASE);
        seizer.setPreview(address(weth), 1 ether, SEIZER_COVER_BASE, SEIZER_COVER_BASE, true);

        uint256 insuranceBefore = vault.balances(address(insuranceFund), address(usdc));
        uint256 liquidatorBefore = vault.balances(CAROL, address(usdc));

        vm.expectCall(
            address(insuranceFund),
            abi.encodeWithSignature("coverVaultShortfall(address,address,uint256)", address(usdc), CAROL, INSURANCE_COVER_BASE)
        );

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, ONE);

        assertEq(vault.balances(address(insuranceFund), address(usdc)), insuranceBefore - INSURANCE_COVER_BASE);
        assertEq(
            vault.balances(CAROL, address(usdc)),
            liquidatorBefore + REALIZED_TRANSFER_BASE_ONE + INSURANCE_COVER_BASE
        );
        assertEq(vault.balances(CAROL, address(weth)), 1 ether);
        assertEq(engine.getResidualBadDebt(ALICE), 0);
    }

    function testLiquidationRecordsResidualBadDebtWhenCollateralAndInsuranceAreBothInsufficient() external {
        _depositUsdc(ALICE, REALIZED_TRANSFER_BASE_ONE);
        _depositWeth(ALICE, 1 ether);
        _fundInsurance(40 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);
        _mockImprovingLiquidationRisk(ALICE);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(weth);
        amounts[0] = 1 ether;

        seizer.setPlan(tokens, amounts, SEIZER_COVER_BASE);
        seizer.setPreview(address(weth), 1 ether, SEIZER_COVER_BASE, SEIZER_COVER_BASE, true);

        vm.prank(CAROL);
        engine.liquidate(ALICE, marketId, ONE);

        assertEq(engine.getResidualBadDebt(ALICE), RESIDUAL_BAD_DEBT_BASE);
    }

    function testLiquidationMustImproveSolvencyOrRevert() external {
        _depositUsdc(ALICE, 1_000 * BASE_UNIT);
        _openLong(ALICE, BOB, TWO);
        _mockNonImprovingLiquidationRisk(ALICE);

        PerpEngineTypes.Position memory traderBefore = engine.positions(ALICE, marketId);
        uint256 traderUsdcBefore = vault.balances(ALICE, address(usdc));
        uint256 liquidatorUsdcBefore = vault.balances(CAROL, address(usdc));

        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSignature("LiquidationNotImproving()"));
        engine.liquidate(ALICE, marketId, ONE);

        PerpEngineTypes.Position memory traderAfter = engine.positions(ALICE, marketId);
        assertEq(traderAfter.size1e8, traderBefore.size1e8);
        assertEq(traderAfter.openNotional1e8, traderBefore.openNotional1e8);
        assertEq(vault.balances(ALICE, address(usdc)), traderUsdcBefore);
        assertEq(vault.balances(CAROL, address(usdc)), liquidatorUsdcBefore);
        assertEq(engine.getResidualBadDebt(ALICE), 0);
    }

    function _openLong(address trader, address counterparty, uint128 size1e8) internal {
        vm.prank(MATCHING_ENGINE);
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: trader,
                seller: counterparty,
                marketId: marketId,
                sizeDelta1e8: size1e8,
                executionPrice1e8: ENTRY_PRICE,
                buyerIsMaker: false
            })
        );
    }

    function _depositUsdc(address user, uint256 amount) internal {
        usdc.mint(user, amount);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function _depositWeth(address user, uint256 amount) internal {
        weth.mint(user, amount);

        vm.startPrank(user);
        weth.approve(address(vault), amount);
        vault.deposit(address(weth), amount);
        vm.stopPrank();
    }

    function _fundInsurance(uint256 amount) internal {
        usdc.mint(address(insuranceFund), amount);
        insuranceFund.depositToVault(address(usdc), amount);
    }

    function _mockImprovingLiquidationRisk(address trader) internal {
        bytes memory callData = abi.encodeWithSelector(IPerpRiskModule.computeAccountRisk.selector, trader);
        bytes[] memory returnsData = new bytes[](3);

        returnsData[0] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        returnsData[1] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        returnsData[2] = abi.encode(IPerpRiskModule.AccountRisk(IMPROVED_EQUITY, IMPROVED_MM, 0));

        vm.mockCalls(address(riskModule), callData, returnsData);
    }

    function _mockNonImprovingLiquidationRisk(address trader) internal {
        bytes memory callData = abi.encodeWithSelector(IPerpRiskModule.computeAccountRisk.selector, trader);
        bytes[] memory returnsData = new bytes[](3);

        returnsData[0] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        returnsData[1] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        returnsData[2] = abi.encode(IPerpRiskModule.AccountRisk(NOT_IMPROVED_EQUITY, NOT_IMPROVED_MM, 0));

        vm.mockCalls(address(riskModule), callData, returnsData);
    }
}
