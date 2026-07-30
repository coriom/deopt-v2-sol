// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionMatchingEngineV2TestBase} from "../options/OptionMatchingEngineV2.t.sol";

import {RecoveryFinalizerV1} from "../../../src/hybrid-v2/recovery/RecoveryFinalizerV1.sol";
import {EscapeControllerV1} from "../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {IEscapeController} from "../../../src/hybrid-v2/interfaces/IEscapeController.sol";
import {RecoveryState} from "../../../src/hybrid-v2/libraries/RecoveryTypes.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";

/// @title RecoveryFinalizerV1Test
/// @notice `ONCHAIN-SUBACCOUNT-RECOVERY-FINALIZER-V1` (WP-10B) — unit + fuzz +
///         integration coverage for the atomic finalization primitive. Exercises
///         authority, recovery-state gate, position proof, reservation proof,
///         withdrawal recipient, atomic-all-token withdrawal, finalized-state
///         restrictions, and DB-loss reconstruction.
contract RecoveryFinalizerV1Test is OptionMatchingEngineV2TestBase {
    EscapeControllerV1 internal escape;
    RecoveryFinalizerV1 internal finalizer;

    uint64 internal constant DELAY = 0;
    uint64 internal constant PAUSE_MAX_BLOCKS = 3600;

    function setUp() public override {
        super.setUp();
        escape = new EscapeControllerV1(address(registry), governance, DELAY, PAUSE_MAX_BLOCKS);
        finalizer = new RecoveryFinalizerV1(address(registry), address(vault), address(escape), address(ledger));
        vm.startPrank(governance);
        vault.initializeEscapeController(address(escape));
        vault.initializeRecoveryFinalizer(address(finalizer));
        escape.initializeRecoveryFinalizer(address(finalizer));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTION + AUTHORITY
    //////////////////////////////////////////////////////////////*/

    function test_construction_rejectsZeroDependencies() public {
        vm.expectRevert(RecoveryFinalizerV1.InvalidDependency.selector);
        new RecoveryFinalizerV1(address(0), address(vault), address(escape), address(ledger));
        vm.expectRevert(RecoveryFinalizerV1.InvalidDependency.selector);
        new RecoveryFinalizerV1(address(registry), address(0), address(escape), address(ledger));
        vm.expectRevert(RecoveryFinalizerV1.InvalidDependency.selector);
        new RecoveryFinalizerV1(address(registry), address(vault), address(0), address(ledger));
        vm.expectRevert(RecoveryFinalizerV1.InvalidDependency.selector);
        new RecoveryFinalizerV1(address(registry), address(vault), address(escape), address(0));
    }

    function test_construction_persistsImmutables() public view {
        assertEq(address(finalizer.REGISTRY()), address(registry));
        assertEq(address(finalizer.VAULT()), address(vault));
        assertEq(address(finalizer.ESCAPE_CONTROLLER()), address(escape));
        assertEq(address(finalizer.POSITIONS_LEDGER()), address(ledger));
    }

    function test_authority_nonOwnerRejected() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        // Bob tries to finalize alice's subaccount.
        vm.prank(bob);
        vm.expectRevert(); // SubaccountNotFound(bob, 1) — bob's slot exists though; owner check via ownerOf
        finalizer.finalize(1);
    }

    function test_authority_subaccountZeroRejected() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryFinalizerV1.InvalidSubaccountId.selector);
        finalizer.finalize(0);
    }

    function test_authority_unknownSubaccountRejected() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RecoveryFinalizerV1.SubaccountNotFound.selector, alice, uint32(42)));
        finalizer.finalize(42);
    }

    /*//////////////////////////////////////////////////////////////
                        RECOVERY-STATE GATE
    //////////////////////////////////////////////////////////////*/

    function test_state_normalStateRejected() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        vm.expectRevert();
        finalizer.finalize(1);
    }

    function test_state_pendingRejected() public {
        EscapeControllerV1 delayed =
            new EscapeControllerV1(address(registry), governance, uint64(1 hours), PAUSE_MAX_BLOCKS);
        RecoveryFinalizerV1 delayedFinalizer =
            new RecoveryFinalizerV1(address(registry), address(vault), address(delayed), address(ledger));
        vm.prank(governance);
        delayed.initializeRecoveryFinalizer(address(delayedFinalizer));
        vm.prank(alice);
        delayed.activateRecovery(1);
        vm.prank(alice);
        vm.expectRevert();
        delayedFinalizer.finalize(1);
    }

    function test_state_cancelledRejected() public {
        EscapeControllerV1 delayed =
            new EscapeControllerV1(address(registry), governance, uint64(1 hours), PAUSE_MAX_BLOCKS);
        RecoveryFinalizerV1 delayedFinalizer =
            new RecoveryFinalizerV1(address(registry), address(vault), address(delayed), address(ledger));
        vm.prank(governance);
        delayed.initializeRecoveryFinalizer(address(delayedFinalizer));
        vm.prank(alice);
        delayed.activateRecovery(1);
        vm.prank(alice);
        delayed.cancelRecovery(1);
        vm.prank(alice);
        vm.expectRevert();
        delayedFinalizer.finalize(1);
    }

    function test_state_alreadyFinalizedRejected() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        finalizer.finalize(1);
        // Second call reverts.
        vm.prank(alice);
        vm.expectRevert();
        finalizer.finalize(1);
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION PROOF
    //////////////////////////////////////////////////////////////*/

    function test_position_zeroActiveSeriesFinalizes() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        finalizer.finalize(1);
        bytes32 sk = _sk(alice, 1);
        assertEq(uint8(escape.recoveryStateOf(sk)), uint8(RecoveryState.RECOVERED));
    }

    /*//////////////////////////////////////////////////////////////
                        RESERVATION PROOF
    //////////////////////////////////////////////////////////////*/

    /// @notice The withdrawal happens with no reservations remaining.
    function test_reservation_zeroReservationsPasses() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        (, uint8 count) = finalizer.finalize(1);
        assertEq(count, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL MODEL (RW-1)
    //////////////////////////////////////////////////////////////*/

    function test_withdrawal_oneTokenWithdrawalMovesFullBalance() public {
        _fund(alice, 1, 1_000e6);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        (address recipient, uint8 count) = finalizer.finalize(1);
        assertEq(recipient, alice);
        assertEq(count, 1);
        assertEq(usdc.balanceOf(alice), aliceBefore + 1_000e6);
        assertEq(vault.balanceOf(_sk(alice, 1), address(usdc)), 0);
    }

    function test_withdrawal_totalAccountedDecreasedByExactAmount() public {
        _fund(alice, 1, 1_000e6);
        uint256 totalBefore = vault.totalAccounted(address(usdc));
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        finalizer.finalize(1);
        assertEq(vault.totalAccounted(address(usdc)), totalBefore - 1_000e6);
    }

    function test_withdrawal_donationSurplusRemainsWithVault() public {
        _fund(alice, 1, 1_000e6);
        // Direct donation to the vault (bypasses `_totalAccounted`).
        usdc.mint(address(vault), 500e6);
        uint256 vaultPhysicalBefore = usdc.balanceOf(address(vault));
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        finalizer.finalize(1);
        // Alice receives ONLY her canonical balance (1_000e6). Donation
        // stays with the vault.
        assertEq(usdc.balanceOf(address(vault)), vaultPhysicalBefore - 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 500e6); // 500 donation remains
    }

    function test_withdrawal_disabledTokenBalanceStillWithdraws() public {
        _fund(alice, 1, 1_000e6);
        // Governance disables USDC after the deposit landed. The
        // append-only universe rule ensures the token is still iterated.
        vm.prank(governance);
        vault.removeSupportedToken(address(usdc));
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        (address recipient, uint8 count) = finalizer.finalize(1);
        assertEq(recipient, alice);
        assertEq(count, 1);
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    function test_withdrawal_zeroBalanceTokenSkippedFromCount() public {
        // Add a second collateral token; alice never deposits into it.
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        vm.prank(governance);
        vault.addSupportedToken(address(wbtc));
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        (, uint8 count) = finalizer.finalize(1);
        // Only USDC has a balance → count = 1.
        assertEq(count, 1);
    }

    function test_withdrawal_multiTokenWithdrawsAll() public {
        MockERC20 wbtc = new MockERC20("WBTC", "WBTC", 8);
        vm.prank(governance);
        vault.addSupportedToken(address(wbtc));
        _fund(alice, 1, 1_000e6);
        // Fund WBTC directly.
        wbtc.mint(alice, 2e8);
        vm.prank(alice);
        wbtc.approve(address(vault), 2e8);
        vm.prank(alice);
        vault.deposit(1, address(wbtc), 2e8);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWbtcBefore = wbtc.balanceOf(alice);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        (, uint8 count) = finalizer.finalize(1);
        assertEq(count, 2);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 1_000e6);
        assertEq(wbtc.balanceOf(alice), aliceWbtcBefore + 2e8);
    }

    function test_withdrawal_siblingSubaccountBalanceUnchanged() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        registry.registerNext(); // subaccount 2 for alice
        _fund(alice, 2, 500e6);
        vm.prank(alice);
        escape.activateRecovery(1); // sub 1 only
        vm.prank(alice);
        finalizer.finalize(1);
        // Sibling subaccount 2 balance untouched.
        assertEq(vault.balanceOf(_sk(alice, 2), address(usdc)), 500e6);
    }

    /*//////////////////////////////////////////////////////////////
                        FINALIZED-STATE RESTRICTIONS (Part K)
    //////////////////////////////////////////////////////////////*/

    function _finalize(address o) internal {
        _fund(o, 1, 1_000e6);
        vm.prank(o);
        escape.activateRecovery(1);
        vm.prank(o);
        finalizer.finalize(1);
    }

    function test_finalized_depositBlocked() public {
        _finalize(alice);
        bytes32 aliceSk = _sk(alice, 1);
        bytes memory expected = abi.encodeWithSelector(CollateralVaultV2Core.SubaccountFinalized.selector, aliceSk);
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(vault), 100e6);
        vm.prank(alice);
        vm.expectRevert(expected);
        vault.deposit(1, address(usdc), 100e6);
    }

    function test_finalized_depositForBlocked() public {
        _finalize(alice);
        bytes32 aliceSk = _sk(alice, 1);
        bytes memory expected = abi.encodeWithSelector(CollateralVaultV2Core.SubaccountFinalized.selector, aliceSk);
        usdc.mint(bob, 100e6);
        vm.prank(bob);
        usdc.approve(address(vault), 100e6);
        vm.prank(bob);
        vm.expectRevert(expected);
        vault.depositFor(alice, 1, address(usdc), 100e6);
    }

    function test_finalized_internalTransferInBlocked() public {
        // Alice needs a second subaccount to source the transfer from.
        vm.prank(alice);
        registry.registerNext(); // sub 2
        _fund(alice, 2, 500e6);
        _finalize(alice); // sub 1 finalizes
        bytes32 aliceSk = _sk(alice, 1);
        bytes memory expected = abi.encodeWithSelector(CollateralVaultV2Core.SubaccountFinalized.selector, aliceSk);
        vm.prank(alice);
        vm.expectRevert(expected);
        vault.internalTransfer(address(usdc), 2, 1, 1e6);
    }

    function test_finalized_matchBlocked() public {
        _finalize(alice);
        _fund(bob, 1, 10_000e6);
        // Build a match involving finalized alice.
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
            salt: bytes32("fz-b")
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
            salt: bytes32("fz-s")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(alice, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory bSig = _sign(alicePk, bEnv);
        bytes memory sSig = _sign(bobPk, sEnv);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(IOptionMatchingEngine.RecoveryActiveForSubaccount.selector, bEnv.subKey));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                        AUTHORITY BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function test_vault_recoveryPrimitive_nonFinalizerRejected() public {
        bytes32 aliceSk = _sk(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.applyRecoveryFinalization(aliceSk, address(usdc));
    }

    function test_escape_markFinalized_nonFinalizerRejected() public {
        bytes32 aliceSk = _sk(alice, 1);
        vm.prank(alice);
        vm.expectRevert(EscapeControllerV1.OnlyRecoveryFinalizer.selector);
        escape.markFinalized(aliceSk);
    }

    function test_escape_initializeFinalizer_oneShot() public {
        vm.prank(governance);
        vm.expectRevert(EscapeControllerV1.RecoveryFinalizerAlreadyInitialized.selector);
        escape.initializeRecoveryFinalizer(address(0xBEEF));
    }

    function test_vault_initializeFinalizer_oneShot() public {
        vm.prank(governance);
        vm.expectRevert(CollateralVaultV2Core.RecoveryFinalizerAlreadyInitialized.selector);
        vault.initializeRecoveryFinalizer(address(0xBEEF));
    }

    /*//////////////////////////////////////////////////////////////
                        READINESS VIEW (bounded, O(N)≤8)
    //////////////////////////////////////////////////////////////*/

    function test_readiness_falseBeforeActivation() public view {
        bytes32 sk = _sk(alice, 1);
        (bool ready,,,) = finalizer.readinessOf(sk);
        assertFalse(ready);
    }

    function test_readiness_trueAfterActivation_zeroPositions_zeroReservations() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        bytes32 sk = _sk(alice, 1);
        (bool ready, RecoveryState state, uint32 count, address firstBlocker) = finalizer.readinessOf(sk);
        assertTrue(ready);
        assertEq(uint8(state), uint8(RecoveryState.RECOVERY_ACTIVE));
        assertEq(count, 0);
        assertEq(firstBlocker, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        DB-LOSS RECONSTRUCTION (Part S)
    //////////////////////////////////////////////////////////////*/

    function test_reconstruction_finalizationOnChainIsAuthoritative() public {
        _fund(alice, 1, 1_000e6);
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.prank(alice);
        finalizer.finalize(1);
        bytes32 sk = _sk(alice, 1);
        // Snapshot canonical values.
        RecoveryState state = escape.recoveryStateOf(sk);
        uint64 finalizedAt = escape.finalizedAt(sk);
        uint256 balance = vault.balanceOf(sk, address(usdc));
        assertEq(uint8(state), uint8(RecoveryState.RECOVERED));
        assertGt(finalizedAt, 0);
        assertEq(balance, 0);
        // A hypothetical indexer restart would rediscover the same
        // values by replaying `RecoveryFinalized` and
        // `RecoveryFinalizationWithdrawn` events + reading views.
        // Duplicate finalization is impossible.
        vm.prank(alice);
        vm.expectRevert();
        finalizer.finalize(1);
    }
}
