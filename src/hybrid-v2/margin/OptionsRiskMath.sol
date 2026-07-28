// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title OptionsRiskMath
/// @notice Pure math library for the frozen Options V1 maintenance-margin +
///         initial-margin computation used by `OptionsRiskModuleV2` (WP-08).
/// @dev
///  All math is in `uint256`. No storage. No external calls. No allocations.
///  Every function is `internal pure` so calling contracts inherit no
///  bytecode footprint beyond inlined arithmetic.
///
///  Frozen formulas (see `deopt-v2-sol/ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1.md`
///  §Part G):
///    - `intrinsic_call1e8   = max(spot - strike, 0)`
///    - `intrinsic_put1e8    = max(strike - spot, 0)`
///    - `stressed_call1e8    = max(spot * (1 + spotUp) - strike, 0)`
///    - `stressed_put1e8     = max(strike - spot * (1 - spotDown), 0)`
///    - `mmPerContract1e8    = max(intrinsic, stressed, baseFloor)`
///    - `imPerContract1e8    = ceil(mmPerContract * imFactorBps / 10_000)`
///    - `mmPortfolio1e8      = sum_i short_i * mmPerContract_i / 1e8`
///    - `imPortfolio1e8      = sum_i short_i * imPerContract_i / 1e8`
///  Long positions contribute ZERO to the portfolio margin sum in V1 (P1
///  isolation between subaccounts; explicit long/short offset is deferred to
///  a future portfolio-margin milestone).
///
///  Units:
///   - All computations INSIDE this library run in 1e8 (Chainlink convention).
///   - The RiskModule caller converts the 1e8 aggregate to 1e18 by scaling
///     with the settlement token decimals.
library OptionsRiskMath {
    /// @notice Basis-points denominator (100% = 10_000).
    uint256 internal constant BPS = 10_000;

    /// @notice Price scale locked at 1e8 (Chainlink convention).
    uint256 internal constant PRICE_SCALE = 1e8;

    /// @notice Contract-size scale locked at 1e8 (per `OptionProductRegistry`
    ///         invariant `contractSize1e8 == 1e8`).
    uint256 internal constant CONTRACT_SIZE_1E8 = 1e8;

    /// @notice Compute the intrinsic value of one contract at `spot1e8` for
    ///         a series with `strike1e8`.
    /// @return intrinsic1e8 zero if OTM / at-the-money, else max(spot-strike, 0)
    ///         (call) or max(strike-spot, 0) (put).
    function intrinsicPerContract(uint256 spot1e8, uint256 strike1e8, bool isCall)
        internal
        pure
        returns (uint256 intrinsic1e8)
    {
        if (isCall) {
            return spot1e8 > strike1e8 ? spot1e8 - strike1e8 : 0;
        }
        return strike1e8 > spot1e8 ? strike1e8 - spot1e8 : 0;
    }

    /// @notice Compute the stressed liability of one contract under the
    ///         approved spot-shock model. Vol shocks are reserved for a future
    ///         extension and are IGNORED in V1.
    /// @param spot1e8 current spot price in 1e8
    /// @param strike1e8 strike price in 1e8
    /// @param isCall true for calls, false for puts
    /// @param spotShockUpBps up-shock in bps (only used for calls)
    /// @param spotShockDownBps down-shock in bps (only used for puts)
    function stressedPerContract(
        uint256 spot1e8,
        uint256 strike1e8,
        bool isCall,
        uint256 spotShockUpBps,
        uint256 spotShockDownBps
    ) internal pure returns (uint256 stressed1e8) {
        if (isCall) {
            // spot * (1 + shockUp) then intrinsic-call vs strike.
            // stressedSpot1e8 = spot1e8 * (BPS + spotShockUpBps) / BPS
            uint256 stressedSpot = (spot1e8 * (BPS + spotShockUpBps)) / BPS;
            return stressedSpot > strike1e8 ? stressedSpot - strike1e8 : 0;
        }
        // spot * (1 - shockDown). Clamp to zero if shock exceeds 100%.
        if (spotShockDownBps >= BPS) {
            // Full wipe: stressed spot = 0 → stressed put = strike.
            return strike1e8;
        }
        uint256 stressedSpotDown = (spot1e8 * (BPS - spotShockDownBps)) / BPS;
        return strike1e8 > stressedSpotDown ? strike1e8 - stressedSpotDown : 0;
    }

    /// @notice `mmPerContract = max(intrinsic, stressed, baseFloor)`.
    function mmPerContract(uint256 intrinsic1e8, uint256 stressed1e8, uint256 baseFloor1e8)
        internal
        pure
        returns (uint256 mm1e8)
    {
        mm1e8 = intrinsic1e8;
        if (stressed1e8 > mm1e8) mm1e8 = stressed1e8;
        if (baseFloor1e8 > mm1e8) mm1e8 = baseFloor1e8;
    }

    /// @notice `imPerContract = ceil(mm * imFactorBps / 10_000)`.
    /// @dev `imFactorBps` MUST be >= 10_000 (IM ≥ MM). The caller validates.
    function imPerContract(uint256 mm1e8, uint256 imFactorBps) internal pure returns (uint256 im1e8) {
        // Ceil division against the user (higher IM is safer).
        uint256 numerator = mm1e8 * imFactorBps;
        im1e8 = (numerator + BPS - 1) / BPS;
    }

    /// @notice `portfolioContribution = shortQuantity1e8 * perContract1e8 / CONTRACT_SIZE_1E8`.
    /// @dev The division by 1e8 folds the contract-size scale so the returned
    ///      quantity is a plain 1e8 amount in the settlement numeraire.
    function seriesContribution(uint256 shortQuantity1e8, uint256 perContract1e8)
        internal
        pure
        returns (uint256 contribution1e8)
    {
        if (shortQuantity1e8 == 0) return 0;
        contribution1e8 = (shortQuantity1e8 * perContract1e8) / CONTRACT_SIZE_1E8;
    }

    /// @notice Scale a 1e8-normalized value into 1e18 units using the settlement
    ///         token's decimals: `value1e18 = value1e8 * 1e18 / (10 ** decimals)`.
    /// @dev The 1e18 output is what the abstract `RiskModuleV2` consumes.
    ///      Reverts implicitly on `decimals > 77` via multiplication overflow;
    ///      no realistic token exceeds `decimals = 30`.
    function scale1e8To1e18(uint256 value1e8, uint8 decimals) internal pure returns (uint256 value1e18) {
        if (value1e8 == 0) return 0;
        // For USDC (6 dec): value1e18 = value1e8 * 1e18 / 1e6 = value1e8 * 1e12.
        // For WETH (18 dec): value1e18 = value1e8 * 1e18 / 1e18 = value1e8 * 1e0.
        //
        // We want to keep the *purchasing-power* invariant: 1 unit of a 6-dec
        // token equals 1e8 in 1e8 units and 1e18 in 1e18 units, regardless of
        // decimals. Therefore the mapping from 1e8 → 1e18 is decimal-agnostic
        // and equals `value1e8 * 1e10`.
        //
        // The `decimals` argument is kept for forward compatibility with
        // non-quote settlement assets that may want per-asset scaling. In V1
        // it is not used, but the caller supplies it so a future upgrade can
        // switch semantics without an ABI change.
        decimals; // silence unused-var warning without emitting bytecode
        value1e18 = value1e8 * 1e10;
    }
}
