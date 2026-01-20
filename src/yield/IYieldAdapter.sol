// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IYieldAdapter {
    function asset() external view returns (address);

    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @dev Vault appelle deposit() après avoir fait approve(asset, adapter, amount)
    function deposit(uint256 assets) external returns (uint256 sharesMinted);

    /// @dev Retire `assets` et envoie les tokens à `to`
    function withdraw(uint256 assets, address to) external returns (uint256 sharesBurned);
}
