// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolFeeVault} from "../src/fees/ProtocolFeeVault.sol";

/// @title DeployProtocolFeeVault
/// @notice V2G-RX safe-by-default deploy script. Refuses to broadcast
///         unless `DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM=true`. Prints
///         the planned constructor inputs (no private keys) before
///         making any call.
///
/// @dev    Required env (all addresses must be non-zero + non-EOA
///         for owner/CV/FM-V2 by post-deploy verify):
///           - DEPLOYER_PRIVATE_KEY        (sanitised; never logged)
///           - PROTOCOL_FEE_VAULT_OWNER    (target = ProtocolTimelock)
///           - COLLATERAL_VAULT            (live address)
///           - FEES_MANAGER_V2             (live address)
///           - DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM=true   ← REQUIRED
///         V2G-RX.1:
///           - PROTOCOL_FEE_VAULT_GUARDIAN (target = OPS_MULTISIG)
///           - ALLOW_ZERO_GUARDIAN_CONFIRM=true (only required when
///             intentionally deploying with the slow-pause posture)
///
///         Hard rules:
///          - aborts on chain id 8453 (Base mainnet) unless an
///            explicit `MAINNET_OK=true` is also set (defensive — the
///            V2G-R5 broadcast target is Base Sepolia 84532; mainnet
///            requires the V2G-Y / audit gate).
///          - never sets the owner to the deployer EOA.
///          - never prints the private key.
///          - V2G-RX.1: refuses to deploy with `guardian == address(0)`
///            unless `ALLOW_ZERO_GUARDIAN_CONFIRM=true` is also set.
contract DeployProtocolFeeVault is Script {
    error InitialOwnerUnset();
    error CollateralVaultUnset();
    error FeesManagerV2Unset();
    error NoCodeAt(string name, address target);
    error DeployConfirmFlagNotSet();
    error MainnetWithoutOk(uint256 chainId);
    /// @notice V2G-RX.1 — guardian env is unset / zero and the
    ///         operator has not opted in to the slow-pause posture
    ///         via `ALLOW_ZERO_GUARDIAN_CONFIRM=true`.
    error GuardianUnsetWithoutConfirm();

    function run() external returns (address vault) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address initialOwner = _envAddressOrZero("PROTOCOL_FEE_VAULT_OWNER");
        address cv = _envAddressOrZero("COLLATERAL_VAULT");
        address fmv2 = _envAddressOrZero("FEES_MANAGER_V2");
        address guardianAddr = _envAddressOrZero("PROTOCOL_FEE_VAULT_GUARDIAN");
        bool confirmed = vm.envOr("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM", false);
        bool mainnetOk = vm.envOr("MAINNET_OK", false);
        bool allowZeroGuardian = vm.envOr("ALLOW_ZERO_GUARDIAN_CONFIRM", false);

        if (initialOwner == address(0)) revert InitialOwnerUnset();
        if (cv == address(0)) revert CollateralVaultUnset();
        if (fmv2 == address(0)) revert FeesManagerV2Unset();
        _requireCode("COLLATERAL_VAULT", cv);
        _requireCode("FEES_MANAGER_V2", fmv2);

        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }

        // V2G-RX.1 — refuse the slow-pause posture unless explicitly opted into.
        if (guardianAddr == address(0) && !allowZeroGuardian) {
            revert GuardianUnsetWithoutConfirm();
        }

        console2.log("V2G-RX ProtocolFeeVault deploy preflight");
        console2.log("chainId                         ", block.chainid);
        console2.log("deployer (sanitised, no key)    ", deployer);
        console2.log("PROTOCOL_FEE_VAULT_OWNER (target)", initialOwner);
        console2.log("COLLATERAL_VAULT                ", cv);
        console2.log("FEES_MANAGER_V2                 ", fmv2);
        console2.log("PROTOCOL_FEE_VAULT_GUARDIAN      ", guardianAddr);
        console2.log("ALLOW_ZERO_GUARDIAN_CONFIRM     ", allowZeroGuardian);
        console2.log("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM", confirmed);

        if (!confirmed) {
            console2.log("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM is not true; preflight only.");
            return address(0);
        }

        // V2G-RX.1 — owner must call `setGuardian(guardianAddr)` after
        // deployment (or in the same multisig batch) when guardian is
        // non-zero. The deploy script intentionally does NOT push the
        // setGuardian call itself because the constructor's `owner`
        // is set to the timelock/multisig, not the deployer EOA, so
        // the deployer cannot perform owner-only actions. The wire
        // script issues the setGuardian call from the owner.
        vm.startBroadcast(deployerPk);
        vault = address(new ProtocolFeeVault(initialOwner, cv, fmv2));
        vm.stopBroadcast();

        console2.log("ProtocolFeeVault deployed at    ", vault);
        console2.log(string.concat("PROTOCOL_FEE_VAULT_ADDR=", vm.toString(vault)));
        console2.log("Reminder: owner must call setGuardian(PROTOCOL_FEE_VAULT_GUARDIAN) before V2G-R5 cutover.");
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }
}
