// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {IMarginEngineTrade} from "./IMarginEngineTrade.sol";

/// @title OptionMatchingEngine
/// @notice Dedicated option execution ingress for signed on-chain option intents.
/// @dev
///  Security model:
///   - only authorized executors may submit matched option trades
///   - buyer and seller both sign the same EIP-712 payload
///   - sequential per-address nonces provide replay protection
///   - signed series metadata is checked against OptionProductRegistry
///   - MarginEngine remains the canonical option accounting surface
contract OptionMatchingEngine is ReentrancyGuard, EIP712 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);
    event ExecutorSet(address indexed executor, bool allowed);
    event EngineSet(address indexed oldEngine, address indexed newEngine);
    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event OptionTradeExecuted(
        bytes32 indexed intentId,
        address indexed buyer,
        address indexed seller,
        uint256 optionId,
        uint128 quantity,
        uint128 premiumPerContract,
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
    error PausedError();
    error InvalidSignature();
    error BadNonce();
    error InvalidTrade();
    error DeadlineExpired();
    error OwnershipTransferNotInitiated();
    error EngineNotSet();
    error RegistryNotSet();
    error UnknownOptionId();
    error SeriesInactive();
    error SeriesMetadataMismatch();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    IMarginEngineTrade public marginEngine;
    OptionProductRegistry public optionRegistry;

    mapping(address => bool) public isExecutor;
    bool public paused;
    mapping(address => uint256) public nonces;

    bytes32 public constant TRADE_TYPEHASH = keccak256(
        "OptionTrade(bytes32 intentId,address buyer,address seller,uint256 optionId,address underlying,address settlementAsset,uint64 expiry,uint64 strike1e8,bool isCall,uint128 contractSize1e8,uint128 quantity,uint128 premiumPerContract,bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)"
    );

    struct OptionTrade {
        bytes32 intentId;
        address buyer;
        address seller;
        uint256 optionId;
        address underlying;
        address settlementAsset;
        uint64 expiry;
        uint64 strike1e8;
        bool isCall;
        uint128 contractSize1e8;
        uint128 quantity;
        uint128 premiumPerContract;
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

    modifier onlyGuardianOrOwner() {
        if (msg.sender != guardian && msg.sender != owner) revert NotAuthorized();
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

    constructor(address _owner, address _marginEngine, address _optionRegistry)
        EIP712("DeOptV2-OptionMatchingEngine", "1")
    {
        if (_owner == address(0) || _marginEngine == address(0) || _optionRegistry == address(0)) {
            revert ZeroAddress();
        }

        owner = _owner;
        marginEngine = IMarginEngineTrade(_marginEngine);
        optionRegistry = OptionProductRegistry(_optionRegistry);

        isExecutor[_owner] = true;

        emit OwnershipTransferred(address(0), _owner);
        emit EngineSet(address(0), _marginEngine);
        emit RegistrySet(address(0), _optionRegistry);
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

    function setGuardian(address newGuardian) external onlyOwner {
        address old = guardian;
        guardian = newGuardian;
        emit GuardianSet(old, newGuardian);
    }

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

    function setEngine(address _marginEngine) external onlyOwner {
        if (_marginEngine == address(0)) revert ZeroAddress();
        address old = address(marginEngine);
        marginEngine = IMarginEngineTrade(_marginEngine);
        emit EngineSet(old, _marginEngine);
    }

    function setRegistry(address _optionRegistry) external onlyOwner {
        if (_optionRegistry == address(0)) revert ZeroAddress();
        address old = address(optionRegistry);
        optionRegistry = OptionProductRegistry(_optionRegistry);
        emit RegistrySet(old, _optionRegistry);
    }

    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
        }
    }

    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        TRADER ACTIONS (CANCEL)
    //////////////////////////////////////////////////////////////*/

    function cancelNextNonce() external {
        uint256 newNonce = nonces[msg.sender] + 1;
        nonces[msg.sender] = newNonce;
        emit NonceCancelled(msg.sender, newNonce);
    }

    function cancelNoncesUpTo(uint256 targetNonce) external {
        if (targetNonce <= nonces[msg.sender]) revert BadNonce();
        nonces[msg.sender] = targetNonce;
        emit NonceCancelled(msg.sender, targetNonce);
    }

    /*//////////////////////////////////////////////////////////////
                            EIP-712 HELPERS
    //////////////////////////////////////////////////////////////*/

    function domainSeparatorV4() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashTrade(OptionTrade calldata t) public view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRADE_TYPEHASH,
                t.intentId,
                t.buyer,
                t.seller,
                t.optionId,
                t.underlying,
                t.settlementAsset,
                t.expiry,
                t.strike1e8,
                t.isCall,
                t.contractSize1e8,
                t.quantity,
                t.premiumPerContract,
                t.buyerIsMaker,
                t.buyerNonce,
                t.sellerNonce,
                t.deadline
            )
        );

        digest = _hashTypedDataV4(structHash);
    }

    function previewTradeDigest(OptionTrade calldata t) external view returns (bytes32) {
        return hashTrade(t);
    }

    function previewTradeValidity(OptionTrade calldata t)
        external
        view
        returns (
            bool structurallyValid,
            bool deadlineValid,
            bool buyerNonceValid,
            bool sellerNonceValid,
            bool seriesMetadataValid,
            bytes32 digest
        )
    {
        digest = hashTrade(t);

        structurallyValid = _isStructurallyValid(t);
        deadlineValid = _isDeadlineValid(t);
        buyerNonceValid = nonces[t.buyer] == t.buyerNonce;
        sellerNonceValid = nonces[t.seller] == t.sellerNonce;
        seriesMetadataValid = _isSeriesMetadataValid(t);
    }

    function _verify(address signer, bytes32 digest, bytes calldata sig) internal pure returns (bool) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        return (err == ECDSA.RecoverError.NoError) && (recovered == signer);
    }

    function _consumeNonces(OptionTrade calldata t) internal {
        if (nonces[t.buyer] != t.buyerNonce) revert BadNonce();
        if (nonces[t.seller] != t.sellerNonce) revert BadNonce();

        unchecked {
            nonces[t.buyer] = t.buyerNonce + 1;
            nonces[t.seller] = t.sellerNonce + 1;
        }
    }

    function _isStructurallyValid(OptionTrade calldata t) internal pure returns (bool) {
        if (t.intentId == bytes32(0)) return false;
        if (t.buyer == address(0) || t.seller == address(0)) return false;
        if (t.buyer == t.seller) return false;
        if (t.underlying == address(0) || t.settlementAsset == address(0)) return false;
        if (t.expiry == 0 || t.strike1e8 == 0 || t.contractSize1e8 == 0) return false;
        if (t.quantity == 0 || t.premiumPerContract == 0) return false;
        return true;
    }

    function _isDeadlineValid(OptionTrade calldata t) internal view returns (bool) {
        if (t.deadline == 0) return true;
        return block.timestamp <= t.deadline;
    }

    function _isSeriesMetadataValid(OptionTrade calldata t) internal view returns (bool) {
        OptionProductRegistry registry = optionRegistry;
        if (address(registry) == address(0)) return false;

        (OptionProductRegistry.OptionSeries memory series, bool exists) = registry.getSeriesIfExists(t.optionId);
        if (!exists || !series.isActive) return false;

        return series.underlying == t.underlying && series.settlementAsset == t.settlementAsset
            && series.expiry == t.expiry && series.strike == t.strike1e8 && series.isCall == t.isCall
            && series.contractSize1e8 == t.contractSize1e8;
    }

    function _validate(OptionTrade calldata t) internal view {
        if (!_isStructurallyValid(t)) revert InvalidTrade();
        if (!_isDeadlineValid(t)) revert DeadlineExpired();
        _validateSeriesMetadata(t);
    }

    function _validateSeriesMetadata(OptionTrade calldata t) internal view {
        OptionProductRegistry registry = optionRegistry;
        if (address(registry) == address(0)) revert RegistryNotSet();

        (OptionProductRegistry.OptionSeries memory series, bool exists) = registry.getSeriesIfExists(t.optionId);
        if (!exists) revert UnknownOptionId();
        if (!series.isActive) revert SeriesInactive();

        if (
            series.underlying != t.underlying || series.settlementAsset != t.settlementAsset
                || series.expiry != t.expiry || series.strike != t.strike1e8 || series.isCall != t.isCall
                || series.contractSize1e8 != t.contractSize1e8
        ) {
            revert SeriesMetadataMismatch();
        }
    }

    function _toMarginTrade(OptionTrade calldata t) internal pure returns (IMarginEngineTrade.Trade memory mt) {
        mt = IMarginEngineTrade.Trade({
            buyer: t.buyer,
            seller: t.seller,
            optionId: t.optionId,
            quantity: t.quantity,
            price: t.premiumPerContract,
            buyerIsMaker: t.buyerIsMaker
        });
    }

    function _requireEngineSet() internal view {
        if (address(marginEngine) == address(0)) revert EngineNotSet();
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    function executeTrade(OptionTrade calldata t, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        onlyExecutor
        whenNotPaused
        nonReentrant
    {
        _requireEngineSet();
        _validate(t);

        bytes32 digest = hashTrade(t);

        if (!_verify(t.buyer, digest, buyerSig)) revert InvalidSignature();
        if (!_verify(t.seller, digest, sellerSig)) revert InvalidSignature();

        _consumeNonces(t);

        marginEngine.applyTrade(_toMarginTrade(t));

        emit OptionTradeExecuted(
            t.intentId,
            t.buyer,
            t.seller,
            t.optionId,
            t.quantity,
            t.premiumPerContract,
            t.buyerIsMaker,
            t.buyerNonce,
            t.sellerNonce
        );
    }
}
