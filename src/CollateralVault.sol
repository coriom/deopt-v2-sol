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
///  - Source de vérité du "principal" : balances[user][token]
///  - Idle = principal réellement détenu par le vault (liquide)
///  - StrategyShares = parts détenues dans une stratégie (AaveAdapter, etc.)
///  - IMPORTANT:
///      * Les intérêts (yield) ne sont PAS reflétés dans balances[]. Ils sont visibles via balanceWithYield().
///      * Les retraits / transferts internes ne peuvent JAMAIS consommer le yield "gratuitement" si le principal
///        est insuffisant (protection anti-dette fantôme).
///      * Toute conversion shares<->assets suit les previews canonique de l’adapter:
///          - previewWithdraw(assets) = ceil  (pour brûler assez de shares)
///          - previewDeposit(assets)  = floor
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

    // yield
    error StrategyNotSet();
    error NotEnoughIdle();
    error StrategyMismatch();
    error YieldNotAllowedForProtocolAccount();
    error StrategyChangeNotAllowedWithActiveShares();
    error TokenNotConfigured();
    error InsufficientStrategyShares();
    error AdapterReturnedUnexpectedShares();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MarginEngineSet(address indexed newMarginEngine);
    event RiskModuleSet(address indexed newRiskModule);

    event CollateralTokenConfigured(
        address indexed token,
        bool isSupported,
        uint8 decimals,
        uint16 collateralFactorBps
    );

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

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public marginEngine;
    IRiskModule public riskModule;

    /// @notice Solde principal par compte / token (source de vérité)
    mapping(address => mapping(address => uint256)) public balances;

    mapping(address => CollateralTokenConfig) public collateralConfigs;
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

    /// @notice part idle conservée dans le Vault (principal liquide)
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
        require(!paused, "PAUSED");
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
                          OWNERSHIP MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
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

    function setCollateralToken(
        address token,
        bool isSupported,
        uint8 decimals,
        uint16 collateralFactorBps
    ) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (collateralFactorBps > 10_000) revert FactorTooHigh();

        collateralConfigs[token] = CollateralTokenConfig({
            isSupported: isSupported,
            decimals: decimals,
            collateralFactorBps: collateralFactorBps
        });

        if (!isCollateralTokenListed[token]) {
            isCollateralTokenListed[token] = true;
            collateralTokens.push(token);
        }

        emit CollateralTokenConfigured(token, isSupported, decimals, collateralFactorBps);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    /// @notice Configure un adapter de rendement pour un token
    /// @dev Robuste: interdit de changer d’adapter si des shares existent (migration explicite sinon).
    function setTokenStrategy(address token, address adapter) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        address old = tokenStrategy[token];
        if (old != address(0) && old != adapter) {
            // On interdit tout switch tant que l'ancien adapter a une supply non nulle
            // (sinon les shares users deviennent orphelines).
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
        // comptes protocolaires (insurance fund, engine, etc.) ne doivent PAS utiliser yield
        if (msg.sender == marginEngine) revert YieldNotAllowedForProtocolAccount();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        yieldOptIn[msg.sender][token] = optedIn;
        emit YieldOptInSet(msg.sender, token, optedIn);
    }

    function balanceWithYield(address user, address token) external view returns (uint256) {
        uint256 idle = idleBalances[user][token];
        uint256 shares = strategyShares[user][token];
        address adapter = tokenStrategy[token];
        if (shares == 0 || adapter == address(0)) return idle;
        // convertToAssets (floor) est ok pour une vue conservatrice; si tu veux la vue exacte,
        // tu peux exposer previewRedeem.
        return idle + IYieldAdapter(adapter).convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////
                            USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // principal augmente
        balances[msg.sender][token] += amount;
        idleBalances[msg.sender][token] += amount;

        emit Deposited(msg.sender, token, amount);

        if (yieldOptIn[msg.sender][token]) {
            _moveToStrategy(msg.sender, token, amount);
        }
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        _withdrawInternal(msg.sender, msg.sender, token, amount);
    }

    function withdrawFor(address user, address token, uint256 amount)
        external
        onlyMarginEngine
        nonReentrant
    {
        if (user == address(0)) revert ZeroAddress();
        _withdrawInternal(user, user, token, amount);
    }

    function moveToStrategy(address token, uint256 amount) external whenNotPaused nonReentrant {
        _moveToStrategy(msg.sender, token, amount);
    }

    function moveToIdle(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        // IMPORTANT: pour retirer `amount` d'assets depuis la stratégie, on doit brûler des shares en CEIL.
        uint256 sharesNeeded = IYieldAdapter(adapter).previewWithdraw(amount);

        uint256 userShares = strategyShares[msg.sender][token];
        if (userShares < sharesNeeded) revert InsufficientStrategyShares();

        // On burn les shares côté user en même temps que l'adapter.
        strategyShares[msg.sender][token] = userShares - sharesNeeded;

        uint256 sharesBurned = IYieldAdapter(adapter).withdraw(amount, address(this));
        // Invariant canonique: sharesBurned doit être >= sharesNeeded (et idéalement ==)
        // On exige == pour éviter toute divergence silencieuse.
        if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

        idleBalances[msg.sender][token] += amount;

        emit MovedToIdle(msg.sender, token, amount, sharesBurned);
    }

    /*//////////////////////////////////////////////////////////////
                        MARGIN ENGINE HOOKS
    //////////////////////////////////////////////////////////////*/

    function transferBetweenAccounts(
        address token,
        address from,
        address to,
        uint256 amount
    ) external onlyMarginEngine whenNotPaused nonReentrant {
        if (from == to) revert SameAccountTransfer();
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        uint256 fromBal = balances[from][token];
        if (fromBal < amount) revert InsufficientBalance();

        // transfert de principal (source de vérité)
        balances[from][token] = fromBal - amount;
        balances[to][token] += amount;

        // déplacer d'abord l'idle (exact)
        uint256 idleFrom = idleBalances[from][token];
        uint256 idleMove = idleFrom >= amount ? amount : idleFrom;

        if (idleMove > 0) {
            idleBalances[from][token] = idleFrom - idleMove;
            idleBalances[to][token] += idleMove;
        }

        // le reste est servi en shares (ceil sur withdraw d'assets équivalents)
        uint256 remaining = amount - idleMove;
        if (remaining > 0) {
            address adapter = tokenStrategy[token];
            if (adapter == address(0)) revert NotEnoughIdle();

            // On veut transférer une valeur d'assets `remaining` depuis la poche stratégie de from vers to.
            // Robuste: on transfère les shares nécessaires en CEIL (previewWithdraw).
            uint256 sharesMove = IYieldAdapter(adapter).previewWithdraw(remaining);

            uint256 sharesFrom = strategyShares[from][token];
            if (sharesFrom < sharesMove) revert InsufficientStrategyShares();

            strategyShares[from][token] = sharesFrom - sharesMove;
            strategyShares[to][token] += sharesMove;
        }

        emit InternalTransfer(token, from, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _moveToStrategy(address user, address token, uint256 amount) internal {
        if (amount == 0) revert AmountZero();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        uint256 idle = idleBalances[user][token];
        if (idle < amount) revert NotEnoughIdle();

        // déplacer de idle -> stratégie
        idleBalances[user][token] = idle - amount;

        // IMPORTANT: previewDeposit = floor; si 0 => revert dans l'adapter (anti-dust / anti-dilution)
        IERC20(token).forceApprove(adapter, amount);
        uint256 sharesMinted = IYieldAdapter(adapter).deposit(amount);

        // compta shares user
        strategyShares[user][token] += sharesMinted;

        emit MovedToStrategy(user, token, amount, sharesMinted);
    }

    function _withdrawInternal(address user, address to, address token, uint256 amount) internal {
        if (amount == 0) revert AmountZero();
        if (to == address(0)) revert ZeroAddress();

        CollateralTokenConfig memory cfg = collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        uint256 bal = balances[user][token];
        if (bal < amount) revert InsufficientBalance();

        // Risk gate (basé sur principal / configs de risk module)
        if (address(riskModule) != address(0)) {
            uint256 maxAllowed = riskModule.getWithdrawableAmount(user, token);
            if (amount > maxAllowed) revert WithdrawExceedsRiskLimits();
        }

        // décrémenter principal
        balances[user][token] = bal - amount;

        // servir d'abord l'idle
        uint256 idle = idleBalances[user][token];
        if (idle >= amount) {
            idleBalances[user][token] = idle - amount;
            IERC20(token).safeTransfer(to, amount);
            emit Withdrawn(user, token, amount);
            return;
        }

        uint256 remaining = amount - idle;

        // transfer idle partielle
        if (idle > 0) {
            idleBalances[user][token] = 0;
            IERC20(token).safeTransfer(to, idle);
        }

        // compléter via stratégie (retrait exact d'assets)
        address adapter = tokenStrategy[token];
        if (adapter == address(0)) revert StrategyNotSet();

        uint256 sharesNeeded = IYieldAdapter(adapter).previewWithdraw(remaining);

        uint256 userShares = strategyShares[user][token];
        if (userShares < sharesNeeded) revert InsufficientStrategyShares();

        strategyShares[user][token] = userShares - sharesNeeded;

        uint256 sharesBurned = IYieldAdapter(adapter).withdraw(remaining, to);
        if (sharesBurned != sharesNeeded) revert AdapterReturnedUnexpectedShares();

        emit Withdrawn(user, token, amount);
    }
}
