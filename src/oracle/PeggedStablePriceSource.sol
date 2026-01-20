// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @title PeggedStablePriceSource
/// @notice Retourne toujours un prix fixe (ex: 1e8 pour 1.0), pour des stablecoins fortement peggés.
/// @dev Tu peux l'utiliser comme USDC/USD ou USDT/USD par exemple.
contract PeggedStablePriceSource is IPriceSource {
    uint256 public immutable price; // ex: 1e8
    uint256 public immutable startedAt;

    constructor(uint256 _price) {
        require(_price > 0, "PRICE_ZERO");
        price = _price;
        startedAt = block.timestamp;
    }

    function getLatestPrice()
        external
        view
        override
        returns (uint256, uint256)
    {
        // On renvoie un timestamp "vivant" pour ne pas être considéré comme stale
        return (price, block.timestamp);
    }
}
