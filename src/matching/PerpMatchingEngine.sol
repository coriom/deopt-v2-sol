// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IPerpEngine {
    function applyTrade(
        address taker,
        address maker,
        uint256 marketId,
        int256 sizeDelta,
        uint256 price,
        bool takerIsLong
    ) external;
}

/// @title PerpMatchingEngine
/// @notice Matching engine dédié aux perps (EIP-712 + nonces + execution gate)
contract PerpMatchingEngine is ReentrancyGuard, EIP712 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event ExecutorSet(address indexed executor, bool allowed);
    event EngineSet(address indexed oldEngine, address indexed newEngine);

    event TradeExecuted(
        address indexed taker,
        address indexed maker,
        uint256 indexed marketId,
        int256 sizeDelta,
        uint256 price,
        bool takerIsLong,
        uint256 takerNonce,
        uint256 makerNonce
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidSignature();
    error BadNonce();
    error InvalidTrade();
    error DeadlineExpired();
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;

    IPerpEngine public perpEngine;

    mapping(address => bool) public isExecutor;
    mapping(address => uint256) public nonces;

    bytes32 public constant TRADE_TYPEHASH = keccak256(
        "PerpTrade(address taker,address maker,uint256 marketId,int256 sizeDelta,uint256 price,bool takerIsLong,uint256 takerNonce,uint256 makerNonce,uint256 deadline)"
    );

    struct PerpTrade {
        address taker;
        address maker;
        uint256 marketId;
        int256 sizeDelta;
        uint256 price;
        bool takerIsLong;
        uint256 takerNonce;
        uint256 makerNonce;
        uint256 deadline;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyExecutor() {
        if (!isExecutor[msg.sender]) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _engine)
        EIP712("DeOptV2-PerpMatchingEngine", "1")
    {
        if (_owner == address(0) || _engine == address(0)) revert ZeroAddress();

        owner = _owner;
        perpEngine = IPerpEngine(_engine);

        isExecutor[_owner] = true;

        emit OwnershipTransferred(address(0), _owner);
        emit EngineSet(address(0), _engine);
        emit ExecutorSet(_owner, true);
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

    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        isExecutor[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    function setEngine(address _engine) external onlyOwner {
        if (_engine == address(0)) revert ZeroAddress();
        address old = address(perpEngine);
        perpEngine = IPerpEngine(_engine);
        emit EngineSet(old, _engine);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function hashTrade(PerpTrade calldata t) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRADE_TYPEHASH,
                t.taker,
                t.maker,
                t.marketId,
                t.sizeDelta,
                t.price,
                t.takerIsLong,
                t.takerNonce,
                t.makerNonce,
                t.deadline
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _verify(address signer, bytes32 digest, bytes calldata sig) internal pure returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        return (err == ECDSA.RecoverError.NoError) && (recovered == signer);
    }

    function _consumeNonces(PerpTrade calldata t) internal {
        if (nonces[t.taker] != t.takerNonce) revert BadNonce();
        if (nonces[t.maker] != t.makerNonce) revert BadNonce();

        unchecked {
            nonces[t.taker] = t.takerNonce + 1;
            nonces[t.maker] = t.makerNonce + 1;
        }
    }

    function _validate(PerpTrade calldata t) internal view {
        if (t.taker == address(0) || t.maker == address(0)) revert InvalidTrade();
        if (t.taker == t.maker) revert InvalidTrade();
        if (t.sizeDelta == 0 || t.price == 0) revert InvalidTrade();

        if (t.deadline != 0 && block.timestamp > t.deadline) revert DeadlineExpired();
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    function executeTrade(
        PerpTrade calldata t,
        bytes calldata takerSig,
        bytes calldata makerSig
    )
        external
        onlyExecutor
        nonReentrant
    {
        _validate(t);

        bytes32 digest = hashTrade(t);

        if (!_verify(t.taker, digest, takerSig)) revert InvalidSignature();
        if (!_verify(t.maker, digest, makerSig)) revert InvalidSignature();

        _consumeNonces(t);

        perpEngine.applyTrade(
            t.taker,
            t.maker,
            t.marketId,
            t.sizeDelta,
            t.price,
            t.takerIsLong
        );

        emit TradeExecuted(
            t.taker,
            t.maker,
            t.marketId,
            t.sizeDelta,
            t.price,
            t.takerIsLong,
            t.takerNonce,
            t.makerNonce
        );
    }
}