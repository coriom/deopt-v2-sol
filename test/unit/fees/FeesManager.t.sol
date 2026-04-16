// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FeesManager} from "../../../src/fees/FeesManager.sol";
import {IFeesManager} from "../../../src/fees/IFeesManager.sol";

contract FeesManagerTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB2);

    uint256 internal constant PREMIUM = 1_000_000;
    uint256 internal constant NOTIONAL = 10_000_000;
    uint64 internal constant FUTURE_EXPIRY = 2_000_000_000;

    FeesManager internal feesManager;

    function setUp() external {
        feesManager = new FeesManager(
            OWNER,
            2,  // maker notional
            4,  // maker premium cap
            5,  // taker notional
            6,  // taker premium cap
            100 // fee cap
        );
    }

    function testDefaultMakerFeeQuoteIsCorrect() external view {
        IFeesManager.FeeQuote memory quote = feesManager.quoteFee(ALICE, true, PREMIUM, NOTIONAL);

        assertEq(quote.notionalFee, 2_000);
        assertEq(quote.premiumCapFee, 400);
        assertEq(quote.appliedFee, 400);
        assertTrue(quote.cappedByPremium);
        assertEq(quote.paramsUsed.notionalFeeBps, 2);
        assertEq(quote.paramsUsed.premiumCapBps, 4);
    }

    function testDefaultTakerFeeQuoteIsCorrect() external view {
        IFeesManager.FeeQuote memory quote = feesManager.quoteFee(ALICE, false, PREMIUM, NOTIONAL);

        assertEq(quote.notionalFee, 5_000);
        assertEq(quote.premiumCapFee, 600);
        assertEq(quote.appliedFee, 600);
        assertTrue(quote.cappedByPremium);
        assertEq(quote.paramsUsed.notionalFeeBps, 5);
        assertEq(quote.paramsUsed.premiumCapBps, 6);
    }

    function testFeeCapIsEnforcedCorrectly() external {
        vm.prank(OWNER);
        feesManager.setDefaultFees(150, 120, 90, 80);

        assertEq(feesManager.defaultMakerNotionalFeeBps(), 100);
        assertEq(feesManager.defaultMakerPremiumCapBps(), 100);
        assertEq(feesManager.defaultTakerNotionalFeeBps(), 90);
        assertEq(feesManager.defaultTakerPremiumCapBps(), 80);
    }

    function testTierProfileIsReturnedCorrectlyForEachTier() external view {
        IFeesManager.FeeProfile memory tier0 = feesManager.getTierClassProfile(IFeesManager.VolumeTierClass.Tier0);
        IFeesManager.FeeProfile memory tier1 = feesManager.getTierClassProfile(IFeesManager.VolumeTierClass.Tier1);
        IFeesManager.FeeProfile memory tier2 = feesManager.getTierClassProfile(IFeesManager.VolumeTierClass.Tier2);

        assertEq(tier0.maker.notionalFeeBps, 1);
        assertEq(tier0.maker.premiumCapBps, 1);
        assertEq(tier0.taker.notionalFeeBps, 3);
        assertEq(tier0.taker.premiumCapBps, 3);

        assertEq(tier1.maker.notionalFeeBps, 0);
        assertEq(tier1.maker.premiumCapBps, 0);
        assertEq(tier1.taker.notionalFeeBps, 2);
        assertEq(tier1.taker.premiumCapBps, 2);

        assertEq(tier2.maker.notionalFeeBps, 0);
        assertEq(tier2.maker.premiumCapBps, 0);
        assertEq(tier2.taker.notionalFeeBps, 1);
        assertEq(tier2.taker.premiumCapBps, 1);
    }

    function testOverrideTakesPrecedenceOverTier() external {
        _claimTier(ALICE, IFeesManager.VolumeTierClass.Tier2, FUTURE_EXPIRY, _singleLeafProof(ALICE, IFeesManager.VolumeTierClass.Tier2, FUTURE_EXPIRY));

        vm.prank(OWNER);
        feesManager.setOverride(ALICE, 9, 8, 7, 6, FUTURE_EXPIRY, true);

        IFeesManager.FeeParams memory maker = feesManager.getFeeParams(ALICE, true);
        IFeesManager.FeeParams memory taker = feesManager.getFeeParams(ALICE, false);

        assertEq(maker.notionalFeeBps, 9);
        assertEq(maker.premiumCapBps, 8);
        assertEq(taker.notionalFeeBps, 7);
        assertEq(taker.premiumCapBps, 6);
    }

    function testExpiredOverrideFallsBackCorrectly() external {
        _claimTier(ALICE, IFeesManager.VolumeTierClass.Tier1, FUTURE_EXPIRY, _singleLeafProof(ALICE, IFeesManager.VolumeTierClass.Tier1, FUTURE_EXPIRY));

        vm.prank(OWNER);
        feesManager.setOverride(ALICE, 9, 8, 7, 6, uint64(block.timestamp + 1), true);

        vm.warp(block.timestamp + 2);

        IFeesManager.FeeParams memory maker = feesManager.getFeeParams(ALICE, true);
        IFeesManager.FeeParams memory taker = feesManager.getFeeParams(ALICE, false);

        assertEq(maker.notionalFeeBps, 0);
        assertEq(maker.premiumCapBps, 0);
        assertEq(taker.notionalFeeBps, 2);
        assertEq(taker.premiumCapBps, 2);
    }

    function testQuoteFeeReturnsMinNotionalFeePremiumCapFee() external view {
        IFeesManager.FeeQuote memory quote = feesManager.quoteFee(ALICE, true, 10_000_000, 100_000_000);

        assertEq(quote.notionalFee, 20_000);
        assertEq(quote.premiumCapFee, 4_000);
        assertEq(quote.appliedFee, 4_000);
        assertTrue(quote.cappedByPremium);
    }

    function testZeroPremiumAndZeroNotionalReturnsZeroFee() external view {
        IFeesManager.FeeQuote memory quote = feesManager.quoteFee(ALICE, true, 0, 0);

        assertEq(quote.notionalFee, 0);
        assertEq(quote.premiumCapFee, 0);
        assertEq(quote.appliedFee, 0);
        assertFalse(quote.cappedByPremium);
    }

    function testValidMerkleTierClaimSucceeds() external {
        bytes32[] memory proof = _singleLeafProof(ALICE, IFeesManager.VolumeTierClass.Tier2, FUTURE_EXPIRY);

        _claimTier(ALICE, IFeesManager.VolumeTierClass.Tier2, FUTURE_EXPIRY, proof);

        IFeesManager.Tier memory tier = feesManager.tiers(ALICE);
        assertEq(uint256(tier.tierClass), uint256(IFeesManager.VolumeTierClass.Tier2));
        assertEq(tier.expiry, FUTURE_EXPIRY);
        assertEq(tier.epoch, feesManager.epoch());
    }

    function testInvalidMerkleProofReverts() external {
        bytes32[] memory proof = _singleLeafProof(ALICE, IFeesManager.VolumeTierClass.Tier0, FUTURE_EXPIRY);

        vm.prank(ALICE);
        vm.expectRevert(FeesManager.ProofInvalid.selector);
        feesManager.claimTier(ALICE, IFeesManager.VolumeTierClass.Tier1, FUTURE_EXPIRY, proof);
    }

    function _claimTier(
        address trader,
        IFeesManager.VolumeTierClass tierClass,
        uint64 expiry,
        bytes32[] memory proof
    ) internal {
        _setSingleLeafRoot(trader, tierClass, expiry);

        vm.prank(trader);
        feesManager.claimTier(trader, tierClass, expiry, proof);
    }

    function _setSingleLeafRoot(address trader, IFeesManager.VolumeTierClass tierClass, uint64 expiry) internal {
        uint64 nextEpoch = feesManager.epoch() + 1;
        bytes32 root = _leaf(trader, tierClass, expiry, nextEpoch);

        vm.prank(OWNER);
        feesManager.setMerkleRoot(root);

        assertEq(feesManager.epoch(), nextEpoch);
    }

    function _singleLeafProof(address, IFeesManager.VolumeTierClass, uint64)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        proof = new bytes32[](0);
    }

    function _leaf(address trader, IFeesManager.VolumeTierClass tierClass, uint64 expiry, uint64 epoch)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(trader, tierClass, expiry, epoch));
    }
}
