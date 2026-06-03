// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolFeeVault} from "../src/fees/ProtocolFeeVault.sol";

/// @title SetProtocolFeeVaultGuardian
/// @notice V2G-R5-P1 — keystore-mode hardening of the V2G-RX.1
///         safe-by-default owner-driven script that calls
///         {ProtocolFeeVault.setGuardian} so the vault has a
///         fast-pause guardian (typically the OPS_MULTISIG) before
///         the V2G-R5 cutover broadcast.
///
/// @dev    V2G-R5-P1 signer-source policy:
///           - When `OWNER_PRIVATE_KEY` is set + non-zero the script
///             derives the caller from the key and broadcasts via
///             `vm.startBroadcast(pk)`.
///           - When unset (or zero) the script broadcasts via no-arg
///             `vm.startBroadcast()` and defers signer resolution to
///             Foundry's `--account <keystore>` / `--sender <addr>`
///             CLI flags. The caller address comes from
///             `OWNER_ADDRESS` (no canonical default — the vault owner
///             may be the deployer EOA at fresh deploy or the Timelock
///             after `transferOwnership`; the operator passes the
///             correct address explicitly).
///           - Both PK and ADDRESS unset is a hard error.
///           - V2G-R5-P1 chain guard: aborts on Base mainnet
///             (chainId 8453) unless `MAINNET_OK=true`.
///
///         Required env:
///           - PROTOCOL_FEE_VAULT             (target vault)
///           - PROTOCOL_FEE_VAULT_GUARDIAN    (new guardian; may be
///                                            address(0) ONLY with
///                                            ALLOW_ZERO_GUARDIAN_CONFIRM)
///           - SET_GUARDIAN_CONFIRM=true                   ← REQUIRED
///           - ALLOW_ZERO_GUARDIAN_CONFIRM=true  (only required when
///                                                intentionally
///                                                disabling fast-pause)
///         Required (one of):
///           - OWNER_PRIVATE_KEY    (PK-mode), or
///           - OWNER_ADDRESS        (keystore mode; address must match
///                                   the `--sender` flag)
///
///         Hard rules:
///          - aborts on chain id 8453 (Base mainnet) unless an
///            explicit `MAINNET_OK=true` is also set.
///          - never broadcasts unless `SET_GUARDIAN_CONFIRM=true`.
///          - never prints the private key.
///          - refuses zero guardian unless
///            `ALLOW_ZERO_GUARDIAN_CONFIRM=true`.
///          - asserts caller == vault.owner() before broadcasting.
contract SetProtocolFeeVaultGuardian is Script {
    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error ProtocolFeeVaultUnset();
    error NoCodeAt(string name, address target);
    error MainnetWithoutOk(uint256 chainId);
    error GuardianUnsetWithoutConfirm();
    error UnexpectedPostStateGuardian(address got, address expected);
    /// @notice V2G-R5-P1 — both `OWNER_PRIVATE_KEY` and `OWNER_ADDRESS`
    ///         are set but disagree.
    error OwnerPrivateKeyAddressMismatch(address fromPk, address fromEnv);
    /// @notice V2G-R5-P1 — neither `OWNER_PRIVATE_KEY` nor
    ///         `OWNER_ADDRESS` is set; cannot determine signer.
    error OwnerSignerUnset();
    /// @notice V2G-R5-P1 — resolved caller does not equal
    ///         `vault.owner()`. The setGuardian call would revert
    ///         on chain with `NotOwner()`; this fails fast offline.
    error CallerNotVaultOwner(address caller, address vaultOwner);

    function run() external {
        // V2G-R5-P1 — keystore-mode-aware signer resolution.
        uint256 ownerPk = vm.envOr("OWNER_PRIVATE_KEY", uint256(0));
        address envOwner = vm.envOr("OWNER_ADDRESS", address(0));
        address owner;
        if (ownerPk != 0) {
            address derived = vm.addr(ownerPk);
            if (envOwner != address(0) && derived != envOwner) {
                revert OwnerPrivateKeyAddressMismatch(derived, envOwner);
            }
            owner = derived;
        } else if (envOwner != address(0)) {
            owner = envOwner;
        } else {
            revert OwnerSignerUnset();
        }

        address vault = vm.envAddress("PROTOCOL_FEE_VAULT");
        address guardian_ = _envAddressOrZero("PROTOCOL_FEE_VAULT_GUARDIAN");
        bool confirmed = vm.envOr("SET_GUARDIAN_CONFIRM", false);
        bool allowZeroGuardian = vm.envOr("ALLOW_ZERO_GUARDIAN_CONFIRM", false);
        bool mainnetOk = vm.envOr("MAINNET_OK", false);

        if (vault == address(0)) revert ProtocolFeeVaultUnset();
        _requireCode("PROTOCOL_FEE_VAULT", vault);

        // V2G-R5-P1 — chain guard.
        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }

        if (guardian_ == address(0) && !allowZeroGuardian) {
            revert GuardianUnsetWithoutConfirm();
        }

        // V2G-R5-P1 — owner-check (offline). The on-chain
        // `setGuardian` enforces `onlyOwner`; fail-fast prevents an
        // operator-cost revert and surfaces the misconfiguration in
        // the preflight log.
        address vaultOwner = ProtocolFeeVault(vault).owner();
        if (confirmed && owner != vaultOwner) {
            revert CallerNotVaultOwner(owner, vaultOwner);
        }

        console2.log("V2G-R5-P1 SetProtocolFeeVaultGuardian preflight");
        console2.log("chainId                         ", block.chainid);
        console2.log("owner (sanitised, no key)       ", owner);
        console2.log("vault.owner() (current)         ", vaultOwner);
        console2.log("PROTOCOL_FEE_VAULT              ", vault);
        console2.log("PROTOCOL_FEE_VAULT_GUARDIAN     ", guardian_);
        console2.log("ALLOW_ZERO_GUARDIAN_CONFIRM     ", allowZeroGuardian);
        console2.log("SET_GUARDIAN_CONFIRM            ", confirmed);

        address current = ProtocolFeeVault(vault).guardian();
        console2.log("vault.guardian() (current)      ", current);

        if (!confirmed) {
            console2.log("SET_GUARDIAN_CONFIRM is not true; preflight only, no transactions sent.");
            return;
        }

        // V2G-R5-P1 — keystore-mode-aware broadcast.
        if (ownerPk != 0) {
            vm.startBroadcast(ownerPk);
        } else {
            vm.startBroadcast();
        }
        ProtocolFeeVault(vault).setGuardian(guardian_);
        vm.stopBroadcast();

        address postState = ProtocolFeeVault(vault).guardian();
        if (postState != guardian_) {
            revert UnexpectedPostStateGuardian(postState, guardian_);
        }
        console2.log("vault.guardian() (post)         ", postState);
        console2.log("V2G-R5-P1 guardian update complete.");
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }
}
