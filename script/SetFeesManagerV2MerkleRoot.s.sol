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
///  Required env in all cases:
///    - `DEPLOYER_PRIVATE_KEY` (owner key)
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

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.confirmed) {
            console2.log("SET_FEES_MANAGER_V2_MERKLE_ROOT_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
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
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);
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
