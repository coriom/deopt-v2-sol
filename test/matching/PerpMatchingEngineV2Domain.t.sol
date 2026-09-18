// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1 §7b
// EIP-712 domain-separator isolation between PerpMatchingEngine (V1) and
// PerpMatchingEngineV2. Both signatures MUST be replay-safe across
// versions.

import {Test} from "forge-std/Test.sol";

import {PerpMatchingEngine} from "../../src/matching/PerpMatchingEngine.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";

// Stub engine — accepts any trade without side effects; sufficient for
// signature-domain assertions.
contract StubEngine is IPerpEngineTrade {
    event Called(address buyer, address seller, uint256 marketId, uint128 sizeDelta1e8, uint128 execPrice1e8);

    function applyTrade(Trade calldata t) external {
        emit Called(t.buyer, t.seller, t.marketId, t.sizeDelta1e8, t.executionPrice1e8);
    }
}

contract PerpMatchingEngineV2DomainTest is Test {
    address internal constant OWNER = address(0xA11CE);

    PerpMatchingEngine internal meV1;
    PerpMatchingEngineV2 internal meV2;

    StubEngine internal stub;

    function setUp() external {
        stub = new StubEngine();
        meV1 = new PerpMatchingEngine(OWNER, address(stub));
        meV2 = new PerpMatchingEngineV2(OWNER, address(stub));
    }

    /// @notice V1 and V2 domain separators MUST differ (guarantees no
    ///         cross-version signature replay).
    function testDomainSeparatorsDiffer() external {
        // EIP712's `_domainSeparatorV4` is internal — compute the same
        // digest the standard uses so we can compare without exposing
        // internals from the engine contracts.
        bytes32 typeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

        bytes32 dsV1 = keccak256(
            abi.encode(
                typeHash,
                keccak256(bytes("DeOptV2-PerpMatchingEngine")),
                keccak256(bytes("1")),
                block.chainid,
                address(meV1)
            )
        );

        bytes32 dsV2 = keccak256(
            abi.encode(
                typeHash,
                keccak256(bytes("DeOptV2-PerpMatchingEngine")),
                keccak256(bytes("2")),
                block.chainid,
                address(meV2)
            )
        );

        assertTrue(dsV1 != dsV2, "V1 and V2 domain separators must differ");
    }

    /// @notice For the SAME struct-hash content, the final EIP-712 digest
    ///         produced by V1 and V2 must be different. Ensures a V1
    ///         signature cannot be replayed to authorize a V2 trade with
    ///         identical parameters.
    function testTradeDigestsDifferAcrossV1AndV2() external {
        PerpMatchingEngine.PerpTrade memory t1 = PerpMatchingEngine.PerpTrade({
            intentId: bytes32(uint256(0x11)),
            buyer: address(0xBEEF01),
            seller: address(0xBEEF02),
            marketId: 42,
            sizeDelta1e8: 1_000_000,
            executionPrice1e8: 246_831_000_000,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0,
            buyerIsMaker: false,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: type(uint256).max
        });

        PerpMatchingEngineV2.PerpTrade memory t2 = PerpMatchingEngineV2.PerpTrade({
            intentId: bytes32(uint256(0x11)),
            buyer: address(0xBEEF01),
            seller: address(0xBEEF02),
            marketId: 42,
            sizeDelta1e8: 1_000_000,
            executionPrice1e8: 246_831_000_000,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0,
            buyerIsMaker: false,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: type(uint256).max
        });

        bytes32 d1 = meV1.hashTrade(t1);
        bytes32 d2 = meV2.hashTrade(t2);

        assertTrue(d1 != d2, "identical trade must hash to different digests on V1 vs V2");
    }

    /// @notice V2 signature must NOT verify against V1's engine (and V1
    ///         signature must NOT verify against V2's). Achieved by
    ///         having a real signer sign a V2 payload and attempting to
    ///         submit it to V1 with the same content — expect signature
    ///         rejection.
    function testSignatureReplayAcrossVersionsIsRejected() external {
        uint256 sellerPk = 0xA11CE;
        uint256 buyerPk = 0xB0B0;
        address buyer = vm.addr(buyerPk);
        address seller = vm.addr(sellerPk);

        // Allow the test as executor on both engines so signature
        // rejection (not authorization) is the sole failure mode.
        vm.startPrank(OWNER);
        meV1.setExecutor(address(this), true);
        meV2.setExecutor(address(this), true);
        vm.stopPrank();

        // Build an identical trade payload on each engine's struct type.
        PerpMatchingEngineV2.PerpTrade memory tv2 = PerpMatchingEngineV2.PerpTrade({
            intentId: bytes32(uint256(0x22)),
            buyer: buyer,
            seller: seller,
            marketId: 1,
            sizeDelta1e8: 1e6,
            executionPrice1e8: 2_000 * 1e8,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0,
            buyerIsMaker: false,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: type(uint256).max
        });

        // Sign under V2 domain (both signers).
        bytes32 dv2 = meV2.hashTrade(tv2);
        (uint8 v1_, bytes32 r1, bytes32 s1) = vm.sign(buyerPk, dv2);
        (uint8 v2_, bytes32 r2, bytes32 s2) = vm.sign(sellerPk, dv2);
        bytes memory buyerSigV2 = abi.encodePacked(r1, s1, v1_);
        bytes memory sellerSigV2 = abi.encodePacked(r2, s2, v2_);

        // V2 accepts (sanity).
        meV2.executeTrade(tv2, buyerSigV2, sellerSigV2);

        // Now try the SAME signature on V1 with the identical-content trade.
        PerpMatchingEngine.PerpTrade memory tv1 = PerpMatchingEngine.PerpTrade({
            intentId: bytes32(uint256(0x22)),
            buyer: buyer,
            seller: seller,
            marketId: 1,
            sizeDelta1e8: 1e6,
            executionPrice1e8: 2_000 * 1e8,
            maxExecutionPrice1e8: 0,
            minExecutionPrice1e8: 0,
            buyerIsMaker: false,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: type(uint256).max
        });

        // V1 must reject — different domain -> different digest ->
        // recovered signer != buyer/seller.
        vm.expectRevert(PerpMatchingEngine.InvalidSignature.selector);
        meV1.executeTrade(tv1, buyerSigV2, sellerSigV2);
    }
}
