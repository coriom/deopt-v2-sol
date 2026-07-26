// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {FinalizationStatus, FallbackSource} from "../libraries/RecoveryTypes.sol";

/// @title IRecoveryFinalizer
/// @notice Fallback settlement finalization boundary for options in recovery.
/// @dev
///  Escape-hatch F-A → F-B → F-C → F-D hierarchy. F-D bounded emergency prices
///  require timelock queue + user challenge window + strict deviation corridor.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete RecoveryFinalizer implementation lives in
///  `ONCHAIN-SUBACCOUNT-RECOVERY-FINALIZER-V1-B` (WP-10B). This file introduces
///  no state.
interface IRecoveryFinalizer {
    /*//////////////////////////////////////////////////////////////
                               MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone MAY request fallback finalization for `optionId` after inactivity.
    /// @param optionId The option series id to finalize.
    /// @param sourceHint The preferred fallback source in the F-A → F-D hierarchy.
    /// @param historicalPriceProof Optional proof bytes used by F-C historical TWAP source.
    function requestFallbackFinalization(
        uint256 optionId,
        FallbackSource sourceHint,
        bytes calldata historicalPriceProof
    ) external;

    /// @notice Anyone MAY dispute an in-progress finalization within the dispute window.
    function disputeFallbackFinalization(uint256 optionId, FallbackSource competingSource, bytes calldata proof)
        external;

    /// @notice Anyone MAY finalize the pending fallback settlement after the dispute window closes.
    function finalizeFallbackSettlement(uint256 optionId) external;

    /// @notice Timelocked emergency price queueing for F-D.
    /// @dev Caller MUST be the ProtocolTimelock. Enforced deviation corridor.
    function queueEmergencyPrice(uint256 optionId, uint256 price1e8) external;

    /// @notice Guardian veto for a queued emergency price.
    function cancelEmergencyPrice(uint256 optionId) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function fallbackStatusOf(uint256 optionId) external view returns (FinalizationStatus);

    function pendingProposalOf(uint256 optionId) external view returns (uint256 price1e8, uint64 dueAt);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event FallbackFinalizationRequested(
        uint256 indexed optionId,
        FallbackSource indexed source,
        address indexed requester,
        uint256 proposedPrice1e8,
        uint64 disputeDeadline,
        uint16 eventVersion
    );

    event FallbackFinalizationDisputed(
        uint256 indexed optionId,
        FallbackSource indexed competingSource,
        address indexed disputer,
        uint256 competingPrice1e8,
        uint64 newDisputeDeadline,
        uint16 eventVersion
    );

    event FallbackPriceFinalized(
        uint256 indexed optionId, FallbackSource indexed source, uint256 price1e8, uint16 eventVersion
    );

    event EmergencyPriceQueued(
        uint256 indexed optionId, uint256 price1e8, uint64 challengeDeadline, uint16 eventVersion
    );

    event EmergencyPriceCancelled(uint256 indexed optionId, address indexed by, uint16 eventVersion);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SettlementFinalizerTimeoutNotElapsed();
    error AlreadySettled();
    error InvalidFallbackProof();
    error PriceDeviationTooHigh();
    error DisputeWindowActive();
    error NoPendingProposal();
    error EmergencyPriceOutOfCorridor();
}
