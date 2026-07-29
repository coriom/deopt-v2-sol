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
/// @notice `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` — end-to-end
///         signed-order execution: orders + signatures + premium + positions +
///         reservations + fees + rollback.
contract OptionMatchingEngineV2Execution is OptionMatchingEngineV2TestBase {
    /*//////////////////////////////////////////////////////////////
                         HAPPY PATH — EOA/EOA
    //////////////////////////////////////////////////////////////*/

    function test_happyPath_fullFillEOAtoEOA() public {
        _fund(alice, 1, 1000e6); // buyer funds 1000 USDC
        _fund(bob, 1, 1000e6); // seller funds 1000 USDC (collateral for short)

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

        bytes32 execId = engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, buyerActive, sellerActive);
        assertTrue(execId != bytes32(0));

        // 100e8 * 1e8 / 1e8 = 100e8 quote-1e8. Native (6-dec): 100e8 / 100 = 1e8 (100 USDC).
        assertEq(vault.balanceOf(aliceSk, address(usdc)), aliceBalBefore - 100e6);
        assertEq(vault.balanceOf(bobSk, address(usdc)), bobBalBefore + 100e6);

        PositionTypes.OptionPosition memory alicePos = ledger.positionOf(aliceSk, 1);
        PositionTypes.OptionPosition memory bobPos = ledger.positionOf(bobSk, 1);
        assertEq(uint256(alicePos.longQuantity1e8), 1e8);
        assertEq(uint256(alicePos.shortQuantity1e8), 0);
        assertEq(uint256(bobPos.longQuantity1e8), 0);
        assertEq(uint256(bobPos.shortQuantity1e8), 1e8);

        // Seller reservation locked at IM.
        uint256 sellerLocked = vault.lockedByEngineOf(bobSk, address(usdc), address(engine));
        assertGt(sellerLocked, 0);
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
        // Point seller envelope to same subKey as buyer.
        sEnv.owner = alice;
        sEnv.signer = alice;
        sEnv.subKey = _sk(alice, 1);
        sSig = _sign(alicePk, sEnv);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.SelfTrade.selector, _sk(alice, 1)));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    function test_rejects_zeroAccountId() public {
        // Envelope with subaccountId 0 must revert per WP-05.
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    function test_rejects_quantityDisagreement() public {
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
        sOrder.quantity1e8 = 2e8;
        sEnv.payloadHash = OptionOrderTypes.hashOrder(sOrder);
        sSig = _sign(bobPk, sEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IOptionMatchingEngine.QuantityDisagreement.selector, uint128(1e8), uint128(2e8))
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        // Buyer signed a max of 50e8 but execution price is 100e8.
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        // Buyer signed as taker + post-only — impossible combination.
        bOrder.timeInForce = OptionOrderTypes.TIF_POST_ONLY;
        bEnv.payloadHash = OptionOrderTypes.hashOrder(bOrder);
        bSig = _sign(alicePk, bEnv);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.PostOnlyRoleViolation.selector, _sk(alice, 1)));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        // Buyer's `signer` field != `owner`.
        bEnv.signer = carol;
        bSig = _sign(alicePk, bEnv); // signed with alicePk but signer=carol

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IOptionMatchingEngine.InvalidSigner.selector, _sk(alice, 1), carol, alice)
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        // Random 65-byte signature.
        bytes memory badSig = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            badSig[i] = 0xAA;
        }

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IOptionMatchingEngine.InvalidSigner.selector, _sk(alice, 1), alice, alice)
        );
        engine.executeMatch(bEnv, badSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    function test_rejects_replayedIntent() public {
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
        // Same signatures + envelopes replayed → nonce mismatch on buyer.
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                       CANCELLATION
    //////////////////////////////////////////////////////////////*/

    function test_cancelNextNonce_blocksFuturePairExecution() public {
        _fund(alice, 1, 1000e6);
        _fund(bob, 1, 1000e6);
        vm.prank(alice);
        engine.cancelNextNonce(); // alice's next nonce is now 1
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildDefaultMatch(0, 0);
        uint256[] memory ids = new uint256[](0);
        // Buyer's envelope still uses nonce 0.
        vm.expectRevert(
            abi.encodeWithSelector(ReplayAndEpochController.BadNonce.selector, alice, uint256(1), uint256(0))
        );
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                      POST-STATE MARGIN CHECK
    //////////////////////////////////////////////////////////////*/

    function test_rejects_undercollateralizedSeller() public {
        _fund(alice, 1, 1000e6);
        // Bob has near-zero collateral — reservation lock or post-margin check
        // fails closed. Both paths revert atomically — the test asserts revert
        // without pinning to a specific error selector.
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                     ROLLBACK ATOMICITY
    //////////////////////////////////////////////////////////////*/

    function test_rollback_failedPostStateRestoresLedgerAndBalances() public {
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
        uint256 aliceNonceBefore = engine.nonces(alice);
        uint256 bobNonceBefore = engine.nonces(bob);

        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);

        assertEq(vault.balanceOf(aliceSk, address(usdc)), aliceBalBefore);
        assertEq(vault.balanceOf(bobSk, address(usdc)), bobBalBefore);
        assertEq(uint256(ledger.activeSeriesCount(aliceSk)), uint256(aliceActiveBefore));
        assertEq(uint256(ledger.activeSeriesCount(bobSk)), uint256(bobActiveBefore));
        assertEq(engine.nonces(alice), aliceNonceBefore);
        assertEq(engine.nonces(bob), bobNonceBefore);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                        ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_siblingSubaccount_untouched() public {
        // Buyer alice/1 + seller bob/1 executes; carol/1 completely untouched.
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
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids);

        bytes32 carolSk = _sk(carol, 1);
        assertEq(vault.balanceOf(carolSk, address(usdc)), 500e6);
        assertEq(uint256(ledger.activeSeriesCount(carolSk)), 0);
        assertEq(vault.lockedByEngineOf(carolSk, address(usdc), address(engine)), 0);
    }
}
