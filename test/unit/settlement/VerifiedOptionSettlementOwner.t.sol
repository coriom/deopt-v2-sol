// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionProductRegistry} from "../../../src/OptionProductRegistry.sol";
import {ProtocolTimelock} from "../../../src/gouvernance/ProtocolTimelock.sol";
import {
    VerifiedOptionSettlementOwner,
    IHistoricalChainlinkFeed,
    IHistoricalPyth
} from "../../../src/settlement/VerifiedOptionSettlementOwner.sol";

contract HistoricalChainlinkStub is IHistoricalChainlinkFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function setRound(uint80 id, int256 answer, uint256 updatedAt) external {
        rounds[id] = Round(answer, updatedAt);
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory round = rounds[id];
        require(round.updatedAt != 0, "missing round");
        return (id, round.answer, round.updatedAt, round.updatedAt, id);
    }
}

/// @dev This stub tests control flow only. It does not authenticate Pyth data.
contract HistoricalPythStub is IHistoricalPyth {
    bool public reject;
    int64 public price = 3300_00000000;
    uint64 public conf = 1_00000000;
    uint256 public publishTime;
    bytes32 public id;

    function configure(bytes32 id_, uint256 publishTime_, int64 price_) external {
        id = id_;
        publishTime = publishTime_;
        price = price_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function setConfidence(uint64 value) external {
        conf = value;
    }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata ids, uint64 minTime, uint64 maxTime)
        external
        payable
        returns (PriceFeed[] memory result)
    {
        require(!reject && id == ids[0] && publishTime >= minTime && publishTime <= maxTime, "bad signed update");
        result = new PriceFeed[](1);
        result[0] = PriceFeed(id, Price(price, conf, -8, publishTime), Price(price, conf, -8, publishTime));
    }
}

