// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PerpEngineTypes
/// @notice Types / constants / errors / events / pure helpers for DeOpt v2 perpetuals.
/// @dev Canonical unit conventions used by this module:
///  - prices normalized by the protocol are in 1e8
///  - position sizes are signed underlying amounts scaled by 1e8
///  - quote notionals normalized by the protocol are in 1e8
///  - funding accumulators use 1e18 precision
///  - token-native cash amounts use the settlement/base token native decimals
///  - base risk amounts are expressed in native units of the protocol base collateral token
///  - ratios use basis points (BPS)
///
///  Naming conventions:
///  - `...1e8`   => protocol-normalized price/notional/size
///  - `...1e18`  => high-precision funding accumulator / rate
///  - `...Base`  => native units of the protocol base collateral token
///  - `...Native`=> native units of the token being moved
///  - `...Bps`   => ratio in basis points
///
///  Economic conventions:
///  - `shortfall` = transient deficit during liquidation resolution
///  - `badDebt`   = final residual uncovered amount recorded by the protocol
///
///  Design choice:
///   - perpetual positions use:
///       size1e8
///       openNotional1e8
///       lastCumulativeFundingRate1e18
///   - this is more robust than storing only an entry price,
///     especially for partial closes / flips / funding settlement.
///
///  Liquidation design note:
///   - liquidation is economically closed through:
///       reduction -> penalty seizure -> shortfall resolution -> residual bad debt accounting
///
///  Debt lifecycle note:
///   - residual bad debt may later be repaid through explicit protocol paths
///   - repayment reduces stored residual debt in base-token native units
abstract contract PerpEngineTypes {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Canonical normalized price scale.
    uint256 internal constant PRICE_1E8 = 1e8;

    /// @notice Canonical funding precision.
    uint256 internal constant FUNDING_SCALE_1E18 = 1e18;

    /// @dev Defensive: 10**77 fits in uint256, 10**78 does not.
    uint256 internal constant MAX_POW10_EXP = 77;

    int256 internal constant INT128_MAX = int256(type(int128).max);
    int256 internal constant INT128_MIN = int256(type(int128).min);
    int256 internal constant INT256_MAX = type(int256).max;
    int256 internal constant INT256_MIN = type(int256).min;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Signed perp position for one trader on one market.
    /// @dev
    ///  - size1e8:
    ///      signed underlying exposure
    ///      +1e8 = long 1 underlying
    ///      -5e7 = short 0.5 underlying
    ///
    ///  - openNotional1e8:
    ///      signed normalized quote notional basis used for unrealized PnL
    ///      convention:
    ///       * long opened by paying quote => positive basis
    ///       * short opened by receiving quote => negative basis
    ///
    ///  - lastCumulativeFundingRate1e18:
    ///      market funding accumulator snapshot at the last funding settlement point
    struct Position {
        int256 size1e8;
        int256 openNotional1e8;
        int256 lastCumulativeFundingRate1e18;
    }

    /// @notice Per-market mutable runtime state.
    /// @dev
    ///  - open interests are tracked as absolute underlying size in 1e8
    ///  - cumulative funding is signed and scaled by 1e18
    struct MarketState {
        uint256 longOpenInterest1e8;
        uint256 shortOpenInterest1e8;
        int256 cumulativeFundingRate1e18;
        uint64 lastFundingTimestamp;
    }

    /// @notice Margin snapshot helper.
    /// @dev
    ///  Canonical unit convention:
    ///   - all fields ending in `Base` are denominated in native units of the protocol base collateral token
    ///  This avoids ambiguity with normalized 1e8 quote amounts.
    struct MarginState {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
        int256 unrealizedPnlBase;
        int256 fundingAccruedBase;
    }

    /// @notice Funding preview helper.
    struct FundingComputation {
        int256 fundingRateDelta1e18;
        int256 nextCumulativeFundingRate1e18;
        uint64 effectiveTimestamp;
    }

    /// @notice Pure liquidation preview helper.
    /// @dev Used to reason about the liquidation clip before touching state.
    struct LiquidationPreview {
        bool isLiquidatable;
        uint128 maxClosableSize1e8;
        uint128 requestedCloseSize1e8;
        uint128 executedCloseSize1e8;
        uint256 liquidationPrice1e8;
        uint256 notionalClosed1e8;
        uint256 penaltyBase;
    }

    /// @notice Resolution detail for the economic tail of a liquidation.
    /// @dev
    ///  - penaltyTargetBase     = target incentive intended for liquidator
    ///  - seizedPenaltyBase     = value actually seized from trader collateral
    ///  - insurancePaidBase     = value covered by insurance fund
    ///  - residualShortfallBase = remaining transient shortfall after insurance
    struct LiquidationResolution {
        uint256 penaltyTargetBase;
        uint256 seizedPenaltyBase;
        uint256 insurancePaidBase;
        uint256 residualShortfallBase;
    }

    /// @notice Aggregated shortfall accounting helper.
    /// @dev
    ///  - requestedBase            = target requested during liquidation resolution
    ///  - seizedBase               = amount recovered by collateral seizure
    ///  - remainingAfterSeizureBase= transient shortfall after seizure
    ///  - insurancePaidBase        = amount covered by insurance fund
    ///  - residualBadDebtBase      = final residual uncovered amount recorded as bad debt
    struct ShortfallState {
        uint256 requestedBase;
        uint256 seizedBase;
        uint256 remainingAfterSeizureBase;
        uint256 insurancePaidBase;
        uint256 residualBadDebtBase;
    }

    /// @notice Repayment preview / accounting helper for residual bad debt.
    /// @dev
    ///  - requestedBase  = amount payer/admin intends to repay
    ///  - outstandingBase= debt before repayment
    ///  - repaidBase     = effective amount actually applied
    ///  - remainingBase  = debt left after repayment
    struct BadDebtRepayment {
        uint256 requestedBase;
        uint256 outstandingBase;
        uint256 repaidBase;
        uint256 remainingBase;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error OwnershipTransferNotInitiated();
    error NotAuthorized();
    error GuardianNotAuthorized();
    error ZeroAddress();
    error InvalidTrade();
    error InvalidMarket();
    error UnknownMarket();

    error AmountZero();
    error PriceZero();
    error SizeZero();
    error SizeTooLarge();

    error PausedError();
    error TradingPaused();
    error LiquidationPaused();
    error FundingPaused();
    error CollateralOpsPaused();

    error MarketInactive();
    error MarketCloseOnly();
    error ReduceOnlyViolation();

    error MarginRequirementBreached(address trader);
    error NotLiquidatable();
    error LiquidationNothingToDo();
    error LiquidationNotImproving();
    error LiquidationParamsInvalid();
    error LiquidationSelfNotAllowed();
    error LiquidatorWouldBreachMargin(address liquidator);
    error LiquidationPriceInvalid();
    error LiquidationPenaltyTooLarge();
    error LiquidationCloseFactorZero();

    error OraclePriceUnavailable();
    error OraclePriceStale();
    error FundingParamsInvalid();
    error FundingIntervalNotElapsed();

    error WithdrawTooLarge();
    error WithdrawWouldBreachMargin();

    error MatchingEngineNotSet();
    error RiskModuleNotSet();
    error OracleNotSet();
    error CollateralVaultNotSet();
    error InsuranceFundNotSet();
    error FeesManagerNotSet();
    error CollateralSeizerNotSet();

    error InsuranceFundCoverageFailed();
    error BadDebtOutstanding(address trader, uint256 residualBaseValue);

    error MathOverflow();
    error SignedMathOverflow();
    error CastOverflow();
    error QuantityMinNotAllowed();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    event MatchingEngineSet(address indexed newMatchingEngine);
    event OracleSet(address indexed newOracle);
    event RiskModuleSet(address indexed newRiskModule);
    event CollateralSeizerSet(address indexed oldSeizer, address indexed newSeizer);
    event InsuranceFundSet(address indexed oldFund, address indexed newFund);
    event FeesManagerSet(address indexed newFeesManager);
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event GlobalPauseSet(bool paused);
    event TradingPauseSet(bool paused);
    event LiquidationPauseSet(bool paused);
    event FundingPauseSet(bool paused);
    event CollateralOpsPauseSet(bool paused);

    event EmergencyModeUpdated(
        bool tradingPaused,
        bool liquidationPaused,
        bool fundingPaused,
        bool collateralOpsPaused
    );

    /// @notice Perp trade execution.
    /// @dev
    ///  - `sizeDelta1e8` is signed exposure magnitude expressed as an absolute uint128 clip in 1e8 underlying units
    ///  - `executionPrice1e8` is the normalized execution price
    event TradeExecuted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed marketId,
        uint128 sizeDelta1e8,
        uint128 executionPrice1e8,
        bool buyerIsMaker
    );

    event FundingUpdated(
        uint256 indexed marketId,
        int256 fundingRateDelta1e18,
        int256 newCumulativeFundingRate1e18,
        uint64 effectiveTimestamp
    );

    /// @notice Funding settled into position accounting for one trader.
    /// @dev `fundingPayment1e8` is a normalized quote amount in 1e8 units.
    event PositionFundingSettled(
        address indexed trader,
        uint256 indexed marketId,
        int256 fundingPayment1e8,
        int256 newLastCumulativeFundingRate1e18
    );

    /// @notice Terminal liquidation summary.
    /// @dev `collateralSeizedBaseValue` is denominated in native units of the protocol base collateral token.
    event Liquidation(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint128 sizeClosed1e8,
        uint256 executionPrice1e8,
        uint256 collateralSeizedBaseValue
    );

    /// @notice Total penalty effectively paid toward the liquidator incentive.
    /// @dev `penaltyBaseValue` is denominated in native units of the protocol base collateral token.
    event LiquidationPenaltyPaid(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 penaltyBaseValue
    );

    /// @notice Emitted when trader collateral does not fully cover the penalty target.
    /// @dev All values are denominated in native units of the protocol base collateral token.
    event LiquidationShortfall(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 requestedBaseValue,
        uint256 seizedBaseValue,
        uint256 shortfallBaseValue
    );

    /// @notice Emitted when InsuranceFund contributes to resolve a liquidation shortfall.
    /// @dev All values are denominated in native units of the protocol base collateral token.
    event LiquidationInsuranceCoverage(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 requestedBaseValue,
        uint256 paidBaseValue
    );

    /// @notice Emitted when liquidation still leaves a final uncovered bad debt.
    /// @dev `residualBaseValue` is denominated in native units of the protocol base collateral token.
    event LiquidationBadDebtRecorded(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 residualBaseValue
    );

    /// @notice Emitted when residual bad debt is repaid through an explicit protocol path.
    /// @dev
    ///  - `payer` = actor providing funds / initiating repayment
    ///  - `trader` = account whose debt is reduced
    ///  - `recipient` = protocol destination receiving repayment funds, if applicable
    ///  - all numeric fields are denominated in native units of the protocol base collateral token
    event ResidualBadDebtRepaid(
        address indexed payer,
        address indexed trader,
        address indexed recipient,
        uint256 requestedBaseValue,
        uint256 repaidBaseValue,
        uint256 remainingBaseValue
    );

    /// @notice User collateral deposit into the protocol vault.
    /// @dev `amount` is denominated in token-native units.
    event CollateralDeposited(address indexed trader, address indexed token, uint256 amount);

    /// @notice User collateral withdrawal from the protocol vault.
    /// @dev
    ///  - `amount` is denominated in token-native units
    ///  - `marginRatioAfterBps` is in basis points
    event CollateralWithdrawn(address indexed trader, address indexed token, uint256 amount, uint256 marginRatioAfterBps);

    /*//////////////////////////////////////////////////////////////
                          PURE / SAFE HELPERS
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

    function _subChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (b > a) revert MathOverflow();
        unchecked {
            c = a - b;
        }
    }

    function _ensureInt128Allowed(int128 x) internal pure {
        if (x == type(int128).min) revert QuantityMinNotAllowed();
    }

    function _ensureInt256Allowed(int256 x) internal pure {
        if (x == type(int256).min) revert QuantityMinNotAllowed();
    }

    function _absInt256(int256 x) internal pure returns (uint256) {
        if (x == type(int256).min) revert QuantityMinNotAllowed();
        return uint256(x >= 0 ? x : -x);
    }

    function _absInt128(int128 x) internal pure returns (uint256) {
        if (x == type(int128).min) revert QuantityMinNotAllowed();
        int256 y = int256(x);
        return uint256(y >= 0 ? y : -y);
    }

    function _toInt256(uint256 x) internal pure returns (int256 y) {
        if (x > uint256(type(int256).max)) revert CastOverflow();
        y = int256(x);
    }

    function _toUint256(int256 x) internal pure returns (uint256 y) {
        if (x < 0) revert CastOverflow();
        y = uint256(x);
    }

    function _toInt128(uint128 x) internal pure returns (int128 y) {
        if (x > uint128(type(int128).max)) revert CastOverflow();
        y = int128(int256(uint256(x)));
        _ensureInt128Allowed(y);
    }

    function _checkedAddInt256(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a + b;
        }

        if (b > 0 && r < a) revert SignedMathOverflow();
        if (b < 0 && r > a) revert SignedMathOverflow();
        if (r == type(int256).min) revert QuantityMinNotAllowed();
    }

    function _checkedSubInt256(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a - b;
        }

        if (b > 0 && r > a) revert SignedMathOverflow();
        if (b < 0 && r < a) revert SignedMathOverflow();
        if (r == type(int256).min) revert QuantityMinNotAllowed();
    }

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert MathOverflow();
        return 10 ** exp;
    }

    /// @notice Absolute notional in normalized quote 1e8 units.
    /// @dev notional = abs(size1e8) * price1e8 / 1e8
    function _absNotional1e8(int256 size1e8, uint256 price1e8) internal pure returns (uint256 notional1e8) {
        if (price1e8 == 0) revert PriceZero();
        uint256 absSize = _absInt256(size1e8);
        notional1e8 = _mulChecked(absSize, price1e8) / PRICE_1E8;
    }

    /// @notice Signed mark value in normalized quote 1e8 units.
    /// @dev value = size * price / 1e8
    function _signedMarkValue1e8(int256 size1e8, uint256 price1e8) internal pure returns (int256 value1e8) {
        if (price1e8 == 0) revert PriceZero();

        uint256 absSize = _absInt256(size1e8);
        uint256 absValue = _mulChecked(absSize, price1e8) / PRICE_1E8;
        int256 absValueSigned = _toInt256(absValue);

        value1e8 = size1e8 >= 0 ? absValueSigned : -absValueSigned;
    }

    /// @notice Unrealized PnL in normalized quote 1e8 units.
    /// @dev pnl = current signed mark value - openNotional basis
    function _unrealizedPnl1e8(int256 size1e8, int256 openNotional1e8, uint256 markPrice1e8)
        internal
        pure
        returns (int256 pnl1e8)
    {
        int256 markValue = _signedMarkValue1e8(size1e8, markPrice1e8);
        pnl1e8 = _checkedSubInt256(markValue, openNotional1e8);
    }

    /// @notice Funding payment in normalized quote 1e8 units.
    /// @dev
    ///  fundingPayment = size * (cumNow - cumLast) / 1e18
    ///  positive payment means trader owes quote if engine uses the canonical sign convention.
    function _fundingPayment1e8(int256 size1e8, int256 cumulativeFundingNow1e18, int256 cumulativeFundingLast1e18)
        internal
        pure
        returns (int256 payment1e8)
    {
        int256 delta = _checkedSubInt256(cumulativeFundingNow1e18, cumulativeFundingLast1e18);

        if (size1e8 == 0 || delta == 0) return 0;

        uint256 absSize = _absInt256(size1e8);
        uint256 absDelta = _absInt256(delta);

        uint256 absPayment = _mulChecked(absSize, absDelta) / FUNDING_SCALE_1E18;
        int256 absPaymentSigned = _toInt256(absPayment);

        bool sameSign = (size1e8 >= 0 && delta >= 0) || (size1e8 < 0 && delta < 0);
        payment1e8 = sameSign ? absPaymentSigned : -absPaymentSigned;
    }

    /// @notice Margin ratio helper in basis points.
    /// @dev
    ///  - `equityBase` and `maintenanceMarginBase` are denominated in native units of the protocol base collateral token
    function _marginRatioBpsFromState(int256 equityBase, uint256 maintenanceMarginBase) internal pure returns (uint256) {
        if (maintenanceMarginBase == 0) return type(uint256).max;
        if (equityBase <= 0) return 0;
        return (uint256(equityBase) * BPS) / maintenanceMarginBase;
    }

    /// @notice Checks whether a transition is strictly reduce-only.
    /// @dev
    ///  - old == 0 => new must be 0
    ///  - new == 0 => ok
    ///  - sign must remain identical
    ///  - absolute size must not increase
    function _isReduceOnlyTransition(int256 oldSize1e8, int256 newSize1e8) internal pure returns (bool) {
        _ensureInt256Allowed(oldSize1e8);
        _ensureInt256Allowed(newSize1e8);

        if (oldSize1e8 == 0) return newSize1e8 == 0;
        if (newSize1e8 == 0) return true;

        bool oldPos = oldSize1e8 > 0;
        bool newPos = newSize1e8 > 0;
        if (oldPos != newPos) return false;

        return _absInt256(newSize1e8) <= _absInt256(oldSize1e8);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION PURE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the maximum closeable size under a close factor.
    /// @dev Ensures at least 1 unit is closeable if absSize != 0 and closeFactorBps != 0.
    function _maxLiquidatableSize1e8(int256 positionSize1e8, uint256 closeFactorBps)
        internal
        pure
        returns (uint128 maxCloseSize1e8)
    {
        if (closeFactorBps == 0) revert LiquidationCloseFactorZero();
        if (closeFactorBps > BPS) revert LiquidationParamsInvalid();

        uint256 absSize = _absInt256(positionSize1e8);
        if (absSize == 0) return 0;

        uint256 raw = (absSize * closeFactorBps) / BPS;
        if (raw == 0) raw = 1;

        if (raw > uint256(type(uint128).max)) revert SizeTooLarge();
        return uint128(raw);
    }

    /// @notice Clamps a requested liquidation clip to the protocol maximum.
    function _boundedLiquidationSize1e8(
        int256 positionSize1e8,
        uint128 requestedCloseSize1e8,
        uint256 closeFactorBps
    ) internal pure returns (uint128 executedCloseSize1e8) {
        uint128 maxClose = _maxLiquidatableSize1e8(positionSize1e8, closeFactorBps);
        if (maxClose == 0) return 0;
        if (requestedCloseSize1e8 == 0) return maxClose;
        return requestedCloseSize1e8 < maxClose ? requestedCloseSize1e8 : maxClose;
    }

    /// @notice Computes a liquidation execution price from mark price and spread.
    /// @dev
    ///  - liquidating a long means seller-side close, so worse price = mark * (1 - spread)
    ///  - liquidating a short means buyer-side close, so worse price = mark * (1 + spread)
    function _liquidationPrice1e8FromMark(int256 liquidatedPositionSize1e8, uint256 markPrice1e8, uint256 spreadBps)
        internal
        pure
        returns (uint256 liqPrice1e8)
    {
        if (markPrice1e8 == 0) revert LiquidationPriceInvalid();
        if (spreadBps > BPS) revert LiquidationParamsInvalid();
        if (liquidatedPositionSize1e8 == 0) revert LiquidationNothingToDo();

        if (liquidatedPositionSize1e8 > 0) {
            liqPrice1e8 = (markPrice1e8 * (BPS - spreadBps)) / BPS;
        } else {
            liqPrice1e8 = (markPrice1e8 * (BPS + spreadBps)) / BPS;
        }

        if (liqPrice1e8 == 0) revert LiquidationPriceInvalid();
    }

    /// @notice Computes liquidation penalty in base-token native units.
    /// @dev penalty = closedNotionalBase * penaltyBps / 10_000
    function _liquidationPenaltyBaseValue(uint256 closedNotionalBaseValue, uint256 penaltyBps)
        internal
        pure
        returns (uint256 penaltyBaseValue)
    {
        if (penaltyBps > BPS) revert LiquidationPenaltyTooLarge();
        if (closedNotionalBaseValue == 0 || penaltyBps == 0) return 0;
        penaltyBaseValue = (closedNotionalBaseValue * penaltyBps) / BPS;
    }

    /// @notice Computes remaining shortfall after a first recovery leg.
    /// @dev All amounts are in base-token native units.
    function _remainingShortfall(uint256 targetBaseValue, uint256 recoveredBaseValue)
        internal
        pure
        virtual
        returns (uint256 remainingBaseValue)
    {
        if (recoveredBaseValue >= targetBaseValue) return 0;
        return targetBaseValue - recoveredBaseValue;
    }

    /// @notice Checks that liquidation improved the account state by at least minImprovementBps.
    /// @dev
    ///  - equity / margin inputs are in base-token native units
    ///  - output is a pure boolean policy check
    function _liquidationImproved(
        int256 equityBeforeBase,
        uint256 maintenanceMarginBeforeBase,
        int256 equityAfterBase,
        uint256 maintenanceMarginAfterBase,
        uint256 minImprovementBps
    ) internal pure returns (bool) {
        uint256 beforeRatio = _marginRatioBpsFromState(equityBeforeBase, maintenanceMarginBeforeBase);
        uint256 afterRatio = _marginRatioBpsFromState(equityAfterBase, maintenanceMarginAfterBase);

        if (equityBeforeBase > 0) {
            return afterRatio >= beforeRatio + minImprovementBps;
        }

        return (maintenanceMarginAfterBase < maintenanceMarginBeforeBase) || (equityAfterBase > equityBeforeBase);
    }
}