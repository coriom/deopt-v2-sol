// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title SubKey
/// @notice Single canonical derivation of the DeOpt V2 internal subaccount key.
/// @dev
///  Formula (frozen by contract-spec 02 + spec 15):
///
///      subKey = keccak256(abi.encode(chainId, registryAddress, owner, subaccountId))
///
///  Properties:
///   - `abi.encode` (never `abi.encodePacked`) prevents field-concatenation collisions.
///   - Field order is fixed: chainId, registry, owner, subaccountId.
///   - `subKey` is deployment-scoped: a new registry address creates a new subKey namespace.
///   - Different chain ids produce different keys.
///   - Different owners produce different keys.
///   - Different subaccountIds produce different keys.
///   - Domain-separation for signatures does NOT live in this hash; EIP-712 domain
///     (per contract-spec 08) carries architectureVersion + verifyingContract.
///
///  This library is the ONLY canonical implementation of the derivation. Any
///  downstream module reproducing the formula independently is forbidden by
///  Principle 5 (naming register) + this milestone's shared-types contract.
library SubKey {
    /// @notice Derive a subKey using the current chain id.
    /// @param registry The SubaccountRegistry deployment address that scopes the key namespace.
    /// @param owner The canonical owner (EOA or smart-wallet contract per INV-ID-06).
    /// @param subaccountId The monotonic per-owner subaccount id.
    /// @return subKey The 32-byte canonical internal key.
    /// @dev Consumes `block.chainid`. Use `derive` for deterministic cross-chain reproduction.
    function deriveHere(address registry, address owner, uint32 subaccountId) internal view returns (bytes32 subKey) {
        subKey = keccak256(abi.encode(block.chainid, registry, owner, subaccountId));
    }

    /// @notice Derive a subKey using an explicit chain id.
    /// @param chainId The chain id to bind into the derivation.
    /// @param registry The SubaccountRegistry deployment address.
    /// @param owner The canonical owner.
    /// @param subaccountId The monotonic per-owner subaccount id.
    /// @return subKey The 32-byte canonical internal key.
    /// @dev Pure form for tests, off-chain reproduction, and cross-chain reconstruction.
    ///      Callers on-chain SHOULD prefer `deriveHere` unless they must derive for a
    ///      different chain.
    function derive(uint256 chainId, address registry, address owner, uint32 subaccountId)
        internal
        pure
        returns (bytes32 subKey)
    {
        subKey = keccak256(abi.encode(chainId, registry, owner, subaccountId));
    }
}
