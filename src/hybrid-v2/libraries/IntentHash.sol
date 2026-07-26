// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {EIP712Types} from "./EIP712Types.sol";

/// @title IntentHash
/// @notice Canonical hashing primitives for the DeOpt V2 `SignedActionEnvelope`.
/// @dev
///  Pure functions. No storage. No behavior.
///
///  `SignedActionEnvelope` fields — see `EIP712Types.SIGNED_ACTION_ENVELOPE_TYPE`.
///  Field ordering is FROZEN and MUST match the canonical type string exactly.
library IntentHash {
    /// @notice The canonical envelope struct that every replay-protected DeOpt V2 action
    ///         serializes into before hashing.
    /// @dev All fields are bound into the struct hash via `abi.encode` (never packed).
    struct SignedActionEnvelope {
        address owner;
        uint32 subaccountId;
        bytes32 subKey;
        address signer;
        address engine;
        bytes32 action;
        uint256 architectureVersion;
        uint256 nonce;
        uint256 deadline;
        uint256 ownerRecoveryEpoch;
        uint256 subaccountRecoveryEpoch;
        bytes32 payloadHash;
    }

    /// @notice Compute the EIP-712 struct hash for a `SignedActionEnvelope`.
    /// @dev Uses `abi.encode` on the type hash + all fields. NEVER `abi.encodePacked`:
    ///      concatenation would collide across `(subKey, action, payloadHash)` bytes32 boundaries.
    /// @param envelope The envelope to hash.
    /// @return structHash The 32-byte struct hash (input to `_hashTypedDataV4`).
    function hashEnvelope(SignedActionEnvelope memory envelope) internal pure returns (bytes32 structHash) {
        structHash = keccak256(
            abi.encode(
                EIP712Types.SIGNED_ACTION_ENVELOPE_TYPEHASH,
                envelope.owner,
                envelope.subaccountId,
                envelope.subKey,
                envelope.signer,
                envelope.engine,
                envelope.action,
                envelope.architectureVersion,
                envelope.nonce,
                envelope.deadline,
                envelope.ownerRecoveryEpoch,
                envelope.subaccountRecoveryEpoch,
                envelope.payloadHash
            )
        );
    }
}