contract VerifiedOptionSettlementOwnerTest is Test {
    address internal constant UNDERLYING = address(0x1001);
    address internal constant OTHER_UNDERLYING = address(0x1002);
    address internal constant TOKEN = address(0x2001);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant GUARDIAN = address(0xF00D);
    bytes32 internal constant PRICE_ID = bytes32(uint256(0xA1));

    OptionProductRegistry internal registry;
    HistoricalChainlinkStub internal chainlink;
    HistoricalPythStub internal pyth;
    VerifiedOptionSettlementOwner internal verifier;
    uint256 internal optionId;
    uint64 internal expiry;

    function setUp() public {
        vm.warp(10_000_000);
        registry = new OptionProductRegistry(address(this));
        chainlink = new HistoricalChainlinkStub();
        pyth = new HistoricalPythStub();
        registry.setSettlementAssetAllowed(TOKEN, true);
        OptionProductRegistry.UnderlyingConfig memory config =
            OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true);
        registry.setUnderlyingConfig(UNDERLYING, config);
        expiry = uint64(block.timestamp + 1_000);
        chainlink.setRound(101, 3000e8, expiry - 10);
        chainlink.setRound(102, 3001e8, expiry + 10);
        pyth.configure(PRICE_ID, expiry + 11, 3300_00000000);
        address[2] memory underlyings = [UNDERLYING, OTHER_UNDERLYING];
        address[2] memory feeds = [address(chainlink), address(new HistoricalChainlinkStub())];
        bytes32[2] memory ids = [PRICE_ID, bytes32(uint256(0xA2))];
        verifier = new VerifiedOptionSettlementOwner(
            address(registry),
            address(this),
            GUARDIAN,
            TOKEN,
            address(pyth),
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        registry.pauseSettlement();
        registry.pauseCreation();
        registry.transferOwnership(address(verifier));
        verifier.acceptRegistryOwnership();
        optionId = verifier.createInactiveCallSeries(UNDERLYING, expiry, 3001e8);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));
        vm.warp(expiry + 20);
    }

    function _successor(uint32 divergenceBps) internal returns (VerifiedOptionSettlementOwner next) {
        address[2] memory underlyings = [UNDERLYING, OTHER_UNDERLYING];
        address[2] memory feeds = [address(chainlink), address(verifier.chainlinkFeed(OTHER_UNDERLYING))];
        bytes32[2] memory ids = [PRICE_ID, bytes32(uint256(0xA2))];
        next = new VerifiedOptionSettlementOwner(
            address(registry),
            address(this),
            GUARDIAN,
            TOKEN,
            address(pyth),
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            divergenceBps,
            100
        );
    }

    function testTimelockedRecoveryPreservesSeriesAndRequiresProof() public {
        VerifiedOptionSettlementOwner next = _successor(100);
        next.prepareRecovery(address(verifier));
        vm.expectRevert(VerifiedOptionSettlementOwner.RecoveryNotReady.selector);
        verifier.handoffTo(next);
        vm.prank(GUARDIAN);
        verifier.emergencyPauseForRecovery();
        verifier.handoffTo(next);
        assertEq(registry.pendingOwner(), address(next));
        assertEq(registry.owner(), address(verifier));
        next.acceptRecoveredOwnership();
        assertEq(registry.owner(), address(next));
        assertEq(registry.guardian(), address(next));
        assertTrue(next.isSettlementEligible(optionId));
        assertEq(registry.getAllOptionIds().length, 1);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.setSettlementPrice(optionId, 1);

        next.executeRegistryAdmin(abi.encodeCall(registry.unpause, ()));
        next.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));
        next.propose(optionId, 101, 102);
        vm.warp(block.timestamp + 2 days);
        next.resolve(optionId);
        next.finalize(optionId);
        (uint256 price, bool finalized) = registry.getSettlementInfo(optionId);
        assertTrue(finalized);
        assertEq(price, 3000e8);
    }

    function testRecoveryRejectsUnauthorizedDriftAndPreservesPendingPriceDeadline() public {
        VerifiedOptionSettlementOwner drift = _successor(99);
        vm.prank(ATTACKER);
        vm.expectRevert(VerifiedOptionSettlementOwner.NotTimelock.selector);
        drift.prepareRecovery(address(verifier));
        vm.expectRevert(VerifiedOptionSettlementOwner.IncompatibleSuccessor.selector);
        drift.prepareRecovery(address(verifier));

        VerifiedOptionSettlementOwner next = _successor(100);
        next.prepareRecovery(address(verifier));
        verifier.propose(optionId, 101, 102);
        uint64 originalDeadlineStart = verifier.getProposal(optionId).proposedAt;
        vm.prank(GUARDIAN);
        verifier.emergencyPauseForRecovery();
        verifier.handoffTo(next);
        next.acceptRecoveredOwnership();
        assertEq(registry.owner(), address(next));
        assertEq(next.getProposal(optionId).proposedAt, originalDeadlineStart);
        assertEq(
            uint8(next.getProposal(optionId).state), uint8(VerifiedOptionSettlementOwner.SettlementState.PRICE_PROPOSED)
        );
        vm.expectRevert(VerifiedOptionSettlementOwner.UnsafeRegistryState.selector);
        verifier.resolve(optionId);
        next.executeRegistryAdmin(abi.encodeCall(registry.unpause, ()));
        next.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));
        vm.warp(uint256(originalDeadlineStart) + 2 days);
        next.resolve(optionId);
        next.finalize(optionId);
        assertTrue(registry.isSettled(optionId));
    }

    function testRecoveryCanBeCancelledBeforeSuccessorAccepts() public {
        VerifiedOptionSettlementOwner next = _successor(100);
        next.prepareRecovery(address(verifier));
        vm.prank(GUARDIAN);
        verifier.emergencyPauseForRecovery();
        verifier.handoffTo(next);
        vm.prank(ATTACKER);
        vm.expectRevert(VerifiedOptionSettlementOwner.NotTimelock.selector);
        verifier.cancelRecovery();
        verifier.cancelRecovery();
        assertEq(registry.owner(), address(verifier));
        assertEq(registry.pendingOwner(), address(0));
        vm.expectRevert(VerifiedOptionSettlementOwner.RecoveryNotReady.selector);
        next.acceptRecoveredOwnership();
    }

    function testRecoveryKeepsAuthenticallyChallengedSeriesBlocked() public {
        VerifiedOptionSettlementOwner next = _successor(100);
        next.prepareRecovery(address(verifier));
        verifier.propose(optionId, 101, 102);
        bytes[] memory updateData = new bytes[](0);
        verifier.challengeWithPyth(optionId, updateData); // unit stub; fork separately verifies Pyth Core
        vm.prank(GUARDIAN);
        verifier.emergencyPauseForRecovery();
        verifier.handoffTo(next);
        next.acceptRecoveredOwnership();
        assertEq(
            uint8(next.getProposal(optionId).state), uint8(VerifiedOptionSettlementOwner.SettlementState.CHALLENGED)
        );
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(VerifiedOptionSettlementOwner.UnresolvedDivergence.selector);
        next.resolve(optionId);
        assertFalse(registry.isSettled(optionId));
    }

    function testRecoveryHandoffUsesRealTimelockDelay() public {
        ProtocolTimelock lock = new ProtocolTimelock(address(this), GUARDIAN, 1 days);
        OptionProductRegistry dedicated = new OptionProductRegistry(address(lock));
        address[2] memory underlyings = [UNDERLYING, OTHER_UNDERLYING];
        address[2] memory feeds = [address(chainlink), address(verifier.chainlinkFeed(OTHER_UNDERLYING))];
        bytes32[2] memory ids = [PRICE_ID, bytes32(uint256(0xA2))];
        VerifiedOptionSettlementOwner first = new VerifiedOptionSettlementOwner(
            address(dedicated),
            address(lock),
            GUARDIAN,
            TOKEN,
            address(pyth),
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        // Initial setup is impersonated locally; recovery below uses the
        // actual ProtocolTimelock queue and execute entrypoints.
        vm.startPrank(address(lock));
        dedicated.setSettlementAssetAllowed(TOKEN, true);
        dedicated.setUnderlyingConfig(UNDERLYING, OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true));
        dedicated.pauseCreation();
        dedicated.pauseSettlement();
        dedicated.transferOwnership(address(first));
        first.acceptRegistryOwnership();
        uint256 series = first.createInactiveCallSeries(UNDERLYING, uint64(block.timestamp + 7 days), 3000e8);
        vm.stopPrank();
        VerifiedOptionSettlementOwner next = new VerifiedOptionSettlementOwner(
            address(dedicated),
            address(lock),
            GUARDIAN,
            TOKEN,
            address(pyth),
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            100,
            100
        );

        bytes memory prepare = abi.encodeCall(next.prepareRecovery, (address(first)));
        uint256 eta = block.timestamp + 1 days;
        lock.queueTransaction(address(next), 0, prepare, eta);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        lock.executeTransaction(address(next), 0, prepare, eta);
        vm.warp(eta);
        lock.executeTransaction(address(next), 0, prepare, eta);

        vm.prank(GUARDIAN);
        first.emergencyPauseForRecovery();
        bytes memory handoff = abi.encodeCall(first.handoffTo, (next));
        eta += 1 days;
        lock.queueTransaction(address(first), 0, handoff, eta);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        lock.executeTransaction(address(first), 0, handoff, eta);
        vm.warp(eta);
        lock.executeTransaction(address(first), 0, handoff, eta);
        assertEq(dedicated.owner(), address(first));

        bytes memory accept = abi.encodeCall(next.acceptRecoveredOwnership, ());
        eta += 1 days;
        lock.queueTransaction(address(next), 0, accept, eta);
        vm.warp(eta);
        lock.executeTransaction(address(next), 0, accept, eta);
        assertEq(dedicated.owner(), address(next));
        assertTrue(next.isSettlementEligible(series));
        assertFalse(dedicated.getSeries(series).isActive);
    }

    function testSyntheticChainlinkBoundaryAndDirectBypassRejection() public {
        assertTrue(verifier.settlementEligible(optionId));
        assertFalse(registry.getSeries(optionId).isActive);
        assertFalse(registry.isSeriesCreator(address(verifier)));
        vm.expectRevert(OptionProductRegistry.StrikeZero.selector);
        verifier.createInactiveCallSeries(UNDERLYING, uint64(block.timestamp + 1 days), 0);
        assertTrue(registry.creationPaused());
        assertFalse(registry.isSeriesCreator(address(verifier)));
        assertTrue(registry.creationPaused());
        assertEq(registry.guardian(), address(verifier));
        vm.prank(GUARDIAN);
        vm.expectRevert(OptionProductRegistry.GuardianNotAuthorized.selector);
        registry.setEmergencyModes(false, false, false);
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.unpauseCreation, ()));
        vm.expectRevert(OptionProductRegistry.CreationPaused.selector);
        registry.createSeries(OTHER_UNDERLYING, TOKEN, uint64(block.timestamp + 1 days), 3000e8, 1e8, true, true);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.setSettlementPrice(optionId, 1);
        vm.prank(ATTACKER);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.setSettlementPrice(optionId, 1);
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSettlementPrice, (optionId, 1)));
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSettlementOperator, (ATTACKER)));
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.transferOwnership, (ATTACKER)));
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSettlementFinalityDelay, (0)));
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeWithSelector(OptionProductRegistry.setOptionRiskConfig.selector));
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (optionId, true)));
        assertTrue(registry.getSeries(optionId).isActive);

        verifier.propose(optionId, 101, 102);
        vm.expectRevert(VerifiedOptionSettlementOwner.ProposalExists.selector);
        verifier.propose(optionId, 101, 102);
        vm.expectRevert(VerifiedOptionSettlementOwner.ChallengeOpen.selector);
        verifier.resolve(optionId);
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(optionId);
        verifier.finalize(optionId);
        (uint256 price, bool finalized) = registry.getSettlementInfo(optionId);
        assertTrue(finalized);
        assertEq(price, 3000e8);
        (,,,,,, VerifiedOptionSettlementOwner.SettlementState state) = verifier.proposals(optionId);
        assertEq(uint256(state), uint256(VerifiedOptionSettlementOwner.SettlementState.FINALIZED));
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.finalize(optionId);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidPriceProof.selector);
        verifier.propose(optionId, 101, 102);
    }

    function testWrongRoundFeedAndTimestampAreRejected() public {
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(optionId, 100, 102);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(optionId, type(uint64).max, uint80(uint256(type(uint64).max) + 1));
        chainlink.setRound(101, 3000e8, expiry - 1_501);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(optionId, 101, 102);
        chainlink.setRound(101, 3000e8, expiry - 10);
        chainlink.setRound(102, 3001e8, expiry - 1);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(optionId, 101, 102);
        chainlink.setRound(102, 3001e8, expiry + 10);
        vm.prank(ATTACKER);
        vm.expectRevert(VerifiedOptionSettlementOwner.NotTimelock.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (optionId, false)));
    }

    function testSettlementProofCannotBeReplayedAfterChainIdChange() public {
        vm.chainId(block.chainid + 1);
        vm.expectRevert(VerifiedOptionSettlementOwner.WrongChain.selector);
        verifier.propose(optionId, 101, 102);
    }

    function testPythStubDivergenceBlocksFinalizationWithoutDeadlineReset() public {
        verifier.propose(optionId, 101, 102);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"aa";
        pyth.setReject(true);
        vm.expectRevert(bytes("bad signed update"));
        verifier.challengeWithPyth(optionId, updateData);
        pyth.setReject(false);
        verifier.challengeWithPyth(optionId, updateData);
        vm.expectRevert(VerifiedOptionSettlementOwner.ChallengeOpen.selector);
        verifier.resolve(optionId);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.challengeWithPyth(optionId, updateData);
        vm.expectRevert(VerifiedOptionSettlementOwner.ProposalExists.selector);
        verifier.propose(optionId, 101, 102);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(VerifiedOptionSettlementOwner.UnresolvedDivergence.selector);
        verifier.resolve(optionId);
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(VerifiedOptionSettlementOwner.UnresolvedDivergence.selector);
        verifier.resolve(optionId);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.challengeWithPyth(optionId, updateData);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.finalize(optionId);
        (, bool finalized) = registry.getSettlementInfo(optionId);
        assertFalse(finalized);
        vm.expectRevert(VerifiedOptionSettlementOwner.LegacySeriesRestricted.selector);
        verifier.finalizeLegacyPrice(optionId, 1);
    }

    function testUnavailableHistoryAndAdministrativeCompatibility() public {
        chainlink.setRound(101, 3000e8, expiry - 1_501);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(optionId, 101, 102);
        (,,,,,, VerifiedOptionSettlementOwner.SettlementState state) = verifier.proposals(optionId);
        assertEq(uint256(state), uint256(VerifiedOptionSettlementOwner.SettlementState.PRICE_UNAVAILABLE));
        (, bool finalized) = registry.getSettlementInfo(optionId);
        assertFalse(finalized);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (optionId, false)));
        assertFalse(registry.getSeries(optionId).isActive);
        chainlink.setRound(101, 3000e8, expiry - 10);
        verifier.propose(optionId, 101, 102);
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(optionId);
        verifier.finalize(optionId);
        (uint256 price, bool nowFinal) = registry.getSettlementInfo(optionId);
        assertTrue(nowFinal);
        assertEq(price, 3000e8);
    }

    function testMatchingPythPriceCannotGriefAndLateChallengeIsClosed() public {
        verifier.propose(optionId, 101, 102);
        pyth.configure(PRICE_ID, expiry + 11, 3000_00000000);
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"aa";
        vm.expectRevert(VerifiedOptionSettlementOwner.NoMaterialDisagreement.selector);
        verifier.challengeWithPyth(optionId, updateData);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(VerifiedOptionSettlementOwner.ChallengeClosed.selector);
        verifier.challengeWithPyth(optionId, updateData);
        verifier.resolve(optionId);
        verifier.finalize(optionId);
    }

    function testPythFallbackRequiresObjectiveStaleChainlinkBoundary() public {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = hex"aa";
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.proposePythFallback(optionId, 101, 102, updateData);

        chainlink.setRound(101, 3000e8, expiry - 1_501);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(optionId, 101, 102);
        pyth.configure(PRICE_ID, expiry + 1_501, 3300_00000000);
        vm.expectRevert(bytes("bad signed update"));
        verifier.proposePythFallback(optionId, 101, 102, updateData);
        pyth.configure(PRICE_ID, expiry + 100, 3300_00000000);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidPriceProof.selector);
        verifier.proposePythFallback(optionId, 101, 102, updateData);
        pyth.configure(PRICE_ID, expiry + 11, 3300_00000000);
        pyth.setConfidence(33_00000000 + 1);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidPriceProof.selector);
        verifier.proposePythFallback(optionId, 101, 102, updateData);
        pyth.setConfidence(1_00000000);
        verifier.proposePythFallback(optionId, 101, 102, updateData);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.challengeWithPyth(optionId, updateData);
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(optionId);
        verifier.finalize(optionId);
        (uint256 price, bool finalized) = registry.getSettlementInfo(optionId);
        assertTrue(finalized);
        assertEq(price, 3300e8);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.finalize(optionId);
    }
}
