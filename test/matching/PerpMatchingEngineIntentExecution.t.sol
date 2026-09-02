// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpMatchingEngine} from "../../src/matching/PerpMatchingEngine.sol";

/// @title _AcceptingPerpEngine
/// @notice Trivial mock — accepts every trade and records the last apply.
///         Used for happy-path and validation-layer tests where downstream
///         engine behaviour is out of scope.
contract _AcceptingPerpEngine is IPerpEngineTrade {
    Trade internal _lastTrade;
    uint256 internal _applyCount;
    uint128 internal _totalSize;

    function applyTrade(Trade calldata t) external {
        _lastTrade = t;
        _applyCount++;
        _totalSize += t.sizeDelta1e8;
    }

    function applyCount() external view returns (uint256) {
        return _applyCount;
    }

    function totalSize() external view returns (uint128) {
        return _totalSize;
    }

    function lastTrade() external view returns (Trade memory) {
        return _lastTrade;
    }
}

/// @title _OutOfBandPerpEngine
/// @notice Reverts with the real protocol Part A guard error. Proves the
///         matching engine's intent path does NOT swallow the downstream
///         execution-price-band revert (i.e. Part A guard is preserved).
contract _OutOfBandPerpEngine is IPerpEngineTrade {
    /// @dev Mirrors {PerpEngineTypes.ExecutionPriceOutOfBand} so the intent
    ///      execution test can `vm.expectRevert(...)` on the exact selector
    ///      without importing perp-engine internals.
    error ExecutionPriceOutOfBand();

    function applyTrade(Trade calldata) external pure {
        revert ExecutionPriceOutOfBand();
    }
}

