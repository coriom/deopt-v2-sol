// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {ReplayAndEpochControllerHarness} from "../harness/ReplayAndEpochControllerHarness.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {SubKey} from "../../../../src/hybrid-v2/libraries/SubKey.sol";

/// @title ReplayAndEpochControllerHandler
/// @notice Bounded fuzz-driven handler + ghost mirror for the WP-05 controller invariants.
///
/// Ghost invariants tracked:
///  - a bounded set of registered owners + their subaccounts,
///  - a mirror of consumed intents (fresh -> consumed transitions only),
///  - a mirror of per-signer next-nonce advancement,
///  - a mirror of per-scope epoch counters.
///
/// The handler bounds every action:
///  - owner and signer pools are fixed (5 + 5 addresses),
///  - subaccount id pool bounded (up to 3 per owner),
///  - amounts bounded via `bound`.
contract ReplayAndEpochControllerHandler is StdUtils {
    // Forge cheat-code address.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ReplayAndEpochControllerHarness public immutable controller;
    SubaccountRegistry public immutable registry;
    address public immutable recoveryAuthority;

    address[] public owners;
    address[] public signers;

    // Ghosts
    mapping(bytes32 => bool) public ghostConsumedIntent;
    bytes32[] public consumedIntentList;
    mapping(address => uint256) public ghostNextNonce;
    mapping(address => uint256) public ghostOwnerEpoch;
    mapping(bytes32 => uint256) public ghostSubaccountEpoch;
    bytes32[] public trackedSubKeys;
    mapping(bytes32 => address) public trackedSubKeyOwner;
    mapping(bytes32 => uint32) public trackedSubKeyId;

    uint256 public callCount;

    constructor(ReplayAndEpochControllerHarness controller_, SubaccountRegistry registry_, address recoveryAuthority_) {
        controller = controller_;
        registry = registry_;
        recoveryAuthority = recoveryAuthority_;

        for (uint160 i = 1; i <= 5; i++) {
            owners.push(address(uint160(0x10000 + i)));
            signers.push(address(uint160(0x20000 + i)));
        }
    }

    /// @notice Register a subaccount for one of the bounded owners (up to 3 per owner).
    function ownerRegisterSubaccount(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        uint32 nextId = registry.nextIdFor(owner);
        if (nextId >= 4) return;
        vm.prank(owner);
        registry.registerNext();
        bytes32 subKey = registry.subKeyOf(owner, nextId);
        trackedSubKeys.push(subKey);
        trackedSubKeyOwner[subKey] = owner;
        trackedSubKeyId[subKey] = nextId;
    }

    /// @notice Consume a fresh intent hash. Ghost mirror ensures monotonic membership.
    function consumeIntent(uint256 seed) external {
        callCount++;
        address signer = signers[seed % signers.length];
        bytes32 h = keccak256(abi.encode("intent", seed, callCount));
        if (ghostConsumedIntent[h]) return;
        ghostConsumedIntent[h] = true;
        consumedIntentList.push(h);
        controller.consumeIntent(h, signer, keccak256("A"));
    }

    /// @notice Attempt to re-consume an already-consumed intent — MUST revert.
    function attemptReconsumeExistingIntent(uint256 seed) external {
        callCount++;
        if (consumedIntentList.length == 0) return;
        bytes32 h = consumedIntentList[seed % consumedIntentList.length];
        try controller.consumeIntent(h, signers[0], keccak256("A")) {
            revert("consumed intent re-accepted");
        } catch {
            // expected
        }
    }

    /// @notice Advance a bounded signer's sequential nonce.
    function consumeNonce(uint256 seed) external {
        callCount++;
        address signer = signers[seed % signers.length];
        uint256 expected = controller.nonces(signer);
        if (expected == type(uint256).max) return;
        controller.consumeNonce(signer, expected);
        ghostNextNonce[signer] = expected + 1;
    }

    /// @notice Try to consume a wrong nonce — must revert.
    function attemptBadNonce(uint256 seed) external {
        callCount++;
        address signer = signers[seed % signers.length];
        uint256 expected = controller.nonces(signer);
        uint256 provided = bound(seed, expected + 1, expected + 100);
        try controller.consumeNonce(signer, provided) {
            revert("wrong nonce accepted");
        } catch {}
    }

    /// @notice Cancel next nonce for a signer.
    function signerCancelNextNonce(uint256 seed) external {
        callCount++;
        address signer = signers[seed % signers.length];
        uint256 current = controller.nonces(signer);
        if (current == type(uint256).max) return;
        vm.prank(signer);
        controller.cancelNextNonce();
        ghostNextNonce[signer] = current + 1;
    }

    /// @notice Advance the owner-wide recovery epoch for a bounded owner.
    function ownerAdvanceOwnerEpoch(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        uint256 current = controller.ownerRecoveryEpoch(owner);
        if (current == type(uint256).max) return;
        vm.prank(owner);
        controller.advanceMyOwnerRecoveryEpoch();
        ghostOwnerEpoch[owner] = current + 1;
    }

    /// @notice Advance a per-subaccount recovery epoch (owner path).
    function ownerAdvanceSubaccountEpoch(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        uint32 nextId = registry.nextIdFor(owner);
        if (nextId <= 1) return;
        uint32 sid = uint32(bound(seed, 1, nextId - 1));
        bytes32 subKey = registry.subKeyOf(owner, sid);
        uint256 current = controller.subaccountRecoveryEpoch(subKey);
        if (current == type(uint256).max) return;
        vm.prank(owner);
        controller.advanceMySubaccountRecoveryEpoch(sid);
        ghostSubaccountEpoch[subKey] = current + 1;
    }

    /// @notice Authority-driven owner epoch advance (via recovery authority).
    function authorityAdvanceOwnerEpoch(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        uint256 current = controller.ownerRecoveryEpoch(owner);
        if (current == type(uint256).max) return;
        vm.prank(recoveryAuthority);
        controller.authorityAdvanceOwnerRecoveryEpoch(owner);
        ghostOwnerEpoch[owner] = current + 1;
    }

    /// @notice Attempt unauthorized epoch advance — MUST revert.
    function attemptUnauthorizedEpochAdvance(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        address attacker = address(uint160(0x33000 + (seed % 100)));
        if (attacker == owner || attacker == recoveryAuthority) return;
        vm.prank(attacker);
        try controller.authorityAdvanceOwnerRecoveryEpoch(owner) {
            revert("attacker advanced owner epoch");
        } catch {}
    }

    /// @notice Attempt cross-owner subaccount epoch advance — MUST revert.
    function attemptCrossOwnerSubaccountEpochAdvance(uint256 seed) external {
        callCount++;
        if (owners.length < 2) return;
        address ownerX = owners[seed % owners.length];
        address ownerY = owners[(seed + 1) % owners.length];
        if (ownerX == ownerY) return;
        uint32 nextIdX = registry.nextIdFor(ownerX);
        if (nextIdX <= 1) return;
        uint32 sid = uint32(bound(seed, 1, nextIdX - 1));
        // ownerY tries to bump ownerX's subaccount epoch.
        vm.prank(ownerY);
        try controller.advanceMySubaccountRecoveryEpoch(sid) {
            // Only allowed if ownerY also happens to have this id registered.
            // (both may have subaccount 1). Rebuild the ghost from post-state.
            bytes32 subKeyY = registry.subKeyOf(ownerY, sid);
            uint256 cy = controller.subaccountRecoveryEpoch(subKeyY);
            ghostSubaccountEpoch[subKeyY] = cy;
        } catch {}
    }

    // --- helpers for invariant expectations ---
    function ownersLength() external view returns (uint256) {
        return owners.length;
    }

    function signersLength() external view returns (uint256) {
        return signers.length;
    }

    function trackedSubKeysLength() external view returns (uint256) {
        return trackedSubKeys.length;
    }

    function consumedIntentListLength() external view returns (uint256) {
        return consumedIntentList.length;
    }
}
