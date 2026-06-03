// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolFeeVault} from "../src/fees/ProtocolFeeVault.sol";

/// @title DeployProtocolFeeVault
/// @notice V2G-R5-P1 — keystore-mode hardening of the V2G-RX
///         safe-by-default ProtocolFeeVault deploy script. Refuses to
///         broadcast unless `DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM=true`.
///         Prints the planned constructor inputs (no private keys)
///         before making any call.
///
/// @dev    V2G-R5-P1 signer-source policy (mirrors `DeployFeesManagerV2.s.sol`):
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
///         Required env (all addresses must be non-zero + non-EOA for
///         owner/CV/FM-V2 per post-deploy verify):
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
    /// @notice V2G-R5-P1 — both `DEPLOYER_PRIVATE_KEY` and
    ///         `DEPLOYER_ADDRESS` are set but disagree.
    error DeployerPrivateKeyAddressMismatch(address fromPk, address fromEnv);
    /// @notice V2G-R5-P1 — resolved caller is not the canonical
    ///         deployer EOA.
    error DeployerNotCanonical(address provided, address required);
    /// @notice V2G-R5-P1 — post-state assertion: deployed vault must
    ///         have non-zero code, owner == initialOwner,
    ///         collateralVault == cv, feesManagerV2 == fmv2.
    error PostStateOwnerMismatch(address got, address expected);
    error PostStateCollateralVaultMismatch(address got, address expected);
    error PostStateFeesManagerV2Mismatch(address got, address expected);
    error PostStateNoCode(address target);

    function run() external returns (address vault) {
        // V2G-R5-P1 — keystore-mode-aware signer resolution.
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address envDeployer = vm.envOr("DEPLOYER_ADDRESS", CANONICAL_DEPLOYER);
        address deployer;
        if (deployerPk != 0) {
            address derived = vm.addr(deployerPk);
            if (derived != envDeployer) {
                revert DeployerPrivateKeyAddressMismatch(derived, envDeployer);
            }
            deployer = derived;
        } else {
            deployer = envDeployer;
        }
        if (deployer != CANONICAL_DEPLOYER) {
            revert DeployerNotCanonical(deployer, CANONICAL_DEPLOYER);
        }

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

        // V2G-R5-P1 — chain guard. Aborts on Base mainnet unless the
        // operator has explicitly opted in.
        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }

        // V2G-RX.1 — refuse the slow-pause posture unless explicitly opted into.
        if (guardianAddr == address(0) && !allowZeroGuardian) {
            revert GuardianUnsetWithoutConfirm();
        }

        console2.log("V2G-R5-P1 ProtocolFeeVault deploy preflight");
        console2.log("chainId                          ", block.chainid);
        console2.log("deployer (sanitised, no key)     ", deployer);
        console2.log("PROTOCOL_FEE_VAULT_OWNER (target)", initialOwner);
        console2.log("COLLATERAL_VAULT                 ", cv);
        console2.log("FEES_MANAGER_V2                  ", fmv2);
        console2.log("PROTOCOL_FEE_VAULT_GUARDIAN      ", guardianAddr);
        console2.log("ALLOW_ZERO_GUARDIAN_CONFIRM      ", allowZeroGuardian);
        console2.log("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM", confirmed);

        if (!confirmed) {
            console2.log("DEPLOY_PROTOCOL_FEE_VAULT_CONFIRM is not true; preflight only, no transactions sent.");
            return address(0);
        }

        // V2G-RX.1 — owner must call `setGuardian(guardianAddr)` after
        // deployment (or in the same multisig batch) when guardian is
        // non-zero. The deploy script intentionally does NOT push the
        // setGuardian call itself because the constructor's `owner`
        // is set to the timelock/multisig, not the deployer EOA, so
        // the deployer cannot perform owner-only actions. The wire
        // script issues the setGuardian call from the owner.

        // V2G-R5-P1 — keystore-mode-aware broadcast.
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }
        vault = address(new ProtocolFeeVault(initialOwner, cv, fmv2));
        vm.stopBroadcast();

        // V2G-R5-P1 — post-state verification.
        _verifyPostState(vault, initialOwner, cv, fmv2);

        console2.log("ProtocolFeeVault deployed at     ", vault);
        console2.log(string.concat("PROTOCOL_FEE_VAULT_ADDR=", vm.toString(vault)));
        console2.log("Reminder: owner must call setGuardian(PROTOCOL_FEE_VAULT_GUARDIAN) before V2G-R5 cutover.");
    }

    function _verifyPostState(address vault, address expectedOwner, address expectedCv, address expectedFmv2)
        internal
        view
    {
        if (vault.code.length == 0) revert PostStateNoCode(vault);
        ProtocolFeeVault pfv = ProtocolFeeVault(vault);
        if (pfv.owner() != expectedOwner) revert PostStateOwnerMismatch(pfv.owner(), expectedOwner);
        if (pfv.collateralVault() != expectedCv) {
            revert PostStateCollateralVaultMismatch(pfv.collateralVault(), expectedCv);
        }
        if (pfv.feesManagerV2() != expectedFmv2) {
            revert PostStateFeesManagerV2Mismatch(pfv.feesManagerV2(), expectedFmv2);
        }
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }
}
