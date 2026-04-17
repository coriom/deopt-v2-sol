// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {IPriceSource} from "../../../src/oracle/IPriceSource.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {OracleRouter} from "../../../src/oracle/OracleRouter.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";

contract ScenarioOracleFailureERC20 is ERC20 {
    uint8 private immutable _decimalsValue;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }
}

contract ScenarioOracleFailurePriceSource is IPriceSource {
    uint256 internal _price;
    uint256 internal _updatedAt;
    bool internal _shouldRevert;

    function setResponse(uint256 price_, uint256 updatedAt_, bool shouldRevert_) external {
        _price = price_;
        _updatedAt = updatedAt_;
        _shouldRevert = shouldRevert_;
    }

    function getLatestPrice() external view returns (uint256 price, uint256 updatedAt) {
        if (_shouldRevert) revert("source-unavailable");
        return (_price, _updatedAt);
    }
}

contract ScenarioOracleFailurePerpRiskModule is IPerpRiskModule {
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

contract ScenarioOracleFailureInsuranceFund {
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

contract OracleFailureFlowTest is Test {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BASE_UNIT = 1e6;
    uint128 internal constant ONE = 1e8;
    uint128 internal constant TWO = 2e8;
    uint128 internal constant ENTRY_PRICE = 2_000 * 1e8;
    bytes32 internal constant ETH_PERP_SYMBOL = 0x4554482d50455250000000000000000000000000000000000000000000000000;

    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;
    int256 internal constant LIQUIDATABLE_EQUITY = 90 * 1e6;
    uint256 internal constant LIQUIDATABLE_MM = 100 * 1e6;

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant TRADER = address(0xA1);
    address internal constant MAKER = address(0xB2);
    address internal constant LIQUIDATOR = address(0xC3);

    CollateralVault internal vault;
    OracleRouter internal router;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    ScenarioOracleFailurePerpRiskModule internal riskModule;
    ScenarioOracleFailureInsuranceFund internal insuranceFund;
    ScenarioOracleFailurePriceSource internal primarySource;
    ScenarioOracleFailurePriceSource internal secondarySource;
    ScenarioOracleFailureERC20 internal usdc;
    ScenarioOracleFailureERC20 internal weth;

    uint256 internal marketId;

    function setUp() external {
        vm.warp(1_000);

        vault = new CollateralVault(OWNER);
        router = new OracleRouter(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        usdc = new ScenarioOracleFailureERC20("Mock USDC", "mUSDC", 6);
        weth = new ScenarioOracleFailureERC20("Mock WETH", "mWETH", 18);
        riskModule = new ScenarioOracleFailurePerpRiskModule(address(usdc), 6);
        insuranceFund = new ScenarioOracleFailureInsuranceFund(address(vault));
        primarySource = new ScenarioOracleFailurePriceSource();
        secondarySource = new ScenarioOracleFailurePriceSource();
        engine = new PerpEngine(OWNER, address(registry), address(vault), address(router));

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
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
        engine.setInsuranceFund(address(insuranceFund));

        router.setMaxOracleDelay(600);
        router.setFeed(address(weth), address(usdc), primarySource, IPriceSource(address(0)), 60, 100, true);
        vm.stopPrank();

        primarySource.setResponse(uint256(ENTRY_PRICE), block.timestamp, false);
        _setHealthyRisk(TRADER);
        _setHealthyRisk(MAKER);
        _setHealthyRisk(LIQUIDATOR);
        _openLong(TRADER, MAKER, TWO);
        riskModule.setAccountRisk(TRADER, LIQUIDATABLE_EQUITY, LIQUIDATABLE_MM, 0);
    }

    function testStaleOraclePriceCausesProtectedLiquidationPathToRevert() external {
        primarySource.setResponse(uint256(ENTRY_PRICE), block.timestamp - 61, false);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(OracleRouter.StalePrice.selector);
        engine.liquidate(TRADER, marketId, ONE);
    }

    function testZeroOraclePriceIsRejected() external {
        primarySource.setResponse(0, block.timestamp, false);

        vm.expectRevert(OracleRouter.NoSource.selector);
        router.getPrice(address(weth), address(usdc));

        (uint256 price, uint256 updatedAt, bool ok) = router.getPriceSafe(address(weth), address(usdc));
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(ok);
    }

    function testFutureTimestampOracleUpdateIsRejected() external {
        primarySource.setResponse(uint256(ENTRY_PRICE), block.timestamp + 1, false);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(OracleRouter.FutureTimestamp.selector);
        engine.liquidate(TRADER, marketId, ONE);
    }

    function testUnavailableOraclePathCausesProtectedOperationToFailSafely() external {
        primarySource.setResponse(0, 0, true);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(OracleRouter.NoSource.selector);
        engine.liquidate(TRADER, marketId, ONE);
    }

    function testFallbackDeviationLogicBehavesConservativelyWhenConfigured() external {
        vm.startPrank(OWNER);
        router.setFeed(address(weth), address(usdc), primarySource, secondarySource, 60, 100, true);
        vm.stopPrank();

        primarySource.setResponse(1_990 * PRICE_SCALE, block.timestamp - 61, false);
        secondarySource.setResponse(1_995 * PRICE_SCALE, block.timestamp, false);

        (uint256 fallbackPrice, uint256 updatedAt, bool ok) = router.getPriceSafe(address(weth), address(usdc));
        assertTrue(ok);
        assertEq(fallbackPrice, 1_995 * PRICE_SCALE);
        assertEq(updatedAt, block.timestamp);

        primarySource.setResponse(2_000 * PRICE_SCALE, block.timestamp, false);
        secondarySource.setResponse(2_050 * PRICE_SCALE, block.timestamp, false);

        vm.expectRevert(OracleRouter.DeviationTooHigh.selector);
        router.getPrice(address(weth), address(usdc));

        (uint256 rejectedPrice, uint256 rejectedUpdatedAt, bool rejectedOk) = router.getPriceSafe(address(weth), address(usdc));
        assertEq(rejectedPrice, 0);
        assertEq(rejectedUpdatedAt, 0);
        assertFalse(rejectedOk);
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

    function _setHealthyRisk(address trader) internal {
        riskModule.setAccountRisk(trader, HEALTHY_EQUITY, 0, 0);
    }
}
