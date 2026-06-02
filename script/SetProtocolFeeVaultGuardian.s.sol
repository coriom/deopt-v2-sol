// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolFeeVault} from "../src/fees/ProtocolFeeVault.sol";

/// @title SetProtocolFeeVaultGuardian
/// @notice V2G-RX.1 — safe-by-default owner-driven script that calls
///         {ProtocolFeeVault.setGuardian} so the vault has a
///         fast-pause guardian (typically the OPS_MULTISIG) before
///         the V2G-R5 cutover broadcast.
///
/// @dev    Required env:
///           - OWNER_PRIVATE_KEY              (owner key; never logged)
///           - PROTOCOL_FEE_VAULT             (target vault)
///           - PROTOCOL_FEE_VAULT_GUARDIAN    (new guardian; may be
///                                            address(0) ONLY with
///                                            ALLOW_ZERO_GUARDIAN_CONFIRM)
///           - SET_GUARDIAN_CONFIRM=true                   ← REQUIRED
///           - ALLOW_ZERO_GUARDIAN_CONFIRM=true  (only required when
///                                                intentionally
///                                                disabling fast-pause)
///
///         Hard rules:
///          - aborts on chain id 8453 (Base mainnet) unless an
///            explicit `MAINNET_OK=true` is also set.
///          - never broadcasts unless `SET_GUARDIAN_CONFIRM=true`.
///          - never prints the private key.
///          - refuses zero guardian unless
///            `ALLOW_ZERO_GUARDIAN_CONFIRM=true`.
contract SetProtocolFeeVaultGuardian is Script {
    error ProtocolFeeVaultUnset();
    error MainnetWithoutOk(uint256 chainId);
    error GuardianUnsetWithoutConfirm();
    error UnexpectedPostStateGuardian(address got, address expected);

    function run() external {
        uint256 ownerPk = vm.envUint("OWNER_PRIVATE_KEY");
        address owner = vm.addr(ownerPk);
        address vault = vm.envAddress("PROTOCOL_FEE_VAULT");
        address guardian_ = _envAddressOrZero("PROTOCOL_FEE_VAULT_GUARDIAN");
        bool confirmed = vm.envOr("SET_GUARDIAN_CONFIRM", false);
        bool allowZeroGuardian = vm.envOr("ALLOW_ZERO_GUARDIAN_CONFIRM", false);
        bool mainnetOk = vm.envOr("MAINNET_OK", false);

        if (vault == address(0)) revert ProtocolFeeVaultUnset();
        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }
        if (guardian_ == address(0) && !allowZeroGuardian) {
            revert GuardianUnsetWithoutConfirm();
        }

        console2.log("V2G-RX.1 SetProtocolFeeVaultGuardian preflight");
        console2.log("chainId                         ", block.chainid);
        console2.log("owner (sanitised, no key)       ", owner);
        console2.log("PROTOCOL_FEE_VAULT              ", vault);
        console2.log("PROTOCOL_FEE_VAULT_GUARDIAN     ", guardian_);
        console2.log("ALLOW_ZERO_GUARDIAN_CONFIRM     ", allowZeroGuardian);
        console2.log("SET_GUARDIAN_CONFIRM            ", confirmed);

        address current = ProtocolFeeVault(vault).guardian();
        console2.log("vault.guardian() (current)      ", current);

        if (!confirmed) {
            console2.log("SET_GUARDIAN_CONFIRM is not true; preflight only.");
            return;
        }

        vm.startBroadcast(ownerPk);
        ProtocolFeeVault(vault).setGuardian(guardian_);
        vm.stopBroadcast();

        address postState = ProtocolFeeVault(vault).guardian();
        if (postState != guardian_) {
            revert UnexpectedPostStateGuardian(postState, guardian_);
        }
        console2.log("vault.guardian() (post)         ", postState);
        console2.log("V2G-RX.1 guardian update complete.");
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
