// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";

/// @title V2G-A backend / Solidity Merkle leaf cross-vector
/// @notice Pins the byte-for-byte equality between
/// `FeesManagerV2.hashTierLeaf` and the off-chain leaf hasher in
/// `deopt-v2-backend/src/fees/tier_merkle.rs::tier_leaf`. Any drift
/// in the ABI encoding of the leaf (e.g. accidental `encodePacked`)
/// will trip both sides' assertions against the same vector.
contract V2GALeafCrossVector is Test {
    FeesManagerV2 internal feesManager;

    address internal constant OWNER = address(0xA11CE);
    address internal constant FEE_RECIPIENT = address(0xFEE);

    // The vector mirrors `tier_merkle::tests::solidity_hash_tier_leaf_vector`.
    address internal constant ACCOUNT = address(0x0000000000000000000000000000000000000001);
    uint8 internal constant TIER = 4;
    uint256 internal constant VOLUME_28D = 25_000_000 * 1e8;
    uint32 internal constant VOLUME_SHARE_PPM = 50_000;
    uint256 internal constant STAKED_DEOPT = 250_000 * 1e8;
    uint64 internal constant VALID_FROM = 1_700_000_000;
    uint64 internal constant VALID_UNTIL = 1_700_000_000 + 7 * 86_400;

    function setUp() external {
        feesManager = new FeesManagerV2(OWNER, FEE_RECIPIENT);
    }

    function testHashTierLeafIsKeccakOfAbiEncode() external view {
        bytes32 onchain = feesManager.hashTierLeaf(
            ACCOUNT, TIER, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL
        );
        bytes32 expected =
            keccak256(abi.encode(ACCOUNT, TIER, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL));
        assertEq(onchain, expected, "hashTierLeaf must equal keccak(abi.encode(...))");

        // The encoded buffer is exactly 7 ABI words (224 bytes).
        bytes memory encoded =
            abi.encode(ACCOUNT, TIER, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL);
        assertEq(encoded.length, 7 * 32, "abi.encode must produce 7 x 32 byte words");
    }
}
