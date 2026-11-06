// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {
    VerifiedOptionSettlementOwner,
    IHistoricalChainlinkFeed,
    IHistoricalPyth
} from "../../src/settlement/VerifiedOptionSettlementOwner.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ForkChainlinkBoundaryStub is IHistoricalChainlinkFeed {
    uint64 public immutable expiry;

    constructor(uint64 expiry_) {
        expiry = expiry_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(id == 101 || id == 102, "unknown round");
        uint256 updatedAt = id == 101 ? expiry - 10 : expiry + 1;
        return (id, 2000e8, updatedAt, updatedAt, id);
    }
}

contract VerifiedOptionSettlementOwnerForkTest is Test {
    address internal constant REGISTRY = 0x3d52b033Fab00ed6104DD3bc0a715F8648344ecA;
    address internal constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address internal constant ENGINE = 0x506cD65a63C53c66ab572B9f9dd819B7BfE00D30;
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant ETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BTC = 0x9D871aC7595E8Da271E866608E5145252047967c;
    address internal constant ETH_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant BTC_FEED = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address internal constant PYTH = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    bytes32 internal constant ETH_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant BTC_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 internal constant ETH_CALL = 24145907678156652148089862289363692212069910767044828147380657249455352740183;

    function testExclusiveProofOwnerCanTakeHistoricalRegistryWithoutMovingCollateral() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_041_332);
        OptionProductRegistry registry = OptionProductRegistry(REGISTRY);
        CollateralVault vault = CollateralVault(VAULT);
        assertEq(registry.owner(), TIMELOCK);
        assertEq(registry.settlementOperator(), address(0));
        (bool linked, bytes memory linkedData) = ENGINE.staticcall(abi.encodeWithSignature("optionRegistry()"));
        assertTrue(linked);
        assertEq(abi.decode(linkedData, (address)), REGISTRY);
        uint256 accountingBefore = vault.totalDepositedByToken(TOKEN);
        uint256 assetsBefore = IERC20(TOKEN).balanceOf(VAULT);
        (bool ok, bytes memory data) =
            ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok, "missing OI");
        uint256 shortOiBefore = abi.decode(data, (uint256));

        address[2] memory underlyings = [ETH, BTC];
        address[2] memory feeds = [ETH_FEED, BTC_FEED];
        bytes32[2] memory ids = [ETH_ID, BTC_ID];
        VerifiedOptionSettlementOwner verifier = new VerifiedOptionSettlementOwner(
            REGISTRY,
            TIMELOCK,
            registry.guardian(),
            TOKEN,
            PYTH,
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        vm.prank(registry.guardian());
        registry.pauseSettlement();
        vm.prank(registry.guardian());
        registry.pauseCreation();
        vm.prank(TIMELOCK); // fork-only impersonation, not a real Safe signature
        registry.transferOwnership(address(verifier));
        vm.prank(TIMELOCK);
        verifier.acceptRegistryOwnership();
        assertEq(registry.owner(), address(verifier));
        assertEq(registry.guardian(), address(verifier));
        assertTrue(registry.creationPaused());
        assertFalse(verifier.settlementEligible(ETH_CALL));
        assertEq(registry.settlementOperator(), address(0));
        vm.prank(TIMELOCK);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));
        vm.prank(TIMELOCK);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.setSettlementPrice(ETH_CALL, 1);
        vm.prank(TIMELOCK);
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSettlementOperator, (TIMELOCK)));
        vm.prank(TIMELOCK);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (ETH_CALL, false)));
        assertFalse(registry.getSeries(ETH_CALL).isActive);
        vm.prank(TIMELOCK);
        vm.expectRevert(VerifiedOptionSettlementOwner.ForbiddenAdminCall.selector);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (ETH_CALL, true)));
        assertFalse(registry.getSeries(ETH_CALL).isActive);

        assertEq(vault.totalDepositedByToken(TOKEN), accountingBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), assetsBefore);
        (linked, linkedData) = ENGINE.staticcall(abi.encodeWithSignature("optionRegistry()"));
        assertTrue(linked);
        assertEq(abi.decode(linkedData, (address)), REGISTRY);
        (ok, data) = ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok && abi.decode(data, (uint256)) == shortOiBefore, "positions changed");
        assertEq(shortOiBefore, 7);
    }

    function testRealChainlinkRoundsVerifySyntheticExpiredSeries() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_061_338);
        (bool ok, bytes memory latestData) = ETH_FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "latest round unavailable");
        (uint80 latestId, int256 latestPrice,, uint256 latestAt,) =
            abi.decode(latestData, (uint80, int256, uint256, uint256, uint80));
        bytes memory earlierData;
        (ok, earlierData) = ETH_FEED.staticcall(abi.encodeWithSignature("getRoundData(uint80)", latestId - 1));
        require(ok, "historical round unavailable");
        (uint80 earlierId, int256 earlierPrice,, uint256 earlierAt,) =
            abi.decode(earlierData, (uint80, int256, uint256, uint256, uint80));
        assertEq(earlierId + 1, latestId);
        assertGt(earlierPrice, 0);
        assertGt(latestPrice, 0);
        assertGt(latestAt, earlierAt + 1);
        uint64 syntheticExpiry = uint64(earlierAt + (latestAt - earlierAt) / 2);

        // Time is changed on the fork solely to create a local expired series
        // bracketed by two authentic, already published Chainlink rounds.
        vm.warp(earlierAt);
        OptionProductRegistry localRegistry = new OptionProductRegistry(address(this));
        localRegistry.setSettlementAssetAllowed(TOKEN, true);
        localRegistry.setUnderlyingConfig(ETH, OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true));
        address[2] memory underlyings = [ETH, BTC];
        address[2] memory feeds = [ETH_FEED, BTC_FEED];
        bytes32[2] memory ids = [ETH_ID, BTC_ID];
        VerifiedOptionSettlementOwner verifier = new VerifiedOptionSettlementOwner(
            address(localRegistry),
            address(this),
            address(this),
            TOKEN,
            PYTH,
            underlyings,
            feeds,
            ids,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        localRegistry.pauseSettlement();
        localRegistry.pauseCreation();
        localRegistry.transferOwnership(address(verifier));
        verifier.acceptRegistryOwnership();
        uint256 localSeries = verifier.createInactiveCallSeries(ETH, syntheticExpiry, 3000e8);
        verifier.executeRegistryAdmin(abi.encodeCall(localRegistry.unpauseSettlement, ()));
        vm.warp(latestAt + 1);
        verifier.propose(localSeries, earlierId, latestId);
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(localSeries);
        verifier.finalize(localSeries);
        (uint256 settledPrice, bool finalized) = localRegistry.getSettlementInfo(localSeries);
        assertTrue(finalized);
        assertEq(settledPrice, uint256(earlierPrice));
    }

    function testAuthenticPythCorePayloadAcceptedByDeployedVerifier() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_064_571);
        bytes memory signedUpdate = vm.parseBytes(vm.readFile("test/fixtures/options_v9_pyth_core_eth_payload.hex"));
        bytes[] memory updates = new bytes[](1);
        updates[0] = signedUpdate;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint64 publishTime = 1_793_934_781;
        uint256 fee = IHistoricalPyth(PYTH).getUpdateFee(updates);
        vm.deal(address(this), fee);
        IHistoricalPyth.PriceFeed[] memory prices = IHistoricalPyth(PYTH).parsePriceFeedUpdatesUnique{value: fee}(
            updates, ids, publishTime, publishTime + 1_500
        );
        assertEq(prices.length, 1);
        assertEq(prices[0].id, ETH_ID);
        assertEq(prices[0].price.publishTime, publishTime);
        assertGt(prices[0].price.price, 0);
        assertLe(uint256(prices[0].price.conf) * 10_000, uint256(uint64(prices[0].price.price)) * 100);
        // The deployed Base Sepolia contract currently quotes zero native fee;
        // execution gas remains nonzero and must be budgeted separately.
        assertEq(fee, 0);

        // The exact same signed update cannot authenticate a different feed
        // or a window beginning after its publication timestamp.
        ids[0] = BTC_ID;
        vm.expectRevert();
        IHistoricalPyth(PYTH).parsePriceFeedUpdatesUnique{value: fee}(updates, ids, publishTime, publishTime + 1_500);
        ids[0] = ETH_ID;
        vm.expectRevert();
        IHistoricalPyth(PYTH).parsePriceFeedUpdatesUnique{value: fee}(
            updates, ids, publishTime + 1, publishTime + 1_500
        );
    }

    function testAuthenticPythCoreDisputeResolvesSeriesOnFork() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_064_571);
        uint64 expiry = 1_793_934_781;
        bytes memory signedUpdate = vm.parseBytes(vm.readFile("test/fixtures/options_v9_pyth_core_eth_payload.hex"));
        bytes[] memory updates = new bytes[](1);
        updates[0] = signedUpdate;
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = ETH_ID;
        uint256 fee = IHistoricalPyth(PYTH).getUpdateFee(updates);

        vm.warp(expiry - 100);
        OptionProductRegistry localRegistry = new OptionProductRegistry(address(this));
        localRegistry.setSettlementAssetAllowed(TOKEN, true);
        localRegistry.setUnderlyingConfig(ETH, OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true));
        ForkChainlinkBoundaryStub boundary = new ForkChainlinkBoundaryStub(expiry);
        address[2] memory underlyings = [ETH, BTC];
        address[2] memory feeds = [address(boundary), BTC_FEED];
        bytes32[2] memory pythIds = [ETH_ID, BTC_ID];
        VerifiedOptionSettlementOwner verifier = new VerifiedOptionSettlementOwner(
            address(localRegistry),
            address(this),
            address(this),
            TOKEN,
            PYTH,
            underlyings,
            feeds,
            pythIds,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        localRegistry.pauseSettlement();
        localRegistry.pauseCreation();
        localRegistry.transferOwnership(address(verifier));
        verifier.acceptRegistryOwnership();
        uint256 series = verifier.createInactiveCallSeries(ETH, expiry, 2000e8);
        verifier.executeRegistryAdmin(abi.encodeCall(localRegistry.unpauseSettlement, ()));

        vm.warp(expiry + 2);
        verifier.propose(series, 101, 102);
        vm.deal(address(this), fee);
        uint256 challengeGasStart = gasleft();
        verifier.challengeWithPyth{value: fee}(series, updates);
        emit log_named_uint("AUTHENTIC_PYTH_CHALLENGE_GAS", challengeGasStart - gasleft());
        (,,,,,, VerifiedOptionSettlementOwner.SettlementState disputed) = verifier.proposals(series);
        assertEq(uint256(disputed), uint256(VerifiedOptionSettlementOwner.SettlementState.CHALLENGED));
        vm.warp(block.timestamp + 2 days);
        uint256 settleGasStart = gasleft();
        verifier.resolve(series);
        verifier.finalize(series);
        emit log_named_uint("RESOLVE_AND_FINALIZE_GAS", settleGasStart - gasleft());
        (uint256 price, bool finalized) = localRegistry.getSettlementInfo(series);
        assertTrue(finalized);
        assertTrue(price > 0 && price != 2000e8);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidState.selector);
        verifier.finalize(series);
    }

    function testAuthenticChainlinkAndPythAgreeOnPinnedHistoricalExpiry() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_073_290);
        uint64 expiry = 1_793_934_781;
        uint80 beforeId = 18_446_744_073_709_842_478;
        uint80 afterId = beforeId + 1;
        bytes memory signedUpdate = vm.parseBytes(vm.readFile("test/fixtures/options_v9_pyth_core_eth_payload.hex"));
        bytes[] memory updates = new bytes[](1);
        updates[0] = signedUpdate;
        vm.warp(expiry - 100);
        OptionProductRegistry localRegistry = new OptionProductRegistry(address(this));
        localRegistry.setSettlementAssetAllowed(TOKEN, true);
        localRegistry.setUnderlyingConfig(ETH, OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true));
        address[2] memory underlyings = [ETH, BTC];
        address[2] memory feeds = [ETH_FEED, BTC_FEED];
        bytes32[2] memory pythIds = [ETH_ID, BTC_ID];
        VerifiedOptionSettlementOwner verifier = new VerifiedOptionSettlementOwner(
            address(localRegistry),
            address(this),
            address(this),
            TOKEN,
            PYTH,
            underlyings,
            feeds,
            pythIds,
            1_500,
            1_500,
            2 days,
            100,
            100
        );
        localRegistry.pauseSettlement();
        localRegistry.pauseCreation();
        localRegistry.transferOwnership(address(verifier));
        verifier.acceptRegistryOwnership();
        uint256 series = verifier.createInactiveCallSeries(ETH, expiry, 2000e8);
        verifier.executeRegistryAdmin(abi.encodeCall(localRegistry.unpauseSettlement, ()));

        vm.warp(expiry + 32);
        uint256 proposeGasStart = gasleft();
        verifier.propose(series, beforeId, afterId);
        emit log_named_uint("AUTHENTIC_CHAINLINK_PROPOSE_GAS", proposeGasStart - gasleft());
        uint256 fee = IHistoricalPyth(PYTH).getUpdateFee(updates);
        vm.deal(address(this), fee);
        vm.expectRevert(VerifiedOptionSettlementOwner.NoMaterialDisagreement.selector);
        verifier.challengeWithPyth{value: fee}(series, updates);
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(series);
        verifier.finalize(series);
        (uint256 settled, bool finalized) = localRegistry.getSettlementInfo(series);
        assertTrue(finalized);
        assertEq(settled, 224_042_789_828);
    }
}
