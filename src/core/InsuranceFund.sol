// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CollateralVault} from "../collateral/CollateralVault.sol";

/// @title InsuranceFund
/// @notice Trésorerie de backstop (multi-token) destinée à être utilisée COMME "account" dans CollateralVault.
/// @dev
///  Rôles dans DeOpt v2:
///   - backstop de règlement / bad debt via CollateralVault.transferBetweenAccounts(from=address(this), ...),
///   - réceptacle possible des trading fees si MarginEngine choisit insuranceFund comme feeRecipient fallback.
///
///  Important:
///   - Les fees reçues via MarginEngine NE transitent pas onchain par ce contrat.
///     Elles arrivent comme crédit interne dans CollateralVault sous l’adresse `address(this)`.
///   - Ce contrat sert donc à:
///       * gérer l’allowlist de tokens,
///       * déposer / retirer des fonds dans le CollateralVault sous l’adresse de ce contrat,
///       * (optionnel) activer le yield côté vault (moveToStrategy/moveToIdle),
///       * exposer des vues utilitaires sur les balances locales / vault.
///
///  Hardenings:
///   - ownership 2-step
///   - allowlist stricte (TokenNotAllowed)
///   - helpers depositAllToVault / sweepUnexpectedToken
///   - guardian + emergency pauses compatibles Safe multisig
contract InsuranceFund is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error GuardianNotAuthorized();
    error ZeroAddress();
    error TokenNotAllowed();
    error AmountZero();
    error InsufficientBalance();
    error RescueForbidden();

    error OwnershipTransferNotInitiated();

    error PausedError();
    error FundingPaused();
    error WithdrawPaused();
    error YieldOpsPaused();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    event OperatorSet(address indexed operator, bool allowed);
    event TokenAllowed(address indexed token, bool allowed);

    event VaultSet(address indexed vault);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event GlobalPauseSet(bool isPaused);
    event FundingPauseSet(bool isPaused);
    event WithdrawPauseSet(bool isPaused);
    event YieldOpsPauseSet(bool isPaused);
    event EmergencyModeUpdated(bool fundingPaused, bool withdrawPaused, bool yieldOpsPaused);

    event FundedFromOwner(address indexed token, address indexed from, uint256 amount);
    event DepositedToVault(address indexed token, uint256 amount);
    event WithdrawnFromVault(address indexed token, address indexed to, uint256 amount);

    event YieldOptInSet(address indexed token, bool optedIn);
    event MovedToStrategy(address indexed token, uint256 assets);
    event MovedToIdle(address indexed token, uint256 assets);
    event Synced(address indexed token);

    event Swept(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    /// @notice Legacy global pause.
    bool public paused;

    /// @notice Granular emergency flags.
    bool public fundingPaused;
    bool public withdrawPaused;
    bool public yieldOpsPaused;

    /// @notice Opérateurs autorisés (optionnel): keepers / ops / etc.
    mapping(address => bool) public isOperator;

    /// @notice Allowlist multi-token (USDC, WETH, WBTC, etc.)
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

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
        _;
    }

    modifier whenFundingNotPaused() {
        if (_isFundingPaused()) revert FundingPaused();
        _;
    }

    modifier whenWithdrawNotPaused() {
        if (_isWithdrawPaused()) revert WithdrawPaused();
        _;
    }

    modifier whenYieldOpsNotPaused() {
        if (_isYieldOpsPaused()) revert YieldOpsPaused();
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

        isOperator[_owner] = true;
        emit OperatorSet(_owner, true);

        emit EmergencyModeUpdated(false, false, false);
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
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress();
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    function clearGuardian() external onlyOwner {
        address old = guardian;
        guardian = address(0);
        emit GuardianSet(old, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
        }
    }

    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
        }
    }

    function pauseFunding() external onlyGuardianOrOwner {
        if (!fundingPaused) {
            fundingPaused = true;
            emit FundingPauseSet(true);
            emit EmergencyModeUpdated(fundingPaused, withdrawPaused, yieldOpsPaused);
        }
    }

    function unpauseFunding() external onlyOwner {
        if (fundingPaused) {
            fundingPaused = false;
            emit FundingPauseSet(false);
            emit EmergencyModeUpdated(fundingPaused, withdrawPaused, yieldOpsPaused);
        }
    }

    function pauseWithdraws() external onlyGuardianOrOwner {
        if (!withdrawPaused) {
            withdrawPaused = true;
            emit WithdrawPauseSet(true);
            emit EmergencyModeUpdated(fundingPaused, withdrawPaused, yieldOpsPaused);
        }
    }

    function unpauseWithdraws() external onlyOwner {
        if (withdrawPaused) {
            withdrawPaused = false;
            emit WithdrawPauseSet(false);
            emit EmergencyModeUpdated(fundingPaused, withdrawPaused, yieldOpsPaused);
        }
    }

    function pauseYieldOps() external onlyGuardianOrOwner {
        if (!yieldOpsPaused) {
            yieldOpsPaused = true;
            emit YieldOpsPauseSet(true);
            emit EmergencyModeUpdated(fundingPaused, withdrawPaused, yieldOpsPaused);
        }
    }

    function unpauseYieldOps() external onlyOwner {
        if (yieldOpsPaused) {
            yieldOpsPaused = false;
            emit YieldOpsPauseSet(false);
            emit EmergencyModeUpdated(fundingPaused, withdrawPaused, yieldOpsPaused);
        }
    }

    function setEmergencyModes(bool fundingPaused_, bool withdrawPaused_, bool yieldOpsPaused_)
        external
        onlyGuardianOrOwner
    {
        _setEmergencyModes(fundingPaused_, withdrawPaused_, yieldOpsPaused_);
    }

    function clearEmergencyModes() external onlyOwner {
        _setEmergencyModes(false, false, false);
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
        whenFundingNotPaused
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
        whenFundingNotPaused
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal < amount) revert InsufficientBalance();

        _depositToVault(token, amount);
    }

    /// @notice Dépose 100% du solde local détenu par le fund dans le CollateralVault.
    function depositAllToVault(address token)
        external
        onlyOwnerOrOperator
        whenFundingNotPaused
        nonReentrant
        returns (uint256 amount)
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();

        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert AmountZero();

        _depositToVault(token, amount);
    }

    function _depositToVault(address token, uint256 amount) internal {
        IERC20(token).forceApprove(address(collateralVault), 0);
        IERC20(token).forceApprove(address(collateralVault), amount);
        collateralVault.deposit(token, amount);

        emit DepositedToVault(token, amount);
    }

    /// @notice Retire des tokens du CollateralVault (depuis le balance interne du fund) et les envoie à `to`.
    /// @dev Ici, on sort des actifs du vault (on-chain transfer). À utiliser pour ops/gestion.
    function withdrawFromVault(address token, address to, uint256 amount)
        external
        onlyOwner
        whenWithdrawNotPaused
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        collateralVault.withdraw(token, amount);
        IERC20(token).safeTransfer(to, amount);

        emit WithdrawnFromVault(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            YIELD WRAPPERS (OPTIONNEL)
    //////////////////////////////////////////////////////////////*/

    function setYieldOptIn(address token, bool optedIn) external onlyOwner whenYieldOpsNotPaused {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        collateralVault.setYieldOptIn(token, optedIn);
        emit YieldOptInSet(token, optedIn);
    }

    function moveToStrategy(address token, uint256 amount)
        external
        onlyOwner
        whenYieldOpsNotPaused
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();

        collateralVault.moveToStrategy(token, amount);
        emit MovedToStrategy(token, amount);
    }

    function moveToIdle(address token, uint256 amount)
        external
        onlyOwner
        whenYieldOpsNotPaused
        nonReentrant
    {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0) revert AmountZero();

        collateralVault.moveToIdle(token, amount);
        emit MovedToIdle(token, amount);
    }

    function syncVaultAccount(address token) external onlyOwnerOrOperator whenYieldOpsNotPaused nonReentrant {
        if (!isTokenAllowed[token]) revert TokenNotAllowed();
        collateralVault.syncAccount(token);
        emit Synced(token);
    }

    /*//////////////////////////////////////////////////////////////
                                RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice Récupère des tokens envoyés par erreur AU CONTRAT (pas dans le vault).
    /// @dev Interdit de "sweep" un token allowlisté (fonds de backstop / fees protocolaires).
    ///      Pour ces tokens:
    ///        - déposer via depositToVault(), ou
    ///        - retirer via withdrawFromVault().
    function sweepUnexpectedToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        if (isTokenAllowed[token]) revert RescueForbidden();

        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function vaultBalance(address token) external view returns (uint256) {
        return collateralVault.balances(address(this), token);
    }

    function vaultBalanceWithYield(address token) external view returns (uint256) {
        try collateralVault.balanceWithYield(address(this), token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(address(this), token);
        }
    }

    function localBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function isUsableToken(address token) external view returns (bool) {
        if (!isTokenAllowed[token]) return false;
        CollateralVault.CollateralTokenConfig memory cfg = collateralVault.getCollateralConfig(token);
        return cfg.isSupported;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isFundingPaused() internal view returns (bool) {
        return paused || fundingPaused;
    }

    function _isWithdrawPaused() internal view returns (bool) {
        return paused || withdrawPaused;
    }

    function _isYieldOpsPaused() internal view returns (bool) {
        return paused || yieldOpsPaused;
    }

    function _setEmergencyModes(bool fundingPaused_, bool withdrawPaused_, bool yieldOpsPaused_) internal {
        if (fundingPaused != fundingPaused_) {
            fundingPaused = fundingPaused_;
            emit FundingPauseSet(fundingPaused_);
        }

        if (withdrawPaused != withdrawPaused_) {
            withdrawPaused = withdrawPaused_;
            emit WithdrawPauseSet(withdrawPaused_);
        }

        if (yieldOpsPaused != yieldOpsPaused_) {
            yieldOpsPaused = yieldOpsPaused_;
            emit YieldOpsPauseSet(yieldOpsPaused_);
        }

        emit EmergencyModeUpdated(fundingPaused_, withdrawPaused_, yieldOpsPaused_);
    }
}