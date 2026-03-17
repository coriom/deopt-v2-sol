// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";

contract OptionProductRegistryTest is Test {
    OptionProductRegistry internal registry;

    address internal owner = address(0xA11CE);
    address internal guardian = address(0xB0B);
    address internal alice = address(0xCAFE);
    address internal settlementOperator = address(0xD00D);

    address internal underlying = address(0x1001);
    address internal settlementAsset = address(0x2002);
    address internal otherSettlementAsset = address(0x2003);
    address internal oracle = address(0x3003);

    uint64 internal constant STRIKE = 2_000e8;

    function setUp() public {
        vm.prank(owner);
        registry = new OptionProductRegistry(owner);

        vm.startPrank(owner);
        registry.setUnderlyingConfig(
            underlying,
            OptionProductRegistry.UnderlyingConfig({
                oracle: oracle,
                spotShockDownBps: 2_500,
                spotShockUpBps: 2_500,
                volShockDownBps: 500,
                volShockUpBps: 1_500,
                isEnabled: true
            })
        );
        registry.setSettlementAssetAllowed(settlementAsset, true);
        registry.setSettlementAssetAllowed(otherSettlementAsset, true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _futureExpiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _computeId(
        address _underlying,
        address _settlementAsset,
        uint64 expiry,
        uint64 strike,
        bool isCall,
        bool isEuropean
    ) internal pure returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(
                    _underlying,
                    _settlementAsset,
                    expiry,
                    strike,
                    uint128(1e8),
                    isCall,
                    isEuropean
                )
            )
        );
    }

    function _createDefaultSeries() internal returns (uint256 optionId, uint64 expiry) {
        expiry = _futureExpiry();

        vm.prank(owner);
        optionId = registry.createSeries(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );
    }

    function _createDefaultSeriesWithSettlementDelay()
        internal
        returns (uint256 optionId, uint64 expiry)
    {
        vm.prank(owner);
        registry.setSettlementFinalityDelay(1 days);

        return _createDefaultSeries();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR / INIT
    //////////////////////////////////////////////////////////////*/

    function test_constructor_initializes_core_state() public {
        assertEq(registry.owner(), owner);
        assertEq(registry.pendingOwner(), address(0));
        assertEq(registry.guardian(), address(0));
        assertEq(registry.minExpiryDelay(), 0);
        assertEq(registry.settlementFinalityDelay(), 0);
        assertEq(registry.totalSeries(), 0);
        assertTrue(registry.isSeriesCreator(owner));
        assertFalse(registry.paused());
        assertFalse(registry.creationPaused());
        assertFalse(registry.settlementPaused());
        assertFalse(registry.configPaused());
    }

    function test_constructor_reverts_on_zero_owner() public {
        vm.expectRevert(OptionProductRegistry.ZeroAddress.selector);
        new OptionProductRegistry(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_transferOwnership_acceptOwnership_flow() public {
        vm.prank(owner);
        registry.transferOwnership(alice);

        assertEq(registry.pendingOwner(), alice);

        vm.prank(alice);
        registry.acceptOwnership();

        assertEq(registry.owner(), alice);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_transferOwnership_reverts_if_not_owner() public {
        vm.prank(alice);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.transferOwnership(alice);
    }

    function test_acceptOwnership_reverts_if_not_pendingOwner() public {
        vm.prank(owner);
        registry.transferOwnership(alice);

        vm.prank(guardian);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.acceptOwnership();
    }

    function test_cancelOwnershipTransfer() public {
        vm.prank(owner);
        registry.transferOwnership(alice);

        vm.prank(owner);
        registry.cancelOwnershipTransfer();

        assertEq(registry.pendingOwner(), address(0));
    }

    function test_cancelOwnershipTransfer_reverts_if_no_pending_transfer() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.OwnershipTransferNotInitiated.selector);
        registry.cancelOwnershipTransfer();
    }

    function test_renounceOwnership() public {
        vm.prank(owner);
        registry.renounceOwnership();

        assertEq(registry.owner(), address(0));
    }

    function test_renounceOwnership_reverts_if_pending_owner_exists() public {
        vm.prank(owner);
        registry.transferOwnership(alice);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function test_setGuardian_and_clearGuardian() public {
        vm.prank(owner);
        registry.setGuardian(guardian);
        assertEq(registry.guardian(), guardian);

        vm.prank(owner);
        registry.clearGuardian();
        assertEq(registry.guardian(), address(0));
    }

    function test_setGuardian_reverts_on_zero() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.ZeroAddress.selector);
        registry.setGuardian(address(0));
    }

    function test_pause_by_guardian_unpause_only_owner() public {
        vm.prank(owner);
        registry.setGuardian(guardian);

        vm.prank(guardian);
        registry.pause();

        assertTrue(registry.paused());

        vm.prank(guardian);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.unpause();

        vm.prank(owner);
        registry.unpause();

        assertFalse(registry.paused());
    }

    function test_setEmergencyModes_by_guardian() public {
        vm.prank(owner);
        registry.setGuardian(guardian);

        vm.prank(guardian);
        registry.setEmergencyModes(true, true, true);

        assertTrue(registry.creationPaused());
        assertTrue(registry.settlementPaused());
        assertTrue(registry.configPaused());
    }

    function test_clearEmergencyModes_only_owner() public {
        vm.prank(owner);
        registry.setGuardian(guardian);

        vm.prank(guardian);
        registry.setEmergencyModes(true, true, true);

        vm.prank(owner);
        registry.clearEmergencyModes();

        assertFalse(registry.creationPaused());
        assertFalse(registry.settlementPaused());
        assertFalse(registry.configPaused());
    }

    function test_pauseCreation_by_guardian() public {
        vm.prank(owner);
        registry.setGuardian(guardian);

        vm.prank(guardian);
        registry.pauseCreation();

        assertTrue(registry.creationPaused());

        vm.prank(guardian);
        vm.expectRevert(OptionProductRegistry.GuardianNotAuthorized.selector);
        registry.unpauseCreation();

        vm.prank(owner);
        registry.unpauseCreation();

        assertFalse(registry.creationPaused());
    }

    function test_pauseSettlement_by_guardian() public {
        vm.prank(owner);
        registry.setGuardian(guardian);

        vm.prank(guardian);
        registry.pauseSettlement();

        assertTrue(registry.settlementPaused());

        vm.prank(owner);
        registry.unpauseSettlement();

        assertFalse(registry.settlementPaused());
    }

    function test_pauseConfig_by_guardian() public {
        vm.prank(owner);
        registry.setGuardian(guardian);

        vm.prank(guardian);
        registry.pauseConfig();

        assertTrue(registry.configPaused());

        vm.prank(owner);
        registry.unpauseConfig();

        assertFalse(registry.configPaused());
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function test_setUnderlyingConfig() public {
        address newUnderlying = address(0x9999);

        vm.prank(owner);
        registry.setUnderlyingConfig(
            newUnderlying,
            OptionProductRegistry.UnderlyingConfig({
                oracle: oracle,
                spotShockDownBps: 1_000,
                spotShockUpBps: 2_000,
                volShockDownBps: 100,
                volShockUpBps: 500,
                isEnabled: true
            })
        );

        (
            address cfgOracle,
            uint64 down,
            uint64 up,
            uint64 volDown,
            uint64 volUp,
            bool enabled
        ) = registry.underlyingConfigs(newUnderlying);

        assertEq(cfgOracle, oracle);
        assertEq(down, 1_000);
        assertEq(up, 2_000);
        assertEq(volDown, 100);
        assertEq(volUp, 500);
        assertTrue(enabled);
    }

    function test_setUnderlyingConfig_reverts_if_invalid_spot_shock() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.InvalidUnderlyingConfig.selector);
        registry.setUnderlyingConfig(
            underlying,
            OptionProductRegistry.UnderlyingConfig({
                oracle: oracle,
                spotShockDownBps: 10_001,
                spotShockUpBps: 0,
                volShockDownBps: 0,
                volShockUpBps: 0,
                isEnabled: true
            })
        );
    }

    function test_setUnderlyingConfig_reverts_if_invalid_vol_shock() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.InvalidUnderlyingConfig.selector);
        registry.setUnderlyingConfig(
            underlying,
            OptionProductRegistry.UnderlyingConfig({
                oracle: oracle,
                spotShockDownBps: 0,
                spotShockUpBps: 0,
                volShockDownBps: 5_001,
                volShockUpBps: 0,
                isEnabled: true
            })
        );
    }

    function test_setSettlementAssetAllowed_reverts_on_zero() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.SettlementZero.selector);
        registry.setSettlementAssetAllowed(address(0), true);
    }

    function test_setMinExpiryDelay() public {
        vm.prank(owner);
        registry.setMinExpiryDelay(2 days);

        assertEq(registry.minExpiryDelay(), 2 days);
    }

    function test_setSettlementFinalityDelay_reverts_if_too_large() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.InvalidDelay.selector);
        registry.setSettlementFinalityDelay(8 days);
    }

    function test_setSeriesCreator_reverts_when_config_paused() public {
        vm.prank(owner);
        registry.pauseConfig();

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.ConfigPausedError.selector);
        registry.setSeriesCreator(alice, true);
    }

    /*//////////////////////////////////////////////////////////////
                            SERIES CREATION
    //////////////////////////////////////////////////////////////*/

    function test_createSeries_success_and_stores_series() public {
        uint64 expiry = _futureExpiry();

        vm.prank(owner);
        uint256 optionId = registry.createSeries(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );

        (
            address sUnderlying,
            address sSettlementAsset,
            uint64 sExpiry,
            uint64 sStrike,
            uint128 sContractSize,
            bool sIsCall,
            bool sIsEuropean,
            bool sExists,
            bool sIsActive
        ) = registry.getSeries(optionId);

        assertEq(sUnderlying, underlying);
        assertEq(sSettlementAsset, settlementAsset);
        assertEq(sExpiry, expiry);
        assertEq(sStrike, STRIKE);
        assertEq(uint256(sContractSize), 1e8);
        assertTrue(sIsCall);
        assertTrue(sIsEuropean);
        assertTrue(sExists);
        assertTrue(sIsActive);

        assertEq(registry.totalSeries(), 1);
        assertTrue(registry.seriesExists(optionId));
    }

    function test_createSeries_returns_expected_optionId() public {
        uint64 expiry = _futureExpiry();
        uint256 expectedId = _computeId(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );

        vm.prank(owner);
        uint256 optionId = registry.createSeries(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );

        assertEq(optionId, expectedId);
    }

    function test_createSeries_reverts_if_not_series_creator() public {
        vm.prank(alice);
        vm.expectRevert(OptionProductRegistry.NotAuthorized.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_creation_paused() public {
        vm.prank(owner);
        registry.pauseCreation();

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.CreationPaused.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_global_pause() public {
        vm.prank(owner);
        registry.pause();

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.CreationPaused.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_underlying_zero() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.UnderlyingZero.selector);
        registry.createSeries(
            address(0),
            settlementAsset,
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_settlement_zero() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.SettlementZero.selector);
        registry.createSeries(
            underlying,
            address(0),
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_underlying_not_enabled() public {
        address disabledUnderlying = address(0x7777);

        vm.prank(owner);
        registry.setUnderlyingConfig(
            disabledUnderlying,
            OptionProductRegistry.UnderlyingConfig({
                oracle: oracle,
                spotShockDownBps: 100,
                spotShockUpBps: 100,
                volShockDownBps: 100,
                volShockUpBps: 100,
                isEnabled: false
            })
        );

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.UnderlyingNotEnabled.selector);
        registry.createSeries(
            disabledUnderlying,
            settlementAsset,
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_settlement_asset_not_allowed() public {
        address forbiddenSettlement = address(0xABCD);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.SettlementAssetNotAllowed.selector);
        registry.createSeries(
            underlying,
            forbiddenSettlement,
            _futureExpiry(),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_expiry_in_past() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.ExpiryInPast.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            uint64(block.timestamp),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_expiry_too_soon() public {
        vm.prank(owner);
        registry.setMinExpiryDelay(3 days);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.ExpiryTooSoon.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            uint64(block.timestamp + 2 days),
            STRIKE,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_strike_zero() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.StrikeZero.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            _futureExpiry(),
            0,
            true,
            true
        );
    }

    function test_createSeries_reverts_if_contract_size_not_standard() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.InvalidContractSize.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            _futureExpiry(),
            STRIKE,
            uint128(2e8),
            true,
            true
        );
    }

    function test_createSeries_reverts_if_duplicate_series() public {
        uint64 expiry = _futureExpiry();

        vm.prank(owner);
        registry.createSeries(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.SeriesAlreadyExists.selector);
        registry.createSeries(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );
    }

    function test_createStrip_creates_calls_and_puts() public {
        uint64 expiry = _futureExpiry();
        uint64;
        strikes[0] = 1_800e8;
        strikes[1] = 2_000e8;

        vm.prank(owner);
        registry.createStrip(underlying, settlementAsset, expiry, strikes, true);

        assertEq(registry.totalSeries(), 4);

        uint256[] memory ids = registry.getSeriesByUnderlying(underlying);
        assertEq(ids.length, 4);
    }

    function test_createStrip_reverts_if_empty_strikes() public {
        uint64;

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.EmptyStrikes.selector);
        registry.createStrip(underlying, settlementAsset, _futureExpiry(), strikes, true);
    }

    /*//////////////////////////////////////////////////////////////
                            SERIES ADMIN
    //////////////////////////////////////////////////////////////*/

    function test_setSeriesActive() public {
        (uint256 optionId,) = _createDefaultSeries();

        vm.prank(owner);
        registry.setSeriesActive(optionId, false);

        (, , , , , , , , bool isActive) = registry.getSeries(optionId);
        assertFalse(isActive);
    }

    function test_setSeriesActive_reverts_if_unknown_series() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.UnknownSeries.selector);
        registry.setSeriesActive(12345, false);
    }

    function test_setSeriesMetadata() public {
        (uint256 optionId,) = _createDefaultSeries();
        bytes32 metadata = keccak256("ipfs://series");

        vm.prank(owner);
        registry.setSeriesMetadata(optionId, metadata);

        assertEq(registry.seriesMetadata(optionId), metadata);
    }

    function test_setSeriesMetadata_reverts_if_unknown_series() public {
        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.UnknownSeries.selector);
        registry.setSeriesMetadata(999, keccak256("x"));
    }

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_settlement_immediate_when_finality_delay_zero() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeries();

        vm.warp(expiry + 1);

        vm.prank(owner);
        registry.setSettlementPrice(optionId, 2_100e8);

        (uint256 px, bool isSet) = registry.getSettlementInfo(optionId);
        assertEq(px, 2_100e8);
        assertTrue(isSet);
        assertTrue(registry.isSettled(optionId));
    }

    function test_settlement_two_phase_flow() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeriesWithSettlementDelay();

        vm.prank(owner);
        registry.setSettlementOperator(settlementOperator);

        vm.warp(expiry + 1);

        vm.prank(settlementOperator);
        registry.setSettlementPrice(optionId, 2_100e8);

        (uint256 proposedPrice, uint64 proposedAt, bool exists) = registry.getSettlementProposal(optionId);
        assertEq(proposedPrice, 2_100e8);
        assertGt(proposedAt, 0);
        assertTrue(exists);

        vm.prank(settlementOperator);
        vm.expectRevert(OptionProductRegistry.SettlementFinalityDelayNotElapsed.selector);
        registry.finalizeSettlementPrice(optionId);

        vm.warp(block.timestamp + 1 days);

        vm.prank(settlementOperator);
        registry.finalizeSettlementPrice(optionId);

        (uint256 px, bool isSet) = registry.getSettlementInfo(optionId);
        assertEq(px, 2_100e8);
        assertTrue(isSet);
    }

    function test_cancelSettlementProposal() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeriesWithSettlementDelay();

        vm.warp(expiry + 1);

        vm.prank(owner);
        registry.setSettlementPrice(optionId, 2_100e8);

        vm.prank(owner);
        registry.cancelSettlementProposal(optionId);

        (uint256 proposedPrice, uint64 proposedAt, bool exists) = registry.getSettlementProposal(optionId);
        assertEq(proposedPrice, 0);
        assertEq(proposedAt, 0);
        assertFalse(exists);
    }

    function test_setSettlementPrice_reverts_if_settlement_paused() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeries();

        vm.prank(owner);
        registry.pauseSettlement();

        vm.warp(expiry + 1);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.SettlementPaused.selector);
        registry.setSettlementPrice(optionId, 2_100e8);
    }

    function test_setSettlementPrice_reverts_if_not_expired() public {
        (uint256 optionId,) = _createDefaultSeries();

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.NotExpiredYet.selector);
        registry.setSettlementPrice(optionId, 2_100e8);
    }

    function test_setSettlementPrice_reverts_if_zero_price() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeries();

        vm.warp(expiry + 1);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.SettlementPriceZero.selector);
        registry.setSettlementPrice(optionId, 0);
    }

    function test_setSettlementPrice_reverts_if_already_settled() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeries();

        vm.warp(expiry + 1);

        vm.startPrank(owner);
        registry.setSettlementPrice(optionId, 2_100e8);

        vm.expectRevert(OptionProductRegistry.SettlementAlreadySet.selector);
        registry.setSettlementPrice(optionId, 2_200e8);
        vm.stopPrank();
    }

    function test_finalizeSettlementPrice_reverts_if_no_proposal() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeriesWithSettlementDelay();

        vm.warp(expiry + 1);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.NoSettlementProposal.selector);
        registry.finalizeSettlementPrice(optionId);
    }

    function test_cancelSettlementProposal_reverts_if_no_proposal() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeriesWithSettlementDelay();

        vm.warp(expiry + 1);

        vm.prank(owner);
        vm.expectRevert(OptionProductRegistry.NoSettlementProposal.selector);
        registry.cancelSettlementProposal(optionId);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_getSeriesIfExists_returns_false_for_unknown() public {
        (OptionProductRegistry.OptionSeries memory s, bool exists) = registry.getSeriesIfExists(123);
        assertFalse(exists);
        assertFalse(s.exists);
    }

    function test_seriesAt_and_totalSeries() public {
        (uint256 optionId,) = _createDefaultSeries();

        assertEq(registry.totalSeries(), 1);
        assertEq(registry.seriesAt(0), optionId);

        vm.expectRevert(OptionProductRegistry.IndexOutOfBounds.selector);
        registry.seriesAt(1);
    }

    function test_getAllOptionIdsSlice() public {
        (uint256 optionId1,) = _createDefaultSeries();

        uint64 expiry2 = uint64(block.timestamp + 9 days);
        vm.prank(owner);
        uint256 optionId2 = registry.createSeries(
            underlying,
            settlementAsset,
            expiry2,
            2_100e8,
            false,
            true
        );

        uint256[] memory slice = registry.getAllOptionIdsSlice(0, 2);
        assertEq(slice.length, 2);
        assertEq(slice[0], optionId1);
        assertEq(slice[1], optionId2);
    }

    function test_getSeriesByUnderlying_and_activeSeries() public {
        (uint256 optionId1,) = _createDefaultSeries();

        uint64 expiry2 = uint64(block.timestamp + 9 days);
        vm.prank(owner);
        uint256 optionId2 = registry.createSeries(
            underlying,
            settlementAsset,
            expiry2,
            2_100e8,
            false,
            true
        );

        uint256[] memory allIds = registry.getSeriesByUnderlying(underlying);
        assertEq(allIds.length, 2);
        assertEq(allIds[0], optionId1);
        assertEq(allIds[1], optionId2);

        vm.prank(owner);
        registry.setSeriesActive(optionId2, false);

        uint256[] memory activeIds = registry.getActiveSeriesByUnderlying(underlying);
        assertEq(activeIds.length, 1);
        assertEq(activeIds[0], optionId1);
    }

    function test_getSeriesEconomicParams() public {
        (uint256 optionId, uint64 expiry) = _createDefaultSeries();

        (
            address settlementAssetOut,
            uint64 strike,
            uint128 contractSize1e8,
            bool isCall,
            bool isEuropean,
            bool isActive,
            uint64 expiryOut
        ) = registry.getSeriesEconomicParams(optionId);

        assertEq(settlementAssetOut, settlementAsset);
        assertEq(strike, STRIKE);
        assertEq(uint256(contractSize1e8), 1e8);
        assertTrue(isCall);
        assertTrue(isEuropean);
        assertTrue(isActive);
        assertEq(expiryOut, expiry);
    }

    function test_getStrikeNotionalPerContract1e8() public {
        (uint256 optionId,) = _createDefaultSeries();
        uint256 notionnel = registry.getStrikeNotionalPerContract1e8(optionId);
        assertEq(notionnel, STRIKE);
    }

    function test_getStrikeNotional1e8() public {
        (uint256 optionId,) = _createDefaultSeries();
        uint256 notionnel = registry.getStrikeNotional1e8(optionId, 3);
        assertEq(notionnel, uint256(STRIKE) * 3);
    }

    function test_computeOptionId_matches_created_series_id() public {
        uint64 expiry = _futureExpiry();

        uint256 expected = registry.computeOptionId(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            uint128(1e8),
            true,
            true
        );

        vm.prank(owner);
        uint256 actual = registry.createSeries(
            underlying,
            settlementAsset,
            expiry,
            STRIKE,
            true,
            true
        );

        assertEq(expected, actual);
    }
}