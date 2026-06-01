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
///
///         Hard rules:
///          - aborts on chain id 8453 (Base mainnet) unless an
///            explicit `MAINNET_OK=true` is also set (defensive — the
///            V2G-R5 broadcast target is Base Sepolia 84532; mainnet
///            requires the V2G-Y / audit gate).
///          - never sets the owner to the deployer EOA.
///          - never prints the private key.
contract DeployProtocolFeeVault is Script {
    error InitialOwnerUnset();
    error CollateralVaultUnset();
    error FeesManagerV2Unset();
    error NoCodeAt(string name, address target);
    error DeployConfirmFlagNotSet();
    error MainnetWithoutOk(uint256 chainId);

    function run() external returns (address vault) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address initialOwner = _envAddressOrZero("PROTOCOL_FEE_VAULT_OWNER");
        address cv = _envAddressOrZero("COLLATERAL_VAULT");
        address fmv2 = _envAddressOrZero("FEES_MANAGER_V2");
        bool confirmed = vm.envOr("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM", false);
        bool mainnetOk = vm.envOr("MAINNET_OK", false);

        if (initialOwner == address(0)) revert InitialOwnerUnset();
        if (cv == address(0)) revert CollateralVaultUnset();
        if (fmv2 == address(0)) revert FeesManagerV2Unset();
        _requireCode("COLLATERAL_VAULT", cv);
        _requireCode("FEES_MANAGER_V2", fmv2);

        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }

        console2.log("V2G-RX ProtocolFeeVault deploy preflight");
        console2.log("chainId                         ", block.chainid);
        console2.log("deployer (sanitised, no key)    ", deployer);
        console2.log("PROTOCOL_FEE_VAULT_OWNER (target)", initialOwner);
        console2.log("COLLATERAL_VAULT                ", cv);
        console2.log("FEES_MANAGER_V2                 ", fmv2);
        console2.log("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM", confirmed);

        if (!confirmed) {
            console2.log("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM is not true; preflight only.");
            return address(0);
        }

        vm.startBroadcast(deployerPk);
        vault = address(new ProtocolFeeVault(initialOwner, cv, fmv2));
        vm.stopBroadcast();

        console2.log("ProtocolFeeVault deployed at    ", vault);
        console2.log(string.concat("PROTOCOL_FEE_VAULT_ADDR=", vm.toString(vault)));
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }
}
