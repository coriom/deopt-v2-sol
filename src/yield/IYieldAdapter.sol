// contracts/yield/IYieldAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IYieldAdapter
/// @notice Interface standardisée pour une stratégie de rendement utilisée par CollateralVault.
/// @dev Invariants et conventions de rounding:
///  - totalAssets() : quantité totale d'assets sous gestion (principal + intérêts), en unités de `asset()`.
///  - totalShares(): supply interne de shares de l'adapter (comptabilité).
///
///  - previewDeposit(assets)  -> sharesMinted : arrondi DOWN (floor)
///  - previewWithdraw(assets) -> sharesBurned : arrondi UP   (ceil)  (pour garantir que l'adapter brûle assez)
///  - previewRedeem(shares)   -> assetsOut    : arrondi DOWN (floor)
///  - previewMint(shares)     -> assetsIn     : arrondi UP   (ceil)
///
///  - convertToShares / convertToAssets sont conservées pour compatibilité,
///    et DOIVENT être cohérentes avec previewDeposit/previewRedeem (floor).
///    Ne PAS utiliser convertToShares pour estimer un withdraw (il faut previewWithdraw).
interface IYieldAdapter {
    /// @notice L'asset sous-jacent géré par l'adapter (ex: USDC).
    function asset() external view returns (address);

    /// @notice Décimales de l’asset (ex: 6 pour USDC). OPTIONNEL mais utile pour sanity-check.
    function assetDecimals() external view returns (uint8);

    /// @notice Total d'assets actuellement sous gestion (principal + intérêts), en unités de l'asset.
    function totalAssets() external view returns (uint256);

    /// @notice Total de shares émises par l'adapter (supply interne).
    function totalShares() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            PREVIEWS (CANONICAL)
    //////////////////////////////////////////////////////////////*/

    /// @notice Prévisualise les shares mintées pour `assets` déposés (floor).
    function previewDeposit(uint256 assets) external view returns (uint256 sharesMinted);

    /// @notice Prévisualise les shares nécessaires à brûler pour retirer `assets` (ceil).
    function previewWithdraw(uint256 assets) external view returns (uint256 sharesBurned);

    /// @notice Prévisualise les assets reçus en brûlant `shares` (floor).
    function previewRedeem(uint256 shares) external view returns (uint256 assetsOut);

    /// @notice Prévisualise les assets nécessaires pour minter `shares` (ceil).
    function previewMint(uint256 shares) external view returns (uint256 assetsIn);

    /*//////////////////////////////////////////////////////////////
                        CONVERSION HELPERS (FLOOR)
    //////////////////////////////////////////////////////////////*/

    /// @notice Convertit `assets` -> `shares` avec arrondi DOWN (floor).
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Convertit `shares` -> `assets` avec arrondi DOWN (floor).
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Le Vault appelle deposit() après avoir fait transfer/approve selon le modèle de l'adapter.
    /// @return sharesMinted Shares effectivement mintées (DOIT matcher previewDeposit).
    function deposit(uint256 assets) external returns (uint256 sharesMinted);

    /// @dev Retire exactement `assets` et envoie les tokens à `to`.
    /// @return sharesBurned Shares effectivement brûlées (DOIT matcher previewWithdraw).
    function withdraw(uint256 assets, address to) external returns (uint256 sharesBurned);

    /*//////////////////////////////////////////////////////////////
                              OPTIONAL ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency pull (optionnel) pour récupérer des fonds au Vault (ex: pause Aave).
    /// @dev Si non supporté, l’impl peut revert.
    function emergencyWithdrawTo(address to, uint256 assets) external returns (uint256 sharesBurned);
}
