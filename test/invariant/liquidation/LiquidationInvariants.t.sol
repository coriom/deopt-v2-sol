// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {IOracle} from "../../../src/oracle/IOracle.sol";
import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {PerpEngine} from "../../../src/perp/PerpEngine.sol";
import {PerpEngineTypes} from "../../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../../src/perp/PerpMarketRegistry.sol";
import {IPerpRiskModule} from "../../../src/perp/PerpEngineStorage.sol";
import {ICollateralSeizer} from "../../../src/liquidation/ICollateralSeizer.sol";

contract InvariantLiquidationERC20 is ERC20 {
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

contract InvariantLiquidationOracle is IOracle {
    function getPrice(address, address) external view returns (uint256 price, uint256 updatedAt) {
        return (2_000 * 1e8, block.timestamp);
    }

    function getPriceSafe(address, address) external view returns (uint256 price, uint256 updatedAt, bool ok) {
        return (2_000 * 1e8, block.timestamp, true);
    }
}

interface IInvariantPerpPositionView {
    function getPositionSize(address trader, uint256 marketId) external view returns (int256);
}

contract InvariantLiquidationRiskModule is IPerpRiskModule {
    address internal _engine;
    uint256 internal _marketId;
    address internal _baseCollateralTokenValue;
    uint8 internal _baseDecimalsValue;

    mapping(address => IPerpRiskModule.AccountRisk) internal healthyRisk;
    mapping(address => bool) internal dynamicTrader;

    function setPerpContext(address engine_, uint256 marketId_) external {
        _engine = engine_;
        _marketId = marketId_;
    }

    function setBaseConfig(address baseCollateralToken_, uint8 baseDecimals_) external {
        _baseCollateralTokenValue = baseCollateralToken_;
        _baseDecimalsValue = baseDecimals_;
    }

    function setHealthyRisk(address trader, int256 equityBase, uint256 maintenanceMarginBase, uint256 initialMarginBase)
        external
    {
        healthyRisk[trader] = IPerpRiskModule.AccountRisk({
            equityBase: equityBase,
            maintenanceMarginBase: maintenanceMarginBase,
            initialMarginBase: initialMarginBase
        });
    }

    function setDynamicTrader(address trader, bool enabled) external {
        dynamicTrader[trader] = enabled;
    }

    function computeAccountRisk(address trader) external view returns (IPerpRiskModule.AccountRisk memory risk) {
        if (dynamicTrader[trader] && _engine != address(0)) {
            int256 size1e8 = IInvariantPerpPositionView(_engine).getPositionSize(trader, _marketId);
            uint256 absSize1e8 = size1e8 >= 0 ? uint256(size1e8) : uint256(-size1e8);

            if (absSize1e8 > 1e8) {
                return IPerpRiskModule.AccountRisk({
                    equityBase: 90 * 1e6,
                    maintenanceMarginBase: 100 * 1e6,
                    initialMarginBase: 0
                });
            }

            if (absSize1e8 != 0) {
                return IPerpRiskModule.AccountRisk({
                    equityBase: 100 * 1e6,
                    maintenanceMarginBase: 90 * 1e6,
                    initialMarginBase: 0
                });
            }
        }

        return healthyRisk[trader];
    }

    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase) {
        IPerpRiskModule.AccountRisk memory risk = healthyRisk[trader];
        return risk.equityBase - int256(risk.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (IPerpRiskModule.WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;
        preview.maxWithdrawable = amount;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256 amount) {
        return type(uint256).max;
    }

    function baseCollateralToken() external view returns (address) {
        return _baseCollateralTokenValue;
    }

    function baseDecimals() external view returns (uint8) {
        return _baseDecimalsValue;
    }
}

contract InvariantLiquidationSeizer is ICollateralSeizer {
    struct Preview {
        uint256 valueBaseFloor;
        uint256 effectiveBaseFloor;
        bool ok;
    }

    address[] internal _tokensOut;
    uint256[] internal _amountsOut;
    uint256 internal _baseCovered;
    mapping(bytes32 => Preview) internal _previews;

    function clearPlan() external {
        delete _tokensOut;
        delete _amountsOut;
        _baseCovered = 0;
    }

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

contract InvariantLiquidationInsuranceFund {
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

contract LiquidationInvariantHandler is Test {
    uint256 internal constant ONE = 1e8;
    uint128 internal constant CLOSE_SIZE_1E8 = 1e8;
    int256 internal constant CLOSE_SIZE_INT_1E8 = 1e8;
    uint128 internal constant TWO = 2e8;
    uint128 internal constant ENTRY_PRICE_1E8 = 2_000 * 1e8;
    uint256 internal constant TRADER_USDC_BUFFER = 40 * 1e6;
    uint256 internal constant PENALTY_TARGET_BASE = 99 * 1e6;
    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;
    uint256 internal constant CASE_COUNT = 5;

    CollateralVault internal immutable VAULT;
    PerpEngine internal immutable PERP_ENGINE;
    InvariantLiquidationRiskModule internal immutable RISK_MODULE;
    InvariantLiquidationSeizer internal immutable SEIZER;
    InvariantLiquidationInsuranceFund internal immutable INSURANCE_FUND;
    InvariantLiquidationERC20 internal immutable USDC;
    InvariantLiquidationERC20 internal immutable WETH;
    uint256 internal immutable MARKET_ID;
    address internal immutable MATCHING_ENGINE;
    address internal immutable MAKER;
    address internal immutable LIQUIDATOR;

    address[] internal traders;
    mapping(address => bool) internal usedTrader;

    uint256 internal _totalPlannedCoverageBase;
    uint256 internal _totalEffectiveSeizedBase;
    uint256 internal _totalExplicitResidualBase;

    bool internal _overCreditViolation;
    bool internal _debtPathViolation;
    bool internal _insuranceRequestedViolation;
    bool internal _insuranceAvailabilityViolation;
    bool internal _bookkeepingViolation;

    constructor(
        CollateralVault vault_,
        PerpEngine perpEngine_,
        InvariantLiquidationRiskModule riskModule_,
        InvariantLiquidationSeizer seizer_,
        InvariantLiquidationInsuranceFund insuranceFund_,
        InvariantLiquidationERC20 usdc_,
        InvariantLiquidationERC20 weth_,
        uint256 marketId_,
        address matchingEngine_,
        address maker_,
        address liquidator_,
        address[] memory traders_
    ) {
        VAULT = vault_;
        PERP_ENGINE = perpEngine_;
        RISK_MODULE = riskModule_;
        SEIZER = seizer_;
        INSURANCE_FUND = insuranceFund_;
        USDC = usdc_;
        WETH = weth_;
        MARKET_ID = marketId_;
        MATCHING_ENGINE = matchingEngine_;
        MAKER = maker_;
        LIQUIDATOR = liquidator_;

        for (uint256 i = 0; i < traders_.length; i++) {
            traders.push(traders_[i]);
        }
    }

    function liquidateFreshTrader(uint256 traderSeed, uint256 caseSeed) external {
        address trader = traders[traderSeed % traders.length];
        if (usedTrader[trader]) return;
        usedTrader[trader] = true;

        uint256 liquidationCase = caseSeed % CASE_COUNT;

        uint256 insuranceFundingBase;
        uint256 plannedCoverageBase;
        uint256 plannedWethAmount;
        uint256 traderWethDeposit;
        uint256 previewEffectiveBase;

        if (liquidationCase == 0) {
            traderWethDeposit = 1 ether;
            plannedWethAmount = 1 ether;
            plannedCoverageBase = PENALTY_TARGET_BASE;
            previewEffectiveBase = PENALTY_TARGET_BASE;
        } else if (liquidationCase == 1) {
            traderWethDeposit = 1 ether;
            plannedWethAmount = 1 ether;
            plannedCoverageBase = 30 * 1e6;
            previewEffectiveBase = 30 * 1e6;
            insuranceFundingBase = 69 * 1e6;
        } else if (liquidationCase == 2) {
            traderWethDeposit = 1 ether;
            plannedWethAmount = 1 ether;
            plannedCoverageBase = 30 * 1e6;
            previewEffectiveBase = 30 * 1e6;
            insuranceFundingBase = 40 * 1e6;
        } else if (liquidationCase == 3) {
            insuranceFundingBase = 0;
        } else {
            traderWethDeposit = 1 ether;
            plannedWethAmount = 2 ether;
            plannedCoverageBase = PENALTY_TARGET_BASE;
            previewEffectiveBase = 30 * 1e6;
            insuranceFundingBase = 69 * 1e6;
        }

        _depositUsdc(trader, TRADER_USDC_BUFFER);
        if (traderWethDeposit != 0) {
            _depositWeth(trader, traderWethDeposit);
        }
        if (insuranceFundingBase != 0) {
            _fundInsurance(insuranceFundingBase);
        }

        _configureSeizer(plannedWethAmount, plannedCoverageBase, previewEffectiveBase);
        _openLong(trader);

        uint256 traderUsdcBefore = VAULT.balances(trader, address(USDC));
        uint256 traderWethBefore = VAULT.balances(trader, address(WETH));
        uint256 liquidatorUsdcBefore = VAULT.balances(LIQUIDATOR, address(USDC));
        uint256 liquidatorWethBefore = VAULT.balances(LIQUIDATOR, address(WETH));
        uint256 insuranceUsdcBefore = VAULT.balances(address(INSURANCE_FUND), address(USDC));
        uint256 residualDebtBefore = PERP_ENGINE.getResidualBadDebt(trader);

        PerpEngineTypes.Position memory traderPosBefore = PERP_ENGINE.positions(trader, MARKET_ID);
        PerpEngineTypes.Position memory liquidatorPosBefore = PERP_ENGINE.positions(LIQUIDATOR, MARKET_ID);

        vm.prank(LIQUIDATOR);
        PERP_ENGINE.liquidate(trader, MARKET_ID, CLOSE_SIZE_1E8);

        uint256 traderUsdcAfter = VAULT.balances(trader, address(USDC));
        uint256 traderWethAfter = VAULT.balances(trader, address(WETH));
        uint256 liquidatorUsdcAfter = VAULT.balances(LIQUIDATOR, address(USDC));
        uint256 liquidatorWethAfter = VAULT.balances(LIQUIDATOR, address(WETH));
        uint256 insuranceUsdcAfter = VAULT.balances(address(INSURANCE_FUND), address(USDC));
        uint256 residualDebtAfter = PERP_ENGINE.getResidualBadDebt(trader);

        PerpEngineTypes.Position memory traderPosAfter = PERP_ENGINE.positions(trader, MARKET_ID);
        PerpEngineTypes.Position memory liquidatorPosAfter = PERP_ENGINE.positions(LIQUIDATOR, MARKET_ID);

        uint256 traderUsdcDebit = traderUsdcBefore - traderUsdcAfter;
        uint256 traderWethDebit = traderWethBefore - traderWethAfter;
        uint256 liquidatorUsdcCredit = liquidatorUsdcAfter - liquidatorUsdcBefore;
        uint256 liquidatorWethCredit = liquidatorWethAfter - liquidatorWethBefore;
        uint256 insuranceUsdcDebit = insuranceUsdcBefore - insuranceUsdcAfter;
        uint256 residualDebtDelta = residualDebtAfter - residualDebtBefore;

        if (liquidatorUsdcCredit > traderUsdcBefore + insuranceUsdcBefore) {
            _overCreditViolation = true;
        }
        if (liquidatorWethCredit > traderWethBefore) {
            _overCreditViolation = true;
        }

        uint256 actualSeizedEffectiveBase;
        if (traderWethDebit != 0) {
            (, uint256 effectiveBaseFloor, bool ok) = SEIZER.previewEffectiveBaseValue(address(WETH), traderWethDebit);
            if (!ok) {
                _bookkeepingViolation = true;
            } else {
                actualSeizedEffectiveBase = effectiveBaseFloor;
            }
        }

        _totalPlannedCoverageBase += plannedCoverageBase;
        _totalEffectiveSeizedBase += actualSeizedEffectiveBase;

        uint256 requestedInsuranceBase = PENALTY_TARGET_BASE > actualSeizedEffectiveBase
            ? PENALTY_TARGET_BASE - actualSeizedEffectiveBase
            : 0;

        if (insuranceUsdcDebit > requestedInsuranceBase) {
            _insuranceRequestedViolation = true;
        }
        if (insuranceUsdcDebit > insuranceUsdcBefore) {
            _insuranceAvailabilityViolation = true;
        }

        uint256 expectedResidualBase = requestedInsuranceBase > insuranceUsdcDebit
            ? requestedInsuranceBase - insuranceUsdcDebit
            : 0;
        _totalExplicitResidualBase += expectedResidualBase;

        if (residualDebtDelta != expectedResidualBase) {
            _debtPathViolation = true;
        }

        if (liquidatorUsdcCredit != traderUsdcDebit + insuranceUsdcDebit) {
            _bookkeepingViolation = true;
        }
        if (liquidatorWethCredit != traderWethDebit) {
            _bookkeepingViolation = true;
        }

        int256 traderClosed = traderPosBefore.size1e8 - traderPosAfter.size1e8;
        int256 liquidatorOpened = liquidatorPosAfter.size1e8 - liquidatorPosBefore.size1e8;

        if (traderClosed != CLOSE_SIZE_INT_1E8 || liquidatorOpened != CLOSE_SIZE_INT_1E8) {
            _bookkeepingViolation = true;
        }
    }

    function tradersLength() external view returns (uint256) {
        return traders.length;
    }

    function traderAt(uint256 index) external view returns (address) {
        return traders[index];
    }

    function totalPlannedCoverageBase() external view returns (uint256) {
        return _totalPlannedCoverageBase;
    }

    function totalEffectiveSeizedBase() external view returns (uint256) {
        return _totalEffectiveSeizedBase;
    }

    function totalExplicitResidualBase() external view returns (uint256) {
        return _totalExplicitResidualBase;
    }

    function overCreditViolation() external view returns (bool) {
        return _overCreditViolation;
    }

    function debtPathViolation() external view returns (bool) {
        return _debtPathViolation;
    }

    function insuranceRequestedViolation() external view returns (bool) {
        return _insuranceRequestedViolation;
    }

    function insuranceAvailabilityViolation() external view returns (bool) {
        return _insuranceAvailabilityViolation;
    }

    function bookkeepingViolation() external view returns (bool) {
        return _bookkeepingViolation;
    }

    function _configureSeizer(uint256 plannedWethAmount, uint256 plannedCoverageBase, uint256 previewEffectiveBase)
        internal
    {
        if (plannedWethAmount == 0 || plannedCoverageBase == 0) {
            SEIZER.clearPlan();
            return;
        }

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(WETH);
        amounts[0] = plannedWethAmount;

        SEIZER.setPlan(tokens, amounts, plannedCoverageBase);
        SEIZER.setPreview(address(WETH), 1 ether, previewEffectiveBase, previewEffectiveBase, true);
    }

    function _depositUsdc(address user, uint256 amount) internal {
        USDC.mint(user, amount);

        vm.startPrank(user);
        IERC20(address(USDC)).approve(address(VAULT), amount);
        VAULT.deposit(address(USDC), amount);
        vm.stopPrank();
    }

    function _depositWeth(address user, uint256 amount) internal {
        WETH.mint(user, amount);

        vm.startPrank(user);
        IERC20(address(WETH)).approve(address(VAULT), amount);
        VAULT.deposit(address(WETH), amount);
        vm.stopPrank();
    }

    function _fundInsurance(uint256 amount) internal {
        USDC.mint(address(INSURANCE_FUND), amount);
        INSURANCE_FUND.depositToVault(address(USDC), amount);
    }

    function _openLong(address trader) internal {
        vm.prank(MATCHING_ENGINE);
        PERP_ENGINE.applyTrade(
            IPerpEngineTrade.Trade({
                buyer: trader,
                seller: MAKER,
                marketId: MARKET_ID,
                sizeDelta1e8: uint128(TWO),
                executionPrice1e8: uint128(ENTRY_PRICE_1E8),
                buyerIsMaker: false
            })
        );
    }
}

contract LiquidationInvariantsTest is StdInvariant, Test {
    uint256 internal constant ONE = 1e8;
    uint128 internal constant MAX_POSITION_SIZE_1E8 = 1_000 * 1e8;
    uint128 internal constant MAX_OPEN_INTEREST_1E8 = 10_000 * 1e8;
    int256 internal constant HEALTHY_EQUITY = 1_000_000 * 1e6;
    bytes32 internal constant ETH_PERP_SYMBOL = "ETH-PERP";

    address internal constant OWNER = address(0xA11CE);
    address internal constant MATCHING_ENGINE = address(0xBEEF);
    address internal constant MAKER = address(0xB2);
    address internal constant LIQUIDATOR = address(0xC3);
    address internal constant TRADER_0 = address(0xA100);
    address internal constant TRADER_1 = address(0xA101);
    address internal constant TRADER_2 = address(0xA102);
    address internal constant TRADER_3 = address(0xA103);
    address internal constant TRADER_4 = address(0xA104);
    address internal constant TRADER_5 = address(0xA105);
    address internal constant TRADER_6 = address(0xA106);
    address internal constant TRADER_7 = address(0xA107);
    address internal constant TRADER_8 = address(0xA108);
    address internal constant TRADER_9 = address(0xA109);
    address internal constant TRADER_10 = address(0xA10A);
    address internal constant TRADER_11 = address(0xA10B);

    CollateralVault internal vault;
    PerpMarketRegistry internal registry;
    PerpEngine internal engine;
    InvariantLiquidationOracle internal oracle;
    InvariantLiquidationRiskModule internal riskModule;
    InvariantLiquidationSeizer internal seizer;
    InvariantLiquidationInsuranceFund internal insuranceFund;
    InvariantLiquidationERC20 internal usdc;
    InvariantLiquidationERC20 internal weth;
    LiquidationInvariantHandler internal handler;

    uint256 internal marketId;
    address[] internal traders;

    function setUp() external {
        vault = new CollateralVault(OWNER);
        registry = new PerpMarketRegistry(OWNER);
        oracle = new InvariantLiquidationOracle();
        usdc = new InvariantLiquidationERC20("Mock USDC", "mUSDC", 6);
        weth = new InvariantLiquidationERC20("Mock WETH", "mWETH", 18);
        riskModule = new InvariantLiquidationRiskModule();
        seizer = new InvariantLiquidationSeizer();
        insuranceFund = new InvariantLiquidationInsuranceFund(address(vault));
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
                maxPositionSize1e8: MAX_POSITION_SIZE_1E8,
                maxOpenInterest1e8: MAX_OPEN_INTEREST_1E8,
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
        riskModule.setPerpContext(address(engine), marketId);
        riskModule.setBaseConfig(address(usdc), 6);
        vm.stopPrank();

        traders = new address[](12);
        traders[0] = TRADER_0;
        traders[1] = TRADER_1;
        traders[2] = TRADER_2;
        traders[3] = TRADER_3;
        traders[4] = TRADER_4;
        traders[5] = TRADER_5;
        traders[6] = TRADER_6;
        traders[7] = TRADER_7;
        traders[8] = TRADER_8;
        traders[9] = TRADER_9;
        traders[10] = TRADER_10;
        traders[11] = TRADER_11;

        riskModule.setHealthyRisk(MAKER, HEALTHY_EQUITY, 0, 0);
        riskModule.setHealthyRisk(LIQUIDATOR, HEALTHY_EQUITY, 0, 0);
        for (uint256 i = 0; i < traders.length; i++) {
            riskModule.setHealthyRisk(traders[i], HEALTHY_EQUITY, 0, 0);
            riskModule.setDynamicTrader(traders[i], true);
        }

        _depositUsdc(MAKER, 1_000_000 * 1e6);

        handler = new LiquidationInvariantHandler(
            vault,
            engine,
            riskModule,
            seizer,
            insuranceFund,
            usdc,
            weth,
            marketId,
            MATCHING_ENGINE,
            MAKER,
            LIQUIDATOR,
            traders
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.liquidateFreshTrader.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_seizedCollateralEffectiveValueNeverExceedsConservativePlannedCoverage() external view {
        assertLe(handler.totalEffectiveSeizedBase(), handler.totalPlannedCoverageBase());
    }

    function invariant_liquidationCannotOverCreditCollateralRelativeToActualAvailableBalances() external view {
        assertFalse(handler.overCreditViolation());
    }

    function invariant_residualBadDebtIsOnlyCreatedThroughExplicitShortfallPaths() external view {
        assertFalse(handler.debtPathViolation());
        assertEq(engine.getTotalResidualBadDebt(), handler.totalExplicitResidualBase());
    }

    function invariant_insuranceCoverageNeverExceedsRequestedShortfall() external view {
        assertFalse(handler.insuranceRequestedViolation());
    }

    function invariant_insuranceCoverageNeverExceedsActuallyAvailableFundBalance() external view {
        assertFalse(handler.insuranceAvailabilityViolation());
    }

    function invariant_testedLiquidationSequencesDoNotSilentlyWorsenSolvencyAccountingThroughInconsistentBookkeeping()
        external
        view
    {
        assertFalse(handler.bookkeepingViolation());
        assertEq(engine.getTotalResidualBadDebt(), _sumTraderResidualBadDebt());
    }

    function _sumTraderResidualBadDebt() internal view returns (uint256 total) {
        uint256 len = handler.tradersLength();
        for (uint256 i = 0; i < len; i++) {
            total += engine.getResidualBadDebt(handler.traderAt(i));
        }
    }

    function _depositUsdc(address user, uint256 amount) internal {
        usdc.mint(user, amount);

        vm.startPrank(user);
        IERC20(address(usdc)).approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }
}
