// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionMatchingEngineV2TestBase} from "./OptionMatchingEngineV2.t.sol";
import {OptionMatchingEngineV2} from "../../../src/hybrid-v2/options/OptionMatchingEngineV2.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IOptionsRiskProvider} from "../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {ReplayAndEpochController} from "../../../src/hybrid-v2/security/ReplayAndEpochController.sol";
import {IReplayProtected} from "../../../src/hybrid-v2/interfaces/IReplayProtected.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

import {MockERC1271Wallet} from "./harness/MockERC1271Wallet.sol";

/// @title OptionMatchingEngineV2Execution
/// @notice `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` +
///         `ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-AND-NONCE-V2-PATCH` —
///         end-to-end signed-order execution with reusable-order lifecycle.
contract OptionMatchingEngineV2Execution is OptionMatchingEngineV2TestBase {
    /*//////////////////////////////////////////////////////////////
                         HAPPY PATH — EOA/EOA
    //////////////////////////////////////////////////////////////*/

    function test_happyPath_fullFillEOAtoEOA() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);

        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);

        uint256[] memory buyerActive = new uint256[](1);
        buyerActive[0] = 1;
        uint256[] memory sellerActive = new uint256[](1);
        sellerActive[0] = 1;

        bytes32 aliceSk = _sk(alice, 1);
        bytes32 bobSk = _sk(bob, 1);
        uint256 aliceBalBefore = vault.balanceOf(aliceSk, address(usdc));
        uint256 bobBalBefore = vault.balanceOf(bobSk, address(usdc));

        bytes32 execId = engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, buyerActive, sellerActive);
        assertTrue(execId != bytes32(0));

        assertEq(vault.balanceOf(aliceSk, address(usdc)), aliceBalBefore - 100e6);
        assertEq(vault.balanceOf(bobSk, address(usdc)), bobBalBefore + 100e6);

        PositionTypes.OptionPosition memory alicePos = ledger.positionOf(aliceSk, 1);
        PositionTypes.OptionPosition memory bobPos = ledger.positionOf(bobSk, 1);
        assertEq(uint256(alicePos.longQuantity1e8), 1e8);
        assertEq(uint256(alicePos.shortQuantity1e8), 0);
        assertEq(uint256(bobPos.longQuantity1e8), 0);
        assertEq(uint256(bobPos.shortQuantity1e8), 1e8);

        uint256 sellerLocked = vault.lockedByEngineOf(bobSk, address(usdc), address(engine));
        assertGt(sellerLocked, 0);

        // Lifecycle: buyer + seller both fully filled — filledQuantity == signed max.
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sellerOrderId = engine.hashSignedActionEnvelopeDigest(sEnv);
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 1e8);
        assertEq(uint256(engine.filledQuantityOf(sellerOrderId)), 1e8);
    }

    /*//////////////////////////////////////////////////////////////
                       WITNESS + SUBKEY BINDING
    //////////////////////////////////////////////////////////////*/

    function test_rejects_selfTrade_sameSubKey() public {
        _fund(alice, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        sEnv.owner = alice;
        sEnv.signer = alice;
        sEnv.subKey = _sk(alice, 1);
        sSig = _sign(alicePk, sEnv);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.SelfTrade.selector, _sk(alice, 1)));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_zeroAccountId() public {
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bEnv.subaccountId = 0;
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(ReplayAndEpochController.InvalidSubaccountId.selector);
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                       ORDER COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    function test_rejects_sameSide() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        sOrder.side = OptionOrderTypes.SIDE_LONG;
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.SameSideMatch.selector, OptionOrderTypes.SIDE_LONG, OptionOrderTypes.SIDE_LONG
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_differentSeries() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        _series(2, address(0xE7E7), STRIKE_1E8, false);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        sOrder.seriesId = 2;
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.SeriesMismatch.selector, 1, 2));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice Post-patch: buyer and seller MAY sign different quantity maxes.
    ///         The engine fills `min(buyerRemaining, sellerRemaining)` and the
    ///         higher-signed side retains capacity for a subsequent fill.
    function test_asymmetricSignedQuantity_fillsMinRemaining() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        // Buyer signs qty=5, seller signs qty=3. First fill = 3 (min).
        bOrder.quantity1e8 = 5e8;
        sOrder.quantity1e8 = 3e8;
        bEnv.payloadHash = OptionOrderTypes.hashOrder(bOrder);
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        bSig = _sign(alicePk, bEnv);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8, ids, ids);

        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sellerOrderId = engine.hashSignedActionEnvelopeDigest(sEnv);
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 3e8);
        assertEq(uint256(engine.filledQuantityOf(sellerOrderId)), 3e8);
        // Seller was fully filled → no remaining. Buyer still has 2e8 remaining.
    }

    function test_rejects_priceDisagreement() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        sOrder.pricePerContract1e8 = 90e8;
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IOptionMatchingEngine.PremiumDisagreement.selector, uint128(100e8), uint128(90e8))
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_buyerLimitViolation() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bOrder.limitPricePerContract1e8 = 50e8;
        bEnv.payloadHash = OptionOrderTypes.hashOrder(bOrder);
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.PremiumOutsideLimit.selector,
                uint128(100e8),
                uint128(50e8),
                OptionOrderTypes.SIDE_LONG
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_postOnlyTakerRole() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bOrder.timeInForce = OptionOrderTypes.TIF_POST_ONLY;
        bEnv.payloadHash = OptionOrderTypes.hashOrder(bOrder);
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.PostOnlyRoleViolation.selector, _sk(alice, 1)));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_bothMakerRoles() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bOrder.role = OptionOrderTypes.ROLE_MAKER;
        sOrder.role = OptionOrderTypes.ROLE_MAKER;
        bEnv.payloadHash = OptionOrderTypes.hashOrder(bOrder);
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        bSig = _sign(alicePk, bEnv);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.InvalidMakerTakerAssignment.selector,
                OptionOrderTypes.ROLE_MAKER,
                OptionOrderTypes.ROLE_MAKER
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNATURE VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_rejects_signerNotOwner() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bEnv.signer = carol;
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IOptionMatchingEngine.InvalidSigner.selector, _sk(alice, 1), carol, alice)
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_invalidSignatureBytes() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            /* bSig */
            ,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bytes memory badSig = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            badSig[i] = 0xAA;
        }

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IOptionMatchingEngine.InvalidSigner.selector, _sk(alice, 1), alice, alice)
        );
        engine.executeMatch(bEnv, badSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                     DEADLINE + REPLAY
    //////////////////////////////////////////////////////////////*/

    function test_rejects_expiredDeadline() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bEnv.deadline = block.timestamp - 1;
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice Post-patch replay guard: the same envelope re-submitted after
    ///         a full fill reverts because filledBefore has reached signed
    ///         max — no residual capacity for another fill.
    function test_rejects_replayAfterFullFill() public {
        _fund(alice, 1, 2000e6);
        _fund(bob, 1, 2000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        // Second call reverts: buyer's filled has reached signed max.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderAlreadyFullyFilled.selector, buyerOrderId, uint128(1e8), uint128(1e8)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_wrongEngine() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bEnv.engine = address(0xDEAD);
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                       LIFECYCLE — GTC PARTIAL FILLS
    //////////////////////////////////////////////////////////////*/

    function test_gtc_partialFill_thenSecondFillCompletes() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        // Both sign qty=10, fill 3 then 7.
        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 10e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("b-gtc")
        });
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 10e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("s-gtc")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(alice, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory bSig = _sign(alicePk, bEnv);
        bytes memory sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8, ids, ids);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sellerOrderId = engine.hashSignedActionEnvelopeDigest(sEnv);
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 3e8);
        assertEq(uint256(engine.filledQuantityOf(sellerOrderId)), 3e8);

        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 7e8, ids, ids);
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 10e8);
        assertEq(uint256(engine.filledQuantityOf(sellerOrderId)), 10e8);

        // Third attempt on same fully-filled orders reverts.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderAlreadyFullyFilled.selector, buyerOrderId, uint128(10e8), uint128(10e8)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_gtc_rejectsFillExceedingRemaining() public {
        _fund(alice, 1, 2000e6);
        _fund(bob, 1, 2000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        // Signed qty = 1e8, requesting 2e8 → invalid.
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.FillQuantityInvalid.selector, uint128(2e8), uint128(1e8), uint128(1e8)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 2e8, ids, ids);
    }

    function test_gtc_rejectsZeroFillQuantity() public {
        _fund(alice, 1, 2000e6);
        _fund(bob, 1, 2000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(IOptionMatchingEngine.QuantityZero.selector);
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 0, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                       LIFECYCLE — IOC + FOK
    //////////////////////////////////////////////////////////////*/

    function test_ioc_terminatesOrderAfterAnyFill() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 10e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_IOC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("b-ioc")
        });
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 10e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("s-gtc")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(alice, 1, 2, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 2, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory bSig = _sign(alicePk, bEnv);
        bytes memory sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8, ids, ids);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        // IOC buyer is now cancelled after 3-of-10 fill.
        assertTrue(engine.isOrderCancelled(buyerOrderId));
        // Second attempt reverts.
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.OrderCancelled.selector, buyerOrderId));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 7e8, ids, ids);
    }

    function test_fok_requiresFullFillFromZero() public {
        _fund(alice, 1, 2000e6);
        _fund(bob, 1, 2000e6);
        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 5e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_FOK,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("b-fok")
        });
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 5e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("s-gtc-fok")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(alice, 1, 3, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 3, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory bSig = _sign(alicePk, bEnv);
        bytes memory sSig = _sign(bobPk, sEnv);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.FokRequiresFullFillFromZero.selector,
                buyerOrderId,
                uint128(3e8),
                uint128(5e8),
                uint128(0)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8, ids, ids);
    }

    function test_fok_fullFillFromZeroSucceeds() public {
        _fund(alice, 1, 20_000e6);
        _fund(bob, 1, 20_000e6);
        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 5e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_FOK,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("b-fok-ok")
        });
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 5e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("s-gtc-fok-ok")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(alice, 1, 4, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 4, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory bSig = _sign(alicePk, bEnv);
        bytes memory sSig = _sign(bobPk, sEnv);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 5e8, ids, ids);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 5e8);
    }

    /*//////////////////////////////////////////////////////////////
                     LIFECYCLE — CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_cancelSignedOrder_ownerBlocksFutureExecution() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        vm.prank(alice);
        engine.cancelSignedOrder(bEnv);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        assertTrue(engine.isOrderCancelled(buyerOrderId));

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.OrderCancelled.selector, buyerOrderId));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_cancelSignedOrder_rejectsNonOwner() public {
        (IntentHash.SignedActionEnvelope memory bEnv,,,,,) = _buildDefaultMatch(0, 0);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.NotOrderOwner.selector, buyerOrderId, bob, alice));
        vm.prank(bob);
        engine.cancelSignedOrder(bEnv);
    }

    function test_cancelSignedOrder_rejectsDoubleCancel() public {
        (IntentHash.SignedActionEnvelope memory bEnv,,,,,) = _buildDefaultMatch(0, 0);
        vm.prank(alice);
        engine.cancelSignedOrder(bEnv);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.OrderCancelled.selector, buyerOrderId));
        vm.prank(alice);
        engine.cancelSignedOrder(bEnv);
    }

    function test_advanceMinValidOrderNonce_bulkInvalidates() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        // Alice advances min-valid to 5 → any envelope with nonce < 5 fails.
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 5);
        assertEq(engine.minValidOrderNonceOf(_sk(alice, 1)), 5);

        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.OrderNonceStale.selector, _sk(alice, 1), uint256(0), uint256(5)
            )
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_advanceMinValidOrderNonce_mustStrictlyAdvance() public {
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOptionMatchingEngine.MinValidOrderNonceNotAdvancing.selector, _sk(alice, 1), uint256(10), uint256(10)
            )
        );
        vm.prank(alice);
        engine.advanceMinValidOrderNonce(1, 10);
    }

    function test_multipleConcurrentLiveOrders_perSubaccount() public {
        _fund(alice, 1, 3000e6);
        _fund(bob, 1, 3000e6);
        // Alice signs THREE orders with nonces 1, 2, 3 (three concurrent live buys).
        // Fill each in a distinct pair.
        for (uint256 i = 1; i <= 3; i++) {
            OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
                seriesId: 1,
                side: OptionOrderTypes.SIDE_LONG,
                quantity1e8: 1e8,
                pricePerContract1e8: 100e8,
                limitPricePerContract1e8: 200e8,
                premiumToken: address(usdc),
                timeInForce: OptionOrderTypes.TIF_GTC,
                role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
                salt: bytes32(i)
            });
            OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
                seriesId: 1,
                side: OptionOrderTypes.SIDE_SHORT,
                quantity1e8: 1e8,
                pricePerContract1e8: 100e8,
                limitPricePerContract1e8: 50e8,
                premiumToken: address(usdc),
                timeInForce: OptionOrderTypes.TIF_GTC,
                role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
                salt: bytes32(i + 100)
            });
            IntentHash.SignedActionEnvelope memory bEnv =
                _makeEnvelope(alice, 1, i, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
            IntentHash.SignedActionEnvelope memory sEnv =
                _makeEnvelope(bob, 1, i, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
            bytes memory bSig = _sign(alicePk, bEnv);
            bytes memory sSig = _sign(bobPk, sEnv);
            uint256[] memory ids = new uint256[](1);
            ids[0] = 1;
            engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        }

        bytes32 aliceSk = _sk(alice, 1);
        PositionTypes.OptionPosition memory alicePos = ledger.positionOf(aliceSk, 1);
        assertEq(uint256(alicePos.longQuantity1e8), 3e8);
    }

    /*//////////////////////////////////////////////////////////////
                        SERIES VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_rejects_unknownSeries() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        bOrder.seriesId = 42;
        sOrder.seriesId = 42;
        bEnv.payloadHash = OptionOrderTypes.hashOrder(bOrder);
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        bSig = _sign(alicePk, bEnv);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.InvalidSeries.selector, 42));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                      POST-STATE MARGIN CHECK
    //////////////////////////////////////////////////////////////*/

    function test_rejects_undercollateralizedSeller() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                     ROLLBACK ATOMICITY
    //////////////////////////////////////////////////////////////*/

    function test_rollback_failedPostStateRestoresLedgerBalancesAndLifecycle() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        bytes32 aliceSk = _sk(alice, 1);
        bytes32 bobSk = _sk(bob, 1);
        uint256 aliceBalBefore = vault.balanceOf(aliceSk, address(usdc));
        uint256 bobBalBefore = vault.balanceOf(bobSk, address(usdc));
        uint32 aliceActiveBefore = ledger.activeSeriesCount(aliceSk);
        uint32 bobActiveBefore = ledger.activeSeriesCount(bobSk);
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        bytes32 sellerOrderId = engine.hashSignedActionEnvelopeDigest(sEnv);

        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);

        assertEq(vault.balanceOf(aliceSk, address(usdc)), aliceBalBefore);
        assertEq(vault.balanceOf(bobSk, address(usdc)), bobBalBefore);
        assertEq(uint256(ledger.activeSeriesCount(aliceSk)), uint256(aliceActiveBefore));
        assertEq(uint256(ledger.activeSeriesCount(bobSk)), uint256(bobActiveBefore));
        // Lifecycle state preserved: filled untouched, not cancelled.
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 0);
        assertEq(uint256(engine.filledQuantityOf(sellerOrderId)), 0);
        assertFalse(engine.isOrderCancelled(buyerOrderId));
        assertFalse(engine.isOrderCancelled(sellerOrderId));
    }

    /*//////////////////////////////////////////////////////////////
                      FEE HOOK VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_rejects_feeHookReturningNotOk() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        feeHook.setReject(true);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.FeeHookRejected.selector, _sk(alice, 1)));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    function test_rejects_feeHookEmittingRebate() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        feeHook.setEmitRebate(true);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function test_pausedExecution_rejectsAllOrders() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        vm.prank(guardian);
        engine.pauseExecution();
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(IOptionMatchingEngine.ExecutionPaused.selector);
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                        ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_siblingSubaccount_untouched() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        _fund(carol, 1, 500e6);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);

        bytes32 carolSk = _sk(carol, 1);
        assertEq(vault.balanceOf(carolSk, address(usdc)), 500e6);
        assertEq(uint256(ledger.activeSeriesCount(carolSk)), 0);
        assertEq(vault.lockedByEngineOf(carolSk, address(usdc), address(engine)), 0);
    }
}
