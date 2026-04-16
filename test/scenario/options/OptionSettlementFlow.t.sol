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

contract ScenarioOptionERC20 is ERC20 {
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

contract ScenarioOptionOracle is IOracle {
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

contract ScenarioMarginRiskModule is IRiskModule {
    IMarginEngineState internal immutable MARGIN_STATE;
    address internal immutable BASE_COLLATERAL_TOKEN;
    uint8 internal immutable BASE_DECIMALS;
    uint256 internal immutable BASE_MAINTENANCE_MARGIN_PER_CONTRACT;
    uint256 internal immutable IM_FACTOR_BPS;

    mapping(address => int256) internal equityBaseByTrader;

    constructor(
        address marginState_,
        address baseCollateralToken_,
        uint8 baseDecimals_,
        uint256 baseMaintenanceMarginPerContract_,
        uint256 imFactorBps_
    ) {
        MARGIN_STATE = IMarginEngineState(marginState_);
        BASE_COLLATERAL_TOKEN = baseCollateralToken_;
        BASE_DECIMALS = baseDecimals_;
        BASE_MAINTENANCE_MARGIN_PER_CONTRACT = baseMaintenanceMarginPerContract_;
        IM_FACTOR_BPS = imFactorBps_;
    }

    function setEquityBase(address trader, int256 equityBase_) external {
        equityBaseByTrader[trader] = equityBase_;
    }

    function computeAccountRisk(address trader) public view returns (AccountRisk memory risk) {
        uint256 shortContracts = MARGIN_STATE.totalShortContracts(trader);
        uint256 mmBase = shortContracts * BASE_MAINTENANCE_MARGIN_PER_CONTRACT;

        risk = AccountRisk({
            equityBase: equityBaseByTrader[trader],
            maintenanceMarginBase: mmBase,
            initialMarginBase: (mmBase * IM_FACTOR_BPS) / 10_000
        });
    }

    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase) {
        AccountRisk memory risk = computeAccountRisk(trader);
        return risk.equityBase - int256(risk.initialMarginBase);
    }

    function baseCollateralToken() external view returns (address) {
        return BASE_COLLATERAL_TOKEN;
    }

    function baseDecimals() external view returns (uint8) {
        return BASE_DECIMALS;
    }

    function baseMaintenanceMarginPerContract() external view returns (uint256) {
        return BASE_MAINTENANCE_MARGIN_PER_CONTRACT;
    }

    function imFactorBps() external view returns (uint256) {
        return IM_FACTOR_BPS;
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

contract ScenarioOptionInsuranceFund {
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

contract OptionSettlementFlowTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint256 internal constant STRIKE = 2_000 * PRICE_SCALE;
    uint128 internal constant PREMIUM_PER_CONTRACT = 100 * 1e6;
    uint256 internal constant ITM_SETTLEMENT_PRICE = 2_500 * PRICE_SCALE;
    uint256 internal constant OTM_SETTLEMENT_PRICE = 1_500 * PRICE_SCALE;
    uint256 internal constant ITM_PAYOFF = 500 * 1e6;
    uint256 internal constant BASE_MM_PER_CONTRACT = 10 * BASE_UNIT;
    uint256 internal constant IM_FACTOR_BPS = 12_000;
    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant BUYER = address(0xA1);
    address internal constant SELLER = address(0xB2);

    CollateralVault internal vault;
    OptionProductRegistry internal registry;
    MarginEngine internal engine;
    ScenarioOptionOracle internal oracle;
    ScenarioMarginRiskModule internal riskModule;
    ScenarioOptionInsuranceFund internal insuranceFund;
    ScenarioOptionERC20 internal usdc;
    ScenarioOptionERC20 internal weth;

    uint256 internal callOptionId;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new OptionProductRegistry(OWNER);
        oracle = new ScenarioOptionOracle();
        engine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));
        insuranceFund = new ScenarioOptionInsuranceFund(address(vault));

        usdc = new ScenarioOptionERC20("Mock USDC", "mUSDC", 6);
        weth = new ScenarioOptionERC20("Mock WETH", "mWETH", 18);

        riskModule =
            new ScenarioMarginRiskModule(address(engine), address(usdc), 6, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setMarginEngine(address(engine));
        vault.setAuthorizedEngine(address(insuranceFund), true);

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
        engine.setInsuranceFund(address(insuranceFund));
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
        riskModule.setEquityBase(BUYER, HEALTHY_EQUITY);
        riskModule.setEquityBase(SELLER, HEALTHY_EQUITY);
    }

    function testTraderDepositsOpensExpiresAndSettlesWithCorrectItmPayoff() external {
        _deposit(BUYER, 10_000 * BASE_UNIT);
        _deposit(SELLER, 10_000 * BASE_UNIT);
        _trade(BUYER, SELLER, 1);

        uint256 buyerBeforeSettlement = vault.balances(BUYER, address(usdc));
        uint256 sellerBeforeSettlement = vault.balances(SELLER, address(usdc));

        _expireAndSettlePrice(ITM_SETTLEMENT_PRICE);

        engine.settleAccount(callOptionId, SELLER);
        engine.settleAccount(callOptionId, BUYER);

        assertEq(vault.balances(BUYER, address(usdc)), buyerBeforeSettlement + ITM_PAYOFF);
        assertEq(vault.balances(SELLER, address(usdc)), sellerBeforeSettlement - ITM_PAYOFF);
        assertEq(engine.positions(BUYER, callOptionId).quantity, 0);
        assertEq(engine.positions(SELLER, callOptionId).quantity, 0);
    }

    function testTraderDepositsOpensExpiresAndSettlesWithZeroPayoffWhenOtm() external {
        _deposit(BUYER, 10_000 * BASE_UNIT);
        _deposit(SELLER, 10_000 * BASE_UNIT);
        _trade(BUYER, SELLER, 1);

        uint256 buyerBeforeSettlement = vault.balances(BUYER, address(usdc));
        uint256 sellerBeforeSettlement = vault.balances(SELLER, address(usdc));

        _expireAndSettlePrice(OTM_SETTLEMENT_PRICE);

        engine.settleAccount(callOptionId, SELLER);
        engine.settleAccount(callOptionId, BUYER);

        assertEq(vault.balances(BUYER, address(usdc)), buyerBeforeSettlement);
        assertEq(vault.balances(SELLER, address(usdc)), sellerBeforeSettlement);
        assertEq(engine.positions(BUYER, callOptionId).quantity, 0);
        assertEq(engine.positions(SELLER, callOptionId).quantity, 0);
    }

    function testSettledAccountCannotSettleSameExpiredOptionTwice() external {
        _deposit(BUYER, 10_000 * BASE_UNIT);
        _deposit(SELLER, 10_000 * BASE_UNIT);
        _trade(BUYER, SELLER, 1);
        _expireAndSettlePrice(ITM_SETTLEMENT_PRICE);

        engine.settleAccount(callOptionId, BUYER);

        vm.expectRevert(MarginEngineTypes.SettlementAlreadyProcessed.selector);
        engine.settleAccount(callOptionId, BUYER);
    }

    function testPremiumAndPayoffAccountingRemainCoherentThroughFullFlow() external {
        _deposit(BUYER, 10_000 * BASE_UNIT);
        _deposit(SELLER, 10_000 * BASE_UNIT);

        uint256 buyerStart = vault.balances(BUYER, address(usdc));
        uint256 sellerStart = vault.balances(SELLER, address(usdc));

        _trade(BUYER, SELLER, 1);
        _expireAndSettlePrice(ITM_SETTLEMENT_PRICE);

        engine.settleAccount(callOptionId, SELLER);
        engine.settleAccount(callOptionId, BUYER);

        MarginEngineTypes.SeriesSettlementState memory accounting = engine.getSeriesSettlementAccounting(callOptionId);

        assertEq(vault.balances(BUYER, address(usdc)), buyerStart - PREMIUM_PER_CONTRACT + ITM_PAYOFF);
        assertEq(vault.balances(SELLER, address(usdc)), sellerStart + PREMIUM_PER_CONTRACT - ITM_PAYOFF);
        assertEq(vault.balances(BUYER, address(usdc)) + vault.balances(SELLER, address(usdc)), buyerStart + sellerStart);
        assertEq(accounting.totalCollected, ITM_PAYOFF);
        assertEq(accounting.totalPaid, ITM_PAYOFF);
        assertEq(accounting.totalBadDebt, 0);
    }

    function testInsuranceFundIsUsedWhenSettlementShortfallExists() external {
        _deposit(BUYER, 10_000 * BASE_UNIT);
        _trade(BUYER, SELLER, 1);
        _fundInsurance(ITM_PAYOFF);
        _expireAndSettlePrice(ITM_SETTLEMENT_PRICE);

        uint256 insuranceBefore = vault.balances(address(insuranceFund), address(usdc));
        uint256 buyerBefore = vault.balances(BUYER, address(usdc));

        engine.settleAccount(callOptionId, BUYER);

        MarginEngineTypes.SeriesSettlementState memory accounting = engine.getSeriesSettlementAccounting(callOptionId);

        assertEq(vault.balances(BUYER, address(usdc)), buyerBefore + ITM_PAYOFF);
        assertEq(vault.balances(address(insuranceFund), address(usdc)), insuranceBefore - ITM_PAYOFF);
        assertEq(accounting.totalCollected, 0);
        assertEq(accounting.totalPaid, ITM_PAYOFF);
        assertEq(accounting.totalBadDebt, 0);
    }

    function testResidualBadDebtIsRecordedWhenCollateralAndInsuranceAreBothInsufficient() external {
        _deposit(BUYER, 10_000 * BASE_UNIT);
        _trade(BUYER, SELLER, 1);
        _fundInsurance(200 * BASE_UNIT);
        _expireAndSettlePrice(ITM_SETTLEMENT_PRICE);

        uint256 buyerBefore = vault.balances(BUYER, address(usdc));

        engine.settleAccount(callOptionId, BUYER);

        MarginEngineTypes.SeriesSettlementState memory accounting = engine.getSeriesSettlementAccounting(callOptionId);

        assertEq(vault.balances(BUYER, address(usdc)), buyerBefore + (200 * BASE_UNIT));
        assertEq(accounting.totalCollected, 0);
        assertEq(accounting.totalPaid, 200 * BASE_UNIT);
        assertEq(accounting.totalBadDebt, 300 * BASE_UNIT);
    }

    function _trade(address buyer, address seller, uint128 quantity) internal {
        vm.prank(MATCHING_ENGINE);
        engine.applyTrade(
            IMarginEngineTrade.Trade({
                buyer: buyer,
                seller: seller,
                optionId: callOptionId,
                quantity: quantity,
                price: PREMIUM_PER_CONTRACT,
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

    function _fundInsurance(uint256 amount) internal {
        usdc.mint(address(insuranceFund), amount);
        insuranceFund.depositToVault(address(usdc), amount);
    }

    function _expireAndSettlePrice(uint256 settlementPrice) internal {
        vm.warp(block.timestamp + 8 days);
        vm.prank(OWNER);
        registry.setSettlementPrice(callOptionId, settlementPrice);
    }
}
