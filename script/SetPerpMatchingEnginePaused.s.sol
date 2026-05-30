// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";

/// @title SetPerpMatchingEnginePaused
/// @notice Safe-by-default V2F-I helper for toggling `PerpMatchingEngine.pause()`
///         / `PerpMatchingEngine.unpause()`. Used to recover from the V2F-G
///         freeze after V2F-H rewire so the NEW PerpEngine can accept trades.
/// @dev
///  Single confirm flag gates the only mutating call:
///    - `SET_PERP_MATCHING_ENGINE_PAUSED_CONFIRM=true` is required to send any tx.
///
///  Desired state is selected by `PERP_MATCHING_ENGINE_PAUSED` (defaults to `false`):
///    - `PERP_MATCHING_ENGINE_PAUSED=false` -> call `unpause()` (onlyOwner)
///    - `PERP_MATCHING_ENGINE_PAUSED=true`  -> call `pause()` (onlyGuardianOrOwner)
///
///  Default is preflight-only: sanitized snapshot, no transactions sent.
///
///  Hard-refuses (no transaction is sent):
///    - current paused state already equals the requested state (no-op);
///    - caller has neither authority on the engine for the requested call
///      (`unpause` requires owner; `pause` requires owner OR guardian).
///
///  Required env in all cases:
///    - `DEPLOYER_PRIVATE_KEY`
///    - `PERP_MATCHING_ENGINE` (must have code on the target chain)
contract SetPerpMatchingEnginePaused is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address perpMatchingEngine;
        bool desiredPaused;
        bool confirmed;
    }

    struct Snapshot {
        address perpMatchingEngineOwner;
        address perpMatchingEngineGuardian;
        bool perpMatchingEnginePaused;
        address perpMatchingEnginePerpEngine;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error PerpMatchingEngineUnset();
    error NoCodeAt(string name, address target);
    error AlreadyInRequestedState(bool requested);
    error NotOwner(address caller, address owner);
    error NotOwnerOrGuardian(address caller, address owner, address guardian);
    error PauseDidNotTake(bool expected);

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
            console2.log("SET_PERP_MATCHING_ENGINE_PAUSED_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        if (inputs.desiredPaused) {
            PerpMatchingEngine(inputs.perpMatchingEngine).pause();
        } else {
            PerpMatchingEngine(inputs.perpMatchingEngine).unpause();
        }

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
        inputs.perpMatchingEngine = _envAddressOrZero("PERP_MATCHING_ENGINE");
        inputs.desiredPaused = vm.envOr("PERP_MATCHING_ENGINE_PAUSED", false);
        inputs.confirmed = vm.envOr("SET_PERP_MATCHING_ENGINE_PAUSED_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.perpMatchingEngine == address(0)) revert PerpMatchingEngineUnset();
        if (inputs.perpMatchingEngine.code.length == 0) {
            revert NoCodeAt("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        }
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);
        snap.perpMatchingEngineOwner = matching.owner();
        try matching.guardian() returns (address g) {
            snap.perpMatchingEngineGuardian = g;
        } catch {}
        snap.perpMatchingEnginePaused = matching.paused();
        snap.perpMatchingEnginePerpEngine = address(matching.perpEngine());
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.confirmed) {
            if (snap.perpMatchingEnginePaused == inputs.desiredPaused) {
                revert AlreadyInRequestedState(inputs.desiredPaused);
            }

            if (inputs.desiredPaused) {
                // pause() is onlyGuardianOrOwner
                if (inputs.caller != snap.perpMatchingEngineOwner && inputs.caller != snap.perpMatchingEngineGuardian) {
                    revert NotOwnerOrGuardian(
                        inputs.caller, snap.perpMatchingEngineOwner, snap.perpMatchingEngineGuardian
                    );
                }
            } else {
                // unpause() is onlyOwner
                if (inputs.caller != snap.perpMatchingEngineOwner) {
                    revert NotOwner(inputs.caller, snap.perpMatchingEngineOwner);
                }
            }
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (snap.perpMatchingEnginePaused != inputs.desiredPaused) {
            revert PauseDidNotTake(inputs.desiredPaused);
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("PerpMatchingEngine paused-toggle preflight V2F-I");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        console2.log("PERP_MATCHING_ENGINE_PAUSED (desired)", inputs.desiredPaused);
        console2.log("SET_PERP_MATCHING_ENGINE_PAUSED_CONFIRM", inputs.confirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" PerpMatchingEngine.owner()", snap.perpMatchingEngineOwner);
        console2.log(" PerpMatchingEngine.guardian()", snap.perpMatchingEngineGuardian);
        console2.log(" PerpMatchingEngine.paused()", snap.perpMatchingEnginePaused);
        console2.log(" PerpMatchingEngine.perpEngine()", snap.perpMatchingEnginePerpEngine);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
