// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

/// @title WireProtocolFeeVaultFeesManager
/// @notice V2G-R5-P1 — keystore-mode hardening of the V2G-RX
///         safe-by-default rewire that points FeesManagerV2's
///         feeRecipient + rebateFundingAccount + protocolFeeVault at
///         the freshly-deployed ProtocolFeeVault.
///
/// @dev    V2G-R5-P1 signer-source policy (mirrors `SetFeesManagerV2MerkleRoot.s.sol`):
///           - When `DEPLOYER_PRIVATE_KEY` is set + non-zero the script
///             derives the caller from the key and broadcasts via
///             `vm.startBroadcast(pk)`.
///           - When unset (or zero) the script broadcasts via no-arg
///             `vm.startBroadcast()` and defers signer resolution to
///             Foundry's `--account <keystore>` / `--sender <addr>`
///             CLI flags. The caller address comes from
///             `DEPLOYER_ADDRESS` (defaulting to {CANONICAL_DEPLOYER}).
///           - Either way, the resolved caller must equal
///             {CANONICAL_DEPLOYER}.
///           - V2G-R5-P1 chain guard: aborts on Base mainnet
///             (chainId 8453) unless `MAINNET_OK=true`.
///
///         Required env:
///           - FEES_MANAGER_V2
///           - PROTOCOL_FEE_VAULT
///           - WIRE_PROTOCOL_FEE_VAULT_CONFIRM=true   ← REQUIRED
///
///         Order matters (preserved from V2G-RX):
///          1. setProtocolFeeVault — so the hook fires from the
///             first fee event after Step 2.
///          2. setFeeRecipient — positive-fee target becomes vault.
///          3. setRebateFundingAccount — rebate source becomes vault.
///
///         Step 1 first guarantees no fee event leaks past the
///         cutover boundary with the hook unset.
contract WireProtocolFeeVaultFeesManager is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice V2G-R5-P1 — canonical deployer EOA. The only address
    ///         allowed to broadcast this script. Mirrors the
    ///         V2G-RX-FM-P1 deployer constant.
    address internal constant CANONICAL_DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeesManagerV2Unset();
    error ProtocolFeeVaultUnset();
    error NoCodeAt(string name, address target);
    error WireConfirmFlagNotSet();
    error UnexpectedPostStateRecipient(address got, address expected);
    error UnexpectedPostStateFundingAccount(address got, address expected);
    error UnexpectedPostStateVault(address got, address expected);
    /// @notice V2G-R5-P1 — both `DEPLOYER_PRIVATE_KEY` and
    ///         `DEPLOYER_ADDRESS` are set but disagree.
    error DeployerPrivateKeyAddressMismatch(address fromPk, address fromEnv);
    /// @notice V2G-R5-P1 — resolved caller is not the canonical
    ///         deployer EOA.
    error DeployerNotCanonical(address provided, address required);
    /// @notice V2G-R5-P1 — refused on Base mainnet unless
    ///         `MAINNET_OK=true`.
    error MainnetWithoutOk(uint256 chainId);

    function run() external {
        // V2G-R5-P1 — keystore-mode-aware signer resolution.
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address envDeployer = vm.envOr("DEPLOYER_ADDRESS", CANONICAL_DEPLOYER);
        address caller;
        if (deployerPk != 0) {
            address derived = vm.addr(deployerPk);
            if (derived != envDeployer) {
                revert DeployerPrivateKeyAddressMismatch(derived, envDeployer);
            }
            caller = derived;
        } else {
            caller = envDeployer;
        }
        if (caller != CANONICAL_DEPLOYER) {
            revert DeployerNotCanonical(caller, CANONICAL_DEPLOYER);
        }

        address fmv2 = vm.envAddress("FEES_MANAGER_V2");
        address vault = vm.envAddress("PROTOCOL_FEE_VAULT");
        bool confirmed = vm.envOr("WIRE_PROTOCOL_FEE_VAULT_CONFIRM", false);
        bool mainnetOk = vm.envOr("MAINNET_OK", false);

        if (fmv2 == address(0)) revert FeesManagerV2Unset();
        if (vault == address(0)) revert ProtocolFeeVaultUnset();
        _requireCode("FEES_MANAGER_V2", fmv2);
        _requireCode("PROTOCOL_FEE_VAULT", vault);

        // V2G-R5-P1 — chain guard. Aborts on Base mainnet unless the
        // operator has explicitly opted in.
        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }

        console2.log("V2G-R5-P1 FM-V2 + Vault wire preflight");
        console2.log("chainId                         ", block.chainid);
        console2.log("caller (sanitised, no key)      ", caller);
        console2.log("FEES_MANAGER_V2                 ", fmv2);
        console2.log("PROTOCOL_FEE_VAULT (target)     ", vault);
        console2.log("WIRE_PROTOCOL_FEE_VAULT_CONFIRM ", confirmed);

        if (!confirmed) {
            console2.log("WIRE_PROTOCOL_FEE_VAULT_CONFIRM is not true; preflight only, no transactions sent.");
            return;
        }

        FeesManagerV2 fm = FeesManagerV2(fmv2);

        // V2G-R5-P1 — keystore-mode-aware broadcast.
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }
        // Order: vault flag first, then recipient + funding account.
        fm.setProtocolFeeVault(vault);
        fm.setFeeRecipient(vault);
        fm.setRebateFundingAccount(vault);
        vm.stopBroadcast();

        // Post-state verification.
        if (fm.protocolFeeVault() != vault) {
            revert UnexpectedPostStateVault(fm.protocolFeeVault(), vault);
        }
        if (fm.feeRecipient() != vault) {
            revert UnexpectedPostStateRecipient(fm.feeRecipient(), vault);
        }
        if (fm.rebateFundingAccount() != vault) {
            revert UnexpectedPostStateFundingAccount(fm.rebateFundingAccount(), vault);
        }

        console2.log("FM-V2.protocolFeeVault     ", fm.protocolFeeVault());
        console2.log("FM-V2.feeRecipient         ", fm.feeRecipient());
        console2.log("FM-V2.rebateFundingAccount ", fm.rebateFundingAccount());
        console2.log("V2G-R5-P1 wire complete. Next step: BootstrapProtocolFeeVault per asset.");
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }
}
