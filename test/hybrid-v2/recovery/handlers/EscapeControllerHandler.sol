// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EscapeControllerV1} from "../../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {RecoveryState} from "../../../../src/hybrid-v2/libraries/RecoveryTypes.sol";

/// @title EscapeControllerHandler
/// @notice Foundry invariant handler exercising the EscapeControllerV1 state
///         machine, epoch primitives, cancellation window, and pause boundary.
/// @dev Bounded actor + subaccount sets keep runs deterministic. Ghost state
///      mirrors the frozen state-machine invariants (ESCAPE-I1..I6, I15, I16).
///
///  Not exercised (out of WP-10A scope):
///   - withdrawal / reservation paths (revert-only in WP-10A);
///   - final recovery transitions (`SETTLEMENT_PENDING` and beyond).
contract EscapeControllerHandler is Test {
    EscapeControllerV1 public immutable controller;
    SubaccountRegistry public immutable registry;

    address[] internal _actors;
    /// @dev Each actor registers a single subaccount id `1` before the fuzz loop.
    uint32 internal constant SUBACCOUNT_ID = 1;

    /*//////////////////////////////////////////////////////////////
                             GHOST STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Ghost mirror of monotonic recovery epoch per subKey.
    mapping(bytes32 => uint256) public ghostSubEpoch;
    /// @dev Ghost mirror of monotonic owner-wide recovery epoch.
    mapping(address => uint256) public ghostOwnerEpoch;
    /// @dev Ghost mirror of the state machine per subKey.
    mapping(bytes32 => RecoveryState) public ghostState;
    /// @dev Ghost: for each subKey, has an activation ever landed?
    mapping(bytes32 => bool) public everActivated;

    constructor(EscapeControllerV1 controller_, SubaccountRegistry registry_, address[] memory actors_) {
        controller = controller_;
        registry = registry_;
        _actors = actors_;
        // Each actor registers a single subaccount at id 1.
        for (uint256 i = 0; i < actors_.length; i++) {
            vm.prank(actors_[i]);
            registry_.registerNext();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          HANDLER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function attemptActivate(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        bytes32 subKey = registry.subKeyOf(actor, SUBACCOUNT_ID);
        vm.prank(actor);
        try controller.activateRecovery(SUBACCOUNT_ID) {
            everActivated[subKey] = true;
            if (controller.ACTIVATION_DELAY() == 0) {
                ghostSubEpoch[subKey] += 1;
                ghostState[subKey] = RecoveryState.RECOVERY_ACTIVE;
            } else {
                ghostState[subKey] = RecoveryState.RECOVERY_PENDING;
            }
        } catch {}
    }

    function attemptFinalize(uint256 actorSeed, uint64 warpDelta) external {
        address actor = _actors[actorSeed % _actors.length];
        bytes32 subKey = registry.subKeyOf(actor, SUBACCOUNT_ID);
        warpDelta = uint64(bound(uint256(warpDelta), 0, 7 days));
        vm.warp(block.timestamp + warpDelta);
        try controller.finalizePendingActivation(SUBACCOUNT_ID, actor) {
            ghostSubEpoch[subKey] += 1;
            ghostState[subKey] = RecoveryState.RECOVERY_ACTIVE;
        } catch {}
    }

    function attemptCancel(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        bytes32 subKey = registry.subKeyOf(actor, SUBACCOUNT_ID);
        vm.prank(actor);
        try controller.cancelRecovery(SUBACCOUNT_ID) {
            ghostState[subKey] = RecoveryState.CANCELLED;
        } catch {}
    }

    function attemptInvalidateIntents(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        bytes32 subKey = registry.subKeyOf(actor, SUBACCOUNT_ID);
        vm.prank(actor);
        try controller.invalidateIntents(SUBACCOUNT_ID) {
            ghostSubEpoch[subKey] += 1;
        } catch {}
    }

    function attemptInvalidateAll(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        vm.prank(actor);
        try controller.invalidateAllIntents() {
            ghostOwnerEpoch[actor] += 1;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESSORS
    //////////////////////////////////////////////////////////////*/

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }
}
