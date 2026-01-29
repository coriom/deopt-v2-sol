// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @title PeggedStablePriceSource
/// @notice Retourne toujours un prix fixe (ex: 1e8 pour 1.0), pour des stablecoins peggés.
/// @dev updatedAt = block.timestamp (timestamp "vivant" pour la staleness du Router).
contract PeggedStablePriceSource is IPriceSource {
    uint256 public immutable price; // ex: 1e8

    error PriceZero();

    constructor(uint256 _price) {
        if (_price == 0) revert PriceZero();
        price = _price;
    }

    function getLatestPrice()
        external
        view
        override
        returns (uint256, uint256)
    {
        return (price, block.timestamp);
    }
}
