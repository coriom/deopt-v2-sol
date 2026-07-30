// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionMatchingEngineV2TestBase} from "./OptionMatchingEngineV2.t.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {OptionExecutionFeeAdapterV2} from "../../../src/hybrid-v2/fees/OptionExecutionFeeAdapterV2.sol";

/// @title OptionFeesIntegrationV1
/// @notice `ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1` — deterministic
///         tests for the concrete fee wiring. Covers:
///           - signed positive-fee cap enforcement (Part E);
///           - fee/rebate Vault accounting conservation (Part M);
///           - reusable-order per-fill fee semantics (Part N);
///           - failed-fee rollback of every lifecycle mutation (Part Q).
///           - concrete adapter constructor validation.
contract OptionFeesIntegrationV1 is OptionMatchingEngineV2TestBase {
    /*//////////////////////////////////////////////////////////////
                        HELPERS + FIXTURES
    //////////////////////////////////////////////////////////////*/

    function _buildFeeCappedMatch(uint32 maxPpm, uint256 buyerNonce, uint256 sellerNonce)
        internal
        view
        returns (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        )
    {
        bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: maxPpm,
            salt: bytes32("fee-b")
        });
        sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: maxPpm,
            salt: bytes32("fee-s")
        });
        bEnv = _makeEnvelope(alice, 1, buyerNonce, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        sEnv = _makeEnvelope(bob, 1, sellerNonce, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bSig = _sign(alicePk, bEnv);
        sSig = _sign(bobPk, sEnv);
    }

    /*//////////////////////////////////////////////////////////////
                    FEE-CAP ENFORCEMENT (Part E)
    //////////////////////////////////////////////////////////////*/

    /// @notice Actual fee below signed cap — accepted; fee accounted to
    ///         protocol subKey.
    function test_feeCap_belowCapAccepted_feeAccountedToProtocol() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        // Fee schedule: 500 bps = 5% = 50_000 ppm; cap 100_000 ppm (10%).
        feeHook.setFees(500, 500);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(100_000, 1, 1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bytes32 protocolSk = vault.protocolFeeVaultSubKey();
        uint256 protocolBefore = vault.balanceOf(protocolSk, address(usdc));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        uint256 protocolAfter = vault.balanceOf(protocolSk, address(usdc));
        // Total protocol credit = buyer fee + seller fee.
        assertGt(protocolAfter, protocolBefore);
    }

    /// @notice Actual fee above signed cap — reverts
    ///         `PositiveFeeRateExceedsSignedMaximum`.
    function test_feeCap_aboveCapReverts() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        // Schedule 100 bps = 10_000 ppm. Cap = 500 ppm. Exceeds cap.
        feeHook.setFees(10_000, 10_000);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(500, 1, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(); // PositiveFeeRateExceedsSignedMaximum with computed args
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice Signed cap = 0 with actual fee = 0 — accepted (rebate-only path).
    function test_feeCap_zeroCapAllowsZeroFee() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        feeHook.setFees(0, 0);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(0, 1, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        // Protocol fee subKey balance unchanged.
        assertEq(vault.balanceOf(vault.protocolFeeVaultSubKey(), address(usdc)), 0);
    }

    /// @notice Signed cap = 0 with actual fee > 0 — reverts.
    function test_feeCap_zeroCapPositiveFeeReverts() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        feeHook.setFees(100, 100); // 1 bps
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(0, 1, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /// @notice Order digest changes when only the signed fee cap changes.
    ///         Direct evidence that fee-cap is bound into `payloadHash`.
    function test_feeCap_digestChangesWithCap() public view {
        OptionOrderTypes.OptionOrder memory low = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 0,
            salt: bytes32("d")
        });
        OptionOrderTypes.OptionOrder memory high = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 5000,
            salt: bytes32("d")
        });
        assertTrue(OptionOrderTypes.hashOrder(low) != OptionOrderTypes.hashOrder(high));
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT ACCOUNTING CONSERVATION (Part M)
    //////////////////////////////////////////////////////////////*/

    /// @notice Total accounted USDC unchanged after fee-charging execution.
    function test_conservation_totalAccountedInvariantHolds() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        feeHook.setFees(200, 100); // taker 200 bps = 20_000 ppm; maker 100 bps = 10_000 ppm
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(50_000, 1, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        uint256 totalBefore = vault.totalAccounted(address(usdc));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        assertEq(vault.totalAccounted(address(usdc)), totalBefore);
    }

    /// @notice Buyer + seller balance sums + protocol balance conserve premium+fee ledger.
    function test_conservation_balanceSumMatchesInitial() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        feeHook.setFees(500, 500); // 500 bps = 50_000 ppm each side
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(100_000, 1, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        bytes32 aliceSk = _sk(alice, 1);
        bytes32 bobSk = _sk(bob, 1);
        bytes32 protocolSk = vault.protocolFeeVaultSubKey();
        uint256 totalUser =
            vault.balanceOf(aliceSk, address(usdc)) + vault.balanceOf(bobSk, address(usdc))
                + vault.balanceOf(protocolSk, address(usdc));
        assertEq(totalUser, 20_000e6);
    }

    /*//////////////////////////////////////////////////////////////
                REUSABLE-ORDER PER-FILL FEE SEMANTICS (Part N)
    //////////////////////////////////////////////////////////////*/

    /// @notice Each fill in a reusable GTC sequence pays fee on its own
    ///         delta, never on the whole signed maximum.
    function test_perFillFee_gtcSequenceChargesEachDelta() public {
        _fund(alice, 1, 100_000e6);
        _fund(bob, 1, 100_000e6);
        feeHook.setFees(1000, 500); // taker 1000 bps = 100_000 ppm; maker 500 bps = 50_000 ppm
        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 10e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 500e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 200_000,
            salt: bytes32("gtc-b-fee")
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
            maxPositiveFeePpm: 200_000,
            salt: bytes32("gtc-s-fee")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(alice, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv =
            _makeEnvelope(bob, 1, 1, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(sOrder));
        bytes memory bSig = _sign(alicePk, bEnv);
        bytes memory sSig = _sign(bobPk, sEnv);

        bytes32 protocolSk = vault.protocolFeeVaultSubKey();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8, ids, ids);
        uint256 afterFirst = vault.balanceOf(protocolSk, address(usdc));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 3e8, ids, ids);
        uint256 afterSecond = vault.balanceOf(protocolSk, address(usdc));
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 4e8, ids, ids);
        uint256 afterThird = vault.balanceOf(protocolSk, address(usdc));

        // Fee on 3 contracts + fee on 3 contracts + fee on 4 contracts.
        uint256 delta1 = afterFirst - 0;
        uint256 delta2 = afterSecond - afterFirst;
        uint256 delta3 = afterThird - afterSecond;
        assertGt(delta1, 0);
        assertEq(delta1, delta2); // same qty → same fee
        assertGt(delta3, 0);
    }

    /*//////////////////////////////////////////////////////////////
                ROLLBACK — fee revert atomicity (Part Q)
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee-cap violation leaves all lifecycle + Vault + ledger
    ///         state unchanged.
    function test_rollback_feeCapExceededPreservesEverything() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        feeHook.setFees(10_000, 10_000); // 100 bps
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(100, 1, 1); // cap 100 ppm
        bytes32 buyerOrderId = engine.hashSignedActionEnvelopeDigest(bEnv);
        uint256 aliceBalBefore = vault.balanceOf(_sk(alice, 1), address(usdc));
        uint256 protocolBefore = vault.balanceOf(vault.protocolFeeVaultSubKey(), address(usdc));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
        assertEq(vault.balanceOf(_sk(alice, 1), address(usdc)), aliceBalBefore);
        assertEq(vault.balanceOf(vault.protocolFeeVaultSubKey(), address(usdc)), protocolBefore);
        assertEq(uint256(engine.filledQuantityOf(buyerOrderId)), 0);
        assertFalse(engine.isOrderCancelled(buyerOrderId));
    }

    /*//////////////////////////////////////////////////////////////
                REBATE ACCOUNTING + BUDGET (Part Q)
    //////////////////////////////////////////////////////////////*/

    /// @notice A configured rebate on the maker path is credited to the
    ///         seller. The rebate budget subKey is debited by the same amount.
    function test_rebate_makerRebateCreditedFromBudget() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        // Fund the rebate budget subKey with ample USDC.
        usdc.mint(rebateBudgetOwner, 1000e6);
        vm.prank(rebateBudgetOwner);
        usdc.approve(address(vault), 1000e6);
        vm.prank(rebateBudgetOwner);
        vault.deposit(1, address(usdc), 1000e6);

        // No positive fees; only maker rebate.
        feeHook.setFees(0, 0);
        feeHook.setMakerRebate(true, 5000); // returns rebate = 5000 (1e8 scale)

        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(10_000, 1, 1);

        bytes32 budgetSk = vault.rebateBudgetSubKey();
        uint256 budgetBefore = vault.balanceOf(budgetSk, address(usdc));
        uint256 bobBefore = vault.balanceOf(_sk(bob, 1), address(usdc));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);

        uint256 budgetAfter = vault.balanceOf(budgetSk, address(usdc));
        uint256 bobAfter = vault.balanceOf(_sk(bob, 1), address(usdc));
        assertLt(budgetAfter, budgetBefore);
        assertEq(budgetBefore - budgetAfter, bobAfter - bobBefore - 100e6); // subtract premium credit
    }

    /// @notice A rebate exceeding the available budget subKey reverts —
    ///         the whole trade fails atomically.
    function test_rebate_insufficientBudgetReverts() public {
        _fund(alice, 1, 10_000e6);
        _fund(bob, 1, 10_000e6);
        // NO funding on the rebate budget subKey.
        feeHook.setFees(0, 0);
        feeHook.setMakerRebate(true, 5000);
        (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        ) = _buildFeeCappedMatch(10_000, 1, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }

    /*//////////////////////////////////////////////////////////////
                CONCRETE ADAPTER — construction validation
    //////////////////////////////////////////////////////////////*/

    function test_adapter_constructor_rejectsZeroDependencies() public {
        vm.expectRevert(OptionExecutionFeeAdapterV2.InvalidDependency.selector);
        new OptionExecutionFeeAdapterV2(address(0), address(vault), address(registry), 6);
        vm.expectRevert(OptionExecutionFeeAdapterV2.InvalidDependency.selector);
        new OptionExecutionFeeAdapterV2(address(0xBEEF), address(0), address(registry), 6);
        vm.expectRevert(OptionExecutionFeeAdapterV2.InvalidDependency.selector);
        new OptionExecutionFeeAdapterV2(address(0xBEEF), address(vault), address(0), 6);
        vm.expectRevert(OptionExecutionFeeAdapterV2.InvalidDependency.selector);
        new OptionExecutionFeeAdapterV2(address(0xBEEF), address(vault), address(registry), 0);
    }
}
