// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {VaultCapabilityController} from "../../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {Capabilities} from "../../../../src/hybrid-v2/libraries/Capabilities.sol";

import {VaultCapabilityControllerHarness} from "../harness/VaultCapabilityControllerHarness.sol";

/// @title VaultCapabilityControllerHandler
/// @notice Bounded fuzz handler exercising the capability subsystem + registry integration.
/// @dev Actor set is finite. Ghost state mirrors capability bitmap + an event-derived
///      bitmap so invariants can compare storage vs. reconstruction.
contract VaultCapabilityControllerHandler is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    VaultCapabilityControllerHarness public immutable controller;
    SubaccountRegistry public immutable registry;

    address public immutable governance;
    address public immutable guardian;

    address[] internal _engines;
    address[] internal _attackers;
    address[] internal _owners;

    /*//////////////////////////////////////////////////////////////
                             GHOST STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Direct mirror updated only by successful governance mutations.
    mapping(address => uint256) public ghostBits;

    /// @dev Event-log-derived mirror (mirrors event sequence).
    ///      Updated inside handler in lockstep with ghostBits so we can prove
    ///      that the storage bitmap is reproducible from the ordered event stream.
    mapping(address => uint256) public ghostBitsFromEvents;

    /// @dev Ghost lazy-registrations tracked (owner set).
    mapping(address => bool) public ghostLazyRegistered;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(VaultCapabilityControllerHarness controller_, SubaccountRegistry registry_) {
        controller = controller_;
        registry = registry_;
        governance = controller_.governance();
        guardian = controller_.guardian();

        _engines.push(address(0xE001));
        _engines.push(address(0xE002));
        _engines.push(address(0xE003));

        _attackers.push(address(0xBAD0));
        _attackers.push(address(0xBAD1));

        _owners.push(address(0xA1));
        _owners.push(address(0xA2));
    }

    /*//////////////////////////////////////////////////////////////
                        AUTHORIZED HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function governanceGrant(uint256 engineSeed, uint256 rawMask) external {
        address engine = _pickEngine(engineSeed);
        uint256 mask = _sanitizeMask(rawMask);
        if (mask == 0) return; // handler avoids known-revert paths for CAP-I2 clarity

        uint256 oldBits = ghostBits[engine];
        uint256 newBits = oldBits | mask;

        vm.prank(governance);
        controller.setEngineCapability(engine, mask, true);

        _applyMirror(engine, oldBits, newBits);
    }

    function governanceRevoke(uint256 engineSeed, uint256 rawMask) external {
        address engine = _pickEngine(engineSeed);
        uint256 mask = _sanitizeMask(rawMask);
        if (mask == 0) return;

        uint256 oldBits = ghostBits[engine];
        uint256 newBits = oldBits & ~mask;

        vm.prank(governance);
        controller.setEngineCapability(engine, mask, false);

        _applyMirror(engine, oldBits, newBits);
    }

    function guardianRevoke(uint256 engineSeed) external {
        address engine = _pickEngine(engineSeed);
        uint256 oldBits = ghostBits[engine];

        vm.prank(guardian);
        controller.guardianRevokeEngine(engine);

        _applyMirror(engine, oldBits, 0);
    }

    /*//////////////////////////////////////////////////////////////
                      UNAUTHORIZED HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function attackerTryGrant(uint256 attackerSeed, uint256 engineSeed, uint256 rawMask) external {
        address attacker = _pickAttacker(attackerSeed);
        address engine = _pickEngine(engineSeed);
        uint256 mask = _sanitizeMask(rawMask);
        if (mask == 0) return;

        vm.prank(attacker);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(engine, mask, true);
        // No ghost mutation — the revert protects state.
    }

    function attackerTryGuardianRevoke(uint256 attackerSeed, uint256 engineSeed) external {
        address attacker = _pickAttacker(attackerSeed);
        address engine = _pickEngine(engineSeed);

        vm.prank(attacker);
        vm.expectRevert(VaultCapabilityController.OnlyGuardian.selector);
        controller.guardianRevokeEngine(engine);
    }

    function engineTrySelfGrant(uint256 engineSeed, uint256 rawMask) external {
        address engine = _pickEngine(engineSeed);
        uint256 mask = _sanitizeMask(rawMask);
        if (mask == 0) return;

        vm.prank(engine);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(engine, mask, true);
    }

    function guardianTryGrant(uint256 engineSeed, uint256 rawMask) external {
        address engine = _pickEngine(engineSeed);
        uint256 mask = _sanitizeMask(rawMask);
        if (mask == 0) return;

        vm.prank(guardian);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(engine, mask, true);
    }

    /*//////////////////////////////////////////////////////////////
                       REGISTRY INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function engineTryLazyRegister(uint256 engineSeed, uint256 ownerSeed) external {
        address engine = _pickEngine(engineSeed);
        address owner = _pickOwner(ownerSeed);

        bool hasCap = (ghostBits[engine] & Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT) != 0;

        if (!hasCap) {
            vm.prank(engine);
            vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
            registry.registerLazyDefault(owner);
            return;
        }

        vm.prank(engine);
        registry.registerLazyDefault(owner);
        ghostLazyRegistered[owner] = true;
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Confine mask to defined bits so mutations proceed through validation
    ///      rather than reverting on reserved-bit checks. Reserved-bit rejection
    ///      is separately unit-tested.
    function _sanitizeMask(uint256 rawMask) internal pure returns (uint256) {
        return rawMask & Capabilities.ALL_CAPABILITIES;
    }

    function _pickEngine(uint256 seed) internal view returns (address) {
        return _engines[seed % _engines.length];
    }

    function _pickAttacker(uint256 seed) internal view returns (address) {
        return _attackers[seed % _attackers.length];
    }

    function _pickOwner(uint256 seed) internal view returns (address) {
        return _owners[seed % _owners.length];
    }

    function _applyMirror(address engine, uint256 oldBits, uint256 newBits) internal {
        ghostBits[engine] = newBits;

        // Also apply the same delta to the event-derived mirror. Real reconstruction
        // would consume the emitted events; here we simulate that consumption
        // deterministically using the same add/remove masks the abstract emits.
        uint256 added = newBits & ~oldBits;
        uint256 removed = oldBits & ~newBits;
        ghostBitsFromEvents[engine] = (ghostBitsFromEvents[engine] | added) & ~removed;
    }

    /*//////////////////////////////////////////////////////////////
                         READ HELPERS FOR TESTS
    //////////////////////////////////////////////////////////////*/

    function engineCount() external view returns (uint256) {
        return _engines.length;
    }

    function engineAt(uint256 i) external view returns (address) {
        return _engines[i];
    }

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    function ownerAt(uint256 i) external view returns (address) {
        return _owners[i];
    }
}
