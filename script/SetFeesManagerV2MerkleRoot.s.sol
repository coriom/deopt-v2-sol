// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

/// @title SetFeesManagerV2MerkleRoot
/// @notice V2G-B safe-by-default helper for calling
///         `FeesManagerV2.setMerkleRoot(root, validFrom, validUntil)`
///         from the operator wallet during the rebate live smoke.
///         Mirrors the `SetPerpMatchingEnginePaused` pattern:
///         single confirm flag gates the only mutating call; default
///         is preflight-only (sanitized snapshot, no transactions).
/// @dev
///  V2G-RX-FM-P1 signer-source policy (matches DeployMarginEngineV2):
///    - When `DEPLOYER_PRIVATE_KEY` is set + non-zero the script derives
///      the caller from the key and broadcasts via
///      `vm.startBroadcast(pk)`.
///    - When unset (or zero) the script broadcasts via no-arg
///      `vm.startBroadcast()` and defers signer resolution to Foundry's
///      `--account <keystore>` / `--sender <addr>` CLI flags. The caller
///      address comes from `DEPLOYER_ADDRESS` (defaulting to
///      {CANONICAL_DEPLOYER}).
///    - Either way, the resolved caller must equal {CANONICAL_DEPLOYER}.
///    - V2G-RX-FM-P1 chain guard: aborts on Base mainnet (chainId 8453)
///      unless `MAINNET_OK=true`.
///
///  Required env in all cases:
///    - `FEES_MANAGER_V2_ADDRESS`
///    - `FEES_MANAGER_V2_MERKLE_ROOT` (32-byte hex, 0x-prefixed)
///    - `FEES_MANAGER_V2_VALID_FROM`  (uint64 seconds)
///    - `FEES_MANAGER_V2_VALID_UNTIL` (uint64 seconds)
///
///  Mutating call gated by:
///    - `SET_FEES_MANAGER_V2_MERKLE_ROOT_CONFIRM=true`
///
///  Hard-refuses (no transaction is sent):
///    - target has no code;
///    - caller is not the contract owner;
///    - `validUntil != 0 && validFrom > validUntil`;
///    - root equals the current `merkleRoot()` (no-op).
contract SetFeesManagerV2MerkleRoot is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice V2G-RX-FM-P1 — canonical deployer EOA.
    address internal constant CANONICAL_DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address feesManager;
        bytes32 root;
        uint64 validFrom;
        uint64 validUntil;
        bool confirmed;
    }

    struct Snapshot {
        address owner;
        bytes32 merkleRoot;
        uint64 rootValidFrom;
        uint64 rootValidUntil;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeesManagerUnset();
    error NoCodeAt(string name, address target);
    error InvalidWindow(uint64 validFrom, uint64 validUntil);
    error NotOwner(address caller, address owner);
    error RootUnchanged(bytes32 root);
    error RootDidNotTake(bytes32 expected, bytes32 observed);
    /// @notice V2G-RX-FM-P1 — both `DEPLOYER_PRIVATE_KEY` and
    ///         `DEPLOYER_ADDRESS` are set but disagree.
    error DeployerPrivateKeyAddressMismatch(address fromPk, address fromEnv);
    /// @notice V2G-RX-FM-P1 — resolved caller is not the canonical
    ///         deployer EOA.
    error DeployerNotCanonical(address provided, address required);
    /// @notice V2G-RX-FM-P1 — refused on Base mainnet unless
    ///         `MAINNET_OK=true`.
    error MainnetWithoutOk(uint256 chainId);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        // V2G-RX-FM-P1 — chain guard. Aborts on Base mainnet unless
        // the operator has explicitly opted in.
        bool mainnetOk = vm.envOr("MAINNET_OK", false);
        if (block.chainid == 8453 && !mainnetOk) {
            revert MainnetWithoutOk(block.chainid);
        }

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.confirmed) {
            console2.log("SET_FEES_MANAGER_V2_MERKLE_ROOT_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        // V2G-RX-FM-P1 — keystore-mode-aware broadcast.
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (deployerPk != 0) {
            vm.startBroadcast(deployerPk);
        } else {
            vm.startBroadcast();
        }
        FeesManagerV2(inputs.feesManager).setMerkleRoot(inputs.root, inputs.validFrom, inputs.validUntil);
        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        // V2G-RX-FM-P1 — keystore-mode-aware signer resolution.
        uint256 deployerPk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address envDeployer = vm.envOr("DEPLOYER_ADDRESS", CANONICAL_DEPLOYER);
        if (deployerPk != 0) {
            address derived = vm.addr(deployerPk);
            if (derived != envDeployer) {
                revert DeployerPrivateKeyAddressMismatch(derived, envDeployer);
            }
            inputs.caller = derived;
        } else {
            inputs.caller = envDeployer;
        }
        if (inputs.caller != CANONICAL_DEPLOYER) {
            revert DeployerNotCanonical(inputs.caller, CANONICAL_DEPLOYER);
        }

        inputs.feesManager = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.root = vm.envBytes32("FEES_MANAGER_V2_MERKLE_ROOT");
        inputs.validFrom = uint64(vm.envUint("FEES_MANAGER_V2_VALID_FROM"));
        inputs.validUntil = uint64(vm.envUint("FEES_MANAGER_V2_VALID_UNTIL"));
        inputs.confirmed = vm.envOr("SET_FEES_MANAGER_V2_MERKLE_ROOT_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.feesManager.code.length == 0) {
            revert NoCodeAt("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        }
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);
        snap.owner = fm.owner();
        snap.merkleRoot = fm.merkleRoot();
        snap.rootValidFrom = fm.rootValidFrom();
        snap.rootValidUntil = fm.rootValidUntil();
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.validUntil != 0 && inputs.validFrom > inputs.validUntil) {
            revert InvalidWindow(inputs.validFrom, inputs.validUntil);
        }
        if (inputs.confirmed) {
            if (inputs.caller != snap.owner) revert NotOwner(inputs.caller, snap.owner);
            if (snap.merkleRoot == inputs.root) revert RootUnchanged(inputs.root);
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (snap.merkleRoot != inputs.root) revert RootDidNotTake(inputs.root, snap.merkleRoot);
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("FeesManagerV2.setMerkleRoot preflight V2G-B");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("FEES_MANAGER_V2_MERKLE_ROOT");
        console2.logBytes32(inputs.root);
        console2.log("FEES_MANAGER_V2_VALID_FROM", inputs.validFrom);
        console2.log("FEES_MANAGER_V2_VALID_UNTIL", inputs.validUntil);
        console2.log("SET_FEES_MANAGER_V2_MERKLE_ROOT_CONFIRM", inputs.confirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" FeesManagerV2.owner()", snap.owner);
        console2.log(" FeesManagerV2.merkleRoot()");
        console2.logBytes32(snap.merkleRoot);
        console2.log(" FeesManagerV2.rootValidFrom()", snap.rootValidFrom);
        console2.log(" FeesManagerV2.rootValidUntil()", snap.rootValidUntil);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
