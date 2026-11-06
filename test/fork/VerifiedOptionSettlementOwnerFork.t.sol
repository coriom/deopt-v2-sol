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
import {MarginEngine} from "../../src/margin/MarginEngine.sol";
import {RiskModule} from "../../src/risk/RiskModule.sol";
import {OptionMatchingEngine} from "../../src/matching/OptionMatchingEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ForkChainlinkBoundaryStub is IHistoricalChainlinkFeed {
    uint64 public immutable expiry;
    bool public immutable stale;

    constructor(uint64 expiry_, bool stale_) {
        expiry = expiry_;
        stale = stale_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getRoundData(uint80 id) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(id == 101 || id == 102, "unknown round");
        uint256 updatedAt = id == 101 ? expiry - (stale ? 1_501 : 10) : expiry + 1;
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

    function testV15SameOptionIdAcrossHistoricalAndDedicatedRegistry() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_041_332);
        OptionProductRegistry.OptionSeries memory original = OptionProductRegistry(REGISTRY).getSeries(ETH_CALL);
        OptionProductRegistry dedicated = new OptionProductRegistry(TIMELOCK);
        vm.startPrank(TIMELOCK); // fork-only impersonation; no Safe signature
        dedicated.setSettlementAssetAllowed(original.settlementAsset, true);
        dedicated.setUnderlyingConfig(
            original.underlying, OptionProductRegistry.UnderlyingConfig(address(0x1), 0, 0, 0, 0, true)
        );
        uint256 duplicate = dedicated.createSeries(
            original.underlying,
            original.settlementAsset,
            original.expiry,
            original.strike,
            original.isCall,
            original.isEuropean
        );
        vm.stopPrank();
        assertEq(duplicate, ETH_CALL, "raw optionId must collide across registries");
        assertTrue(address(dedicated) != REGISTRY);
        assertEq(OptionProductRegistry(REGISTRY).getSeries(ETH_CALL).expiry, original.expiry);
    }

    function testDedicatedOptionsStackDoesNotTakeLegacyOwnershipOrCollateral() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_041_332);
        OptionProductRegistry historicalRegistry = OptionProductRegistry(REGISTRY);
        CollateralVault historicalVault = CollateralVault(VAULT);
        uint256 historicalTotal = historicalVault.totalDepositedByToken(TOKEN);
        uint256 historicalAssets = IERC20(TOKEN).balanceOf(VAULT);
        uint256 historicalSeller = historicalVault.balances(0x290bD12C93E467Bf51c51f5273D35bdDb19e9274, TOKEN);
        (bool ok, bytes memory data) =
            ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok, "historical OI unavailable");
        uint256 historicalShorts = abi.decode(data, (uint256));
        assertEq(historicalShorts, 7);

        // A fresh stack is a topology proof, not a configured or trade-ready
        // deployment. It deliberately grants no capability over old funds.
        OptionProductRegistry newRegistry = new OptionProductRegistry(TIMELOCK);
        CollateralVault newVault = new CollateralVault(TIMELOCK);
        MarginEngine newEngine = new MarginEngine(TIMELOCK, address(newRegistry), address(newVault), address(0x1));
        RiskModule newRisk =
            new RiskModule(TIMELOCK, address(newVault), address(newRegistry), address(newEngine), address(0x1));
        OptionMatchingEngine newMatching = new OptionMatchingEngine(TIMELOCK, address(newEngine), address(newRegistry));
        assertEq(address(newEngine.optionRegistry()), address(newRegistry));
        assertEq(address(newEngine.collateralVault()), address(newVault));
        assertEq(address(newMatching.optionRegistry()), address(newRegistry));
        assertEq(address(newMatching.marginEngine()), address(newEngine));
        assertEq(address(newRisk.collateralVault()), address(newVault));
        assertEq(historicalRegistry.owner(), TIMELOCK);
        assertEq(historicalVault.marginEngine(), ENGINE);
        assertFalse(historicalVault.isAuthorizedEngine(address(newEngine)));
        assertFalse(historicalVault.isAuthorizedEngine(address(newMatching)));
        assertEq(historicalVault.totalDepositedByToken(TOKEN), historicalTotal);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), historicalAssets);
        assertEq(historicalVault.balances(0x290bD12C93E467Bf51c51f5273D35bdDb19e9274, TOKEN), historicalSeller);
        (ok, data) = ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok, "historical OI unavailable after local deployment");
        assertEq(abi.decode(data, (uint256)), historicalShorts);
    }

    function testDedicatedRegistryRecoveryPreservesHistoricalStackOnFork() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_041_332);
        OptionProductRegistry historicalRegistry = OptionProductRegistry(REGISTRY);
        CollateralVault historicalVault = CollateralVault(VAULT);
        uint256 historicalAssets = IERC20(TOKEN).balanceOf(VAULT);
        uint256 historicalTotal = historicalVault.totalDepositedByToken(TOKEN);

        OptionProductRegistry dedicated = new OptionProductRegistry(TIMELOCK);
        vm.startPrank(TIMELOCK); // fork-only impersonation, not a Safe signature
        dedicated.setSettlementAssetAllowed(TOKEN, true);
        dedicated.setUnderlyingConfig(ETH, OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true));
        vm.stopPrank();
        address[2] memory underlyings = [ETH, BTC];
        address[2] memory feeds = [ETH_FEED, BTC_FEED];
        bytes32[2] memory ids = [ETH_ID, BTC_ID];
        VerifiedOptionSettlementOwner first = new VerifiedOptionSettlementOwner(
            address(dedicated), TIMELOCK, TIMELOCK, TOKEN, PYTH, underlyings, feeds, ids, 1_500, 1_500, 2 days, 100, 100
        );
        vm.startPrank(TIMELOCK);
        dedicated.pauseCreation();
        dedicated.pauseSettlement();
        dedicated.transferOwnership(address(first));
        first.acceptRegistryOwnership();
        uint256 newSeries = first.createInactiveCallSeries(ETH, uint64(block.timestamp + 30 days), 3000e8);
        vm.stopPrank();

        VerifiedOptionSettlementOwner successor = new VerifiedOptionSettlementOwner(
            address(dedicated), TIMELOCK, TIMELOCK, TOKEN, PYTH, underlyings, feeds, ids, 1_500, 1_500, 2 days, 100, 100
        );
        vm.startPrank(TIMELOCK);
        successor.prepareRecovery(address(first));
        first.emergencyPauseForRecovery();
        first.handoffTo(successor);
        successor.acceptRecoveredOwnership();
        vm.stopPrank();
        assertEq(dedicated.owner(), address(successor));
        assertTrue(successor.isSettlementEligible(newSeries));
        assertFalse(dedicated.getSeries(newSeries).isActive);
        assertEq(historicalRegistry.owner(), TIMELOCK);
        assertEq(historicalVault.marginEngine(), ENGINE);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), historicalAssets);
        assertEq(historicalVault.totalDepositedByToken(TOKEN), historicalTotal);
        (bool ok, bytes memory data) =
            ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok, "historical OI unavailable");
        assertEq(abi.decode(data, (uint256)), 7);
    }

    function testLegacyPricePathIsIsolatedAndCollateralUnchanged() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_041_332);
        OptionProductRegistry registry = OptionProductRegistry(REGISTRY);
        CollateralVault vault = CollateralVault(VAULT);
        assertEq(registry.owner(), TIMELOCK);
        uint256 accountingBefore = vault.totalDepositedByToken(TOKEN);
        uint256 assetsBefore = IERC20(TOKEN).balanceOf(VAULT);
        (bool ok, bytes memory data) =
            ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok, "missing OI");
        uint256 shortOiBefore = abi.decode(data, (uint256));
        assertEq(shortOiBefore, 7);

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
        vm.prank(TIMELOCK); // fork-only impersonation, not a Safe signature
        registry.transferOwnership(address(verifier));
        vm.prank(TIMELOCK);
        verifier.acceptRegistryOwnership();
        assertEq(registry.owner(), address(verifier));
        uint256[] memory historicalIds = registry.getAllOptionIds();
        assertEq(historicalIds.length, 2);
        for (uint256 i; i < historicalIds.length; ++i) {
            assertTrue(verifier.legacySeries(historicalIds[i]));
            assertFalse(verifier.settlementEligible(historicalIds[i]));
        }
        assertTrue(verifier.legacySeries(ETH_CALL));
        assertFalse(verifier.settlementEligible(ETH_CALL));
        vm.prank(TIMELOCK);
        uint256 newSeries = verifier.createInactiveCallSeries(ETH, uint64(block.timestamp + 30 days), 3_000e8);
        assertTrue(verifier.settlementEligible(newSeries));
        assertFalse(verifier.legacySeries(newSeries));
        assertFalse(registry.getSeries(newSeries).isActive);
        (ok, data) = ENGINE.staticcall(abi.encodeWithSignature("optionRegistry()"));
        require(ok, "engine registry unreadable");
        assertEq(abi.decode(data, (address)), REGISTRY);
        (ok, data) = ENGINE.staticcall(abi.encodeWithSignature("matchingEngine()"));
        require(ok, "matching engine unreadable");
        address matching = abi.decode(data, (address));
        (ok, data) = matching.staticcall(abi.encodeWithSignature("optionRegistry()"));
        require(ok, "matching registry unreadable");
        assertEq(abi.decode(data, (address)), REGISTRY);
        vm.prank(TIMELOCK);
        vm.expectRevert(VerifiedOptionSettlementOwner.LegacySeriesRestricted.selector);
        verifier.finalizeLegacyPrice(newSeries, 1e8);
        vm.prank(TIMELOCK);
        verifier.executeRegistryAdmin(abi.encodeCall(registry.unpauseSettlement, ()));
        vm.warp(registry.getSeries(ETH_CALL).expiry);
        vm.prank(TIMELOCK);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.setSettlementPrice(ETH_CALL, 1e8);
        vm.prank(address(0xBAD));
        vm.expectRevert(VerifiedOptionSettlementOwner.NotTimelock.selector);
        verifier.finalizeLegacyPrice(ETH_CALL, 1e8);
        vm.prank(TIMELOCK);
        verifier.finalizeLegacyPrice(ETH_CALL, 1e8);
        (uint256 historicalPrice, bool historicalFinalized) = registry.getSettlementInfo(ETH_CALL);
        assertTrue(historicalFinalized);
        assertEq(historicalPrice, 1e8);
        vm.prank(TIMELOCK);
        vm.expectRevert(OptionProductRegistry.SettlementAlreadySet.selector);
        verifier.finalizeLegacyPrice(ETH_CALL, 2e8);
        assertEq(vault.totalDepositedByToken(TOKEN), accountingBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), assetsBefore);
        (ok, data) = ENGINE.staticcall(abi.encodeWithSignature("seriesShortOpenInterest(uint256)", ETH_CALL));
        require(ok, "missing OI after attempted transfer");
        assertEq(abi.decode(data, (uint256)), shortOiBefore);
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
        // A signed update from later in the allowed window is not the
        // unique first update after this earlier expiry.
        vm.expectRevert();
        IHistoricalPyth(PYTH).parsePriceFeedUpdatesUnique{value: fee}(updates, ids, publishTime - 1_500, publishTime);
    }

    function testAuthenticPythFallbackRequiresStalePrimaryBoundary() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_064_571);
        uint64 expiry = 1_793_934_781;
        bytes[] memory updates = new bytes[](1);
        updates[0] = vm.parseBytes(vm.readFile("test/fixtures/options_v9_pyth_core_eth_payload.hex"));
        uint256 fee = IHistoricalPyth(PYTH).getUpdateFee(updates);

        vm.warp(expiry - 100);
        OptionProductRegistry localRegistry = new OptionProductRegistry(address(this));
        localRegistry.setSettlementAssetAllowed(TOKEN, true);
        localRegistry.setUnderlyingConfig(ETH, OptionProductRegistry.UnderlyingConfig(address(0), 0, 0, 0, 0, true));
        ForkChainlinkBoundaryStub staleBoundary = new ForkChainlinkBoundaryStub(expiry, true);
        address[2] memory underlyings = [ETH, BTC];
        address[2] memory feeds = [address(staleBoundary), BTC_FEED];
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
        uint256 series = verifier.createInactiveCallSeries(ETH, expiry, 2000e8);
        verifier.executeRegistryAdmin(abi.encodeCall(localRegistry.unpauseSettlement, ()));

        vm.warp(expiry + 2);
        vm.expectRevert(VerifiedOptionSettlementOwner.InvalidRoundProof.selector);
        verifier.propose(series, 101, 102);
        uint256 fallbackGasStart = gasleft();
        verifier.proposePythFallback{value: fee}(series, 101, 102, updates);
        emit log_named_uint("AUTHENTIC_PYTH_FALLBACK_GAS", fallbackGasStart - gasleft());
        vm.warp(block.timestamp + 2 days);
        verifier.resolve(series);
        verifier.finalize(series);
        (uint256 price, bool finalized) = localRegistry.getSettlementInfo(series);
        assertTrue(finalized);
        assertEq(price, 223_785_865_763);
    }

    function testAuthenticPythCoreDisputeBlocksFinalizationOnFork() public {
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
        ForkChainlinkBoundaryStub boundary = new ForkChainlinkBoundaryStub(expiry, false);
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
        vm.expectRevert(VerifiedOptionSettlementOwner.UnresolvedDivergence.selector);
        verifier.resolve(series);
        (uint256 price, bool finalized) = localRegistry.getSettlementInfo(series);
        assertFalse(finalized);
        assertEq(price, 0);
        vm.expectRevert(VerifiedOptionSettlementOwner.UnresolvedDivergence.selector);
        verifier.resolve(series);
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
