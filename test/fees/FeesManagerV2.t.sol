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
}
