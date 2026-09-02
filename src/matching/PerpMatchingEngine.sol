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

    /// @notice Emitted when a matched trade is applied via the pre-signed
    ///         intent path (`executeTradeFromIntents`) — mirrors the wire
    ///         format required by PERPS-FULLSTACK-RUNTIME-INTEGRATION-V1
    ///         Part D. Intent hashes are the EIP-712 struct hashes as
    ///         computed by {hashOrderIntent} (i.e. the digest signed by each
    ///         counterparty).
    event TradeExecutedFromIntents(
        bytes32 indexed buyerIntentHash,
        bytes32 indexed sellerIntentHash,
        uint256 marketId,
        uint128 size1e8,
        uint128 executionPrice1e8,
        uint256 timestamp
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
                    INTENT-PATH ERRORS (PART D)
    //////////////////////////////////////////////////////////////*/

    /// @notice Either the buyer's or the seller's intent signature failed
    ///         ECDSA recovery against the intent's declared `trader` field.
    error IntentSignatureInvalid();

    /// @notice A signed intent used the wrong side selector for its role
    ///         (buyer must sign side==0, seller must sign side==1) or the
    ///         side↔bounds shape (buy needs max>0/min==0; sell needs
    ///         min>0/max==0) is violated.
    error IntentSideMismatch();

    /// @notice The buyer, seller, and trade all disagree on `marketId`.
    error IntentMarketMismatch();

    /// @notice The trade payload's `buyerSubaccountId` / `sellerSubaccountId`
    ///         does not match the corresponding signed intent's
    ///         `subaccountId` (defense in depth — subaccount is bound into
    ///         the intent hash so any mismatch already breaks signature).
    error IntentSubaccountMismatch();

    /// @notice The requested fill would exceed the intent's remaining size
    ///         (`intent.size1e8 - intentFilled[hash]`) on the buyer or seller
    ///         side, or the trade size is zero.
    error IntentSizeExceedsRemaining();

    /// @notice Execution price exceeds the buyer's signed `maxExecPrice1e8`.
    error IntentExecPriceAboveBuyerMax();

    /// @notice Execution price is below the seller's signed `minExecPrice1e8`.
    error IntentExecPriceBelowSellerMin();

    /// @notice A signed `limitPrice1e8` was set and the execution price
    ///         violates it (buyer: exec > limit; seller: exec < limit).
    error IntentLimitPriceViolated();

    /// @notice `block.timestamp` is past `intent.deadline` for buyer or seller.
    error IntentDeadlineExpired();

    /// @notice The (trader, nonce) key for this intent has already been
    ///         consumed by a prior intent — replay/duplicate rejected.
    ///         Partial fills against the SAME intent do NOT re-consume the
    ///         nonce (they check `intentFilled[hash]` instead).
    error IntentNonceAlreadyUsed();

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

    /// @notice Cumulative filled size per intent hash — supports partial
    ///         fills against a single signed intent. The key is the EIP-712
    ///         struct hash (i.e. the digest signed by the trader as returned
    ///         by {hashOrderIntent}). Fills stop when
    ///         `intentFilled[hash] == intent.size1e8`.
    mapping(bytes32 => uint128) public intentFilled;

    /// @notice Two-dimensional (trader, nonce) → consumed bitmap for the
    ///         intent execution path. The FIRST fill against an intent
    ///         consumes the nonce (idempotent for that intent — subsequent
    ///         partial fills observe `intentFilled[hash] != 0` and skip
    ///         re-consuming). A different intent that re-uses the same
    ///         `(trader, nonce)` pair MUST revert with
    ///         {IntentNonceAlreadyUsed}.
    /// @dev Kept SEPARATE from the pre-matched `nonces[trader]` monotonic
    ///      counter used by {executeTrade} — the two paths have independent
    ///      nonce spaces, matching the additive design constraint.
    mapping(address => mapping(uint256 => bool)) public intentNonceUsed;

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

    /// @notice EIP-712 typehash for the pre-signed `PerpOrderIntent` payload
    ///         used by the intent-based execution path
    ///         (PERPS-FULLSTACK-RUNTIME-INTEGRATION-V1 Part D). A user signs
    ///         this ONCE and the matcher may then produce any conforming
    ///         `TradeFromIntents` that respects the signed side/price/size
    ///         bounds. Field order MUST match {PerpOrderIntent} exactly.
    /// @dev This typehash is ADDITIVE — it does NOT supersede
    ///      {TRADE_TYPEHASH}. Both entry points remain live: the
    ///      pre-matched `executeTrade(PerpTrade,...)` path (used when both
    ///      counterparties directly co-sign the exact fill) and the
    ///      pre-signed intent path via {executeTradeFromIntents}. The
    ///      EIP-712 domain separator is shared, so both payloads live under
    ///      the same domain and cannot collide (different type hashes bind
    ///      different digests).
    bytes32 public constant ORDER_INTENT_TYPEHASH = keccak256(
        "PerpOrderIntent(bytes32 intentId,address trader,uint32 subaccountId,uint256 marketId,uint8 side,uint128 size1e8,uint128 limitPrice1e8,uint128 maxExecPrice1e8,uint128 minExecPrice1e8,uint256 nonce,uint256 deadline)"
    );

    /// @notice Canonical pre-signed order intent — see {ORDER_INTENT_TYPEHASH}.
    /// @dev `side`: 0 = buy, 1 = sell. On buy: `maxExecPrice1e8 > 0` and
    ///      `minExecPrice1e8 == 0`. On sell: `minExecPrice1e8 > 0` and
    ///      `maxExecPrice1e8 == 0`. `limitPrice1e8 == 0` denotes a market
    ///      order (only bounds constrain).
    struct PerpOrderIntent {
        bytes32 intentId;
        address trader;
        uint32 subaccountId;
        uint256 marketId;
        uint8 side;
        uint128 size1e8;
        uint128 limitPrice1e8;
        uint128 maxExecPrice1e8;
        uint128 minExecPrice1e8;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Fill descriptor emitted by the off-chain matcher against a
    ///         previously-signed pair of intents. Fields MUST correspond to
    ///         the intents (`marketId` matches both intents; subaccount ids
    ///         match each intent's `subaccountId`).
    /// @dev `buyerIntentId` / `sellerIntentId` echo the client-supplied
    ///      `intentId` from each intent — enforced-equal for defense in
    ///      depth (intent identity is bound by hash, not by this field).
    ///      `buyerIsMaker` is a routing hint forwarded to the engine trade
    ///      (mirrors the existing `PerpTrade` semantics) — the intent
    ///      itself does not commit to maker/taker role.
    struct TradeFromIntents {
        uint256 marketId;
        uint32 buyerSubaccountId;
        uint32 sellerSubaccountId;
        uint128 size1e8;
        uint128 executionPrice1e8;
        bool buyerIsMaker;
        bytes32 buyerIntentId;
        bytes32 sellerIntentId;
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

    /// @notice EIP-712 digest of a `PerpOrderIntent` — the value the trader
    ///         signs to authorise a pre-signed intent, and the key under
    ///         which cumulative partial fills are tracked in
    ///         {intentFilled}.
    function hashOrderIntent(PerpOrderIntent calldata i) public view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_INTENT_TYPEHASH,
                i.intentId,
                i.trader,
                i.subaccountId,
                i.marketId,
                i.side,
                i.size1e8,
                i.limitPrice1e8,
                i.maxExecPrice1e8,
                i.minExecPrice1e8,
                i.nonce,
                i.deadline
            )
        );

        digest = _hashTypedDataV4(structHash);
    }

    function previewOrderIntentDigest(PerpOrderIntent calldata i) external view returns (bytes32) {
        return hashOrderIntent(i);
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

    /*//////////////////////////////////////////////////////////////
                INTENT EXECUTION (PART D — ADDITIVE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute one matched trade against a pair of pre-signed
    ///         `PerpOrderIntent`s (PERPS-FULLSTACK-RUNTIME-INTEGRATION-V1
    ///         Part D). Neither party co-signs the specific fill; each
    ///         signed side/price/size bounds authorise the matcher to
    ///         produce any conforming fill.
    /// @dev Additive to `executeTrade(PerpTrade,...)` — does NOT replace
    ///      it. Protocol Part A execution-price guard remains authoritative
    ///      because {applyTrade} is still the ONLY on-ramp into engine
    ///      accounting.
    function executeTradeFromIntents(
        PerpOrderIntent calldata buyerIntent,
        bytes calldata buyerSig,
        PerpOrderIntent calldata sellerIntent,
        bytes calldata sellerSig,
        TradeFromIntents calldata trade
    ) external onlyExecutor whenNotPaused nonReentrant {
        _requireEngineSet();

        // --- (1) signatures ---
        bytes32 buyerHash = hashOrderIntent(buyerIntent);
        bytes32 sellerHash = hashOrderIntent(sellerIntent);

        if (!_verify(buyerIntent.trader, buyerHash, buyerSig)) revert IntentSignatureInvalid();
        if (!_verify(sellerIntent.trader, sellerHash, sellerSig)) revert IntentSignatureInvalid();

        // --- (2) side selectors + side-shape invariant ---
        // Buy MUST use max>0/min==0; Sell MUST use min>0/max==0.
        if (
            buyerIntent.side != 0 || buyerIntent.maxExecPrice1e8 == 0 || buyerIntent.minExecPrice1e8 != 0
        ) revert IntentSideMismatch();
        if (
            sellerIntent.side != 1 || sellerIntent.minExecPrice1e8 == 0 || sellerIntent.maxExecPrice1e8 != 0
        ) revert IntentSideMismatch();

        // --- (3) market alignment ---
        if (
            buyerIntent.marketId != sellerIntent.marketId || buyerIntent.marketId != trade.marketId
        ) revert IntentMarketMismatch();

        // --- (10) deadlines ---
        if (block.timestamp > buyerIntent.deadline || block.timestamp > sellerIntent.deadline) {
            revert IntentDeadlineExpired();
        }

        // --- (12) subaccount echoes (defense in depth — subaccount is in the hash) ---
        if (
            buyerIntent.subaccountId != trade.buyerSubaccountId
                || sellerIntent.subaccountId != trade.sellerSubaccountId
        ) revert IntentSubaccountMismatch();

        // Defense-in-depth: echo of intentId in the trade payload MUST match
        // each intent. Not load-bearing for security (identity is bound by
        // hash), but rejects trivial off-chain composition mistakes.
        if (
            trade.buyerIntentId != buyerIntent.intentId || trade.sellerIntentId != sellerIntent.intentId
        ) revert IntentSubaccountMismatch();

        // --- (5) exec price non-zero ---
        if (trade.executionPrice1e8 == 0) revert IntentExecPriceBelowSellerMin();

        // --- (6)(7) bound checks ---
        if (trade.executionPrice1e8 > buyerIntent.maxExecPrice1e8) revert IntentExecPriceAboveBuyerMax();
        if (trade.executionPrice1e8 < sellerIntent.minExecPrice1e8) revert IntentExecPriceBelowSellerMin();

        // --- (8)(9) limit-price checks (only if limit set) ---
        if (buyerIntent.limitPrice1e8 != 0 && trade.executionPrice1e8 > buyerIntent.limitPrice1e8) {
            revert IntentLimitPriceViolated();
        }
        if (sellerIntent.limitPrice1e8 != 0 && trade.executionPrice1e8 < sellerIntent.limitPrice1e8) {
            revert IntentLimitPriceViolated();
        }

        // --- (4) partial-fill size accounting ---
        if (trade.size1e8 == 0) revert IntentSizeExceedsRemaining();

        uint128 buyerRemaining = buyerIntent.size1e8 - intentFilled[buyerHash];
        uint128 sellerRemaining = sellerIntent.size1e8 - intentFilled[sellerHash];
        if (trade.size1e8 > buyerRemaining || trade.size1e8 > sellerRemaining) {
            revert IntentSizeExceedsRemaining();
        }

        // --- (11) nonce replay: first-fill semantics ---
        _consumeIntentNonceIfFirstFill(buyerIntent, buyerHash);
        _consumeIntentNonceIfFirstFill(sellerIntent, sellerHash);

        // Post-check tally (unchecked: bounded by prior `size1e8` check).
        unchecked {
            intentFilled[buyerHash] += trade.size1e8;
            intentFilled[sellerHash] += trade.size1e8;
        }

        // --- (14) construct engine trade & apply (fires Part A guard) ---
        IPerpEngineTrade.Trade memory mt = IPerpEngineTrade.Trade({
            buyer: buyerIntent.trader,
            seller: sellerIntent.trader,
            marketId: trade.marketId,
            sizeDelta1e8: trade.size1e8,
            executionPrice1e8: trade.executionPrice1e8,
            buyerIsMaker: trade.buyerIsMaker
        });
        perpEngine.applyTrade(mt);

        // --- (15) emit ---
        emit TradeExecutedFromIntents(
            buyerHash, sellerHash, trade.marketId, trade.size1e8, trade.executionPrice1e8, block.timestamp
        );
    }

    /// @dev First fill against an intent consumes the (trader, nonce) slot.
    ///      Subsequent partial fills observe `intentFilled[hash] != 0` and
    ///      skip the consume — they still check the intent is open via the
    ///      caller-side `intentFilled[hash] + size <= intent.size1e8` bound.
    ///      A DIFFERENT intent that re-uses the same (trader, nonce) will
    ///      have `intentFilled[hash] == 0` (different hash), fall into this
    ///      branch, see the slot already true, and revert.
    function _consumeIntentNonceIfFirstFill(PerpOrderIntent calldata intent, bytes32 hash) internal {
        if (intentFilled[hash] != 0) {
            // Already opened — nonce was consumed by the first fill. No-op.
            return;
        }
        if (intentNonceUsed[intent.trader][intent.nonce]) {
            revert IntentNonceAlreadyUsed();
        }
        intentNonceUsed[intent.trader][intent.nonce] = true;
    }
}
