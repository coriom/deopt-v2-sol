// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

import {MockCapabilityAuthority} from "./mocks/MockCapabilityAuthority.sol";

/// @title SubaccountRegistryTest
/// @notice Unit + fuzz coverage for the WP-02 SubaccountRegistry implementation.
/// @dev Covers the acceptance list in the ONCHAIN-SUBACCOUNT-REGISTRY-V1 milestone
///      brief: monotonic ids, Account 0 rejection, event surface, view semantics,
///      pagination bounds, lazy default authorization, overflow, and smart-wallet
///      owner behavior.
contract SubaccountRegistryTest is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    SubaccountRegistry internal registry;
    MockCapabilityAuthority internal authority;

    address internal constant OWNER_A = address(0xA1);
    address internal constant OWNER_B = address(0xB2);
    address internal constant ENGINE_AUTHORIZED = address(0xE0);
    address internal constant ENGINE_UNAUTHORIZED = address(0xE1);

    function setUp() external {
        authority = new MockCapabilityAuthority();
        registry = new SubaccountRegistry(address(authority));

        authority.setBits(ENGINE_AUTHORIZED, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);
        // ENGINE_UNAUTHORIZED intentionally left at zero bits.
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_pinsDeploymentMetadata() external view {
        assertEq(registry.DEPLOYMENT_CHAIN_ID(), block.chainid);
        assertEq(registry.DEPLOYMENT_BLOCK(), uint64(block.number));
        assertEq(registry.capabilityAuthority(), address(authority));
    }

    function test_constructor_versionIsOne() external view {
        assertEq(registry.version(), "1");
        assertEq(registry.VERSION(), "1");
    }

    function test_constructor_maxBatchSizeIsBounded() external view {
        assertEq(registry.MAX_BATCH_SIZE(), uint32(256));
    }

    function test_constructor_rejectsZeroAuthority() external {
        vm.expectRevert(SubaccountRegistry.InvalidCapabilityAuthority.selector);
        new SubaccountRegistry(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          registerNext()
    //////////////////////////////////////////////////////////////*/

    function test_registerNext_firstCallAssignsIdOne() external {
        vm.prank(OWNER_A);
        (uint32 id, bytes32 key) = registry.registerNext();
        assertEq(id, uint32(1));
        assertEq(key, SubKey.deriveHere(address(registry), OWNER_A, 1));
    }

    function test_registerNext_secondCallAssignsIdTwo() external {
        vm.prank(OWNER_A);
        registry.registerNext();
        vm.prank(OWNER_A);
        (uint32 id, bytes32 key) = registry.registerNext();
        assertEq(id, uint32(2));
        assertEq(key, SubKey.deriveHere(address(registry), OWNER_A, 2));
    }

    function test_registerNext_perOwnerSequencesIndependent() external {
        vm.prank(OWNER_A);
        registry.registerNext();
        vm.prank(OWNER_A);
        registry.registerNext();
        vm.prank(OWNER_B);
        (uint32 idB,) = registry.registerNext();
        assertEq(idB, uint32(1));
        assertEq(registry.nextIdFor(OWNER_A), uint32(3));
        assertEq(registry.nextIdFor(OWNER_B), uint32(2));
    }

    function test_registerNext_neverAssignsAccountZero() external {
        vm.prank(OWNER_A);
        (uint32 id,) = registry.registerNext();
        assertTrue(id > 0);
        assertFalse(registry.existsOf(OWNER_A, 0));
    }

    function test_registerNext_emitsSubaccountCreatedWithVersion() external {
        bytes32 expectedKey = SubKey.deriveHere(address(registry), OWNER_A, 1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit ISubaccountRegistry.SubaccountCreated(
            OWNER_A, uint32(1), expectedKey, block.chainid, Versions.EVENT_VERSION
        );

        vm.prank(OWNER_A);
        registry.registerNext();
    }

    function test_registerNext_populatesReverseLookups() external {
        vm.prank(OWNER_A);
        (uint32 id, bytes32 key) = registry.registerNext();

        assertEq(registry.ownerOf(key), OWNER_A);
        assertEq(registry.subaccountIdOf(key), id);
        assertTrue(registry.existsOf(OWNER_A, id));
    }

    function test_registerNext_overflowRevertsAtUint32Max() external {
        // Warp storage so the next assigned id would be type(uint32).max.
        // Trick: pack the mapping slot directly.
        bytes32 slot = keccak256(abi.encode(OWNER_A, uint256(0)));
        vm.store(address(registry), slot, bytes32(uint256(type(uint32).max)));
        assertEq(registry.nextIdFor(OWNER_A), type(uint32).max);

        vm.prank(OWNER_A);
        vm.expectRevert(ISubaccountRegistry.RegistrationOverflow.selector);
        registry.registerNext();
    }

    function test_registerNext_maxRegisterableIsUint32MaxMinusOne() external {
        // With _nextIdOfOwner already at type(uint32).max - 1, registerNext must succeed
        // once (assigning id = type(uint32).max - 1), leaving nextId at type(uint32).max,
        // then the following call must revert.
        bytes32 slot = keccak256(abi.encode(OWNER_A, uint256(0)));
        vm.store(address(registry), slot, bytes32(uint256(type(uint32).max - 1)));

        vm.prank(OWNER_A);
        (uint32 id,) = registry.registerNext();
        assertEq(id, type(uint32).max - 1);
        assertEq(registry.nextIdFor(OWNER_A), type(uint32).max);

        vm.prank(OWNER_A);
        vm.expectRevert(ISubaccountRegistry.RegistrationOverflow.selector);
        registry.registerNext();
    }

    /*//////////////////////////////////////////////////////////////
                     registerLazyDefault()
    //////////////////////////////////////////////////////////////*/

    function test_registerLazyDefault_succeedsForAuthorizedEngine() external {
        bytes32 expectedKey = SubKey.deriveHere(address(registry), OWNER_A, 1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit ISubaccountRegistry.SubaccountLazyRegistered(
            OWNER_A, uint32(1), expectedKey, block.chainid, ENGINE_AUTHORIZED, Versions.EVENT_VERSION
        );

        vm.prank(ENGINE_AUTHORIZED);
        registry.registerLazyDefault(OWNER_A);

        assertTrue(registry.existsOf(OWNER_A, 1));
        assertEq(registry.ownerOf(expectedKey), OWNER_A);
        assertEq(registry.subaccountIdOf(expectedKey), uint32(1));
        assertEq(registry.nextIdFor(OWNER_A), uint32(2));
    }

    function test_registerLazyDefault_revertsForUnauthorizedCaller() external {
        vm.prank(ENGINE_UNAUTHORIZED);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        registry.registerLazyDefault(OWNER_A);

        assertFalse(registry.existsOf(OWNER_A, 1));
    }

    function test_registerLazyDefault_revertsForZeroOwner() external {
        vm.prank(ENGINE_AUTHORIZED);
        vm.expectRevert(ISubaccountRegistry.InvalidOwner.selector);
        registry.registerLazyDefault(address(0));
    }

    function test_registerLazyDefault_idempotentAfterOwnerRegisterNext() external {
        vm.prank(OWNER_A);
        registry.registerNext(); // assigns Account 1 for OWNER_A
        vm.prank(OWNER_A);
        registry.registerNext(); // assigns Account 2

        // Recording logs to assert no SubaccountLazyRegistered emitted on idempotent call.
        vm.recordLogs();

        vm.prank(ENGINE_AUTHORIZED);
        registry.registerLazyDefault(OWNER_A);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "no event on idempotent lazy default");

        // Sequence preserved.
        assertEq(registry.nextIdFor(OWNER_A), uint32(3));
    }

    function test_registerLazyDefault_idempotentAfterPriorLazyCall() external {
        vm.prank(ENGINE_AUTHORIZED);
        registry.registerLazyDefault(OWNER_A);

        vm.recordLogs();
        vm.prank(ENGINE_AUTHORIZED);
        registry.registerLazyDefault(OWNER_A);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "no event on repeat lazy default");
    }

    function test_registerLazyDefault_ownerSequencePreservedAfterAccountTwo() external {
        vm.prank(ENGINE_AUTHORIZED);
        registry.registerLazyDefault(OWNER_A);
        vm.prank(OWNER_A);
        (uint32 id,) = registry.registerNext();
        assertEq(id, uint32(2));
        assertEq(registry.nextIdFor(OWNER_A), uint32(3));
    }

    /*//////////////////////////////////////////////////////////////
                        subKey derivation + views
    //////////////////////////////////////////////////////////////*/

    function test_subKeyOf_matchesCanonicalDerivation() external view {
        bytes32 expected = SubKey.derive(block.chainid, address(registry), OWNER_A, 5);
        assertEq(registry.subKeyOf(OWNER_A, 5), expected);
    }

    function test_subKeyOf_deploymentScoped() external {
        SubaccountRegistry alt = new SubaccountRegistry(address(authority));
        assertTrue(
            registry.subKeyOf(OWNER_A, 1) != alt.subKeyOf(OWNER_A, 1),
            "distinct registry addresses must produce distinct subKeys"
        );
    }

    function test_subKeyOf_differentOwnersProduceDifferentKeys() external view {
        assertTrue(registry.subKeyOf(OWNER_A, 1) != registry.subKeyOf(OWNER_B, 1));
    }

    function test_subKeyOf_differentIdsProduceDifferentKeys() external view {
        assertTrue(registry.subKeyOf(OWNER_A, 1) != registry.subKeyOf(OWNER_A, 2));
    }

    function test_existsOf_falseBeforeRegistration() external view {
        assertFalse(registry.existsOf(OWNER_A, 1));
    }

    function test_existsOf_trueAfterRegistration() external {
        vm.prank(OWNER_A);
        registry.registerNext();
        assertTrue(registry.existsOf(OWNER_A, 1));
    }

    function test_existsOf_rejectsAccountZeroWithoutStorageAccess() external view {
        assertFalse(registry.existsOf(OWNER_A, 0));
        assertFalse(registry.existsOf(address(0), 0));
    }

    function test_ownerOf_returnsZeroForUnknownKey() external view {
        assertEq(registry.ownerOf(bytes32(uint256(0xdead))), address(0));
    }

    function test_subaccountIdOf_returnsZeroForUnknownKey() external view {
        assertEq(registry.subaccountIdOf(bytes32(uint256(0xdead))), uint32(0));
    }

    function test_nextIdFor_returnsOneBeforeAnyRegistration() external view {
        assertEq(registry.nextIdFor(OWNER_A), uint32(1));
    }

    /*//////////////////////////////////////////////////////////////
                            pagination
    //////////////////////////////////////////////////////////////*/

    function test_subaccountsOfPage_emptyForFreshOwner() external view {
        (uint32[] memory ids, bytes32[] memory keys) = registry.subaccountsOfPage(OWNER_A, 0, 10);
        assertEq(ids.length, 0);
        assertEq(keys.length, 0);
    }

    function test_subaccountsOfPage_firstPageIncludesAccountOne() external {
        vm.startPrank(OWNER_A);
        for (uint256 i = 0; i < 5; i++) {
            registry.registerNext();
        }
        vm.stopPrank();

        (uint32[] memory ids, bytes32[] memory keys) = registry.subaccountsOfPage(OWNER_A, 0, 3);
        assertEq(ids.length, 3);
        assertEq(ids[0], uint32(1));
        assertEq(ids[1], uint32(2));
        assertEq(ids[2], uint32(3));
        assertEq(keys[0], SubKey.deriveHere(address(registry), OWNER_A, 1));
        assertEq(keys[2], SubKey.deriveHere(address(registry), OWNER_A, 3));
    }

    function test_subaccountsOfPage_secondPageStartsAtOffset() external {
        vm.startPrank(OWNER_A);
        for (uint256 i = 0; i < 5; i++) {
            registry.registerNext();
        }
        vm.stopPrank();

        (uint32[] memory ids,) = registry.subaccountsOfPage(OWNER_A, 4, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], uint32(4));
        assertEq(ids[1], uint32(5));
    }

    function test_subaccountsOfPage_offsetBeyondEndReturnsEmpty() external {
        vm.prank(OWNER_A);
        registry.registerNext();

        (uint32[] memory ids,) = registry.subaccountsOfPage(OWNER_A, 100, 10);
        assertEq(ids.length, 0);
    }

    function test_subaccountsOfPage_limitZeroReturnsEmpty() external {
        vm.prank(OWNER_A);
        registry.registerNext();

        (uint32[] memory ids,) = registry.subaccountsOfPage(OWNER_A, 0, 0);
        assertEq(ids.length, 0);
    }

    function test_subaccountsOfPage_capsLimitAtMaxBatchSize() external {
        // Fabricate storage to simulate a very high nextIdOf so we can exercise the cap.
        bytes32 slot = keccak256(abi.encode(OWNER_A, uint256(0)));
        vm.store(address(registry), slot, bytes32(uint256(uint32(1000))));

        (uint32[] memory ids,) = registry.subaccountsOfPage(OWNER_A, 1, 500);
        assertEq(ids.length, uint256(registry.MAX_BATCH_SIZE()));
        assertEq(ids[0], uint32(1));
        assertEq(ids[ids.length - 1], uint32(uint256(registry.MAX_BATCH_SIZE())));
    }

    function test_subaccountsOfPage_stableAscendingOrder() external {
        vm.startPrank(OWNER_A);
        for (uint256 i = 0; i < 8; i++) {
            registry.registerNext();
        }
        vm.stopPrank();

        (uint32[] memory ids,) = registry.subaccountsOfPage(OWNER_A, 0, 8);
        for (uint256 i = 1; i < ids.length; i++) {
            assertTrue(ids[i] == ids[i - 1] + 1, "ids must be strictly ascending contiguous");
        }
    }

    function test_subaccountsOfPage_offsetOneEquivalentToOffsetZeroForStart() external {
        vm.startPrank(OWNER_A);
        for (uint256 i = 0; i < 3; i++) {
            registry.registerNext();
        }
        vm.stopPrank();

        (uint32[] memory zeroIds,) = registry.subaccountsOfPage(OWNER_A, 0, 100);
        (uint32[] memory oneIds,) = registry.subaccountsOfPage(OWNER_A, 1, 100);
        assertEq(zeroIds.length, oneIds.length);
        for (uint256 i = 0; i < zeroIds.length; i++) {
            assertEq(zeroIds[i], oneIds[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       smart-wallet owner shape
    //////////////////////////////////////////////////////////////*/

    function test_smartWalletOwner_canRegister() external {
        // A "smart wallet" address is just an address; the registry does not know or care.
        address smartWallet = address(new EmptyContract());
        vm.prank(smartWallet);
        (uint32 id, bytes32 key) = registry.registerNext();
        assertEq(id, uint32(1));
        assertEq(registry.ownerOf(key), smartWallet);
        assertEq(registry.subaccountIdOf(key), id);
    }

    function test_smartWalletControllerRotationDoesNotAlterCanonicalOwner() external {
        address smartWallet = address(new EmptyContract());
        vm.prank(smartWallet);
        (uint32 id, bytes32 key) = registry.registerNext();
        address originalOwner = registry.ownerOf(key);

        // Simulate a "controller rotation" by any other action; the canonical owner
        // (the wallet contract address) is unchanged.
        vm.prank(OWNER_B);
        registry.registerNext(); // unrelated action by a different account

        assertEq(registry.ownerOf(key), originalOwner);
        assertEq(registry.subaccountIdOf(key), id);
    }

    /*//////////////////////////////////////////////////////////////
                            invariants smoke
    //////////////////////////////////////////////////////////////*/

    function test_registryHoldsNoNativeBalance() external view {
        assertEq(address(registry).balance, uint256(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 fuzz
    //////////////////////////////////////////////////////////////*/

    function testFuzz_registerNext_sequentialPerOwner(address owner, uint8 count) external {
        vm.assume(owner != address(0));
        vm.assume(count > 0 && count <= 40);

        vm.startPrank(owner);
        for (uint256 i = 0; i < count; i++) {
            (uint32 id, bytes32 key) = registry.registerNext();
            assertEq(id, uint32(i + 1));
            assertEq(key, SubKey.deriveHere(address(registry), owner, uint32(i + 1)));
            assertTrue(registry.existsOf(owner, uint32(i + 1)));
            assertEq(registry.nextIdFor(owner), uint32(i + 2));
        }
        vm.stopPrank();
    }

    function testFuzz_subKeyOf_matchesCanonicalDerivation(address owner, uint32 subaccountId) external view {
        bytes32 expected = SubKey.derive(block.chainid, address(registry), owner, subaccountId);
        assertEq(registry.subKeyOf(owner, subaccountId), expected);
    }

    function testFuzz_existsOf_falseUntilRegistered(address owner, uint32 subaccountId) external {
        vm.assume(owner != address(0));
        vm.assume(subaccountId > 0 && subaccountId < 32);

        assertFalse(registry.existsOf(owner, subaccountId));

        vm.startPrank(owner);
        for (uint256 i = 0; i < subaccountId; i++) {
            registry.registerNext();
        }
        vm.stopPrank();

        assertTrue(registry.existsOf(owner, subaccountId));
    }
}

/// @dev No-op contract used to model "any address can be the canonical owner", including
///      a smart-contract wallet. The wallet's internal signer rotation is transparent to
///      the registry because the registry keys on `address`, not on signer.
contract EmptyContract {}
