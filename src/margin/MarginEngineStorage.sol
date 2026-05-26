// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IRiskModule} from "../risk/IRiskModule.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../matching/IMarginEngineTrade.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {IFeesManagerV2} from "../fees/IFeesManagerV2.sol";

import {MarginEngineTypes} from "./MarginEngineTypes.sol";

/// @notice Minimal read view used to assert local cached risk params match RiskModule.
interface IRiskParamsView {
    function baseCollateralToken() external view returns (address);
    function baseMaintenanceMarginPerContract() external view returns (uint256);
    function imFactorBps() external view returns (uint256);
}

/// @notice Storage + stateful helpers for MarginEngine.
/// @dev
///  This file is the single source of truth for MarginEngine state.
///  It also hosts the low-level stateful helpers that maintain invariants:
///   - position quantity must never be int128.min
///   - open-series list must only contain non-zero positions
///   - totalShortContracts must remain consistent with positions
///
///  Important architectural note:
///   - external/public read surfaces should live in MarginEngineViews
///   - this storage layer only exposes internal helpers for those views
abstract contract MarginEngineStorage is MarginEngineTypes, ReentrancyGuard, IMarginEngineState, IMarginEngineTrade {
    /*//////////////////////////////////////////////////////////////
                                LOCAL CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint8 internal constant SERIES_ACTIVATION_ACTIVE = 0;
    uint8 internal constant SERIES_ACTIVATION_RESTRICTED = 1;
    uint8 internal constant SERIES_ACTIVATION_INACTIVE = 2;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public matchingEngine;

    /// @notice Emergency guardian allowed to trigger emergency protections.
    address public guardian;

    OptionProductRegistry internal _optionRegistry;
    CollateralVault internal _collateralVault;
    IOracle internal _oracle;
    IRiskModule internal _riskModule;

    /// @notice Hybrid fee engine (defaults + tiers + overrides).
    IFeesManager public feesManager;

    /// @notice Recipient of collected trading fees.
    /// @dev If zero, integration code may fallback to `insuranceFund`.
    address public feeRecipient;

    mapping(address => mapping(uint256 => IMarginEngineState.Position)) internal _positions;

    /// @notice Total absolute short quantity across all open series.
    mapping(address => uint256) public totalShortContracts;

    /// @notice Aggregate absolute short contracts per option series.
    mapping(uint256 => uint256) public seriesShortOpenInterest;

    /// @notice Optional launch-safety cap for aggregate short contracts per option series. 0 = disabled.
    mapping(uint256 => uint256) public seriesShortOpenInterestCap;

    /// @notice Engine-level emergency close-only flag per option series.
    mapping(uint256 => bool) public seriesEmergencyCloseOnly;

    /// @notice Launch-stage activation state per option series.
    /// @dev 0 = active, 1 = restricted reduce-only, 2 = inactive close-to-zero only.
    mapping(uint256 => uint8) public seriesActivationState;

    /// -----------------------------------------------------------------------
    /// OPEN SERIES TRACKING
    /// -----------------------------------------------------------------------
    /// @notice List of series with NON-ZERO position for a trader.
    mapping(address => uint256[]) internal traderSeries;

    /// @notice Index+1 inside traderSeries (0 = absent) for O(1) removal.
    mapping(address => mapping(uint256 => uint256)) internal traderSeriesIndexPlus1;

    /// @notice Local cached risk params expected to match RiskModule.
    address public baseCollateralToken;
    uint256 public baseMaintenanceMarginPerContract;
    uint256 public imFactorBps;

    /// @notice Legacy global pause.
    bool public paused;

    /// @notice Granular emergency flags.
    bool public tradingPaused;
    bool public liquidationPaused;
    bool public settlementPaused;
    bool public collateralOpsPaused;

    uint256 public liquidationThresholdBps = 10050;
    uint256 public liquidationPenaltyBps = 500;

    // ===================== Liquidation hardening =====================

    uint256 public liquidationCloseFactorBps = 5000;
    uint256 public minLiquidationImprovementBps = 1;

    // ===================== Liquidation pricing =====================

    uint256 public liquidationPriceSpreadBps = 500;
    uint256 public minLiquidationPriceBpsOfIntrinsic = 0;

    /// @notice Required oracle freshness for liquidation. 0 = disabled.
    uint32 public liquidationOracleMaxDelay = 600;

    // ===================== Settlement =====================

    address public insuranceFund;

    mapping(uint256 => mapping(address => bool)) public isAccountSettled;

    mapping(uint256 => uint256) public seriesCollected;
    mapping(uint256 => uint256) public seriesPaid;
    mapping(uint256 => uint256) public seriesBadDebt;

    /// @notice Optional signed-ppm fee engine for options V2. Disabled by default.
    IFeesManagerV2 public feesManagerV2;

    /// @notice If true, option execution uses FeesManagerV2 instead of V1.
    bool public useFeesManagerV2;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    modifier onlyGuardianOrOwner() {
        _onlyGuardianOrOwner();
        _;
    }

    modifier onlyMatchingEngine() {
        _onlyMatchingEngine();
        _;
    }

    modifier whenTradingNotPaused() {
        _whenTradingNotPaused();
        _;
    }

    modifier whenLiquidationNotPaused() {
        _whenLiquidationNotPaused();
        _;
    }

    modifier whenSettlementNotPaused() {
        _whenSettlementNotPaused();
        _;
    }

    modifier whenCollateralOpsNotPaused() {
        _whenCollateralOpsNotPaused();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotAuthorized();
    }

    function _onlyGuardianOrOwner() internal view {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
    }

    function _onlyMatchingEngine() internal view {
        if (msg.sender != matchingEngine) revert NotAuthorized();
    }

    function _whenTradingNotPaused() internal view {
        if (_isTradingPaused()) revert TradingPaused();
    }

    function _whenLiquidationNotPaused() internal view {
        if (_isLiquidationPaused()) revert LiquidationPaused();
    }

    function _whenSettlementNotPaused() internal view {
        if (_isSettlementPaused()) revert SettlementPaused();
    }

    function _whenCollateralOpsNotPaused() internal view {
        if (_isCollateralOpsPaused()) revert CollateralOpsPaused();
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function _initMarginEngineStorage(address owner_, address registry_, address vault_, address oracle_) internal {
        if (owner != address(0)) revert NotAuthorized();
        if (owner_ == address(0) || registry_ == address(0) || vault_ == address(0) || oracle_ == address(0)) {
            revert ZeroAddress();
        }

        owner = owner_;
        _optionRegistry = OptionProductRegistry(registry_);
        _collateralVault = CollateralVault(vault_);
        _oracle = IOracle(oracle_);

        paused = false;
        tradingPaused = false;
        liquidationPaused = false;
        settlementPaused = false;
        collateralOpsPaused = false;

        emit OwnershipTransferred(address(0), owner_);
        emit OracleSet(oracle_);
        emit GuardianSet(address(0), address(0));
        emit GlobalPauseSet(false);
        emit EmergencyModeUpdated(false, false, false, false);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL PURE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _meTryMul(uint256 a, uint256 b) internal pure returns (uint256 c, bool ok) {
        if (a == 0 || b == 0) return (0, true);
        unchecked {
            c = a * b;
        }
        if (c / a != b) return (0, false);
        return (c, true);
    }

    function _meSubChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (b > a) revert MathOverflow();
        unchecked {
            c = a - b;
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL EMERGENCY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isTradingPaused() internal view returns (bool) {
        return paused || tradingPaused;
    }

    function _isLiquidationPaused() internal view returns (bool) {
        return paused || liquidationPaused;
    }

    function _isSettlementPaused() internal view returns (bool) {
        return paused || settlementPaused;
    }

    function _isCollateralOpsPaused() internal view returns (bool) {
        return paused || collateralOpsPaused;
    }

    function _setEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool settlementPaused_,
        bool collateralOpsPaused_
    ) internal {
        _setSinglePauseNoAggregate(0, tradingPaused_);
        _setSinglePauseNoAggregate(1, liquidationPaused_);
        _setSinglePauseNoAggregate(2, settlementPaused_);
        _setSinglePauseNoAggregate(3, collateralOpsPaused_);
        emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
    }

    /// @dev Branch-table helper used by every pause/unpause entrypoint. Kinds:
    ///   0 = trading, 1 = liquidation, 2 = settlement, 3 = collateral ops.
    /// Writes the flag, emits the per-kind event, then emits the aggregate event.
    function _setSinglePause(uint8 kind, bool to) internal {
        _setSinglePauseNoAggregate(kind, to);
        emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
    }

    function _setSinglePauseNoAggregate(uint8 kind, bool to) private {
        if (kind == 0) {
            if (tradingPaused == to) return;
            tradingPaused = to;
            emit TradingPauseSet(to);
        } else if (kind == 1) {
            if (liquidationPaused == to) return;
            liquidationPaused = to;
            emit LiquidationPauseSet(to);
        } else if (kind == 2) {
            if (settlementPaused == to) return;
            settlementPaused = to;
            emit SettlementPauseSet(to);
        } else {
            if (collateralOpsPaused == to) return;
            collateralOpsPaused = to;
            emit CollateralOpsPauseSet(to);
        }
    }

    function _setGuardian(address guardian_) internal {
        address old = guardian;
        guardian = guardian_;
        emit GuardianSet(old, guardian_);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL STATE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _enforceInitialMargin(address trader) internal view {
        IRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        if (r.initialMarginBase > uint256(type(int256).max)) revert MathOverflow();
        if (r.equityBase < int256(r.initialMarginBase)) revert MarginRequirementBreached(trader);
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

        uint256 oldShort = oldQty < 0 ? _absInt128(oldQty) : 0;
        uint256 newShort = newQty < 0 ? _absInt128(newQty) : 0;

        uint256 cur = totalShortContracts[trader];

        if (newShort >= oldShort) {
            totalShortContracts[trader] = _addChecked(cur, newShort - oldShort);
        } else {
            totalShortContracts[trader] = _meSubChecked(cur, oldShort - newShort);
        }
    }

    function _updateSeriesShortOpenInterest(uint256 optionId, int128 oldQty, int128 newQty) internal {
        _ensureQtyAllowed(oldQty);
        _ensureQtyAllowed(newQty);

        uint256 oldShort = oldQty < 0 ? _absInt128(oldQty) : 0;
        uint256 newShort = newQty < 0 ? _absInt128(newQty) : 0;

        uint256 cur = seriesShortOpenInterest[optionId];

        if (newShort >= oldShort) {
            seriesShortOpenInterest[optionId] = _addChecked(cur, newShort - oldShort);
        } else {
            seriesShortOpenInterest[optionId] = _meSubChecked(cur, oldShort - newShort);
        }
    }

    function _enforceSeriesShortOpenInterestCap(uint256 optionId) internal view {
        uint256 cap = seriesShortOpenInterestCap[optionId];
        if (cap == 0) return;

        uint256 openInterest = seriesShortOpenInterest[optionId];
        if (openInterest > cap) revert SeriesShortOpenInterestCapExceeded(optionId, openInterest, cap);
    }

    /// @dev Canonical helper to maintain all open-series / short aggregates on a position mutation.
    function _syncPositionIndexes(address trader, uint256 optionId, int128 oldQty, int128 newQty) internal {
        _updateOpenSeriesOnChange(trader, optionId, oldQty, newQty);
        _updateTotalShortContracts(trader, oldQty, newQty);
        _updateSeriesShortOpenInterest(optionId, oldQty, newQty);
    }

    function _vaultCfg(address token) internal view returns (CollateralVault.CollateralTokenConfig memory cfg) {
        cfg = _collateralVault.getCollateralConfig(token);
    }

    function _requireSettlementAssetConfigured(address settlementAsset) internal view {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);
    }

    function _price1e8ToSettlementUnits(address settlementAsset, uint256 value1e8)
        internal
        view
        returns (uint256 valueNative)
    {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);

        uint256 scale = _pow10(uint256(cfg.decimals));
        valueNative = Math.mulDiv(value1e8, scale, PRICE_1E8, Math.Rounding.Floor);
    }

    function _requireBaseConfigured() internal view {
        if (baseCollateralToken == address(0)) revert NoBaseCollateral();
        _requireSettlementAssetConfigured(baseCollateralToken);
    }

    function _requireRiskParamsSynced() internal view {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();

        IRiskParamsView rp = IRiskParamsView(address(_riskModule));

        if (rp.baseCollateralToken() != baseCollateralToken) revert RiskParamsMismatch();
        if (rp.baseMaintenanceMarginPerContract() != baseMaintenanceMarginPerContract) revert RiskParamsMismatch();
        if (rp.imFactorBps() != imFactorBps) revert RiskParamsMismatch();
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
        (bool ok,) =
            address(_collateralVault).call(abi.encodeWithSignature("syncAccountFor(address,address)", user, token));
        ok;
    }

    function _resolvedFeeRecipient() internal view returns (address recipient) {
        recipient = feeRecipient;
        if (recipient == address(0)) {
            recipient = insuranceFund;
        }
    }

    function _hasFeeRecipient() internal view returns (bool) {
        return _resolvedFeeRecipient() != address(0);
    }

    /// @notice Computes strike-based implicit notional in native settlement units.
    /// @dev With contractSize locked to 1e8 (= 1 underlying), strike per contract is directly a 1e8 quote price.
    function _computeStrikeNotionalImplicit(OptionProductRegistry.OptionSeries memory s, uint256 quantity)
        internal
        view
        returns (uint256 notionalImplicit)
    {
        _requireStandardContractSize(s);
        if (quantity == 0) return 0;

        uint256 strikePerContractNative = _price1e8ToSettlementUnits(s.settlementAsset, uint256(s.strike));
        notionalImplicit = _mulChecked(quantity, strikePerContractNative);
    }

    function _quoteHybridFee(address trader, bool isMaker, uint256 premium, uint256 notionalImplicit)
        internal
        view
        returns (IFeesManager.FeeQuote memory quote)
    {
        IFeesManager fm = feesManager;
        if (address(fm) == address(0)) {
            return quote;
        }
        return fm.quoteFee(trader, isMaker, premium, notionalImplicit);
    }

    // Heavy decimal/oracle conversion helpers used by the liquidation seizure loop have been
    // extracted into `MarginEngineSeizureLib` so the engine bytecode stays under the EIP-170 limit.
    // Callers in `MarginEngineOps.liquidate` invoke the library directly.

    /*//////////////////////////////////////////////////////////////
                        INTERNAL READ HELPERS FOR VIEWS
    //////////////////////////////////////////////////////////////*/

    function _positionOf(address trader, uint256 optionId)
        internal
        view
        returns (IMarginEngineState.Position memory pos)
    {
        pos = _positions[trader][optionId];
    }

    function _positionQuantityOf(address trader, uint256 optionId) internal view returns (int128) {
        return _positions[trader][optionId].quantity;
    }

    function _isOpenSeriesInternal(address trader, uint256 optionId) internal view returns (bool) {
        return traderSeriesIndexPlus1[trader][optionId] != 0;
    }

    function _getTraderSeriesInternal(address trader) internal view returns (uint256[] memory) {
        return traderSeries[trader];
    }

    function _getTraderSeriesLengthInternal(address trader) internal view returns (uint256) {
        return traderSeries[trader].length;
    }

    function _getTraderSeriesSliceInternal(address trader, uint256 start, uint256 end)
        internal
        view
        returns (uint256[] memory slice)
    {
        uint256 len = traderSeries[trader].length;

        if (start >= len || start >= end) {
            return new uint256[](0);
        }

        if (end > len) end = len;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = traderSeries[trader][start + i];
        }
    }

    function _optionRegistryAddress() internal view returns (address) {
        return address(_optionRegistry);
    }

    function _collateralVaultAddress() internal view returns (address) {
        return address(_collateralVault);
    }

    function _oracleAddress() internal view returns (address) {
        return address(_oracle);
    }

    function _riskModuleAddress() internal view returns (address) {
        return address(_riskModule);
    }
}
