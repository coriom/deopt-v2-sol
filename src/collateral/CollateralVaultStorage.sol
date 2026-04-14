// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../risk/IRiskModule.sol";
import "../yield/IYieldAdapter.sol";

abstract contract CollateralVaultStorage is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct CollateralTokenConfig {
        bool isSupported;
        uint8 decimals;
        uint16 collateralFactorBps;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error GuardianNotAuthorized();
    error TokenNotSupported();
    error AmountZero();
    error InsufficientBalance();
    error ZeroAddress();
    error WithdrawExceedsRiskLimits();
    error FactorTooHigh();
    error SameAccountTransfer();
    error PausedError();
    error BadDecimals();

    error DepositsPaused();
    error WithdrawalsPaused();
    error InternalTransfersPaused();
    error YieldOperationsPaused();

    error StrategyNotSet();
    error NotEnoughIdle();
    error StrategyMismatch();
    error YieldNotAllowedForProtocolAccount();
    error StrategyChangeNotAllowedWithActiveShares();
    error InsufficientStrategyShares();
    error AdapterReturnedUnexpectedShares();
    error AdapterPreviewFailed();

    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    /// @notice Legacy primary protocol engine.
    /// @dev Conserved for backward compatibility with the existing codebase.
    event MarginEngineSet(address indexed newMarginEngine);

    /// @notice Engine allowlist update.
    event AuthorizedEngineSet(address indexed engine, bool allowed);

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

    event GlobalPauseSet(bool isPaused);
    event DepositPauseSet(bool isPaused);
    event WithdrawalPauseSet(bool isPaused);
    event InternalTransferPauseSet(bool isPaused);
    event YieldOpsPauseSet(bool isPaused);
    event EmergencyModeUpdated(
        bool depositsPaused,
        bool withdrawalsPaused,
        bool internalTransfersPaused,
        bool yieldOpsPaused
    );

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

    /// @notice Emergency guardian allowed to trigger operational emergency actions.
    /// @dev Intended owner != guardian in production. Owner = governance/timelock, guardian = operational multisig.
    address public guardian;

    /// @notice Legacy primary engine pointer kept for backward compatibility.
    /// @dev Historically this was the only authorized engine.
    address public marginEngine;

    /// @notice Protocol engines authorized to call privileged vault hooks.
    /// @dev Supports options engine + perp engine + future product engines.
    mapping(address => bool) public isAuthorizedEngine;

    /// @notice Optional list of engines for views / admin sync.
    address[] internal authorizedEngines;
    mapping(address => bool) internal isAuthorizedEngineListed;

    IRiskModule public riskModule;

    /// @notice User accounting balance in token native units.
    /// @dev This balance is intended to reflect the effective account balance after sync.
    mapping(address => mapping(address => uint256)) public balances;

    mapping(address => CollateralTokenConfig) internal _collateralConfigs;
    address[] public collateralTokens;
    mapping(address => bool) public isCollateralTokenListed;

    /// @notice Legacy global pause.
    /// @dev Kept for backward compatibility. Effective checks may also use granular flags below.
    bool public paused;

    /// @notice Granular emergency flags.
    bool public depositsPaused;
    bool public withdrawalsPaused;
    bool public internalTransfersPaused;
    bool public yieldOpsPaused;

    /// @notice Strategy adapter configured per token.
    mapping(address => address) public tokenStrategy;

    /// @notice User opt-in for yield deployment per token.
    mapping(address => mapping(address => bool)) public yieldOptIn;

    /// @notice User strategy shares per token.
    mapping(address => mapping(address => uint256)) public strategyShares;

    /// @notice Total strategy shares per token.
    mapping(address => uint256) public tokenTotalStrategyShares;

    /// @notice Idle portion of each user balance per token.
    /// @dev The sum of idle + strategy-backed balance should match effective account balance after sync.
    mapping(address => mapping(address => uint256)) public idleBalances;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
        _;
    }

    /// @dev Legacy modifier name preserved so existing actions/admin files
    ///      do not need immediate signature changes.
    modifier onlyMarginEngine() {
        if (!_isAuthorizedEngine(msg.sender)) revert NotAuthorized();
        _;
    }

    modifier onlyAuthorizedEngine() {
        if (!_isAuthorizedEngine(msg.sender)) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_isAnyPauseActive()) revert PausedError();
        _;
    }

    modifier whenDepositsNotPaused() {
        if (_isDepositsPaused()) revert DepositsPaused();
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        if (_isWithdrawalsPaused()) revert WithdrawalsPaused();
        _;
    }

    modifier whenInternalTransfersNotPaused() {
        if (_isInternalTransfersPaused()) revert InternalTransfersPaused();
        _;
    }

    modifier whenYieldOpsNotPaused() {
        if (_isYieldOpsPaused()) revert YieldOperationsPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL AUTHORIZED ENGINE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isAuthorizedEngine(address engine) internal view returns (bool) {
        return engine != address(0) && (engine == marginEngine || isAuthorizedEngine[engine]);
    }

    function _setAuthorizedEngine(address engine, bool allowed) internal {
        if (engine == address(0)) revert ZeroAddress();

        isAuthorizedEngine[engine] = allowed;

        if (allowed && !isAuthorizedEngineListed[engine]) {
            isAuthorizedEngineListed[engine] = true;
            authorizedEngines.push(engine);
        }

        emit AuthorizedEngineSet(engine, allowed);
    }

    /// @dev Sets the legacy primary engine and auto-authorizes it.
    function _setPrimaryMarginEngine(address engine) internal {
        if (engine == address(0)) revert ZeroAddress();

        marginEngine = engine;
        _setAuthorizedEngine(engine, true);

        emit MarginEngineSet(engine);
    }

    function _getAuthorizedEngines() internal view returns (address[] memory) {
        return authorizedEngines;
    }

    function _isProtocolAccount(address account) internal view returns (bool) {
        return account != address(0) && _isAuthorizedEngine(account);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL TOKEN / CONFIG HELPERS
    //////////////////////////////////////////////////////////////*/

    function _getCollateralConfig(address token) internal view returns (CollateralTokenConfig memory cfg) {
        cfg = _collateralConfigs[token];
    }

    function _requireSupportedToken(address token) internal view returns (CollateralTokenConfig memory cfg) {
        cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();
    }

    function _listCollateralTokenIfNeeded(address token) internal {
        if (!isCollateralTokenListed[token]) {
            isCollateralTokenListed[token] = true;
            collateralTokens.push(token);
        }
    }

    function _setRiskModule(address newRiskModule) internal {
        if (newRiskModule == address(0)) revert ZeroAddress();
        riskModule = IRiskModule(newRiskModule);
        emit RiskModuleSet(newRiskModule);
    }

    function _requireYieldAllowed(address user) internal view {
        if (_isProtocolAccount(user)) revert YieldNotAllowedForProtocolAccount();
    }

    function _requireStrategySet(address token) internal view returns (IYieldAdapter adapter) {
        address strategy = tokenStrategy[token];
        if (strategy == address(0)) revert StrategyNotSet();
        adapter = IYieldAdapter(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL EMERGENCY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isAnyPauseActive() internal view returns (bool) {
        return paused || depositsPaused || withdrawalsPaused || internalTransfersPaused || yieldOpsPaused;
    }

    function _isDepositsPaused() internal view returns (bool) {
        return paused || depositsPaused;
    }

    function _isWithdrawalsPaused() internal view returns (bool) {
        return paused || withdrawalsPaused;
    }

    function _isInternalTransfersPaused() internal view returns (bool) {
        return paused || internalTransfersPaused;
    }

    function _isYieldOpsPaused() internal view returns (bool) {
        return paused || yieldOpsPaused;
    }

    function _setGuardian(address newGuardian) internal {
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianSet(oldGuardian, newGuardian);
    }

    function _setEmergencyModes(
        bool depositsPaused_,
        bool withdrawalsPaused_,
        bool internalTransfersPaused_,
        bool yieldOpsPaused_
    ) internal {
        if (depositsPaused != depositsPaused_) {
            depositsPaused = depositsPaused_;
            emit DepositPauseSet(depositsPaused_);
        }

        if (withdrawalsPaused != withdrawalsPaused_) {
            withdrawalsPaused = withdrawalsPaused_;
            emit WithdrawalPauseSet(withdrawalsPaused_);
        }

        if (internalTransfersPaused != internalTransfersPaused_) {
            internalTransfersPaused = internalTransfersPaused_;
            emit InternalTransferPauseSet(internalTransfersPaused_);
        }

        if (yieldOpsPaused != yieldOpsPaused_) {
            yieldOpsPaused = yieldOpsPaused_;
            emit YieldOpsPauseSet(yieldOpsPaused_);
        }

        emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
    }
}