// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ProtocolTimelock
/// @notice Generic timelock used to execute sensitive protocol changes after a delay.
/// @dev
///  - Operations are identified by:
///      keccak256(abi.encode(target, value, data, eta))
///  - `eta` must be >= block.timestamp + minDelay when queueing.
///  - A queued operation can be executed in [eta ; eta + GRACE_PERIOD].
///  - `proposers` can queue.
///  - `executors` can execute.
///  - `guardian` or `owner` can cancel / pause queueing.
///  - The timelock is expected to become owner of sensitive contracts
///    (RiskModule, OracleRouter, FeesManager, OptionProductRegistry, etc.).
///  - Queueing can be stopped without blocking execution of already queued operations.
///  - Bootstrap: owner is proposer + executor by default.
///  - Guardian is intentionally limited to cancellation / queue pause, not execution.
///  - Supports native value forwarding on execution.
contract ProtocolTimelock {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MIN_DELAY_FLOOR = 1 hours;
    uint256 public constant MAX_DELAY_CEILING = 30 days;
    uint256 public constant GRACE_PERIOD = 14 days;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);
    event ProposerSet(address indexed account, bool allowed);
    event ExecutorSet(address indexed account, bool allowed);

    event MinDelaySet(uint256 oldDelay, uint256 newDelay);
    event QueuePaused(address indexed account);
    event QueueUnpaused(address indexed account);

    event TransactionQueued(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);

    event TransactionCancelled(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);

    event TransactionExecuted(
        bytes32 indexed txHash,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 eta,
        bytes returnData
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidDelay();
    error EtaTooSoon();
    error TransactionNotQueued();
    error TransactionAlreadyQueued();
    error TransactionNotReady();
    error TransactionStale();
    error TransactionExecutionFailed(bytes revertData);
    error OwnershipTransferNotInitiated();
    error QueuePausedError();
    error InvalidMsgValue();
    error LengthMismatch();
    error EmptyBatch();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    uint256 public minDelay;
    bool public queuePaused;

    mapping(address => bool) public proposers;
    mapping(address => bool) public executors;

    mapping(bytes32 => bool) public queuedTransactions;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyProposer() {
        if (!proposers[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier onlyExecutor() {
        if (!executors[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier whenQueueNotPaused() {
        if (queuePaused) revert QueuePausedError();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _guardian, uint256 _minDelay) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_minDelay < MIN_DELAY_FLOOR || _minDelay > MAX_DELAY_CEILING) revert InvalidDelay();

        owner = _owner;
        guardian = _guardian;
        minDelay = _minDelay;

        // bootstrap
        proposers[_owner] = true;
        executors[_owner] = true;

        emit OwnershipTransferred(address(0), _owner);
        emit GuardianSet(address(0), _guardian);
        emit ProposerSet(_owner, true);
        emit ExecutorSet(_owner, true);
        emit MinDelaySet(0, _minDelay);
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

        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, po);
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
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @dev address(0) allowed to disable guardian.
    function setGuardian(address newGuardian) external onlyOwner {
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

    function setProposer(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        proposers[account] = allowed;
        emit ProposerSet(account, allowed);
    }

    function setExecutor(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        executors[account] = allowed;
        emit ExecutorSet(account, allowed);
    }

    function setProposers(address[] calldata accounts, bool[] calldata allowed) external onlyOwner {
        uint256 len = accounts.length;
        if (len == 0) revert EmptyBatch();
        if (allowed.length != len) revert LengthMismatch();

        for (uint256 i = 0; i < len; i++) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();

            bool allow = allowed[i];
            proposers[account] = allow;
            emit ProposerSet(account, allow);
        }
    }

    function setExecutors(address[] calldata accounts, bool[] calldata allowed) external onlyOwner {
        uint256 len = accounts.length;
        if (len == 0) revert EmptyBatch();
        if (allowed.length != len) revert LengthMismatch();

        for (uint256 i = 0; i < len; i++) {
            address account = accounts[i];
            if (account == address(0)) revert ZeroAddress();

            bool allow = allowed[i];
            executors[account] = allow;
            emit ExecutorSet(account, allow);
        }
    }

    function setMinDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_DELAY_FLOOR || newDelay > MAX_DELAY_CEILING) revert InvalidDelay();

        uint256 old = minDelay;
        minDelay = newDelay;

        emit MinDelaySet(old, newDelay);
    }

    function pauseQueueing() external onlyGuardianOrOwner {
        if (!queuePaused) {
            queuePaused = true;
            emit QueuePaused(msg.sender);
        }
    }

    function unpauseQueueing() external onlyOwner {
        if (queuePaused) {
            queuePaused = false;
            emit QueueUnpaused(msg.sender);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HASH / VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function hashOperation(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        pure
        returns (bytes32)
    {
        return _hashOperation(target, value, data, eta);
    }

    function hashOperationBytes(address target, uint256 value, bytes memory data, uint256 eta)
        public
        pure
        returns (bytes32)
    {
        return _hashOperation(target, value, data, eta);
    }

    function isQueued(address target, uint256 value, bytes calldata data, uint256 eta) external view returns (bool) {
        return queuedTransactions[_hashOperation(target, value, data, eta)];
    }

    function isOperationReady(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        view
        returns (bool)
    {
        bytes32 txHash = _hashOperation(target, value, data, eta);
        if (!queuedTransactions[txHash]) return false;
        if (block.timestamp < eta) return false;
        if (block.timestamp > eta + GRACE_PERIOD) return false;
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                                CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    function queueTransaction(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        onlyProposer
        whenQueueNotPaused
        returns (bytes32 txHash)
    {
        if (target == address(0)) revert ZeroAddress();
        if (eta < block.timestamp + minDelay) revert EtaTooSoon();

        txHash = _hashOperation(target, value, data, eta);
        if (queuedTransactions[txHash]) revert TransactionAlreadyQueued();

        queuedTransactions[txHash] = true;

        emit TransactionQueued(txHash, target, value, data, eta);
    }

    function cancelTransaction(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        onlyGuardianOrOwner
        returns (bytes32 txHash)
    {
        if (target == address(0)) revert ZeroAddress();

        txHash = _hashOperation(target, value, data, eta);
        if (!queuedTransactions[txHash]) revert TransactionNotQueued();

        queuedTransactions[txHash] = false;

        emit TransactionCancelled(txHash, target, value, data, eta);
    }

    function executeTransaction(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        payable
        onlyExecutor
        returns (bytes memory returnData)
    {
        if (target == address(0)) revert ZeroAddress();
        if (msg.value != value) revert InvalidMsgValue();

        bytes32 txHash = _hashOperation(target, value, data, eta);
        if (!queuedTransactions[txHash]) revert TransactionNotQueued();
        if (block.timestamp < eta) revert TransactionNotReady();
        if (block.timestamp > eta + GRACE_PERIOD) revert TransactionStale();

        queuedTransactions[txHash] = false;

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert TransactionExecutionFailed(ret);

        emit TransactionExecuted(txHash, target, value, data, eta, ret);
        return ret;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _hashOperation(address target, uint256 value, bytes memory data, uint256 eta)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, eta));
    }

    receive() external payable {}
}