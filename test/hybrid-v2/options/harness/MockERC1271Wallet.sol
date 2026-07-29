// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title MockERC1271Wallet
/// @notice Test-only ERC-1271 smart wallet whose owner is a designated ECDSA
///         signer address. Validates typed-data signatures via ecrecover.
///         NOT production source.
contract MockERC1271Wallet {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e; // isValidSignature(bytes32,bytes)

    address public immutable OWNER_SIGNER;
    bool public rejectAll;

    constructor(address ownerSigner_) {
        OWNER_SIGNER = ownerSigner_;
    }

    function setRejectAll(bool r) external {
        rejectAll = r;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (rejectAll) return 0xffffffff;
        // Split signature (r, s, v).
        if (signature.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        // Solidity assembly to parse.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := calldataload(add(signature.offset, 0))
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) return 0xffffffff;
        if (recovered != OWNER_SIGNER) return 0xffffffff;
        return MAGIC_VALUE;
    }
}
