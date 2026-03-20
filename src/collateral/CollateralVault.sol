// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CollateralVaultActions.sol";

contract CollateralVault is CollateralVaultActions {
    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;

        emit OwnershipTransferred(address(0), _owner);
        emit EmergencyModeUpdated(false, false, false, false);
    }
}