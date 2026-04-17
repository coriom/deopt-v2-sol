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

contract ScenarioSystemERC20 is ERC20 {
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

contract ScenarioSystemOracle is IOracle {
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

contract ScenarioSystemPerpRiskModule is IPerpRiskModule {
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
        return risks[trader];
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

contract ScenarioSystemCollateralSeizer is ICollateralSeizer {
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

contract ScenarioSystemInsuranceFund {
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

contract BadDebtRepaymentFlowTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;

    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;
    int256 internal constant LIQUIDATABLE_EQUITY = 90 * 1e6;
    uint256 internal constant LIQUIDATABLE_MM = 100 * 1e6;
    int256 internal constant IMPROVED_EQUITY = 100 * 1e6;
    uint256 internal constant IMPROVED_MM = 90 * 1e6;

    uint128 internal constant ONE = 1e8;
    uint128 internal constant HALF = 5e7;
    uint128 internal constant TWO = 2e8;

    uint128 internal constant ENTRY_PRICE = 2_000 * 1e8;
    uint128 internal constant CASHFLOW_PRICE = 2_100 * 1e8;
    uint128 internal constant REOPEN_PRICE = 196_020_000_000;

    uint256 internal constant INITIAL_MARK_PRICE = 2_000 * 1e8;
    uint256 internal constant ADVERSE_MARK_PRICE = 1_980 * 1e8;
    uint256 internal constant REALIZED_TRANSFER_BASE_ONE = 79_600_000;
    uint256 internal constant SEIZER_COVER_BASE = 30 * 1e6;
    uint256 internal constant INSURANCE_COVER_BASE = 40 * 1e6;
    uint256 internal constant RESIDUAL_BAD_DEBT_BASE = 28_010_000;
    uint256 internal constant PARTIAL_REPAY_BASE = 10 * 1e6;
    uint256 internal constant SMALL_PAYER_BALANCE = 7 * 1e6;
    uint256 internal constant REALIZED_CASHFLOW_BASE_HALF = 100 * 1e6;
    uint256 internal constant RECEIVER_CREDIT_AFTER_DEBT = 71_990_000;
    bytes32 internal constant ETH_PERP_SYMBOL = 0x4554482d50455250000000000000000000000000000000000000000000000000;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant TRADER = address(0xA1);
    address internal constant MAKER = address(0xB2);
    address internal constant LIQUIDATOR = address(0xC3);
    address internal constant REPAYER = address(0xD4);

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    ScenarioSystemOracle internal oracle;
    ScenarioSystemPerpRiskModule internal riskModule;
    ScenarioSystemCollateralSeizer internal seizer;
    ScenarioSystemInsuranceFund internal insuranceFund;
    ScenarioSystemERC20 internal usdc;
    ScenarioSystemERC20 internal weth;

    uint256 internal marketId;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new ScenarioSystemOracle();
        usdc = new ScenarioSystemERC20("Mock USDC", "mUSDC", 6);
        weth = new ScenarioSystemERC20("Mock WETH", "mWETH", 18);
        riskModule = new ScenarioSystemPerpRiskModule(address(usdc), 6);
        seizer = new ScenarioSystemCollateralSeizer();
        insuranceFund = new ScenarioSystemInsuranceFund(address(vault));
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

        oracle.setPrice(address(weth), address(usdc), INITIAL_MARK_PRICE, block.timestamp, true);
        _setHealthyRisk(TRADER);
        _setHealthyRisk(MAKER);
        _setHealthyRisk(LIQUIDATOR);
        _setHealthyRisk(REPAYER);

        _depositUsdc(MAKER, 1_000 * BASE_UNIT);
        _depositUsdc(REPAYER, SMALL_PAYER_BALANCE);
    }

    function testAccountAcquiresResidualBadDebtAfterUndercollateralizedLiquidationFlow() external {
        _createResidualBadDebtViaLiquidation();

        (
            uint256 residualBadDebtBase,
            bool hasOpenPositions,
            ,
            bool reduceOnly,
            bool canIncrease
        ) = engine.getPerpAccountStatus(TRADER);

        assertEq(residualBadDebtBase, RESIDUAL_BAD_DEBT_BASE);
        assertTrue(hasOpenPositions);
        assertTrue(reduceOnly);
        assertFalse(canIncrease);
        assertEq(engine.getTotalResidualBadDebt(), RESIDUAL_BAD_DEBT_BASE);
    }

    function testAccountWithResidualBadDebtCannotIncreaseExposure() external {
        _createResidualBadDebtViaLiquidation();

        vm.prank(MATCHING_ENGINE);
        vm.expectRevert(
            abi.encodeWithSelector(PerpEngineTypes.BadDebtOutstanding.selector, TRADER, RESIDUAL_BAD_DEBT_BASE)
        );
        engine.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: TRADER,
                seller: LIQUIDATOR,
                marketId: marketId,
                sizeDelta1e8: HALF,
                executionPrice1e8: REOPEN_PRICE,
                buyerIsMaker: false
            })
        );
    }

    function testAccountWithResidualBadDebtCanStillPerformReduceOnlyTransitions() external {
        _createResidualBadDebtViaLiquidation();

        _trade(MAKER, TRADER, HALF, ENTRY_PRICE);

        PerpEngineTypes.Position memory traderPos = engine.positions(TRADER, marketId);

        assertEq(traderPos.size1e8, int256(uint256(HALF)));
        assertEq(traderPos.openNotional1e8, int256(uint256(HALF) * uint256(ENTRY_PRICE) / PRICE_SCALE));
        assertEq(engine.getResidualBadDebt(TRADER), RESIDUAL_BAD_DEBT_BASE);
        assertTrue(engine.isReduceOnlyByBadDebt(TRADER));
    }

    function testIncomingCashflowIsRoutedDebtFirstBeforeNormalReceiverCredit() external {
        _createResidualBadDebtViaLiquidation();

        uint256 insuranceBefore = vault.balances(address(insuranceFund), address(usdc));
        uint256 traderBefore = vault.balances(TRADER, address(usdc));
        uint256 makerBefore = vault.balances(MAKER, address(usdc));

        _trade(MAKER, TRADER, HALF, CASHFLOW_PRICE);

        assertEq(vault.balances(MAKER, address(usdc)), makerBefore - REALIZED_CASHFLOW_BASE_HALF);
        assertEq(vault.balances(address(insuranceFund), address(usdc)), insuranceBefore + RESIDUAL_BAD_DEBT_BASE);
        assertEq(vault.balances(TRADER, address(usdc)), traderBefore + RECEIVER_CREDIT_AFTER_DEBT);
        assertEq(engine.getResidualBadDebt(TRADER), 0);
        assertFalse(engine.isReduceOnlyByBadDebt(TRADER));
    }

    function testResidualBadDebtDecreasesCorrectlyAfterRepayment() external {
        _createResidualBadDebtViaLiquidation();

        uint256 repayerBefore = vault.balances(MAKER, address(usdc));
        uint256 insuranceBefore = vault.balances(address(insuranceFund), address(usdc));

        vm.prank(OWNER);
        PerpEngineTypes.BadDebtRepayment memory repayment =
            engine.repayResidualBadDebt(MAKER, TRADER, PARTIAL_REPAY_BASE);

        assertEq(repayment.requestedBase, PARTIAL_REPAY_BASE);
        assertEq(repayment.outstandingBase, RESIDUAL_BAD_DEBT_BASE);
        assertEq(repayment.repaidBase, PARTIAL_REPAY_BASE);
        assertEq(repayment.remainingBase, RESIDUAL_BAD_DEBT_BASE - PARTIAL_REPAY_BASE);
        assertEq(engine.getResidualBadDebt(TRADER), RESIDUAL_BAD_DEBT_BASE - PARTIAL_REPAY_BASE);
        assertEq(vault.balances(MAKER, address(usdc)), repayerBefore - PARTIAL_REPAY_BASE);
        assertEq(vault.balances(address(insuranceFund), address(usdc)), insuranceBefore + PARTIAL_REPAY_BASE);
    }

    function testRepaymentCannotExceedOutstandingBadDebt() external {
        _createResidualBadDebtViaLiquidation();

        uint256 repayerBefore = vault.balances(MAKER, address(usdc));
        uint256 insuranceBefore = vault.balances(address(insuranceFund), address(usdc));

        vm.prank(OWNER);
        PerpEngineTypes.BadDebtRepayment memory repayment =
            engine.repayResidualBadDebt(MAKER, TRADER, 100 * BASE_UNIT);

        assertEq(repayment.requestedBase, 100 * BASE_UNIT);
        assertEq(repayment.outstandingBase, RESIDUAL_BAD_DEBT_BASE);
        assertEq(repayment.repaidBase, RESIDUAL_BAD_DEBT_BASE);
        assertEq(repayment.remainingBase, 0);
        assertEq(engine.getResidualBadDebt(TRADER), 0);
        assertEq(vault.balances(MAKER, address(usdc)), repayerBefore - RESIDUAL_BAD_DEBT_BASE);
        assertEq(vault.balances(address(insuranceFund), address(usdc)), insuranceBefore + RESIDUAL_BAD_DEBT_BASE);
    }

    function testRepaymentCannotExceedActualIncomingTransferableAmount() external {
        _createResidualBadDebtViaLiquidation();

        uint256 repayerBefore = vault.balances(REPAYER, address(usdc));
        uint256 insuranceBefore = vault.balances(address(insuranceFund), address(usdc));

        vm.prank(OWNER);
        PerpEngineTypes.BadDebtRepayment memory repayment =
            engine.repayResidualBadDebt(REPAYER, TRADER, RESIDUAL_BAD_DEBT_BASE);

        assertEq(repayment.requestedBase, RESIDUAL_BAD_DEBT_BASE);
        assertEq(repayment.outstandingBase, RESIDUAL_BAD_DEBT_BASE);
        assertEq(repayment.repaidBase, SMALL_PAYER_BALANCE);
        assertEq(repayment.remainingBase, RESIDUAL_BAD_DEBT_BASE - SMALL_PAYER_BALANCE);
        assertEq(engine.getResidualBadDebt(TRADER), RESIDUAL_BAD_DEBT_BASE - SMALL_PAYER_BALANCE);
        assertEq(vault.balances(REPAYER, address(usdc)), repayerBefore - SMALL_PAYER_BALANCE);
        assertEq(vault.balances(address(insuranceFund), address(usdc)), insuranceBefore + SMALL_PAYER_BALANCE);
    }

    function testWhenDebtReachesZeroNormalExposureIncreaseBecomesAllowedAgain() external {
        _createResidualBadDebtViaLiquidation();

        vm.prank(OWNER);
        engine.repayResidualBadDebt(MAKER, TRADER, RESIDUAL_BAD_DEBT_BASE);

        assertEq(engine.getResidualBadDebt(TRADER), 0);
        assertTrue(engine.canIncreaseExposure(TRADER));

        _trade(TRADER, LIQUIDATOR, HALF, REOPEN_PRICE);

        PerpEngineTypes.Position memory traderPos = engine.positions(TRADER, marketId);
        assertEq(traderPos.size1e8, int256(uint256(3 * HALF)));
    }

    function _createResidualBadDebtViaLiquidation() internal {
        _depositUsdc(TRADER, REALIZED_TRANSFER_BASE_ONE);
        _depositWeth(TRADER, 1 ether);
        _fundInsurance(INSURANCE_COVER_BASE);
        _openLong(TRADER, MAKER, TWO);

        oracle.setPrice(address(weth), address(usdc), ADVERSE_MARK_PRICE, block.timestamp, true);
        riskModule.setAccountRisk(TRADER, LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0);
        _mockImprovingLiquidationRisk(TRADER);

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(weth);
        amounts[0] = 1 ether;

        seizer.setPlan(tokens, amounts, SEIZER_COVER_BASE);
        seizer.setPreview(address(weth), 1 ether, SEIZER_COVER_BASE, SEIZER_COVER_BASE, true);

        vm.prank(LIQUIDATOR);
        engine.liquidate(TRADER, marketId, ONE);

        assertEq(engine.getResidualBadDebt(TRADER), RESIDUAL_BAD_DEBT_BASE);
    }

    function _openLong(address trader, address counterparty, uint128 size1e8) internal {
        _trade(trader, counterparty, size1e8, ENTRY_PRICE);
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

    function _setHealthyRisk(address trader) internal {
        riskModule.setAccountRisk(trader, HEALTHY_EQUITY, 0, 0);
    }

    function _mockImprovingLiquidationRisk(address trader) internal {
        bytes memory callData = abi.encodeWithSelector(IPerpRiskModule.computeAccountRisk.selector, trader);
        bytes[] memory returnsData = new bytes[](3);

        returnsData[0] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        returnsData[1] = abi.encode(IPerpRiskModule.AccountRisk(LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0));
        returnsData[2] = abi.encode(IPerpRiskModule.AccountRisk(IMPROVED_EQUITY, IMPROVED_MM, 0));

        vm.mockCalls(address(riskModule), callData, returnsData);
    }
}
