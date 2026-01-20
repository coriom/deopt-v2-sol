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
    AggregatorV3Interface public immutable aggregator;
    uint8 public immutable aggregatorDecimals; // décimales natives de Chainlink

    error InvalidAnswer();
    error InvalidDecimals();

    constructor(address _aggregator) {
        require(_aggregator != address(0), "ZERO_AGGREGATOR");
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
        // latestRoundData retourne 5 valeurs : (roundId, answer, startedAt, updatedAt, answeredInRound)
        (, int256 answer, , uint256 updatedAt_, ) = aggregator.latestRoundData();

        if (answer <= 0) revert InvalidAnswer();

        uint256 raw = uint256(answer);
        uint8 dec = aggregatorDecimals;

        // Normalisation en 1e8
        if (dec == 8) {
            // déjà en 1e8
            price = raw;
        } else if (dec > 8) {
            // ex: 1e18 -> / 1e10
            uint256 factor = 10 ** uint256(dec - 8);
            price = raw / factor;
        } else {
            // ex: 1e6 -> * 1e2
            uint256 factor = 10 ** uint256(8 - dec);
            price = raw * factor;
        }

        updatedAt = updatedAt_;
    }
}
