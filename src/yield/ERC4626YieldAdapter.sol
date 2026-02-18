// contracts/yield/ERC4626YieldAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import "./IYieldAdapter.sol";

/// @title ERC4626YieldAdapter
/// @notice Adapter générique: wrap un vault ERC-4626 externe pour l'API IYieldAdapter.
/// @dev
///  - Le CollateralVault est l'unique caller autorisé sur deposit/withdraw.
///  - Les "shares" retournées = shares ERC-4626 mintées au bénéfice de *cet adapter* (receiver = address(this)).
///  - totalShares() = balanceOf(adapter) sur le token share (IERC20(address(erc4626))).
///  - totalAssets() = convertToAssets(totalShares()) => assets représentés par les shares détenues.
///
/// Hypothèses pour CollateralVault (strict-equality):
///  - previewDeposit == deposit (même tx; pas de fee dynamique / pas de changement d’état externe affectant les previews)
///  - previewWithdraw == withdraw (idem)
contract ERC4626YieldAdapter is IYieldAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error AssetMismatch();
    error AmountZero();

    // strict previews vs actions
    error ZeroSharesMinted();
    error ZeroSharesBurned();
    error UnexpectedSharesMinted();
    error UnexpectedSharesBurned();

    // rescue
    error RescueForbidden();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

    // emergency hardening (avoid desync with CollateralVault accounting)
    error EmergencyForbiddenWithActiveShares();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    address public immutable vault;        // CollateralVault (caller autorisé)
    IERC4626 public immutable erc4626;     // vault ERC-4626 cible
    address public immutable underlying;   // erc4626.asset()

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _collateralVault, address _erc4626Vault) {
        if (_owner == address(0) || _collateralVault == address(0) || _erc4626Vault == address(0)) {
            revert ZeroAddress();
        }

        owner = _owner;
        vault = _collateralVault;

        IERC4626 v = IERC4626(_erc4626Vault);
        erc4626 = v;

        address a = v.asset();
        if (a == address(0)) revert AssetMismatch();
        underlying = a;

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
                        IYieldAdapter: VIEWS
    //////////////////////////////////////////////////////////////*/

    function asset() external view override returns (address) {
        return underlying;
    }

    function assetDecimals() external view override returns (uint8) {
        // best-effort: certains tokens non-standards peuvent revert
        try IERC20Metadata(underlying).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 0;
        }
    }

    function totalShares() public view override returns (uint256) {
        // ERC-4626 shares token = l’ERC20 du vault ERC-4626 lui-même
        return IERC20(address(erc4626)).balanceOf(address(this));
    }

    function totalAssets() external view override returns (uint256) {
        return erc4626.convertToAssets(totalShares());
    }

    function previewDeposit(uint256 assets_) external view override returns (uint256 sharesMinted) {
        return erc4626.previewDeposit(assets_);
    }

    function previewWithdraw(uint256 assets_) external view override returns (uint256 sharesBurned) {
        return erc4626.previewWithdraw(assets_);
    }

    function previewRedeem(uint256 shares_) external view override returns (uint256 assetsOut) {
        return erc4626.previewRedeem(shares_);
    }

    function previewMint(uint256 shares_) external view override returns (uint256 assetsIn) {
        return erc4626.previewMint(shares_);
    }

    function convertToShares(uint256 assets_) external view override returns (uint256 shares_) {
        // floor
        return erc4626.convertToShares(assets_);
    }

    function convertToAssets(uint256 shares_) external view override returns (uint256 assets_) {
        // floor
        return erc4626.convertToAssets(shares_);
    }

    /*//////////////////////////////////////////////////////////////
                        IYieldAdapter: ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets_) external override onlyVault nonReentrant returns (uint256 sharesMinted) {
        if (assets_ == 0) revert AmountZero();

        // Expected shares (strict)
        uint256 expected = erc4626.previewDeposit(assets_);
        if (expected == 0) revert ZeroSharesMinted();

        // Pull assets depuis CollateralVault
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), assets_);

        // Approve vers le vault ERC-4626 et deposit au profit de l’adapter
        IERC20(underlying).forceApprove(address(erc4626), assets_);
        sharesMinted = erc4626.deposit(assets_, address(this));

        if (sharesMinted == 0) revert ZeroSharesMinted();
        if (sharesMinted != expected) revert UnexpectedSharesMinted();
    }

    function withdraw(uint256 assets_, address to) external override onlyVault nonReentrant returns (uint256 sharesBurned) {
        if (assets_ == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        uint256 expected = erc4626.previewWithdraw(assets_);
        if (expected == 0) revert ZeroSharesBurned();

        // owner = address(this) (adapter) car les shares sont détenues ici
        sharesBurned = erc4626.withdraw(assets_, to, address(this));

        if (sharesBurned == 0) revert ZeroSharesBurned();
        if (sharesBurned != expected) revert UnexpectedSharesBurned();
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL ADMIN (IYieldAdapter)
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency pull (optionnel).
    /// @dev Hardening: interdit si des shares sont actives (sinon désynchronise CollateralVault).
    function emergencyWithdrawTo(address to, uint256 assets_)
        external
        override
        onlyOwner
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (to == address(0)) revert ZeroAddress();
        if (assets_ == 0) revert AmountZero();

        if (totalShares() != 0) revert EmergencyForbiddenWithActiveShares();

        uint256 expected = erc4626.previewWithdraw(assets_);
        if (expected == 0) revert ZeroSharesBurned();

        sharesBurned = erc4626.withdraw(assets_, to, address(this));

        if (sharesBurned == 0) revert ZeroSharesBurned();
        if (sharesBurned != expected) revert UnexpectedSharesBurned();
    }

    /*//////////////////////////////////////////////////////////////
                                RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Rescue tokens envoyés par erreur.
    /// @dev Interdit de rescue l'underlying ou le share token ERC-4626 (fonds utilisateurs).
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == underlying) revert RescueForbidden();
        if (token == address(erc4626)) revert RescueForbidden();

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }
}
