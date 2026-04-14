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
    error OperationAlreadyQueued();
    error OperationNotQueued();
    error OperationAlreadyExecuted();
    error OperationAlreadyCancelled();
    error InvalidOperationState();
    error InvalidTarget();

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum OperationState {
        None,
        Queued,
        Executed,
        Cancelled
    }

    struct QueuedOperation {
        address target;
        uint256 value;
        uint256 eta;
        bytes data;
        OperationState state;
    }

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

    /// @notice Bookkeeping layer for operations queued through the governor.
    mapping(bytes32 => QueuedOperation) internal queuedOperations;

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

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setGuardian(address newGuardian) internal {
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    function _setRiskModule(address newTarget) internal {
        address old = riskModule;
        riskModule = newTarget;
        emit RiskModuleSet(old, newTarget);
    }

    function _setMarginEngine(address newTarget) internal {
        address old = marginEngine;
        marginEngine = newTarget;
        emit MarginEngineSet(old, newTarget);
    }

    function _setOracleRouter(address newTarget) internal {
        address old = oracleRouter;
        oracleRouter = newTarget;
        emit OracleRouterSet(old, newTarget);
    }

    function _setFeesManager(address newTarget) internal {
        address old = feesManager;
        feesManager = newTarget;
        emit FeesManagerSet(old, newTarget);
    }

    function _setOptionRegistry(address newTarget) internal {
        address old = optionRegistry;
        optionRegistry = newTarget;
        emit OptionRegistrySet(old, newTarget);
    }

    function _setCollateralVault(address newTarget) internal {
        address old = collateralVault;
        collateralVault = newTarget;
        emit CollateralVaultSet(old, newTarget);
    }

    function _setInsuranceFund(address newTarget) internal {
        address old = insuranceFund;
        insuranceFund = newTarget;
        emit InsuranceFundSet(old, newTarget);
    }

    function _setPerpMarketRegistry(address newTarget) internal {
        address old = perpMarketRegistry;
        perpMarketRegistry = newTarget;
        emit PerpMarketRegistrySet(old, newTarget);
    }

    function _setPerpEngine(address newTarget) internal {
        address old = perpEngine;
        perpEngine = newTarget;
        emit PerpEngineSet(old, newTarget);
    }

    function _validateTarget(address target) internal pure {
        if (target == address(0)) revert InvalidTarget();
    }

    function _storeQueuedOperation(bytes32 txHash, address target, uint256 value, uint256 eta, bytes memory data)
        internal
    {
        QueuedOperation storage op = queuedOperations[txHash];
        if (op.state == OperationState.Queued) revert OperationAlreadyQueued();
        if (op.state == OperationState.Executed) revert OperationAlreadyExecuted();
        if (op.state == OperationState.Cancelled) revert OperationAlreadyCancelled();

        queuedOperations[txHash] = QueuedOperation({
            target: target,
            value: value,
            eta: eta,
            data: data,
            state: OperationState.Queued
        });
    }

    function _markOperationCancelled(bytes32 txHash) internal {
        QueuedOperation storage op = queuedOperations[txHash];
        if (op.state != OperationState.Queued) revert OperationNotQueued();
        op.state = OperationState.Cancelled;
    }

    function _markOperationExecuted(bytes32 txHash) internal {
        QueuedOperation storage op = queuedOperations[txHash];
        if (op.state != OperationState.Queued) revert OperationNotQueued();
        op.state = OperationState.Executed;
    }

    function _getQueuedOperation(bytes32 txHash) internal view returns (QueuedOperation memory op) {
        op = queuedOperations[txHash];
    }
}