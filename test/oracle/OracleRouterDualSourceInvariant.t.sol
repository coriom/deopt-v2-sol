// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IPriceSource} from "../../src/oracle/IPriceSource.sol";
import {MockPriceSource} from "../../src/oracle/MockPriceSource.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";

/// @title OracleRouterDualSourceInvariantTest
/// @notice Coverage for the PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 (Part A) OracleRouter
///         hardening: an active feed MUST have BOTH a non-zero secondary source AND a non-zero
///         `maxDeviationBps`.
/// @dev
///  This closes the audit finding where `setFeed` and `setFeedStatus` silently allowed a
///  solo-primary active configuration, bypassing the dual-source deviation check inside
///  `_readConfiguredFeed`. Deactivating an existing solo-primary feed remains allowed
///  (reactivation is blocked until governance provides a paired secondary + non-zero bound).
contract OracleRouterDualSourceInvariantTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address internal constant OWNER = address(0xA11CE);
    address internal constant NOT_OWNER = address(0xBAAAD);

    address internal constant BASE_ASSET = address(0x1111111111111111111111111111111111111111);
    address internal constant QUOTE_ASSET = address(0x2222222222222222222222222222222222222222);

    uint256 internal constant PRICE_1E8 = 2_000 * 1e8;

    uint32 internal constant MAX_DELAY = 60;
    uint16 internal constant DEV_BPS = 100; // 1%

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    OracleRouter internal router;
    MockPriceSource internal primary;
    MockPriceSource internal secondary;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        vm.warp(1_000);

        vm.prank(OWNER);
        router = new OracleRouter(OWNER);

        primary = new MockPriceSource(PRICE_1E8, block.timestamp);
        secondary = new MockPriceSource(PRICE_1E8, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                    setFeed: SOLO PRIMARY BLOCKED
    //////////////////////////////////////////////////////////////*/

    function testSetFeedActiveWithZeroSecondaryReverts() external {
        vm.prank(OWNER);
        vm.expectRevert(OracleRouter.SecondarySourceRequired.selector);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, IPriceSource(address(0)), MAX_DELAY, DEV_BPS, true);
    }

    function testSetFeedActiveWithZeroDeviationBpsReverts() external {
        vm.prank(OWNER);
        vm.expectRevert(OracleRouter.SecondarySourceRequired.selector);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, 0, true);
    }

    function testSetFeedActiveWithZeroSecondaryAndZeroDeviationReverts() external {
        vm.prank(OWNER);
        vm.expectRevert(OracleRouter.SecondarySourceRequired.selector);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, IPriceSource(address(0)), MAX_DELAY, 0, true);
    }

    function testSetFeedActiveWithSecondaryAndDeviationSucceeds() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, DEV_BPS, true);

        assertTrue(router.hasActiveFeed(BASE_ASSET, QUOTE_ASSET));

        OracleRouter.FeedConfig memory cfg = router.getFeed(BASE_ASSET, QUOTE_ASSET);
        assertEq(address(cfg.primarySource), address(primary));
        assertEq(address(cfg.secondarySource), address(secondary));
        assertEq(uint256(cfg.maxDelay), uint256(MAX_DELAY));
        assertEq(uint256(cfg.maxDeviationBps), uint256(DEV_BPS));
        assertTrue(cfg.isActive);
    }

    /*//////////////////////////////////////////////////////////////
        setFeed: INACTIVE PATH STILL ALLOWED (including solo primary)
    //////////////////////////////////////////////////////////////*/

    function testSetFeedInactiveWithSoloPrimaryIsAllowed() external {
        // Inactive feeds do not participate in reads and hence do not need the dual-source
        // invariant. This is important for staging: an operator may pre-register a primary
        // and later pair a secondary before flipping to active.
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, IPriceSource(address(0)), MAX_DELAY, DEV_BPS, false);

        OracleRouter.FeedConfig memory cfg = router.getFeed(BASE_ASSET, QUOTE_ASSET);
        assertFalse(cfg.isActive);
        assertEq(address(cfg.primarySource), address(primary));
        assertEq(address(cfg.secondarySource), address(0));
        assertFalse(router.hasActiveFeed(BASE_ASSET, QUOTE_ASSET));
    }

    function testSetFeedInactiveWithZeroDeviationIsAllowed() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, 0, false);

        OracleRouter.FeedConfig memory cfg = router.getFeed(BASE_ASSET, QUOTE_ASSET);
        assertFalse(cfg.isActive);
    }

    /*//////////////////////////////////////////////////////////////
                setFeedStatus: FLIPPING TO ACTIVE
    //////////////////////////////////////////////////////////////*/

    function testSetFeedStatusFlipToActiveWithSoloPrimaryReverts() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, IPriceSource(address(0)), MAX_DELAY, DEV_BPS, false);

        vm.prank(OWNER);
        vm.expectRevert(OracleRouter.SecondarySourceRequired.selector);
        router.setFeedStatus(BASE_ASSET, QUOTE_ASSET, true);
    }

    function testSetFeedStatusFlipToActiveWithZeroDeviationReverts() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, 0, false);

        vm.prank(OWNER);
        vm.expectRevert(OracleRouter.SecondarySourceRequired.selector);
        router.setFeedStatus(BASE_ASSET, QUOTE_ASSET, true);
    }

    function testSetFeedStatusFlipToActiveWithSecondaryAndDeviationSucceeds() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, DEV_BPS, false);

        vm.prank(OWNER);
        router.setFeedStatus(BASE_ASSET, QUOTE_ASSET, true);

        assertTrue(router.getFeed(BASE_ASSET, QUOTE_ASSET).isActive);
        assertTrue(router.hasActiveFeed(BASE_ASSET, QUOTE_ASSET));
    }

    /*//////////////////////////////////////////////////////////////
                setFeedStatus: FLIPPING TO INACTIVE
    //////////////////////////////////////////////////////////////*/

    function testSetFeedStatusDeactivatingAFeedIsAlwaysAllowed() external {
        // Register a valid dual-source active feed.
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, DEV_BPS, true);
        assertTrue(router.getFeed(BASE_ASSET, QUOTE_ASSET).isActive);

        // Deactivation MUST always be allowed (guardian/governance emergency lever).
        vm.prank(OWNER);
        router.setFeedStatus(BASE_ASSET, QUOTE_ASSET, false);
        assertFalse(router.getFeed(BASE_ASSET, QUOTE_ASSET).isActive);
    }

    function testSetFeedStatusDeactivatingASoloPrimaryFeedIsStillAllowed() external {
        // Legacy staging path: operator has a solo-primary feed that was previously registered
        // as inactive. They can toggle inactive->inactive, or here the "no-op" false->false.
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, IPriceSource(address(0)), MAX_DELAY, DEV_BPS, false);

        vm.prank(OWNER);
        router.setFeedStatus(BASE_ASSET, QUOTE_ASSET, false);
        assertFalse(router.getFeed(BASE_ASSET, QUOTE_ASSET).isActive);
    }

    /*//////////////////////////////////////////////////////////////
                clearFeed still works (no dual-source ties)
    //////////////////////////////////////////////////////////////*/

    function testClearFeedWorksAfterActiveDualSourceConfiguration() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, DEV_BPS, true);

        vm.prank(OWNER);
        router.clearFeed(BASE_ASSET, QUOTE_ASSET);

        OracleRouter.FeedConfig memory cfg = router.getFeed(BASE_ASSET, QUOTE_ASSET);
        assertEq(address(cfg.primarySource), address(0));
        assertEq(address(cfg.secondarySource), address(0));
        assertFalse(cfg.isActive);
    }

    /*//////////////////////////////////////////////////////////////
                    AUTHORIZATION UNCHANGED
    //////////////////////////////////////////////////////////////*/

    function testOnlyOwnerCanSetFeed() external {
        vm.prank(NOT_OWNER);
        vm.expectRevert(OracleRouter.NotAuthorized.selector);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, DEV_BPS, true);
    }

    function testOnlyOwnerCanSetFeedStatus() external {
        vm.prank(OWNER);
        router.setFeed(BASE_ASSET, QUOTE_ASSET, primary, secondary, MAX_DELAY, DEV_BPS, true);

        vm.prank(NOT_OWNER);
        vm.expectRevert(OracleRouter.NotAuthorized.selector);
        router.setFeedStatus(BASE_ASSET, QUOTE_ASSET, false);
    }
}
