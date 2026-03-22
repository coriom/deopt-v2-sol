// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ProtocolTimelock.sol";
import "./RiskGovernorInterfaces.sol";

abstract contract RiskGovernorStorage {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    event RiskModuleSet(address indexed oldTarget, address indexed newTarget);
    event MarginEngineSet(address indexed oldTarget, address indexed newTarget);
    event OracleRouterSet(address indexed oldTarget, address indexed newTarget);
    event FeesManagerSet(address indexed oldTarget, address indexed newTarget);
    event OptionRegistrySet(address indexed oldTarget, address indexed newTarget);
    event CollateralVaultSet(address indexed oldTarget, address indexed newTarget);
    event InsuranceFundSet(address indexed oldTarget, address indexed newTarget);

    event PerpMarketRegistrySet(address indexed oldTarget, address indexed newTarget);
    event PerpEngineSet(address indexed oldTarget, address indexed newTarget);

    event OperationQueued(bytes32 indexed txHash, address indexed target, uint256 value, uint256 eta, bytes data);
    event OperationCancelled(bytes32 indexed txHash, address indexed target, uint256 value, uint256 eta, bytes data);
    event OperationExecuted(bytes32 indexed txHash, address indexed target, uint256 value, uint256 eta, bytes data);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error OwnershipTransferNotInitiated();
    error TimelockValueMismatch();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    ProtocolTimelock public immutable timelock;

    address public riskModule;
    address public marginEngine;
    address public oracleRouter;
    address public feesManager;
    address public optionRegistry;
    address public collateralVault;
    address public insuranceFund;

    address public perpMarketRegistry;
    address public perpEngine;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _owner,
        address _guardian,
        address _timelock,
        address _riskModule,
        address _marginEngine,
        address _oracleRouter,
        address _feesManager,
        address _optionRegistry,
        address _collateralVault,
        address _insuranceFund,
        address _perpMarketRegistry,
        address _perpEngine
    ) {
        if (_owner == address(0) || _timelock == address(0)) revert ZeroAddress();

        owner = _owner;
        guardian = _guardian;
        timelock = ProtocolTimelock(payable(_timelock));

        riskModule = _riskModule;
        marginEngine = _marginEngine;
        oracleRouter = _oracleRouter;
        feesManager = _feesManager;
        optionRegistry = _optionRegistry;
        collateralVault = _collateralVault;
        insuranceFund = _insuranceFund;

        perpMarketRegistry = _perpMarketRegistry;
        perpEngine = _perpEngine;

        emit OwnershipTransferred(address(0), _owner);
        emit GuardianSet(address(0), _guardian);

        emit RiskModuleSet(address(0), _riskModule);
        emit MarginEngineSet(address(0), _marginEngine);
        emit OracleRouterSet(address(0), _oracleRouter);
        emit FeesManagerSet(address(0), _feesManager);
        emit OptionRegistrySet(address(0), _optionRegistry);
        emit CollateralVaultSet(address(0), _collateralVault);
        emit InsuranceFundSet(address(0), _insuranceFund);

        emit PerpMarketRegistrySet(address(0), _perpMarketRegistry);
        emit PerpEngineSet(address(0), _perpEngine);
    }
}