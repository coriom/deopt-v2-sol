// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title MockCapabilityAuthority
/// @notice Minimal test-only stand-in for the CollateralVault v2 capability surface.
/// @dev Implements just the `engineCapabilityBits(address)` selector consumed by
///      SubaccountRegistry. Not a full ICollateralVault implementation.
contract MockCapabilityAuthority {
    mapping(address => uint256) private _bits;

    function setBits(address engine, uint256 bits) external {
        _bits[engine] = bits;
    }

    function engineCapabilityBits(address engine) external view returns (uint256) {
        return _bits[engine];
    }
}
