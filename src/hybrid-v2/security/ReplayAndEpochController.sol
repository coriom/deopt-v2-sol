// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IReplayAndEpochController} from "./IReplayAndEpochController.sol";
import {IReplayProtected} from "../interfaces/IReplayProtected.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {IntentHash} from "../libraries/IntentHash.sol";
import {SubKey} from "../libraries/SubKey.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title ReplayAndEpochController
/// @notice Canonical durable D.2 replay + owner/subaccount recovery-epoch foundation
///         inherited by every DeOpt V2 matching engine (WP-08) and the escape
///         controller (WP-10).
/// @dev
///  Abstract; MUST be inherited. Introduces:
///
///   1. per-signer per-engine sequential nonces (spec 08 D-C-08 FROZEN)
///   2. per-engine consumed-intent-hash set (spec 08 D-C-08 + INV-AUTH-06)
///   3. per-subaccount recovery epoch monotonic counter (escape design P-1)
///   4. owner-wide recovery epoch monotonic counter (escape design P-2)
///   5. deadline validation helper (spec 08)
///   6. canonical `SignedActionEnvelope` digest primitive built on OZ `EIP712` (spec 08)
///
///  D.1 / D.2 separation is preserved: this contract implements ONLY D.2 canonical
///  chain-side replay state; D.1 off-chain coordination remains a backend concern.
///
///  Deployment-version binding (Part C verdict: FROZEN
///  `DEPLOYMENT_VERSION_IS_MANIFEST_ONLY_WITH_VERIFYING_CONTRACT_DOMAIN`):
///  cross-deployment signature separation is provided entirely by
///  `verifyingContract` in the EIP-712 domain (bound automatically by
///  OpenZeppelin's `EIP712` cache) PLUS the deployment-scoped registry address
///  encoded into `subKey`. `deploymentVersion` is NEVER bound into signed payloads
///  (see `EIP712Types.sol` for the frozen envelope shape).
///
///  Recovery-authority path (WP-10):
///   - `_advanceSubaccountRecoveryEpoch(subKey, actor)` + `_advanceOwnerRecoveryEpoch(owner, actor)`
///     are `internal` primitives. WP-10 `EscapeController` inherits this abstract and
///     exposes its own authority-gated externals that call these primitives after
///     verifying the objective on-chain conditions for recovery activation.
///   - This abstract does NOT expose a broad mutable admin. Owner is always
///     authorized for their own scope; every other authority path lives in
///     downstream inheritors.
abstract contract ReplayAndEpochController is IReplayAndEpochController, EIP712 {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Immutable Registry reference. Used ONLY by owner-path epoch mutators
    ///         to derive the canonical subKey + verify subaccount existence.
    /// @dev Storing the raw address rather than the interface for lower gas + smaller
    ///      calldata; casts happen at call sites.
    address public immutable REGISTRY;

    /// @notice Architecture version enforced on every envelope digest built by this
    ///         contract's `_hashSignedActionEnvelopeDigest`. Frozen at deployment.
    /// @dev Reads `Versions.ARCHITECTURE_VERSION` at construction time and pins it as an
    ///      immutable — inheritors deploying against a superseded architecture
    ///      version would fail-closed on envelope validation.
    uint256 public immutable ARCHITECTURE_VERSION;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Per-signer per-engine next expected sequential nonce.
    ///      Sequential (D-C-08 FROZEN). Sequenced from `0` on first sighting.
    mapping(address => uint256) private _nextNonceOfSigner;

    /// @dev Per-engine consumed-intent-hash set. Once true, NEVER cleared.
    ///      Populated via `_consumeIntent`. Enforces INV-AUTH-06.
    mapping(bytes32 => bool) private _consumedIntent;

    /// @dev Per-subaccount monotonic recovery epoch. Zero means never advanced.
    ///      Enforces escape design P-1 (monotone `recoveryEpoch[subKey]`).
    mapping(bytes32 => uint256) private _subaccountRecoveryEpoch;

    /// @dev Owner-wide monotonic recovery epoch. Zero means never advanced.
    ///      Enforces escape design P-2 (monotone `ownerRecoveryEpoch[owner]`).
    mapping(address => uint256) private _ownerRecoveryEpoch;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor arg `registry_` is the zero address.
    error InvalidRegistry();

    /// @notice `_consumeIntent` called with `bytes32(0)`.
    error ZeroIntentHash();

    /// @notice Attempt to consume an already-consumed intent hash.
    error IntentReplayed(bytes32 intentHash);

    /// @notice Sequential nonce mismatch.
    error BadNonce(address signer, uint256 expected, uint256 provided);

    /// @notice `cancelNoncesUpTo` called with a target that would not advance the
    ///         signer's next nonce.
    error NonceCancelNoOp(address signer, uint256 currentNextNonce, uint256 provided);

    /// @notice Sequential nonce would overflow `uint256`.
    error NonceOverflow(address signer, uint256 currentNextNonce);

    /// @notice Signer was the zero address at a mutation call site.
    error SignerZero();

    /// @notice Deadline was strictly before `block.timestamp` at validation time.
    error DeadlineExpired(uint256 deadline, uint256 blockTimestamp);

    /// @notice Owner-wide recovery epoch in the envelope does not match current state.
    error StaleOwnerRecoveryEpoch(address owner, uint256 currentEpoch, uint256 providedEpoch);

    /// @notice Per-subaccount recovery epoch in the envelope does not match current state.
    error StaleSubaccountRecoveryEpoch(bytes32 subKey, uint256 currentEpoch, uint256 providedEpoch);

    /// @notice Owner-wide recovery epoch would overflow `uint256`.
    error OwnerRecoveryEpochOverflow(address owner);

    /// @notice Per-subaccount recovery epoch would overflow `uint256`.
    error SubaccountRecoveryEpochOverflow(bytes32 subKey);

    /// @notice Owner path called for a subaccount that has not been registered.
    error SubaccountNotFoundForOwner(address owner, uint32 subaccountId);

    /// @notice Envelope's `subKey` field does not match the computed value.
    error SubKeyMismatch(bytes32 expected, bytes32 provided);

    /// @notice Envelope's `engine` field is not `address(this)`.
    error InvalidEngineBinding(address expected, address provided);

    /// @notice Envelope's `architectureVersion` field is not the deployed value.
    error InvalidArchitectureVersion(uint256 expected, uint256 provided);

    /// @notice `subaccountId == 0` is reserved and invalid at every call site that
    ///         requires a real subaccount.
    error InvalidSubaccountId();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param registry_ Canonical SubaccountRegistry deployment. MUST NOT be zero.
    /// @param eip712Name_ Engine-specific EIP-712 domain name (spec 08 table). Bound into
    ///        the domain separator; inheritors set to e.g. `"DeOptV2-OptionMatchingEngine"`.
    /// @param eip712Version_ Engine-specific EIP-712 domain version. `"1"` in V1 per spec 08.
    constructor(address registry_, string memory eip712Name_, string memory eip712Version_)
        EIP712(eip712Name_, eip712Version_)
    {
        if (registry_ == address(0)) revert InvalidRegistry();
        REGISTRY = registry_;
        ARCHITECTURE_VERSION = Versions.ARCHITECTURE_VERSION;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW ACCESSORS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IReplayAndEpochController
    function registry() external view returns (address) {
        return REGISTRY;
    }

    /// @inheritdoc IReplayAndEpochController
    function architectureVersion() external view returns (uint256) {
        return ARCHITECTURE_VERSION;
    }

    /// @inheritdoc IReplayAndEpochController
    function subaccountRecoveryEpoch(bytes32 subKey) external view returns (uint256) {
        return _subaccountRecoveryEpoch[subKey];
    }

    /// @inheritdoc IReplayAndEpochController
    function ownerRecoveryEpoch(address owner) external view returns (uint256) {
        return _ownerRecoveryEpoch[owner];
    }

    /// @inheritdoc IReplayAndEpochController
    function currentEpochPair(address owner, uint32 subaccountId)
        external
        view
        returns (uint256 ownerEpoch, uint256 subaccountEpoch)
    {
        ownerEpoch = _ownerRecoveryEpoch[owner];
        bytes32 subKey = SubKey.deriveHere(REGISTRY, owner, subaccountId);
        subaccountEpoch = _subaccountRecoveryEpoch[subKey];
    }

    /*//////////////////////////////////////////////////////////////
                        IReplayProtected: sequential nonces
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IReplayProtected
    function nonces(address signer) external view returns (uint256) {
        return _nextNonceOfSigner[signer];
    }

    /// @inheritdoc IReplayProtected
    function isIntentConsumed(bytes32 intentHash) external view returns (bool) {
        return _consumedIntent[intentHash];
    }

    /// @inheritdoc IReplayProtected
    /// @dev Advances msg.sender's next nonce by one. Emits `NonceCancelled(msg.sender, prev, prev+1, msg.sender)`.
    function cancelNextNonce() external {
        address signer = msg.sender;
        if (signer == address(0)) revert SignerZero();
        uint256 current = _nextNonceOfSigner[signer];
        if (current == type(uint256).max) revert NonceOverflow(signer, current);

        unchecked {
            _nextNonceOfSigner[signer] = current + 1;
        }
        emit NonceCancelled(signer, current, current + 1, signer, Versions.EVENT_VERSION);
    }

    /// @inheritdoc IReplayProtected
    /// @dev Sets msg.sender's next nonce to `nextValid`. Reverts `NonceCancelNoOp` if
    ///      `nextValid <= current`. Sequential monotonicity preserved.
    function cancelNoncesUpTo(uint256 nextValid) external {
        address signer = msg.sender;
        if (signer == address(0)) revert SignerZero();
        uint256 current = _nextNonceOfSigner[signer];
        if (nextValid <= current) revert NonceCancelNoOp(signer, current, nextValid);
        _nextNonceOfSigner[signer] = nextValid;
        emit NonceCancelled(signer, current, nextValid, signer, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                       OWNER-PATH RECOVERY-EPOCH MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IReplayAndEpochController
    function advanceMyOwnerRecoveryEpoch() external {
        _advanceOwnerRecoveryEpoch(msg.sender, msg.sender);
    }

    /// @inheritdoc IReplayAndEpochController
    function advanceMySubaccountRecoveryEpoch(uint32 subaccountId) external {
        if (subaccountId == 0) revert InvalidSubaccountId();
        address owner = msg.sender;
        if (!ISubaccountRegistry(REGISTRY).existsOf(owner, subaccountId)) {
            revert SubaccountNotFoundForOwner(owner, subaccountId);
        }
        bytes32 subKey = SubKey.deriveHere(REGISTRY, owner, subaccountId);
        _advanceSubaccountRecoveryEpoch(subKey, owner, subaccountId, owner);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL PRIMITIVES
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal owner-epoch advance primitive. Callable by inheritors along authority
    ///      paths not defined in WP-05 (e.g. WP-10 EscapeController). Reverts on saturation.
    /// @param owner Canonical owner scope to advance.
    /// @param actor msg.sender of the outer call — emitted for reconstruction attribution.
    function _advanceOwnerRecoveryEpoch(address owner, address actor) internal {
        if (owner == address(0)) revert InvalidOwnerAddress();
        uint256 current = _ownerRecoveryEpoch[owner];
        if (current == type(uint256).max) revert OwnerRecoveryEpochOverflow(owner);
        unchecked {
            _ownerRecoveryEpoch[owner] = current + 1;
        }
        emit OwnerRecoveryEpochAdvanced(owner, current, current + 1, actor, Versions.EVENT_VERSION);
    }

    /// @dev Internal subaccount-epoch advance primitive.
    /// @param subKey Canonical internal key for the subaccount.
    /// @param owner Owner scope (informational — bound into event).
    /// @param subaccountId Subaccount id (informational).
    /// @param actor msg.sender of the outer call.
    function _advanceSubaccountRecoveryEpoch(bytes32 subKey, address owner, uint32 subaccountId, address actor)
        internal
    {
        if (subKey == bytes32(0)) revert InvalidSubKey();
        uint256 current = _subaccountRecoveryEpoch[subKey];
        if (current == type(uint256).max) revert SubaccountRecoveryEpochOverflow(subKey);
        unchecked {
            _subaccountRecoveryEpoch[subKey] = current + 1;
        }
        emit SubaccountRecoveryEpochAdvanced(
            subKey, owner, subaccountId, current, current + 1, actor, Versions.EVENT_VERSION
        );
    }

    /// @dev Consume an intent hash. Reverts on zero-hash or double-consume. Emits
    ///      `IntentConsumed(intentHash, signer, address(this), action, eventVersion)`.
    ///      Concrete engines invoke this after all preconditions succeed but BEFORE any
    ///      external call to another contract; the enclosing tx reverts atomically on
    ///      any downstream failure, so consumption cannot outlive a failed execution.
    function _consumeIntent(bytes32 intentHash, address signer, bytes32 action) internal {
        if (intentHash == bytes32(0)) revert ZeroIntentHash();
        if (_consumedIntent[intentHash]) revert IntentReplayed(intentHash);
        _consumedIntent[intentHash] = true;
        emit IntentConsumed(intentHash, signer, address(this), action, Versions.EVENT_VERSION);
    }

    /// @dev Consume a sequential nonce for `signer`. Requires `provided == expected`.
    ///      Enforces D-C-08 FROZEN semantics. Emits no event on its own — inheritors
    ///      typically emit the product event describing the executed action which pins
    ///      the (signer, nonce) pair separately.
    function _consumeNonce(address signer, uint256 provided) internal {
        if (signer == address(0)) revert SignerZero();
        uint256 expected = _nextNonceOfSigner[signer];
        if (expected != provided) revert BadNonce(signer, expected, provided);
        if (expected == type(uint256).max) revert NonceOverflow(signer, expected);
        unchecked {
            _nextNonceOfSigner[signer] = expected + 1;
        }
    }

    /// @dev Deadline validation. Zero is ALWAYS expired. No no-expiry sentinel.
    function _requireDeadlineNotExpired(uint256 deadline) internal view {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
    }

    /// @dev Validate that both epochs in the envelope match current storage. Reverts with
    ///      the epoch-scope-specific error (owner-wide checked first).
    function _requireEpochsFresh(
        address owner,
        bytes32 subKey,
        uint256 providedOwnerEpoch,
        uint256 providedSubaccountEpoch
    ) internal view {
        uint256 currentOwner = _ownerRecoveryEpoch[owner];
        if (currentOwner != providedOwnerEpoch) {
            revert StaleOwnerRecoveryEpoch(owner, currentOwner, providedOwnerEpoch);
        }
        uint256 currentSub = _subaccountRecoveryEpoch[subKey];
        if (currentSub != providedSubaccountEpoch) {
            revert StaleSubaccountRecoveryEpoch(subKey, currentSub, providedSubaccountEpoch);
        }
    }

    /// @dev Validate every static self-describing field of an envelope. Does NOT
    ///      consult signer authorization — engines add their own signer/ECDSA/ERC1271
    ///      checks. Does NOT consult recovery epochs — those are checked separately
    ///      via `_requireEpochsFresh` so tests can distinguish stale-epoch failures
    ///      from binding mismatches. Does NOT consume the intent — that is
    ///      `_consumeIntent`.
    /// @param envelope Envelope to validate.
    function _requireEnvelopeBindingValid(IntentHash.SignedActionEnvelope memory envelope) internal view {
        if (envelope.engine != address(this)) revert InvalidEngineBinding(address(this), envelope.engine);
        if (envelope.architectureVersion != ARCHITECTURE_VERSION) {
            revert InvalidArchitectureVersion(ARCHITECTURE_VERSION, envelope.architectureVersion);
        }
        if (envelope.subaccountId == 0) revert InvalidSubaccountId();
        if (envelope.owner == address(0)) revert InvalidOwnerAddress();
        bytes32 expectedSubKey = SubKey.deriveHere(REGISTRY, envelope.owner, envelope.subaccountId);
        if (envelope.subKey != expectedSubKey) revert SubKeyMismatch(expectedSubKey, envelope.subKey);
    }

    /// @dev Compute the EIP-712 typed-data digest for a signed envelope. Combines the
    ///      OZ `EIP712` domain separator (chainId + verifyingContract + name + version)
    ///      with the frozen envelope struct hash from `IntentHash.hashEnvelope`.
    /// @param envelope Envelope to digest.
    /// @return digest 32-byte EIP-712 typed-data hash suitable for `ECDSA.recover`.
    function _hashSignedActionEnvelopeDigest(IntentHash.SignedActionEnvelope memory envelope)
        internal
        view
        returns (bytes32 digest)
    {
        digest = _hashTypedDataV4(IntentHash.hashEnvelope(envelope));
    }

    /*//////////////////////////////////////////////////////////////
                              LOCAL ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Envelope-side owner was the zero address at a validation site.
    error InvalidOwnerAddress();

    /// @notice Envelope-side subKey was zero at a validation site.
    error InvalidSubKey();
}
