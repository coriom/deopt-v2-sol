// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";

/// @title SetPerpMarketEmergencyCloseOnly
/// @notice Safe-by-default V2F-F preflight to flip a single perp market to
///         emergency-close-only and optionally pause the perp matching engine,
///         as the A2 step of the V2F-E selected drain strategy.
/// @dev
///  Two independent confirmation flags gate the only two mutating operations:
///    - `SET_PERP_MARKET_EMERGENCY_CLOSE_ONLY_CONFIRM=true`
///      -> `PerpEngine.setMarketEmergencyCloseOnly(PERP_MARKET_FREEZE_ID, true)`
///    - `PAUSE_PERP_MATCHING_ENGINE_CONFIRM=true`
///      -> `PerpMatchingEngine.pause()`
///
///  Default is safe: no transaction is sent. Reads owner/guardian, current
///  `marketEmergencyCloseOnly`, current matching `paused`, validates caller
///  authority (must be owner or guardian on the engine for the close-only
///  flip; must be owner or guardian on the matching engine for the pause),
///  prints a sanitized snapshot, exits.
///
///  Required env in all cases:
///    - `DEPLOYER_PRIVATE_KEY` (owner OR guardian — script reads both and
///      reverts if the broadcaster is neither)
///    - `PERP_ENGINE` (address; must have code on the target chain)
///    - `PERP_MARKET_FREEZE_ID` (uint256; default = 1, matching V2F-E
///      selected market)
///    - `PERP_MATCHING_ENGINE` (address; only required when the matching
///      pause flag is set)
///
///  Hard-refuses:
///    - any non-existent market (PerpEngine reverts on
///      `setMarketEmergencyCloseOnly` for an unknown marketId; we also
///      pre-read `marketActivationState` to surface that mistake earlier)
///    - if the close-only flag is already in the requested state (would be a
///      no-op transaction we'd rather skip than send)
///    - if matching pause is requested but matching engine address is unset
contract SetPerpMarketEmergencyCloseOnly is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address perpEngine;
        address perpMatchingEngine;
        uint256 marketId;
        bool freezeConfirmed;
        bool pauseMatchingConfirmed;
    }

    struct Snapshot {
        address perpEngineOwner;
        address perpEngineGuardian;
        bool marketEmergencyCloseOnly;
        uint8 marketActivationState;
        address perpMatchingEngineOwner;
        address perpMatchingEngineGuardian;
        bool perpMatchingEnginePaused;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error PerpEngineUnset();
    error PerpMatchingEngineUnset();
    error NoCodeAt(string name, address target);
    error NotOwnerOrGuardian(string holder, address caller, address owner, address guardian);
    error AlreadyEmergencyCloseOnly(uint256 marketId);
    error AlreadyPaused();
    error FreezeDidNotTake(uint256 marketId);
    error MatchingPauseDidNotTake();

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

        if (!inputs.freezeConfirmed && !inputs.pauseMatchingConfirmed) {
            console2.log("Neither freeze nor matching-pause confirmed; preflight done, no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        if (inputs.freezeConfirmed) {
            PerpEngine(inputs.perpEngine).setMarketEmergencyCloseOnly(inputs.marketId, true);
        }

        if (inputs.pauseMatchingConfirmed) {
            PerpMatchingEngine(inputs.perpMatchingEngine).pause();
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
        inputs.perpEngine = _envAddressOrZero("PERP_ENGINE");
        inputs.perpMatchingEngine = _envAddressOrZero("PERP_MATCHING_ENGINE");
        inputs.marketId = vm.envOr("PERP_MARKET_FREEZE_ID", uint256(1));
        inputs.freezeConfirmed = vm.envOr("SET_PERP_MARKET_EMERGENCY_CLOSE_ONLY_CONFIRM", false);
        inputs.pauseMatchingConfirmed = vm.envOr("PAUSE_PERP_MATCHING_ENGINE_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.perpEngine == address(0)) revert PerpEngineUnset();
        if (inputs.perpEngine.code.length == 0) revert NoCodeAt("PERP_ENGINE", inputs.perpEngine);

        if (inputs.pauseMatchingConfirmed) {
            if (inputs.perpMatchingEngine == address(0)) revert PerpMatchingEngineUnset();
            if (inputs.perpMatchingEngine.code.length == 0) {
                revert NoCodeAt("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
            }
        }
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        PerpEngine engine = PerpEngine(inputs.perpEngine);
        snap.perpEngineOwner = engine.owner();
        snap.perpEngineGuardian = engine.guardian();
        snap.marketEmergencyCloseOnly = engine.marketEmergencyCloseOnly(inputs.marketId);
        snap.marketActivationState = engine.marketActivationState(inputs.marketId);

        if (inputs.perpMatchingEngine != address(0) && inputs.perpMatchingEngine.code.length != 0) {
            PerpMatchingEngine matching = PerpMatchingEngine(inputs.perpMatchingEngine);
            snap.perpMatchingEngineOwner = matching.owner();
            try matching.guardian() returns (address g) {
                snap.perpMatchingEngineGuardian = g;
            } catch {}
            snap.perpMatchingEnginePaused = matching.paused();
        }
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.freezeConfirmed) {
            if (inputs.caller != snap.perpEngineOwner && inputs.caller != snap.perpEngineGuardian) {
                revert NotOwnerOrGuardian("PerpEngine", inputs.caller, snap.perpEngineOwner, snap.perpEngineGuardian);
            }
            if (snap.marketEmergencyCloseOnly) {
                revert AlreadyEmergencyCloseOnly(inputs.marketId);
            }
        }

        if (inputs.pauseMatchingConfirmed) {
            if (inputs.caller != snap.perpMatchingEngineOwner && inputs.caller != snap.perpMatchingEngineGuardian) {
                revert NotOwnerOrGuardian(
                    "PerpMatchingEngine", inputs.caller, snap.perpMatchingEngineOwner, snap.perpMatchingEngineGuardian
                );
            }
            if (snap.perpMatchingEnginePaused) {
                revert AlreadyPaused();
            }
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.freezeConfirmed && !snap.marketEmergencyCloseOnly) {
            revert FreezeDidNotTake(inputs.marketId);
        }
        if (inputs.pauseMatchingConfirmed && !snap.perpMatchingEnginePaused) {
            revert MatchingPauseDidNotTake();
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("PerpEngine market freeze preflight V2F-F");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("PERP_ENGINE", inputs.perpEngine);
        console2.log("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        console2.log("PERP_MARKET_FREEZE_ID", inputs.marketId);
        console2.log("SET_PERP_MARKET_EMERGENCY_CLOSE_ONLY_CONFIRM", inputs.freezeConfirmed);
        console2.log("PAUSE_PERP_MATCHING_ENGINE_CONFIRM", inputs.pauseMatchingConfirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" PerpEngine.owner()", snap.perpEngineOwner);
        console2.log(" PerpEngine.guardian()", snap.perpEngineGuardian);
        console2.log(" PerpEngine.marketEmergencyCloseOnly(marketId)", snap.marketEmergencyCloseOnly);
        console2.log(" PerpEngine.marketActivationState(marketId)", uint256(snap.marketActivationState));
        console2.log(" PerpMatchingEngine.owner()", snap.perpMatchingEngineOwner);
        console2.log(" PerpMatchingEngine.guardian()", snap.perpMatchingEngineGuardian);
        console2.log(" PerpMatchingEngine.paused()", snap.perpMatchingEnginePaused);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
