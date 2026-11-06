// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {VerifiedOptionSettlementOwner} from "../../src/settlement/VerifiedOptionSettlementOwner.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        verifier.executeRegistryAdmin(abi.encodeCall(registry.setSeriesActive, (ETH_CALL, true)));
        assertTrue(registry.getSeries(ETH_CALL).isActive);

        assertEq(vault.totalDepositedByToken(TOKEN), accountingBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), assetsBefore);
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
        uint256 localSeries = localRegistry.createSeries(ETH, TOKEN, syntheticExpiry, 3000e8, 1e8, true, true);
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
        verifier.executeRegistryAdmin(abi.encodeCall(localRegistry.unpauseSettlement, ()));
        vm.warp(latestAt + 1);
        verifier.propose(localSeries, earlierId, latestId);
        vm.warp(block.timestamp + 2 days);
        verifier.finalize(localSeries);
        (uint256 settledPrice, bool finalized) = localRegistry.getSettlementInfo(localSeries);
        assertTrue(finalized);
        assertEq(settledPrice, uint256(earlierPrice));
    }
}
