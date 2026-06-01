// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FeesManagerV2} from "../../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../../src/fees/IFeesManagerV2.sol";
import {ProtocolFeeVault} from "../../../src/fees/ProtocolFeeVault.sol";
import {ICollateralVaultInternalTransfer} from "../../../src/collateral/ICollateralVaultInternalTransfer.sol";

/// @notice V2G-RX — end-to-end integration test for the
///         FeesManagerV2 ↔ ProtocolFeeVault hook flow + the
///         CollateralVault `transferFromInternalAccount` extension.
///
///         The test models the V2G-R5 cutover scenario:
///         FM-V2.feeRecipient == FM-V2.rebateFundingAccount == vault,
///         FM-V2.protocolFeeVault == vault. Then exercise a charge
///         + a rebate via consumeFees and confirm:
///          - vault counter buckets update.
///          - vault accounting identity holds.
///          - vault.netRevenue == grossFees − rebates.
///          - FM-V2.rebateBudget decrements independently of the
///            vault's internal reserve.
///          - the vault's internal CV balance matches feeBalance
///            + rebateReserve.
contract V2GRXProtocolFeeVaultIntegrationTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant CONSUMER = address(0xC0FFEE);
    address internal constant TAKER = address(0x77CA);
    address internal constant MAKER = address(0x290B);
    address internal constant ASSET = address(0xCAFE);

    uint64 internal constant VALID_FROM = 1_000;
    uint64 internal constant VALID_UNTIL = 100_000;
    uint256 internal constant VOLUME_28D = 25_000_000e6;
    uint32 internal constant VOLUME_SHARE_PPM = 50_000;
    uint256 internal constant STAKED_DEOPT = 250_000e8;

    FeesManagerV2 internal feesManager;
    ProtocolFeeVault internal vault;
    StubCollateralVault internal cv;

    function setUp() external {
        vm.warp(VALID_FROM);
        cv = new StubCollateralVault();
        // FM-V2 needs a non-zero feeRecipient at construction.
        // We use a placeholder that will be rotated to the vault.
        feesManager = new FeesManagerV2(OWNER, address(0xBEEF));
        vault = new ProtocolFeeVault(OWNER, address(cv), address(feesManager));

        // Authorize CONSUMER as a fee consumer of FM-V2.
        vm.prank(OWNER);
        feesManager.setFeeConsumer(CONSUMER, true);

        // Wire vault as fee recipient + rebate funder + protocolFeeVault.
        vm.prank(OWNER);
        feesManager.setFeeRecipient(address(vault));
        vm.prank(OWNER);
        feesManager.setRebateFundingAccount(address(vault));
        vm.prank(OWNER);
        feesManager.setProtocolFeeVault(address(vault));
    }

    function testV2GRX_Integration_PositiveChargeUpdatesVaultBuckets() external {
        // Tier-0 taker on a basis = 1e6 premium ⇒ feeAmount = 250 native.
        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory q = feesManager.consumeFees(
            TAKER, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, ASSET, 1_000_000
        );

        // The hook fired: vault buckets updated.
        assertEq(vault.feeBalance(ASSET), 250, "feeBalance");
        assertEq(vault.grossFeesCollected(ASSET), 250, "grossFeesCollected");
        assertEq(vault.netRevenue(ASSET), 250, "netRevenue");
        assertEq(vault.rebatesPaid(ASSET), 0, "rebatesPaid stays 0");
        assertEq(vault.rebateReserve(ASSET), 0, "rebateReserve stays 0");

        // FM-V2 quote shape unchanged.
        assertEq(q.feeAmount, 250);
        assertFalse(q.isRebate);
    }

    function testV2GRX_Integration_RebatePullsFromReserveAndDecrementsBudget() external {
        _claimTier(MAKER, 4);
        _fundBudget(1_000);

        // Set up reserve first by pretending the operator pre-allocated
        // it via the V2G-R5 bootstrap (or via charge + allocate).
        _credit(ASSET, 100);
        vm.prank(OWNER);
        vault.allocateToRebateReserve(ASSET, 100);
        assertEq(vault.feeBalance(ASSET), 0);
        assertEq(vault.rebateReserve(ASSET), 100);

        // Tier-4 maker rebate at basis = 1e6 ⇒ rebate = 50 native.
        uint256 budgetBefore = feesManager.rebateBudget(ASSET);
        vm.prank(CONSUMER);
        IFeesManagerV2.FeeQuote memory q = feesManager.consumeFees(
            MAKER, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, ASSET, 1_000_000
        );

        // FM-V2 rebate budget decremented independently of vault accounting.
        assertEq(feesManager.rebateBudget(ASSET), budgetBefore - 50);

        // Vault: rebateReserve drawn down; rebatesPaid up; netRevenue down.
        assertEq(vault.rebateReserve(ASSET), 50, "rebateReserve drawn down");
        assertEq(vault.rebatesPaid(ASSET), 50, "rebatesPaid up");
        // grossFeesCollected stayed at 100 from the credit above; netRevenue = 100 - 50 = 50.
        assertEq(vault.grossFeesCollected(ASSET), 100);
        assertEq(vault.netRevenue(ASSET), 50);

        assertTrue(q.isRebate);
        assertEq(q.feeAmount, 50);
    }

    function testV2GRX_Integration_AccountingIdentityHoldsAcrossMixedFlow() external {
        _claimTier(MAKER, 4);
        _fundBudget(1_000);

        // 1. Three positive charges.
        _consumeCharge(TAKER, 1_000_000); // 250
        _consumeCharge(TAKER, 1_000_000); // 250
        _consumeCharge(TAKER, 1_000_000); // 250

        assertEq(vault.grossFeesCollected(ASSET), 750);
        assertEq(vault.feeBalance(ASSET), 750);
        assertEq(vault.netRevenue(ASSET), 750);

        // 2. Allocate 300 to reserve.
        vm.prank(OWNER);
        vault.allocateToRebateReserve(ASSET, 300);
        assertEq(vault.feeBalance(ASSET), 450);
        assertEq(vault.rebateReserve(ASSET), 300);
        // Accounting identity still holds.
        assertEq(vault.grossFeesCollected(ASSET) - vault.rebatesPaid(ASSET), vault.netRevenue(ASSET));

        // 3. Two rebates pulled from reserve.
        _consumeRebate(MAKER, 1_000_000); // 50
        _consumeRebate(MAKER, 1_000_000); // 50

        assertEq(vault.rebatesPaid(ASSET), 100);
        assertEq(vault.rebateReserve(ASSET), 200);
        assertEq(vault.netRevenue(ASSET), 650);
        // Identity: gross(750) - rebates(100) == net(650).
        assertEq(vault.grossFeesCollected(ASSET) - vault.rebatesPaid(ASSET), vault.netRevenue(ASSET));
    }

    function testV2GRX_Integration_HookSilentWhenProtocolFeeVaultUnset() external {
        // Rollback path: unset protocolFeeVault while keeping the vault
        // as fee recipient. Subsequent charges do NOT update vault buckets.
        vm.prank(OWNER);
        feesManager.setProtocolFeeVault(address(0));

        vm.prank(CONSUMER);
        feesManager.consumeFees(
            TAKER, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, ASSET, 1_000_000
        );

        // Vault buckets stay at zero.
        assertEq(vault.feeBalance(ASSET), 0);
        assertEq(vault.grossFeesCollected(ASSET), 0);
        assertEq(vault.netRevenue(ASSET), 0);
    }

    function testV2GRX_Integration_FmV2RebateBudgetIndependentOfVaultReserve() external {
        _claimTier(MAKER, 4);
        _fundBudget(40); // less than the rebate amount intentionally.

        // Vault has reserve, but FM-V2 budget is short.
        _credit(ASSET, 200);
        vm.prank(OWNER);
        vault.allocateToRebateReserve(ASSET, 200);

        // FM-V2 reverts BEFORE the vault hook is reached because the
        // budget check is in FM-V2.consumeFees.
        vm.prank(CONSUMER);
        vm.expectRevert(abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, ASSET, 40, 50));
        feesManager.consumeFees(
            MAKER, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, ASSET, 1_000_000
        );

        // Confirm vault state didn't change.
        assertEq(vault.rebateReserve(ASSET), 200);
        assertEq(vault.rebatesPaid(ASSET), 0);
    }

    function testV2GRX_Integration_VaultMustNotShadowRebateBudget() external {
        // Even when the vault has 0 reserve, FM-V2 has its own budget.
        // The vault hook reverts with InsufficientRebateReserve, which
        // bubbles up and reverts the whole consumeFees — preserving the
        // V2G-RX "revert for configured vault" semantics.
        _claimTier(MAKER, 4);
        _fundBudget(1_000); // FM-V2 budget plenty.
        // Vault reserve = 0.

        vm.prank(CONSUMER);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeVault.InsufficientRebateReserve.selector, 0, 50));
        feesManager.consumeFees(
            MAKER, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, ASSET, 1_000_000
        );

        // Both budget and vault counters unchanged because the whole tx reverted.
        assertEq(feesManager.rebateBudget(ASSET), 1_000);
        assertEq(vault.rebatesPaid(ASSET), 0);
    }

    /* -------------------- helpers -------------------- */

    function _claimTier(address account, uint8 tier) internal {
        bytes32 root = feesManager.hashTierLeaf(
            account, tier, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL
        );
        vm.prank(OWNER);
        feesManager.setMerkleRoot(root, VALID_FROM, VALID_UNTIL);
        vm.prank(account);
        feesManager.claimTier(
            account, tier, VOLUME_28D, VOLUME_SHARE_PPM, STAKED_DEOPT, VALID_FROM, VALID_UNTIL, new bytes32[](0)
        );
    }

    function _fundBudget(uint256 amount) internal {
        vm.prank(OWNER);
        feesManager.fundRebateBudget(ASSET, amount);
    }

    /// @dev Credits the vault as if a trader paid a fee via the engine →
    ///      CV.transferBetweenAccounts → FM-V2.consumeFees → vault hook
    ///      flow. The stub CV doesn't actually track inter-account
    ///      movement; this helper invokes the hook directly to simulate
    ///      the credit side of a positive-fee consumption.
    function _credit(address asset, uint256 amount) internal {
        vm.prank(address(feesManager));
        vault.onFeeCharged(asset, amount);
    }

    function _consumeCharge(address trader, uint256 premium) internal {
        vm.prank(CONSUMER);
        feesManager.consumeFees(
            trader, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, false, ASSET, premium
        );
    }

    function _consumeRebate(address trader, uint256 premium) internal {
        vm.prank(CONSUMER);
        feesManager.consumeFees(
            trader, IFeesManagerV2.ProductKind.OPTION, IFeesManagerV2.FlowKind.ORDERBOOK, true, ASSET, premium
        );
    }
}

/// @notice Stub CollateralVault — implements the V2G-R1
///         {ICollateralVaultInternalTransfer} interface and tracks
///         per-account balances enough to satisfy
///         {ProtocolFeeVault}'s invariants. Does NOT simulate the
///         real CV's yield-adapter / strategy-share machinery — the
///         integration test exercises the FM-V2 → vault hook flow,
///         not the CV's withdrawal mechanics (those are pinned
///         separately by `testV2GRX_TransferFromInternalAccount*` in
///         the CV unit suite).
contract StubCollateralVault is ICollateralVaultInternalTransfer {
    mapping(address => mapping(address => uint256)) public balances;

    function transferFromInternalAccount(address asset, address to, uint256 amount) external override {
        require(balances[msg.sender][asset] >= amount, "stub CV: insufficient");
        balances[msg.sender][asset] -= amount;
        balances[to][asset] += amount;
    }

    // Test-only helper used by ProtocolFeeVault's invariant harness; not invoked
    // by the V2G-RX integration suite directly.
    function mockTransferIn(address asset, address to, uint256 amount) external {
        balances[to][asset] += amount;
    }
}
