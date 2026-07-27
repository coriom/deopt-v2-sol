// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {ReplayAndEpochControllerHarness} from "../security/harness/ReplayAndEpochControllerHarness.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title OptionsPositionsLedgerIntegration
/// @notice L2 + L8 integration + DB-loss reconstruction suite for the WP-06 ledger.
///         Proves the ledger is isolated from Registry, Vault, and Replay canonical
///         state and that its own state is reconstructible from events.
contract OptionsPositionsLedgerIntegration is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    OptionsPositionsLedger internal ledger;
    ReplayAndEpochControllerHarness internal replayCtl;
    MockERC20 internal token;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal recoveryAuthority = address(0xA3);
    address internal engineFill = address(0xE1);
    address internal engineSettle = address(0xE2);
    address internal engineLiquidate = address(0xE3);
    address internal attacker = address(0xE9);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    uint256 internal constant SERIES_A = 1;
    uint256 internal constant SERIES_B = 2;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        ledger = new OptionsPositionsLedger(address(registry), address(vault));
        replayCtl = new ReplayAndEpochControllerHarness(address(registry), "DeOptV2-TestEngine", "1", recoveryAuthority);
        token = new MockERC20("Mock", "MCK", 18);

        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();

        vm.prank(governance);
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.prank(governance);
        vault.setEngineCapability(engineSettle, Capabilities.CAP_SETTLE_OPTION, true);
        vm.prank(governance);
        vault.setEngineCapability(engineLiquidate, Capabilities.CAP_LIQUIDATE_OPTIONS, true);

        vm.prank(governance);
        vault.addSupportedToken(address(token));
        token.mint(ownerA, 100 ether);
        vm.prank(ownerA);
        token.approve(address(vault), type(uint256).max);
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    /*//////////////////////////////////////////////////////////////
                    REGISTRY IS CANONICAL SOURCE
    //////////////////////////////////////////////////////////////*/

    function test_registryIsCanonicalIdentitySource() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertEq(registry.ownerOf(sk), ownerA);
        assertEq(registry.subaccountIdOf(sk), 1);
    }

    /*//////////////////////////////////////////////////////////////
              ACCOUNT 0 + UNKNOWN CANNOT HOLD A POSITION
    //////////////////////////////////////////////////////////////*/

    function test_account0CannotHoldPosition() public {
        // The Registry rejects subaccountId==0 at registration; the resulting
        // subKey is a bytes32 but has no `ownerOf` binding. Ledger rejects.
        bytes32 zeroKey = registry.subKeyOf(ownerA, 0);
        vm.expectRevert(IOptionsPositionsLedger.OptionSubKeyNotFound.selector);
        vm.prank(engineFill);
        ledger.applyFill(zeroKey, SERIES_A, 0, 1e8, 100e8);
    }

    function test_unknownSubaccountRejected() public {
        bytes32 fake = registry.subKeyOf(ownerA, 42);
        vm.expectRevert(IOptionsPositionsLedger.OptionSubKeyNotFound.selector);
        vm.prank(engineFill);
        ledger.applyFill(fake, SERIES_A, 0, 1e8, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
             UNAUTHORIZED ENGINE CANNOT MUTATE
    //////////////////////////////////////////////////////////////*/

    function test_unauthorizedEngineRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(attacker);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
             LEDGER DOES NOT MUTATE VAULT BALANCES / LOCKS
    //////////////////////////////////////////////////////////////*/

    function test_positionMutationDoesNotMutateVaultBalance() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(ownerA);
        vault.deposit(1, address(token), 5 ether);
        uint256 preBal = vault.balanceOf(sk, address(token));
        uint256 preAcct = vault.totalAccounted(address(token));
        uint256 prePhys = vault.physicalBalance(address(token));

        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 4e8, 110e8);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 120e8);

        assertEq(vault.balanceOf(sk, address(token)), preBal);
        assertEq(vault.totalAccounted(address(token)), preAcct);
        assertEq(vault.physicalBalance(address(token)), prePhys);
        assertEq(vault.lockedOf(sk, address(token)), 0);
    }

    function test_positionMutationDoesNotMutateReplayState() public {
        bytes32 sk = _sk(ownerA, 1);
        // Populate some replay state via the WP-05 controller.
        replayCtl.consumeIntent(keccak256("i1"), address(0xC1), keccak256("A"));
        replayCtl.consumeNonce(address(0xC1), 0);
        vm.prank(ownerA);
        replayCtl.advanceMyOwnerRecoveryEpoch();

        uint256 nonceBefore = replayCtl.nonces(address(0xC1));
        uint256 ownerEpochBefore = replayCtl.ownerRecoveryEpoch(ownerA);
        bool intentBefore = replayCtl.isIntentConsumed(keccak256("i1"));

        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 1e8, 100e8);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 100e8);

        assertEq(replayCtl.nonces(address(0xC1)), nonceBefore);
        assertEq(replayCtl.ownerRecoveryEpoch(ownerA), ownerEpochBefore);
        assertEq(replayCtl.isIntentConsumed(keccak256("i1")), intentBefore);
    }

    function test_epochAdvanceDoesNotMutatePositions() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        PositionTypes.OptionPosition memory before = ledger.positionOf(sk, SERIES_A);

        vm.prank(ownerA);
        replayCtl.advanceMyOwnerRecoveryEpoch();
        vm.prank(ownerA);
        replayCtl.advanceMySubaccountRecoveryEpoch(1);

        PositionTypes.OptionPosition memory after_ = ledger.positionOf(sk, SERIES_A);
        assertEq(after_.longQuantity1e8, before.longQuantity1e8);
        assertEq(after_.premiumBasis1e8, before.premiumBasis1e8);
    }

    /*//////////////////////////////////////////////////////////////
              GUARDIAN REVOCATION FREEZES FUTURE MUTATIONS
    //////////////////////////////////////////////////////////////*/

    function test_guardianRevocationBlocksFutureMutations() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        uint128 longBefore = ledger.positionOf(sk, SERIES_A).longQuantity1e8;

        vm.prank(guardian);
        vault.guardianRevokeEngine(engineFill);

        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);

        // Existing state preserved.
        assertEq(ledger.positionOf(sk, SERIES_A).longQuantity1e8, longBefore);
    }

    /*//////////////////////////////////////////////////////////////
             DB-LOSS RECONSTRUCTION FROM EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_reconstructionFromEvents() public {
        bytes32 sk1 = _sk(ownerA, 1);
        bytes32 sk2 = _sk(ownerA, 2);
        bytes32 skB = _sk(ownerB, 1);

        vm.recordLogs();
        vm.prank(engineFill);
        ledger.applyFill(sk1, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineFill);
        ledger.applyFill(sk1, SERIES_A, 1, 4e8, 105e8);
        vm.prank(engineFill);
        ledger.applyFill(sk2, SERIES_B, 0, 20e8, 200e8);
        vm.prank(engineFill);
        ledger.applyFill(skB, SERIES_A, 0, 7e8, 100e8);
        vm.prank(engineSettle);
        ledger.applyExercise(sk1, SERIES_A, 3e8, 110e8);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 openedTopic =
            keccak256("OptionPositionOpened(bytes32,uint256,uint8,uint128,uint128,address,address,uint32,uint16)");
        bytes32 modifiedTopic =
            keccak256("OptionPositionModified(bytes32,uint256,uint8,int128,uint128,address,address,uint32,uint16)");
        bytes32 exercisedTopic =
            keccak256("OptionExercised(bytes32,uint256,uint128,uint128,int256,address,uint32,uint16)");

        // Reconstruct long and short per (subKey, series) from events alone.
        uint128 reconLongSk1SeriesA;
        uint128 reconShortSk1SeriesA;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0) continue;
            if (
                (entries[i].topics[0] == openedTopic || entries[i].topics[0] == modifiedTopic)
                    && entries[i].topics[1] == sk1 && uint256(entries[i].topics[2]) == SERIES_A
            ) {
                // topics[3] is the indexed `side`. Data starts with quantity1e8.
                uint8 side = uint8(uint256(entries[i].topics[3]));
                if (entries[i].topics[0] == openedTopic) {
                    (uint128 qty,,,,,) =
                        abi.decode(entries[i].data, (uint128, uint128, address, address, uint32, uint16));
                    if (side == 0) reconLongSk1SeriesA += qty;
                    else reconShortSk1SeriesA += qty;
                } else {
                    (int128 delta,,,,,) =
                        abi.decode(entries[i].data, (int128, uint128, address, address, uint32, uint16));
                    if (side == 0) {
                        reconLongSk1SeriesA = uint128(int128(int256(uint256(reconLongSk1SeriesA)) + int256(delta)));
                    } else {
                        reconShortSk1SeriesA = uint128(int128(int256(uint256(reconShortSk1SeriesA)) + int256(delta)));
                    }
                }
            }
            if (
                entries[i].topics[0] == exercisedTopic && entries[i].topics[1] == sk1
                    && uint256(entries[i].topics[2]) == SERIES_A
            ) {
                (uint128 qty,,,,,) = abi.decode(entries[i].data, (uint128, uint128, int256, address, uint32, uint16));
                reconLongSk1SeriesA -= qty;
            }
        }

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk1, SERIES_A);
        assertEq(reconLongSk1SeriesA, p.longQuantity1e8, "reconstructed long matches");
        assertEq(reconShortSk1SeriesA, p.shortQuantity1e8, "reconstructed short matches");
    }

    function test_reconstructionFromEventsDoesNotNeedVaultOrReplay() public {
        // Prove that the emitted events carry readable owner + subaccountId, so
        // reconstruction does not need to consult the Vault, the Registry, or
        // the ReplayController — just the ledger event stream.
        bytes32 sk = _sk(ownerA, 1);
        vm.recordLogs();
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 5e8, 100e8);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 topic =
            keccak256("OptionPositionOpened(bytes32,uint256,uint8,uint128,uint128,address,address,uint32,uint16)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 0) continue;
            if (entries[i].topics[0] != topic) continue;
            (,, address engine, address owner, uint32 subaccountId,) =
                abi.decode(entries[i].data, (uint128, uint128, address, address, uint32, uint16));
            assertEq(engine, engineFill);
            assertEq(owner, ownerA);
            assertEq(subaccountId, 1);
            found = true;
            break;
        }
        assertTrue(found, "expected event");
    }
}
