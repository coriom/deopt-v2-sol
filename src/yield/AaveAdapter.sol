// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./IYieldAdapter.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title AaveAdapter
/// @notice Adapter “vault-managed shares” pour Aave v3 : seul le Vault appelle deposit/withdraw.
/// @dev
///  - totalAssets() ≈ balance(aToken) (aToken accrue les intérêts via balance croissant)
///  - Shares internes suivent une logique type ERC4626:
///      * deposit: shares = floor(assets * totalShares / totalAssets)
///      * withdraw: shares = ceil(assets * totalShares / totalAssets)
///  - IMPORTANT: jamais de "mint 1 share" sur dust -> sinon dilution / vol de valeur.
///    Si previewDeposit retourne 0 shares, on revert (assets trop faibles).
contract AaveAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    error NotVault();
    error ZeroAddress();
    error AmountZero();
    error ZeroAssetsUnderManagement();
    error ZeroSharesMinted();
    error InsufficientShares();
    error WithdrawSlippage();

    address public immutable vault;
    address public immutable override asset;
    address public immutable aToken;
    IAaveV3Pool public immutable pool;

    uint256 public override totalShares;

    constructor(address _vault, address _pool, address _asset, address _aToken) {
        if (_vault == address(0) || _pool == address(0) || _asset == address(0) || _aToken == address(0)) {
            revert ZeroAddress();
        }
        vault = _vault;
        pool = IAaveV3Pool(_pool);
        asset = _asset;
        aToken = _aToken;

        // approve max vers Aave pool
        IERC20(_asset).forceApprove(_pool, type(uint256).max);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    function totalAssets() public view override returns (uint256) {
        // Pour Aave v3, aToken balance représente (principal + intérêts) en unités de l’asset.
        return IERC20(aToken).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEWS (CANONICAL)
    //////////////////////////////////////////////////////////////*/

    function previewDeposit(uint256 assets) public view override returns (uint256 sharesMinted) {
        if (assets == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        // Bootstrap: 1 share = 1 asset
        if (ts == 0 || ta == 0) return assets;

        // floor
        sharesMinted = Math.mulDiv(assets, ts, ta, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 sharesBurned) {
        if (assets == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        // Si ts>0 alors ta doit être >0, sinon l'adapter est dans un état incohérent.
        if (ts == 0) return 0;
        if (ta == 0) revert ZeroAssetsUnderManagement();

        // ceil
        sharesBurned = Math.mulDiv(assets, ts, ta, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256 assetsOut) {
        if (shares == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0) return 0;
        if (ta == 0) revert ZeroAssetsUnderManagement();

        // floor
        assetsOut = Math.mulDiv(shares, ta, ts, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256 assetsIn) {
        if (shares == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        // Bootstrap: 1 share = 1 asset
        if (ts == 0 || ta == 0) return shares;

        // ceil
        assetsIn = Math.mulDiv(shares, ta, ts, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERSION HELPERS (FLOOR)
    //////////////////////////////////////////////////////////////*/

    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        // floor conversion, coherent with previewDeposit
        return previewDeposit(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assetsOut) {
        // floor conversion, coherent with previewRedeem
        return previewRedeem(shares);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets) external override onlyVault returns (uint256 sharesMinted) {
        if (assets == 0) revert AmountZero();

        sharesMinted = previewDeposit(assets);
        // IMPORTANT: refuse dust that would mint 0 shares (would otherwise donate value to existing holders)
        if (sharesMinted == 0) revert ZeroSharesMinted();

        // pull l’asset depuis le vault (vault doit avoir approuvé)
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        totalShares = totalShares + sharesMinted;

        // supply Aave
        pool.supply(asset, assets, address(this), 0);
    }

    function withdraw(uint256 assets, address to) external override onlyVault returns (uint256 sharesBurned) {
        if (assets == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        sharesBurned = previewWithdraw(assets);
        if (sharesBurned == 0) revert InsufficientShares();

        uint256 ts = totalShares;
        if (sharesBurned > ts) revert InsufficientShares();

        totalShares = ts - sharesBurned;

        uint256 got = pool.withdraw(asset, assets, to);
        if (got != assets) revert WithdrawSlippage();
    }
}
