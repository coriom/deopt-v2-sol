// contracts/yield/AaveAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
///  - totalAssets() ≈ balance(aToken) (aToken accrues interest via growing balance)
///  - Shares internes (comptabilité) type ERC4626:
///      * deposit:  shares = floor(assets * totalShares / totalAssets)
///      * withdraw: shares = ceil(assets * totalShares / totalAssets)
///  - Hardening:
///      * refuse l’état “assets>0 && totalShares==0” (donation aToken) dans les previews.
///  - IMPORTANT: l’adapter ne tient PAS un ledger per-user : CollateralVault est la source de vérité.
contract AaveAdapter is IYieldAdapter, ReentrancyGuard {
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
    error UnexpectedAssetsWithoutShares();
    error OwnershipTransferNotInitiated();
    error EmergencyOnlyWhenNoShares();

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

    address public immutable vault;                 // CollateralVault
    address public immutable override asset;        // underlying (ex: USDC)
    uint8 private immutable _assetDecimals;         // cached (best-effort)

    address public immutable aToken;                // aToken correspondant
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

        uint8 d;
        try IERC20Metadata(_asset).decimals() returns (uint8 dd) {
            d = dd;
        } catch {
            d = 0;
        }
        _assetDecimals = d;

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

    function assetDecimals() external view override returns (uint8) {
        return _assetDecimals;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(aToken).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            PREVIEWS (CANONICAL)
    //////////////////////////////////////////////////////////////*/

    function previewDeposit(uint256 assets_) public view override returns (uint256 sharesMinted) {
        if (assets_ == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        // Etat anormal: assets déjà là sans shares => refuse (évite captation de donation)
        if (ts == 0 && ta > 0) revert UnexpectedAssetsWithoutShares();

        // Bootstrap: 1 share = 1 asset
        if (ts == 0 && ta == 0) return assets_;

        // Si shares existent, assets doit exister
        if (ta == 0) revert ZeroAssetsUnderManagement();

        sharesMinted = Math.mulDiv(assets_, ts, ta, Math.Rounding.Floor);
    }

    function previewWithdraw(uint256 assets_) public view override returns (uint256 sharesBurned) {
        if (assets_ == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0) revert InsufficientShares();
        if (ta == 0) revert ZeroAssetsUnderManagement();

        sharesBurned = Math.mulDiv(assets_, ts, ta, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares_) public view override returns (uint256 assetsOut) {
        if (shares_ == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0) return 0;
        if (ta == 0) revert ZeroAssetsUnderManagement();

        assetsOut = Math.mulDiv(shares_, ta, ts, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares_) public view override returns (uint256 assetsIn) {
        if (shares_ == 0) return 0;

        uint256 ts = totalShares;
        uint256 ta = totalAssets();

        if (ts == 0 && ta > 0) revert UnexpectedAssetsWithoutShares();

        // Bootstrap: 1 share = 1 asset
        if (ts == 0 && ta == 0) return shares_;

        if (ta == 0) revert ZeroAssetsUnderManagement();

        assetsIn = Math.mulDiv(shares_, ta, ts, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERSION HELPERS (FLOOR)
    //////////////////////////////////////////////////////////////*/

    function convertToShares(uint256 assets_) public view override returns (uint256 shares_) {
        return previewDeposit(assets_);
    }

    function convertToAssets(uint256 shares_) public view override returns (uint256 assetsOut) {
        return previewRedeem(shares_);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets_) external override onlyVault nonReentrant returns (uint256 sharesMinted) {
        if (assets_ == 0) revert AmountZero();

        sharesMinted = previewDeposit(assets_);
        if (sharesMinted == 0) revert ZeroSharesMinted();

        // Pull assets depuis CollateralVault
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets_);

        // Comptabilité shares (source de vérité = CollateralVault pour le mapping user->shares)
        totalShares = totalShares + sharesMinted;

        // Supply sur Aave (adapter détient les aTokens)
        pool.supply(asset, assets_, address(this), 0);
    }

    function withdraw(uint256 assets_, address to) external override onlyVault nonReentrant returns (uint256 sharesBurned) {
        if (assets_ == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        sharesBurned = previewWithdraw(assets_);

        uint256 ts = totalShares;
        if (sharesBurned > ts) revert InsufficientShares();

        totalShares = ts - sharesBurned;

        uint256 got = pool.withdraw(asset, assets_, to);
        if (got != assets_) revert WithdrawSlippage();
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL ADMIN (IYieldAdapter)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency pull (optionnel).
    /// @dev Hardening: uniquement si totalShares == 0 (sinon désynchronise CollateralVault).
    function emergencyWithdrawTo(address to, uint256 assets_)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (to == address(0)) revert ZeroAddress();
        if (assets_ == 0) revert AmountZero();
        if (totalShares != 0) revert EmergencyOnlyWhenNoShares();

        // Si totalShares==0, on n’a aucune dette de shares; on retire simplement.
        uint256 got = pool.withdraw(asset, assets_, to);
        if (got != assets_) revert WithdrawSlippage();

        sharesBurned = 0;
    }

    /*//////////////////////////////////////////////////////////////
                                EMERGENCY / RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Retire TOUT d'Aave (type(uint256).max) vers `to`.
    /// @dev Safety: uniquement si totalShares == 0 (pas de comptes utilisateurs).
    function emergencyWithdrawAll(address to) external onlyOwner nonReentrant returns (uint256 assetsWithdrawn) {
        if (to == address(0)) revert ZeroAddress();
        if (totalShares != 0) revert EmergencyOnlyWhenNoShares();

        assetsWithdrawn = pool.withdraw(asset, type(uint256).max, to);
        emit EmergencyWithdrawAll(to, assetsWithdrawn);
    }

    /// @notice Rescue tokens envoyés par erreur.
    /// @dev Interdit de sortir `asset` et `aToken`.
    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == asset || token == aToken) revert RescueNotAllowed();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
