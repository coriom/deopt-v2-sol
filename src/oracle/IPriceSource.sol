// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceSource
/// @notice Interface générique pour une source de prix (Chainlink, Pyth, mock, etc.)
/// @dev Convention: retourne un prix normalisé en 1e8 et un timestamp UNIX `updatedAt`.
interface IPriceSource {
    /// @return price Prix normalisé en 1e8
    /// @return updatedAt Timestamp UNIX de la dernière mise à jour du prix
    function getLatestPrice() external view returns (uint256 price, uint256 updatedAt);
}
