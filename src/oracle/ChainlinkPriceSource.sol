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
contract ChainlinkPriceSource is IPriceSource {
    uint8 internal constant TARGET_DECIMALS = 8;

    AggregatorV3Interface public immutable aggregator;
    uint8 public immutable aggregatorDecimals;

    error ZeroAggregator();
    error InvalidDecimals();
    error InvalidAnswer();
    error InvalidRound();
    error InvalidTimestamp();
    error ScaleOverflow();

    constructor(address _aggregator) {
        if (_aggregator == address(0)) revert ZeroAggregator();
        aggregator = AggregatorV3Interface(_aggregator);

        uint8 dec = aggregator.decimals();
        // Défensif : Chainlink est généralement <= 18 décimales (8, 18…)
        if (dec > 18) revert InvalidDecimals();
        aggregatorDecimals = dec;
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
        if (answeredInRound < roundId) revert InvalidRound();

        // Timestamp must be set (Router gère ensuite la staleness)
        if (updatedAt_ == 0) revert InvalidTimestamp();

        if (answer <= 0) revert InvalidAnswer();

        uint256 raw = uint256(answer);
        uint8 dec = aggregatorDecimals;

        if (dec == TARGET_DECIMALS) {
            price = raw;
        } else if (dec > TARGET_DECIMALS) {
            uint256 factor = 10 ** uint256(dec - TARGET_DECIMALS);
            price = raw / factor;
        } else {
            uint256 factor = 10 ** uint256(TARGET_DECIMALS - dec);
            if (raw != 0 && factor > type(uint256).max / raw) revert ScaleOverflow();
            price = raw * factor;
        }

        if (price == 0) revert InvalidAnswer();

        updatedAt = updatedAt_;
    }
}
