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
    error TokenNotSupported();
    error AmountZero();
    error InsufficientBalance();
    error ZeroAddress();
    error WithdrawExceedsRiskLimits();
    error FactorTooHigh();
    error SameAccountTransfer();
    error PausedError();
    error BadDecimals();

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

    event MarginEngineSet(address indexed newMarginEngine);
    event RiskModuleSet(address indexed newRiskModule);

    event CollateralTokenConfigured(
        address indexed token, bool isSupported, uint8 decimals, uint16 collateralFactorBps
    );

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event InternalTransfer(address indexed token, address indexed from, address indexed to, uint256 amount);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

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

    mapping(address => mapping(address => uint256)) public balances;

    mapping(address => CollateralTokenConfig) internal _collateralConfigs;
    address[] public collateralTokens;
    mapping(address => bool) public isCollateralTokenListed;

    bool public paused;

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

    modifier onlyMarginEngine() {
        if (msg.sender != marginEngine) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }
}