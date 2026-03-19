// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @title PeggedStablePriceSource
/// @notice Retourne toujours un prix fixe (ex: 1e8 pour 1.0), pour des stablecoins peggés.
/// @dev
///  - Source purement statique.
///  - updatedAt = block.timestamp pour rester compatible avec la logique de fraîcheur du router.
///  - À réserver aux actifs explicitement assumés comme peggés côté gouvernance.
contract PeggedStablePriceSource is IPriceSource {
    uint256 public immutable price; // ex: 1e8

    error PriceZero();

    constructor(uint256 _price) {
        if (_price == 0) revert PriceZero();
        price = _price;
    }

    /// @inheritdoc IPriceSource
    function getLatestPrice() external view override returns (uint256, uint256) {
        return (price, block.timestamp);
    }
}