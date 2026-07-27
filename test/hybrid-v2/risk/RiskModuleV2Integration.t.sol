// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {RiskAwareVaultHarness} from "./harness/RiskAwareVaultHarness.sol";
import {CollateralVaultV2RiskIntegrated} from "../../../src/hybrid-v2/risk/CollateralVaultV2RiskIntegrated.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {ReplayAndEpochControllerHarness} from "../security/harness/ReplayAndEpochControllerHarness.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {CollateralVaultV2} from "../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title RiskModuleV2Integration
/// @notice L2 real Registry + Vault + Ledger + RiskModule integration + Vault
///         risk-hook rollback + fail-closed oracle propagation.
contract RiskModuleV2Integration is Test {
    // Two Vault variants: the pre-existing WP-04B Harness (no risk integration)
    // and the new WP-07 RiskAwareVaultHarness that wires the risk hooks.
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal riskVault;
    RiskModuleV2Harness internal riskModule;
    OptionsPositionsLedger internal ledger;
    ReplayAndEpochControllerHarness internal replayCtl;
    MockERC20 internal token;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal recoveryAuthority = address(0xA3);
    address internal engineFill = address(0xE1);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        // Predict the addresses of `riskVault` (nonce +2) and `ledger` (nonce +3)
        // so the RiskModule can point at the SAME Vault + Ledger the integration
        // flow will actually mutate. The deployer here is `address(this)`; nonce
        // 1 was consumed by the registry above, so nonce 2 is the next `new`.
        uint256 currentNonce = vm.getNonce(address(this));
        address predictedRiskModule = vm.computeCreateAddress(address(this), currentNonce);
        address predictedRiskVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), currentNonce + 2);

        riskModule = new RiskModuleV2Harness(address(registry), predictedRiskVault, predictedLedger, 1);
        riskVault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedRiskModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedRiskVault);
        require(address(riskModule) == predictedRiskModule, "risk-module addr mismatch");
        require(address(riskVault) == predictedRiskVault, "risk-vault addr mismatch");
        require(address(ledger) == predictedLedger, "ledger addr mismatch");

        replayCtl = new ReplayAndEpochControllerHarness(address(registry), "DeOptV2-TestEngine", "1", recoveryAuthority);
        token = new MockERC20("Mock", "MCK", 18);

        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();

        vm.prank(governance);
        riskVault.addSupportedToken(address(token));

        token.mint(ownerA, 1_000 ether);
        vm.prank(ownerA);
        token.approve(address(riskVault), type(uint256).max);
        token.mint(ownerB, 1_000 ether);
        vm.prank(ownerB);
        token.approve(address(riskVault), type(uint256).max);

        riskModule.setTokenPrice1e8(address(token), 1e8);
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT CONSTRUCTOR GATES
    //////////////////////////////////////////////////////////////*/

    function test_riskVaultConstructor_rejectsZeroRiskModule() public {
        vm.expectRevert(CollateralVaultV2RiskIntegrated.InvalidRiskModule.selector);
        new RiskAwareVaultHarness(address(registry), governance, guardian, address(0));
    }

    function test_riskVaultConstructor_rejectsRegistryMismatch() public {
        SubaccountRegistry other = new SubaccountRegistry(address(0xDEAD));
        CollateralVaultV2Harness otherVault = new CollateralVaultV2Harness(address(other), governance, guardian);
        OptionsPositionsLedger otherLedger = new OptionsPositionsLedger(address(other), address(otherVault));
        RiskModuleV2Harness otherRisk =
            new RiskModuleV2Harness(address(other), address(otherVault), address(otherLedger), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultV2RiskIntegrated.RiskModuleRegistryMismatch.selector, address(registry), address(other)
            )
        );
        new RiskAwareVaultHarness(address(registry), governance, guardian, address(otherRisk));
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAWAL SUCCESS PATH
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_succeedsWhenModuleApproves() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 100 ether);
        // Configure risk: available = 100e18, required = 0 → any withdrawal safe.
        riskModule.setRequiredMargin(sk, 0);
        riskModule.setAvailableMargin(sk, 100e18);

        vm.prank(ownerA);
        riskVault.withdraw(1, address(token), 40 ether);
        assertEq(riskVault.balanceOf(sk, address(token)), 60 ether);
        assertEq(token.balanceOf(ownerA), 940 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAWAL ROLLBACK ON UNSAFE
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_rollsBackWhenModuleRejects() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 100 ether);
        // Configure risk: required = 90e18, available = 100e18 → withdrawing
        // 20e18 leaves post-avail 80, below required 90 → reject.
        riskModule.setRequiredMargin(sk, 90e18);
        riskModule.setAvailableMargin(sk, 100e18);

        uint256 balanceBefore = riskVault.balanceOf(sk, address(token));
        uint256 physicalBefore = riskVault.physicalBalance(address(token));
        uint256 accountedBefore = riskVault.totalAccounted(address(token));
        uint256 ownerBefore = token.balanceOf(ownerA);

        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vm.prank(ownerA);
        riskVault.withdraw(1, address(token), 20 ether);

        // All accounting unchanged.
        assertEq(riskVault.balanceOf(sk, address(token)), balanceBefore);
        assertEq(riskVault.physicalBalance(address(token)), physicalBefore);
        assertEq(riskVault.totalAccounted(address(token)), accountedBefore);
        assertEq(token.balanceOf(ownerA), ownerBefore);
    }

    function test_withdraw_rollsBackOnStaleProvider() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 100 ether);
        riskModule.setRequiredMargin(sk, 0);
        riskModule.setAvailableMargin(sk, 100e18);
        riskModule.setProviderStale(true);

        uint256 balanceBefore = riskVault.balanceOf(sk, address(token));

        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vm.prank(ownerA);
        riskVault.withdraw(1, address(token), 10 ether);
        assertEq(riskVault.balanceOf(sk, address(token)), balanceBefore);
    }

    function test_withdraw_rollsBackWhenModuleReverts() public {
        // If we set token price to zero, `_valueOfWithdrawnAmount` returns
        // ok=false. Vault's `withdrawalAllowed` returns false → UnsafeWithdrawal.
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 100 ether);
        riskModule.setRequiredMargin(sk, 0);
        riskModule.setAvailableMargin(sk, 100e18);
        riskModule.setTokenPrice1e8(address(token), 0);
        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vm.prank(ownerA);
        riskVault.withdraw(1, address(token), 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL-TRANSFER PATHS
    //////////////////////////////////////////////////////////////*/

    function test_internalTransfer_succeedsWhenSourceSafe() public {
        bytes32 sk1 = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 100 ether);
        riskModule.setRequiredMargin(sk1, 30e18);
        riskModule.setAvailableMargin(sk1, 100e18);

        vm.prank(ownerA);
        riskVault.internalTransfer(address(token), 1, 2, 40 ether);
        assertEq(riskVault.balanceOf(sk1, address(token)), 60 ether);
        assertEq(riskVault.balanceOf(_sk(ownerA, 2), address(token)), 40 ether);
    }

    function test_internalTransfer_rollsBackWhenSourceUnsafe() public {
        bytes32 sk1 = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 100 ether);
        riskModule.setRequiredMargin(sk1, 90e18);
        riskModule.setAvailableMargin(sk1, 100e18);

        uint256 preSrc = riskVault.balanceOf(sk1, address(token));
        uint256 preDst = riskVault.balanceOf(_sk(ownerA, 2), address(token));

        vm.expectRevert(CollateralVaultV2.UnsafeTransfer.selector);
        vm.prank(ownerA);
        riskVault.internalTransfer(address(token), 1, 2, 40 ether);

        assertEq(riskVault.balanceOf(sk1, address(token)), preSrc);
        assertEq(riskVault.balanceOf(_sk(ownerA, 2), address(token)), preDst);
    }

    /*//////////////////////////////////////////////////////////////
              LEDGER MUTATION CHANGES RISK RESULT
    //////////////////////////////////////////////////////////////*/

    function test_ledgerMutationVisibleToRiskModule() public {
        // Grant fill capability, apply a position, prove position visible via
        // the module's LEDGER immutable reference.
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(governance);
        riskVault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 0, 10e8, 100e8);
        PositionTypes.OptionPosition memory p = riskModule.OPTIONS_LEDGER().positionOf(sk, 1);
        assertEq(p.longQuantity1e8, 10e8);
    }

    /*//////////////////////////////////////////////////////////////
             REPLAY / EPOCH STATE UNAFFECTED BY RISK
    //////////////////////////////////////////////////////////////*/

    function test_riskViewsDoNotMutateReplayState() public {
        // Populate some replay state.
        replayCtl.consumeIntent(keccak256("i1"), address(0xC1), keccak256("A"));
        replayCtl.consumeNonce(address(0xC1), 0);
        vm.prank(ownerA);
        replayCtl.advanceMyOwnerRecoveryEpoch();

        uint256 nonceBefore = replayCtl.nonces(address(0xC1));
        uint256 epochBefore = replayCtl.ownerRecoveryEpoch(ownerA);
        bool intentBefore = replayCtl.isIntentConsumed(keccak256("i1"));

        bytes32 sk = _sk(ownerA, 1);
        riskModule.setRequiredMargin(sk, 10e18);
        riskModule.setAvailableMargin(sk, 100e18);

        // Call every risk view.
        riskModule.marginRequirement(sk);
        riskModule.availableMargin(sk);
        riskModule.marginHealthy(sk);
        riskModule.marginRatio(sk);
        riskModule.liquidationStatus(sk);
        riskModule.withdrawalAllowed(sk, address(token), 1);
        riskModule.transferAllowed(sk, address(token), 1);
        riskModule.productsEnabled(sk);
        riskModule.moduleVersion();
        riskModule.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION);

        assertEq(replayCtl.nonces(address(0xC1)), nonceBefore);
        assertEq(replayCtl.ownerRecoveryEpoch(ownerA), epochBefore);
        assertEq(replayCtl.isIntentConsumed(keccak256("i1")), intentBefore);
    }

    /*//////////////////////////////////////////////////////////////
              DIRECT DONATION DOES NOT IMPROVE EQUITY
    //////////////////////////////////////////////////////////////*/

    function test_directDonationDoesNotImproveUserEquity() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(ownerA);
        riskVault.deposit(1, address(token), 10 ether);
        // Direct token donation to the vault contract — bypasses `deposit`.
        vm.prank(ownerA);
        token.transfer(address(riskVault), 5 ether);
        // Balance-of accounting still shows 10 ether (the accounted figure).
        assertEq(riskVault.balanceOf(sk, address(token)), 10 ether);
        // Physical balance = accounted + donated but only accounted matters.
        assertEq(riskVault.physicalBalance(address(token)), 15 ether);
        assertEq(riskVault.totalAccounted(address(token)), 10 ether);
        // Configure risk to authorize withdrawal of exactly the accounted amount.
        riskModule.setRequiredMargin(sk, 0);
        riskModule.setAvailableMargin(sk, 10e18);
        vm.prank(ownerA);
        riskVault.withdraw(1, address(token), 10 ether);
        assertEq(riskVault.balanceOf(sk, address(token)), 0);
        // The donated surplus remains on the vault; the user cannot claim it.
        assertEq(riskVault.physicalBalance(address(token)), 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
              CAPABILITY REVOCATION DOES NOT ALTER RISK STATE
    //////////////////////////////////////////////////////////////*/

    function test_guardianRevocationDoesNotAlterModuleState() public {
        bytes32 sk = _sk(ownerA, 1);
        riskModule.setRequiredMargin(sk, 100e18);
        riskModule.setAvailableMargin(sk, 200e18);
        uint256 reqBefore = riskModule.marginRequirement(sk);

        // Grant + revoke a fake engine's capability.
        vm.prank(governance);
        riskVault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.prank(guardian);
        riskVault.guardianRevokeEngine(engineFill);

        assertEq(riskModule.marginRequirement(sk), reqBefore);
    }
}
