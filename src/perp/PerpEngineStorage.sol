// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";

import {PerpMarketRegistry} from "./PerpMarketRegistry.sol";
import {PerpEngineTypes} from "./PerpEngineTypes.sol";

/// @notice Minimal risk-module surface expected by PerpEngine.
/// @dev
///  This stays intentionally narrow so the perp stack can evolve independently
///  from the options RiskModule.
///
///  Canonical conventions:
///   - `AccountRisk` outputs are denominated in native units of the protocol base collateral token
///   - `WithdrawPreview.requestedAmount / maxWithdrawable` are denominated in token-native units
interface IPerpRiskModule {
    struct AccountRisk {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
    }

    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
    }

    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk);
    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase);
    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (WithdrawPreview memory preview);
    function getWithdrawableAmount(address trader, address token) external view returns (uint256 amount);
}

/// @notice Minimal read view for market-registry config coherence checks.
interface IPerpMarketRegistryView {
    function getMarket(uint256 marketId) external view returns (PerpMarketRegistry.Market memory);
    function getRiskConfig(uint256 marketId) external view returns (PerpMarketRegistry.RiskConfig memory);
    function getLiquidationConfig(uint256 marketId) external view returns (PerpMarketRegistry.LiquidationConfig memory);
    function getFundingConfig(uint256 marketId) external view returns (PerpMarketRegistry.FundingConfig memory);
}