/// @title PerpMatchingEngineIntentExecutionTest
/// @notice Unit + fuzz coverage for the ADDITIVE Part D intent execution
///         path (`executeTradeFromIntents`) — PERPS-FULLSTACK-RUNTIME-
///         INTEGRATION-V1.
contract PerpMatchingEngineIntentExecutionTest is Test {
    // Signer keys.
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;
    uint256 internal constant ATTACKER_PK = 0xBAD;

    // Trade & intent shape defaults.
    uint256 internal constant MARKET_ID = 42;
    uint32 internal constant BUYER_SUB = 1;
    uint32 internal constant SELLER_SUB = 2;
    uint128 internal constant INTENT_SIZE = 5e8;
    uint128 internal constant TRADE_PRICE = 2_000e8;
    uint128 internal constant BUYER_MAX = 2_050e8;
    uint128 internal constant SELLER_MIN = 1_950e8;

    address internal OWNER;
    address internal BUYER;
    address internal SELLER;

    _AcceptingPerpEngine internal perpEngine;
    PerpMatchingEngine internal matchingEngine;

    function setUp() external {
        OWNER = vm.addr(OWNER_PK);
        BUYER = vm.addr(BUYER_PK);
        SELLER = vm.addr(SELLER_PK);

        perpEngine = new _AcceptingPerpEngine();
        matchingEngine = new PerpMatchingEngine(OWNER, address(perpEngine));
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function testHappyPathIntentExecutionSucceedsAndEmits() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        bytes32 expectedBuyerHash = matchingEngine.hashOrderIntent(buy);
        bytes32 expectedSellerHash = matchingEngine.hashOrderIntent(sell);

        vm.expectEmit(true, true, false, true, address(matchingEngine));
        emit PerpMatchingEngine.TradeExecutedFromIntents(
            expectedBuyerHash, expectedSellerHash, MARKET_ID, INTENT_SIZE, TRADE_PRICE, block.timestamp
        );

        vm.prank(OWNER);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);

        assertEq(perpEngine.applyCount(), 1);
        assertEq(perpEngine.lastTrade().buyer, BUYER);
        assertEq(perpEngine.lastTrade().seller, SELLER);
        assertEq(perpEngine.lastTrade().marketId, MARKET_ID);
        assertEq(perpEngine.lastTrade().sizeDelta1e8, INTENT_SIZE);
        assertEq(perpEngine.lastTrade().executionPrice1e8, TRADE_PRICE);
        assertEq(matchingEngine.intentFilled(expectedBuyerHash), INTENT_SIZE);
        assertEq(matchingEngine.intentFilled(expectedSellerHash), INTENT_SIZE);
        assertTrue(matchingEngine.intentNonceUsed(BUYER, buy.nonce));
        assertTrue(matchingEngine.intentNonceUsed(SELLER, sell.nonce));
    }

    /*//////////////////////////////////////////////////////////////
                          SIGNATURE FAILURES
    //////////////////////////////////////////////////////////////*/

    function testBuyerSignatureInvalidReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        // Sign the buyer intent with the attacker key.
        bytes memory buySig = _sign(ATTACKER_PK, matchingEngine.hashOrderIntent(buy));
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSignatureInvalid.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testSellerSignatureInvalidReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _sign(ATTACKER_PK, matchingEngine.hashOrderIntent(sell));
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSignatureInvalid.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                          SIDE / MARKET / SUB
    //////////////////////////////////////////////////////////////*/

    function testBuyerSideNonZeroReverts() external {
        // Craft a "buyer intent" that mistakenly declares side=1.
        PerpMatchingEngine.PerpOrderIntent memory buy = PerpMatchingEngine.PerpOrderIntent({
            intentId: keccak256("bad-side-buy"),
            trader: BUYER,
            subaccountId: BUYER_SUB,
            marketId: MARKET_ID,
            side: 1, // WRONG
            size1e8: INTENT_SIZE,
            limitPrice1e8: 0,
            maxExecPrice1e8: BUYER_MAX,
            minExecPrice1e8: 0,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSideMismatch.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testSellerSideNonOneReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = PerpMatchingEngine.PerpOrderIntent({
            intentId: keccak256("bad-side-sell"),
            trader: SELLER,
            subaccountId: SELLER_SUB,
            marketId: MARKET_ID,
            side: 0, // WRONG
            size1e8: INTENT_SIZE,
            limitPrice1e8: 0,
            maxExecPrice1e8: 0,
            minExecPrice1e8: SELLER_MIN,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSideMismatch.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testMarketIdMismatchReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        // Seller intent on a DIFFERENT market.
        PerpMatchingEngine.PerpOrderIntent memory sell = PerpMatchingEngine.PerpOrderIntent({
            intentId: keccak256("wrong-market-sell"),
            trader: SELLER,
            subaccountId: SELLER_SUB,
            marketId: MARKET_ID + 1,
            side: 1,
            size1e8: INTENT_SIZE,
            limitPrice1e8: 0,
            maxExecPrice1e8: 0,
            minExecPrice1e8: SELLER_MIN,
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentMarketMismatch.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testSubaccountMismatchReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);

        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);
        // Mutate the trade's buyer subaccount id.
        tr.buyerSubaccountId = BUYER_SUB + 99;

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSubaccountMismatch.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                           SIZE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function testTradeSizeExceedsBuyerRemainingReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, 3e8, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        // Request more than the buyer's total.
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(4e8, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSizeExceedsRemaining.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testTradeSizeExceedsSellerRemainingReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, 2e8, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(3e8, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSizeExceedsRemaining.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE BOUNDS
    //////////////////////////////////////////////////////////////*/

    function testExecPriceAboveBuyerMaxReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, 2_000e8);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, 1_500e8);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, 2_100e8, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentExecPriceAboveBuyerMax.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testExecPriceBelowSellerMinReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, 3_000e8);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, 2_000e8);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, 1_900e8, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentExecPriceBelowSellerMin.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testBuyerLimitPriceViolatedReverts() external {
        // Buyer signs limit=1_950; matcher tries exec=2_000 which is within
        // the buyer max (2_050) but violates the LIMIT.
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 1_950e8, 2_050e8);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, 1_500e8);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, 2_000e8, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentLimitPriceViolated.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    function testSellerLimitPriceViolatedReverts() external {
        // Seller signs limit=2_050; matcher tries exec=2_000 which is above
        // the seller min (1_950) but violates the LIMIT (below 2_050).
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, 3_000e8);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 2_050e8, 1_950e8);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, 2_000e8, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentLimitPriceViolated.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                              DEADLINE
    //////////////////////////////////////////////////////////////*/

    function testDeadlinePassedReverts() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        // Warp forward past both deadlines.
        vm.warp(buy.deadline + 1);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentDeadlineExpired.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                            NONCE REPLAY
    //////////////////////////////////////////////////////////////*/

    function testNonceReplayFullyFilledIntentReverts() external {
        // First fill: exhaust the intent.
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);

        // Second attempt to submit a DIFFERENT intent re-using the same
        // (BUYER, nonce=1): should revert with IntentNonceAlreadyUsed.
        PerpMatchingEngine.PerpOrderIntent memory buy2 = PerpMatchingEngine.PerpOrderIntent({
            intentId: keccak256("replay-attempt"),
            trader: BUYER,
            subaccountId: BUYER_SUB,
            marketId: MARKET_ID,
            side: 0,
            size1e8: INTENT_SIZE,
            limitPrice1e8: 0,
            maxExecPrice1e8: BUYER_MAX,
            minExecPrice1e8: 0,
            nonce: 1, // SAME as buy.nonce
            deadline: block.timestamp + 1 hours
        });
        // Different seller intent so we don't trip seller-side nonce reuse first.
        PerpMatchingEngine.PerpOrderIntent memory sell2 = _sellIntent(2, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buy2Sig = _signBuyer(buy2);
        bytes memory sell2Sig = _signSeller(sell2);
        PerpMatchingEngine.TradeFromIntents memory tr2 = _trade(INTENT_SIZE, TRADE_PRICE, buy2, sell2);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentNonceAlreadyUsed.selector);
        matchingEngine.executeTradeFromIntents(buy2, buy2Sig, sell2, sell2Sig, tr2);
    }

    /*//////////////////////////////////////////////////////////////
                         PARTIAL FILL SEQUENCE
    //////////////////////////////////////////////////////////////*/

    function testPartialFillAccountingSequence() external {
        // Buyer & seller each sign a size-5 intent. Sequence:
        //   fill 3 → OK
        //   fill 2 → OK   (cumulative = 5)
        //   fill 1 → OK   (need fresh seller intent — we exhausted the
        //                  first seller; use a NEW seller intent, but
        //                  the BUYER's remaining is now 0, so this must
        //                  ACTUALLY REVERT)
        // Adjusted per spec item #16 wording: the SAME intent supplies both
        // sides; the sequence is:
        //   fill 3 → OK
        //   fill 2 → OK (cumulative buyer/seller = 5)
        //   fill 1 → revert IntentSizeExceedsRemaining
        // The "third for 1 succeeds; fourth for 1 reverts" phrasing in the
        // spec assumes size-6 intent (3+2+1=6, 4th=1 reverts). Interpret
        // the size as 6 to satisfy the "third succeeds" clause verbatim.
        uint128 intentSize = 6e8;
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, intentSize, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, intentSize, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);

        bytes32 buyerHash = matchingEngine.hashOrderIntent(buy);
        bytes32 sellerHash = matchingEngine.hashOrderIntent(sell);

        // Fill 1: 3
        PerpMatchingEngine.TradeFromIntents memory tr1 = _trade(3e8, TRADE_PRICE, buy, sell);
        vm.prank(OWNER);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr1);
        assertEq(matchingEngine.intentFilled(buyerHash), 3e8);
        assertEq(matchingEngine.intentFilled(sellerHash), 3e8);

        // Fill 2: 2 (cum = 5)
        PerpMatchingEngine.TradeFromIntents memory tr2 = _trade(2e8, TRADE_PRICE, buy, sell);
        vm.prank(OWNER);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr2);
        assertEq(matchingEngine.intentFilled(buyerHash), 5e8);

        // Fill 3: 1 (cum = 6, exact intent size)
        PerpMatchingEngine.TradeFromIntents memory tr3 = _trade(1e8, TRADE_PRICE, buy, sell);
        vm.prank(OWNER);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr3);
        assertEq(matchingEngine.intentFilled(buyerHash), 6e8);

        // Fill 4: 1 — MUST revert (intent exhausted).
        PerpMatchingEngine.TradeFromIntents memory tr4 = _trade(1e8, TRADE_PRICE, buy, sell);
        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSizeExceedsRemaining.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr4);

        // Apply count should reflect exactly three successful fills.
        assertEq(perpEngine.applyCount(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                    PROTOCOL PART A GUARD PRESERVED
    //////////////////////////////////////////////////////////////*/

    function testProtocolExecutionPriceGuardStillFires() external {
        // Swap in the OutOfBand-reverting engine.
        _OutOfBandPerpEngine badEngine = new _OutOfBandPerpEngine();
        vm.prank(OWNER);
        matchingEngine.setEngine(address(badEngine));

        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(_OutOfBandPerpEngine.ExecutionPriceOutOfBand.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                       TAMPERED FIELD → BAD SIG
    //////////////////////////////////////////////////////////////*/

    function testTamperedSignedFieldSurfacesAsInvalidSignature() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);

        // Now tamper the buyer intent's max price WITHOUT resigning.
        buy.maxExecPrice1e8 = BUYER_MAX + 1;
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);

        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSignatureInvalid.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /// @notice Signed under a DIFFERENT chain id → recovered signer
    /// address diverges from the declared trader → `IntentSignatureInvalid`.
    /// Pins the invariant that a signature captured on one deployment
    /// (chain X) cannot be replayed against another (chain Y). The
    /// domain separator embeds `block.chainid`, so signing against a
    /// crafted alt-chain domain then submitting on the current chain
    /// forces the recover to point at an unrelated address.
    function testCrossChainSignatureReplayIsRejected() external {
        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        // Legitimate seller sig on the CURRENT chain domain.
        bytes memory sellSig = _signSeller(sell);

        // Craft an alt-chain domain separator (chainid + 1) and sign
        // the same buy intent against it. The recovered signer on the
        // current-chain digest will be a random address, not BUYER.
        bytes32 altDomainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("DeOptV2-PerpMatchingEngine")),
                keccak256(bytes("1")),
                block.chainid + 1, // wrong chain
                address(matchingEngine)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                matchingEngine.ORDER_INTENT_TYPEHASH(),
                buy.intentId,
                buy.trader,
                buy.subaccountId,
                buy.marketId,
                buy.side,
                buy.size1e8,
                buy.limitPrice1e8,
                buy.maxExecPrice1e8,
                buy.minExecPrice1e8,
                buy.nonce,
                buy.deadline
            )
        );
        bytes32 altDigest = keccak256(abi.encodePacked("\x19\x01", altDomainSeparator, structHash));
        bytes memory buySig = _sign(BUYER_PK, altDigest);

        PerpMatchingEngine.TradeFromIntents memory tr = _trade(INTENT_SIZE, TRADE_PRICE, buy, sell);
        vm.prank(OWNER);
        vm.expectRevert(PerpMatchingEngine.IntentSignatureInvalid.selector);
        matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz over exec price + trade size within the signed bounds:
    ///         valid combinations must succeed; a mutated signed field must
    ///         either fail signature recovery or hit a semantic bound
    ///         error.
    function testFuzz_sigInvariants(uint128 execPriceIn, uint128 sizeIn, uint8 mutationIdx) external {
        // Constrain to the valid legal window: exec in [SELLER_MIN, BUYER_MAX],
        // size in [1, INTENT_SIZE].
        uint128 execPrice = uint128(bound(uint256(execPriceIn), uint256(SELLER_MIN), uint256(BUYER_MAX)));
        uint128 size = uint128(bound(uint256(sizeIn), 1, uint256(INTENT_SIZE)));

        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, INTENT_SIZE, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, INTENT_SIZE, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);
        PerpMatchingEngine.TradeFromIntents memory tr = _trade(size, execPrice, buy, sell);

        // Path 1: unmutated → must succeed.
        if (mutationIdx == 0) {
            vm.prank(OWNER);
            matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
            bytes32 buyerHash = matchingEngine.hashOrderIntent(buy);
            assertEq(matchingEngine.intentFilled(buyerHash), size);
            return;
        }

        // Path 2: mutate one signed field. Any mutation to a hashed field
        // breaks the buyer's signature (or triggers a semantic guard first
        // if the mutation lands on a side-shape / market field).
        uint8 which = mutationIdx % 5;
        if (which == 0) {
            // Trader → sig-invalid (recovered != new trader).
            buy.trader = vm.addr(ATTACKER_PK);
        } else if (which == 1) {
            // Nonce → hash mismatch → sig-invalid.
            buy.nonce = buy.nonce + 1;
        } else if (which == 2) {
            // Market → hash mismatch (and also market mismatch semantically).
            buy.marketId = buy.marketId + 1;
        } else if (which == 3) {
            // Max exec price → hash mismatch.
            buy.maxExecPrice1e8 = buy.maxExecPrice1e8 + 1;
        } else {
            // Size → hash mismatch.
            buy.size1e8 = buy.size1e8 + 1;
        }

        vm.prank(OWNER);
        // Accept EITHER signature failure OR a specific semantic revert —
        // both prove the mutation was caught before engine apply.
        try matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr) {
            revert("mutated intent unexpectedly accepted");
        } catch (bytes memory reason) {
            bytes4 sel;
            assembly {
                sel := mload(add(reason, 0x20))
            }
            assertTrue(
                sel == PerpMatchingEngine.IntentSignatureInvalid.selector
                    || sel == PerpMatchingEngine.IntentMarketMismatch.selector
                    || sel == PerpMatchingEngine.IntentSideMismatch.selector
                    || sel == PerpMatchingEngine.IntentSizeExceedsRemaining.selector
                    || sel == PerpMatchingEngine.IntentExecPriceAboveBuyerMax.selector,
                "mutation caught by unexpected error"
            );
        }
    }

    /// @notice Fuzz partial fill sequence: random slices sum to at most the
    ///         intent size; assert cumulative fills tracked exactly.
    function testFuzz_partialFillBoundedBySize(uint8 slice1, uint8 slice2, uint8 slice3) external {
        uint128 intentSize = 10e8;
        // Bound each slice to [1, 4e8] so the sum stays <= 12e8 and we can
        // exercise both success and the eventual overrun.
        uint128 s1 = uint128(bound(uint256(slice1), 1, 4e8));
        uint128 s2 = uint128(bound(uint256(slice2), 1, 4e8));
        uint128 s3 = uint128(bound(uint256(slice3), 1, 4e8));

        PerpMatchingEngine.PerpOrderIntent memory buy = _buyIntent(1, intentSize, 0, BUYER_MAX);
        PerpMatchingEngine.PerpOrderIntent memory sell = _sellIntent(1, intentSize, 0, SELLER_MIN);
        bytes memory buySig = _signBuyer(buy);
        bytes memory sellSig = _signSeller(sell);

        bytes32 buyerHash = matchingEngine.hashOrderIntent(buy);
        bytes32 sellerHash = matchingEngine.hashOrderIntent(sell);

        uint128 cumFilled = 0;
        uint128[3] memory slices = [s1, s2, s3];
        for (uint256 i = 0; i < 3; i++) {
            uint128 s = slices[i];
            PerpMatchingEngine.TradeFromIntents memory tr = _trade(s, TRADE_PRICE, buy, sell);
            vm.prank(OWNER);
            if (cumFilled + s > intentSize) {
                vm.expectRevert(PerpMatchingEngine.IntentSizeExceedsRemaining.selector);
                matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
                // Cumulative unchanged.
                assertEq(matchingEngine.intentFilled(buyerHash), cumFilled);
                assertEq(matchingEngine.intentFilled(sellerHash), cumFilled);
            } else {
                matchingEngine.executeTradeFromIntents(buy, buySig, sell, sellSig, tr);
                cumFilled += s;
                assertEq(matchingEngine.intentFilled(buyerHash), cumFilled);
                assertEq(matchingEngine.intentFilled(sellerHash), cumFilled);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _buyIntent(uint256 nonce, uint128 size, uint128 limitPrice, uint128 maxExec)
        internal
        view
        returns (PerpMatchingEngine.PerpOrderIntent memory)
    {
        return PerpMatchingEngine.PerpOrderIntent({
            intentId: keccak256(abi.encodePacked("buy", nonce)),
            trader: BUYER,
            subaccountId: BUYER_SUB,
            marketId: MARKET_ID,
            side: 0,
            size1e8: size,
            limitPrice1e8: limitPrice,
            maxExecPrice1e8: maxExec,
            minExecPrice1e8: 0,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _sellIntent(uint256 nonce, uint128 size, uint128 limitPrice, uint128 minExec)
        internal
        view
        returns (PerpMatchingEngine.PerpOrderIntent memory)
    {
        return PerpMatchingEngine.PerpOrderIntent({
            intentId: keccak256(abi.encodePacked("sell", nonce)),
            trader: SELLER,
            subaccountId: SELLER_SUB,
            marketId: MARKET_ID,
            side: 1,
            size1e8: size,
            limitPrice1e8: limitPrice,
            maxExecPrice1e8: 0,
            minExecPrice1e8: minExec,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _trade(
        uint128 size,
        uint128 execPrice,
        PerpMatchingEngine.PerpOrderIntent memory buy,
        PerpMatchingEngine.PerpOrderIntent memory sell
    ) internal pure returns (PerpMatchingEngine.TradeFromIntents memory) {
        return PerpMatchingEngine.TradeFromIntents({
            marketId: buy.marketId,
            buyerSubaccountId: buy.subaccountId,
            sellerSubaccountId: sell.subaccountId,
            size1e8: size,
            executionPrice1e8: execPrice,
            buyerIsMaker: true,
            buyerIntentId: buy.intentId,
            sellerIntentId: sell.intentId
        });
    }

    function _signBuyer(PerpMatchingEngine.PerpOrderIntent memory i) internal view returns (bytes memory) {
        return _signIntent(BUYER_PK, i);
    }

    function _signSeller(PerpMatchingEngine.PerpOrderIntent memory i) internal view returns (bytes memory) {
        return _signIntent(SELLER_PK, i);
    }

    function _signIntent(uint256 pk, PerpMatchingEngine.PerpOrderIntent memory i)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _hashIntent(i);
        return _sign(pk, digest);
    }

    /// @notice Off-chain-shape reproduction of {PerpMatchingEngine.hashOrderIntent}
    ///         so we can hash a `memory` intent (the on-chain function takes
    ///         `calldata`).
    function _hashIntent(PerpMatchingEngine.PerpOrderIntent memory i) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                matchingEngine.ORDER_INTENT_TYPEHASH(),
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
        bytes32 ds = matchingEngine.domainSeparatorV4();
        return keccak256(abi.encodePacked("\x19\x01", ds, structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
