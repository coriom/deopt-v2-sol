// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {CollateralVaultV2Harness} from "./harness/CollateralVaultV2Harness.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title CollateralVaultV2CollateralUniverse
/// @notice `ONCHAIN-SUBACCOUNT-RISK-EXECUTION-BOUNDS-AND-COLLATERAL-UNIVERSE-V1`
///         — unit + fuzz for the append-only bounded collateral universe.
contract CollateralVaultV2CollateralUniverse is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal ownerA = address(0xB1);

    MockERC20[9] internal tokens;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        for (uint256 i = 0; i < 9; i++) {
            tokens[i] = new MockERC20("Mock", "MCK", 18);
        }
        vm.prank(ownerA);
        registry.registerNext();
    }

    function _enable(address token) internal {
        vm.prank(governance);
        vault.addSupportedToken(token);
    }

    function _disable(address token) internal {
        vm.prank(governance);
        vault.removeSupportedToken(token);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTANT + VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_constant_equals8() public view {
        assertEq(vault.MAX_COLLATERAL_TOKENS(), 8);
        assertEq(vault.maxCollateralTokens(), 8);
    }

    function test_emptyUniverse() public view {
        assertEq(vault.collateralTokenCount(), 0);
        assertEq(vault.collateralUniverse().length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    FIRST INSERTION + INDEX
    //////////////////////////////////////////////////////////////*/

    function test_firstEnableInsertsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ICollateralVault.CollateralTokenEnteredUniverse(address(tokens[0]), 0, 1);
        _enable(address(tokens[0]));
        assertEq(vault.collateralTokenCount(), 1);
        assertEq(vault.collateralTokenAt(0), address(tokens[0]));
        assertTrue(vault.isKnownCollateralToken(address(tokens[0])));
        assertTrue(vault.supportedTokens(address(tokens[0])));
    }

    function test_eighthTokenInsertion() public {
        for (uint256 i = 0; i < 8; i++) {
            _enable(address(tokens[i]));
        }
        assertEq(vault.collateralTokenCount(), 8);
        for (uint256 i = 0; i < 8; i++) {
            assertEq(vault.collateralTokenAt(i), address(tokens[i]));
        }
    }

    function test_ninthDistinctReverts() public {
        for (uint256 i = 0; i < 8; i++) {
            _enable(address(tokens[i]));
        }
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralVault.CollateralUniverseLimitExceeded.selector, uint256(8), uint256(8))
        );
        _enable(address(tokens[8]));
    }

    function test_ninthRevertLeavesUniverseUnchanged() public {
        for (uint256 i = 0; i < 8; i++) {
            _enable(address(tokens[i]));
        }
        try this._extEnable(address(tokens[8])) {
            revert("expected revert");
        } catch {}
        assertEq(vault.collateralTokenCount(), 8);
        assertFalse(vault.isKnownCollateralToken(address(tokens[8])));
        assertFalse(vault.supportedTokens(address(tokens[8])));
    }

    /// @dev External wrapper for `try/catch` above.
    function _extEnable(address token) external {
        _enable(token);
    }

    /*//////////////////////////////////////////////////////////////
                DISABLE PRESERVES MEMBERSHIP + BALANCES
    //////////////////////////////////////////////////////////////*/

    function test_disablePreservesUniverseMembership() public {
        _enable(address(tokens[0]));
        _enable(address(tokens[1]));
        _disable(address(tokens[0]));
        // Membership + index intact; only the enable-flag flips.
        assertTrue(vault.isKnownCollateralToken(address(tokens[0])));
        assertFalse(vault.supportedTokens(address(tokens[0])));
        assertEq(vault.collateralTokenCount(), 2);
        assertEq(vault.collateralTokenAt(0), address(tokens[0]));
    }

    function test_disablePreservesBalances() public {
        // Enable + deposit.
        _enable(address(tokens[0]));
        MockERC20 t = tokens[0];
        t.mint(ownerA, 100 ether);
        vm.prank(ownerA);
        t.approve(address(vault), 100 ether);
        vm.prank(ownerA);
        vault.deposit(1, address(t), 100 ether);
        bytes32 sk = registry.subKeyOf(ownerA, 1);
        assertEq(vault.balanceOf(sk, address(t)), 100 ether);
        // Disable — balance + accounted preserved.
        _disable(address(t));
        assertEq(vault.balanceOf(sk, address(t)), 100 ether);
        assertEq(vault.totalAccounted(address(t)), 100 ether);
    }

    function test_disablePreservesLiabilities() public {
        _enable(address(tokens[0]));
        MockERC20 t = tokens[0];
        t.mint(ownerA, 50 ether);
        vm.prank(ownerA);
        t.approve(address(vault), 50 ether);
        vm.prank(ownerA);
        vault.deposit(1, address(t), 50 ether);
        _disable(address(t));
        assertEq(vault.totalAccounted(address(t)), 50 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    RE-ENABLE DOES NOT DUPLICATE
    //////////////////////////////////////////////////////////////*/

    function test_reEnableDoesNotAppend() public {
        _enable(address(tokens[0]));
        _enable(address(tokens[1]));
        _disable(address(tokens[0]));
        _enable(address(tokens[0])); // re-enable
        // Universe unchanged in length + order.
        assertEq(vault.collateralTokenCount(), 2);
        assertEq(vault.collateralTokenAt(0), address(tokens[0]));
        assertEq(vault.collateralTokenAt(1), address(tokens[1]));
        assertTrue(vault.supportedTokens(address(tokens[0])));
    }

    function test_reEnableDoesNotEmitUniverseEvent() public {
        _enable(address(tokens[0]));
        _disable(address(tokens[0]));
        // Re-enable: expect only SupportedTokenAdded, NOT CollateralTokenEnteredUniverse.
        vm.recordLogs();
        _enable(address(tokens[0]));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 universeSig = keccak256("CollateralTokenEnteredUniverse(address,uint256,uint16)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], universeSig, "unexpected universe event on re-enable");
        }
    }

    function test_reEnableDoesNotConsumeSlot() public {
        // Fill 7 distinct + 1 re-enable churn.
        for (uint256 i = 0; i < 7; i++) {
            _enable(address(tokens[i]));
        }
        _disable(address(tokens[3]));
        _enable(address(tokens[3])); // re-enable — no slot consumed
        // Slot 8 still free.
        _enable(address(tokens[7]));
        assertEq(vault.collateralTokenCount(), 8);
        // Adding token 8 (9th distinct) still reverts.
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralVault.CollateralUniverseLimitExceeded.selector, uint256(8), uint256(8))
        );
        _enable(address(tokens[8]));
    }

    /*//////////////////////////////////////////////////////////////
                    INSERTION ORDER STABLE
    //////////////////////////////////////////////////////////////*/

    function test_insertionOrderStable() public {
        // Enable in order 3, 7, 1, 0, 5.
        _enable(address(tokens[3]));
        _enable(address(tokens[7]));
        _enable(address(tokens[1]));
        _enable(address(tokens[0]));
        _enable(address(tokens[5]));
        assertEq(vault.collateralTokenAt(0), address(tokens[3]));
        assertEq(vault.collateralTokenAt(1), address(tokens[7]));
        assertEq(vault.collateralTokenAt(2), address(tokens[1]));
        assertEq(vault.collateralTokenAt(3), address(tokens[0]));
        assertEq(vault.collateralTokenAt(4), address(tokens[5]));
        // Disable + re-enable index-2 (tokens[1]) — order preserved.
        _disable(address(tokens[1]));
        _enable(address(tokens[1]));
        assertEq(vault.collateralTokenAt(2), address(tokens[1]));
    }

    /*//////////////////////////////////////////////////////////////
                    OUT-OF-BOUNDS / UNKNOWN
    //////////////////////////////////////////////////////////////*/

    function test_invalidIndexReverts() public {
        _enable(address(tokens[0]));
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralVault.CollateralUniverseIndexOutOfBounds.selector, uint256(1), uint256(1))
        );
        vault.collateralTokenAt(1);
    }

    function test_unknownTokenReturnsFalse() public view {
        assertFalse(vault.isKnownCollateralToken(address(tokens[5])));
    }

    function test_knownDisabledTokenReturnsTrue() public {
        _enable(address(tokens[0]));
        _disable(address(tokens[0]));
        assertTrue(vault.isKnownCollateralToken(address(tokens[0])));
        assertFalse(vault.supportedTokens(address(tokens[0])));
    }

    /*//////////////////////////////////////////////////////////////
                    DONATION DOES NOT ADD TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_donationDoesNotAddToken() public {
        MockERC20 t = tokens[0];
        t.mint(ownerA, 100 ether);
        // Direct token transfer to vault (donation).
        vm.prank(ownerA);
        t.transfer(address(vault), 100 ether);
        // Universe still empty.
        assertEq(vault.collateralTokenCount(), 0);
        assertFalse(vault.isKnownCollateralToken(address(t)));
    }

    /*//////////////////////////////////////////////////////////////
                SEPARATE VAULTS HAVE SEPARATE UNIVERSES
    //////////////////////////////////////////////////////////////*/

    function test_separateVaultsHaveSeparateUniverses() public {
        _enable(address(tokens[0]));
        CollateralVaultV2Harness other = new CollateralVaultV2Harness(address(registry), governance, guardian);
        assertEq(other.collateralTokenCount(), 0);
        assertFalse(other.isKnownCollateralToken(address(tokens[0])));
    }

    /*//////////////////////////////////////////////////////////////
                    CAPABILITY + REGISTRY UNCHANGED
    //////////////////////////////////////////////////////////////*/

    function test_universeChangesDoNotMutateCapabilityOrRegistry() public {
        uint256 bitsBefore = vault.engineCapabilityBits(address(0xE1));
        for (uint256 i = 0; i < 8; i++) {
            _enable(address(tokens[i]));
        }
        _disable(address(tokens[3]));
        _enable(address(tokens[3]));
        assertEq(vault.engineCapabilityBits(address(0xE1)), bitsBefore);
        assertEq(registry.ownerOf(registry.subKeyOf(ownerA, 1)), ownerA);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_enableDisableSequenceNeverExceedsEight(uint8 seed) public {
        uint256 s = uint256(seed);
        // Try up to 20 op steps; each is enable(x) or disable(x). Sequence
        // MUST never push universe above 8 nor break invariants.
        for (uint256 step = 0; step < 20; step++) {
            uint256 tokenIndex = (s >> (step % 8)) & 0x7;
            bool doEnable = (s >> (step % 7)) & 1 == 1;
            address t = address(tokens[tokenIndex]);
            bool alreadyEnabled = vault.supportedTokens(t);
            bool alreadyKnown = vault.isKnownCollateralToken(t);
            uint256 cntBefore = vault.collateralTokenCount();

            if (doEnable) {
                if (alreadyEnabled) {
                    // Duplicate → revert TokenAlreadySupported.
                    vm.expectRevert(CollateralVaultV2Core.TokenAlreadySupported.selector);
                    vm.prank(governance);
                    vault.addSupportedToken(t);
                } else if (!alreadyKnown && cntBefore == 8) {
                    // Cap → revert CollateralUniverseLimitExceeded.
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            ICollateralVault.CollateralUniverseLimitExceeded.selector, uint256(8), uint256(8)
                        )
                    );
                    vm.prank(governance);
                    vault.addSupportedToken(t);
                } else {
                    vm.prank(governance);
                    vault.addSupportedToken(t);
                }
            } else {
                if (!alreadyEnabled) {
                    vm.expectRevert(CollateralVaultV2Core.TokenNotEnabled.selector);
                    vm.prank(governance);
                    vault.removeSupportedToken(t);
                } else {
                    vm.prank(governance);
                    vault.removeSupportedToken(t);
                }
            }
            assertLe(vault.collateralTokenCount(), 8);
        }
    }
}
