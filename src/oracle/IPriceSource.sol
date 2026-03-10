// src/oracle/IPriceSource.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceSource
/// @notice Interface générique pour une source de prix unitaire (Chainlink, Pyth, mock, stable peg, etc.).
/// @dev Convention canonique DeOpt:
///  - `price` est normalisé en 1e8.
///  - `updatedAt` est un timestamp UNIX en secondes.
///  - La source est censée représenter le prix d'un feed unique déjà résolu.
///  - Le router reste responsable de:
///      * la staleness policy,
///      * les fallbacks,
///      * les checks de déviation,
///      * l'inversion base/quote si nécessaire.
///
///  Hardening recommandé côté implémentations:
///  - `price > 0`
///  - `updatedAt != 0`
///  - `updatedAt <= block.timestamp`
///
///  Philosophie:
///  - `getLatestPrice()` peut revert si la donnée sous-jacente est invalide.
///  - Le router consomme cette interface en best-effort via try/catch.
interface IPriceSource {
    /// @notice Scale canonique des prix retournés par toutes les implémentations.
    uint256 constant PRICE_SCALE = 1e8;

    /// @notice Retourne le dernier prix disponible de la source.
    /// @dev
    ///  - `price` est exprimé en 1e8.
    ///  - `updatedAt` correspond au timestamp effectif de la donnée, pas au timestamp de lecture.
    ///  - Peut revert si la source considère la donnée invalide.
    function getLatestPrice() external view returns (uint256 price, uint256 updatedAt);
}