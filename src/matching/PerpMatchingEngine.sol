// SPDX-License-Identifier: BSL-1.1
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
///
///  Security model:
///   - only authorized executors may submit matched trades
///   - both parties sign the exact same EIP-712 payload
///   - each side consumes one strictly monotonic account nonce
///   - traders may invalidate future orders by bumping nonce
contract PerpMatchingEngine is ReentrancyGuard, EIP712 {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);
    event ExecutorSet(address indexed executor, bool allowed);
    event EngineSet(address indexed oldEngine, address indexed newEngine);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event TradeExecuted(
        bytes32 indexed intentId,
        address indexed buyer,
        address indexed seller,
        uint256 marketId,
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
    error PausedError();
    error InvalidSignature();
    error BadNonce();
    error InvalidTrade();
    error DeadlineExpired();
    error OwnershipTransferNotInitiated();
    error EngineNotSet();

    /// @notice Reverts when `executionPrice1e8` exceeds the buyer's signed
    ///         `maxExecutionPrice1e8` bound (V2 PerpTrade user-price bounds —
    ///         PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1). Only triggered
    ///         when the buyer's bound is non-zero.
    error BuyerBoundExceeded();

    /// @notice Reverts when `executionPrice1e8` is below the seller's signed
    ///         `minExecutionPrice1e8` bound (V2 PerpTrade user-price bounds —
    ///         PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1). Only triggered
    ///         when the seller's bound is non-zero.
    error SellerBoundViolated();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public pendingOwner;
    address public guardian;

    IPerpEngineTrade public perpEngine;

    mapping(address => bool) public isExecutor;
    bool public paused;
    mapping(address => uint256) public nonces;

    /// @notice EIP-712 typehash for the signed PerpTrade payload —
    ///         V2 shape (PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1).
    /// @dev
    ///  V1 → V2 typehash supersession: two new fields were inserted between
    ///  `executionPrice1e8` and `buyerIsMaker` to let counterparties sign
    ///  INCLUSIVE user-side price bounds instead of an exact executable
    ///  price:
    ///    - `maxExecutionPrice1e8` — buyer's max acceptable exec price
    ///                              (`0` = strict: exec MUST equal
    ///                              `executionPrice1e8`, legacy shape).
    ///    - `minExecutionPrice1e8` — seller's min acceptable exec price
    ///                              (`0` = strict, symmetric with buyer).
    ///  Both bounds set to `0` is BACKWARDS-COMPATIBLE behaviour: both
    ///  counterparties still sign the exact `executionPrice1e8`, matching
    ///  the pre-V2 limit-order equivalence semantics. Non-zero on either
    ///  side activates the corresponding inclusive bound check inside
    ///  {_executeSingle}.
    ///
    ///  This is a HARD EIP-712 type supersession: because the typehash
    ///  string differs from V1, the resulting `TRADE_TYPEHASH` digest is
    ///  different and every EIP-712 signature produced against the V1
    ///  typehash is REJECTED at signature verification time — the digest
    ///  no longer matches. This is the intended replay-safety property.
    ///  Pre-upgrade off-chain signatures cannot be replayed against the V2
    ///  engine. The domain separator's `version` string is intentionally
    ///  left at `"1"` — mirrors the precedent in
    ///  {OptionOrderTypes} (see `OPTION_ORDER_TYPE` /
    ///  `ACTION_OPTION_ORDER = "OPTION_ORDER_MATCH_V2"` at
    ///  `src/hybrid-v2/options/OptionOrderTypes.sol:108-121`), where a V1
    ///  → V2 payload supersession is expressed by bumping the typehash
    ///  content, not the domain version.
    bytes32 public constant TRADE_TYPEHASH = keccak256(
        "PerpTrade(bytes32 intentId,address buyer,address seller,uint256 marketId,uint128 sizeDelta1e8,uint128 executionPrice1e8,uint128 maxExecutionPrice1e8,uint128 minExecutionPrice1e8,bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)"
    );

    /// @notice Canonical V2 PerpTrade payload signed by both counterparties.
    /// @dev Field order MUST match {TRADE_TYPEHASH} exactly.
    ///      `maxExecutionPrice1e8` / `minExecutionPrice1e8` semantics are
    ///      documented on {TRADE_TYPEHASH}. Setting both to `0` reproduces
    ///      the V1 strict-price signing shape.
    struct PerpTrade {
        bytes32 intentId;
        address buyer;
        address seller;
        uint256 marketId;
        uint128 sizeDelta1e8;
        uint128 executionPrice1e8;
        uint128 maxExecutionPrice1e8;
        uint128 minExecutionPrice1e8;
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

    function setEngine(address _engine) external onlyOwner {
        if (_engine == address(0)) revert ZeroAddress();
        address old = address(perpEngine);
        perpEngine = IPerpEngineTrade(_engine);
        emit EngineSet(old, _engine);
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
                t.intentId,
                t.buyer,
                t.seller,
                t.marketId,
                t.sizeDelta1e8,
                t.executionPrice1e8,
                t.maxExecutionPrice1e8,
                t.minExecutionPrice1e8,
                t.buyerIsMaker,
                t.buyerNonce,
                t.sellerNonce,
                t.deadline
            )
        );

        digest = _hashTypedDataV4(structHash);
    }

    function previewTradeDigest(PerpTrade calldata t) external view returns (bytes32) {
        return hashTrade(t);
    }

    function previewTradeValidity(PerpTrade calldata t)
        external
        view
        returns (
            bool structurallyValid,
            bool deadlineValid,
            bool buyerNonceValid,
            bool sellerNonceValid,
            bytes32 digest
        )
    {
        digest = hashTrade(t);

        structurallyValid = _isStructurallyValid(t);
        deadlineValid = _isDeadlineValid(t);
        buyerNonceValid = nonces[t.buyer] == t.buyerNonce;
        sellerNonceValid = nonces[t.seller] == t.sellerNonce;
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

    function _isStructurallyValid(PerpTrade calldata t) internal pure returns (bool) {
        if (t.intentId == bytes32(0)) return false;
        if (t.buyer == address(0) || t.seller == address(0)) return false;
        if (t.buyer == t.seller) return false;
        if (t.sizeDelta1e8 == 0) return false;
        if (t.executionPrice1e8 == 0) return false;
        return true;
    }

    function _isDeadlineValid(PerpTrade calldata t) internal view returns (bool) {
        if (t.deadline == 0) return true;
        return block.timestamp <= t.deadline;
    }

    function _validate(PerpTrade calldata t) internal view {
        if (!_isStructurallyValid(t)) revert InvalidTrade();
        if (!_isDeadlineValid(t)) revert DeadlineExpired();
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

    function _requireEngineSet() internal view {
        if (address(perpEngine) == address(0)) revert EngineNotSet();
    }

    function _executeSingle(PerpTrade calldata t, bytes calldata buyerSig, bytes calldata sellerSig) internal {
        _validate(t);

        bytes32 digest = hashTrade(t);

        if (!_verify(t.buyer, digest, buyerSig)) revert InvalidSignature();
        if (!_verify(t.seller, digest, sellerSig)) revert InvalidSignature();

        // V2 user-side inclusive execution-price bounds
        // (PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1). A bound of `0`
        // preserves the V1 strict-price semantics (both sides signed the
        // exact `executionPrice1e8`, so no additional check is needed
        // beyond signature match). A non-zero bound activates an inclusive
        // check on the corresponding side. Both bounds are enforced only
        // AFTER signature verification succeeds, so the check operates on
        // consented, authenticated values.
        if (t.maxExecutionPrice1e8 != 0 && t.executionPrice1e8 > t.maxExecutionPrice1e8) {
            revert BuyerBoundExceeded();
        }
        if (t.minExecutionPrice1e8 != 0 && t.executionPrice1e8 < t.minExecutionPrice1e8) {
            revert SellerBoundViolated();
        }

        _consumeNonces(t);

        perpEngine.applyTrade(_toEngineTrade(t));

        emit TradeExecuted(
            t.intentId,
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

    /*//////////////////////////////////////////////////////////////
                                EXECUTION
    //////////////////////////////////////////////////////////////*/

    function executeTrade(PerpTrade calldata t, bytes calldata buyerSig, bytes calldata sellerSig)
        external
        onlyExecutor
        whenNotPaused
        nonReentrant
    {
        _requireEngineSet();
        _executeSingle(t, buyerSig, sellerSig);
    }

    function executeBatch(PerpTrade[] calldata trades, bytes[] calldata buyerSigs, bytes[] calldata sellerSigs)
        external
        onlyExecutor
        whenNotPaused
        nonReentrant
    {
        _requireEngineSet();

        uint256 len = trades.length;
        if (len == 0 || buyerSigs.length != len || sellerSigs.length != len) revert InvalidTrade();

        for (uint256 i = 0; i < len; i++) {
            _executeSingle(trades[i], buyerSigs[i], sellerSigs[i]);
        }
    }
}
