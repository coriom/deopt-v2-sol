// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface de l'oracle central utilisé par le moteur de marge.
interface IOracle {
    /// @notice Retourne le prix du sous-jacent en asset de règlement.
    /// @param underlying Sous-jacent (ex: WETH)
    /// @param settlementAsset Asset de règlement (ex: USDC)
    /// @return price Prix en 1e8 (ex: 2500$ => 2500 * 1e8)
    /// @return updatedAt Timestamp de dernière mise à jour du prix
    function getPrice(address underlying, address settlementAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt);
}
