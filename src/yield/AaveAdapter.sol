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
/// @notice Adapter “vault-managed shares” pour Aave v3 : seul le CollateralVault appelle deposit/withdraw.
/// @dev
///  - totalAssets() ≈ balance(aToken) (aToken accrue les intérêts via balance croissant)
///  - Shares internes suivent une logique type ERC4626:
///      * deposit: shares = floor(assets * totalShares / totalAssets)
///      * withdraw: shares = ceil(assets * totalShares / totalAssets)
///  - Hardening:
///      * refuse l’état “assets>0 && totalShares==0” (donation aToken) pour éviter captation.
///  - Admin:
///      * emergencyWithdrawAll + rescue accessibles à l’owner (sinon dead-code si onlyVault).
contract AaveAdapter is IYieldAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotVault();
    error NotAuthorized();
    error ZeroAddress();
    error AmountZero();
    error ZeroAssetsUnderManagement();
    error ZeroSharesMinted();
    error InsufficientShares();
    error WithdrawSlippage();
    error RescueNotAllowed();
    error EmergencyOnlyWhenNoShares();
    error UnexpectedAssetsWithoutShares();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event EmergencyWithdrawAll(address indexed to, uint256 assetsWithdrawn);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    address public immutable vault;             // CollateralVault
    address public immutable override asset;    // underlying (ex: USDC)
    address public immutable aToken;            // aToken correspondant
    IAaveV3Pool public immutable pool;

    /// @notice Supply interne de shares (comptabilité adapter)
    uint256 public override totalShares;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _vault, address _pool, address _asset, address _aToken) {
        if (_owner == address(0) || _vault == address(0) || _pool == address(0) || _asset == address(0) || _aToken == address(0)) {
            revert ZeroAddress();
        }

        owner = _owner;

        vault = _vault;
        pool = IAaveV3Pool(_pool);
        asset = _asset;
        aToken = _aToken;

        // approve max vers Aave pool (adapter -> pool)
        IERC20(_asset).forceApprove(_pool, type(uint256).max);

        emit OwnershipTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address old = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, po);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();
        address old = owner;
        owner = address(0);
        emit OwnershipTransferred(old, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view override returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEWS (CANONICAL)
    //////////////////////////////////////////////////////////////*/

    function previewDeposit(uint256 assets) public view override returns (uint256 sharesMinted) {
        if (assets == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        // Etat anormal: assets déjà là sans shares => refuse (évite captation de donation)
        if (ts == 0 && ta > 0) revert UnexpectedAssetsWithoutShares();

        // Bootstrap: 1 share = 1 asset
        if (ts == 0 && ta == 0) return assets;

        // Si shares existent, assets doit exister
        if (ta == 0) revert ZeroAssetsUnderManagement();

        sharesMinted = Math.mulDiv(assets, ts, ta, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256 sharesBurned) {
        if (assets == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0) revert InsufficientShares();
        if (ta == 0) revert ZeroAssetsUnderManagement();

        sharesBurned = Math.mulDiv(assets, ts, ta, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256 assetsOut) {
        if (shares == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0) return 0;
        if (ta == 0) revert ZeroAssetsUnderManagement();

        assetsOut = Math.mulDiv(shares, ta, ts, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256 assetsIn) {
        if (shares == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0 && ta > 0) revert UnexpectedAssetsWithoutShares();

        // Bootstrap: 1 share = 1 asset
        if (ts == 0 && ta == 0) return shares;

        if (ta == 0) revert ZeroAssetsUnderManagement();

        assetsIn = Math.mulDiv(shares, ta, ts, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERSION HELPERS (FLOOR)
    //////////////////////////////////////////////////////////////*/

    function convertToShares(uint256 assets) public view override returns (uint256 shares) {
        return previewDeposit(assets);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256 assetsOut) {
        return previewRedeem(shares);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets) external override onlyVault returns (uint256 sharesMinted) {
        if (assets == 0) revert AmountZero();

        sharesMinted = previewDeposit(assets);
        if (sharesMinted == 0) revert ZeroSharesMinted();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        totalShares = totalShares + sharesMinted;

        pool.supply(asset, assets, address(this), 0);
    }

    function withdraw(uint256 assets, address to) external override onlyVault returns (uint256 sharesBurned) {
        if (assets == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        sharesBurned = previewWithdraw(assets);

        uint256 ts = totalShares;
        if (sharesBurned > ts) revert InsufficientShares();

        totalShares = ts - sharesBurned;

        uint256 got = pool.withdraw(asset, assets, to);
        if (got != assets) revert WithdrawSlippage();
    }

    /*//////////////////////////////////////////////////////////////
                                EMERGENCY / RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Retire TOUT d'Aave (type(uint256).max) vers `to`.
    /// @dev Safety: uniquement si totalShares == 0 (pas de comptes utilisateurs).
    function emergencyWithdrawAll(address to) external onlyOwner returns (uint256 assetsWithdrawn) {
        if (to == address(0)) revert ZeroAddress();
        if (totalShares != 0) revert EmergencyOnlyWhenNoShares();

        assetsWithdrawn = pool.withdraw(asset, type(uint256).max, to);
        emit EmergencyWithdrawAll(to, assetsWithdrawn);
    }

    /// @notice Rescue tokens envoyés par erreur.
    /// @dev Interdit de sortir `asset` et `aToken`.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == asset || token == aToken) revert RescueNotAllowed();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
