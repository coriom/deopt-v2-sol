// src/oracle/IPriceSource.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceSource
/// @notice Interface générique pour une source de prix (Chainlink, Pyth, mock, etc.)
/// @dev Convention:
///  - price est normalisé en 1e8 (PRICE_SCALE).
///  - updatedAt est un timestamp UNIX (seconds).
///  - Recommandations hardening (côté impl):
///      * price > 0
///      * updatedAt != 0
///      * updatedAt <= block.timestamp
interface IPriceSource {
    /// @notice Scale canonique des prix retournés.
    uint256 constant PRICE_SCALE = 1e8;

    /// @return price Prix normalisé en 1e8
    /// @return updatedAt Timestamp UNIX de la dernière mise à jour du prix
    function getLatestPrice() external view returns (uint256 price, uint256 updatedAt);
}
