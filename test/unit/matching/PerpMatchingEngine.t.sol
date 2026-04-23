// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IPerpEngineTrade} from "../../../src/matching/IPerpEngineTrade.sol";
import {PerpMatchingEngine} from "../../../src/matching/PerpMatchingEngine.sol";

contract MockPerpEngineTrade is IPerpEngineTrade {
    Trade internal _lastTrade;
    uint256 internal _applyCount;

    function applyTrade(Trade calldata t) external {
        _lastTrade = t;
        _applyCount++;
    }

    function applyCount() external view returns (uint256) {
        return _applyCount;
    }

    function lastTrade() external view returns (Trade memory t) {
        return _lastTrade;
    }
}

contract PerpMatchingEngineTest is Test {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;

    address internal OWNER;
    address internal BUYER;
    address internal SELLER;
    address internal constant GUARDIAN = address(0x1234);

    MockPerpEngineTrade internal perpEngine;
    PerpMatchingEngine internal matchingEngine;

    function setUp() external {
        OWNER = vm.addr(OWNER_PK);
        BUYER = vm.addr(BUYER_PK);
        SELLER = vm.addr(SELLER_PK);

        perpEngine = new MockPerpEngineTrade();
        matchingEngine = new PerpMatchingEngine(OWNER, address(perpEngine));
    }

    function testGuardianCanPauseIngressAndOwnerCanUnpause() external {
        vm.prank(OWNER);
        matchingEngine.setGuardian(GUARDIAN);

        vm.prank(GUARDIAN);
        matchingEngine.pause();

        assertTrue(matchingEngine.paused());
        assertEq(matchingEngine.guardian(), GUARDIAN);

        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade();

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.PausedError.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 0);

        vm.prank(OWNER);
        matchingEngine.unpause();

        assertFalse(matchingEngine.paused());

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(perpEngine.applyCount(), 1);
    }

    function testExecuteTradePreservesExistingSemanticsWhenNotPaused() external {
        (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade();

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        IPerpEngineTrade.Trade memory forwarded = perpEngine.lastTrade();
        assertEq(forwarded.buyer, BUYER);
        assertEq(forwarded.seller, SELLER);
        assertEq(forwarded.marketId, 7);
        assertEq(forwarded.sizeDelta1e8, 2e8);
        assertEq(forwarded.executionPrice1e8, 2_000e8);
        assertTrue(forwarded.buyerIsMaker);
        assertEq(perpEngine.applyCount(), 1);
        assertEq(matchingEngine.nonces(BUYER), 1);
        assertEq(matchingEngine.nonces(SELLER), 1);
    }

    function _signedTrade()
        internal
        returns (PerpMatchingEngine.PerpTrade memory t, bytes memory buyerSig, bytes memory sellerSig)
    {
        t = PerpMatchingEngine.PerpTrade({
            buyer: BUYER,
            seller: SELLER,
            marketId: 7,
            sizeDelta1e8: 2e8,
            executionPrice1e8: 2_000e8,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });

        bytes32 digest = matchingEngine.hashTrade(t);
        buyerSig = _sign(BUYER_PK, digest);
        sellerSig = _sign(SELLER_PK, digest);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