/// @notice Storage root for the perpetual engine.
abstract contract PerpEngineStorage is PerpEngineTypes, ReentrancyGuard {
    uint8 internal constant MARKET_ACTIVATION_ACTIVE = 0;
    uint8 internal constant MARKET_ACTIVATION_RESTRICTED = 1;
    uint8 internal constant MARKET_ACTIVATION_INACTIVE = 2;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    /// @notice Authorized matching engine for perp trades.
    address public matchingEngine;

    /// @notice Emergency operator.
    address public guardian;

    PerpMarketRegistry internal _marketRegistry;
    CollateralVault internal _collateralVault;
    IOracle internal _oracle;
    IPerpRiskModule internal _riskModule;
    ICollateralSeizer internal _collateralSeizer;
    IFeesManager public feesManager;

    /// @notice Insurance fund / backstop.
    address public insuranceFund;

    /// @notice Explicit fee recipient. Fallback may use insuranceFund.
    address public feeRecipient;

    /// @notice Net position per trader per market.
    mapping(address => mapping(uint256 => Position)) internal _positions;

    /// @notice Runtime market state.
    mapping(uint256 => MarketState) internal _marketStates;

    /// @notice Optional engine-level launch cap for effective market OI, in 1e8 underlying units. 0 = disabled.
    mapping(uint256 => uint256) public launchOpenInterestCap1e8;

    /// @notice Engine-level emergency close-only flag per market.
    mapping(uint256 => bool) public marketEmergencyCloseOnly;

    /// @notice Launch-stage activation state per market.
    /// @dev 0 = active, 1 = restricted reduce-only, 2 = inactive close-to-zero only.
    mapping(uint256 => uint8) public marketActivationState;

    /// @notice List of markets with non-zero position for trader.
    mapping(address => uint256[]) internal traderMarkets;
    mapping(address => mapping(uint256 => uint256)) internal traderMarketIndexPlus1;

    /// @notice Aggregate exposure helpers.
    mapping(address => uint256) public totalAbsLongSize1e8;
    mapping(address => uint256) public totalAbsShortSize1e8;

    /// @notice Residual bad debt per trader, denominated in native base-token units.
    /// @dev
    ///  This tracks liquidation leftovers not covered by:
    ///   - collateral seizure
    ///   - insurance fund top-up
    ///
    ///  It is protocol-visible economic debt and must be consumed by risk views.
    mapping(address => uint256) internal _residualBadDebtBase;

    /// @notice Aggregate residual bad debt across all traders, in native base-token units.
    uint256 public totalResidualBadDebtBase;

    /// @notice Legacy global pause.
    bool public paused;

    /// @notice Granular emergency flags.
    bool public tradingPaused;
    bool public liquidationPaused;
    bool public fundingPaused;
    bool public collateralOpsPaused;

    /// @notice Legacy default close factor used only as fallback when market-specific config is unavailable.
    /// @dev 5000 = 50%
    uint256 public liquidationCloseFactorBps = 5000;

    /// @notice Legacy default liquidation penalty used only as fallback when market-specific config is unavailable.
    /// @dev 500 = 5%
    uint256 public liquidationPenaltyBps = 500;

    /// @notice Legacy default liquidation spread used only as fallback when market-specific config is unavailable.
    /// @dev 100 = 1%
    uint256 public liquidationPriceSpreadBps = 100;

    /// @notice Legacy default minimum required improvement used only as fallback when market-specific config is unavailable.
    /// @dev In bps of margin ratio.
    uint256 public minLiquidationImprovementBps = 50;

    /// @notice Legacy default liquidation oracle freshness used only as fallback when market-specific config is unavailable.
    /// @dev In seconds. 0 disables staleness guard for the fallback path.
    uint32 public liquidationOracleMaxDelay = 60;

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

    modifier whenFundingNotPaused() {
        if (_isFundingPaused()) revert FundingPaused();
        _;
    }

    modifier whenCollateralOpsNotPaused() {
        if (_isCollateralOpsPaused()) revert CollateralOpsPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL INITIALIZER
    //////////////////////////////////////////////////////////////*/

    function _initPerpEngineStorage(address owner_, address registry_, address vault_, address oracle_) internal {
        if (owner != address(0)) revert NotAuthorized();
        if (owner_ == address(0) || registry_ == address(0) || vault_ == address(0) || oracle_ == address(0)) {
            revert ZeroAddress();
        }

        owner = owner_;
        _marketRegistry = PerpMarketRegistry(registry_);
        _collateralVault = CollateralVault(vault_);
        _oracle = IOracle(oracle_);

        paused = false;
        tradingPaused = false;
        liquidationPaused = false;
        fundingPaused = false;
        collateralOpsPaused = false;

        emit OwnershipTransferred(address(0), owner_);
        emit OracleSet(oracle_);
        emit GuardianSet(address(0), address(0));
        emit GlobalPauseSet(false);
        emit EmergencyModeUpdated(false, false, false, false);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL EMERGENCY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isAnyPauseActive() internal view returns (bool) {
        return paused || tradingPaused || liquidationPaused || fundingPaused || collateralOpsPaused;
    }

    function _isTradingPaused() internal view returns (bool) {
        return paused || tradingPaused;
    }

    function _isLiquidationPaused() internal view returns (bool) {
        return paused || liquidationPaused;
    }

    function _isFundingPaused() internal view returns (bool) {
        return paused || fundingPaused;
    }

    function _isCollateralOpsPaused() internal view returns (bool) {
        return paused || collateralOpsPaused;
    }

    function _setEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool fundingPaused_,
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

        if (fundingPaused != fundingPaused_) {
            fundingPaused = fundingPaused_;
            emit FundingPauseSet(fundingPaused_);
        }

        if (collateralOpsPaused != collateralOpsPaused_) {
            collateralOpsPaused = collateralOpsPaused_;
            emit CollateralOpsPauseSet(collateralOpsPaused_);
        }

        emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
    }

    function _setGuardian(address guardian_) internal {
        address old = guardian;
        guardian = guardian_;
        emit GuardianSet(old, guardian_);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL DEPENDENCY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _resolvedFeeRecipient() internal view returns (address recipient) {
        recipient = feeRecipient;
        if (recipient == address(0)) recipient = insuranceFund;
    }

    /// @notice Recipient used for explicit residual bad debt repayments.
    /// @dev
    ///  Priority:
    ///   1) insuranceFund, because it is the canonical backstop that absorbed shortfall
    ///   2) feeRecipient as fallback operational sink if insuranceFund is unavailable
    function _resolvedBadDebtRepaymentRecipient() internal view returns (address recipient) {
        recipient = insuranceFund;
        if (recipient == address(0)) {
            recipient = feeRecipient;
        }
    }

    function _hasFeeRecipient() internal view returns (bool) {
        return _resolvedFeeRecipient() != address(0);
    }

    function _hasBadDebtRepaymentRecipient() internal view returns (bool) {
        return _resolvedBadDebtRepaymentRecipient() != address(0);
    }

    function _requireRiskModuleSet() internal view {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
    }

    function _requireMarketExists(uint256 marketId) internal view returns (PerpMarketRegistry.Market memory m) {
        m = _marketRegistry.getMarket(marketId);
        if (!m.exists) revert UnknownMarket();
    }

    function _getRiskConfig(uint256 marketId) internal view returns (PerpMarketRegistry.RiskConfig memory cfg) {
        cfg = _marketRegistry.getRiskConfig(marketId);
    }

    function _getLiquidationConfig(uint256 marketId)
        internal
        view
        returns (PerpMarketRegistry.LiquidationConfig memory cfg)
    {
        cfg = _marketRegistry.getLiquidationConfig(marketId);
    }

    function _getFundingConfig(uint256 marketId) internal view returns (PerpMarketRegistry.FundingConfig memory cfg) {
        cfg = _marketRegistry.getFundingConfig(marketId);
    }

    function _marketOracle(PerpMarketRegistry.Market memory m) internal view returns (IOracle) {
        if (m.oracle == address(0)) return _oracle;
        return IOracle(m.oracle);
    }

    function _baseCollateralToken() internal view returns (address) {
        _requireRiskModuleSet();

        (bool success, bytes memory data) =
            address(_riskModule).staticcall(abi.encodeWithSignature("baseCollateralToken()"));

        if (!success || data.length < 32) revert RiskModuleNotSet();
        return abi.decode(data, (address));
    }

    function _baseToken() internal view returns (address) {
        return _baseCollateralToken();
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL MARKET POLICY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Effective close factor for one market.
    /// @dev Falls back to legacy global storage only if registry config is unavailable or zeroed.
    function _liquidationCloseFactorBpsForMarket(uint256 marketId) internal view returns (uint256) {
        try _marketRegistry.getLiquidationConfig(marketId) returns (PerpMarketRegistry.LiquidationConfig memory cfg) {
            if (cfg.closeFactorBps != 0) return uint256(cfg.closeFactorBps);
        } catch {}
        return liquidationCloseFactorBps;
    }

    /// @notice Effective adverse price spread for one market.
    /// @dev Falls back to legacy global storage only if registry config is unavailable.
    function _liquidationPriceSpreadBpsForMarket(uint256 marketId) internal view returns (uint256) {
        try _marketRegistry.getLiquidationConfig(marketId) returns (PerpMarketRegistry.LiquidationConfig memory cfg) {
            return uint256(cfg.priceSpreadBps);
        } catch {}
        return liquidationPriceSpreadBps;
    }

    /// @notice Effective minimum improvement requirement for one market.
    function _minLiquidationImprovementBpsForMarket(uint256 marketId) internal view returns (uint256) {
        try _marketRegistry.getLiquidationConfig(marketId) returns (PerpMarketRegistry.LiquidationConfig memory cfg) {
            return uint256(cfg.minImprovementBps);
        } catch {}
        return minLiquidationImprovementBps;
    }

    /// @notice Effective oracle freshness threshold for one market.
    /// @dev 0 disables staleness enforcement.
    function _liquidationOracleMaxDelayForMarket(uint256 marketId) internal view returns (uint32) {
        try _marketRegistry.getLiquidationConfig(marketId) returns (PerpMarketRegistry.LiquidationConfig memory cfg) {
            return cfg.oracleMaxDelay;
        } catch {}
        return liquidationOracleMaxDelay;
    }

    /// @notice Effective liquidation penalty for one market.
    /// @dev Penalty is still sourced from RiskConfig because it is part of product risk policy.
    function _liquidationPenaltyBpsForMarket(uint256 marketId) internal view returns (uint256) {
        PerpMarketRegistry.RiskConfig memory cfg = _getRiskConfig(marketId);
        if (cfg.liquidationPenaltyBps != 0) return uint256(cfg.liquidationPenaltyBps);
        return liquidationPenaltyBps;
    }

    /// @notice Validates a liquidation policy bundle.
    /// @dev Shared helper for admin config sanity checks and runtime assertions.
    function _validateLiquidationParams(
        uint256 closeFactorBps_,
        uint256 penaltyBps_,
        uint256 priceSpreadBps_,
        uint256 minImprovementBps_,
        uint256 oracleMaxDelay_
    ) internal pure {
        if (closeFactorBps_ == 0) revert LiquidationCloseFactorZero();
        if (closeFactorBps_ > BPS) revert LiquidationParamsInvalid();
        if (penaltyBps_ > BPS) revert LiquidationPenaltyTooLarge();
        if (priceSpreadBps_ > BPS) revert LiquidationParamsInvalid();
        if (minImprovementBps_ > BPS) revert LiquidationParamsInvalid();
        if (oracleMaxDelay_ > 3600) revert LiquidationParamsInvalid();
    }

    /// @notice Runtime fetch + validation of effective market liquidation policy.
    function _loadEffectiveLiquidationParams(uint256 marketId)
        internal
        view
        returns (
            uint256 closeFactorBps,
            uint256 penaltyBps,
            uint256 priceSpreadBps,
            uint256 minImprovementBps,
            uint32 oracleMaxDelay
        )
    {
        closeFactorBps = _liquidationCloseFactorBpsForMarket(marketId);
        penaltyBps = _liquidationPenaltyBpsForMarket(marketId);
        priceSpreadBps = _liquidationPriceSpreadBpsForMarket(marketId);
        minImprovementBps = _minLiquidationImprovementBpsForMarket(marketId);
        oracleMaxDelay = _liquidationOracleMaxDelayForMarket(marketId);

        _validateLiquidationParams(
            closeFactorBps, penaltyBps, priceSpreadBps, minImprovementBps, uint256(oracleMaxDelay)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL SHARED ACCOUNTING HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireSettlementAssetConfigured(address settlementAsset)
        internal
        view
        returns (CollateralVault.CollateralTokenConfig memory cfg)
    {
        cfg = _collateralVault.getCollateralConfig(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert InvalidMarket();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert MathOverflow();
    }

    function _value1e8ToSettlementNative(address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256 amountNative)
    {
        CollateralVault.CollateralTokenConfig memory cfg = _requireSettlementAssetConfigured(settlementAsset);
        uint256 scale = _pow10(uint256(cfg.decimals));
        amountNative = Math.mulDiv(amount1e8, scale, PRICE_1E8, Math.Rounding.Floor);
    }

    function _signedNotional1e8(int256 size1e8, uint256 executionPrice1e8) internal pure returns (int256 notional1e8) {
        return _signedMarkValue1e8(size1e8, executionPrice1e8);
    }

    function _minU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sameSignNonZero(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _absInt256Signed(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function _sign(int256 x) internal pure returns (int256) {
        if (x > 0) return int256(1);
        if (x < 0) return int256(-1);
        return int256(0);
    }

    function _clampSigned(int256 x, int256 minX, int256 maxX) internal pure returns (int256) {
        if (x < minX) return minX;
        if (x > maxX) return maxX;
        return x;
    }

    function _baseValueToTokenAmount(address token, uint256 baseValue, uint256 price1e8)
        internal
        view
        returns (uint256 tokenAmount)
    {
        CollateralVault.CollateralTokenConfig memory baseCfg = _collateralVault.getCollateralConfig(_baseToken());
        CollateralVault.CollateralTokenConfig memory tokCfg = _collateralVault.getCollateralConfig(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!tokCfg.isSupported || tokCfg.decimals == 0) revert InvalidMarket();

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(baseValue, PRICE_1E8, price1e8, Math.Rounding.Floor);

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        }

        uint256 factor2 = _pow10(uint256(baseDec - tokenDec));
        return tmp / factor2;
    }

    function _settlementNativeToBase(address settlementAsset, uint256 settlementAmountNative)
        internal
        view
        returns (uint256 baseValue)
    {
        if (settlementAmountNative == 0) return 0;

        address baseToken = _baseToken();

        CollateralVault.CollateralTokenConfig memory baseCfg = _collateralVault.getCollateralConfig(baseToken);
        CollateralVault.CollateralTokenConfig memory setCfg = _collateralVault.getCollateralConfig(settlementAsset);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!setCfg.isSupported || setCfg.decimals == 0) revert InvalidMarket();

        if (settlementAsset == baseToken) {
            return settlementAmountNative;
        }

        (uint256 px, bool ok) = _tryGetMarkPrice1e8FromPair(settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();

        uint256 tmp = Math.mulDiv(settlementAmountNative, px, PRICE_1E8, Math.Rounding.Floor);

        if (baseCfg.decimals == setCfg.decimals) return tmp;

        if (baseCfg.decimals > setCfg.decimals) {
            uint256 factor = _pow10(uint256(baseCfg.decimals - setCfg.decimals));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        }

        uint256 factor2 = _pow10(uint256(setCfg.decimals - baseCfg.decimals));
        return tmp / factor2;
    }

    function _settlementAmount1e8ToBase(address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256 baseValue)
    {
        if (amount1e8 == 0) return 0;

        uint256 settlementNative = _value1e8ToSettlementNative(settlementAsset, amount1e8);
        return _settlementNativeToBase(settlementAsset, settlementNative);
    }

    function _penaltySettlementNative(address settlementAsset, uint256 penaltyBase)
        internal
        view
        returns (uint256 penaltyNative)
    {
        address baseToken = _baseToken();
        if (penaltyBase == 0) return 0;

        if (settlementAsset == baseToken) {
            return penaltyBase;
        }

        (uint256 px, bool ok) = _tryGetMarkPrice1e8FromPair(settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();
        penaltyNative = _baseValueToTokenAmount(settlementAsset, penaltyBase, px);
    }

    function _tryGetMarkPrice1e8FromPair(address base, address quote) internal view returns (uint256 price1e8, bool ok) {
        {
            (bool success, bytes memory data) =
                address(_oracle).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));

            if (success && data.length >= 96) {
                (uint256 px,, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && px != 0) return (px, true);
            }
        }

        try _oracle.getPrice(base, quote) returns (uint256 px, uint256) {
            if (px == 0) return (0, false);
            return (px, true);
        } catch {
            return (0, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL POSITION TRANSITION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _accruedFundingOnPosition(Position memory oldPos, int256 currentCumulativeFundingRate1e18)
        internal
        pure
        returns (int256 funding1e8)
    {
        if (oldPos.size1e8 == 0) return 0;
        return _fundingPayment1e8(
            oldPos.size1e8, currentCumulativeFundingRate1e18, oldPos.lastCumulativeFundingRate1e18
        );
    }

    function _closedFundingPortion1e8(
        Position memory oldPos,
        uint256 closeAbs,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 closedFunding1e8) {
        if (oldPos.size1e8 == 0 || closeAbs == 0) return 0;

        uint256 absOld = _absInt256(oldPos.size1e8);
        int256 totalAccruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);

        closedFunding1e8 = (totalAccruedFunding1e8 * _toInt256(closeAbs)) / _toInt256(absOld);
    }

    function _carryForwardFundingCheckpointForIncrease(
        Position memory oldPos,
        int256 newSize1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 nextCheckpoint1e18) {
        if (oldPos.size1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 accruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);
        if (accruedFunding1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 deltaRate1e18 = (accruedFunding1e8 * _toInt256(FUNDING_SCALE_1E18)) / newSize1e8;
        nextCheckpoint1e18 = currentCumulativeFundingRate1e18 - deltaRate1e18;
    }

    function _computeNextPosition(
        Position memory oldPos,
        int256 deltaSize1e8,
        uint256 executionPrice1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (Position memory nextPos, int256 realizedPnl1e8) {
        int256 oldSize = oldPos.size1e8;
        int256 oldOpenNotional = oldPos.openNotional1e8;

        if (deltaSize1e8 == 0) revert SizeZero();
        if (executionPrice1e8 == 0) revert PriceZero();

        int256 newSize = _checkedAddInt256(oldSize, deltaSize1e8);
        nextPos.size1e8 = newSize;

        if (oldSize == 0 || _sameSignNonZero(oldSize, deltaSize1e8)) {
            nextPos.openNotional1e8 =
                _checkedAddInt256(oldOpenNotional, _signedNotional1e8(deltaSize1e8, executionPrice1e8));

            if (oldSize == 0) {
                nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
            } else {
                nextPos.lastCumulativeFundingRate1e18 =
                    _carryForwardFundingCheckpointForIncrease(oldPos, newSize, currentCumulativeFundingRate1e18);
            }

            return (nextPos, 0);
        }

        uint256 absOld = _absInt256(oldSize);
        uint256 absDelta = _absInt256(deltaSize1e8);
        uint256 closeAbs = _minU(absOld, absDelta);

        int256 closeSizeSigned = oldSize > 0 ? _toInt256(closeAbs) : -_toInt256(closeAbs);

        int256 removedBasis1e8 = (oldOpenNotional * _toInt256(closeAbs)) / _toInt256(absOld);
        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        int256 closedFunding1e8 = _closedFundingPortion1e8(oldPos, closeAbs, currentCumulativeFundingRate1e18);

        realizedPnl1e8 = _checkedSubInt256(_checkedSubInt256(closedMarkValue1e8, removedBasis1e8), closedFunding1e8);

        if (newSize == 0) {
            nextPos.openNotional1e8 = 0;
            nextPos.lastCumulativeFundingRate1e18 = 0;
            return (nextPos, realizedPnl1e8);
        }

        if (_sameSignNonZero(oldSize, newSize)) {
            nextPos.openNotional1e8 = _checkedSubInt256(oldOpenNotional, removedBasis1e8);
            nextPos.lastCumulativeFundingRate1e18 = oldPos.lastCumulativeFundingRate1e18;
            return (nextPos, realizedPnl1e8);
        }

        nextPos.openNotional1e8 = _signedNotional1e8(newSize, executionPrice1e8);
        nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL POSITION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addOpenMarket(address trader, uint256 marketId) internal {
        if (traderMarketIndexPlus1[trader][marketId] != 0) return;
        traderMarkets[trader].push(marketId);
        traderMarketIndexPlus1[trader][marketId] = traderMarkets[trader].length;
    }

    function _removeOpenMarket(address trader, uint256 marketId) internal {
        uint256 idxPlus1 = traderMarketIndexPlus1[trader][marketId];
        if (idxPlus1 == 0) return;

        uint256 idx = idxPlus1 - 1;
        uint256 lastIdx = traderMarkets[trader].length - 1;

        if (idx != lastIdx) {
            uint256 lastId = traderMarkets[trader][lastIdx];
            traderMarkets[trader][idx] = lastId;
            traderMarketIndexPlus1[trader][lastId] = idx + 1;
        }

        traderMarkets[trader].pop();
        traderMarketIndexPlus1[trader][marketId] = 0;
    }

    function _updateOpenMarketsOnChange(address trader, uint256 marketId, int256 oldSize1e8, int256 newSize1e8)
        internal
    {
        _ensureInt256Allowed(oldSize1e8);
        _ensureInt256Allowed(newSize1e8);

        if (oldSize1e8 == 0 && newSize1e8 != 0) {
            _addOpenMarket(trader, marketId);
        } else if (oldSize1e8 != 0 && newSize1e8 == 0) {
            _removeOpenMarket(trader, marketId);
        }
    }

    function _updateAggregateTraderExposure(address trader, int256 oldSize1e8, int256 newSize1e8) internal {
        _ensureInt256Allowed(oldSize1e8);
        _ensureInt256Allowed(newSize1e8);

        uint256 oldLong = oldSize1e8 > 0 ? _toUint256(oldSize1e8) : 0;
        uint256 newLong = newSize1e8 > 0 ? _toUint256(newSize1e8) : 0;

        uint256 oldShort = oldSize1e8 < 0 ? _absInt256(oldSize1e8) : 0;
        uint256 newShort = newSize1e8 < 0 ? _absInt256(newSize1e8) : 0;

        uint256 curLong = totalAbsLongSize1e8[trader];
        uint256 curShort = totalAbsShortSize1e8[trader];

        if (newLong >= oldLong) {
            totalAbsLongSize1e8[trader] = _addChecked(curLong, newLong - oldLong);
        } else {
            totalAbsLongSize1e8[trader] = _subChecked(curLong, oldLong - newLong);
        }

        if (newShort >= oldShort) {
            totalAbsShortSize1e8[trader] = _addChecked(curShort, newShort - oldShort);
        } else {
            totalAbsShortSize1e8[trader] = _subChecked(curShort, oldShort - newShort);
        }
    }

    function _syncPositionIndexing(address trader, uint256 marketId, int256 oldSize1e8, int256 newSize1e8) internal {
        _updateOpenMarketsOnChange(trader, marketId, oldSize1e8, newSize1e8);
        _updateAggregateTraderExposure(trader, oldSize1e8, newSize1e8);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MARKET-STATE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _marketState(uint256 marketId) internal view returns (MarketState memory s) {
        s = _marketStates[marketId];
    }

    function _updateMarketOpenInterest(uint256 marketId, int256 oldSize1e8, int256 newSize1e8) internal {
        MarketState storage s = _marketStates[marketId];

        uint256 oldLong = oldSize1e8 > 0 ? _toUint256(oldSize1e8) : 0;
        uint256 newLong = newSize1e8 > 0 ? _toUint256(newSize1e8) : 0;

        uint256 oldShort = oldSize1e8 < 0 ? _absInt256(oldSize1e8) : 0;
        uint256 newShort = newSize1e8 < 0 ? _absInt256(newSize1e8) : 0;

        if (newLong >= oldLong) {
            s.longOpenInterest1e8 = _addChecked(s.longOpenInterest1e8, newLong - oldLong);
        } else {
            s.longOpenInterest1e8 = _subChecked(s.longOpenInterest1e8, oldLong - newLong);
        }

        if (newShort >= oldShort) {
            s.shortOpenInterest1e8 = _addChecked(s.shortOpenInterest1e8, newShort - oldShort);
        } else {
            s.shortOpenInterest1e8 = _subChecked(s.shortOpenInterest1e8, oldShort - newShort);
        }
    }

    function _effectiveMarketOpenInterest1e8(uint256 marketId) internal view returns (uint256) {
        MarketState storage s = _marketStates[marketId];
        return s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
    }

    function _enforceLaunchOpenInterestCapIfIncreasing(uint256 marketId, uint256 previousOpenInterest1e8)
        internal
        view
    {
        uint256 cap = launchOpenInterestCap1e8[marketId];
        if (cap == 0) return;

        uint256 currentOpenInterest1e8 = _effectiveMarketOpenInterest1e8(marketId);
        if (currentOpenInterest1e8 <= previousOpenInterest1e8) return;
        if (currentOpenInterest1e8 > cap) {
            revert LaunchOpenInterestCapExceeded(marketId, currentOpenInterest1e8, cap);
        }
    }

    function _recordFundingUpdate(
        uint256 marketId,
        int256 fundingRateDelta1e18,
        int256 nextCumulativeFundingRate1e18,
        uint64 effectiveTimestamp
    ) internal {
        MarketState storage s = _marketStates[marketId];
        s.cumulativeFundingRate1e18 = nextCumulativeFundingRate1e18;
        s.lastFundingTimestamp = effectiveTimestamp;

        emit FundingUpdated(marketId, fundingRateDelta1e18, nextCumulativeFundingRate1e18, effectiveTimestamp);
    }

    function _effectiveFundingTimestamp(uint256 marketId) internal view returns (uint64 ts) {
        uint64 lastTs = _marketStates[marketId].lastFundingTimestamp;
        if (lastTs != 0) return lastTs;
        ts = uint64(block.timestamp);
    }

    function _fundingElapsed(uint256 marketId) internal view returns (uint256 elapsed) {
        uint64 anchor = _effectiveFundingTimestamp(marketId);
        if (block.timestamp <= uint256(anchor)) return 0;
        return block.timestamp - uint256(anchor);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL LIQUIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _recordResidualBadDebt(address trader, uint256 amountBase) internal {
        if (trader == address(0)) revert ZeroAddress();
        if (amountBase == 0) return;

        uint256 oldDebt = _residualBadDebtBase[trader];
        uint256 oldTotalDebt = totalResidualBadDebtBase;
        uint256 newDebt = _addChecked(oldDebt, amountBase);
        uint256 newTotalDebt = _addChecked(oldTotalDebt, amountBase);

        _residualBadDebtBase[trader] = newDebt;
        totalResidualBadDebtBase = newTotalDebt;

        emit ResidualBadDebtUpdated(msg.sender, trader, oldDebt, newDebt, oldTotalDebt, newTotalDebt);
    }

    function _reduceResidualBadDebt(address trader, uint256 amountBase) internal returns (uint256 repaidBase) {
        if (trader == address(0)) revert ZeroAddress();
        if (amountBase == 0) return 0;

        uint256 oldDebt = _residualBadDebtBase[trader];
        if (oldDebt == 0) return 0;

        repaidBase = amountBase < oldDebt ? amountBase : oldDebt;
        uint256 newDebt = oldDebt - repaidBase;
        uint256 oldTotalDebt = totalResidualBadDebtBase;
        uint256 newTotalDebt = _subChecked(oldTotalDebt, repaidBase);

        _residualBadDebtBase[trader] = newDebt;
        totalResidualBadDebtBase = newTotalDebt;

        emit ResidualBadDebtUpdated(msg.sender, trader, oldDebt, newDebt, oldTotalDebt, newTotalDebt);
    }

    function _clearResidualBadDebt(address trader) internal returns (uint256 clearedBase) {
        if (trader == address(0)) revert ZeroAddress();

        clearedBase = _residualBadDebtBase[trader];
        if (clearedBase == 0) return 0;

        uint256 oldTotalDebt = totalResidualBadDebtBase;
        uint256 newTotalDebt = _subChecked(oldTotalDebt, clearedBase);

        _residualBadDebtBase[trader] = 0;
        totalResidualBadDebtBase = newTotalDebt;

        emit ResidualBadDebtUpdated(msg.sender, trader, clearedBase, 0, oldTotalDebt, newTotalDebt);
    }

    function _residualBadDebtOf(address trader) internal view returns (uint256) {
        return _residualBadDebtBase[trader];
    }

    /// @notice Remaining uncovered amount after a partial coverage step.
    /// @dev Safe helper shared by liquidation resolution flow and previews.
    function _remainingShortfall(uint256 targetBaseValue, uint256 coveredBaseValue)
        internal
        pure
        override
        returns (uint256)
    {
        return coveredBaseValue >= targetBaseValue ? 0 : (targetBaseValue - coveredBaseValue);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _getMarkPrice1e8(uint256 marketId) internal view returns (uint256 price1e8) {
        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        IOracle o = _marketOracle(m);

        (uint256 px,) = o.getPrice(m.underlying, m.settlementAsset);
        if (px == 0) revert OraclePriceUnavailable();
        return px;
    }

    function _tryGetMarkPrice1e8(uint256 marketId) internal view returns (uint256 price1e8, bool ok) {
        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        IOracle o = _marketOracle(m);

        {
            (bool success, bytes memory data) = address(o).staticcall(
                abi.encodeWithSignature("getPriceSafe(address,address)", m.underlying, m.settlementAsset)
            );

            if (success && data.length >= 96) {
                (uint256 px,, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && px != 0) return (px, true);
            }
        }

        try o.getPrice(m.underlying, m.settlementAsset) returns (uint256 px, uint256) {
            if (px == 0) return (0, false);
            return (px, true);
        } catch {
            return (0, false);
        }
    }

    function _getIndexPrice1e8(uint256 marketId) internal view returns (uint256 price1e8) {
        return _getMarkPrice1e8(marketId);
    }

    function _tryGetIndexPrice1e8(uint256 marketId) internal view returns (uint256 price1e8, bool ok) {
        return _tryGetMarkPrice1e8(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL ACCOUNTING HELPERS
    //////////////////////////////////////////////////////////////*/

    function _positionUnrealizedPnl1e8(address trader, uint256 marketId, uint256 markPrice1e8)
        internal
        view
        returns (int256 pnl1e8)
    {
        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return 0;
        return _unrealizedPnl1e8(p.size1e8, p.openNotional1e8, markPrice1e8);
    }

    function _positionFundingAccrued1e8(address trader, uint256 marketId) internal view returns (int256 funding1e8) {
        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return 0;

        MarketState memory s = _marketStates[marketId];
        return _fundingPayment1e8(p.size1e8, s.cumulativeFundingRate1e18, p.lastCumulativeFundingRate1e18);
    }

    function _settleFundingSnapshot(address trader, uint256 marketId) internal returns (int256 fundingPayment1e8) {
        Position storage p = _positions[trader][marketId];
        if (p.size1e8 == 0) {
            p.lastCumulativeFundingRate1e18 = _marketStates[marketId].cumulativeFundingRate1e18;
            return 0;
        }

        int256 cumNow = _marketStates[marketId].cumulativeFundingRate1e18;
        fundingPayment1e8 = _fundingPayment1e8(p.size1e8, cumNow, p.lastCumulativeFundingRate1e18);
        p.lastCumulativeFundingRate1e18 = cumNow;

        emit PositionFundingSettled(trader, marketId, fundingPayment1e8, cumNow);
    }

    function _grossTraderNotional1e8(address trader) internal view returns (uint256 total) {
        uint256[] memory markets = traderMarkets[trader];

        for (uint256 i = 0; i < markets.length; i++) {
            uint256 marketId = markets[i];
            Position memory p = _positions[trader][marketId];
            if (p.size1e8 == 0) continue;

            uint256 absSize = p.size1e8 > 0 ? uint256(p.size1e8) : uint256(-p.size1e8);
            uint256 mark = _getMarkPrice1e8(marketId);
            total = _addChecked(total, Math.mulDiv(absSize, mark, PRICE_1E8, Math.Rounding.Floor));
        }
    }

    /*//////////////////////////////////////////////////////////////
                          OPTIONAL COLLATERAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _syncVaultBestEffort(address user, address token) internal {
        (bool ok,) =
            address(_collateralVault).call(abi.encodeWithSignature("syncAccountFor(address,address)", user, token));
        ok;
    }

    /*//////////////////////////////////////////////////////////////
                                READ HELPERS
    //////////////////////////////////////////////////////////////*/

    function _position(address trader, uint256 marketId) internal view returns (Position memory p) {
        p = _positions[trader][marketId];
    }

    function _marketRegistryAddress() internal view returns (address) {
        return address(_marketRegistry);
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

    function _collateralSeizerAddress() internal view returns (address) {
        return address(_collateralSeizer);
    }
}
