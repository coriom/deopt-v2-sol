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

/// @notice Adapter “vault-managed shares” : seul le Vault appelle deposit/withdraw.
/// @dev totalAssets ≈ balance(aToken) (aToken accrue les intérêts en augmentant le balance).
contract AaveAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    error NotVault();
    error ZeroAddress();
    error AmountZero();

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

    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        if (assets == 0) return 0;
        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        if (ts == 0 || ta == 0) return assets;
        // floor
        shares = Math.mulDiv(assets, ts, ta, Math.Rounding.Floor);
        if (shares == 0) shares = 1; // évite de mint 0 share (dust)
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assets) {
        if (shares == 0) return 0;
        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        if (ts == 0) return 0;
        assets = Math.mulDiv(shares, ta, ts, Math.Rounding.Floor);
    }

    function deposit(uint256 assets) external override onlyVault returns (uint256 sharesMinted) {
        if (assets == 0) revert AmountZero();

        // pull l’asset depuis le vault
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        // calc shares
        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        if (ts == 0 || ta == 0) {
            sharesMinted = assets;
        } else {
            sharesMinted = Math.mulDiv(assets, ts, ta, Math.Rounding.Floor);
            if (sharesMinted == 0) sharesMinted = 1;
        }

        totalShares = ts + sharesMinted;

        // supply Aave
        pool.supply(asset, assets, address(this), 0);
    }

    function withdraw(uint256 assets, address to) external override onlyVault returns (uint256 sharesBurned) {
        if (assets == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        // shares = ceil(assets * ts / ta) pour garantir assez
        sharesBurned = Math.mulDiv(assets, ts, ta, Math.Rounding.Ceil);
        if (sharesBurned > ts) sharesBurned = ts;

        totalShares = ts - sharesBurned;

        uint256 got = pool.withdraw(asset, assets, to);
        require(got == assets, "AAVE_WITHDRAW_SLIPPAGE");
    }
}
