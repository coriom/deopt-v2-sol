// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {CollateralVaultV2CoreHarness} from "./harness/CollateralVaultV2CoreHarness.sol";
import {CollateralVaultV2CoreHandler} from "./handlers/CollateralVaultV2CoreHandler.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken} from "./mocks/MaliciousTokens.sol";

/// @title CollateralVaultV2CoreInvariants
/// @notice Foundry invariant suite for WP-04A. Proves VAULT-A-I1..I10 under a
///         bounded handler exercising deposit, third-party deposit, unsupported
///         token, FoT token, direct donation, and attacker-grant paths.
///
///  VAULT-A-I1  physical >= accounted for every tracked token
///  VAULT-A-I2  sum of ghost per-subaccount balances == totalAccounted per token
///  VAULT-A-I3  a deposit mutates only the targeted (subKey, token) pair
///  VAULT-A-I4  no sibling subaccount balance is consumed or credited by accident
///  VAULT-A-I5  unsupported / failed / FoT / malicious paths never inflate liability
///  VAULT-A-I6  token disablement does not delete or reduce existing balances
///  VAULT-A-I7  capability mutations do not modify collateral state
///  VAULT-A-I8  event-derived aggregate reconstruction matches storage
///  VAULT-A-I9  no Account 0 (or unknown identity) ever receives canonical credit
///  VAULT-A-I10 direct donations create only surplus; never user credit
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
contract CollateralVaultV2CoreInvariants is StdInvariant, Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2CoreHarness internal vault;
    CollateralVaultV2CoreHandler internal handler;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal unsupported;
    FeeOnTransferToken internal fot;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);

    function setUp() external {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new CollateralVaultV2CoreHarness(address(registry), GOVERNANCE, GUARDIAN);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        unsupported = new MockERC20("XXX", "XXX", 18);
        fot = new FeeOnTransferToken(100); // 1% fee

        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.addSupportedToken(address(weth));
        vault.addSupportedToken(address(fot));
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.stopPrank();

        handler = new CollateralVaultV2CoreHandler(vault, registry, usdc, weth, fot, unsupported, GOVERNANCE, GUARDIAN);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.ownerDepositAccountOne.selector;
        selectors[1] = handler.ownerDepositRegisteredAccount.selector;
        selectors[2] = handler.thirdPartyDepositExistingAccount.selector;
        selectors[3] = handler.tryUnsupportedTokenDeposit.selector;
        selectors[4] = handler.tryFotDeposit.selector;
        selectors[5] = handler.directDonate.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /* -------------------------- VAULT-A-I1 -------------------------- */

    function invariant_vault_a_i1_physicalCoversAccounted() external view {
        _assertPhysicalCovers(address(usdc));
        _assertPhysicalCovers(address(weth));
        _assertPhysicalCovers(address(fot));
    }

    /* -------------------------- VAULT-A-I2 -------------------------- */

    function invariant_vault_a_i2_sumOfBalancesMatchesAccounted() external view {
        _assertGhostSumMatchesAccounted(address(usdc));
        _assertGhostSumMatchesAccounted(address(weth));
    }

    /* -------------------------- VAULT-A-I3 + I4 --------------------- */

    /// @notice Ghost mirror equals storage per (owner, subaccountId, token). Because
    ///         the handler only updates the ghost on the target's (subKey, token),
    ///         any accidental cross-subaccount mutation would surface as a mismatch.
    function invariant_vault_a_i3_i4_perAccountMirrorMatches() external view {
        _assertGhostMatchesStorage(address(usdc));
        _assertGhostMatchesStorage(address(weth));
    }

    /* -------------------------- VAULT-A-I5 -------------------------- */

    /// @notice For malicious / unsupported / donation paths the handler never touches
    ///         `ghostTotalAccounted`. VAULT-A-I1 (physical >= accounted) is the
    ///         backing check that malicious/failed paths never inflated liability.
    ///         Additionally: FoT and unsupported balances are zero in storage.
    function invariant_vault_a_i5_maliciousPathsCannotInflateLiability() external view {
        assertEq(vault.totalAccounted(address(fot)), 0, "FoT liability MUST stay zero (all FoT deposits revert)");
        assertEq(vault.totalAccounted(address(unsupported)), 0, "unsupported token MUST never accumulate liability");
    }

    /* -------------------------- VAULT-A-I6 -------------------------- */

    /// @notice The current suite does not disable tokens mid-fuzz to avoid perturbing
    ///         other flows. We spot-check the property with an explicit disable/enable
    ///         cycle at invariant time on an unused token.
    function invariant_vault_a_i6_disableDoesNotDeleteBalances() external {
        // Enable weth is a no-op here (weth already enabled). Toggle usdc briefly.
        uint256 accountedBefore = vault.totalAccounted(address(usdc));
        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));
        assertEq(vault.totalAccounted(address(usdc)), accountedBefore, "aggregate MUST survive disable");
        _assertGhostMatchesStorage(address(usdc));
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        assertEq(vault.totalAccounted(address(usdc)), accountedBefore, "aggregate MUST survive re-enable");
    }

    /* -------------------------- VAULT-A-I7 -------------------------- */

    /// @notice Capability mutations at invariant time must not perturb balances.
    function invariant_vault_a_i7_capabilityMutationsInert() external {
        uint256 accountedBefore = vault.totalAccounted(address(usdc));

        vm.prank(GOVERNANCE);
        vault.setEngineCapability(address(0xBEEF), Capabilities.CAP_APPLY_FEE, true);
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(address(0xBEEF));

        assertEq(vault.totalAccounted(address(usdc)), accountedBefore, "capability path MUST NOT alter accounted");
        _assertGhostMatchesStorage(address(usdc));
    }

    /* -------------------------- VAULT-A-I8 -------------------------- */

    function invariant_vault_a_i8_eventDerivedAggregateMatchesStorage() external view {
        // Ghost accumulator mirrors the emitted Deposit amounts. It must equal
        // the on-chain aggregate for tokens the handler actually deposits.
        assertEq(vault.totalAccounted(address(usdc)), handler.ghostFromEvents(address(usdc)));
        assertEq(vault.totalAccounted(address(weth)), handler.ghostFromEvents(address(weth)));
    }

    /* -------------------------- VAULT-A-I9 -------------------------- */

    /// @notice Account 0 for any owner is uncreditable. The registry rejects it
    ///         at derive-time and the vault rejects the subaccountId==0 argument.
    ///         We assert `_balanceOf` under the canonical Account-0 subKey is zero
    ///         for every tracked owner + token.
    function invariant_vault_a_i9_accountZeroNeverCredited() external view {
        uint256 n = handler.ownerCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.ownerAt(i);
            bytes32 key0 = registry.subKeyOf(owner, 0);
            assertEq(vault.balanceOf(key0, address(usdc)), 0);
            assertEq(vault.balanceOf(key0, address(weth)), 0);
            assertEq(vault.balanceOf(key0, address(fot)), 0);
        }
    }

    /* -------------------------- VAULT-A-I10 ------------------------- */

    /// @notice Physical surplus is exactly `physical - accounted` and never
    ///         corresponds to a credited balance. Donations grow surplus but never
    ///         `_totalAccounted`.
    function invariant_vault_a_i10_donationsCreateSurplusOnly() external view {
        uint256 physical = IERC20(address(usdc)).balanceOf(address(vault));
        uint256 accounted = vault.totalAccounted(address(usdc));
        uint256 surplus = physical > accounted ? physical - accounted : 0;
        assertEq(vault.surplus(address(usdc)), surplus);
        // Every user balance MUST be covered by aggregate — otherwise surplus was
        // credited to a user.
        _assertGhostSumMatchesAccounted(address(usdc));
    }

    /* ---------------------------------------------------------------- */
    /* helpers                                                          */
    /* ---------------------------------------------------------------- */

    function _assertPhysicalCovers(address token) internal view {
        uint256 physical = IERC20(token).balanceOf(address(vault));
        uint256 accounted = vault.totalAccounted(token);
        assertGe(physical, accounted, "physical < accounted");
    }

    function _assertGhostSumMatchesAccounted(address token) internal view {
        uint256 sum;
        uint256 n = handler.ownerCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 40; id++) {
                sum += handler.ghostBalance(owner, id, token);
            }
        }
        assertEq(vault.totalAccounted(token), sum, "totalAccounted != sum of ghost balances");
    }

    function _assertGhostMatchesStorage(address token) internal view {
        uint256 n = handler.ownerCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 40; id++) {
                bytes32 key = registry.subKeyOf(owner, id);
                assertEq(
                    vault.balanceOf(key, token), handler.ghostBalance(owner, id, token), "storage balance != ghost"
                );
            }
        }
    }
}
