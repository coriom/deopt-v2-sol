// ChainlinkPriceSource.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @dev Interface minimale de Chainlink V3
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

/// @title ChainlinkPriceSource
/// @notice Adapte un agrégateur Chainlink vers IPriceSource (prix normalisé en 1e8).
/// @dev
///  - Revert sur données invalides: OracleRouter catch et fallback.
///  - Normalisation:
///      * dec == 8 : price = raw
///      * dec > 8  : price = raw / 10^(dec-8)
///      * dec < 8  : price = raw * 10^(8-dec)
contract ChainlinkPriceSource is IPriceSource {
    uint8 internal constant TARGET_DECIMALS = 8;
    uint256 internal constant MAX_POW10_EXP = 77;

    AggregatorV3Interface public immutable aggregator;
    uint8 public immutable aggregatorDecimals;

    error ZeroAggregator();
    error InvalidDecimals();
    error InvalidAnswer();
    error InvalidRound();
    error InvalidTimestamp();
    error ScaleOverflow();
    error Pow10Overflow();

    constructor(address _aggregator) {
        if (_aggregator == address(0)) revert ZeroAggregator();
        aggregator = AggregatorV3Interface(_aggregator);

        uint8 dec = aggregator.decimals();
        // Défensif: Chainlink typiquement <= 18, mais on borne proprement pour éviter 10**k dangereux
        if (dec > 36) revert InvalidDecimals(); // borne large, mais réaliste
        aggregatorDecimals = dec;
    }

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert Pow10Overflow();
        return 10 ** exp;
    }

    /// @inheritdoc IPriceSource
    function getLatestPrice()
        external
        view
        override
        returns (uint256 price, uint256 updatedAt)
    {
        (uint80 roundId, int256 answer, , uint256 updatedAt_, uint80 answeredInRound) =
            aggregator.latestRoundData();

        // Round sanity (Chainlink best practice)
        if (roundId == 0) revert InvalidRound();
        if (answeredInRound < roundId) revert InvalidRound();

        if (updatedAt_ == 0) revert InvalidTimestamp();
        if (answer <= 0) revert InvalidAnswer();

        uint256 raw = uint256(answer);
        uint8 dec = aggregatorDecimals;

        if (dec == TARGET_DECIMALS) {
            price = raw;
        } else if (dec > TARGET_DECIMALS) {
            uint256 diff = uint256(dec - TARGET_DECIMALS);
            uint256 factor = _pow10(diff);
            price = raw / factor; // floor (ok)
        } else {
            uint256 diff = uint256(TARGET_DECIMALS - dec);
            uint256 factor = _pow10(diff);
            if (raw != 0 && factor > type(uint256).max / raw) revert ScaleOverflow();
            price = raw * factor;
        }

        if (price == 0) revert InvalidAnswer();
        updatedAt = updatedAt_;
    }
}
