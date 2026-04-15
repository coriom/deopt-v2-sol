// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OptionProductRegistry} from "../OptionProductRegistry.sol";

/// @title MarginEngineTypes
/// @notice Types / constants / errors / events + pure helpers for the options engine.
/// @dev Canonical unit conventions used by this module:
///  - prices normalized by the protocol are in 1e8
///  - option contract size is fixed to 1e8 (= 1 underlying unit)
///  - token-native cash amounts use the settlement asset native decimals
///  - base risk amounts are expressed in the native decimals of the base collateral token
///  - ratios use basis points (BPS)
///
///  Naming conventions:
///  - `...1e8` => protocol-normalized amount / price
///  - `...Bps` => ratio in basis points
///  - `premium`, `paid`, `collected`, `fee`, `amount` in this file/events refer to token-native cash amounts
///
///  Economic conventions:
///  - `shortfall` is a transient deficit during an operation
///  - `badDebt` is the final residual uncovered amount recorded by the protocol
///  - options settlement accounting mirrors perp logic:
///      collection / payment -> transient shortfall -> insurance coverage -> residual bad debt
abstract contract MarginEngineTypes {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice Canonical normalized price scale.
    uint256 internal constant PRICE_1E8 = 1e8;

    /// @dev Defensive upper bound: 10**77 fits in uint256, 10**78 does not.
    uint256 internal constant MAX_POW10_EXP = 77;

    int256 internal constant INT128_MAX = int256(type(int128).max);
    int256 internal constant INT128_MIN = int256(type(int128).min);

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Terminal result of settling one account on one option series.
    /// @dev
    ///  Sign convention:
    ///   - pnl > 0 => trader was owed funds
    ///   - pnl < 0 => trader owed funds
    ///
    ///  Unit convention:
    ///   - all amounts below are denominated in settlement-asset native units
    struct SettlementResult {
        int256 pnl;
        uint256 collectedFromTrader;
        uint256 paidToTrader;
        uint256 badDebt;
    }

    /// @notice Settlement-side shortfall resolution detail.
    /// @dev
    ///  Used to mirror the perp `LiquidationResolution` semantics:
    ///   - targetAmount           = what should have been paid
    ///   - paidFromSettlementSink = what the settlement sink could actually pay
    ///   - insurancePaid          = what insurance fund additionally paid
    ///   - residualBadDebt        = final uncovered remainder
    struct SettlementResolution {
        uint256 targetAmount;
        uint256 paidFromSettlementSink;
        uint256 insurancePaid;
        uint256 residualBadDebt;
    }

    /// @notice Aggregated settlement accounting state for one series.
    /// @dev All fields are denominated in settlement-asset native units.
    struct SeriesSettlementState {
        uint256 totalCollected;
        uint256 totalPaid;
        uint256 totalBadDebt;
    }

    /// @notice Settlement preview / accounting helper for one trader / one series.
    /// @dev All cash amounts are denominated in settlement-asset native units.
    struct SettlementPreview {
        int256 pnl;
        uint256 grossAmount;
        uint256 collectibleAmount;
        uint256 payableFromSettlementSink;
        uint256 insurancePreview;
        uint256 residualBadDebtPreview;
        bool isSettled;
        bool canSettle;
    }

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

    // ownership / guardian
    error OwnershipTransferNotInitiated();
    error GuardianNotAuthorized();

    // Emergency
    error TradingPaused();
    error LiquidationPaused();
    error SettlementPaused();
    error CollateralOpsPaused();

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
    error QuantityMinNotAllowed(); // forbid int128.min (DoS / negation edge-case)
    error PnlOverflow();
    error MathOverflow();
    error MarginRequirementBreached(address trader);

    // Decimals hardening
    error DecimalsOverflow(address token);

    // Risk params strictness
    error RiskParamsMismatch();

    // Vault deposit / withdraw wrapper hardening
    error VaultDepositForNotSupported();
    error VaultWithdrawForNotSupported();

    // Fees integration
    error FeesRecipientNotSet();
    error FeesRecipientEqualsTrader();
    error FeesRecipientEqualsCounterparty();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event MatchingEngineSet(address indexed newMatchingEngine);

    /// @notice Trade execution in the options engine.
    /// @dev
    ///  - `quantity` is the number of option contracts, with fixed contractSize1e8 = 1e8
    ///  - `price` is the token-native premium per contract in settlement-asset native units
    event TradeExecuted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed optionId,
        uint128 quantity,
        uint128 price
    );

    /// @notice Local cached risk parameters synchronized against the RiskModule source of truth.
    /// @dev
    ///  - `baseCollateralToken` is the unique risk numeraire token
    ///  - `baseMaintenanceMarginPerContract` is denominated in base-token native units
    ///  - `imFactorBps` is in basis points
    event RiskParamsSet(address baseCollateralToken, uint256 baseMaintenanceMarginPerContract, uint256 imFactorBps);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // Emergency / guardian events
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);
    event GlobalPauseSet(bool paused);

    event TradingPauseSet(bool paused);
    event LiquidationPauseSet(bool paused);
    event SettlementPauseSet(bool paused);
    event CollateralOpsPauseSet(bool paused);

    event EmergencyModeUpdated(
        bool tradingPaused,
        bool liquidationPaused,
        bool settlementPaused,
        bool collateralOpsPaused
    );

    event OracleSet(address indexed newOracle);
    event RiskModuleSet(address indexed newRiskModule);

    /// @notice Liquidation trigger params.
    /// @dev
    ///  - `liquidationThresholdBps`: account considered liquidatable below this margin ratio
    ///  - `liquidationPenaltyBps`: penalty charged in basis points
    event LiquidationParamsSet(uint256 liquidationThresholdBps, uint256 liquidationPenaltyBps);

    event LiquidationHardenParamsSet(uint256 liquidationCloseFactorBps, uint256 minLiquidationImprovementBps);

    event LiquidationPricingParamsSet(uint256 liquidationPriceSpreadBps, uint256 minLiquidationPriceBpsOfIntrinsic);

    /// @notice Maximum oracle freshness tolerated by liquidation flows, in seconds. 0 = disabled.
    event LiquidationOracleMaxDelaySet(uint32 oldDelay, uint32 newDelay);

    /// @notice Terminal liquidation summary.
    /// @dev `collateralSeizedBaseValue` is expressed in base-collateral native units.
    event Liquidation(
        address indexed liquidator,
        address indexed trader,
        uint256[] optionIds,
        uint128[] quantitiesExecuted,
        uint256 collateralSeizedBaseValue
    );

    /// @notice Token-native cashflow transferred during liquidation.
    /// @dev
    ///  - `settlementAsset` is the token used for this cash leg
    ///  - `cashPaidByTrader` and `cashRequested` are in settlement-asset native units
    event LiquidationCashflow(
        address indexed liquidator,
        address indexed trader,
        address indexed settlementAsset,
        uint256 cashPaidByTrader,
        uint256 cashRequested
    );

    /// @notice User collateral deposit into the protocol vault.
    /// @dev `amount` is in token-native units.
    event CollateralDeposited(address indexed trader, address indexed token, uint256 amount);

    /// @notice User collateral withdrawal from the protocol vault.
    /// @dev
    ///  - `amount` is in token-native units
    ///  - `marginRatioAfterBps` is the projected post-withdraw risk ratio
    event CollateralWithdrawn(address indexed trader, address indexed token, uint256 amount, uint256 marginRatioAfterBps);

    event InsuranceFundSet(address indexed oldFund, address indexed newFund);

    /// @notice Per-account terminal settlement result.
    /// @dev
    ///  Sign convention:
    ///   - pnl > 0  => trader was owed funds
    ///   - pnl < 0  => trader owed funds
    ///
    ///  Accounting convention:
    ///   - collectedFromTrader = amount actually recovered from the trader account
    ///   - paidToTrader        = amount actually paid to the trader
    ///   - badDebt             = final residual uncovered amount
    ///
    ///  Unit convention:
    ///   - `collectedFromTrader`, `paidToTrader`, `badDebt` are all in settlement-asset native units
    ///
    ///  Therefore:
    ///   - if pnl > 0:  uint256(pnl)  == paidToTrader + badDebt
    ///   - if pnl < 0:  uint256(-pnl) == collectedFromTrader + badDebt
    event AccountSettled(
        address indexed trader,
        uint256 indexed optionId,
        int256 pnl,
        uint256 collectedFromTrader,
        uint256 paidToTrader,
        uint256 badDebt
    );

    /// @notice Running settlement accounting for a series.
    /// @dev
    ///  Aggregates are cumulative across all settled accounts of the series:
    ///   - totalCollected = total amount recovered from losing traders
    ///   - totalPaid      = total amount actually paid to winning traders
    ///   - totalBadDebt   = total residual uncovered amount
    ///
    ///  Unit convention:
    ///   - all three fields are denominated in the series settlement-asset native units
    event SeriesSettlementAccountingUpdated(
        uint256 indexed optionId,
        uint256 totalCollected,
        uint256 totalPaid,
        uint256 totalBadDebt
    );

    /// @notice Options settlement-side shortfall observed for a winning account.
    /// @dev All amounts are denominated in settlement-asset native units.
    event SettlementShortfall(
        address indexed trader,
        uint256 indexed optionId,
        uint256 requestedAmount,
        uint256 paidFromSettlementSink,
        uint256 shortfall
    );

    /// @notice Insurance fund contribution to options settlement.
    /// @dev All amounts are denominated in settlement-asset native units.
    event SettlementInsuranceCoverage(
        address indexed trader,
        uint256 indexed optionId,
        uint256 requestedAmount,
        uint256 paidAmount
    );

    /// @notice Final residual bad debt recorded during options settlement.
    /// @dev All amounts are denominated in settlement-asset native units.
    event SettlementBadDebtRecorded(address indexed trader, uint256 indexed optionId, uint256 residualBadDebt);

    /// @notice Collateral seized during liquidation.
    /// @dev
    ///  - `amountToken` is denominated in the seized token native units
    ///  - `seizedBaseValue` is denominated in base-collateral native units
    event LiquidationSeize(
        address indexed liquidator,
        address indexed trader,
        address indexed token,
        uint256 amountToken,
        uint256 seizedBaseValue
    );

    // Fees admin / config
    event FeesManagerSet(address indexed newFeesManager);
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Trading fee charged during options execution.
    /// @dev
    ///  Unit convention:
    ///   - `premium`, `notionalImplicit`, `notionalFee`, `premiumCapFee`, `appliedFee`
    ///     are all denominated in settlement-asset native units
    event TradingFeeCharged(
        address indexed trader,
        address indexed recipient,
        address indexed settlementAsset,
        uint256 optionId,
        bool isMaker,
        uint256 premium,
        uint256 notionalImplicit,
        uint256 notionalFee,
        uint256 premiumCapFee,
        uint256 appliedFee,
        bool cappedByPremium
    );

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

    function _ensureQtyAllowed(int128 q) internal pure {
        if (q == type(int128).min) revert QuantityMinNotAllowed();
    }

    function _toInt128(uint128 x) internal pure returns (int128) {
        if (x > uint128(type(int128).max)) revert QuantityTooLarge();
        return SafeCast.toInt128(int256(uint256(x)));
    }

    function _checkedAddInt128(int128 a, int128 b) internal pure returns (int128 r) {
        int256 rr = int256(a) + int256(b);
        if (rr == INT128_MIN) revert QuantityMinNotAllowed();
        if (rr > INT128_MAX || rr < INT128_MIN) revert QuantityTooLarge();
        r = SafeCast.toInt128(rr);
        _ensureQtyAllowed(r);
    }

    function _checkedSubInt128(int128 a, int128 b) internal pure returns (int128 r) {
        int256 rr = int256(a) - int256(b);
        if (rr == INT128_MIN) revert QuantityMinNotAllowed();
        if (rr > INT128_MAX || rr < INT128_MIN) revert QuantityTooLarge();
        r = SafeCast.toInt128(rr);
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
        // PRICE_1E8 is the fixed 1e8 scale constant, so the uint128 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
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

    /// @notice Converts account risk into a margin ratio.
    /// @dev
    ///  - `equity` and `maintenanceMargin` are denominated in base-collateral native units
    ///  - output is in basis points
    function _marginRatioBpsFromRisk(int256 equity, uint256 maintenanceMargin) internal pure returns (uint256) {
        if (maintenanceMargin == 0) return type(uint256).max;
        if (equity <= 0) return 0;
        // equity is strictly positive above, so the uint256 cast preserves the value.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(equity) * BPS) / maintenanceMargin;
    }

    /// @notice Intrinsic value per option contract in normalized 1e8 quote units.
    /// @dev Returned value is a price-like amount in 1e8, not token-native cash.
    function _intrinsic1e8(OptionProductRegistry.OptionSeries memory s, uint256 spot1e8)
        internal
        pure
        returns (uint256 intrinsic)
    {
        if (spot1e8 == 0) return 0;

        if (s.isCall) {
            intrinsic = spot1e8 > uint256(s.strike) ? (spot1e8 - uint256(s.strike)) : 0;
        } else {
            intrinsic = uint256(s.strike) > spot1e8 ? (uint256(s.strike) - spot1e8) : 0;
        }
    }
}
