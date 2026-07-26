// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {SubKey} from "../../../../src/hybrid-v2/libraries/SubKey.sol";

import {MockCapabilityAuthority} from "../mocks/MockCapabilityAuthority.sol";

/// @title SubaccountRegistryHandler
/// @notice Bounded fuzz handler exercising the two registration entry points and
///         tracking a ghost model of registrations for invariant assertions.
/// @dev Actor set + engine set is finite (avoids unbounded discovery). The handler
///      never mutates registry state through any path other than the registry's own
///      public functions; ghost state is derived exclusively from successful mutations.
contract SubaccountRegistryHandler is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    SubaccountRegistry public immutable registry;
    MockCapabilityAuthority public immutable authority;

    address[] internal _actors;
    address[] internal _engines;
    /// @dev Engines with CAP_REGISTER_DEFAULT_ACCOUNT granted.
    mapping(address => bool) internal _engineAuthorized;

    /*//////////////////////////////////////////////////////////////
                             GHOST STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Ghost: expected next id for each actor (mirrors _nextIdOfOwner semantics).
    mapping(address => uint32) public ghostNextId;

    /// @dev Ghost: known-registered subKeys (append-only).
    bytes32[] public ghostSubKeys;

    /// @dev Ghost: subKey → expected owner (frozen once set).
    mapping(bytes32 => address) public ghostOwnerOf;

    /// @dev Ghost: subKey → expected subaccountId (frozen once set).
    mapping(bytes32 => uint32) public ghostSubaccountIdOf;

    /// @dev Ghost: total number of successful registrations (unit tests count this).
    uint256 public ghostRegistrationCount;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(SubaccountRegistry registry_, MockCapabilityAuthority authority_) {
        registry = registry_;
        authority = authority_;

        _actors.push(address(0xA001));
        _actors.push(address(0xA002));
        _actors.push(address(0xA003));

        // Two authorized engines + one unauthorized.
        address eng0 = address(0xE001);
        address eng1 = address(0xE002);
        address eng2 = address(0xE003);
        _engines.push(eng0);
        _engines.push(eng1);
        _engines.push(eng2);
        _engineAuthorized[eng0] = true;
        _engineAuthorized[eng1] = true;
        // eng2 unauthorized on purpose to exercise the NotAuthorized revert path.
    }

    /*//////////////////////////////////////////////////////////////
                            HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Attempt owner-initiated registration for a random actor.
    function registerNext(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);

        uint32 storedBefore = registry.nextIdFor(actor);
        // The registry treats 0 as "next=1"; ghost mirrors the same semantic.
        uint32 expectedNext = ghostNextId[actor] == 0 ? uint32(1) : ghostNextId[actor];
        assertEq(storedBefore, expectedNext, "handler ghost desync (pre)");

        if (expectedNext == type(uint32).max) {
            vm.prank(actor);
            vm.expectRevert(ISubaccountRegistry.RegistrationOverflow.selector);
            registry.registerNext();
            return;
        }

        vm.prank(actor);
        (uint32 id, bytes32 key) = registry.registerNext();

        assertEq(id, expectedNext, "id must equal expected next");
        assertEq(key, SubKey.deriveHere(address(registry), actor, id), "subKey must be canonical");

        _recordRegistration(actor, id, key);
    }

    /// @notice Attempt engine-initiated lazy default registration for a random actor.
    function registerLazyDefault(uint256 actorSeed, uint256 engineSeed) external {
        address actor = _pickActor(actorSeed);
        address engine = _pickEngine(engineSeed);

        if (!_engineAuthorized[engine]) {
            vm.prank(engine);
            vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
            registry.registerLazyDefault(actor);
            return;
        }

        bool alreadyRegistered = ghostNextId[actor] != 0;

        vm.prank(engine);
        registry.registerLazyDefault(actor);

        if (alreadyRegistered) {
            // Idempotent: no ghost mutation.
            return;
        }
        bytes32 key = SubKey.deriveHere(address(registry), actor, uint32(1));
        _recordRegistration(actor, uint32(1), key);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _recordRegistration(address actor, uint32 id, bytes32 key) internal {
        ghostNextId[actor] = id + 1;
        ghostSubKeys.push(key);
        ghostOwnerOf[key] = actor;
        ghostSubaccountIdOf[key] = id;
        ghostRegistrationCount += 1;
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _pickEngine(uint256 seed) internal view returns (address) {
        return _engines[seed % _engines.length];
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function ghostSubKeyCount() external view returns (uint256) {
        return ghostSubKeys.length;
    }

    function ghostSubKeyAt(uint256 i) external view returns (bytes32) {
        return ghostSubKeys[i];
    }
}
