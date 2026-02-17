// contracts/margin/MarginEngineTypes.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OptionProductRegistry} from "../OptionProductRegistry.sol";

/// @notice Types/Constants/Errors/Events + helpers purs (no storage)
abstract contract MarginEngineTypes {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_1E8 = 1e8;

    // defensive: 10**77 fits in uint256, 10**78 overflows
    uint256 internal constant MAX_POW10_EXP = 77;

    int256 internal constant INT128_MAX = int256(type(int128).max);
    int256 internal constant INT128_MIN = int256(type(int128).min);

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

    event SeriesSettlementAccountingUpdated(
        uint256 indexed optionId,
        uint256 totalCollected,
        uint256 totalPaid,
        uint256 totalBadDebt
    );

    event LiquidationSeize(
        address indexed liquidator,
        address indexed trader,
        address indexed token,
        uint256 amountToken,
        uint256 seizedBaseValue
    );

    /*//////////////////////////////////////////////////////////////
                        INTERNAL PARAM INTERFACE
    //////////////////////////////////////////////////////////////*/

    interface IRiskModuleParams {
        function baseCollateralToken() external view returns (address);
        function baseMaintenanceMarginPerContract() external view returns (uint256);
        function imFactorBps() external view returns (uint256);
    }

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
        return int128(int256(uint256(x)));
    }

    function _checkedAddInt128(int128 a, int128 b) internal pure returns (int128 r) {
        int256 rr = int256(a) + int256(b);
        if (rr == INT128_MIN) revert QuantityMinNotAllowed();
        if (rr > INT128_MAX || rr < INT128_MIN) revert QuantityTooLarge();
        r = int128(rr);
        _ensureQtyAllowed(r);
    }

    function _checkedSubInt128(int128 a, int128 b) internal pure returns (int128 r) {
        int256 rr = int256(a) - int256(b);
        if (rr == INT128_MIN) revert QuantityMinNotAllowed();
        if (rr > INT128_MAX || rr < INT128_MIN) revert QuantityTooLarge();
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

    function _marginRatioBpsFromRisk(int256 equity, uint256 maintenanceMargin) internal pure returns (uint256) {
        if (maintenanceMargin == 0) return type(uint256).max;
        if (equity <= 0) return 0;
        return (uint256(equity) * BPS) / maintenanceMargin;
    }

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
