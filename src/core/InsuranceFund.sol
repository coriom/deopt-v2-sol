// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../CollateralVault.sol";

/// @title InsuranceFund
/// @notice Trésorerie de backstop (multi-token) destinée à être utilisée COMME "account" dans CollateralVault.
/// @dev
///  - Le MarginEngine couvre le bad debt via CollateralVault.transferBetweenAccounts(from=address(this), ...).
///  - Ce contrat sert à:
///      * gérer l’allowlist de tokens,
///      * déposer/retirer des fonds dans le CollateralVault sous l’adresse de ce contrat,
///      * (optionnel) activer le yield côté vault (moveToStrategy/moveToIdle).
contract InsuranceFund is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error TokenNotAllowed();
    error AmountZero();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event OperatorSet(address indexed operator, bool allowed);
    event TokenAllowed(address indexed token, bool allowed);

    event VaultSet(address indexed vault);

    event FundedFromOwner(address indexed token, address indexed from, uint256 amount);
    event DepositedToVault(address indexed token, uint256 amount);
    event WithdrawnFromVault(address indexed token, address indexed to, uint256 amount);

    event YieldOptInSet(address indexed token, bool optedIn);
    event MovedToStrategy(address indexed token, uint256 assets);
    event MovedToIdle(address indexed token, uint256 assets);
    event Synced(address indexed token);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    /// @notice opérateurs autorisés (optionnel): keepers / ops / etc.
    mapping(address => bool) public isOperator;

    /// @notice allowlist multi-token (USDC, WETH, WBTC, etc.)
    mapping(address => bool) public isTokenAllowed;

    CollateralVault public immutable collateralVault;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner && !isOperator[msg.sender]) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _vault) {
        if (_owner == address(0) || _vault == address(0)) revert ZeroAddress();

        owner = _owner;
        collateralVault = CollateralVault(_vault);

        emit OwnershipTransferred(address(0), _owner);
        emit VaultSet(_vault);

        // owner operator par défaut (bootstrap)
        isOperator[_owner] = true;
        emit OperatorSet(_owner, true);
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

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isTokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT FUNDING / MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pull des tokens depuis l’owner, puis dépôt dans le CollateralVault au nom de ce fund.
    /// @dev Owner doit approve ce contrat.
    function fundAndDepositToVault(address token, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FundedFromOwner(token, msg.sender, amount);

        _depositToVault(token, amount);
    }

    /// @notice Dépôt de tokens déjà détenus par le fund vers le CollateralVault.
    function depositToVault(address token, uint256 amount)
        external
        onlyOwnerOrOperator
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();
        _depositToVault(token, amount);
    }

    function _depositToVault(address token, uint256 amount) internal {
        // approve vault, puis vault.transferFrom(this -> vault)
        IERC20(token).forceApprove(address(collateralVault), amount);
        collateralVault.deposit(token, amount);
        emit DepositedToVault(token, amount);
    }

    /// @notice Retire des tokens du CollateralVault (depuis le balance interne du fund) et les envoie à `to`.
    /// @dev Ici, on sort des actifs du vault (on-chain transfer). À utiliser pour ops/gestion.
    function withdrawFromVault(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        // CollateralVault.withdraw envoie à msg.sender (ici: InsuranceFund).
        collateralVault.withdraw(token, amount);

        // Puis on forward à `to`.
        IERC20(token).safeTransfer(to, amount);

        emit WithdrawnFromVault(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            YIELD WRAPPERS (OPTIONNEL)
    //////////////////////////////////////////////////////////////*/

    function setYieldOptIn(address token, bool optedIn) external onlyOwner {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        collateralVault.setYieldOptIn(token, optedIn);
        emit YieldOptInSet(token, optedIn);
    }

    function moveToStrategy(address token, uint256 amount) external onlyOwner nonReentrant {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();
        collateralVault.moveToStrategy(token, amount);
        emit MovedToStrategy(token, amount);
    }

    function moveToIdle(address token, uint256 amount) external onlyOwner nonReentrant {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();
        collateralVault.moveToIdle(token, amount);
        emit MovedToIdle(token, amount);
    }

    function syncVaultAccount(address token) external onlyOwnerOrOperator nonReentrant {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        collateralVault.syncAccount(token);
        emit Synced(token);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function vaultBalance(address token) external view returns (uint256) {
        return collateralVault.balances(address(this), token);
    }

    function vaultBalanceWithYield(address token) external view returns (uint256) {
        // balanceWithYield est une view “réelle” (idle + parts), mais on reste défensif.
        try collateralVault.balanceWithYield(address(this), token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(address(this), token);
        }
    }
}
