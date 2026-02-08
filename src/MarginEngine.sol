// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./OptionProductRegistry.sol";
import "./CollateralVault.sol";
import "./oracle/IOracle.sol";
import "./risk/IRiskModule.sol";
import "./risk/IMarginEngineState.sol";
import "./matching/IMarginEngineTrade.sol";

/// @title MarginEngine
/// @notice Gère les positions, la marge, les liquidations et le settlement à l'expiration.
/// @dev
///  - Toute la logique de risque est déléguée au RiskModule.
///  - ContractSize hard-lock = 1e8 (PRICE_1E8).
///  - Multi-settlement: premium/payoff par `series.settlementAsset`.
///  - Liquidation: cashflow par settlementAsset + pénalité saisissable (base puis fallback assets touchés).
///  - Hardening:
///      * depositCollateral() utilise CollateralVault.depositFor(user, token, amount) (évite le bug msg.sender).
///      * withdrawCollateral() utilise CollateralVault.withdrawFor(user, token, amount) (évite le bug msg.sender).
///      * best-effort sync du vault avant lectures de balances en settlement/liquidation.
///      * conversions/approx de saisie sans overflow (pas de PRICE_1E8*factor, pas de seizeTok*factor).
///
/// Patch majeur (compile + compat IMarginEngineState):
///  - IMarginEngineState expose optionRegistry()/collateralVault()/oracle()/riskModule() => returns (address).
///  - Les variables publiques typées créent des getters incompatibles (return type != address).
///  => on renomme les variables et on implémente explicitement les getters address.
contract MarginEngine is ReentrancyGuard, IMarginEngineState, IMarginEngineTrade {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant BPS = 10_000;
    uint256 private constant PRICE_1E8 = 1e8;

    // defensive: 10**77 fits in uint256, 10**78 overflows
    uint256 private constant MAX_POW10_EXP = 77;

    int256 private constant INT128_MAX = int256(type(int128).max);
    int256 private constant INT128_MIN = int256(type(int128).min);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error InvalidTrade();
    error ZeroAddress();
    error NotLiquidatable();
    error LengthMismatch();
    error NoBaseCollateral();
    error RiskModuleNotSet();
    error AmountZero();
    error PausedError();

    // Series / trading
    error SeriesExpired();
    error SeriesNotActiveCloseOnly();

    // Contract size hardening (enforce fixed 1e8)
    error InvalidContractSize();

    // Expiration / payoff
    error NotExpired();
    error SettlementNotSet();
    error SettlementAlreadyProcessed();
    error SettlementAssetNotConfigured();
    error InsuranceFundNotSet();
    error InsuranceFundInsufficient(uint256 needed, uint256 available);

    // Withdraw via MarginEngine
    error WithdrawTooLarge();
    error WithdrawWouldBreachMargin();

    // Liquidation hardening
    error LiquidationNotImproving();
    error InvalidLiquidationParams();
    error LiquidationNothingToDo();
    error LiquidationCloseFactorZero();

    // Liquidation pricing
    error OraclePriceUnavailable();
    error OraclePriceStale();
    error LiquidationPricingParamsInvalid();

    // Safety / casting
    error QuantityTooLarge();
    error QuantityMinNotAllowed(); // forbid int128.min (DoS/negation edge-case)
    error PnlOverflow();
    error MathOverflow();
    error MarginRequirementBreached(address trader);

    // Decimals hardening
    error DecimalsOverflow(address token);

    // Risk params strictness
    error RiskParamsMismatch();

    // Vault deposit/withdraw wrapper hardening
    error VaultDepositForNotSupported();
    error VaultWithdrawForNotSupported();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MatchingEngineSet(address indexed newMatchingEngine);

    event TradeExecuted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed optionId,
        uint128 quantity,
        uint128 price
    );

    event RiskParamsSet(address baseCollateralToken, uint256 baseMaintenanceMarginPerContract, uint256 imFactorBps);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event OracleSet(address indexed newOracle);
    event RiskModuleSet(address indexed newRiskModule);

    event LiquidationParamsSet(uint256 liquidationThresholdBps, uint256 liquidationPenaltyBps);

    event LiquidationHardenParamsSet(uint256 liquidationCloseFactorBps, uint256 minLiquidationImprovementBps);

    event LiquidationPricingParamsSet(uint256 liquidationPriceSpreadBps, uint256 minLiquidationPriceBpsOfIntrinsic);

    /// @notice Fraîcheur minimale exigée côté liquidation (en secondes). 0 = désactivé.
    event LiquidationOracleMaxDelaySet(uint32 oldDelay, uint32 newDelay);

    event Liquidation(
        address indexed liquidator,
        address indexed trader,
        uint256[] optionIds,
        uint128[] quantitiesExecuted,
        uint256 collateralSeizedBaseValue
    );

    event LiquidationCashflow(
        address indexed liquidator,
        address indexed trader,
        address indexed settlementAsset,
        uint256 cashPaidByTrader,
        uint256 cashRequested
    );

    event CollateralDeposited(address indexed trader, address indexed token, uint256 amount);

    event CollateralWithdrawn(address indexed trader, address indexed token, uint256 amount, uint256 marginRatioAfterBps);

    event InsuranceFundSet(address indexed oldFund, address indexed newFund);

    event AccountSettled(
        address indexed trader,
        uint256 indexed optionId,
        int256 pnl,
        uint256 collectedFromTrader,
        uint256 paidToTrader,
        uint256 badDebt
    );

    event SeriesSettlementAccountingUpdated(uint256 indexed optionId, uint256 totalCollected, uint256 totalPaid, uint256 totalBadDebt);

    event LiquidationSeize(
        address indexed liquidator,
        address indexed trader,
        address indexed token,
        uint256 amountToken,
        uint256 seizedBaseValue
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public matchingEngine;

    // renamed to avoid getter conflicts with IMarginEngineState optional helpers
    OptionProductRegistry private _optionRegistry;
    CollateralVault private _collateralVault;
    IOracle private _oracle;
    IRiskModule private _riskModule;

    mapping(address => mapping(uint256 => IMarginEngineState.Position)) private _positions;

    /// @notice Nombre total de contrats shorts (toutes séries confondues) par trader
    mapping(address => uint256) public totalShortContracts;

    /// -----------------------------------------------------------------------
    /// OPEN SERIES TRACKING (anti-DoS gaz)
    /// -----------------------------------------------------------------------
    /// @notice Liste des séries sur lesquelles un trader a une position NON NULLE (open only).
    mapping(address => uint256[]) private traderSeries;

    /// @notice Index+1 dans traderSeries (0 = absent). Permet remove O(1).
    mapping(address => mapping(uint256 => uint256)) private traderSeriesIndexPlus1;

    /// @notice Cache local (doit matcher RiskModule) : baseCollateralToken / baseMM / IM factor.
    address public baseCollateralToken;
    uint256 public baseMaintenanceMarginPerContract;
    uint256 public imFactorBps;

    bool public paused;

    uint256 public liquidationThresholdBps = 10050;
    uint256 public liquidationPenaltyBps = 500;

    // ===================== Liquidation hardening (A-1) =====================

    uint256 public liquidationCloseFactorBps = 5000;
    uint256 public minLiquidationImprovementBps = 1;

    // ===================== Liquidation pricing (A-1) =====================

    uint256 public liquidationPriceSpreadBps = 500;
    uint256 public minLiquidationPriceBpsOfIntrinsic = 0;

    /// @notice Fraîcheur exigée côté liquidation. 0 = off.
    uint32 public liquidationOracleMaxDelay = 600;

    // ===================== Settlement (per-account) =====================

    address public insuranceFund;

    mapping(uint256 => mapping(address => bool)) public isAccountSettled;

    mapping(uint256 => uint256) public seriesCollected;
    mapping(uint256 => uint256) public seriesPaid;
    mapping(uint256 => uint256) public seriesBadDebt;

    /*//////////////////////////////////////////////////////////////
                        INTERNAL PARAM INTERFACE
    //////////////////////////////////////////////////////////////*/

    interface IRiskModuleParams {
        function baseCollateralToken() external view returns (address);
        function baseMaintenanceMarginPerContract() external view returns (uint256);
        function imFactorBps() external view returns (uint256);
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyMatchingEngine() {
        if (msg.sender != matchingEngine) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address registry_, address vault_, address oracle_) {
        if (_owner == address(0) || registry_ == address(0) || vault_ == address(0) || oracle_ == address(0)) {
            revert ZeroAddress();
        }

        owner = _owner;
        _optionRegistry = OptionProductRegistry(registry_);
        _collateralVault = CollateralVault(vault_);
        _oracle = IOracle(oracle_);

        emit OwnershipTransferred(address(0), _owner);
        emit OracleSet(oracle_);

        emit LiquidationOracleMaxDelaySet(0, liquidationOracleMaxDelay);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP / CONFIG
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setMatchingEngine(address matchingEngine_) external onlyOwner {
        if (matchingEngine_ == address(0)) revert ZeroAddress();
        matchingEngine = matchingEngine_;
        emit MatchingEngineSet(matchingEngine_);
    }

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        _oracle = IOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function setRiskModule(address riskModule_) external onlyOwner {
        if (riskModule_ == address(0)) revert ZeroAddress();
        _riskModule = IRiskModule(riskModule_);
        emit RiskModuleSet(riskModule_);
    }

    function setInsuranceFund(address insuranceFund_) external onlyOwner {
        if (insuranceFund_ == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = insuranceFund_;
        emit InsuranceFundSet(old, insuranceFund_);
    }

    /// @notice Configure (cache) les risk params côté MarginEngine, en vérifiant qu'ils MATCHENT RiskModule.
    /// @dev Source of truth = RiskModule.
    function setRiskParams(address baseToken_, uint256 baseMMPerContract_, uint256 imFactorBps_) external onlyOwner {
        if (baseToken_ == address(0)) revert ZeroAddress();
        if (imFactorBps_ < BPS) revert InvalidLiquidationParams();
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();

        IRiskModuleParams rp = IRiskModuleParams(address(_riskModule));

        if (rp.baseCollateralToken() != baseToken_) revert RiskParamsMismatch();
        if (rp.baseMaintenanceMarginPerContract() != baseMMPerContract_) revert RiskParamsMismatch();
        if (rp.imFactorBps() != imFactorBps_) revert RiskParamsMismatch();

        baseCollateralToken = baseToken_;
        baseMaintenanceMarginPerContract = baseMMPerContract_;
        imFactorBps = imFactorBps_;

        emit RiskParamsSet(baseToken_, baseMMPerContract_, imFactorBps_);
    }

    function setLiquidationParams(uint256 liquidationThresholdBps_, uint256 liquidationPenaltyBps_) external onlyOwner {
        if (liquidationThresholdBps_ < BPS) revert InvalidLiquidationParams();
        if (liquidationPenaltyBps_ > BPS) revert InvalidLiquidationParams();

        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationPenaltyBps = liquidationPenaltyBps_;

        emit LiquidationParamsSet(liquidationThresholdBps_, liquidationPenaltyBps_);
    }

    function setLiquidationHardenParams(uint256 closeFactorBps_, uint256 minImprovementBps_) external onlyOwner {
        if (closeFactorBps_ == 0) revert LiquidationCloseFactorZero();
        if (closeFactorBps_ > BPS) revert InvalidLiquidationParams();

        minLiquidationImprovementBps = minImprovementBps_;
        liquidationCloseFactorBps = closeFactorBps_;

        emit LiquidationHardenParamsSet(closeFactorBps_, minImprovementBps_);
    }

    function setLiquidationPricingParams(uint256 liquidationPriceSpreadBps_, uint256 minLiqPriceBpsOfIntrinsic_)
        external
        onlyOwner
    {
        if (liquidationPriceSpreadBps_ > BPS) revert LiquidationPricingParamsInvalid();
        if (minLiqPriceBpsOfIntrinsic_ > BPS) revert LiquidationPricingParamsInvalid();

        liquidationPriceSpreadBps = liquidationPriceSpreadBps_;
        minLiquidationPriceBpsOfIntrinsic = minLiqPriceBpsOfIntrinsic_;

        emit LiquidationPricingParamsSet(liquidationPriceSpreadBps_, minLiqPriceBpsOfIntrinsic_);
    }

    function setLiquidationOracleMaxDelay(uint32 delay_) external onlyOwner {
        if (delay_ > 3600) revert LiquidationPricingParamsInvalid();
        uint32 old = liquidationOracleMaxDelay;
        liquidationOracleMaxDelay = delay_;
        emit LiquidationOracleMaxDelaySet(old, delay_);
    }

    /*//////////////////////////////////////////////////////////////
                          IMarginEngineState (required)
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 optionId) external view override returns (IMarginEngineState.Position memory) {
        return _positions[trader][optionId];
    }

    /// @notice OPEN series only (positions non nulles)
    function getTraderSeries(address trader) external view override returns (uint256[] memory) {
        return traderSeries[trader];
    }

    function getTraderSeriesLength(address trader) external view override returns (uint256) {
        return traderSeries[trader].length;
    }

    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        override
        returns (uint256[] memory slice)
    {
        uint256 len = traderSeries[trader].length;
        if (start > len) start = len;
        if (end > len) end = len;
        if (end < start) end = start;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);
        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = traderSeries[trader][start + i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                    IMarginEngineState (optional helpers)
    //////////////////////////////////////////////////////////////*/

    function optionRegistry() external view override returns (address) {
        return address(_optionRegistry);
    }

    function collateralVault() external view override returns (address) {
        return address(_collateralVault);
    }

    function oracle() external view override returns (address) {
        return address(_oracle);
    }

    function riskModule() external view override returns (address) {
        return address(_riskModule);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader) external view returns (IRiskModule.AccountRisk memory risk) {
        if (address(_riskModule) == address(0)) {
            IRiskModule.AccountRisk memory empty;
            return empty;
        }
        return _riskModule.computeAccountRisk(trader);
    }

    function getFreeCollateral(address trader) external view returns (int256) {
        if (address(_riskModule) == address(0)) return 0;
        return _riskModule.computeFreeCollateral(trader);
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (IRiskModule.WithdrawPreview memory preview)
    {
        if (address(_riskModule) == address(0)) return preview;
        return _riskModule.previewWithdrawImpact(trader, token, amount);
    }

    function isSeriesExpired(uint256 optionId) public view returns (bool) {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        return block.timestamp >= series.expiry;
    }

    /*//////////////////////////////////////////////////////////////
                        USER COLLATERAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Dépôt correct via CollateralVault.depositFor(user, token, amount).
    ///      Si non implémenté dans CollateralVault => revert (évite créditer le mauvais compte).
    function depositCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        (bool ok,) =
            address(_collateralVault).call(abi.encodeWithSignature("depositFor(address,address,uint256)", msg.sender, token, amount));
        if (!ok) revert VaultDepositForNotSupported();

        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @dev IMPORTANT: ne jamais appeler collateralVault.withdraw() ici (msg.sender=MarginEngine).
    ///      On force withdrawFor(user, token, amount). Si non supporté => revert.
    function withdrawCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        if (amount == 0) revert AmountZero();

        IRiskModule.WithdrawPreview memory preview = _riskModule.previewWithdrawImpact(msg.sender, token, amount);

        if (amount > preview.maxWithdrawable) revert WithdrawTooLarge();
        if (preview.marginRatioAfterBps < liquidationThresholdBps) revert WithdrawWouldBreachMargin();

        (bool ok,) =
            address(_collateralVault).call(abi.encodeWithSignature("withdrawFor(address,address,uint256)", msg.sender, token, amount));
        if (!ok) revert VaultWithdrawForNotSupported();

        emit CollateralWithdrawn(msg.sender, token, amount, preview.marginRatioAfterBps);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mulChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        c = a * b;
        if (c / a != b) revert MathOverflow();
    }

    function _addChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        if (c < a) revert MathOverflow();
    }

    function _ensureQtyAllowed(int128 q) internal pure {
        if (q == type(int128).min) revert QuantityMinNotAllowed();
    }

    function _toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert QuantityTooLarge();
        return int128(int256(uint256(x)));
    }

    function _checkedAddInt128(int128 a, int128 b) internal pure returns (int128 r) {
        int256 rr = int256(a) + int256(b);
        if (rr > INT128_MAX || rr < INT128_MIN || rr == INT128_MIN) revert QuantityTooLarge();
        r = int128(rr);
        _ensureQtyAllowed(r);
    }

    function _checkedSubInt128(int128 a, int128 b) internal pure returns (int128 r) {
        int256 rr = int256(a) - int256(b);
        if (rr > INT128_MAX || rr < INT128_MIN || rr == INT128_MIN) revert QuantityTooLarge();
        r = int128(rr);
        _ensureQtyAllowed(r);
    }

    function _absInt128(int128 x) internal pure returns (uint256) {
        if (x == type(int128).min) revert QuantityMinNotAllowed();
        int256 y = int256(x);
        return uint256(y >= 0 ? y : -y);
    }

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert MathOverflow();
        return 10 ** exp;
    }

    /// @dev Enforce contractSize1e8 == 1e8 (fixed contract sizing).
    function _requireStandardContractSize(OptionProductRegistry.OptionSeries memory s) internal pure {
        if (s.contractSize1e8 != uint128(PRICE_1E8)) revert InvalidContractSize();
    }

    /// @dev Close-only strict:
    ///  - old == 0  => new must be 0 (no opening)
    ///  - new == 0  => ok (closing)
    ///  - sign must stay identical AND abs must not increase (no flip)
    function _isCloseOnlyTransition(int128 oldQty, int128 newQty) internal pure returns (bool) {
        _ensureQtyAllowed(oldQty);
        _ensureQtyAllowed(newQty);

        if (oldQty == 0) return newQty == 0;
        if (newQty == 0) return true;

        bool oldPos = oldQty > 0;
        bool newPos = newQty > 0;
        if (oldPos != newPos) return false;

        return _absInt128(newQty) <= _absInt128(oldQty);
    }

    function _enforceInitialMargin(address trader) internal view {
        IRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        // (si initialMargin dépassait int256.max => déploiement incohérent)
        if (r.initialMargin > uint256(type(int256).max)) revert MathOverflow();
        if (r.equity < int256(r.initialMargin)) revert MarginRequirementBreached(trader);
    }

    function _addOpenSeries(address trader, uint256 optionId) internal {
        if (traderSeriesIndexPlus1[trader][optionId] != 0) return;
        traderSeries[trader].push(optionId);
        traderSeriesIndexPlus1[trader][optionId] = traderSeries[trader].length;
    }

    function _removeOpenSeries(address trader, uint256 optionId) internal {
        uint256 idxPlus1 = traderSeriesIndexPlus1[trader][optionId];
        if (idxPlus1 == 0) return;

        uint256 idx = idxPlus1 - 1;
        uint256 lastIdx = traderSeries[trader].length - 1;

        if (idx != lastIdx) {
            uint256 lastId = traderSeries[trader][lastIdx];
            traderSeries[trader][idx] = lastId;
            traderSeriesIndexPlus1[trader][lastId] = idx + 1;
        }

        traderSeries[trader].pop();
        traderSeriesIndexPlus1[trader][optionId] = 0;
    }

    function _updateOpenSeriesOnChange(address trader, uint256 optionId, int128 oldQty, int128 newQty) internal {
        _ensureQtyAllowed(oldQty);
        _ensureQtyAllowed(newQty);

        if (oldQty == 0 && newQty != 0) {
            _addOpenSeries(trader, optionId);
        } else if (oldQty != 0 && newQty == 0) {
            _removeOpenSeries(trader, optionId);
        }
    }

    function _updateTotalShortContracts(address trader, int128 oldQty, int128 newQty) internal {
        _ensureQtyAllowed(oldQty);
        _ensureQtyAllowed(newQty);

        uint256 oldShort = oldQty < 0 ? uint256(-int256(oldQty)) : 0;
        uint256 newShort = newQty < 0 ? uint256(-int256(newQty)) : 0;

        if (newShort >= oldShort) totalShortContracts[trader] += (newShort - oldShort);
        else totalShortContracts[trader] -= (oldShort - newShort);
    }

    function _vaultCfg(address token) internal view returns (CollateralVault.CollateralTokenConfig memory cfg) {
        cfg = _collateralVault.getCollateralConfig(token);
    }

    function _requireSettlementAssetConfigured(address settlementAsset) internal view {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);
    }

    function _price1e8ToSettlementUnits(address settlementAsset, uint256 value1e8) internal view returns (uint256 valueNative) {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);

        uint256 scale = _pow10(uint256(cfg.decimals));
        valueNative = Math.mulDiv(value1e8, scale, PRICE_1E8, Math.Rounding.Down);
    }

    function _intrinsic1e8(OptionProductRegistry.OptionSeries memory s, uint256 spot1e8) internal pure returns (uint256 intrinsic) {
        if (spot1e8 == 0) return 0;

        if (s.isCall) {
            intrinsic = spot1e8 > uint256(s.strike) ? (spot1e8 - uint256(s.strike)) : 0;
        } else {
            intrinsic = uint256(s.strike) > spot1e8 ? (uint256(s.strike) - spot1e8) : 0;
        }
    }

    function _requireBaseConfigured() internal view {
        if (baseCollateralToken == address(0)) revert NoBaseCollateral();
        _requireSettlementAssetConfigured(baseCollateralToken);
    }

    function _requireRiskParamsSynced() internal view {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        IRiskModuleParams rp = IRiskModuleParams(address(_riskModule));
        if (rp.baseCollateralToken() != baseCollateralToken) revert RiskParamsMismatch();
        if (rp.baseMaintenanceMarginPerContract() != baseMaintenanceMarginPerContract) revert RiskParamsMismatch();
        if (rp.imFactorBps() != imFactorBps) revert RiskParamsMismatch();
    }

    function _marginRatioBpsFromRisk(IRiskModule.AccountRisk memory risk) internal pure returns (uint256) {
        if (risk.maintenanceMargin == 0) return type(uint256).max;
        if (risk.equity <= 0) return 0;
        return (uint256(risk.equity) * BPS) / risk.maintenanceMargin;
    }

    function _getOraclePriceChecked(address base, address quote) internal view returns (uint256 p) {
        (uint256 px, uint256 updatedAt) = _oracle.getPrice(base, quote);
        if (px == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > maxDelay) revert OraclePriceStale();
        }
        return px;
    }

    function _syncVaultBestEffort(address user, address token) internal {
        // Ne dépend pas de l'ABI compile-time de CollateralVault (best effort).
        (bool ok,) = address(_collateralVault).call(abi.encodeWithSignature("syncAccountFor(address,address)", user, token));
        ok;
    }

    /// @dev Convertit une valeur "base token units" en amount de `token` (token units) arrondi UP (conservateur).
    ///      Utilise oracle.getPrice(token, base) (1e8). Si oracle indispo/stale => (0,false).
    function _baseValueToTokenAmountUp(address token, uint256 baseValue) internal view returns (uint256 amtToken, bool ok) {
        if (baseValue == 0) return (0, true);
        if (token == address(0)) return (0, false);

        if (token == baseCollateralToken) {
            return (baseValue, true);
        }

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) return (0, false);
        if (!tokCfg.isSupported || tokCfg.decimals == 0) return (0, false);
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(baseCollateralToken);
        if (uint256(tokCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint256 px;
        uint256 updatedAt;
        try _oracle.getPrice(token, baseCollateralToken) returns (uint256 _p, uint256 _u) {
            px = _p;
            updatedAt = _u;
        } catch {
            return (0, false);
        }
        if (px == 0) return (0, false);

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) return (0, false);
            if (updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > maxDelay) return (0, false);
        }

        uint8 baseDec = baseCfg.decimals;
        uint8 tokDec = tokCfg.decimals;

        // Step 1 (same decimals): ceil(baseValue * 1e8 / px)
        uint256 sameDec = Math.mulDiv(baseValue, PRICE_1E8, px, Math.Rounding.Ceil);

        if (tokDec == baseDec) {
            return (sameDec, true);
        }

        if (tokDec > baseDec) {
            uint256 factor = _pow10(uint256(tokDec - baseDec));
            amtToken = _mulChecked(sameDec, factor);
            return (amtToken, true);
        } else {
            uint256 factor = _pow10(uint256(baseDec - tokDec));
            amtToken = (sameDec + (factor - 1)) / factor;
            return (amtToken, true);
        }
    }

    /// @dev Approx base value (DOWN) de `tokenAmount` à un prix `pxTokBase` (token->base, 1e8).
    function _tokenAmountToBaseValueDown(address token, uint256 tokenAmount, uint256 pxTokBase)
        internal
        view
        returns (uint256 baseValue)
    {
        if (tokenAmount == 0) return 0;
        if (token == baseCollateralToken) return tokenAmount;

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokDec = tokCfg.decimals;

        // num = tokenAmount * px / 1e8 (still scaled by token decimals vs base decimals)
        uint256 num = Math.mulDiv(tokenAmount, pxTokBase, PRICE_1E8, Math.Rounding.Down);

        if (tokDec == baseDec) return num;

        if (baseDec > tokDec) {
            uint256 factor = _pow10(uint256(baseDec - tokDec));
            return _mulChecked(num, factor);
        } else {
            uint256 factor = _pow10(uint256(tokDec - baseDec));
            return num / factor;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              CORE LOGIC (TRADING)
    //////////////////////////////////////////////////////////////*/

    function applyTrade(IMarginEngineTrade.Trade calldata t)
        external
        override
        onlyMatchingEngine
        whenNotPaused
        nonReentrant
    {
        if (t.buyer == address(0) || t.seller == address(0) || t.buyer == t.seller || t.quantity == 0 || t.price == 0) {
            revert InvalidTrade();
        }

        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        _requireBaseConfigured();
        _requireRiskParamsSynced();

        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(t.optionId);
        _requireStandardContractSize(series);

        if (block.timestamp >= series.expiry) revert SeriesExpired();

        // settlement asset must be supported by vault (premium + payoff ledger)
        _requireSettlementAssetConfigured(series.settlementAsset);

        IMarginEngineState.Position storage buyerPos = _positions[t.buyer][t.optionId];
        IMarginEngineState.Position storage sellerPos = _positions[t.seller][t.optionId];

        int128 oldBuyerQty = buyerPos.quantity;
        int128 oldSellerQty = sellerPos.quantity;

        _ensureQtyAllowed(oldBuyerQty);
        _ensureQtyAllowed(oldSellerQty);

        int128 delta = _toInt128(t.quantity);

        int128 newBuyerQty = _checkedAddInt128(oldBuyerQty, delta);
        int128 newSellerQty = _checkedSubInt128(oldSellerQty, delta);

        if (!series.isActive) {
            bool okBuyer = _isCloseOnlyTransition(oldBuyerQty, newBuyerQty);
            bool okSeller = _isCloseOnlyTransition(oldSellerQty, newSellerQty);
            if (!okBuyer || !okSeller) revert SeriesNotActiveCloseOnly();
        }

        buyerPos.quantity = newBuyerQty;
        sellerPos.quantity = newSellerQty;

        _updateTotalShortContracts(t.buyer, oldBuyerQty, newBuyerQty);
        _updateTotalShortContracts(t.seller, oldSellerQty, newSellerQty);

        _updateOpenSeriesOnChange(t.buyer, t.optionId, oldBuyerQty, newBuyerQty);
        _updateOpenSeriesOnChange(t.seller, t.optionId, oldSellerQty, newSellerQty);

        // premium cashflow in settlement asset native units
        uint256 cashAmount = _mulChecked(uint256(t.quantity), uint256(t.price));
        _collateralVault.transferBetweenAccounts(series.settlementAsset, t.buyer, t.seller, cashAmount);

        emit TradeExecuted(t.buyer, t.seller, t.optionId, t.quantity, t.price);

        _enforceInitialMargin(t.buyer);
        _enforceInitialMargin(t.seller);
    }

    /*//////////////////////////////////////////////////////////////
                    PAYOFF & PnL HELPERS (SETTLEMENT)
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns settlement units per contract.
    function _computePerContractPayoff(OptionProductRegistry.OptionSeries memory series, uint256 settlementPrice)
        internal
        view
        returns (uint256 payoffPerContract)
    {
        _requireStandardContractSize(series);
        if (settlementPrice == 0) return 0;

        uint256 intrinsicPrice1e8;
        if (series.isCall) {
            intrinsicPrice1e8 = settlementPrice > uint256(series.strike) ? (settlementPrice - uint256(series.strike)) : 0;
        } else {
            intrinsicPrice1e8 = uint256(series.strike) > settlementPrice ? (uint256(series.strike) - settlementPrice) : 0;
        }

        if (intrinsicPrice1e8 == 0) return 0;

        payoffPerContract = _price1e8ToSettlementUnits(series.settlementAsset, intrinsicPrice1e8);
    }

    function _settleAccount(uint256 optionId, address trader) internal {
        if (trader == address(0)) revert ZeroAddress();
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();

        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        _requireStandardContractSize(series);

        if (block.timestamp < series.expiry) revert NotExpired();

        (uint256 settlementPrice, bool isSet) = _optionRegistry.getSettlementInfo(optionId);
        if (!isSet || settlementPrice == 0) revert SettlementNotSet();

        _requireSettlementAssetConfigured(series.settlementAsset);

        if (isAccountSettled[optionId][trader]) revert SettlementAlreadyProcessed();
        isAccountSettled[optionId][trader] = true;

        IMarginEngineState.Position storage pos = _positions[trader][optionId];
        int128 oldQty = pos.quantity;

        _ensureQtyAllowed(oldQty);

        if (oldQty == 0) {
            emit AccountSettled(trader, optionId, 0, 0, 0, 0);
            return;
        }

        uint256 payoffPerContract = _computePerContractPayoff(series, settlementPrice);

        int256 pnl;
        if (payoffPerContract == 0) {
            pnl = 0;
        } else {
            int256 q = int256(oldQty);
            uint256 absQty = q >= 0 ? uint256(q) : uint256(-q);

            uint256 amount = _mulChecked(absQty, payoffPerContract);
            if (amount > uint256(type(int256).max)) revert PnlOverflow();

            pnl = q >= 0 ? int256(amount) : -int256(amount);
        }

        // close
        pos.quantity = 0;
        _updateTotalShortContracts(trader, oldQty, 0);
        _updateOpenSeriesOnChange(trader, optionId, oldQty, 0);

        uint256 collectedFromTrader = 0;
        uint256 paidToTrader = 0;
        uint256 badDebt = 0;

        address asset = series.settlementAsset;

        // best-effort sync (yield)
        _syncVaultBestEffort(trader, asset);
        _syncVaultBestEffort(insuranceFund, asset);

        if (pnl > 0) {
            uint256 amountPay = uint256(pnl);

            uint256 fundBal = _collateralVault.balances(insuranceFund, asset);
            if (fundBal < amountPay) revert InsuranceFundInsufficient(amountPay, fundBal);

            _collateralVault.transferBetweenAccounts(asset, insuranceFund, trader, amountPay);

            paidToTrader = amountPay;
            seriesPaid[optionId] += amountPay;
        } else if (pnl < 0) {
            uint256 amountOwed = uint256(-pnl);

            uint256 traderBal = _collateralVault.balances(trader, asset);
            uint256 amountToCollect = traderBal >= amountOwed ? amountOwed : traderBal;

            if (amountToCollect > 0) {
                _collateralVault.transferBetweenAccounts(asset, trader, insuranceFund, amountToCollect);
                collectedFromTrader = amountToCollect;
                seriesCollected[optionId] += amountToCollect;
            }

            if (amountToCollect < amountOwed) {
                badDebt = amountOwed - amountToCollect;
                seriesBadDebt[optionId] += badDebt;
            }
        }

        emit AccountSettled(trader, optionId, pnl, collectedFromTrader, paidToTrader, badDebt);

        emit SeriesSettlementAccountingUpdated(optionId, seriesCollected[optionId], seriesPaid[optionId], seriesBadDebt[optionId]);
    }

    function settleAccount(uint256 optionId, address trader) public whenNotPaused nonReentrant {
        _settleAccount(optionId, trader);
    }

    function settleAccounts(uint256 optionId, address[] calldata traders) external whenNotPaused nonReentrant {
        uint256 len = traders.length;
        for (uint256 i = 0; i < len; i++) {
            _settleAccount(optionId, traders[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION LOGIC (A-1)
    //////////////////////////////////////////////////////////////*/

    function getMarginRatioBps(address trader) public view returns (uint256) {
        if (address(_riskModule) == address(0)) return type(uint256).max;
        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromRisk(risk);
    }

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(_riskModule) == address(0)) return false;

        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        if (risk.maintenanceMargin == 0) return false;
        if (risk.equity <= 0) return true;

        uint256 ratioBps = (uint256(risk.equity) * BPS) / risk.maintenanceMargin;
        return ratioBps < liquidationThresholdBps;
    }

    /// @dev Returns settlement units per contract.
    function _computeLiquidationPricePerContract(OptionProductRegistry.OptionSeries memory s) internal view returns (uint256 pricePerContract) {
        _requireStandardContractSize(s);

        (uint256 spot, uint256 updatedAt) = _oracle.getPrice(s.underlying, s.settlementAsset);
        if (spot == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > maxDelay) revert OraclePriceStale();
        }

        uint256 intrinsicPrice1e8 = _intrinsic1e8(s, spot);
        uint256 liqPrice1e8 = intrinsicPrice1e8;

        if (intrinsicPrice1e8 > 0 && minLiquidationPriceBpsOfIntrinsic > 0) {
            uint256 floorPx = (intrinsicPrice1e8 * minLiquidationPriceBpsOfIntrinsic) / BPS;
            if (liqPrice1e8 < floorPx) liqPrice1e8 = floorPx;
        }

        if (liquidationPriceSpreadBps > 0) {
            liqPrice1e8 = (liqPrice1e8 * (BPS + liquidationPriceSpreadBps)) / BPS;
        }

        pricePerContract = _price1e8ToSettlementUnits(s.settlementAsset, liqPrice1e8);
    }

    function liquidate(address trader, uint256[] calldata optionIds, uint128[] calldata quantities)
        external
        whenNotPaused
        nonReentrant
    {
        if (trader == address(0)) revert ZeroAddress();
        if (trader == msg.sender) revert InvalidTrade();
        if (optionIds.length == 0 || optionIds.length != quantities.length) revert LengthMismatch();
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        if (liquidationCloseFactorBps == 0) revert LiquidationCloseFactorZero();

        _requireBaseConfigured();
        _requireRiskParamsSynced();

        IRiskModule.AccountRisk memory riskBefore = _riskModule.computeAccountRisk(trader);
        uint256 ratioBeforeBps = _marginRatioBpsFromRisk(riskBefore);

        if (!isLiquidatable(trader)) revert NotLiquidatable();

        uint256 traderTotalShort = totalShortContracts[trader];
        if (traderTotalShort == 0) revert NotLiquidatable();

        uint256 maxCloseOverall = (traderTotalShort * liquidationCloseFactorBps) / BPS;
        if (maxCloseOverall == 0) maxCloseOverall = 1;

        address liquidator = msg.sender;
        uint256 totalContractsClosed;

        // precise executed quantities for event
        uint128[] memory executed = new uint128[](optionIds.length);

        // track per settlement asset cash requested
        address[] memory cashAssets = new address[](optionIds.length);
        uint256[] memory cashRequested = new uint256[](optionIds.length);
        uint256 assetsCount;

        // for penalty fallback seize: track distinct settlement assets touched
        address[] memory touchedAssets = new address[](optionIds.length);
        uint256 touchedCount;

        for (uint256 i = 0; i < optionIds.length; i++) {
            if (totalContractsClosed >= maxCloseOverall) break;

            uint256 optionId = optionIds[i];
            uint128 requestedQty = quantities[i];
            if (requestedQty == 0) continue;

            OptionProductRegistry.OptionSeries memory s = _optionRegistry.getSeries(optionId);
            _requireStandardContractSize(s);

            if (block.timestamp >= s.expiry) continue;

            _requireSettlementAssetConfigured(s.settlementAsset);

            IMarginEngineState.Position storage traderPos = _positions[trader][optionId];
            if (traderPos.quantity >= 0) continue;

            IMarginEngineState.Position storage liqPos = _positions[liquidator][optionId];

            int128 oldTraderQty = traderPos.quantity;
            int128 oldLiqQty = liqPos.quantity;

            _ensureQtyAllowed(oldTraderQty);
            _ensureQtyAllowed(oldLiqQty);

            uint256 traderShortAbs = uint256(-int256(oldTraderQty));
            uint256 remainingAllowance = maxCloseOverall - totalContractsClosed;

            uint256 liqQtyU = uint256(requestedQty);
            if (liqQtyU > traderShortAbs) liqQtyU = traderShortAbs;
            if (liqQtyU > remainingAllowance) liqQtyU = remainingAllowance;
            if (liqQtyU == 0) continue;

            if (liqQtyU > uint256(uint128(type(int128).max))) revert QuantityTooLarge();
            uint128 liqQty = uint128(liqQtyU);
            int128 delta = _toInt128(liqQty);

            uint256 liqPricePerContract = _computeLiquidationPricePerContract(s);
            uint256 req = _mulChecked(liqPricePerContract, uint256(liqQty));

            // accumulate req per settlementAsset
            {
                bool found;
                for (uint256 k = 0; k < assetsCount; k++) {
                    if (cashAssets[k] == s.settlementAsset) {
                        cashRequested[k] = _addChecked(cashRequested[k], req);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    cashAssets[assetsCount] = s.settlementAsset;
                    cashRequested[assetsCount] = req;
                    assetsCount++;
                }
            }

            // track touched assets unique (for penalty seize fallback)
            {
                bool tfound;
                for (uint256 k2 = 0; k2 < touchedCount; k2++) {
                    if (touchedAssets[k2] == s.settlementAsset) {
                        tfound = true;
                        break;
                    }
                }
                if (!tfound) {
                    touchedAssets[touchedCount] = s.settlementAsset;
                    touchedCount++;
                }
            }

            // position transfer: trader short reduced, liquidator short increased
            traderPos.quantity = _checkedAddInt128(oldTraderQty, delta);
            liqPos.quantity = _checkedSubInt128(oldLiqQty, delta);

            int128 newTraderQty = traderPos.quantity;
            int128 newLiqQty = liqPos.quantity;

            _updateTotalShortContracts(trader, oldTraderQty, newTraderQty);
            _updateTotalShortContracts(liquidator, oldLiqQty, newLiqQty);

            _updateOpenSeriesOnChange(trader, optionId, oldTraderQty, newTraderQty);
            _updateOpenSeriesOnChange(liquidator, optionId, oldLiqQty, newLiqQty);

            executed[i] = liqQty;
            totalContractsClosed += uint256(liqQty);
        }

        if (totalContractsClosed == 0) revert LiquidationNothingToDo();

        // cashflow: per settlement asset, pay min(balance, requested)
        for (uint256 i = 0; i < assetsCount; i++) {
            address asset = cashAssets[i];
            uint256 req = cashRequested[i];
            if (req == 0) continue;

            _syncVaultBestEffort(trader, asset);

            uint256 traderBal = _collateralVault.balances(trader, asset);
            uint256 paid = req <= traderBal ? req : traderBal;

            if (paid > 0) {
                _collateralVault.transferBetweenAccounts(asset, trader, liquidator, paid);
            }

            emit LiquidationCashflow(liquidator, trader, asset, paid, req);
        }

        // penalty = MM_floor(base) * closedContracts * penaltyBps
        uint256 mmBase = _mulChecked(baseMaintenanceMarginPerContract, totalContractsClosed);
        uint256 penaltyBaseValue = Math.mulDiv(mmBase, liquidationPenaltyBps, BPS, Math.Rounding.Down);

        uint256 remainingBase = penaltyBaseValue;
        uint256 seizedBaseValueTotal = 0;

        // 1) seize in base token first
        if (remainingBase > 0) {
            _syncVaultBestEffort(trader, baseCollateralToken);

            uint256 balBase = _collateralVault.balances(trader, baseCollateralToken);
            uint256 seizeBaseTokenAmt = remainingBase <= balBase ? remainingBase : balBase;

            if (seizeBaseTokenAmt > 0) {
                _collateralVault.transferBetweenAccounts(baseCollateralToken, trader, liquidator, seizeBaseTokenAmt);
                seizedBaseValueTotal += seizeBaseTokenAmt;
                remainingBase -= seizeBaseTokenAmt;

                emit LiquidationSeize(liquidator, trader, baseCollateralToken, seizeBaseTokenAmt, seizeBaseTokenAmt);
            }
        }

        // 2) fallback: seize remaining penalty value using settlement assets touched (if oracle ok)
        if (remainingBase > 0) {
            for (uint256 i = 0; i < touchedCount; i++) {
                if (remainingBase == 0) break;

                address tok = touchedAssets[i];
                if (tok == address(0) || tok == baseCollateralToken) continue;

                CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(tok);
                if (!cfg.isSupported || cfg.decimals == 0) continue;

                _syncVaultBestEffort(trader, tok);

                (uint256 neededTok, bool ok) = _baseValueToTokenAmountUp(tok, remainingBase);
                if (!ok || neededTok == 0) continue;

                uint256 balTok = _collateralVault.balances(trader, tok);
                uint256 seizeTok = neededTok <= balTok ? neededTok : balTok;
                if (seizeTok == 0) continue;

                uint256 pxTokBase = _getOraclePriceChecked(tok, baseCollateralToken);
                uint256 seizedBaseValueApprox = _tokenAmountToBaseValueDown(tok, seizeTok, pxTokBase);

                _collateralVault.transferBetweenAccounts(tok, trader, liquidator, seizeTok);

                uint256 applied = seizedBaseValueApprox <= remainingBase ? seizedBaseValueApprox : remainingBase;
                seizedBaseValueTotal += applied;
                remainingBase -= applied;

                emit LiquidationSeize(liquidator, trader, tok, seizeTok, applied);
            }
        }

        // post-check improvement
        IRiskModule.AccountRisk memory riskAfter = _riskModule.computeAccountRisk(trader);
        uint256 ratioAfterBps = _marginRatioBpsFromRisk(riskAfter);

        if (riskBefore.equity > 0) {
            if (ratioAfterBps < ratioBeforeBps + minLiquidationImprovementBps) revert LiquidationNotImproving();
        } else {
            bool improved = (riskAfter.maintenanceMargin < riskBefore.maintenanceMargin) || (riskAfter.equity > riskBefore.equity);
            if (!improved) revert LiquidationNotImproving();
        }

        emit Liquidation(liquidator, trader, optionIds, executed, seizedBaseValueTotal);

        _enforceInitialMargin(liquidator);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(uint256 optionId) external view returns (uint256 price, uint256 updatedAt) {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        _requireStandardContractSize(series);
        return _oracle.getPrice(series.underlying, series.settlementAsset);
    }
}
