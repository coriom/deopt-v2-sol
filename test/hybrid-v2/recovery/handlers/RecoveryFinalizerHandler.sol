// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RecoveryFinalizerV1} from "../../../../src/hybrid-v2/recovery/RecoveryFinalizerV1.sol";
import {EscapeControllerV1} from "../../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ICollateralVault} from "../../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {RecoveryState} from "../../../../src/hybrid-v2/libraries/RecoveryTypes.sol";

/// @title RecoveryFinalizerHandler
/// @notice Foundry invariant handler exercising the finalizer + escape
///         controller state machine. Bounded actor set with per-actor
///         subaccount id 1. Ghost mirror tracks the finalization
///         outcome for `RECOVERY-FINAL-I5`, `I7`, `I15`, `I16`.
contract RecoveryFinalizerHandler is Test {
    RecoveryFinalizerV1 public immutable finalizer;
    EscapeControllerV1 public immutable escape;
    SubaccountRegistry public immutable registry;
    ICollateralVault public immutable vault;

    address[] internal _actors;
    uint32 internal constant SUBACCOUNT_ID = 1;

    /// @dev Ghost: subKey has ever been finalized.
    mapping(bytes32 => bool) public ghostFinalized;
    /// @dev Ghost: how many tokens were withdrawn on the last finalize().
    mapping(bytes32 => uint256) public ghostTokensWithdrawn;
    /// @dev Ghost: cumulative recorded recipient (should always equal owner).
    mapping(bytes32 => address) public ghostRecipient;

    constructor(
        RecoveryFinalizerV1 finalizer_,
        EscapeControllerV1 escape_,
        SubaccountRegistry registry_,
        ICollateralVault vault_,
        address[] memory actors_
    ) {
        finalizer = finalizer_;
        escape = escape_;
        registry = registry_;
        vault = vault_;
        _actors = actors_;
        for (uint256 i = 0; i < actors_.length; i++) {
            vm.prank(actors_[i]);
            registry_.registerNext();
        }
    }

    function attemptActivate(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        vm.prank(actor);
        try escape.activateRecovery(SUBACCOUNT_ID) {} catch {}
    }

    function attemptFinalize(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        bytes32 subKey = registry.subKeyOf(actor, SUBACCOUNT_ID);
        vm.prank(actor);
        try finalizer.finalize(SUBACCOUNT_ID) returns (address recipient, uint8 count) {
            ghostFinalized[subKey] = true;
            ghostTokensWithdrawn[subKey] = count;
            ghostRecipient[subKey] = recipient;
        } catch {}
    }

    function attemptSecondFinalize(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        bytes32 subKey = registry.subKeyOf(actor, SUBACCOUNT_ID);
        vm.prank(actor);
        try finalizer.finalize(SUBACCOUNT_ID) returns (address recipient, uint8 count) {
            ghostFinalized[subKey] = true;
            ghostTokensWithdrawn[subKey] = count;
            ghostRecipient[subKey] = recipient;
        } catch {}
    }

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }
}
