// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {LiquidationStatus} from "../libraries/PositionTypes.sol";

/// @title IRiskModule
/// @notice Replaceable risk view boundary for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  This module is REPLACEABLE via ProtocolTimelock per contract-spec 06.
///  It owns NO canonical economic state. Every function is `view`.
///
///  Replacement compatibility is enforced by pairing `moduleVersion` with
///  `supportsCanonicalStorageVersion(uint16)`. A migration cutover MUST
///  observe `newModule.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION)`
///  before wiring the new module.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete RiskModuleV2 implementation lives in
///  `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-V1` (WP-07). This file introduces no state.
interface IRiskModule {
    /// @notice Aggregate required collateral value for `subKey` in 1e18 precision.
    function marginRequirement(bytes32 subKey) external view returns (uint256 requiredCollateralValue1e18);

    /// @notice Available collateral value (collateral - required) for `subKey` in 1e18 precision.
    function availableMargin(bytes32 subKey) external view returns (uint256 availableCollateralValue1e18);

    /// @notice Convenience: true when `marginRequirement <= collateralValue`.
    function marginHealthy(bytes32 subKey) external view returns (bool);

    /// @notice Ratio `availableMargin / marginRequirement` in 1e18 precision.
    /// @dev Returns `type(uint256).max` when `marginRequirement == 0`.
    function marginRatio(bytes32 subKey) external view returns (uint256 ratio1e18);

    /// @notice Pre-withdrawal check: returns true iff withdrawing `amount` of `token` from `subKey` is safe.
    function withdrawalAllowed(bytes32 subKey, address token, uint256 amount) external view returns (bool);

    /// @notice Pre-transfer check for the source side of an internal transfer.
    function transferAllowed(bytes32 sourceSubKey, address token, uint256 amount) external view returns (bool);

    /// @notice Aggregated liquidation status for `subKey`.
    function liquidationStatus(bytes32 subKey) external view returns (LiquidationStatus);

    /// @notice Product availability flags for `subKey`.
    /// @dev Returns `(optionsEnabled, perpsEnabled)`.
    function productsEnabled(bytes32 subKey) external view returns (bool optionsEnabled, bool perpsEnabled);

    /// @notice Risk-module version for governance + tooling tracking.
    function moduleVersion() external view returns (uint16);

    /// @notice Migration compatibility check.
    /// @dev A replacement module MUST return `true` for the storage version
    ///      it supports; the migration cutover MUST verify this before wiring.
    function supportsCanonicalStorageVersion(uint16 storageVersion) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RiskParamsSet(bytes32 indexed paramKey, bytes value, uint16 eventVersion);
    event RiskModuleActivated(uint16 moduleVersion, uint16 supportedStorageVersion, uint16 eventVersion);
    event LiquidationTriggered(bytes32 indexed subKey, LiquidationStatus status, uint16 eventVersion);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error RiskModuleUnavailable();
    error RiskParamsInvalid();
    error OracleUnavailable();
    error IncompatibleStorageVersion();
}
