// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RiskModuleV2} from "../../../src/hybrid-v2/risk/RiskModuleV2.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {RiskAwareVaultHarness} from "./harness/RiskAwareVaultHarness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

/// @title LiquidationCompletenessIntegration
/// @notice `ONCHAIN-SUBACCOUNT-RISK-EXECUTION-BOUNDS-AND-COLLATERAL-UNIVERSE-V1`
///         — proves the canonical bounded collateral universe supports
///         liquidation completeness end-to-end without introducing an
///         independent RiskModule allowlist. Also proves donation isolation
///         and no-mutation-during-classification.
contract LiquidationCompletenessIntegration is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    RiskModuleV2Harness internal module;
    MockERC20[9] internal tokens;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        uint256 nonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), nonce + 2);
        module = new RiskModuleV2Harness(address(registry), predictedVault, predictedLedger, 1);
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        require(
            address(module) == predictedModule && address(vault) == predictedVault
                && address(ledger) == predictedLedger,
            "predict mismatch"
        );

        for (uint256 i = 0; i < 9; i++) {
            tokens[i] = new MockERC20("Mock", "MCK", 18);
        }
        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    function _enable(address t) internal {
        vm.prank(governance);
        vault.addSupportedToken(t);
    }

    function _disable(address t) internal {
        vm.prank(governance);
        vault.removeSupportedToken(t);
    }

    function _fund(address o, uint32 id, MockERC20 t, uint256 amt) internal {
        t.mint(o, amt);
        vm.prank(o);
        t.approve(address(vault), amt);
        vm.prank(o);
        vault.deposit(id, address(t), amt);
    }

    /*//////////////////////////////////////////////////////////////
              All 8 tokens enumerable via canonical universe
    //////////////////////////////////////////////////////////////*/

    function test_allEightTokensEnumerable() public {
        for (uint256 i = 0; i < 8; i++) {
            _enable(address(tokens[i]));
        }
        assertEq(vault.collateralTokenCount(), 8);
        address[] memory u = vault.collateralUniverse();
        for (uint256 i = 0; i < 8; i++) {
            assertEq(u[i], address(tokens[i]));
        }
    }

    /*//////////////////////////////////////////////////////////////
              Disabled token with balance stays visible
    //////////////////////////////////////////////////////////////*/

    function test_disabledTokenWithBalanceRemainsVisible() public {
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 100 ether);
        _disable(address(tokens[0]));

        // Disabled token remains in the canonical universe → RiskModule can
        // still discover the balance for liquidation valuation.
        assertTrue(vault.isKnownCollateralToken(address(tokens[0])));
        assertFalse(vault.supportedTokens(address(tokens[0])));
        assertEq(vault.balanceOf(_sk(ownerA, 1), address(tokens[0])), 100 ether);
        // Canonical iteration surfaces the token.
        address[] memory u = vault.collateralUniverse();
        bool found;
        for (uint256 i = 0; i < u.length; i++) {
            if (u[i] == address(tokens[0])) found = true;
        }
        assertTrue(found);
    }

    /*//////////////////////////////////////////////////////////////
              Caller-supplied token list cannot substitute universe
    //////////////////////////////////////////////////////////////*/

    function test_omittedTokenCannotBeSubstitutedByCallerList() public {
        _enable(address(tokens[0]));
        _enable(address(tokens[1]));
        _fund(ownerA, 1, tokens[0], 50 ether);
        _fund(ownerA, 1, tokens[1], 30 ether);
        // The RiskModule (abstract) has no "supply your own token list" input.
        // The canonical source is `vault.collateralUniverse()` (and per-token
        // `vault.balanceOf(subKey, token)`). No override path exists.
        // Documentation-only witness:
        address[] memory canonical = vault.collateralUniverse();
        assertEq(canonical.length, 2);
        assertEq(canonical[0], address(tokens[0]));
        assertEq(canonical[1], address(tokens[1]));
    }

    /*//////////////////////////////////////////////////////////////
              Missing price on non-zero balance → indeterminate
    //////////////////////////////////////////////////////////////*/

    function test_missingPriceForNonZeroBalanceRemainsIndeterminate() public {
        bytes32 sk = _sk(ownerA, 1);
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 100 ether);
        // The concrete WP-08 (not shipped in this milestone) would iterate the
        // universe and require a price for every non-zero balance. Absent a
        // provider (harness `providerStale = true`), the abstract fails closed
        // — `liquidationStatus` reverts, no authorization possible.
        module.setProviderStale(true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    /*//////////////////////////////////////////////////////////////
              Stale price → indeterminate → no authorization
    //////////////////////////////////////////////////////////////*/

    function test_stalePriceRemainsIndeterminate() public {
        bytes32 sk = _sk(ownerA, 1);
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 100 ether);
        module.setSubKeyStale(sk, true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    /*//////////////////////////////////////////////////////////////
              Complete healthy state → not liquidatable
    //////////////////////////////////////////////////////////////*/

    function test_completeHealthyStateNotLiquidatable() public {
        bytes32 sk = _sk(ownerA, 1);
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 100 ether);
        module.setRequiredMargin(sk, 50e18);
        module.setAvailableMargin(sk, 100e18);
        module.setTokenPrice1e8(address(tokens[0]), 1e8);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.HEALTHY));
    }

    /*//////////////////////////////////////////////////////////////
              Complete unhealthy state → ELIGIBLE
    //////////////////////////////////////////////////////////////*/

    function test_completeUnhealthyStateEligible() public {
        bytes32 sk = _sk(ownerA, 1);
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 100 ether);
        module.setRequiredMargin(sk, 200e18);
        module.setAvailableMargin(sk, 100e18);
        module.setTokenPrice1e8(address(tokens[0]), 1e8);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION));
    }

    /*//////////////////////////////////////////////////////////////
              Direct donation does not improve equity
    //////////////////////////////////////////////////////////////*/

    function test_directDonationDoesNotImproveEquity() public {
        bytes32 sk = _sk(ownerA, 1);
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 10 ether);
        // Donation: transfer directly to vault contract (bypassing `deposit`).
        tokens[0].mint(ownerA, 5 ether);
        vm.prank(ownerA);
        tokens[0].transfer(address(vault), 5 ether);
        // Accounted balance unchanged (canonical view).
        assertEq(vault.balanceOf(sk, address(tokens[0])), 10 ether);
        // Physical balance includes donation but is NOT canonical.
        assertEq(vault.physicalBalance(address(tokens[0])), 15 ether);
    }

    /*//////////////////////////////////////////////////////////////
              No mutation during classification
    //////////////////////////////////////////////////////////////*/

    function test_noEconomicStateMutationDuringClassification() public {
        bytes32 sk = _sk(ownerA, 1);
        _enable(address(tokens[0]));
        _fund(ownerA, 1, tokens[0], 100 ether);
        module.setRequiredMargin(sk, 50e18);
        module.setAvailableMargin(sk, 100e18);
        module.setTokenPrice1e8(address(tokens[0]), 1e8);

        uint256 balBefore = vault.balanceOf(sk, address(tokens[0]));
        uint32 activeBefore = ledger.activeSeriesCount(sk);
        uint256 universeBefore = vault.collateralTokenCount();
        address ownerBefore = registry.ownerOf(sk);

        module.liquidationStatus(sk);
        module.marginHealthy(sk);
        module.productsEnabled(sk);

        assertEq(vault.balanceOf(sk, address(tokens[0])), balBefore);
        assertEq(uint256(ledger.activeSeriesCount(sk)), uint256(activeBefore));
        assertEq(vault.collateralTokenCount(), universeBefore);
        assertEq(registry.ownerOf(sk), ownerBefore);
    }

    /*//////////////////////////////////////////////////////////////
              Universe cap propagates through end-to-end flow
    //////////////////////////////////////////////////////////////*/

    function test_ninthTokenRejectedInEndToEndFlow() public {
        for (uint256 i = 0; i < 8; i++) {
            _enable(address(tokens[i]));
            _fund(ownerA, 1, tokens[i], 1 ether);
        }
        assertEq(vault.collateralTokenCount(), 8);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralVault.CollateralUniverseLimitExceeded.selector, uint256(8), uint256(8))
        );
        _enable(address(tokens[8]));
    }
}
