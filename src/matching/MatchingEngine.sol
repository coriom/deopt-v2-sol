// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IMarginEngineTrade} from "./IMarginEngineTrade.sol";

/// @title MatchingEngine (onchain gatekeeper)
/// @notice Vérifie signatures EIP-712 + anti-replay, puis appelle MarginEngine.applyTrade().
/// @dev Modèle:
///  - backend (executor) soumet un trade matché + sig buyer + sig seller.
///  - nonces séquentiels par trader: nonce doit matcher nonces[trader], puis ++.
///  - deadline anti-replay temporel (0 = no deadline).
///  - permissioned execution (isExecutor), signatures restent le fondement de confiance.
///  - hardening ECDSA: refuse malleability / mauvais v,s via ECDSA.recover OZ.
contract MatchingEngine is ReentrancyGuard, EIP712 {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ExecutorSet(address indexed executor, bool allowed);
    event MarginEngineSet(address indexed oldEngine, address indexed newEngine);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event TradeSubmitted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed optionId,
        uint128 quantity,
        uint128 price,
        uint256 buyerNonce,
        uint256 sellerNonce
    );

    event NonceCancelled(address indexed trader, uint256 newNonce);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error PausedError();
    error InvalidTrade();
    error DeadlineExpired();
    error BadNonce();
    error InvalidSignature();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    IMarginEngineTrade public marginEngine;

    mapping(address => bool) public isExecutor;
    bool public paused;

    /// @notice nonces séquentiels par trader (anti-replay)
    mapping(address => uint256) public nonces;

    // EIP-712 typehash
    bytes32 public constant MATCHED_TRADE_TYPEHASH =
        keccak256(
            "MatchedTrade(address buyer,address seller,uint256 optionId,uint128 quantity,uint128 price,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)"
        );

    struct MatchedTrade {
        address buyer;
        address seller;
        uint256 optionId;
        uint128 quantity;
        uint128 price;
        uint256 buyerNonce;
        uint256 sellerNonce;
        uint256 deadline; // 0 = no deadline
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

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _marginEngine) EIP712("DeOptV2-MatchingEngine", "1") {
        if (_owner == address(0) || _marginEngine == address(0)) revert ZeroAddress();

        owner = _owner;
        marginEngine = IMarginEngineTrade(_marginEngine);

        emit OwnershipTransferred(address(0), _owner);
        emit MarginEngineSet(address(0), _marginEngine);

        // Par défaut: owner executor (tu pourras ajouter ton backend ensuite)
        isExecutor[_owner] = true;
        emit ExecutorSet(_owner, true);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setExecutor(address executor, bool allowed) external onlyOwner {
        if (executor == address(0)) revert ZeroAddress();
        isExecutor[executor] = allowed;
        emit ExecutorSet(executor, allowed);
    }

    function setMarginEngine(address _marginEngine) external onlyOwner {
        if (_marginEngine == address(0)) revert ZeroAddress();
        address old = address(marginEngine);
        marginEngine = IMarginEngineTrade(_marginEngine);
        emit MarginEngineSet(old, _marginEngine);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        TRADER ACTIONS (CANCEL)
    //////////////////////////////////////////////////////////////*/

    /// @notice Invalide le nonce courant d’un trader en le bumpant.
    /// @dev Le backend doit resigner avec le nouveau nonce.
    function cancelNextNonce() external {
        uint256 newNonce = nonces[msg.sender] + 1;
        nonces[msg.sender] = newNonce;
        emit NonceCancelled(msg.sender, newNonce);
    }

    /// @notice Invalide tous les nonces <= newNonce-1 en fixant nonces[msg.sender]=newNonce.
    function cancelNoncesUpTo(uint256 newNonce) external {
        if (newNonce <= nonces[msg.sender]) revert BadNonce();
        nonces[msg.sender] = newNonce;
        emit NonceCancelled(msg.sender, newNonce);
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-712 HELPERS
    //////////////////////////////////////////////////////////////*/

    function hashMatchedTrade(MatchedTrade calldata t) public view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                MATCHED_TRADE_TYPEHASH,
                t.buyer,
                t.seller,
                t.optionId,
                t.quantity,
                t.price,
                t.buyerNonce,
                t.sellerNonce,
                t.deadline
            )
        );
        digest = _hashTypedDataV4(structHash);
    }

    function _verify(address signer, bytes32 digest, bytes calldata sig) internal pure returns (bool) {
        // OZ ECDSA.recover: protège contre la malleability (s) + v invalid.
        return digest.recover(sig) == signer;
    }

    function _validateAndConsumeNonces(MatchedTrade calldata t) internal {
        if (nonces[t.buyer] != t.buyerNonce) revert BadNonce();
        if (nonces[t.seller] != t.sellerNonce) revert BadNonce();

        unchecked {
            nonces[t.buyer] = t.buyerNonce + 1;
            nonces[t.seller] = t.sellerNonce + 1;
        }
    }

    function _validateTradeBasics(MatchedTrade calldata t) internal view {
        if (t.buyer == address(0) || t.seller == address(0)) revert InvalidTrade();
        if (t.buyer == t.seller) revert InvalidTrade();
        if (t.quantity == 0 || t.price == 0) revert InvalidTrade();

        if (t.deadline != 0 && block.timestamp > t.deadline) revert DeadlineExpired();
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    function executeTrade(
        MatchedTrade calldata t,
        bytes calldata buyerSig,
        bytes calldata sellerSig
    ) external onlyExecutor whenNotPaused nonReentrant {
        _validateTradeBasics(t);

        bytes32 digest = hashMatchedTrade(t);

        if (!_verify(t.buyer, digest, buyerSig)) revert InvalidSignature();
        if (!_verify(t.seller, digest, sellerSig)) revert InvalidSignature();

        _validateAndConsumeNonces(t);

        // forward to MarginEngine
        IMarginEngineTrade.Trade memory mt = IMarginEngineTrade.Trade({
            buyer: t.buyer,
            seller: t.seller,
            optionId: t.optionId,
            quantity: t.quantity,
            price: t.price
        });

        marginEngine.applyTrade(mt);

        emit TradeSubmitted(
            t.buyer,
            t.seller,
            t.optionId,
            t.quantity,
            t.price,
            t.buyerNonce,
            t.sellerNonce
        );
    }

    function executeBatch(
        MatchedTrade[] calldata trades,
        bytes[] calldata buyerSigs,
        bytes[] calldata sellerSigs
    ) external onlyExecutor whenNotPaused nonReentrant {
        uint256 len = trades.length;
        if (len == 0 || buyerSigs.length != len || sellerSigs.length != len) revert InvalidTrade();

        for (uint256 i = 0; i < len; i++) {
            MatchedTrade calldata t = trades[i];

            _validateTradeBasics(t);

            bytes32 digest = hashMatchedTrade(t);

            if (!_verify(t.buyer, digest, buyerSigs[i])) revert InvalidSignature();
            if (!_verify(t.seller, digest, sellerSigs[i])) revert InvalidSignature();

            _validateAndConsumeNonces(t);

            IMarginEngineTrade.Trade memory mt = IMarginEngineTrade.Trade({
                buyer: t.buyer,
                seller: t.seller,
                optionId: t.optionId,
                quantity: t.quantity,
                price: t.price
            });

            marginEngine.applyTrade(mt);

            emit TradeSubmitted(
                t.buyer,
                t.seller,
                t.optionId,
                t.quantity,
                t.price,
                t.buyerNonce,
                t.sellerNonce
            );
        }
    }
}
