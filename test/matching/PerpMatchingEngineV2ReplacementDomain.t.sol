// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";

contract ReplacementTradeSink is IPerpEngineTrade {
    uint256 public applied;

    function applyTrade(Trade calldata) external {
        applied++;
    }
}

/// @notice Two V2 deployments: same typehash/version, different verifying contract.
contract PerpMatchingEngineV2ReplacementDomainTest is Test {
    uint256 internal constant BUYER_KEY = 0xB0B0;
    uint256 internal constant SELLER_KEY = 0xA11CE;
    address internal constant TIMELOCK = address(0x71);
    address internal constant EXECUTOR = address(0xE1);

    PerpMatchingEngineV2 internal historical;
    PerpMatchingEngineV2 internal replacement;
    ReplacementTradeSink internal sink;

    function setUp() public {
        vm.chainId(84532);
        sink = new ReplacementTradeSink();
        historical = new PerpMatchingEngineV2(TIMELOCK, address(sink));
        replacement = new PerpMatchingEngineV2(TIMELOCK, address(sink));
        vm.startPrank(TIMELOCK);
        historical.setExecutor(EXECUTOR, true);
        replacement.setExecutor(EXECUTOR, true);
        vm.stopPrank();
    }

    function _trade() internal view returns (PerpMatchingEngineV2.PerpTrade memory t) {
        t = PerpMatchingEngineV2.PerpTrade({
            intentId: keccak256("synthetic replacement trade"),
            buyer: vm.addr(BUYER_KEY),
            seller: vm.addr(SELLER_KEY),
            marketId: 1,
            sizeDelta1e8: 1_000_000,
            executionPrice1e8: 246_831_000_000,
            maxExecutionPrice1e8: 246_831_000_000,
            minExecutionPrice1e8: 246_831_000_000,
            buyerIsMaker: false,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 900
        });
    }

    function _signWithVm(bytes32 hash) internal pure returns (bytes memory buyerSig, bytes memory sellerSig) {
        // Test-only synthetic signing; these scalars are unrelated to real traders.
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_KEY, hash);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_KEY, hash);
        return (abi.encodePacked(br, bs, bv), abi.encodePacked(sr, ss, sv));
    }

    function testHistoricalV2SignatureCannotExecuteOnReplacement() public {
        PerpMatchingEngineV2.PerpTrade memory t = _trade();
        assertTrue(historical.domainSeparatorV4() != replacement.domainSeparatorV4());
        (bytes memory b, bytes memory s) = _signWithVm(historical.hashTrade(t));
        vm.prank(EXECUTOR);
        vm.expectRevert(PerpMatchingEngineV2.InvalidSignature.selector);
        replacement.executeTrade(t, b, s);
        assertEq(sink.applied(), 0);
    }

    function testFreshReplacementSignaturesExecuteOnceAndNonceReplayFails() public {
        PerpMatchingEngineV2.PerpTrade memory t = _trade();
        (bytes memory b, bytes memory s) = _signWithVm(replacement.hashTrade(t));
        vm.prank(EXECUTOR);
        replacement.executeTrade(t, b, s);
        assertEq(sink.applied(), 1);
        assertEq(replacement.nonces(t.buyer), 1);
        assertEq(replacement.nonces(t.seller), 1);
        vm.prank(EXECUTOR);
        vm.expectRevert(PerpMatchingEngineV2.BadNonce.selector);
        replacement.executeTrade(t, b, s);
    }

    function testWrongChainSignatureFails() public {
        PerpMatchingEngineV2.PerpTrade memory t = _trade();
        vm.chainId(84533);
        (bytes memory b, bytes memory s) = _signWithVm(replacement.hashTrade(t));
        vm.chainId(84532);
        vm.prank(EXECUTOR);
        vm.expectRevert(PerpMatchingEngineV2.InvalidSignature.selector);
        replacement.executeTrade(t, b, s);
    }

    function testReplacementIntentPartialFillAndNonceSeparation() public {
        PerpMatchingEngineV2.PerpOrderIntent memory buy = PerpMatchingEngineV2.PerpOrderIntent({
            intentId: keccak256("replacement-buyer-intent"),
            trader: vm.addr(BUYER_KEY),
            subaccountId: 1,
            marketId: 1,
            side: 0,
            size1e8: 6e8,
            limitPrice1e8: 0,
            maxExecPrice1e8: 2500e8,
            minExecPrice1e8: 0,
            nonce: 7,
            deadline: block.timestamp + 900
        });
        PerpMatchingEngineV2.PerpOrderIntent memory sell = PerpMatchingEngineV2.PerpOrderIntent({
            intentId: keccak256("replacement-seller-intent"),
            trader: vm.addr(SELLER_KEY),
            subaccountId: 2,
            marketId: 1,
            side: 1,
            size1e8: 6e8,
            limitPrice1e8: 0,
            maxExecPrice1e8: 0,
            minExecPrice1e8: 2400e8,
            nonce: 9,
            deadline: block.timestamp + 900
        });
        bytes32 buyerHash = replacement.hashOrderIntent(buy);
        bytes32 sellerHash = replacement.hashOrderIntent(sell);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_KEY, buyerHash);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_KEY, sellerHash);
        bytes memory buyerSig = abi.encodePacked(br, bs, bv);
        bytes memory sellerSig = abi.encodePacked(sr, ss, sv);
        PerpMatchingEngineV2.TradeFromIntents memory fill = PerpMatchingEngineV2.TradeFromIntents({
            marketId: 1,
            buyerSubaccountId: 1,
            sellerSubaccountId: 2,
            size1e8: 3e8,
            executionPrice1e8: 2468e8,
            buyerIsMaker: true,
            buyerIntentId: buy.intentId,
            sellerIntentId: sell.intentId
        });
        vm.prank(EXECUTOR);
        replacement.executeTradeFromIntents(buy, buyerSig, sell, sellerSig, fill);
        assertEq(replacement.intentFilled(buyerHash), 3e8);
        assertEq(replacement.intentFilled(sellerHash), 3e8);
        assertTrue(replacement.intentNonceUsed(buy.trader, buy.nonce));
        assertTrue(replacement.intentNonceUsed(sell.trader, sell.nonce));
        assertEq(replacement.nonces(buy.trader), 0); // bilateral nonce is separate
        fill.size1e8 = 3e8;
        vm.prank(EXECUTOR);
        replacement.executeTradeFromIntents(buy, buyerSig, sell, sellerSig, fill);
        assertEq(replacement.intentFilled(buyerHash), 6e8);
        vm.prank(EXECUTOR);
        vm.expectRevert(PerpMatchingEngineV2.IntentSizeExceedsRemaining.selector);
        replacement.executeTradeFromIntents(buy, buyerSig, sell, sellerSig, fill);
        assertEq(sink.applied(), 2);
    }
}
