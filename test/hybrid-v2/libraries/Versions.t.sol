// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title VersionsTest
/// @notice Anchors event / architecture / storage version + subaccount id sentinels.
contract VersionsTest is Test {
    function test_eventVersionIsOne() external pure {
        assertEq(Versions.EVENT_VERSION, uint16(1));
    }

    function test_architectureVersionIsOne() external pure {
        assertEq(Versions.ARCHITECTURE_VERSION, uint256(1));
    }

    function test_storageVersionIsOne() external pure {
        assertEq(Versions.STORAGE_VERSION, uint16(1));
    }

    function test_accountZeroIsInvalid() external pure {
        assertEq(Versions.SUBACCOUNT_ID_INVALID, uint32(0));
    }

    function test_accountOneIsDefault() external pure {
        assertEq(Versions.SUBACCOUNT_ID_DEFAULT, uint32(1));
    }

    function test_defaultDiffersFromInvalid() external pure {
        assertTrue(Versions.SUBACCOUNT_ID_DEFAULT != Versions.SUBACCOUNT_ID_INVALID);
    }
}
