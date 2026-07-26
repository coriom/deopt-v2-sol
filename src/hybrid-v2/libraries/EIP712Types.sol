// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title EIP712Types
/// @notice Canonical EIP-712 type strings + type hashes shared by the DeOpt V2 hybrid replay
///         + epoch foundation (`ReplayAndEpochController`) and every downstream matching engine.
/// @dev
///  Every constant here is `internal constant` — no storage, no behavior. Type hashes are
///  precomputed at compile time and cross-checked in tests (`EIP712TypeHash.t.sol`) against
///  a runtime `keccak256(bytes(TYPE_STRING))`.
///
///  Domain model (spec 08, FROZEN):
///    EIP712Domain = { string name, string version, uint256 chainId, address verifyingContract }
///    -> use OpenZeppelin `EIP712` base; the constants below are for the ACTION types,
///       not the domain.
///
///  Envelope model (WP-05):
///    Every replay-protected action is a `SignedActionEnvelope`. The envelope binds every
///    field spec 08 + INV-AUTH-02 require:
///      - `owner`               canonical owner (spec 08 + INV-AUTH-01)
///      - `subaccountId`        target subaccount
///      - `subKey`              canonical internal key (redundant with owner + subaccountId +
///                              this chain + verifyingContract's registry, but binding
///                              it inside the struct pins the exact (chain, registry)
///                              context so signatures cannot be re-scoped by a future
///                              registry replacement even if the same engine is deployed
///                              on a chain with a differently-configured registry)
///      - `signer`              declared signer identity — MAY differ from owner when
///                              future delegation / smart-wallet controller model is
///                              introduced (spec 09). Verification is downstream.
///      - `engine`              executing engine — MUST equal `address(this)` at
///                              verification time; binding it inside the struct provides
///                              defense-in-depth against domain-decoding drift and makes
///                              the envelope self-describing.
///      - `action`              action namespace, e.g. `keccak256("SUBMIT_OPTION_ORDER")`
///                              (spec 08). Distinct actions cannot collide.
///      - `architectureVersion` bound in every signed payload per D-C-26 FROZEN.
///                              `deploymentVersion` is NOT bound here per D-STI-09 FROZEN
///                              (cross-deployment separation is provided by
///                              `verifyingContract` in the EIP-712 domain plus the
///                              deployment-scoped registry address encoded into `subKey`).
///      - `nonce`               per-signer per-engine sequential nonce (spec 08 D-C-08 FROZEN)
///      - `deadline`            Unix timestamp (spec 08). Zero is a valid syntactic value
///                              but is ALWAYS expired at execution time — WP-05 does not
///                              invent a no-expiry sentinel.
///      - `ownerRecoveryEpoch`  expected owner-wide recovery epoch (escape design P-2)
///      - `subaccountRecoveryEpoch` expected per-subaccount recovery epoch (escape design P-1)
///      - `payloadHash`         opaque `bytes32` for the action-specific payload.
///                              Product engines (WP-08 Options, future perps) compute this
///                              as `keccak256(abi.encode(<their action struct>))`.
library EIP712Types {
    /// @notice Canonical `SignedActionEnvelope` type string.
    string internal constant SIGNED_ACTION_ENVELOPE_TYPE = "SignedActionEnvelope(" "address owner,"
        "uint32 subaccountId," "bytes32 subKey," "address signer," "address engine," "bytes32 action,"
        "uint256 architectureVersion," "uint256 nonce," "uint256 deadline," "uint256 ownerRecoveryEpoch,"
        "uint256 subaccountRecoveryEpoch," "bytes32 payloadHash" ")";

    /// @notice Canonical `SignedActionEnvelope` type hash.
    /// @dev Precomputed at compile time. Cross-checked at test time against
    ///      `keccak256(bytes(SIGNED_ACTION_ENVELOPE_TYPE))`.
    bytes32 internal constant SIGNED_ACTION_ENVELOPE_TYPEHASH = keccak256(
        abi.encodePacked(
            "SignedActionEnvelope(",
            "address owner,",
            "uint32 subaccountId,",
            "bytes32 subKey,",
            "address signer,",
            "address engine,",
            "bytes32 action,",
            "uint256 architectureVersion,",
            "uint256 nonce,",
            "uint256 deadline,",
            "uint256 ownerRecoveryEpoch,",
            "uint256 subaccountRecoveryEpoch,",
            "bytes32 payloadHash",
            ")"
        )
    );
}
