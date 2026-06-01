// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

/// @title WireProtocolFeeVaultFeesManager
/// @notice V2G-RX safe-by-default rewire of FeesManagerV2 to point
///         feeRecipient + rebateFundingAccount + protocolFeeVault at
///         the freshly-deployed ProtocolFeeVault.
///
/// @dev    Required env:
///           - DEPLOYER_PRIVATE_KEY (timelock-controlled key)
///           - FEES_MANAGER_V2
///           - PROTOCOL_FEE_VAULT
///           - WIRE_PROTOCOL_FEE_VAULT_CONFIRM=true   ← REQUIRED
///
///         Order matters:
///          1. setProtocolFeeVault — so the hook fires from the
///             first fee event after Step 2.
///          2. setFeeRecipient — positive-fee target becomes vault.
///          3. setRebateFundingAccount — rebate source becomes vault.
///
///         Step 1 first guarantees no fee event leaks past the
///         cutover boundary with the hook unset.
contract WireProtocolFeeVaultFeesManager is Script {
    error FeesManagerV2Unset();
    error ProtocolFeeVaultUnset();
    error WireConfirmFlagNotSet();
    error UnexpectedPostStateRecipient(address got, address expected);
    error UnexpectedPostStateFundingAccount(address got, address expected);
    error UnexpectedPostStateVault(address got, address expected);

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fmv2 = vm.envAddress("FEES_MANAGER_V2");
        address vault = vm.envAddress("PROTOCOL_FEE_VAULT");
        bool confirmed = vm.envOr("WIRE_PROTOCOL_FEE_VAULT_CONFIRM", false);

        if (fmv2 == address(0)) revert FeesManagerV2Unset();
        if (vault == address(0)) revert ProtocolFeeVaultUnset();

        console2.log("V2G-RX FM-V2 + Vault wire preflight");
        console2.log("FEES_MANAGER_V2                  ", fmv2);
        console2.log("PROTOCOL_FEE_VAULT (target)      ", vault);
        console2.log("WIRE_PROTOCOL_FEE_VAULT_CONFIRM  ", confirmed);

        if (!confirmed) {
            console2.log("WIRE_PROTOCOL_FEE_VAULT_CONFIRM is not true; preflight only.");
            return;
        }

        FeesManagerV2 fm = FeesManagerV2(fmv2);

        vm.startBroadcast(deployerPk);
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
        console2.log("V2G-RX wire complete. Next step: BootstrapProtocolFeeVault per asset.");
    }
}
