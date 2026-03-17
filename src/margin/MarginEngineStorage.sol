// contracts/margin/MarginEngineStorage.sol
// SPDX-License-Identifier: MIT
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

import {MarginEngineTypes} from "./MarginEngineTypes.sol";

/// @notice Minimal read view used to assert local cached risk params match RiskModule.
interface IRiskParamsView {
    function baseCollateralToken() external view returns (address);
    function baseMaintenanceMarginPerContract() external view returns (uint256);
    function imFactorBps() external view returns (uint256);
}

/// @notice Storage + helpers stateful (only file that declares MarginEngine state)
/// @dev Keep this file state-oriented. Pure helpers are namespaced here to avoid collisions.
abstract contract MarginEngineStorage is MarginEngineTypes, ReentrancyGuard, IMarginEngineState, IMarginEngineTrade {
    /*//////////////////////////////////////////////////////////////
                                LOCAL CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Defensive local mirrors (avoid relying on whether Types defines them).
    uint256 internal constant _ME_PRICE_1E8 = 1e8;
    uint256 internal constant _ME_MAX_POW10_EXP = 77;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public matchingEngine;

    /// @notice Emergency guardian allowed to trigger protocol emergency actions.
    /// @dev Intended owner != guardian in production. Guardian is operational, owner is governance/timelock.
    address public guardian;

    // renamed to avoid getter conflicts with IMarginEngineState optional helpers
    OptionProductRegistry internal _optionRegistry;
    CollateralVault internal _collateralVault;
    IOracle internal _oracle;
    IRiskModule internal _riskModule;

    /// @notice Hybrid fee engine (defaults + tiers + overrides).
    /// @dev Read-only dependency from MarginEngine perspective.
    IFeesManager public feesManager;

    /// @notice Recipient of collected trading fees.
    /// @dev If zero, integration code may fallback to `insuranceFund`.
    address public feeRecipient;

    mapping(address => mapping(uint256 => IMarginEngineState.Position)) internal _positions;

    /// @notice Nombre total de contrats shorts (toutes séries confondues) par trader
    mapping(address => uint256) public totalShortContracts;

    /// -----------------------------------------------------------------------
    /// OPEN SERIES TRACKING (anti-DoS gaz)
    /// -----------------------------------------------------------------------
    /// @notice Liste des séries sur lesquelles un trader a une position NON NULLE (open only).
    mapping(address => uint256[]) internal traderSeries;

    /// @notice Index+1 dans traderSeries (0 = absent). Permet remove O(1).
    mapping(address => mapping(uint256 => uint256)) internal traderSeriesIndexPlus1;

    /// @notice Cache local (doit matcher RiskModule) : baseCollateralToken / baseMM / IM factor.
    address public baseCollateralToken;
    uint256 public baseMaintenanceMarginPerContract;
    uint256 public imFactorBps;

    /// @notice Legacy global pause.
    /// @dev Kept for backward compatibility. Effective pause checks should use granular flags below.
    bool public paused;

    /// @notice Granular emergency flags.
    bool public tradingPaused;
    bool public liquidationPaused;
    bool public settlementPaused;
    bool public collateralOpsPaused;

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
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
        _;
    }

    modifier onlyMatchingEngine() {
        if (msg.sender != matchingEngine) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_isAnyPauseActive()) revert PausedError();
        _;
    }

    modifier whenTradingNotPaused() {
        if (_isTradingPaused()) revert TradingPaused();
        _;
    }

    modifier whenLiquidationNotPaused() {
        if (_isLiquidationPaused()) revert LiquidationPaused();
        _;
    }

    modifier whenSettlementNotPaused() {
        if (_isSettlementPaused()) revert SettlementPaused();
        _;
    }

    modifier whenCollateralOpsNotPaused() {
        if (_isCollateralOpsPaused()) revert CollateralOpsPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL INITIALIZER (optional)
    //////////////////////////////////////////////////////////////*/

    /// @dev Optional initializer helper for a concrete MarginEngine constructor.
    /// Call once from the concrete contract constructor.
    function _initMarginEngineStorage(address owner_, address registry_, address vault_, address oracle_) internal {
        if (owner != address(0)) revert NotAuthorized(); // already initialized (cheap sentinel)
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
                          INTERNAL PURE HELPERS (NAMESPACED)
    //////////////////////////////////////////////////////////////*/

    function _meEnsureQtyAllowed(int128 q) internal pure {
        // hard rule: never allow int128.min (abs/negation overflow)
        if (q == type(int128).min) revert QuantityMinNotAllowed();
    }

    function _meMulChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        c = a * b;
        if (c / a != b) revert MathOverflow();
    }

    function _meTryMul(uint256 a, uint256 b) internal pure returns (uint256 c, bool ok) {
        if (a == 0 || b == 0) return (0, true);
        unchecked {
            c = a * b;
        }
        if (c / a != b) return (0, false);
        return (c, true);
    }

    function _mePow10(uint256 exp) internal pure returns (uint256) {
        if (exp > _ME_MAX_POW10_EXP) revert MathOverflow();
        return 10 ** exp;
    }

    function _meAddChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        if (c < a) revert MathOverflow();
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

    function _isAnyPauseActive() internal view returns (bool) {
        return paused || tradingPaused || liquidationPaused || settlementPaused || collateralOpsPaused;
    }

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
        if (tradingPaused != tradingPaused_) {
            tradingPaused = tradingPaused_;
            emit TradingPauseSet(tradingPaused_);
        }

        if (liquidationPaused != liquidationPaused_) {
            liquidationPaused = liquidationPaused_;
            emit LiquidationPauseSet(liquidationPaused_);
        }

        if (settlementPaused != settlementPaused_) {
            settlementPaused = settlementPaused_;
            emit SettlementPauseSet(settlementPaused_);
        }

        if (collateralOpsPaused != collateralOpsPaused_) {
            collateralOpsPaused = collateralOpsPaused_;
            emit CollateralOpsPauseSet(collateralOpsPaused_);
        }

        emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
    }

    function _setGuardian(address guardian_) internal {
        address oldGuardian = guardian;
        guardian = guardian_;
        emit GuardianSet(oldGuardian, guardian_);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL (STATEFUL) HELPERS
    //////////////////////////////////////////////////////////////*/

    function _enforceInitialMargin(address trader) internal view {
        IRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        if (r.initialMargin > uint256(type(int256).max)) revert MathOverflow();
        if (r.equity < int256(r.initialMargin)) revert MarginRequirementBreached(trader);
    }

    function _addOpenSeries(address trader, uint256 optionId) internal {
        if (traderSeriesIndexPlus1[trader][optionId] != 0) return;
        traderSeries[trader].push(optionId);
        traderSeriesIndexPlus1[trader][optionId] = traderSeries[trader].length; // index+1
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
        _meEnsureQtyAllowed(oldQty);
        _meEnsureQtyAllowed(newQty);

        if (oldQty == 0 && newQty != 0) {
            _addOpenSeries(trader, optionId);
        } else if (oldQty != 0 && newQty == 0) {
            _removeOpenSeries(trader, optionId);
        }
    }

    function _updateTotalShortContracts(address trader, int128 oldQty, int128 newQty) internal {
        _meEnsureQtyAllowed(oldQty);
        _meEnsureQtyAllowed(newQty);

        uint256 oldShort = oldQty < 0 ? uint256(-int256(oldQty)) : 0;
        uint256 newShort = newQty < 0 ? uint256(-int256(newQty)) : 0;

        uint256 cur = totalShortContracts[trader];

        if (newShort >= oldShort) {
            uint256 delta = newShort - oldShort;
            totalShortContracts[trader] = _meAddChecked(cur, delta);
        } else {
            uint256 delta = oldShort - newShort;
            totalShortContracts[trader] = _meSubChecked(cur, delta);
        }
    }

    function _vaultCfg(address token) internal view returns (CollateralVault.CollateralTokenConfig memory cfg) {
        cfg = _collateralVault.getCollateralConfig(token);
    }

    function _requireSettlementAssetConfigured(address settlementAsset) internal view {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > _ME_MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);
    }

    function _price1e8ToSettlementUnits(address settlementAsset, uint256 value1e8)
        internal
        view
        returns (uint256 valueNative)
    {
        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > _ME_MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);

        uint256 scale = _mePow10(uint256(cfg.decimals));
        valueNative = Math.mulDiv(value1e8, scale, _ME_PRICE_1E8, Math.Rounding.Down);
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
        // best-effort: ignore failures to keep UX paths non-reverting
        (bool ok,) =
            address(_collateralVault).call(abi.encodeWithSignature("syncAccountFor(address,address)", user, token));
        ok;
    }

    /// @notice Resolve fee recipient.
    /// @dev Preferred target is explicit `feeRecipient`; fallback is `insuranceFund`.
    function _resolvedFeeRecipient() internal view returns (address recipient) {
        recipient = feeRecipient;
        if (recipient == address(0)) {
            recipient = insuranceFund;
        }
    }

    /// @notice Returns true if a fee recipient is configured directly or via insuranceFund fallback.
    function _hasFeeRecipient() internal view returns (bool) {
        return _resolvedFeeRecipient() != address(0);
    }

    /// @notice Computes the strike-based implicit notional in native settlement units.
    /// @dev
    ///  With contractSize locked to 1e8 (= 1 underlying), strike per contract is directly a 1e8 quote price.
    ///  Therefore notionalImplicit = quantity * strike, converted to settlement native units.
    function _computeStrikeNotionalImplicit(OptionProductRegistry.OptionSeries memory s, uint256 quantity)
        internal
        view
        returns (uint256 notionalImplicit)
    {
        _requireStandardContractSize(s);
        if (quantity == 0) return 0;

        uint256 strikePerContractNative = _price1e8ToSettlementUnits(s.settlementAsset, uint256(s.strike));
        notionalImplicit = _meMulChecked(quantity, strikePerContractNative);
    }

    /// @notice Quotes the hybrid fee for a given trader/role using the configured FeesManager.
    /// @dev If no FeesManager is configured, returns a zeroed quote.
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

    /// @dev Convertit une valeur "base token units" en amount de `token` (token units) arrondi UP (conservateur).
    ///      Utilise oracle.getPrice(token, base) (1e8). Si oracle indispo/stale => (0,false).
    ///      Best-effort: ne doit pas revert sur overflow (chemin liquidation).
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
        if (uint256(baseCfg.decimals) > _ME_MAX_POW10_EXP) revert DecimalsOverflow(baseCollateralToken);
        if (uint256(tokCfg.decimals) > _ME_MAX_POW10_EXP) revert DecimalsOverflow(token);

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
        uint256 sameDec = Math.mulDiv(baseValue, _ME_PRICE_1E8, px, Math.Rounding.Ceil);

        if (tokDec == baseDec) {
            return (sameDec, true);
        }

        if (tokDec > baseDec) {
            uint256 factor = _mePow10(uint256(tokDec - baseDec));
            (uint256 mul, bool okMul) = _meTryMul(sameDec, factor);
            if (!okMul) return (0, false);
            return (mul, true);
        } else {
            uint256 factor = _mePow10(uint256(baseDec - tokDec));
            amtToken = (sameDec + (factor - 1)) / factor;
            return (amtToken, true);
        }
    }

    /// @dev Approx base value (DOWN) de `tokenAmount` à un prix `pxTokBase` (token->base, 1e8).
    ///      Best-effort: si config invalide/overflow, renvoie 0 (conservateur, évite revert en liquidation).
    function _tokenAmountToBaseValueDown(address token, uint256 tokenAmount, uint256 pxTokBase)
        internal
        view
        returns (uint256 baseValue)
    {
        if (tokenAmount == 0) return 0;
        if (token == baseCollateralToken) return tokenAmount;

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) return 0;
        if (!tokCfg.isSupported || tokCfg.decimals == 0) return 0;

        if (uint256(baseCfg.decimals) > _ME_MAX_POW10_EXP) revert DecimalsOverflow(baseCollateralToken);
        if (uint256(tokCfg.decimals) > _ME_MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokDec = tokCfg.decimals;

        uint256 num = Math.mulDiv(tokenAmount, pxTokBase, _ME_PRICE_1E8, Math.Rounding.Down);

        if (tokDec == baseDec) return num;

        if (baseDec > tokDec) {
            uint256 factor = _mePow10(uint256(baseDec - tokDec));
            (uint256 mul, bool okMul) = _meTryMul(num, factor);
            if (!okMul) return 0;
            return mul;
        } else {
            uint256 factor = _mePow10(uint256(tokDec - baseDec));
            return num / factor;
        }
    }
}