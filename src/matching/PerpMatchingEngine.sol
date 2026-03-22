// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "./IPerpEngineTrade.sol";

/// @title PerpMatchingEngine
/// @notice Dedicated matching engine for perpetuals (EIP-712 + nonces + executor gate).
/// @dev
///  Conventions:
///   - buyer always receives +sizeDelta1e8
///   - seller always receives -sizeDelta1e8
///   - buyerIsMaker:
///       * true  => buyer = maker, seller = taker
///       * false => buyer = taker, seller = maker
contract PerpMatchingEngine is ReentrancyGuard, EIP712 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event ExecutorSet(address indexed executor, bool allowed);
    event EngineSet(address indexed oldEngine, address indexed newEngine);

    event TradeExecuted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed marketId,
        uint128 sizeDelta1e8,
        uint128 executionPrice1e8,
        bool buyerIsMaker,
        uint256 buyerNonce,
        uint256 sellerNonce
    );

    event NonceCancelled(address indexed trader, uint256 newNonce);

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

    IPerpEngineTrade public perpEngine;

    mapping(address => bool) public isExecutor;
    mapping(address => uint256) public nonces;

    bytes32 public constant TRADE_TYPEHASH = keccak256(
        "PerpTrade(address buyer,address seller,uint256 marketId,uint128 sizeDelta1e8,uint128 executionPrice1e8,bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)"
    );

    struct PerpTrade {
        address buyer;
        address seller;
        uint256 marketId;
        uint128 sizeDelta1e8;
        uint128 executionPrice1e8;
        bool buyerIsMaker;
        uint256 buyerNonce;
        uint256 sellerNonce;
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

    constructor(address _owner, address _engine) EIP712("DeOptV2-PerpMatchingEngine", "1") {
        if (_owner == address(0) || _engine == address(0)) revert ZeroAddress();

        owner = _owner;
        perpEngine = IPerpEngineTrade(_engine);

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

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();

        address old = owner;
        owner = address(0);

        emit OwnershipTransferred(old, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        isExecutor[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    function setExecutors(address[] calldata executors, bool[] calldata allowed) external onlyOwner {
        uint256 len = executors.length;
        if (len == 0 || allowed.length != len) revert InvalidTrade();

        for (uint256 i = 0; i < len; i++) {
            address ex = executors[i];
            if (ex == address(0)) revert ZeroAddress();

            bool a = allowed[i];
            isExecutor[ex] = a;
            emit ExecutorSet(ex, a);
        }
    }

    function setEngine(address _engine) external onlyOwner {
        if (_engine == address(0)) revert ZeroAddress();
        address old = address(perpEngine);
        perpEngine = IPerpEngineTrade(_engine);
        emit EngineSet(old, _engine);
    }

    /*//////////////////////////////////////////////////////////////
                        TRADER ACTIONS (CANCEL)
    //////////////////////////////////////////////////////////////*/

    function cancelNextNonce() external {
        uint256 newNonce = nonces[msg.sender] + 1;
        nonces[msg.sender] = newNonce;
        emit NonceCancelled(msg.sender, newNonce);
    }

    function cancelNoncesUpTo(uint256 newNonce) external {
        if (newNonce <= nonces[msg.sender]) revert BadNonce();
        nonces[msg.sender] = newNonce;
        emit NonceCancelled(msg.sender, newNonce);
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-712 HELPERS
    //////////////////////////////////////////////////////////////*/

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashTrade(PerpTrade calldata t) public view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRADE_TYPEHASH,
                t.buyer,
                t.seller,
                t.marketId,
                t.sizeDelta1e8,
                t.executionPrice1e8,
                t.buyerIsMaker,
                t.buyerNonce,
                t.sellerNonce,
                t.deadline
            )
        );

        digest = _hashTypedDataV4(structHash);
    }

    function _verify(address signer, bytes32 digest, bytes calldata sig) internal pure returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        return (err == ECDSA.RecoverError.NoError) && (recovered == signer);
    }

    function _consumeNonces(PerpTrade calldata t) internal {
        if (nonces[t.buyer] != t.buyerNonce) revert BadNonce();
        if (nonces[t.seller] != t.sellerNonce) revert BadNonce();

        unchecked {
            nonces[t.buyer] = t.buyerNonce + 1;
            nonces[t.seller] = t.sellerNonce + 1;
        }
    }

    function _validate(PerpTrade calldata t) internal view {
        if (t.buyer == address(0) || t.seller == address(0)) revert InvalidTrade();
        if (t.buyer == t.seller) revert InvalidTrade();
        if (t.sizeDelta1e8 == 0 || t.executionPrice1e8 == 0) revert InvalidTrade();

        if (t.deadline != 0 && block.timestamp > t.deadline) revert DeadlineExpired();
    }

    function _toEngineTrade(PerpTrade calldata t) internal pure returns (IPerpEngineTrade.Trade memory mt) {
        mt = IPerpEngineTrade.Trade({
            buyer: t.buyer,
            seller: t.seller,
            marketId: t.marketId,
            sizeDelta1e8: t.sizeDelta1e8,
            executionPrice1e8: t.executionPrice1e8,
            buyerIsMaker: t.buyerIsMaker
        });
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    function executeTrade(PerpTrade calldata t, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        onlyExecutor
        nonReentrant
    {
        _validate(t);

        bytes32 digest = hashTrade(t);

        if (!_verify(t.buyer, digest, buyerSig)) revert InvalidSignature();
        if (!_verify(t.seller, digest, sellerSig)) revert InvalidSignature();

        _consumeNonces(t);

        perpEngine.applyTrade(_toEngineTrade(t));

        emit TradeExecuted(
            t.buyer,
            t.seller,
            t.marketId,
            t.sizeDelta1e8,
            t.executionPrice1e8,
            t.buyerIsMaker,
            t.buyerNonce,
            t.sellerNonce
        );
    }

    function executeBatch(PerpTrade[] calldata trades, bytes[] calldata buyerSigs, bytes[] calldata sellerSigs)
        external
        onlyExecutor
        nonReentrant
    {
        uint256 len = trades.length;
        if (len == 0 || buyerSigs.length != len || sellerSigs.length != len) revert InvalidTrade();

        for (uint256 i = 0; i < len; i++) {
            PerpTrade calldata t = trades[i];

            _validate(t);

            bytes32 digest = hashTrade(t);

            if (!_verify(t.buyer, digest, buyerSigs[i])) revert InvalidSignature();
            if (!_verify(t.seller, digest, sellerSigs[i])) revert InvalidSignature();

            _consumeNonces(t);

            perpEngine.applyTrade(_toEngineTrade(t));

            emit TradeExecuted(
                t.buyer,
                t.seller,
                t.marketId,
                t.sizeDelta1e8,
                t.executionPrice1e8,
                t.buyerIsMaker,
                t.buyerNonce,
                t.sellerNonce
            );
        }
    }
}