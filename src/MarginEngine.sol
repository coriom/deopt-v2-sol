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
/// @dev Toute la logique de risque (equity / IM / MM) est déléguée au RiskModule (IRiskModule).
contract MarginEngine is ReentrancyGuard, IMarginEngineState, IMarginEngineTrade {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant BPS = 10_000;
    uint256 private constant PRICE_1E8 = 1e8;

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
    error NotShortPosition();
    error NoBaseCollateral();
    error RiskModuleNotSet();
    error AmountZero();
    error PausedError();

    // Series / trading
    error SeriesExpired();
    error BadSettlementAsset();
    error SeriesNotActiveCloseOnly();

    // Expiration / payoff
    error NotExpired();
    error SettlementNotSet();
    error SettlementAlreadyProcessed();
    error SettlementAssetNotConfigured();
    error InsuranceFundNotSet();
    error InsuranceFundInsufficient();

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

    event RiskParamsSet(
        address baseCollateralToken,
        uint256 baseMaintenanceMarginPerContract,
        uint256 imFactorBps
    );

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event OracleSet(address indexed newOracle);
    event RiskModuleSet(address indexed newRiskModule);

    event LiquidationParamsSet(
        uint256 liquidationThresholdBps,
        uint256 liquidationPenaltyBps
    );

    event LiquidationHardenParamsSet(
        uint256 liquidationCloseFactorBps,
        uint256 minLiquidationImprovementBps
    );

    event LiquidationPricingParamsSet(
        uint256 liquidationPriceSpreadBps,
        uint256 minLiquidationPriceBpsOfIntrinsic
    );

    /// @notice Fraîcheur minimale exigée côté liquidation (en secondes). 0 = désactivé.
    event LiquidationOracleMaxDelaySet(uint32 oldDelay, uint32 newDelay);

    event Liquidation(
        address indexed liquidator,
        address indexed trader,
        uint256[] optionIds,
        uint128[] quantities,
        uint256 collateralSeized
    );

    event LiquidationCashflow(
        address indexed liquidator,
        address indexed trader,
        address indexed settlementAsset,
        uint256 cashPaidByTrader,
        uint256 cashRequested
    );

    event CollateralDeposited(address indexed trader, address indexed token, uint256 amount);

    event CollateralWithdrawn(
        address indexed trader,
        address indexed token,
        uint256 amount,
        uint256 marginRatioAfterBps
    );

    event InsuranceFundSet(address indexed oldFund, address indexed newFund);

    event AccountSettled(
        address indexed trader,
        uint256 indexed optionId,
        int256 pnl,
        uint256 collectedFromTrader,
        uint256 paidToTrader,
        uint256 badDebt
    );

    event SeriesSettlementAccountingUpdated(
        uint256 indexed optionId,
        uint256 totalCollected,
        uint256 totalPaid,
        uint256 totalBadDebt
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public matchingEngine;

    OptionProductRegistry public optionRegistry;
    CollateralVault public collateralVault;
    IOracle public oracle;
    IRiskModule public riskModule;

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

    // ===================== Settlement (claim-based) =====================

    address public insuranceFund;

    mapping(uint256 => mapping(address => bool)) public isAccountSettled;

    mapping(uint256 => uint256) public seriesCollected;
    mapping(uint256 => uint256) public seriesPaid;
    mapping(uint256 => uint256) public seriesBadDebt;

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

    constructor(address _owner, address _registry, address _vault, address _oracle) {
        if (
            _owner == address(0) ||
            _registry == address(0) ||
            _vault == address(0) ||
            _oracle == address(0)
        ) revert ZeroAddress();

        owner = _owner;
        optionRegistry = OptionProductRegistry(_registry);
        collateralVault = CollateralVault(_vault);
        oracle = IOracle(_oracle);

        emit OwnershipTransferred(address(0), _owner);
        emit OracleSet(_oracle);

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

    function setMatchingEngine(address _matchingEngine) external onlyOwner {
        if (_matchingEngine == address(0)) revert ZeroAddress();
        matchingEngine = _matchingEngine;
        emit MatchingEngineSet(_matchingEngine);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = IOracle(_oracle);
        emit OracleSet(_oracle);
    }

    function setRiskModule(address _riskModule) external onlyOwner {
        if (_riskModule == address(0)) revert ZeroAddress();
        riskModule = IRiskModule(_riskModule);
        emit RiskModuleSet(_riskModule);
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        if (_insuranceFund == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = _insuranceFund;
        emit InsuranceFundSet(old, _insuranceFund);
    }

    function setRiskParams(
        address _baseToken,
        uint256 _baseMMPerContract,
        uint256 _imFactorBps
    ) external onlyOwner {
        if (_baseToken == address(0)) revert ZeroAddress();
        if (_imFactorBps < BPS) revert InvalidLiquidationParams();

        baseCollateralToken = _baseToken;
        baseMaintenanceMarginPerContract = _baseMMPerContract;
        imFactorBps = _imFactorBps;

        emit RiskParamsSet(_baseToken, _baseMMPerContract, _imFactorBps);
    }

    function setLiquidationParams(
        uint256 _liquidationThresholdBps,
        uint256 _liquidationPenaltyBps
    ) external onlyOwner {
        if (_liquidationThresholdBps < BPS) revert InvalidLiquidationParams();
        if (_liquidationPenaltyBps > BPS) revert InvalidLiquidationParams();

        liquidationThresholdBps = _liquidationThresholdBps;
        liquidationPenaltyBps = _liquidationPenaltyBps;

        emit LiquidationParamsSet(_liquidationThresholdBps, _liquidationPenaltyBps);
    }

    function setLiquidationHardenParams(
        uint256 _closeFactorBps,
        uint256 _minImprovementBps
    ) external onlyOwner {
        if (_closeFactorBps == 0) revert LiquidationCloseFactorZero();
        if (_closeFactorBps > BPS) revert InvalidLiquidationParams();

        minLiquidationImprovementBps = _minImprovementBps;
        liquidationCloseFactorBps = _closeFactorBps;

        emit LiquidationHardenParamsSet(_closeFactorBps, _minImprovementBps);
    }

    function setLiquidationPricingParams(
        uint256 _liquidationPriceSpreadBps,
        uint256 _minLiquidationPriceBpsOfIntrinsic
    ) external onlyOwner {
        if (_liquidationPriceSpreadBps > BPS) revert LiquidationPricingParamsInvalid();
        if (_minLiquidationPriceBpsOfIntrinsic > BPS) revert LiquidationPricingParamsInvalid();

        liquidationPriceSpreadBps = _liquidationPriceSpreadBps;
        minLiquidationPriceBpsOfIntrinsic = _minLiquidationPriceBpsOfIntrinsic;

        emit LiquidationPricingParamsSet(
            _liquidationPriceSpreadBps,
            _minLiquidationPriceBpsOfIntrinsic
        );
    }

    function setLiquidationOracleMaxDelay(uint32 _delay) external onlyOwner {
        if (_delay > 3600) revert LiquidationPricingParamsInvalid();
        uint32 old = liquidationOracleMaxDelay;
        liquidationOracleMaxDelay = _delay;
        emit LiquidationOracleMaxDelaySet(old, _delay);
    }

    /*//////////////////////////////////////////////////////////////
                              IMarginEngineState
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 optionId)
        external
        view
        override
        returns (IMarginEngineState.Position memory)
    {
        return _positions[trader][optionId];
    }

    /// @notice OPEN series only (positions non nulles)
    function getTraderSeries(address trader)
        external
        view
        override
        returns (uint256[] memory)
    {
        return traderSeries[trader];
    }

    function getTraderSeriesLength(address trader)
        external
        view
        override
        returns (uint256)
    {
        return traderSeries[trader].length;
    }

    function getTraderSeriesSlice(
        address trader,
        uint256 start,
        uint256 end
    ) external view override returns (uint256[] memory slice) {
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
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader)
        external
        view
        returns (IRiskModule.AccountRisk memory risk)
    {
        if (address(riskModule) == address(0)) {
            IRiskModule.AccountRisk memory empty;
            return empty;
        }
        return riskModule.computeAccountRisk(trader);
    }

    function getFreeCollateral(address trader) external view returns (int256) {
        if (address(riskModule) == address(0)) return 0;
        return riskModule.computeFreeCollateral(trader);
    }

    function previewWithdrawImpact(
        address trader,
        address token,
        uint256 amount
    ) external view returns (IRiskModule.WithdrawPreview memory preview) {
        if (address(riskModule) == address(0)) return preview;
        return riskModule.previewWithdrawImpact(trader, token, amount);
    }

    function isSeriesExpired(uint256 optionId) public view returns (bool) {
        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(optionId);
        return block.timestamp >= series.expiry;
    }

    /*//////////////////////////////////////////////////////////////
                        USER COLLATERAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        collateralVault.deposit(token, amount);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (address(riskModule) == address(0)) revert RiskModuleNotSet();
        if (amount == 0) revert AmountZero();

        IRiskModule.WithdrawPreview memory preview =
            riskModule.previewWithdrawImpact(msg.sender, token, amount);

        if (amount > preview.maxWithdrawable) revert WithdrawTooLarge();
        if (preview.marginRatioAfterBps < liquidationThresholdBps) revert WithdrawWouldBreachMargin();

        collateralVault.withdraw(token, amount);

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
        IRiskModule.AccountRisk memory r = riskModule.computeAccountRisk(trader);
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

    function _updateOpenSeriesOnChange(
        address trader,
        uint256 optionId,
        int128 oldQty,
        int128 newQty
    ) internal {
        _ensureQtyAllowed(oldQty);
        _ensureQtyAllowed(newQty);

        if (oldQty == 0 && newQty != 0) {
            _addOpenSeries(trader, optionId);
        } else if (oldQty != 0 && newQty == 0) {
            _removeOpenSeries(trader, optionId);
        }
    }

    function _updateTotalShortContracts(
        address trader,
        int128 oldQty,
        int128 newQty
    ) internal {
        _ensureQtyAllowed(oldQty);
        _ensureQtyAllowed(newQty);

        uint256 oldShort = oldQty < 0 ? uint256(-int256(oldQty)) : 0;
        uint256 newShort = newQty < 0 ? uint256(-int256(newQty)) : 0;

        if (newShort >= oldShort) totalShortContracts[trader] += (newShort - oldShort);
        else totalShortContracts[trader] -= (oldShort - newShort);
    }

    function _requireSettlementAssetConfigured(address settlementAsset) internal view {
        (bool isSupported, uint8 decimals, ) = collateralVault.collateralConfigs(settlementAsset);
        if (!isSupported || decimals == 0) revert SettlementAssetNotConfigured();
    }

    function _price1e8ToSettlementUnits(address settlementAsset, uint256 value1e8)
        internal
        view
        returns (uint256 valueNative)
    {
        (bool isSupported, uint8 decimals, ) = collateralVault.collateralConfigs(settlementAsset);
        if (!isSupported || decimals == 0) revert SettlementAssetNotConfigured();

        uint256 scale = 10 ** uint256(decimals);
        valueNative = Math.mulDiv(value1e8, scale, PRICE_1E8, Math.Rounding.Down);
    }

    function _intrinsic1e8(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8
    ) internal pure returns (uint256 intrinsic) {
        if (spot1e8 == 0) return 0;

        if (s.isCall) {
            if (spot1e8 > uint256(s.strike)) intrinsic = spot1e8 - uint256(s.strike);
            else intrinsic = 0;
        } else {
            if (uint256(s.strike) > spot1e8) intrinsic = uint256(s.strike) - spot1e8;
            else intrinsic = 0;
        }
    }

    /// @dev Returns settlement units per contract (includes contractSize1e8 scaling).
    function _computeLiquidationPricePerContract(
        OptionProductRegistry.OptionSeries memory s
    ) internal view returns (uint256 pricePerContract) {
        (uint256 spot, uint256 updatedAt) = oracle.getPrice(s.underlying, s.settlementAsset);
        if (spot == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (block.timestamp > updatedAt && block.timestamp - updatedAt > maxDelay) {
                revert OraclePriceStale();
            }
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

        uint256 amount1e8 = Math.mulDiv(
            liqPrice1e8,
            uint256(s.contractSize1e8),
            PRICE_1E8,
            Math.Rounding.Ceil
        );

        pricePerContract = _price1e8ToSettlementUnits(s.settlementAsset, amount1e8);
    }

    function _marginRatioBpsFromRisk(IRiskModule.AccountRisk memory risk) internal pure returns (uint256) {
        if (risk.maintenanceMargin == 0) return type(uint256).max;
        if (risk.equity <= 0) return 0;
        return (uint256(risk.equity) * BPS) / risk.maintenanceMargin;
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
        if (
            t.buyer == address(0) ||
            t.seller == address(0) ||
            t.buyer == t.seller ||
            t.quantity == 0 ||
            t.price == 0
        ) revert InvalidTrade();

        if (address(riskModule) == address(0)) revert RiskModuleNotSet();

        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(t.optionId);

        if (block.timestamp >= series.expiry) revert SeriesExpired();

        // Current mode: single settlement asset = baseCollateralToken (liquidation/withdraw logic assumes it).
        if (baseCollateralToken == address(0)) revert NoBaseCollateral();
        if (series.settlementAsset != baseCollateralToken) revert BadSettlementAsset();

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

        uint256 cashAmount = _mulChecked(uint256(t.quantity), uint256(t.price));

        collateralVault.transferBetweenAccounts(
            series.settlementAsset,
            t.buyer,
            t.seller,
            cashAmount
        );

        emit TradeExecuted(t.buyer, t.seller, t.optionId, t.quantity, t.price);

        _enforceInitialMargin(t.buyer);
        _enforceInitialMargin(t.seller);
    }

    /*//////////////////////////////////////////////////////////////
                      PAYOFF & PnL HELPERS (SETTLEMENT)
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns settlement units per contract (includes contractSize1e8 scaling).
    function _computePerContractPayoff(
        OptionProductRegistry.OptionSeries memory series,
        uint256 settlementPrice
    ) internal view returns (uint256 payoffPerContract) {
        if (settlementPrice == 0) return 0;

        uint256 intrinsicPrice1e8;

        if (series.isCall) {
            intrinsicPrice1e8 = settlementPrice > uint256(series.strike)
                ? (settlementPrice - uint256(series.strike))
                : 0;
        } else {
            intrinsicPrice1e8 = uint256(series.strike) > settlementPrice
                ? (uint256(series.strike) - settlementPrice)
                : 0;
        }

        if (intrinsicPrice1e8 == 0) return 0;

        uint256 amount1e8 = Math.mulDiv(
            intrinsicPrice1e8,
            uint256(series.contractSize1e8),
            PRICE_1E8,
            Math.Rounding.Down
        );

        if (amount1e8 == 0) return 0;

        payoffPerContract = _price1e8ToSettlementUnits(series.settlementAsset, amount1e8);
    }

    function _settleAccount(uint256 optionId, address trader) internal {
        if (trader == address(0)) revert ZeroAddress();
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();

        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(optionId);
        if (block.timestamp < series.expiry) revert NotExpired();

        (uint256 settlementPrice, bool isSet) = optionRegistry.getSettlementInfo(optionId);
        if (!isSet || settlementPrice == 0) revert SettlementNotSet();

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

        pos.quantity = 0;

        _updateTotalShortContracts(trader, oldQty, 0);
        _updateOpenSeriesOnChange(trader, optionId, oldQty, 0);

        uint256 collectedFromTrader = 0;
        uint256 paidToTrader = 0;
        uint256 badDebt = 0;

        if (pnl > 0) {
            uint256 amountPay = uint256(pnl);
            uint256 fundBal = collateralVault.balances(insuranceFund, series.settlementAsset);
            if (fundBal < amountPay) revert InsuranceFundInsufficient();

            collateralVault.transferBetweenAccounts(series.settlementAsset, insuranceFund, trader, amountPay);

            paidToTrader = amountPay;
            seriesPaid[optionId] += amountPay;
        } else if (pnl < 0) {
            uint256 amountOwed = uint256(-pnl);

            uint256 traderBal = collateralVault.balances(trader, series.settlementAsset);
            uint256 amountToCollect = traderBal >= amountOwed ? amountOwed : traderBal;

            if (amountToCollect > 0) {
                collateralVault.transferBetweenAccounts(
                    series.settlementAsset,
                    trader,
                    insuranceFund,
                    amountToCollect
                );
                collectedFromTrader = amountToCollect;
                seriesCollected[optionId] += amountToCollect;
            }

            if (amountToCollect < amountOwed) {
                badDebt = amountOwed - amountToCollect;
                seriesBadDebt[optionId] += badDebt;
            }
        }

        emit AccountSettled(trader, optionId, pnl, collectedFromTrader, paidToTrader, badDebt);

        emit SeriesSettlementAccountingUpdated(
            optionId,
            seriesCollected[optionId],
            seriesPaid[optionId],
            seriesBadDebt[optionId]
        );
    }

    function settleAccount(uint256 optionId, address trader) public whenNotPaused nonReentrant {
        _settleAccount(optionId, trader);
    }

    function settleAccounts(uint256 optionId, address[] calldata traders)
        external
        whenNotPaused
        nonReentrant
    {
        uint256 len = traders.length;
        for (uint256 i = 0; i < len; i++) {
            _settleAccount(optionId, traders[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION LOGIC (A-1)
    //////////////////////////////////////////////////////////////*/

    function getMarginRatioBps(address trader) public view returns (uint256) {
        if (address(riskModule) == address(0)) return type(uint256).max;
        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromRisk(risk);
    }

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(riskModule) == address(0)) return false;

        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(trader);
        if (risk.maintenanceMargin == 0) return false;
        if (risk.equity <= 0) return true;

        uint256 ratioBps = (uint256(risk.equity) * BPS) / risk.maintenanceMargin;
        return ratioBps < liquidationThresholdBps;
    }

    function liquidate(
        address trader,
        uint256[] calldata optionIds,
        uint128[] calldata quantities
    ) external whenNotPaused nonReentrant {
        if (trader == address(0)) revert ZeroAddress();
        if (trader == msg.sender) revert InvalidTrade();
        if (optionIds.length == 0 || optionIds.length != quantities.length) revert LengthMismatch();
        if (baseCollateralToken == address(0)) revert NoBaseCollateral();
        if (address(riskModule) == address(0)) revert RiskModuleNotSet();
        if (liquidationCloseFactorBps == 0) revert LiquidationCloseFactorZero();

        IRiskModule.AccountRisk memory riskBefore = riskModule.computeAccountRisk(trader);
        uint256 ratioBeforeBps = _marginRatioBpsFromRisk(riskBefore);

        if (!isLiquidatable(trader)) revert NotLiquidatable();

        uint256 traderTotalShort = totalShortContracts[trader];
        if (traderTotalShort == 0) revert NotLiquidatable();

        uint256 maxCloseOverall = (traderTotalShort * liquidationCloseFactorBps) / BPS;
        if (maxCloseOverall == 0) maxCloseOverall = 1;

        address liquidator = msg.sender;
        uint256 totalContractsClosed;

        uint256 totalCashRequested;
        address settlementAsset = baseCollateralToken;

        _requireSettlementAssetConfigured(settlementAsset);

        for (uint256 i = 0; i < optionIds.length; i++) {
            if (totalContractsClosed >= maxCloseOverall) break;

            uint256 optionId = optionIds[i];
            uint128 requestedQty = quantities[i];
            if (requestedQty == 0) continue;

            OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);

            if (block.timestamp >= s.expiry) continue;
            if (s.settlementAsset != baseCollateralToken) continue;

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
            totalCashRequested = _addChecked(
                totalCashRequested,
                _mulChecked(liqPricePerContract, uint256(liqQty))
            );

            traderPos.quantity = _checkedAddInt128(oldTraderQty, delta);
            liqPos.quantity = _checkedSubInt128(oldLiqQty, delta);

            int128 newTraderQty = traderPos.quantity;
            int128 newLiqQty = liqPos.quantity;

            _updateTotalShortContracts(trader, oldTraderQty, newTraderQty);
            _updateTotalShortContracts(liquidator, oldLiqQty, newLiqQty);

            _updateOpenSeriesOnChange(trader, optionId, oldTraderQty, newTraderQty);
            _updateOpenSeriesOnChange(liquidator, optionId, oldLiqQty, newLiqQty);

            totalContractsClosed += uint256(liqQty);
        }

        if (totalContractsClosed == 0) revert LiquidationNothingToDo();

        uint256 traderBalForCash = collateralVault.balances(trader, settlementAsset);
        uint256 cashPaid = totalCashRequested <= traderBalForCash ? totalCashRequested : traderBalForCash;

        if (cashPaid > 0) {
            collateralVault.transferBetweenAccounts(settlementAsset, trader, liquidator, cashPaid);
        }

        emit LiquidationCashflow(liquidator, trader, settlementAsset, cashPaid, totalCashRequested);

        uint256 mmBase = _mulChecked(baseMaintenanceMarginPerContract, totalContractsClosed);
        uint256 penalty = Math.mulDiv(mmBase, liquidationPenaltyBps, BPS, Math.Rounding.Down);

        uint256 traderBal = collateralVault.balances(trader, baseCollateralToken);
        uint256 seized = penalty <= traderBal ? penalty : traderBal;

        if (seized > 0) {
            collateralVault.transferBetweenAccounts(baseCollateralToken, trader, liquidator, seized);
        }

        IRiskModule.AccountRisk memory riskAfter = riskModule.computeAccountRisk(trader);
        uint256 ratioAfterBps = _marginRatioBpsFromRisk(riskAfter);

        if (riskBefore.equity > 0) {
            if (ratioAfterBps < ratioBeforeBps + minLiquidationImprovementBps) revert LiquidationNotImproving();
        } else {
            bool improved =
                (riskAfter.maintenanceMargin < riskBefore.maintenanceMargin) ||
                (riskAfter.equity > riskBefore.equity);
            if (!improved) revert LiquidationNotImproving();
        }

        emit Liquidation(liquidator, trader, optionIds, quantities, seized);

        _enforceInitialMargin(liquidator);
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(uint256 optionId)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(optionId);
        return oracle.getPrice(series.underlying, series.settlementAsset);
    }
}
