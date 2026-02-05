// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./risk/IRiskModule.sol";
import "./yield/IYieldAdapter.sol";

/// @title CollateralVault
/// @notice Coffre-fort central de collatéral (multi-token, cross-margin, yield optionnel)
/// @dev
///  - balances[user][token] = montant "claimable" (inclut le yield ACCRU après sync)
///  - idleBalances = part liquide détenue par le vault
///  - strategyShares = parts détenues dans une stratégie (AaveAdapter, etc.)
///  - Le vault effectue un _sync() avant toute opération critique afin que:
///      * balances reflète le yield (évite "equity fantôme" côté RiskModule / MarginEngine)
///      * les retraits/transferts puissent consommer le yield réellement gagné
///
/// Hardenings:
///  - Opt-in yield ne DOIT PAS casser les dépôts/transferts si aucun adapter n'est configuré:
///      * deposit() et transferBetweenAccounts() utilisent _maybeMoveToStrategy() (no-revert si strategy absente)
///      * moveToStrategy() reste strict (revert si pas de strategy)
///  - preview calls vers adapter sont wrapées (AdapterPreviewFailed) dans les chemins critiques
///  - balanceWithYield() est “safe view”: si previewRedeem revert => retourne idle (conservateur)
///
/// Ajout requis (patch MarginEngine):
///  - depositFor(user, token, amount) callable UNIQUEMENT par MarginEngine:
///      * évite le bug "deposit(token, amount)" appelé depuis MarginEngine qui crédite msg.sender (MarginEngine)
///      * transfère bien les tokens depuis `user`, crédite `balances[user][token]`
///  - withdrawFor(user, token, amount) callable UNIQUEMENT par MarginEngine (et quandNotPaused):
///      * évite le bug "withdraw(token, amount)" depuis MarginEngine (msg.sender = MarginEngine)
contract CollateralVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct CollateralTokenConfig {
        bool isSupported;
        uint8 decimals;
        uint16 collateralFactorBps; // (legacy / hook futur)
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error TokenNotSupported();
    error AmountZero();
    error InsufficientBalance();
    error ZeroAddress();
    error WithdrawExceedsRiskLimits();
    error FactorTooHigh();
    error SameAccountTransfer();
    error PausedError();
    error BadDecimals();

    // yield
    error StrategyNotSet();
    error NotEnoughIdle();
    error StrategyMismatch();
    error YieldNotAllowedForProtocolAccount();
    error StrategyChangeNotAllowedWithActiveShares();
    error InsufficientStrategyShares();
    error AdapterReturnedUnexpectedShares();
    error AdapterPreviewFailed();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

    // riskModule optional hook not present / failed
    error RiskModuleHookFailed();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event MarginEngineSet(address indexed newMarginEngine);
    event RiskModuleSet(address indexed newRiskModule);

    event CollateralTokenConfigured(address indexed token, bool isSupported, uint8 decimals, uint16 collateralFactorBps);

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event InternalTransfer(address indexed token, address indexed from, address indexed to, uint256 amount);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // yield
    event TokenStrategySet(address indexed token, address indexed adapter);
    event YieldOptInSet(address indexed user, address indexed token, bool optedIn);
    event MovedToStrategy(address indexed user, address indexed token, uint256 assets, uint256 sharesMinted);
    event MovedToIdle(address indexed user, address indexed token, uint256 assets, uint256 sharesBurned);

    event Synced(address indexed user, address indexed token, uint256 newBalance);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    address public marginEngine;
    IRiskModule public riskModule;

    /// @notice Montant claimable (inclut yield accru après sync)
    mapping(address => mapping(address => uint256)) public balances;

    // IMPORTANT: getter custom "collateralConfigs(token)" retourne un struct (pas un tuple)
    mapping(address => CollateralTokenConfig) private _collateralConfigs;
    address[] public collateralTokens;
    mapping(address => bool) public isCollateralTokenListed;

    bool public paused;

    /*//////////////////////////////////////////////////////////////
                            YIELD LAYER
    //////////////////////////////////////////////////////////////*/

    /// @notice token => adapter (0 si aucun)
    mapping(address => address) public tokenStrategy;

    /// @notice user => token => opt-in yield
    mapping(address => mapping(address => bool)) public yieldOptIn;

    /// @notice shares détenues dans l’adapter (comptabilité interne)
    mapping(address => mapping(address => uint256)) public strategyShares;

    /// @notice part idle conservée dans le Vault (liquide)
    mapping(address => mapping(address => uint256)) public idleBalances;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyMarginEngine() {
        if (msg.sender != marginEngine) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP MANAGEMENT (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSABLE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN / CONFIG
    //////////////////////////////////////////////////////////////*/

    function setMarginEngine(address _marginEngine) external onlyOwner {
        if (_marginEngine == address(0)) revert ZeroAddress();
        marginEngine = _marginEngine;
        emit MarginEngineSet(_marginEngine);
    }

    function setRiskModule(address _riskModule) external onlyOwner {
        if (_riskModule == address(0)) revert ZeroAddress();
        riskModule = IRiskModule(_riskModule);
        emit RiskModuleSet(_riskModule);
    }

    function setCollateralToken(address token, bool isSupported, uint8 decimals, uint16 collateralFactorBps)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (collateralFactorBps > 10_000) revert FactorTooHigh();

        // hardening: si supported => decimals doit être non-zero
        if (isSupported && decimals == 0) revert BadDecimals();

        _collateralConfigs[token] =
            CollateralTokenConfig({isSupported: isSupported, decimals: decimals, collateralFactorBps: collateralFactorBps});

        if (!isCollateralTokenListed[token]) {
            isCollateralTokenListed[token] = true;
            collateralTokens.push(token);
        }

        emit CollateralTokenConfigured(token, isSupported, decimals, collateralFactorBps);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    /// @notice Getter struct (consommé par RiskModule / MarginEngine)
    function collateralConfigs(address token) external view returns (CollateralTokenConfig memory cfg) {
        cfg = _collateralConfigs[token];
    }

    /// @notice Getter tuple (legacy compat si besoin)
    function collateralConfigsRaw(address token)
        external
        view
        returns (bool isSupported, uint8 decimals, uint16 collateralFactorBps)
    {
        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        return (cfg.isSupported, cfg.decimals, cfg.collateralFactorBps);
    }

    /// @notice Helper explicite.
    function getCollateralConfig(address token) external view returns (CollateralTokenConfig memory cfg) {
        cfg = _collateralConfigs[token];
    }

    /// @notice Configure un adapter de rendement pour un token
    /// @dev Robuste: interdit de changer d’adapter si totalShares != 0.
    function setTokenStrategy(address token, address adapter) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        address old = tokenStrategy[token];
        if (old != address(0) && old != adapter) {
            uint256 ts = IYieldAdapter(old).totalShares();
            if (ts != 0) revert StrategyChangeNotAllowedWithActiveShares();
        }

        if (adapter != address(0)) {
            if (IYieldAdapter(adapter).asset() != token) revert StrategyMismatch();
        }

        tokenStrategy[token] = adapter;
        emit TokenStrategySet(token, adapter);
    }

    /*//////////////////////////////////////////////////////////////
                            USER: YIELD SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setYieldOptIn(address token, bool optedIn) external {
        if (msg.sender == marginEngine) revert YieldNotAllowedForProtocolAccount();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        yieldOptIn[msg.sender][token] = optedIn;
        emit YieldOptInSet(msg.sender, token, optedIn);
    }

    /// @notice Vue “réelle” (idle + assets représentés par shares), indépendante des syncs.
    /// @dev Safe-view: si previewRedeem revert, retourne idle (conservateur).
    function balanceWithYield(address user, address token) external view returns (uint256) {
        uint256 idle = idleBalances[user][token];
        uint256 shares = strategyShares[user][token];
        address adapter = tokenStrategy[token];
        if (shares == 0 || adapter == address(0)) return idle;

        try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 assetsFromShares) {
            return idle + assetsFromShares;
        } catch {
            return idle;
        }
    }

    /// @notice Force un sync de l’utilisateur (utile front / UX).
    function syncAccount(address token) external nonReentrant {
        _sync(msg.sender, token);
    }

    /// @notice Sync arbitraire (permissionless).
    function syncAccountFor(address user, address token) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        _sync(user, token);
    }

    /// @notice Diagnostic invariant (utile tests).
    function checkInvariant(address user, address token)
        external
        view
        returns (
            uint256 balanceClaimable,
            uint256 idle,
            uint256 shares,
            uint256 assetsFromShares,
            uint256 effective
        )
    {
        balanceClaimable = balances[user][token];
        idle = idleBalances[user][token];
        shares = strategyShares[user][token];

        address adapter = tokenStrategy[token];
        if (shares != 0 && adapter != address(0)) {
            try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 a) {
                assetsFromShares = a;
            } catch {
                assetsFromShares = 0;
            }
        } else {
            assetsFromShares = 0;
        }

        effective = idle + assetsFromShares;
    }

    /*//////////////////////////////////////////////////////////////
                            USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(msg.sender, token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[msg.sender][token] += amount;
        idleBalances[msg.sender][token] += amount;

        emit Deposited(msg.sender, token, amount);

        _maybeMoveToStrategy(msg.sender, token, amount);
    }

    /// @notice Dépôt au nom de `user` (tokens transférés depuis `user`) — appelé par MarginEngine.
    /// @dev Patch requis: empêche de créditer MarginEngine au lieu du user.
    function depositFor(address user, address token, uint256 amount) external whenNotPaused onlyMarginEngine nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(user, token);

        IERC20(token).safeTransferFrom(user, address(this), amount);

        balances[user][token] += amount;
        idleBalances[user][token] += amount;

        emit Deposited(user, token, amount);

        _maybeMoveToStrategy(user, token, amount);
    }

    /// @notice Retrait direct user (peut rester possible même si paused, choix "exit" d'urgence).
    function withdraw(address token, uint256 amount) external nonReentrant {
        _withdrawInternal(msg.sender, msg.sender, token, amount);
    }

    /// @notice Retrait au nom de `user` — appelé par MarginEngine (bloqué si vault paused).
    function withdrawFor(address user, address token, uint256 amount)
        external
        onlyMarginEngine
        whenNotPaused
        nonReentrant
    {
        if (user == address(0)) revert ZeroAddress();
        _withdrawInternal(user, user, token, amount);
    }

    /// @notice Strict: revert si strategy non configurée.
    function moveToStrategy(address token, uint256 amount) external whenNotPaused nonReentrant {
        _sync(msg.sender, token);
        _moveToStrategy(msg.sender, token, amount);
    }

    /// @notice Peut rester autorisé même si paused (sortie d'urgence).
    function moveToIdle(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(msg.sender, token);

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        uint256 sharesNeeded = _previewWithdraw(adapter, amount);

        uint256 userShares = strategyShares[msg.sender][token];
        if (userShares < sharesNeeded) revert InsufficientStrategyShares();

        strategyShares[msg.sender][token] = userShares - sharesNeeded;

        uint256 sharesBurned = IYieldAdapter(adapter).withdraw(amount, address(this));
        if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

        idleBalances[msg.sender][token] += amount;

        emit MovedToIdle(msg.sender, token, amount, sharesBurned);

        _sync(msg.sender, token);
    }

    /*//////////////////////////////////////////////////////////////
                        MARGIN ENGINE HOOKS
    //////////////////////////////////////////////////////////////*/

    function transferBetweenAccounts(address token, address from, address to, uint256 amount)
        external
        onlyMarginEngine
        whenNotPaused
        nonReentrant
    {
        if (from == to) revert SameAccountTransfer();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(from, token);
        _sync(to, token);

        uint256 fromBal = balances[from][token];
        if (fromBal < amount) revert InsufficientBalance();

        // accounting "claimable" moved
        balances[from][token] = fromBal - amount;
        balances[to][token] += amount;

        // move idle first
        uint256 idleFrom = idleBalances[from][token];
        uint256 idleMove = idleFrom >= amount ? amount : idleFrom;

        if (idleMove > 0) {
            idleBalances[from][token] = idleFrom - idleMove;
            idleBalances[to][token] += idleMove;
        }

        // if needed, pull remaining from strategy of `from` into idle (vault)
        uint256 remaining = amount - idleMove;
        if (remaining > 0) {
            address adapter = tokenStrategy[token];
            if (adapter == address(0)) revert NotEnoughIdle();

            uint256 sharesNeeded = _previewWithdraw(adapter, remaining);

            uint256 sharesFrom = strategyShares[from][token];
            if (sharesFrom < sharesNeeded) revert InsufficientStrategyShares();

            strategyShares[from][token] = sharesFrom - sharesNeeded;

            uint256 sharesBurned = IYieldAdapter(adapter).withdraw(remaining, address(this));
            if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

            idleBalances[to][token] += remaining;

            // IMPORTANT: ne doit pas revert si strategy absente (adapter==0) — ici adapter!=0, ok.
            _maybeMoveToStrategy(to, token, remaining);
        } else {
            _maybeMoveToStrategy(to, token, idleMove);
        }

        emit InternalTransfer(token, from, to, amount);

        _sync(from, token);
        _sync(to, token);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _previewDeposit(address adapter, uint256 assets) internal view returns (uint256) {
        try IYieldAdapter(adapter).previewDeposit(assets) returns (uint256 s) {
            return s;
        } catch {
            revert AdapterPreviewFailed();
        }
    }

    function _previewWithdraw(address adapter, uint256 assets) internal view returns (uint256) {
        try IYieldAdapter(adapter).previewWithdraw(assets) returns (uint256 s) {
            return s;
        } catch {
            revert AdapterPreviewFailed();
        }
    }

    function _previewRedeem(address adapter, uint256 shares) internal view returns (uint256) {
        try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 a) {
            return a;
        } catch {
            revert AdapterPreviewFailed();
        }
    }

    function _sync(address user, address token) internal {
        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        uint256 idle = idleBalances[user][token];
        uint256 shares = strategyShares[user][token];
        address adapter = tokenStrategy[token];

        uint256 assetsFromShares = 0;
        if (shares != 0) {
            if (adapter == address(0)) revert StrategyNotSet();
            assetsFromShares = _previewRedeem(adapter, shares);
        }

        uint256 effective = idle + assetsFromShares;
        balances[user][token] = effective;

        emit Synced(user, token, effective);
    }

    /// @dev no-op si user n'est pas opt-in ou si aucun adapter n'est configuré.
    function _maybeMoveToStrategy(address user, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (!yieldOptIn[user][token]) return;

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) return;

        _moveToStrategy(user, token, amount);
    }

    function _moveToStrategy(address user, address token, uint256 amount) internal {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        uint256 idle = idleBalances[user][token];
        if (idle < amount) revert NotEnoughIdle();

        idleBalances[user][token] = idle - amount;

        uint256 expectedShares = _previewDeposit(adapter, amount);

        IERC20(token).forceApprove(adapter, amount);
        uint256 sharesMinted = IYieldAdapter(adapter).deposit(amount);

        if (sharesMinted != expectedShares) revert AdapterReturnedUnexpectedShares();

        strategyShares[user][token] += sharesMinted;

        emit MovedToStrategy(user, token, amount, sharesMinted);
    }

    function _getWithdrawableAmountBestEffort(address user, address token) internal view returns (uint256 maxAllowed, bool ok)
    {
        address rm = address(riskModule);
        if (rm == address(0)) return (type(uint256).max, false);

        // best-effort hook: getWithdrawableAmount(address,address) -> uint256
        (bool success, bytes memory data) =
            rm.staticcall(abi.encodeWithSignature("getWithdrawableAmount(address,address)", user, token));

        if (!success || data.length < 32) return (type(uint256).max, false);
        maxAllowed = abi.decode(data, (uint256));
        return (maxAllowed, true);
    }

    function _withdrawInternal(address user, address to, address token, uint256 amount) internal {
        if (amount == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        _sync(user, token);

        uint256 bal = balances[user][token];
        if (bal < amount) revert InsufficientBalance();

        // Optional hard-check via RiskModule (if configured AND hook exists)
        {
            (uint256 maxAllowed, bool ok) = _getWithdrawableAmountBestEffort(user, token);
            if (ok && amount > maxAllowed) revert WithdrawExceedsRiskLimits();
        }

        // optimistic update; final truth will be re-synced on paths needing strategy withdraw
        balances[user][token] = bal - amount;

        uint256 idle = idleBalances[user][token];
        if (idle >= amount) {
            idleBalances[user][token] = idle - amount;
            IERC20(token).safeTransfer(to, amount);
            emit Withdrawn(user, token, amount);
            return;
        }

        uint256 remaining = amount - idle;

        if (idle > 0) {
            idleBalances[user][token] = 0;
            IERC20(token).safeTransfer(to, idle);
        }

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        uint256 sharesNeeded = _previewWithdraw(adapter, remaining);

        uint256 userShares = strategyShares[user][token];
        if (userShares < sharesNeeded) revert InsufficientStrategyShares();

        strategyShares[user][token] = userShares - sharesNeeded;

        uint256 sharesBurned = IYieldAdapter(adapter).withdraw(remaining, to);
        if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

        emit Withdrawn(user, token, amount);

        _sync(user, token);
    }
}
