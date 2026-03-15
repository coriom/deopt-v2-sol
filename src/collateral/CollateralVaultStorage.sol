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

    address public marginEngine;
    IRiskModule public riskModule;

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

    mapping(address => address) public tokenStrategy;
    mapping(address => mapping(address => bool)) public yieldOptIn;
    mapping(address => mapping(address => uint256)) public strategyShares;
    mapping(address => uint256) public tokenTotalStrategyShares;
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

    modifier onlyMarginEngine() {
        if (msg.sender != marginEngine) revert NotAuthorized();
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