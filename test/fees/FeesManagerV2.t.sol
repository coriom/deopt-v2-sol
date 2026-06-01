// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../src/fees/IFeesManagerV2.sol";

contract FeesManagerV2Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant REBATE_FUNDING_ACCOUNT = address(0xBEEF);
    address internal constant CONSUMER = address(0xC0FFEE);
    address internal constant ALICE = address(0xA1);
    address internal constant SETTLEMENT_ASSET = address(0xCAFE);

    uint256 internal constant VOLUME_28D = 25_000_000e6;
    uint32 internal constant VOLUME_SHARE_PPM = 50_000;
    uint256 internal constant STAKED_DEOPT = 250_000e8;
    uint64 internal constant VALID_FROM = 1_000;
    uint64 internal constant VALID_UNTIL = 2_000;

    FeesManagerV2 internal feesManager;

    event FeeChargedV2(
        address indexed consumer,
        address indexed trader,
        address indexed recipient,
        address settlementAsset,
        uint8 productKind,
        uint8 flowKind,
        bool isMaker,
        int32 feePpm,
        uint256 basisAmount,
        uint256 feeAmount
    );

    event FeeRebatedV2(
        address indexed consumer,
        address indexed trader,
        address indexed recipient,
        address settlementAsset,
        uint8 productKind,
        uint8 flowKind,
        int32 rebatePpm,
        uint256 basisAmount,
        uint256 rebateAmount
    );

    event RebateBudgetSpent(address indexed settlementAsset, uint256 amount);

    function setUp() external {
        vm.warp(VALID_FROM);
        feesManager = new FeesManagerV2(OWNER, FEE_RECIPIENT);
    }

    function testLaunchConstantsAndProductBasisAreCorrect() external view {
        assertEq(feesManager.MAX_TAKER_FEE_PPM(), 1000);
        assertEq(feesManager.MAX_MAKER_REBATE_PPM(), -1000);
        assertEq(feesManager.PPM_DENOMINATOR(), 1_000_000);

        assertEq(
            uint256(feesManager.productFeeBasis(IFeesManagerV2.ProductKind.OPTION)),
            uint256(IFeesManagerV2.FeeBasis.PREMIUM)
        );
        assertEq(
            uint256(feesManager.productFeeBasis(IFeesManagerV2.ProductKind.PERP)),
            uint256(IFeesManagerV2.FeeBasis.NOTIONAL)
        );
    }

    function testFiveTierLaunchSchedulesAreStoredExactly() external view {
        int32[5] memory optionMaker = [int32(50), int32(0), int32(-10), int32(-25), int32(-50)];
        int32[5] memory optionTaker = [int32(250), int32(150), int32(125), int32(100), int32(75)];
        uint32[5] memory optionMakerDiscount =
            [uint32(0), uint32(250_000), uint32(500_000), uint32(750_000), uint32(1_000_000)];
        uint32[5] memory optionTakerDiscount =
            [uint32(0), uint32(100_000), uint32(250_000), uint32(500_000), uint32(750_000)];
        int32[5] memory perpMaker = [int32(50), int32(0), int32(-50), int32(-75), int32(-100)];
        int32[5] memory perpTaker = [int32(300), int32(250), int32(200), int32(175), int32(150)];

        for (uint8 tier; tier < feesManager.TIER_COUNT(); ++tier) {
            IFeesManagerV2.ProductFeeProfilePpm memory optionProfile =
                feesManager.getFeeProfile(tier, IFeesManagerV2.ProductKind.OPTION);
            IFeesManagerV2.ProductFeeProfilePpm memory perpProfile =
                feesManager.getFeeProfile(tier, IFeesManagerV2.ProductKind.PERP);
            IFeesManagerV2.RfqDiscountProfile memory optionRfq =
                feesManager.getRfqDiscountProfile(tier, IFeesManagerV2.ProductKind.OPTION);
            IFeesManagerV2.RfqDiscountProfile memory perpRfq =
                feesManager.getRfqDiscountProfile(tier, IFeesManagerV2.ProductKind.PERP);

            assertEq(optionProfile.makerPpm, optionMaker[tier]);
            assertEq(optionProfile.takerPpm, optionTaker[tier]);
            assertEq(optionRfq.makerDiscountPpm, optionMakerDiscount[tier]);
            assertEq(optionRfq.takerDiscountPpm, optionTakerDiscount[tier]);

            assertEq(perpProfile.makerPpm, perpMaker[tier]);
            assertEq(perpProfile.takerPpm, perpTaker[tier]);
            assertEq(perpRfq.makerDiscountPpm, 0);
            assertEq(perpRfq.takerDiscountPpm, 0);
        }
    }

    function testQuoteOptionsUsesPremiumBasisAndRoundsPositiveFeeUp() external view {
        IFeesManagerV2.FeeQuote memory quote = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, SETTLEMENT_ASSET, 10_000
        );

        assertEq(quote.appliedPpm, 250);
        assertEq(quote.basisAmount, 10_000);
        assertEq(quote.feeAmount, 3);
        assertFalse(quote.isRebate);
        assertEq(quote.tier, 0);
        assertEq(uint256(quote.product), uint256(IFeesManagerV2.ProductKind.OPTION));
        assertEq(uint256(quote.feeBasis), uint256(IFeesManagerV2.FeeBasis.PREMIUM));
        assertEq(quote.recipient, FEE_RECIPIENT);
    }

    function testQuotePerpsUsesNotionalBasis() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        IFeesManagerV2.FeeQuote memory quote = feesManager.quoteFees(
            ALICE,
            IFeesManagerV2.ProductKind.PERP,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            false,
            SETTLEMENT_ASSET,
            1_000_000
        );

        assertEq(quote.appliedPpm, 150);
        assertEq(quote.feeAmount, 150);
        assertFalse(quote.isRebate);
        assertEq(quote.tier, 4);
        assertEq(uint256(quote.product), uint256(IFeesManagerV2.ProductKind.PERP));
        assertEq(uint256(quote.feeBasis), uint256(IFeesManagerV2.FeeBasis.NOTIONAL));
    }

    function testNegativeRebatesRoundDown() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        IFeesManagerV2.FeeQuote memory smallQuote = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, SETTLEMENT_ASSET, 10_000
        );

        assertEq(smallQuote.appliedPpm, -50);
        assertEq(smallQuote.feeAmount, 0);
        assertTrue(smallQuote.isRebate);
        assertEq(smallQuote.recipient, ALICE);

        IFeesManagerV2.FeeQuote memory quote = feesManager.quoteFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_001
        );

        assertEq(quote.appliedPpm, -50);
        assertEq(quote.feeAmount, 50);
        assertTrue(quote.isRebate);
    }

    function testRfqDiscountsReducePositiveFeesOnly() external {
        _claimTier(ALICE, 2, VALID_FROM, VALID_UNTIL);

        IFeesManagerV2.FeeQuote memory taker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, false, SETTLEMENT_ASSET, 1_000_000
        );

        assertEq(taker.appliedPpm, 94);
        assertEq(taker.feeAmount, 94);
        assertFalse(taker.isRebate);

        IFeesManagerV2.FeeQuote memory maker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, true, SETTLEMENT_ASSET, 1_000_000
        );

        assertEq(maker.appliedPpm, -10);
        assertEq(maker.feeAmount, 10);
        assertTrue(maker.isRebate);
    }

    function testOneHundredPercentRfqDiscountFloorsPositiveFeeToZero() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        vm.prank(OWNER);
        feesManager.setFeeProfile(4, IFeesManagerV2.ProductKind.OPTION, 50, 75);

        IFeesManagerV2.FeeQuote memory quote = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, true, SETTLEMENT_ASSET, 1_000_000
        );

        assertEq(quote.appliedPpm, 0);
        assertEq(quote.feeAmount, 0);
        assertFalse(quote.isRebate);
    }

    function testConsumeFeesRequiresAuthorizedConsumer() external {
        vm.expectRevert(abi.encodeWithSelector(FeesManagerV2.NotFeeConsumer.selector, address(this)));
        feesManager.consumeFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, SETTLEMENT_ASSET, 10_000
        );
    }

    function testConsumePositiveFeeEmitsFeeChargedEvent() external {
        _authorizeConsumer();

        vm.expectEmit(true, true, true, true, address(feesManager));
        emit FeeChargedV2(
            CONSUMER,
            ALICE,
            FEE_RECIPIENT,
            SETTLEMENT_ASSET,
            uint8(IFeesManagerV2.ProductKind.OPTION),
            uint8(IFeesManagerV2.FlowKind.ORDERBOOK),
            false,
            250,
            10_000,
            3
        );

        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory quote = feesManager.consumeFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, SETTLEMENT_ASSET, 10_000
        );

        assertEq(quote.feeAmount, 3);
        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 0);
    }

    function testConsumeRebateDecrementsBudgetAndEmitsEvents() external {
        _authorizeConsumer();
        _setRebateFundingAccount();
        _fundBudget(100);
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        vm.expectEmit(true, false, false, true, address(feesManager));
        emit RebateBudgetSpent(SETTLEMENT_ASSET, 50);
        vm.expectEmit(true, true, true, true, address(feesManager));
        emit FeeRebatedV2(
            CONSUMER,
            ALICE,
            ALICE,
            SETTLEMENT_ASSET,
            uint8(IFeesManagerV2.ProductKind.OPTION),
            uint8(IFeesManagerV2.FlowKind.ORDERBOOK),
            -50,
            1_000_000,
            50
        );

        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory quote = feesManager.consumeFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );

        assertEq(quote.feeAmount, 50);
        assertTrue(quote.isRebate);
        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 50);
    }

    function testInsufficientRebateBudgetRevertsStrictly() external {
        _authorizeConsumer();
        _setRebateFundingAccount();
        _fundBudget(49);
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        vm.prank(CONSUMER);
        vm.expectRevert(
            abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, SETTLEMENT_ASSET, 49, 50)
        );
        feesManager.consumeFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );

        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 49);
    }

    function testRebateFundingAccountMustBeSetForNonZeroRebateConsumption() external {
        _authorizeConsumer();
        _fundBudget(100);
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        vm.prank(CONSUMER);
        vm.expectRevert(FeesManagerV2.RebateFundingAccountUnset.selector);
        feesManager.consumeFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );
    }

    function testTierExpiryFallsBackToTier0() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        IFeesManagerV2.FeeQuote memory activeQuote = feesManager.quoteFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );

        assertEq(activeQuote.tier, 4);
        assertEq(activeQuote.appliedPpm, -50);

        vm.warp(VALID_UNTIL + 1);

        IFeesManagerV2.FeeQuote memory expiredQuote = feesManager.quoteFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );

        assertEq(expiredQuote.tier, 0);
        assertEq(expiredQuote.appliedPpm, 50);
        assertFalse(expiredQuote.isRebate);
    }

    function testClaimTierRejectsInvalidProof() external {
        _setSingleLeafRoot(ALICE, 2, VALID_FROM, VALID_UNTIL);

        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.ProofInvalid.selector);
        feesManager.claimTier(
            ALICE, 3, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    function testFeeRecipientMustRemainNonZero() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        feesManager.setFeeRecipient(address(0));
    }

    function testOwnerCanWithdrawAccountingOnlyRebateBudget() external {
        _fundBudget(100);

        vm.prank(OWNER);
        feesManager.withdrawRebateBudget(SETTLEMENT_ASSET, 40, OWNER);

        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 60);
    }

    function _authorizeConsumer() internal {
        vm.prank(OWNER);
        feesManager.setFeeConsumer(CONSUMER, true);
    }

    function _setRebateFundingAccount() internal {
        vm.prank(OWNER);
        feesManager.setRebateFundingAccount(REBATE_FUNDING_ACCOUNT);
    }

    function _fundBudget(uint256 amount) internal {
        vm.prank(OWNER);
        feesManager.fundRebateBudget(SETTLEMENT_ASSET, amount);
    }

    function _claimTier(address account, uint8 tier, uint64 validFrom, uint64 validUntil) internal {
        _setSingleLeafRoot(account, tier, validFrom, validUntil);

        vm.prank(account);
        feesManager.claimTier(
            account, tier, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, validFrom, validUntil, new bytes32[](0)
        );
    }

    function _setSingleLeafRoot(address account, uint8 tier, uint64 validFrom, uint64 validUntil) internal {
        bytes32 root =
            feesManager.hashTierLeaf(account, tier, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, validFrom, validUntil);

        vm.prank(OWNER);
        feesManager.setMerkleRoot(root, validFrom, validUntil);
    }

    /*//////////////////////////////////////////////////////////////
                V2G-N — exhaustive RFQ fee discount coverage
    //////////////////////////////////////////////////////////////*/

    // Canonical OPTION RFQ effective taker ppm per tier, basis = 1_000_000.
    // Derivation: ceil(takerPpm * (1 - takerDiscountPpm / 1_000_000)).
    //   Tier 0: 250  * (1 - 0    )       = 250
    //   Tier 1: 150  * (1 - 0.10 ) = 135.00 -> 135
    //   Tier 2: 125  * (1 - 0.25 ) = 93.75  -> 94 (ceil)
    //   Tier 3: 100  * (1 - 0.50 ) = 50.00  -> 50
    //   Tier 4: 75   * (1 - 0.75 ) = 18.75  -> 19 (ceil)
    function testV2GN_OptionRfqTakerTableWalk() external {
        int32[5] memory expectedOrderbookTaker = [int32(250), int32(150), int32(125), int32(100), int32(75)];
        int32[5] memory expectedRfqTaker = [int32(250), int32(135), int32(94), int32(50), int32(19)];

        for (uint8 tier; tier < feesManager.TIER_COUNT(); ++tier) {
            address trader = address(uint160(0xD000 + uint160(tier)));
            // Tier 0 is the default — no claim needed; other tiers need a tier proof.
            if (tier != 0) {
                _claimTier(trader, tier, VALID_FROM, VALID_UNTIL);
            }

            IFeesManagerV2.FeeQuote memory orderbook = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.OPTION,
                IFeesManagerV2.FlowKind.ORDERBOOK,
                false,
                SETTLEMENT_ASSET,
                1_000_000
            );
            assertEq(orderbook.appliedPpm, expectedOrderbookTaker[tier], "orderbook taker ppm");
            assertFalse(orderbook.isRebate, "orderbook taker is fee");

            IFeesManagerV2.FeeQuote memory rfq = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.OPTION,
                IFeesManagerV2.FlowKind.RFQ,
                false,
                SETTLEMENT_ASSET,
                1_000_000
            );
            assertEq(rfq.appliedPpm, expectedRfqTaker[tier], "rfq taker ppm");
            assertFalse(rfq.isRebate, "rfq taker is fee");
        }
    }

    // Canonical OPTION RFQ effective maker ppm per tier. The Design-Option-A
    // semantics: discount only applies when `ratePpm > 0`. Negative maker
    // rebates pass through unchanged regardless of discount.
    //   Tier 0: +50  * (1 - 0   )         = 50
    //   Tier 1:   0  (no rebate, no fee — discount touches nothing)
    //   Tier 2: -10  (negative, RFQ discount NOT applied, preserved)
    //   Tier 3: -25  (negative, preserved)
    //   Tier 4: -50  (negative, preserved — even at 100 % discount)
    function testV2GN_OptionRfqMakerPreservesNegativeRebatesEvenAtHundredPercentDiscount() external {
        int32[5] memory expectedOrderbookMaker = [int32(50), int32(0), int32(-10), int32(-25), int32(-50)];
        int32[5] memory expectedRfqMaker = [int32(50), int32(0), int32(-10), int32(-25), int32(-50)];
        bool[5] memory expectedIsRebate = [false, false, true, true, true];

        for (uint8 tier; tier < feesManager.TIER_COUNT(); ++tier) {
            address trader = address(uint160(0xE000 + uint160(tier)));
            if (tier != 0) {
                _claimTier(trader, tier, VALID_FROM, VALID_UNTIL);
            }

            IFeesManagerV2.FeeQuote memory orderbook = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.OPTION,
                IFeesManagerV2.FlowKind.ORDERBOOK,
                true,
                SETTLEMENT_ASSET,
                1_000_000
            );
            assertEq(orderbook.appliedPpm, expectedOrderbookMaker[tier], "orderbook maker ppm");
            assertEq(orderbook.isRebate, expectedIsRebate[tier], "orderbook maker rebate flag");

            IFeesManagerV2.FeeQuote memory rfq = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.OPTION,
                IFeesManagerV2.FlowKind.RFQ,
                true,
                SETTLEMENT_ASSET,
                1_000_000
            );
            assertEq(rfq.appliedPpm, expectedRfqMaker[tier], "rfq maker ppm");
            assertEq(rfq.isRebate, expectedIsRebate[tier], "rfq maker rebate flag");
        }
    }

    // Tier 4 — the most aggressive — under the CANONICAL launch schedule.
    // RFQ maker discount is 100 % but maker ppm is -50 (rebate). Design
    // Option A says: 100 % discount must not amplify the rebate, must not
    // flip the rebate to a fee, and must not silently zero it. The maker
    // rebate stays at -50 ppm. Tier 4 RFQ taker discount is 75 %, so
    // taker = 75 ppm * 0.25 = 18.75 → ceil to 19 ppm.
    function testV2GN_OptionRfqTier4HundredPercentMakerDiscountKeepsRebateUnchanged() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        IFeesManagerV2.FeeQuote memory maker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, true, SETTLEMENT_ASSET, 1_000_000
        );
        // Design-Option-A: negative ppm is the rebate side; discount untouched.
        assertEq(maker.appliedPpm, -50, "tier 4 RFQ maker stays at canonical rebate ppm");
        assertTrue(maker.isRebate, "tier 4 RFQ maker is rebate");
        // floor(1_000_000 * 50 / 1_000_000) = 50 native units.
        assertEq(maker.feeAmount, 50, "tier 4 RFQ maker rebate amount unchanged");

        IFeesManagerV2.FeeQuote memory taker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, false, SETTLEMENT_ASSET, 1_000_000
        );
        assertEq(taker.appliedPpm, 19, "tier 4 RFQ taker = ceil(75 * 25%)");
        assertFalse(taker.isRebate, "tier 4 RFQ taker is fee");
        // ceil(1_000_000 * 19 / 1_000_000) = 19.
        assertEq(taker.feeAmount, 19, "tier 4 RFQ taker fee amount");
    }

    // Tier 0 — the base tier — has 0 % RFQ discount on both legs by design.
    // RFQ ppm must equal ORDERBOOK ppm for both maker and taker. This is
    // the "RFQ at base tier is identical to ORDERBOOK" invariant.
    function testV2GN_OptionRfqTier0EqualsOrderbookForBothLegs() external view {
        IFeesManagerV2.FeeQuote memory orderbookTaker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, SETTLEMENT_ASSET, 12_345
        );
        IFeesManagerV2.FeeQuote memory rfqTaker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, false, SETTLEMENT_ASSET, 12_345
        );
        assertEq(rfqTaker.appliedPpm, orderbookTaker.appliedPpm, "tier 0 taker rfq == orderbook ppm");
        assertEq(rfqTaker.feeAmount, orderbookTaker.feeAmount, "tier 0 taker rfq == orderbook amount");

        IFeesManagerV2.FeeQuote memory orderbookMaker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, SETTLEMENT_ASSET, 12_345
        );
        IFeesManagerV2.FeeQuote memory rfqMaker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, true, SETTLEMENT_ASSET, 12_345
        );
        assertEq(rfqMaker.appliedPpm, orderbookMaker.appliedPpm, "tier 0 maker rfq == orderbook ppm");
        assertEq(rfqMaker.feeAmount, orderbookMaker.feeAmount, "tier 0 maker rfq == orderbook amount");
    }

    // PERP RFQ discounts default to 0 % across every tier. The RFQ flow
    // must therefore return the same ppm as ORDERBOOK for both legs and
    // every tier — i.e. RFQ for PERP is supported on the interface but
    // has no fee impact today. This pins the V2G-N invariant.
    function testV2GN_PerpRfqUnaffectedAtEveryTierForBothLegs() external {
        for (uint8 tier; tier < feesManager.TIER_COUNT(); ++tier) {
            address trader = address(uint160(0xF000 + uint160(tier)));
            if (tier != 0) {
                _claimTier(trader, tier, VALID_FROM, VALID_UNTIL);
            }

            // Maker leg.
            IFeesManagerV2.FeeQuote memory ob = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.PERP,
                IFeesManagerV2.FlowKind.ORDERBOOK,
                true,
                SETTLEMENT_ASSET,
                1_000_000
            );
            IFeesManagerV2.FeeQuote memory rfq = feesManager.quoteFees(
                trader, IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.RFQ, true, SETTLEMENT_ASSET, 1_000_000
            );
            assertEq(rfq.appliedPpm, ob.appliedPpm, "perp maker rfq ppm == orderbook");

            // Taker leg.
            ob = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.PERP,
                IFeesManagerV2.FlowKind.ORDERBOOK,
                false,
                SETTLEMENT_ASSET,
                1_000_000
            );
            rfq = feesManager.quoteFees(
                trader, IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.RFQ, false, SETTLEMENT_ASSET, 1_000_000
            );
            assertEq(rfq.appliedPpm, ob.appliedPpm, "perp taker rfq ppm == orderbook");
        }
    }

    // OPTION ORDERBOOK ppm must remain unchanged across every tier for
    // both legs even after V2G-N (the RFQ work is strictly additive on
    // the discount layer; the underlying profile lookup is untouched).
    function testV2GN_OptionOrderbookUnchangedForEveryTier() external {
        int32[5] memory expectedMaker = [int32(50), int32(0), int32(-10), int32(-25), int32(-50)];
        int32[5] memory expectedTaker = [int32(250), int32(150), int32(125), int32(100), int32(75)];

        for (uint8 tier; tier < feesManager.TIER_COUNT(); ++tier) {
            address trader = address(uint160(0xC000 + uint160(tier)));
            if (tier != 0) {
                _claimTier(trader, tier, VALID_FROM, VALID_UNTIL);
            }
            IFeesManagerV2.FeeQuote memory maker = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.OPTION,
                IFeesManagerV2.FlowKind.ORDERBOOK,
                true,
                SETTLEMENT_ASSET,
                1_000_000
            );
            IFeesManagerV2.FeeQuote memory taker = feesManager.quoteFees(
                trader,
                IFeesManagerV2.ProductKind.OPTION,
                IFeesManagerV2.FlowKind.ORDERBOOK,
                false,
                SETTLEMENT_ASSET,
                1_000_000
            );
            assertEq(maker.appliedPpm, expectedMaker[tier], "option orderbook maker ppm");
            assertEq(taker.appliedPpm, expectedTaker[tier], "option orderbook taker ppm");
        }
    }

    // Invariant pin: for any ratePpm <= 0 (rebate or zero), the RFQ flow
    // MUST return the same ppm as ORDERBOOK regardless of which OPTION
    // discount profile is installed. The contract refuses to discount
    // negative ppm — this is the Design-Option-A safety net.
    function testV2GN_RfqDiscountIgnoresNegativeOrZeroPpm() external {
        // Install an aggressive maker discount on Tier 0 (the trader's
        // default tier). Without the contract's "ratePpm <= 0" early
        // return, this would amplify rebates.
        vm.prank(OWNER);
        feesManager.setRfqDiscountProfile(0, IFeesManagerV2.ProductKind.OPTION, 1_000_000, 0);

        // Force the maker profile to negative so the discount path
        // sees a negative ratePpm.
        vm.prank(OWNER);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, -25, 250);

        IFeesManagerV2.FeeQuote memory maker = feesManager.quoteFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.RFQ, true, SETTLEMENT_ASSET, 1_000_000
        );
        // Maker rebate stays at -25 ppm despite the 100% maker discount
        // — Design-Option-A safety net.
        assertEq(maker.appliedPpm, -25, "negative maker ppm not affected by RFQ discount");
        assertTrue(maker.isRebate);
    }

    // Sanity: setting both discount legs to PPM_DENOMINATOR + 1 reverts
    // with InvalidDiscount. The contract refuses to install an
    // overflow-shaped discount.
    function testV2GN_RfqDiscountSetterRejectsOverflow() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidDiscount.selector);
        feesManager.setRfqDiscountProfile(0, IFeesManagerV2.ProductKind.OPTION, 1_000_001, 0);

        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidDiscount.selector);
        feesManager.setRfqDiscountProfile(0, IFeesManagerV2.ProductKind.OPTION, 0, 1_000_001);
    }

    /*//////////////////////////////////////////////////////////////
        V2G-Q — tier schedule + Merkle root behavior matrix
    //////////////////////////////////////////////////////////////*/

    // Per-tier OPTION + PERP profile canonicalization. If any of these
    // numbers ever change, V2G-N / V2G-O / V2G-P0 reference tables in
    // docs must change in lockstep.
    function testV2GQ_AllFiveTierProfilesAreCanonical() external view {
        int32[5] memory expectedOptionMaker = [int32(50), int32(0), int32(-10), int32(-25), int32(-50)];
        int32[5] memory expectedOptionTaker = [int32(250), int32(150), int32(125), int32(100), int32(75)];
        int32[5] memory expectedPerpMaker = [int32(50), int32(0), int32(-50), int32(-75), int32(-100)];
        int32[5] memory expectedPerpTaker = [int32(300), int32(250), int32(200), int32(175), int32(150)];
        uint32[5] memory expectedOptionMakerRfq =
            [uint32(0), uint32(250_000), uint32(500_000), uint32(750_000), uint32(1_000_000)];
        uint32[5] memory expectedOptionTakerRfq =
            [uint32(0), uint32(100_000), uint32(250_000), uint32(500_000), uint32(750_000)];

        for (uint8 tier; tier < feesManager.TIER_COUNT(); ++tier) {
            IFeesManagerV2.ProductFeeProfilePpm memory option =
                feesManager.getFeeProfile(tier, IFeesManagerV2.ProductKind.OPTION);
            assertEq(option.makerPpm, expectedOptionMaker[tier], "option makerPpm drift");
            assertEq(option.takerPpm, expectedOptionTaker[tier], "option takerPpm drift");

            IFeesManagerV2.ProductFeeProfilePpm memory perp =
                feesManager.getFeeProfile(tier, IFeesManagerV2.ProductKind.PERP);
            assertEq(perp.makerPpm, expectedPerpMaker[tier], "perp makerPpm drift");
            assertEq(perp.takerPpm, expectedPerpTaker[tier], "perp takerPpm drift");

            IFeesManagerV2.RfqDiscountProfile memory rfq =
                feesManager.getRfqDiscountProfile(tier, IFeesManagerV2.ProductKind.OPTION);
            assertEq(rfq.makerDiscountPpm, expectedOptionMakerRfq[tier], "option RFQ maker discount drift");
            assertEq(rfq.takerDiscountPpm, expectedOptionTakerRfq[tier], "option RFQ taker discount drift");

            IFeesManagerV2.RfqDiscountProfile memory perpRfq =
                feesManager.getRfqDiscountProfile(tier, IFeesManagerV2.ProductKind.PERP);
            assertEq(perpRfq.makerDiscountPpm, 0, "perp RFQ discount maker must be zero");
            assertEq(perpRfq.takerDiscountPpm, 0, "perp RFQ discount taker must be zero");
        }
    }

    // Threshold OR-logic — the contract is value-agnostic and accepts
    // ANY leaf published in the Merkle tree. The off-chain operator can
    // therefore publish three sibling leaves for the same (account,
    // tier): one earned by volume28d, one by volumeSharePpm, one by
    // stakedDeopt. The user picks whichever proof corresponds to the
    // path they satisfy. We pin that all three leaves verify against
    // the same root.
    function testV2GQ_VolumeOrShareOrStakedThresholdLeavesAllVerify() external {
        uint8 tier = 3;
        bytes32 leafVolume = feesManager.hashTierLeaf(ALICE, tier, 25_000_000e6, 0, 0, VALID_FROM, VALID_UNTIL);
        bytes32 leafShare = feesManager.hashTierLeaf(ALICE, tier, 0, 50_000, 0, VALID_FROM, VALID_UNTIL);
        bytes32 leafStaked = feesManager.hashTierLeaf(ALICE, tier, 0, 0, 250_000e8, VALID_FROM, VALID_UNTIL);

        // Build the 3-leaf Merkle tree manually. We need a fixed
        // ordering compatible with OZ {MerkleProof.verifyCalldata},
        // which uses commutative pair hashing.
        (bytes32 root, bytes32[][3] memory proofs) = _build3LeafTreeAndProofs(leafVolume, leafShare, leafStaked);

        vm.prank(OWNER);
        feesManager.setMerkleRoot(root, VALID_FROM, VALID_UNTIL);

        // Claim via the "volume" leaf.
        vm.prank(ALICE);
        feesManager.claimTier(ALICE, tier, 25_000_000e6, 0, 0, VALID_FROM, VALID_UNTIL, proofs[0]);
        assertEq(feesManager.currentTier(ALICE), tier, "volume-leaf claim must set tier");

        // Re-claim via the "share" leaf (same tier). Should succeed.
        vm.prank(ALICE);
        feesManager.claimTier(ALICE, tier, 0, 50_000, 0, VALID_FROM, VALID_UNTIL, proofs[1]);
        assertEq(feesManager.currentTier(ALICE), tier, "share-leaf claim must set tier");

        // Re-claim via the "staked" leaf (same tier).
        vm.prank(ALICE);
        feesManager.claimTier(ALICE, tier, 0, 0, 250_000e8, VALID_FROM, VALID_UNTIL, proofs[2]);
        assertEq(feesManager.currentTier(ALICE), tier, "staked-leaf claim must set tier");
    }

    // Boundary semantics — contract enforces leaf equality, not
    // numeric thresholds. A leaf published with metrics
    // (vol=25M, share=50_000, staked=250_000e8) verifies; any tuple
    // that differs by even one wei fails with ProofInvalid.
    function testV2GQ_ExactThresholdBoundaryAcceptsLeafExactly() external {
        _setSingleLeafRoot(ALICE, 2, VALID_FROM, VALID_UNTIL);

        // Exact-match metrics succeed.
        vm.prank(ALICE);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
        assertEq(feesManager.currentTier(ALICE), 2);
    }

    function testV2GQ_BelowThresholdMetricsFailWithProofInvalid() external {
        _setSingleLeafRoot(ALICE, 2, VALID_FROM, VALID_UNTIL);

        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.ProofInvalid.selector);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D - 1, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    function testV2GQ_AboveThresholdMetricsAlsoFailWithProofInvalid() external {
        // The contract is value-agnostic: an above-threshold tuple is
        // still a wrong leaf if it wasn't published. Pins that the
        // contract does not do range-comparison.
        _setSingleLeafRoot(ALICE, 2, VALID_FROM, VALID_UNTIL);

        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.ProofInvalid.selector);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D + 1, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    // Expired claim — currentTier falls back to 0 after validUntil.
    // Pinned separately from the existing
    // testTierExpiryFallsBackToTier0 because the V2G-Q matrix asks for
    // it as a row.
    function testV2GQ_ExpiredClaimFallsBackToTier0() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 4);

        vm.warp(VALID_UNTIL + 1);
        assertEq(feesManager.currentTier(ALICE), 0, "post-validUntil tier must be 0");
    }

    // claimTier itself reverts with TierExpired once block.timestamp
    // has passed validUntil — even with a still-valid root.
    function testV2GQ_ClaimAfterValidUntilRevertsWithTierExpired() external {
        _setSingleLeafRoot(ALICE, 4, VALID_FROM, VALID_UNTIL);
        vm.warp(VALID_UNTIL + 1);

        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.TierExpired.selector);
        feesManager.claimTier(
            ALICE, 4, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    // claimTier reverts with TierNotYetValid before validFrom.
    function testV2GQ_ClaimBeforeValidFromRevertsWithTierNotYetValid() external {
        uint64 futureFrom = VALID_FROM + 100;
        uint64 futureUntil = futureFrom + 100;
        _setSingleLeafRoot(ALICE, 4, futureFrom, futureUntil);

        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.TierNotYetValid.selector);
        feesManager.claimTier(
            ALICE, 4, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, futureFrom, futureUntil, new bytes32[](0)
        );
    }

    // Replay — claiming the same (account, tier, metrics, window)
    // twice is allowed (the contract overwrites the same slot). The
    // tier remains the same. This is intentional so an operator can
    // re-publish a root and let users re-claim if storage was lost or
    // the root was rotated.
    function testV2GQ_ReplayOfSameClaimOverwritesIdempotently() external {
        _claimTier(ALICE, 3, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 3);

        // Re-claim the same leaf — should not revert.
        vm.prank(ALICE);
        feesManager.claimTier(
            ALICE, 3, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
        assertEq(feesManager.currentTier(ALICE), 3, "replay must keep the same tier");
    }

    // Upgrade — the operator publishes a new root with Alice at tier 4
    // (was tier 2). After Alice claims, currentTier returns 4.
    function testV2GQ_UpgradeClaimRaisesTier() external {
        _claimTier(ALICE, 2, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 2);

        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 4, "upgrade must raise the tier");
    }

    // Downgrade — the operator publishes a new root with Alice at
    // tier 1 (was tier 4). The contract does NOT refuse downgrades:
    // the tier reflects the most recently claimed leaf. This is
    // intentional so an operator can demote on policy violation.
    function testV2GQ_DowngradeClaimLowersTier() external {
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 4);

        _claimTier(ALICE, 1, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 1, "downgrade must lower the tier");
    }

    // Root rotation — setMerkleRoot with a new root invalidates any
    // proof against the old root. The previously-claimed tier however
    // persists (claimedTiers is independent of the live root).
    function testV2GQ_RootRotationKeepsExistingClaimButInvalidatesOldProofs() external {
        _claimTier(ALICE, 3, VALID_FROM, VALID_UNTIL);
        assertEq(feesManager.currentTier(ALICE), 3);

        // Rotate to a different root that does NOT include Alice's leaf.
        bytes32 newRoot = feesManager.hashTierLeaf(
            address(0xB0B), 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL
        );
        vm.prank(OWNER);
        feesManager.setMerkleRoot(newRoot, VALID_FROM, VALID_UNTIL);

        // Alice's existing tier still reflects her prior claim.
        assertEq(feesManager.currentTier(ALICE), 3, "rotation must not retroactively clear claimed tiers");

        // But re-claiming with the OLD leaf shape under the NEW root fails.
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.ProofInvalid.selector);
        feesManager.claimTier(
            ALICE, 3, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    // Root validity window — setting a root with rootValidFrom in the
    // future causes claimTier to revert with TierNotYetValid even when
    // the leaf's own validFrom has elapsed.
    function testV2GQ_RootValidFromGatesClaimsAcrossWindow() external {
        bytes32 leafRoot =
            feesManager.hashTierLeaf(ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL);

        uint64 futureRootFrom = uint64(block.timestamp) + 500;
        vm.prank(OWNER);
        feesManager.setMerkleRoot(leafRoot, futureRootFrom, VALID_UNTIL);

        // Before rootValidFrom — TierNotYetValid even though leaf's
        // own window has begun.
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.TierNotYetValid.selector);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );

        // After rootValidFrom — claim succeeds.
        vm.warp(futureRootFrom);
        vm.prank(ALICE);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
        assertEq(feesManager.currentTier(ALICE), 2);
    }

    function testV2GQ_RootValidUntilGatesClaimsAcrossWindow() external {
        bytes32 leafRoot = feesManager.hashTierLeaf(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, type(uint64).max
        );

        uint64 rootUntil = uint64(block.timestamp) + 100;
        vm.prank(OWNER);
        feesManager.setMerkleRoot(leafRoot, VALID_FROM, rootUntil);

        vm.warp(rootUntil + 1);

        // Past rootValidUntil — TierExpired even though leaf's
        // own validUntil is far in the future.
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.TierExpired.selector);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, type(uint64).max, new bytes32[](0)
        );
    }

    // setMerkleRoot rejects validFrom > validUntil (non-zero) with
    // InvalidMerkleRootWindow.
    function testV2GQ_SetMerkleRootRejectsInvertedWindow() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidMerkleRootWindow.selector);
        feesManager.setMerkleRoot(bytes32(uint256(1)), VALID_UNTIL, VALID_FROM);
    }

    // claimTier with a non-account caller (msg.sender != account)
    // reverts with NotAccount even with a valid proof.
    function testV2GQ_ClaimTierRejectsThirdPartyCaller() external {
        _setSingleLeafRoot(ALICE, 2, VALID_FROM, VALID_UNTIL);

        vm.prank(address(0xB0B));
        vm.expectRevert(FeesManagerV2.NotAccount.selector);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    // claimTier with no merkle root configured reverts with NoMerkleRoot.
    function testV2GQ_ClaimTierWithNoRootRevertsWithNoMerkleRoot() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NoMerkleRoot.selector);
        feesManager.claimTier(
            ALICE, 2, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    // claimTier with tier >= TIER_COUNT reverts with InvalidTier.
    function testV2GQ_ClaimTierRejectsOutOfRangeTier() external {
        _setSingleLeafRoot(ALICE, 0, VALID_FROM, VALID_UNTIL);
        uint8 outOfRange = feesManager.TIER_COUNT();

        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.InvalidTier.selector);
        feesManager.claimTier(
            ALICE, outOfRange, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    // Helper that hashes three leaves into a tree compatible with
    // {OpenZeppelin MerkleProof.verifyCalldata}. The OZ verifier uses
    // commutative pair hashing (smaller bytes32 first), so we mirror
    // that here.
    function _build3LeafTreeAndProofs(bytes32 a, bytes32 b, bytes32 c)
        internal
        pure
        returns (bytes32 root, bytes32[][3] memory proofs)
    {
        bytes32 ab = _hashPair(a, b);
        // Layer 1 has [ab, c]. Layer 2 hashes them. Standard OZ-shaped
        // tree where odd nodes promote unchanged at higher levels is
        // *not* used — instead we explicitly pair `c` against `ab`.
        root = _hashPair(ab, c);

        // Proof for `a`: needs sibling `b` to make `ab`, then sibling `c`.
        proofs[0] = new bytes32[](2);
        proofs[0][0] = b;
        proofs[0][1] = c;

        // Proof for `b`: needs sibling `a`, then sibling `c`.
        proofs[1] = new bytes32[](2);
        proofs[1][0] = a;
        proofs[1][1] = c;

        // Proof for `c`: needs sibling `ab`.
        proofs[2] = new bytes32[](1);
        proofs[2][0] = ab;
    }

    function _hashPair(bytes32 x, bytes32 y) private pure returns (bytes32) {
        return x < y ? keccak256(abi.encodePacked(x, y)) : keccak256(abi.encodePacked(y, x));
    }

    /*//////////////////////////////////////////////////////////////
        V2G-R2 — admin / setter / consumer / budget behavior matrix
    //////////////////////////////////////////////////////////////*/

    // Reused event signatures for vm.expectEmit. Mirror IFeesManagerV2.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FeeRecipientSet(address indexed oldRecipient, address indexed newRecipient);
    event RebateFundingAccountSet(address indexed oldAccount, address indexed newAccount);
    event FeeConsumerSet(address indexed consumer, bool allowed);
    event FeeProfileUpdated(uint8 indexed tier, uint8 indexed product, int32 makerPpm, int32 takerPpm);
    event RfqDiscountProfileUpdated(
        uint8 indexed tier, uint8 indexed product, uint32 makerDiscountPpm, uint32 takerDiscountPpm
    );
    event RebateBudgetFunded(address indexed settlementAsset, uint256 amount);
    event RebateBudgetWithdrawn(address indexed settlementAsset, address indexed to, uint256 amount);

    /* -------------------- setFeeRecipient -------------------- */

    function testV2GR2_SetFeeRecipientRejectsZero() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        feesManager.setFeeRecipient(address(0));
    }

    function testV2GR2_SetFeeRecipientRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.setFeeRecipient(address(0xDEAD));
    }

    function testV2GR2_SetFeeRecipientUpdatesAndEmits() external {
        vm.expectEmit(true, true, false, false, address(feesManager));
        emit FeeRecipientSet(FEE_RECIPIENT, address(0xDEAD));

        vm.prank(OWNER);
        feesManager.setFeeRecipient(address(0xDEAD));
        assertEq(feesManager.feeRecipient(), address(0xDEAD));
    }

    /* -------------------- setRebateFundingAccount -------------------- */

    function testV2GR2_SetRebateFundingAccountAcceptsZeroToDisable() external {
        // Contract intentionally allows zero — used to disable
        // non-zero rebate consumption (per FM-V2 NatSpec).
        vm.expectEmit(true, true, false, false, address(feesManager));
        emit RebateFundingAccountSet(address(0), address(0));

        vm.prank(OWNER);
        feesManager.setRebateFundingAccount(address(0));
        assertEq(feesManager.rebateFundingAccount(), address(0));
    }

    function testV2GR2_SetRebateFundingAccountAcceptsNonZero() external {
        vm.expectEmit(true, true, false, false, address(feesManager));
        emit RebateFundingAccountSet(address(0), REBATE_FUNDING_ACCOUNT);

        vm.prank(OWNER);
        feesManager.setRebateFundingAccount(REBATE_FUNDING_ACCOUNT);
        assertEq(feesManager.rebateFundingAccount(), REBATE_FUNDING_ACCOUNT);
    }

    function testV2GR2_SetRebateFundingAccountRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.setRebateFundingAccount(REBATE_FUNDING_ACCOUNT);
    }

    /* -------------------- setFeeConsumer -------------------- */

    function testV2GR2_SetFeeConsumerEnableDisableCycle() external {
        assertFalse(feesManager.isFeeConsumer(CONSUMER));

        vm.expectEmit(true, false, false, true, address(feesManager));
        emit FeeConsumerSet(CONSUMER, true);
        vm.prank(OWNER);
        feesManager.setFeeConsumer(CONSUMER, true);
        assertTrue(feesManager.isFeeConsumer(CONSUMER));

        vm.expectEmit(true, false, false, true, address(feesManager));
        emit FeeConsumerSet(CONSUMER, false);
        vm.prank(OWNER);
        feesManager.setFeeConsumer(CONSUMER, false);
        assertFalse(feesManager.isFeeConsumer(CONSUMER));
    }

    function testV2GR2_SetFeeConsumerRejectsZero() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        feesManager.setFeeConsumer(address(0), true);
    }

    function testV2GR2_SetFeeConsumerRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.setFeeConsumer(CONSUMER, true);
    }

    /* -------------------- consumeFees authorization -------------------- */

    function testV2GR2_ConsumeFeesRejectsUnauthorizedCaller() external {
        // No setFeeConsumer call — default is false.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FeesManagerV2.NotFeeConsumer.selector, ALICE));
        feesManager.consumeFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, SETTLEMENT_ASSET, 1_000
        );
    }

    function testV2GR2_ConsumeFeesAcceptsAuthorizedCaller() external {
        _authorizeConsumer();
        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory quote = feesManager.consumeFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, SETTLEMENT_ASSET, 10_000
        );
        // Tier-0 OPTION taker = 250 ppm; ceil(10_000 * 250 / 1e6) = 3.
        assertEq(quote.feeAmount, 3);
        assertEq(quote.appliedPpm, 250);
        assertFalse(quote.isRebate);
        assertEq(quote.recipient, FEE_RECIPIENT);
    }

    /* -------------------- consumeFees positive maker / taker paths -------------------- */

    function testV2GR2_ConsumePositiveMakerFeeAtTier0() external {
        // Tier-0 OPTION makerPpm = 50. ceil(10_000 * 50 / 1e6) = 1.
        _authorizeConsumer();
        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory quote = feesManager.consumeFees(
            ALICE, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, SETTLEMENT_ASSET, 10_000
        );
        assertEq(quote.appliedPpm, 50);
        assertEq(quote.feeAmount, 1);
        assertFalse(quote.isRebate);
        assertEq(quote.recipient, FEE_RECIPIENT);
    }

    function testV2GR2_ConsumePositiveTakerFeeAtTier0() external {
        _authorizeConsumer();
        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory quote = feesManager.consumeFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            false,
            SETTLEMENT_ASSET,
            1_000_000
        );
        assertEq(quote.appliedPpm, 250);
        assertEq(quote.feeAmount, 250);
        assertEq(quote.recipient, FEE_RECIPIENT);
    }

    /* -------------------- consumeFees rebate paths -------------------- */

    function testV2GR2_ConsumeNegativeMakerRebateDecreasesBudget() external {
        _authorizeConsumer();
        _setRebateFundingAccount();
        _fundBudget(100);
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        // Tier-4 OPTION makerPpm = -50. floor(1_000_000 * 50 / 1e6) = 50.
        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory quote = feesManager.consumeFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );

        assertEq(quote.appliedPpm, -50);
        assertEq(quote.feeAmount, 50);
        assertTrue(quote.isRebate);
        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 50);
    }

    function testV2GR2_ConsumeRebateInsufficientBudgetReverts() external {
        _authorizeConsumer();
        _setRebateFundingAccount();
        _fundBudget(1); // budget far below rebate amount
        _claimTier(ALICE, 4, VALID_FROM, VALID_UNTIL);

        vm.prank(CONSUMER);
        vm.expectRevert(
            abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, SETTLEMENT_ASSET, 1, 50)
        );
        feesManager.consumeFees(
            ALICE,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            SETTLEMENT_ASSET,
            1_000_000
        );
    }

    /* -------------------- fundRebateBudget -------------------- */

    function testV2GR2_FundRebateBudgetAccountingAndEvent() external {
        vm.expectEmit(true, false, false, true, address(feesManager));
        emit RebateBudgetFunded(SETTLEMENT_ASSET, 1_000);

        vm.prank(OWNER);
        feesManager.fundRebateBudget(SETTLEMENT_ASSET, 1_000);
        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 1_000);

        // Second top-up sums.
        vm.prank(OWNER);
        feesManager.fundRebateBudget(SETTLEMENT_ASSET, 500);
        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 1_500);
    }

    function testV2GR2_FundRebateBudgetRejectsZeroAsset() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        feesManager.fundRebateBudget(address(0), 1_000);
    }

    function testV2GR2_FundRebateBudgetRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.fundRebateBudget(SETTLEMENT_ASSET, 1_000);
    }

    /* -------------------- withdrawRebateBudget -------------------- */

    function testV2GR2_WithdrawRebateBudgetDecreasesAndEmits() external {
        _fundBudget(200);

        vm.expectEmit(true, true, false, true, address(feesManager));
        emit RebateBudgetWithdrawn(SETTLEMENT_ASSET, ALICE, 80);

        vm.prank(OWNER);
        feesManager.withdrawRebateBudget(SETTLEMENT_ASSET, 80, ALICE);
        assertEq(feesManager.rebateBudget(SETTLEMENT_ASSET), 120);
    }

    function testV2GR2_WithdrawRebateBudgetRejectsOverBudget() external {
        _fundBudget(50);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, SETTLEMENT_ASSET, 50, 60)
        );
        feesManager.withdrawRebateBudget(SETTLEMENT_ASSET, 60, ALICE);
    }

    function testV2GR2_WithdrawRebateBudgetRejectsZeroAsset() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        feesManager.withdrawRebateBudget(address(0), 1, ALICE);
    }

    function testV2GR2_WithdrawRebateBudgetRejectsZeroTo() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        feesManager.withdrawRebateBudget(SETTLEMENT_ASSET, 1, address(0));
    }

    function testV2GR2_WithdrawRebateBudgetRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.withdrawRebateBudget(SETTLEMENT_ASSET, 1, ALICE);
    }

    /* -------------------- setFeeProfile boundaries -------------------- */

    function testV2GR2_SetFeeProfileAcceptsMaxRebateAndMaxTaker() external {
        int32 maxRebate = feesManager.MAX_MAKER_REBATE_PPM(); // -1000
        int32 maxTaker = feesManager.MAX_TAKER_FEE_PPM(); // 1000

        vm.expectEmit(true, true, false, true, address(feesManager));
        emit FeeProfileUpdated(0, uint8(IFeesManagerV2.ProductKind.OPTION), maxRebate, maxTaker);

        vm.prank(OWNER);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, maxRebate, maxTaker);

        IFeesManagerV2.ProductFeeProfilePpm memory profile =
            feesManager.getFeeProfile(0, IFeesManagerV2.ProductKind.OPTION);
        assertEq(profile.makerPpm, maxRebate);
        assertEq(profile.takerPpm, maxTaker);
    }

    function testV2GR2_SetFeeProfileRejectsMakerBelowMaxRebate() external {
        int32 belowMax = feesManager.MAX_MAKER_REBATE_PPM() - 1; // -1001

        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidFeeRate.selector);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, belowMax, 100);
    }

    function testV2GR2_SetFeeProfileRejectsTakerAboveMax() external {
        int32 aboveMax = feesManager.MAX_TAKER_FEE_PPM() + 1; // 1001

        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidFeeRate.selector);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, 0, aboveMax);
    }

    function testV2GR2_SetFeeProfileRejectsTakerAboveMakerCap() external {
        // Maker cap is also MAX_TAKER_FEE_PPM (positive side); maker
        // > 1000 must revert with InvalidFeeRate.
        int32 aboveMax = feesManager.MAX_TAKER_FEE_PPM() + 1;
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidFeeRate.selector);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, aboveMax, 100);
    }

    function testV2GR2_SetFeeProfileRejectsNegativeTaker() external {
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidFeeRate.selector);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, 0, -1);
    }

    function testV2GR2_SetFeeProfileRejectsInvalidTier() external {
        uint8 outOfRange = feesManager.TIER_COUNT();
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidTier.selector);
        feesManager.setFeeProfile(outOfRange, IFeesManagerV2.ProductKind.OPTION, 0, 100);
    }

    function testV2GR2_SetFeeProfileRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.setFeeProfile(0, IFeesManagerV2.ProductKind.OPTION, 0, 100);
    }

    /* -------------------- setRfqDiscountProfile boundaries -------------------- */

    function testV2GR2_SetRfqDiscountProfileAcceptsAtPpmDenominator() external {
        uint32 denominator = feesManager.PPM_DENOMINATOR(); // 1_000_000

        vm.expectEmit(true, true, false, true, address(feesManager));
        emit RfqDiscountProfileUpdated(2, uint8(IFeesManagerV2.ProductKind.OPTION), denominator, denominator);

        vm.prank(OWNER);
        feesManager.setRfqDiscountProfile(2, IFeesManagerV2.ProductKind.OPTION, denominator, denominator);

        IFeesManagerV2.RfqDiscountProfile memory profile =
            feesManager.getRfqDiscountProfile(2, IFeesManagerV2.ProductKind.OPTION);
        assertEq(profile.makerDiscountPpm, denominator);
        assertEq(profile.takerDiscountPpm, denominator);
    }

    function testV2GR2_SetRfqDiscountProfileRejectsInvalidTier() external {
        uint8 outOfRange = feesManager.TIER_COUNT();
        vm.prank(OWNER);
        vm.expectRevert(FeesManagerV2.InvalidTier.selector);
        feesManager.setRfqDiscountProfile(outOfRange, IFeesManagerV2.ProductKind.OPTION, 0, 0);
    }

    function testV2GR2_SetRfqDiscountProfileRejectsNonOwner() external {
        vm.prank(ALICE);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        feesManager.setRfqDiscountProfile(0, IFeesManagerV2.ProductKind.OPTION, 0, 0);
    }

    /* -------------------- productFeeBasis -------------------- */

    function testV2GR2_ProductFeeBasisGetters() external view {
        assertEq(
            uint256(feesManager.productFeeBasis(IFeesManagerV2.ProductKind.OPTION)),
            uint256(IFeesManagerV2.FeeBasis.PREMIUM)
        );
        assertEq(
            uint256(feesManager.productFeeBasis(IFeesManagerV2.ProductKind.PERP)),
            uint256(IFeesManagerV2.FeeBasis.NOTIONAL)
        );
    }
}
