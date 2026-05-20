// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IMarginEngineTrade} from "../../../src/matching/IMarginEngineTrade.sol";
import {OptionMatchingEngine} from "../../../src/matching/OptionMatchingEngine.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";

contract MockOptionMarginEngineTrade is IMarginEngineTrade {
    error MockApplyTradeReverted();

    Trade internal _lastTrade;
    uint256 internal _applyCount;
    bool internal _shouldRevert;

    function setShouldRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    function applyTrade(Trade calldata t) external {
        if (_shouldRevert) revert MockApplyTradeReverted();

        _lastTrade = t;
        _applyCount++;
    }

    function applyCount() external view returns (uint256) {
        return _applyCount;
    }

    function lastTrade() external view returns (Trade memory t) {
        return _lastTrade;
    }

    function matchingEngine() external pure returns (address) {
        return address(0);
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    function paused() external pure returns (bool) {
        return false;
    }
}

contract OptionMatchingEngineTest is Test {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant BUYER_PK = 0xB0B;
    uint256 internal constant SELLER_PK = 0xCA11;
    uint256 internal constant OTHER_PK = 0xD00D;

    bytes32 internal constant INTENT_ID = keccak256("option-intent");
    uint64 internal constant STRIKE_1E8 = uint64(2_000 * 1e8);
    uint128 internal constant CONTRACT_SIZE_1E8 = 1e8;
    uint128 internal constant QUANTITY = 2;
    uint128 internal constant PREMIUM_PER_CONTRACT = 100 * 1e6;

    address internal OWNER;
    address internal BUYER;
    address internal SELLER;
    address internal OTHER;
    address internal constant UNDERLYING = address(0xE7A);
    address internal constant SETTLEMENT_ASSET = address(0xBEEF);
    address internal constant UNAUTHORIZED_EXECUTOR = address(0xBAD);

    OptionProductRegistry internal registry;
    MockOptionMarginEngineTrade internal marginEngine;
    OptionMatchingEngine internal matchingEngine;

    uint64 internal expiry;
    uint256 internal optionId;

    event OptionTradeExecuted(
        bytes32 indexed intentId,
        address indexed buyer,
        address indexed seller,
        uint256 optionId,
        uint128 quantity,
        uint128 premiumPerContract,
        bool buyerIsMaker,
        uint256 buyerNonce,
        uint256 sellerNonce
    );

    function setUp() external {
        OWNER = vm.addr(OWNER_PK);
        BUYER = vm.addr(BUYER_PK);
        SELLER = vm.addr(SELLER_PK);
        OTHER = vm.addr(OTHER_PK);

        registry = new OptionProductRegistry(OWNER);
        marginEngine = new MockOptionMarginEngineTrade();
        matchingEngine = new OptionMatchingEngine(OWNER, address(marginEngine), address(registry));

        expiry = uint64(block.timestamp + 7 days);

        vm.startPrank(OWNER);
        registry.setSettlementAssetAllowed(SETTLEMENT_ASSET, true);
        registry.setUnderlyingConfig(
            UNDERLYING,
            OptionProductRegistry.UnderlyingConfig({
                oracle: address(0),
                spotShockDownBps: 3_000,
                spotShockUpBps: 3_000,
                volShockDownBps: 0,
                volShockUpBps: 2_000,
                isEnabled: true
            })
        );
        optionId = registry.createSeries(UNDERLYING, SETTLEMENT_ASSET, expiry, STRIKE_1E8, true, true);
        vm.stopPrank();
    }

    function testExecuteTradeValidDualSignatureForwardsAndConsumesNonces() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(true);

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        IMarginEngineTrade.Trade memory forwarded = marginEngine.lastTrade();
        assertEq(forwarded.buyer, BUYER);
        assertEq(forwarded.seller, SELLER);
        assertEq(forwarded.optionId, optionId);
        assertEq(forwarded.quantity, QUANTITY);
        assertEq(forwarded.price, PREMIUM_PER_CONTRACT);
        assertTrue(forwarded.buyerIsMaker);
        assertEq(marginEngine.applyCount(), 1);
        assertEq(matchingEngine.nonces(BUYER), 1);
        assertEq(matchingEngine.nonces(SELLER), 1);
    }

    function testExecuteTradeEmitsOptionTradeExecutedWithIntentId() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(true);

        vm.expectEmit(true, true, true, true, address(matchingEngine));
        emit OptionTradeExecuted(
            INTENT_ID, BUYER, SELLER, optionId, QUANTITY, PREMIUM_PER_CONTRACT, true, uint256(0), uint256(0)
        );

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testExecuteTradeRejectsInvalidBuyerSignature() external {
        (OptionMatchingEngine.OptionTrade memory t,, bytes memory sellerSig) = _signedTrade(true);
        bytes memory badBuyerSig = _sign(OTHER_PK, matchingEngine.hashTrade(t));

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidSignature.selector);
        matchingEngine.executeTrade(t, badBuyerSig, sellerSig);

        assertEq(marginEngine.applyCount(), 0);
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    function testExecuteTradeRejectsInvalidSellerSignature() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig,) = _signedTrade(true);
        bytes memory badSellerSig = _sign(OTHER_PK, matchingEngine.hashTrade(t));

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidSignature.selector);
        matchingEngine.executeTrade(t, buyerSig, badSellerSig);

        assertEq(marginEngine.applyCount(), 0);
        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
    }

    function testExecuteTradeRejectsWrongBuyerNonce() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.buyerNonce = 1;
        (bytes memory buyerSig, bytes memory sellerSig) = _signTrade(t);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.BadNonce.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testExecuteTradeRejectsWrongSellerNonce() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.sellerNonce = 1;
        (bytes memory buyerSig, bytes memory sellerSig) = _signTrade(t);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.BadNonce.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testNonceCancellationWorks() external {
        vm.prank(BUYER);
        matchingEngine.cancelNextNonce();
        assertEq(matchingEngine.nonces(BUYER), 1);

        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        (bytes memory buyerSig, bytes memory sellerSig) = _signTrade(t);

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(matchingEngine.nonces(BUYER), 2);
        assertEq(matchingEngine.nonces(SELLER), 1);

        vm.prank(SELLER);
        matchingEngine.cancelNoncesUpTo(5);
        assertEq(matchingEngine.nonces(SELLER), 5);

        vm.prank(SELLER);
        vm.expectRevert(OptionMatchingEngine.BadNonce.selector);
        matchingEngine.cancelNoncesUpTo(5);
    }

    function testExecuteTradeRejectsExpiredDeadline() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(true);

        vm.warp(t.deadline + 1);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.DeadlineExpired.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testExecuteTradeRejectsZeroIntentId() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.intentId = bytes32(0);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidTrade.selector);
        matchingEngine.executeTrade(t, bytes(""), bytes(""));
    }

    function testExecuteTradeRejectsZeroBuyerAndSeller() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.buyer = address(0);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidTrade.selector);
        matchingEngine.executeTrade(t, bytes(""), bytes(""));

        t = _baseTrade(true);
        t.seller = address(0);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidTrade.selector);
        matchingEngine.executeTrade(t, bytes(""), bytes(""));
    }

    function testExecuteTradeRejectsSelfTrade() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.seller = t.buyer;

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidTrade.selector);
        matchingEngine.executeTrade(t, bytes(""), bytes(""));
    }

    function testExecuteTradeRejectsZeroQuantity() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.quantity = 0;

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidTrade.selector);
        matchingEngine.executeTrade(t, bytes(""), bytes(""));
    }

    function testExecuteTradeRejectsZeroPremium() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.premiumPerContract = 0;

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.InvalidTrade.selector);
        matchingEngine.executeTrade(t, bytes(""), bytes(""));
    }

    function testExecuteTradeRejectsUnauthorizedExecutor() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(true);

        vm.prank(UNAUTHORIZED_EXECUTOR);
        vm.expectRevert(OptionMatchingEngine.NotAuthorized.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testExecuteTradeRejectsSeriesMetadataMismatch() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.underlying = address(0xCAFE);
        (bytes memory buyerSig, bytes memory sellerSig) = _signTrade(t);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.SeriesMetadataMismatch.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testExecuteTradeRejectsUnknownOptionId() external {
        OptionMatchingEngine.OptionTrade memory t = _baseTrade(true);
        t.optionId = uint256(keccak256("unknown-option-id"));
        (bytes memory buyerSig, bytes memory sellerSig) = _signTrade(t);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.UnknownOptionId.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testExecuteTradeRejectsInactiveSeries() external {
        vm.prank(OWNER);
        registry.setSeriesActive(optionId, false);

        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(true);

        vm.prank(OWNER);
        vm.expectRevert(OptionMatchingEngine.SeriesInactive.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);
    }

    function testNonceRollbackOnMarginEngineRevert() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(true);
        marginEngine.setShouldRevert(true);

        vm.prank(OWNER);
        vm.expectRevert(MockOptionMarginEngineTrade.MockApplyTradeReverted.selector);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        assertEq(matchingEngine.nonces(BUYER), 0);
        assertEq(matchingEngine.nonces(SELLER), 0);
        assertEq(marginEngine.applyCount(), 0);
    }

    function testBuyerIsMakerFalseForwardsCorrectly() external {
        (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig) = _signedTrade(false);

        vm.prank(OWNER);
        matchingEngine.executeTrade(t, buyerSig, sellerSig);

        IMarginEngineTrade.Trade memory forwarded = marginEngine.lastTrade();
        assertFalse(forwarded.buyerIsMaker);
    }

    function testTradeTypehashMatchesV1BShape() external view {
        assertEq(
            matchingEngine.TRADE_TYPEHASH(),
            keccak256(
                "OptionTrade(bytes32 intentId,address buyer,address seller,uint256 optionId,address underlying,address settlementAsset,uint64 expiry,uint64 strike1e8,bool isCall,uint128 contractSize1e8,uint128 quantity,uint128 premiumPerContract,bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)"
            )
        );
    }

    function _signedTrade(bool buyerIsMaker)
        internal
        view
        returns (OptionMatchingEngine.OptionTrade memory t, bytes memory buyerSig, bytes memory sellerSig)
    {
        t = _baseTrade(buyerIsMaker);
        (buyerSig, sellerSig) = _signTrade(t);
    }

    function _baseTrade(bool buyerIsMaker) internal view returns (OptionMatchingEngine.OptionTrade memory t) {
        t = OptionMatchingEngine.OptionTrade({
            intentId: INTENT_ID,
            buyer: BUYER,
            seller: SELLER,
            optionId: optionId,
            underlying: UNDERLYING,
            settlementAsset: SETTLEMENT_ASSET,
            expiry: expiry,
            strike1e8: STRIKE_1E8,
            isCall: true,
            contractSize1e8: CONTRACT_SIZE_1E8,
            quantity: QUANTITY,
            premiumPerContract: PREMIUM_PER_CONTRACT,
            buyerIsMaker: buyerIsMaker,
            buyerNonce: matchingEngine.nonces(BUYER),
            sellerNonce: matchingEngine.nonces(SELLER),
            deadline: block.timestamp + 1 hours
        });
    }

    function _signTrade(OptionMatchingEngine.OptionTrade memory t)
        internal
        view
        returns (bytes memory buyerSig, bytes memory sellerSig)
    {
        bytes32 digest = matchingEngine.hashTrade(t);
        buyerSig = _sign(BUYER_PK, digest);
        sellerSig = _sign(SELLER_PK, digest);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
