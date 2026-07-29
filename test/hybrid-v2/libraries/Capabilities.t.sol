// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

/// @title CapabilitiesTest
/// @notice Ensures capability bits are unique + non-zero + within the reserved range.
/// @dev Enforces Principle 10 (least-privilege) at compile-time.
contract CapabilitiesTest is Test {
    /// @dev Every declared capability must be a distinct power-of-two bit within uint256.
    function test_allCapabilitiesArePowerOfTwo() external pure {
        _assertPow2(Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);
        _assertPow2(Capabilities.CAP_CREDIT_COLLATERAL);
        _assertPow2(Capabilities.CAP_WITHDRAW_FOR);
        _assertPow2(Capabilities.CAP_LOCK_COLLATERAL);
        _assertPow2(Capabilities.CAP_UNLOCK_OWN_RESERVATION);
        _assertPow2(Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA);
        _assertPow2(Capabilities.CAP_APPLY_PERP_POSITION_DELTA);
        _assertPow2(Capabilities.CAP_APPLY_FEE);
        _assertPow2(Capabilities.CAP_APPLY_REBATE);
        _assertPow2(Capabilities.CAP_SETTLE_OPTION);
        _assertPow2(Capabilities.CAP_LIQUIDATE_OPTIONS);
        _assertPow2(Capabilities.CAP_LIQUIDATE_PERPS);
        _assertPow2(Capabilities.CAP_EXECUTE_INTERNAL_TRANSFER);
        _assertPow2(Capabilities.CAP_CONSUME_REPLAY_NONCE);
        _assertPow2(Capabilities.CAP_RECOVERY_ACTIVATE);
    }

    /// @dev All declared capabilities must be pair-wise distinct.
    function test_allCapabilitiesAreUnique() external pure {
        uint256[15] memory caps = [
            Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT,
            Capabilities.CAP_CREDIT_COLLATERAL,
            Capabilities.CAP_WITHDRAW_FOR,
            Capabilities.CAP_LOCK_COLLATERAL,
            Capabilities.CAP_UNLOCK_OWN_RESERVATION,
            Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA,
            Capabilities.CAP_APPLY_PERP_POSITION_DELTA,
            Capabilities.CAP_APPLY_FEE,
            Capabilities.CAP_APPLY_REBATE,
            Capabilities.CAP_SETTLE_OPTION,
            Capabilities.CAP_LIQUIDATE_OPTIONS,
            Capabilities.CAP_LIQUIDATE_PERPS,
            Capabilities.CAP_EXECUTE_INTERNAL_TRANSFER,
            Capabilities.CAP_CONSUME_REPLAY_NONCE,
            Capabilities.CAP_RECOVERY_ACTIVATE
        ];

        for (uint256 i = 0; i < caps.length; i++) {
            assertTrue(caps[i] != 0, "no capability may be zero");
            for (uint256 j = i + 1; j < caps.length; j++) {
                assertTrue(caps[i] != caps[j], "capabilities must be pair-wise distinct");
            }
        }
    }

    /// @dev Bit-index anchoring: contract-spec 07 pins each bit's index.
    function test_capabilityBitIndicesMatchSpec07() external pure {
        assertEq(Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, uint256(1) << 0, "bit 0");
        assertEq(Capabilities.CAP_CREDIT_COLLATERAL, uint256(1) << 1, "bit 1");
        assertEq(Capabilities.CAP_WITHDRAW_FOR, uint256(1) << 2, "bit 2");
        assertEq(Capabilities.CAP_LOCK_COLLATERAL, uint256(1) << 3, "bit 3");
        assertEq(Capabilities.CAP_UNLOCK_OWN_RESERVATION, uint256(1) << 4, "bit 4");
        assertEq(Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, uint256(1) << 5, "bit 5");
        assertEq(Capabilities.CAP_APPLY_PERP_POSITION_DELTA, uint256(1) << 6, "bit 6");
        assertEq(Capabilities.CAP_APPLY_FEE, uint256(1) << 7, "bit 7");
        assertEq(Capabilities.CAP_APPLY_REBATE, uint256(1) << 8, "bit 8");
        assertEq(Capabilities.CAP_SETTLE_OPTION, uint256(1) << 9, "bit 9");
        assertEq(Capabilities.CAP_LIQUIDATE_OPTIONS, uint256(1) << 10, "bit 10");
        assertEq(Capabilities.CAP_LIQUIDATE_PERPS, uint256(1) << 11, "bit 11");
        assertEq(Capabilities.CAP_EXECUTE_INTERNAL_TRANSFER, uint256(1) << 12, "bit 12");
        assertEq(Capabilities.CAP_CONSUME_REPLAY_NONCE, uint256(1) << 13, "bit 13");
        assertEq(Capabilities.CAP_RECOVERY_ACTIVATE, uint256(1) << 14, "bit 14");
    }

    /// @dev HIGHEST_ASSIGNED_BIT bookkeeping. Bumped to 15 by
    ///      `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B) when
    ///      `CAP_APPLY_OPTIONS_PREMIUM = 1 << 15` was introduced.
    function test_highestAssignedBitMatchesHighestConstant() external pure {
        assertEq(Capabilities.HIGHEST_ASSIGNED_BIT, uint8(15), "highest bit index must be 15");
        assertEq(
            Capabilities.CAP_APPLY_OPTIONS_PREMIUM,
            uint256(1) << Capabilities.HIGHEST_ASSIGNED_BIT,
            "highest cap must sit at HIGHEST_ASSIGNED_BIT"
        );
    }

    /// @dev ALL_CAPABILITIES bitmap: bits 0..15 set, bits 16..255 clear.
    function test_allCapabilitiesBitmap() external pure {
        assertEq(Capabilities.ALL_CAPABILITIES, (uint256(1) << 16) - 1, "ALL_CAPABILITIES must set bits 0..15");
        assertEq(Capabilities.ALL_CAPABILITIES & (uint256(1) << 16), 0, "bit 16 must remain reserved (unset)");
        assertEq(Capabilities.ALL_CAPABILITIES & (uint256(1) << 255), 0, "bit 255 must remain reserved (unset)");
    }

    /// @dev Every declared capability must be present in the ALL_CAPABILITIES mask.
    function test_allDeclaredCapabilitiesAreCoveredByBitmap() external pure {
        uint256 mask = Capabilities.ALL_CAPABILITIES;
        assertEq(mask & Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);
        assertEq(mask & Capabilities.CAP_CREDIT_COLLATERAL, Capabilities.CAP_CREDIT_COLLATERAL);
        assertEq(mask & Capabilities.CAP_WITHDRAW_FOR, Capabilities.CAP_WITHDRAW_FOR);
        assertEq(mask & Capabilities.CAP_LOCK_COLLATERAL, Capabilities.CAP_LOCK_COLLATERAL);
        assertEq(mask & Capabilities.CAP_UNLOCK_OWN_RESERVATION, Capabilities.CAP_UNLOCK_OWN_RESERVATION);
        assertEq(mask & Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA);
        assertEq(mask & Capabilities.CAP_APPLY_PERP_POSITION_DELTA, Capabilities.CAP_APPLY_PERP_POSITION_DELTA);
        assertEq(mask & Capabilities.CAP_APPLY_FEE, Capabilities.CAP_APPLY_FEE);
        assertEq(mask & Capabilities.CAP_APPLY_REBATE, Capabilities.CAP_APPLY_REBATE);
        assertEq(mask & Capabilities.CAP_SETTLE_OPTION, Capabilities.CAP_SETTLE_OPTION);
        assertEq(mask & Capabilities.CAP_LIQUIDATE_OPTIONS, Capabilities.CAP_LIQUIDATE_OPTIONS);
        assertEq(mask & Capabilities.CAP_LIQUIDATE_PERPS, Capabilities.CAP_LIQUIDATE_PERPS);
        assertEq(mask & Capabilities.CAP_EXECUTE_INTERNAL_TRANSFER, Capabilities.CAP_EXECUTE_INTERNAL_TRANSFER);
        assertEq(mask & Capabilities.CAP_CONSUME_REPLAY_NONCE, Capabilities.CAP_CONSUME_REPLAY_NONCE);
        assertEq(mask & Capabilities.CAP_RECOVERY_ACTIVATE, Capabilities.CAP_RECOVERY_ACTIVATE);
        assertEq(mask & Capabilities.CAP_APPLY_OPTIONS_PREMIUM, Capabilities.CAP_APPLY_OPTIONS_PREMIUM);
    }

    /* -------------------------- internal helpers -------------------------- */

    function _assertPow2(uint256 x) internal pure {
        assertTrue(x != 0, "capability value must not be zero");
        assertEq(x & (x - 1), 0, "capability value must be a power of two");
    }
}
