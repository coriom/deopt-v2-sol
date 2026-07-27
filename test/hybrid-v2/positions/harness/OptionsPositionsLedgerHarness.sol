// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionsPositionsLedger} from "../../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {PositionTypes} from "../../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title OptionsPositionsLedgerHarness
/// @notice Test-only inheritor that exposes storage seeding + accumulator peeks so
///         invariant + boundary tests can walk to hard limits (uint128 overflow,
///         active-series cap) without unbounded fuzz runtime.
contract OptionsPositionsLedgerHarness is OptionsPositionsLedger {
    constructor(address registry_, address capabilityAuthority_)
        OptionsPositionsLedger(registry_, capabilityAuthority_)
    {}

    /// @notice Directly seed a position row. Bypasses capability checks + event
    ///         emission. Test-only.
    function testForceSetPosition(bytes32 subKey, uint256 seriesId, PositionTypes.OptionPosition calldata p) external {
        bool wasActive = !_isPositionAllZero(_positions[subKey][seriesId]);
        _positions[subKey][seriesId] = p;
        bool nowActive =
            p.longQuantity1e8 != 0 || p.shortQuantity1e8 != 0 || p.premiumBasis1e8 != 0 || p.shortPremiumRecv1e8 != 0;
        if (!wasActive && nowActive) {
            unchecked {
                _activeSeriesCount[subKey] += 1;
            }
        } else if (wasActive && !nowActive) {
            uint32 c = _activeSeriesCount[subKey];
            if (c > 0) {
                unchecked {
                    _activeSeriesCount[subKey] = c - 1;
                }
            }
        }
    }

    /// @notice Directly seed the active-series counter to a boundary value.
    function testForceActiveSeriesCount(bytes32 subKey, uint32 value) external {
        _activeSeriesCount[subKey] = value;
    }
}
