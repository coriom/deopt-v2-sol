// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";

import {ProtocolFeeVault} from "../../src/fees/ProtocolFeeVault.sol";
import {IProtocolFeeVault} from "../../src/fees/IProtocolFeeVault.sol";
import {ICollateralVaultInternalTransfer} from "../../src/collateral/ICollateralVaultInternalTransfer.sol";

/// @notice V2G-R1 — offline unit + invariant suite for
///         {ProtocolFeeVault}. Uses a mock {CollateralVault} that
///         tracks per-account balances exactly enough to:
///          - model the "feeBalance + rebateReserve == CV balance"
///            invariant,
///          - exercise the withdraw path that calls
///            `transferFromInternalAccount`.
///         No live CollateralVault is touched.
contract ProtocolFeeVaultTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant FEES_MANAGER_V2 = address(0xF12);
    address internal constant ASSET = address(0xCAFE);
    address internal constant ASSET2 = address(0xC0DE);
    address internal constant REVENUE_RECEIVER = address(0xBEA1);
    address internal constant TRADER = address(0x7AAD);
    address internal constant BOB = address(0xB0B);

    MockCollateralVault internal collateralVault;
    ProtocolFeeVault internal vault;

    event FeeRecorded(address indexed asset, uint256 amount);
    event RebateRecorded(address indexed asset, uint256 amount);
    event RebateReserveAllocated(address indexed asset, uint256 amount);
    event RevenueWithdrawn(address indexed asset, address indexed to, uint256 amount);
    event RebatesPaused(address indexed by);
    event RebatesUnpaused(address indexed by);
    event RevenueReceiverUpdated(address indexed previous, address indexed next);
    event BootstrapCompleted(
        address indexed asset, uint256 grossFees, uint256 rebates, uint256 feeBalance, uint256 rebateReserve
    );

    function setUp() public {
        collateralVault = new MockCollateralVault();
        vault = new ProtocolFeeVault(OWNER, address(collateralVault), FEES_MANAGER_V2);

        // Owner sets a default revenue receiver so withdrawRevenue
        // smoke tests don't need to re-set it.
        vm.prank(OWNER);
        vault.setRevenueReceiver(REVENUE_RECEIVER);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        new ProtocolFeeVault(address(0), address(collateralVault), FEES_MANAGER_V2);
    }

    function test_constructorRejectsZeroCollateralVault() public {
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        new ProtocolFeeVault(OWNER, address(0), FEES_MANAGER_V2);
    }

    function test_constructorRejectsZeroFeesManagerV2() public {
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        new ProtocolFeeVault(OWNER, address(collateralVault), address(0));
    }

    function test_initialStateIsZero() public view {
        assertEq(vault.owner(), OWNER);
        assertEq(vault.collateralVault(), address(collateralVault));
        assertEq(vault.feesManagerV2(), FEES_MANAGER_V2);
        assertEq(vault.revenueReceiver(), REVENUE_RECEIVER);
        assertFalse(vault.rebatesPaused());

        assertEq(vault.feeBalance(ASSET), 0);
        assertEq(vault.rebateReserve(ASSET), 0);
        assertEq(vault.grossFeesCollected(ASSET), 0);
        assertEq(vault.rebatesPaid(ASSET), 0);
        assertEq(vault.netRevenue(ASSET), 0);
        assertFalse(vault.bootstrapped(ASSET));
    }

    /*//////////////////////////////////////////////////////////////
                                  HOOKS
    //////////////////////////////////////////////////////////////*/

    function test_onFeeChargedUpdatesGrossAndFeeBalanceAndNetRevenue() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit FeeRecorded(ASSET, 1_000);

        vm.prank(FEES_MANAGER_V2);
        vault.onFeeCharged(ASSET, 1_000);

        assertEq(vault.feeBalance(ASSET), 1_000);
        assertEq(vault.grossFeesCollected(ASSET), 1_000);
        assertEq(vault.netRevenue(ASSET), 1_000);
        assertEq(vault.rebatesPaid(ASSET), 0);
        assertEq(vault.rebateReserve(ASSET), 0);
    }

    function test_onFeeChargedRejectsNonFmCaller() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotFeesManagerV2.selector);
        vault.onFeeCharged(ASSET, 1_000);
    }

    function test_onFeeChargedRejectsZeroAsset() public {
        vm.prank(FEES_MANAGER_V2);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.onFeeCharged(address(0), 1_000);
    }

    function test_onFeeChargedZeroAmountIsNoop() public {
        vm.prank(FEES_MANAGER_V2);
        vault.onFeeCharged(ASSET, 0);
        assertEq(vault.feeBalance(ASSET), 0);
        assertEq(vault.grossFeesCollected(ASSET), 0);
    }

    function test_onRebatePaidUpdatesRebatesAndReserveAndNetRevenue() public {
        // Set up reserve first via fee + allocate.
        _credit(ASSET, 5_000);
        _allocateToReserve(ASSET, 3_000);

        vm.expectEmit(true, false, false, true, address(vault));
        emit RebateRecorded(ASSET, 1_000);

        vm.prank(FEES_MANAGER_V2);
        vault.onRebatePaid(ASSET, 1_000);

        assertEq(vault.rebateReserve(ASSET), 2_000);
        assertEq(vault.rebatesPaid(ASSET), 1_000);
        assertEq(vault.netRevenue(ASSET), 4_000); // 5000 gross - 1000 rebates
        assertEq(vault.grossFeesCollected(ASSET), 5_000);
        assertEq(vault.feeBalance(ASSET), 2_000); // 5000 - 3000 allocated
    }

    function test_onRebatePaidRejectsNonFmCaller() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotFeesManagerV2.selector);
        vault.onRebatePaid(ASSET, 1_000);
    }

    function test_onRebatePaidRevertsWhenInsufficientReserve() public {
        _credit(ASSET, 1_000);
        _allocateToReserve(ASSET, 500);

        vm.prank(FEES_MANAGER_V2);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeVault.InsufficientRebateReserve.selector, 500, 600));
        vault.onRebatePaid(ASSET, 600);
    }

    function test_onRebatePaidWhilePausedReverts() public {
        _credit(ASSET, 2_000);
        _allocateToReserve(ASSET, 1_500);
        vm.prank(OWNER);
        vault.pauseRebates();

        vm.prank(FEES_MANAGER_V2);
        vm.expectRevert(ProtocolFeeVault.RebatesPausedError.selector);
        vault.onRebatePaid(ASSET, 100);
    }

    function test_onRebatePaidZeroAmountIsNoop() public {
        vm.prank(FEES_MANAGER_V2);
        vault.onRebatePaid(ASSET, 0);
        assertEq(vault.rebatesPaid(ASSET), 0);
        assertEq(vault.rebateReserve(ASSET), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          ALLOCATE TO RESERVE
    //////////////////////////////////////////////////////////////*/

    function test_allocateMovesFromFeeBalanceToReserve() public {
        _credit(ASSET, 10_000);

        vm.expectEmit(true, false, false, true, address(vault));
        emit RebateReserveAllocated(ASSET, 3_000);

        vm.prank(OWNER);
        vault.allocateToRebateReserve(ASSET, 3_000);

        assertEq(vault.feeBalance(ASSET), 7_000);
        assertEq(vault.rebateReserve(ASSET), 3_000);
        // Allocate does NOT change cumulative totals.
        assertEq(vault.grossFeesCollected(ASSET), 10_000);
        assertEq(vault.rebatesPaid(ASSET), 0);
        assertEq(vault.netRevenue(ASSET), 10_000);
    }

    function test_allocateRevertsWhenInsufficientFeeBalance() public {
        _credit(ASSET, 1_000);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeVault.InsufficientFeeBalance.selector, 1_000, 1_500));
        vault.allocateToRebateReserve(ASSET, 1_500);
    }

    function test_allocateRevertsOnZeroAmount() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.AmountZero.selector);
        vault.allocateToRebateReserve(ASSET, 0);
    }

    function test_allocateRejectsZeroAsset() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.allocateToRebateReserve(address(0), 100);
    }

    function test_allocateRejectsNonOwnerCaller() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotOwner.selector);
        vault.allocateToRebateReserve(ASSET, 100);
    }

    /*//////////////////////////////////////////////////////////////
                                WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_withdrawDecrementsFeeBalanceAndCallsCollateralVault() public {
        _credit(ASSET, 10_000);

        vm.expectEmit(true, true, false, true, address(vault));
        emit RevenueWithdrawn(ASSET, REVENUE_RECEIVER, 2_500);

        vm.prank(OWNER);
        vault.withdrawRevenue(ASSET, REVENUE_RECEIVER, 2_500);

        assertEq(vault.feeBalance(ASSET), 7_500);
        // Cumulative counters unchanged.
        assertEq(vault.grossFeesCollected(ASSET), 10_000);
        assertEq(vault.netRevenue(ASSET), 10_000);
        // CollateralVault recorded the outbound transfer.
        assertEq(collateralVault.transferOutCount(ASSET, REVENUE_RECEIVER), 1);
        assertEq(collateralVault.lastTransferOutAmount(ASSET, REVENUE_RECEIVER), 2_500);
    }

    function test_withdrawRefusesRebateReserveBucket() public {
        _credit(ASSET, 1_000);
        _allocateToReserve(ASSET, 1_000);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ProtocolFeeVault.InsufficientFeeBalance.selector, 0, 100));
        vault.withdrawRevenue(ASSET, REVENUE_RECEIVER, 100);
    }

    function test_withdrawRefusesZeroAmount() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.AmountZero.selector);
        vault.withdrawRevenue(ASSET, REVENUE_RECEIVER, 0);
    }

    function test_withdrawRefusesZeroAsset() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.withdrawRevenue(address(0), REVENUE_RECEIVER, 100);
    }

    function test_withdrawRefusesZeroTo() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.withdrawRevenue(ASSET, address(0), 100);
    }

    function test_withdrawRejectsNonOwnerCaller() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotOwner.selector);
        vault.withdrawRevenue(ASSET, REVENUE_RECEIVER, 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pauseAndUnpauseToggleFlag() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit RebatesPaused(OWNER);
        vm.prank(OWNER);
        vault.pauseRebates();
        assertTrue(vault.rebatesPaused());

        vm.expectEmit(true, false, false, false, address(vault));
        emit RebatesUnpaused(OWNER);
        vm.prank(OWNER);
        vault.unpauseRebates();
        assertFalse(vault.rebatesPaused());
    }

    function test_pauseRejectsNonOwner() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotOwner.selector);
        vault.pauseRebates();
    }

    function test_unpauseRejectsNonOwner() public {
        vm.prank(OWNER);
        vault.pauseRebates();
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotOwner.selector);
        vault.unpauseRebates();
    }

    /*//////////////////////////////////////////////////////////////
                              REVENUE RECEIVER
    //////////////////////////////////////////////////////////////*/

    function test_setRevenueReceiverEmitsAndPersists() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit RevenueReceiverUpdated(REVENUE_RECEIVER, BOB);
        vm.prank(OWNER);
        vault.setRevenueReceiver(BOB);
        assertEq(vault.revenueReceiver(), BOB);
    }

    function test_setRevenueReceiverRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.setRevenueReceiver(address(0));
    }

    function test_setRevenueReceiverRejectsNonOwner() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotOwner.selector);
        vault.setRevenueReceiver(BOB);
    }

    /*//////////////////////////////////////////////////////////////
                                BOOTSTRAP
    //////////////////////////////////////////////////////////////*/

    function test_bootstrapHappyPath() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit BootstrapCompleted(ASSET, 10_000, 1_500, 6_000, 2_500);

        vm.prank(OWNER);
        vault.bootstrap(ASSET, 10_000, 1_500, 6_000, 2_500);

        assertEq(vault.grossFeesCollected(ASSET), 10_000);
        assertEq(vault.rebatesPaid(ASSET), 1_500);
        assertEq(vault.netRevenue(ASSET), 8_500);
        assertEq(vault.feeBalance(ASSET), 6_000);
        assertEq(vault.rebateReserve(ASSET), 2_500);
        assertTrue(vault.bootstrapped(ASSET));
    }

    function test_bootstrapRevertsOnSecondCall() public {
        vm.prank(OWNER);
        vault.bootstrap(ASSET, 1_000, 0, 1_000, 0);

        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.AlreadyBootstrapped.selector);
        vault.bootstrap(ASSET, 2_000, 0, 2_000, 0);
    }

    function test_bootstrapDistinctAssetsAreIndependent() public {
        vm.prank(OWNER);
        vault.bootstrap(ASSET, 1_000, 0, 1_000, 0);

        vm.prank(OWNER);
        vault.bootstrap(ASSET2, 500, 0, 500, 0);

        assertTrue(vault.bootstrapped(ASSET));
        assertTrue(vault.bootstrapped(ASSET2));
        assertEq(vault.grossFeesCollected(ASSET2), 500);
    }

    function test_bootstrapRevertsWhenRebatesExceedGrossFees() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.InvalidBootstrapValues.selector);
        vault.bootstrap(ASSET, 100, 200, 0, 0);
    }

    function test_bootstrapRevertsWhenSpendableExceedsNet() public {
        // 1000 gross - 500 rebates = 500 net; feeBalance + reserve = 600 > 500.
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.InvalidBootstrapValues.selector);
        vault.bootstrap(ASSET, 1_000, 500, 400, 200);
    }

    function test_bootstrapRejectsZeroAsset() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.bootstrap(address(0), 0, 0, 0, 0);
    }

    function test_bootstrapRejectsNonOwner() public {
        vm.prank(BOB);
        vm.expectRevert(ProtocolFeeVault.NotOwner.selector);
        vault.bootstrap(ASSET, 0, 0, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function test_transferOwnershipUpdatesAndEmits() public {
        vm.prank(OWNER);
        vault.transferOwnership(BOB);
        assertEq(vault.owner(), BOB);
    }

    function test_transferOwnershipRejectsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(ProtocolFeeVault.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              END-TO-END
    //////////////////////////////////////////////////////////////*/

    function test_fullLifecycleAcrossTwoAssets() public {
        // Asset 1: 10k fee, 4k allocated to reserve, 2k rebated, 5k withdrawn.
        _credit(ASSET, 10_000);
        _allocateToReserve(ASSET, 4_000);
        _rebate(ASSET, 2_000);
        vm.prank(OWNER);
        vault.withdrawRevenue(ASSET, REVENUE_RECEIVER, 5_000);

        assertEq(vault.feeBalance(ASSET), 1_000); // 10000 - 4000 - 5000
        assertEq(vault.rebateReserve(ASSET), 2_000); // 4000 - 2000
        assertEq(vault.grossFeesCollected(ASSET), 10_000);
        assertEq(vault.rebatesPaid(ASSET), 2_000);
        assertEq(vault.netRevenue(ASSET), 8_000); // 10000 - 2000

        // Asset 2: independent.
        _credit(ASSET2, 500);
        assertEq(vault.feeBalance(ASSET2), 500);
        assertEq(vault.grossFeesCollected(ASSET2), 500);
        // Cross-asset isolation.
        assertEq(vault.feeBalance(ASSET), 1_000);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Models a positive-fee path: trader → CV → vault internal
    ///      account, then FM-V2 calls the hook. Keeps the mock CV
    ///      balance and vault buckets in lockstep so invariant 2
    ///      remains testable.
    function _credit(address asset, uint256 amount) internal {
        collateralVault.mockTransferIn(asset, address(vault), amount);
        vm.prank(FEES_MANAGER_V2);
        vault.onFeeCharged(asset, amount);
    }

    /// @dev Models a rebate path: vault → CV → trader, then FM-V2
    ///      calls the hook.
    function _rebate(address asset, uint256 amount) internal {
        collateralVault.mockTransferOut(asset, address(vault), TRADER, amount);
        vm.prank(FEES_MANAGER_V2);
        vault.onRebatePaid(asset, amount);
    }

    /// @dev Pure internal book entry — no CV balance change.
    function _allocateToReserve(address asset, uint256 amount) internal {
        vm.prank(OWNER);
        vault.allocateToRebateReserve(asset, amount);
    }
}

/* ------------------------------------------------------------------ */
/*                              MOCK CV                                */
/* ------------------------------------------------------------------ */

/// @dev Minimal CollateralVault stand-in. Models per-account balances
///      and implements {ICollateralVaultInternalTransfer} so the
///      vault's `withdrawRevenue` can exercise the call path without
///      depending on the production CollateralVault ABI.
contract MockCollateralVault is ICollateralVaultInternalTransfer {
    mapping(address => mapping(address => uint256)) public balances;

    // Telemetry for assertions.
    mapping(address => mapping(address => uint256)) public transferOutCount;
    mapping(address => mapping(address => uint256)) public lastTransferOutAmount;

    /// @dev Test-only helper: credit an internal account.
    function mockTransferIn(address asset, address to, uint256 amount) external {
        balances[to][asset] += amount;
    }

    /// @dev Test-only helper: debit an internal account, credit an
    ///      external recipient (models the rebate transfer path).
    function mockTransferOut(address asset, address from, address to, uint256 amount) external {
        require(balances[from][asset] >= amount, "MockCollateralVault: insufficient balance");
        balances[from][asset] -= amount;
        to; // not tracked — external recipient is off-vault.
    }

    /// @inheritdoc ICollateralVaultInternalTransfer
    function transferFromInternalAccount(address asset, address to, uint256 amount) external override {
        // Mirror the gate the production extension is expected to use:
        // msg.sender's internal balance is the only one being debited.
        require(balances[msg.sender][asset] >= amount, "MockCollateralVault: insufficient balance");
        balances[msg.sender][asset] -= amount;
        transferOutCount[asset][to] += 1;
        lastTransferOutAmount[asset][to] = amount;
    }
}

/* ------------------------------------------------------------------ */
/*                       INVARIANT HARNESS                             */
/* ------------------------------------------------------------------ */

/// @notice V2G-R1 — randomised invariant suite for the vault.
contract ProtocolFeeVaultInvariantTest is StdInvariant, Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant FEES_MANAGER_V2 = address(0xF12);
    address internal constant ASSET = address(0xCAFE);
    address internal constant REVENUE_RECEIVER = address(0xBEA1);
    address internal constant TRADER = address(0x7AAD);

    MockCollateralVault internal collateralVault;
    ProtocolFeeVault internal vault;
    VaultActor internal actor;

    function setUp() public {
        collateralVault = new MockCollateralVault();
        vault = new ProtocolFeeVault(OWNER, address(collateralVault), FEES_MANAGER_V2);

        vm.prank(OWNER);
        vault.setRevenueReceiver(REVENUE_RECEIVER);

        actor = new VaultActor(vault, collateralVault, OWNER, FEES_MANAGER_V2, TRADER, REVENUE_RECEIVER, ASSET);

        targetContract(address(actor));
        targetSender(address(this));
    }

    /// @notice Invariant 1: accounting identity.
    function invariant_accountingIdentity() public view {
        assertEq(
            vault.grossFeesCollected(ASSET) - vault.rebatesPaid(ASSET),
            vault.netRevenue(ASSET),
            "gross - rebates must equal netRevenue"
        );
    }

    /// @notice Invariant 2: feeBalance + rebateReserve equals the
    ///         modeled CollateralVault internal balance.
    function invariant_internalBalanceConservation() public view {
        assertEq(
            vault.feeBalance(ASSET) + vault.rebateReserve(ASSET),
            collateralVault.balances(address(vault), ASSET),
            "feeBalance + rebateReserve must equal vault CV balance"
        );
    }

    /// @notice Invariant 3a: grossFeesCollected is monotonic non-decreasing.
    function invariant_grossFeesCollectedMonotonic() public view {
        assertGe(vault.grossFeesCollected(ASSET), actor.observedGross(), "grossFeesCollected went down");
    }

    /// @notice Invariant 3b: rebatesPaid is monotonic non-decreasing.
    function invariant_rebatesPaidMonotonic() public view {
        assertGe(vault.rebatesPaid(ASSET), actor.observedRebates(), "rebatesPaid went down");
    }

    /// @notice Invariant 4: while paused, no withdrawal has touched
    ///         the reserve bucket. The actor records the reserve
    ///         balance at pause time; any decrease below that during
    ///         pause is a violation.
    function invariant_pauseProtectsReserve() public view {
        if (actor.pauseReserveSnapshot() == type(uint256).max) return;
        if (!vault.rebatesPaused()) return;
        assertEq(vault.rebateReserve(ASSET), actor.pauseReserveSnapshot(), "rebateReserve changed while paused");
    }
}

/// @notice Stateful actor — forge invariant fuzzer drives these
///         entry points; each call leaves the system in a consistent
///         state.
contract VaultActor is Test {
    ProtocolFeeVault public vault;
    MockCollateralVault public collateralVault;
    address public owner;
    address public feesManagerV2;
    address public trader;
    address public revenueReceiver;
    address public asset;

    uint256 public observedGross;
    uint256 public observedRebates;
    uint256 public pauseReserveSnapshot;

    constructor(
        ProtocolFeeVault vault_,
        MockCollateralVault cv_,
        address owner_,
        address fm_,
        address trader_,
        address receiver_,
        address asset_
    ) {
        vault = vault_;
        collateralVault = cv_;
        owner = owner_;
        feesManagerV2 = fm_;
        trader = trader_;
        revenueReceiver = receiver_;
        asset = asset_;
        pauseReserveSnapshot = type(uint256).max; // sentinel: no pause yet observed
    }

    function chargeFee(uint128 amount) external {
        uint256 amt = uint256(amount) % 1_000_000;
        collateralVault.mockTransferIn(asset, address(vault), amt);
        vm.prank(feesManagerV2);
        vault.onFeeCharged(asset, amt);
        observedGross += amt;
    }

    function payRebate(uint128 amount) external {
        if (vault.rebatesPaused()) return;
        uint256 reserve = vault.rebateReserve(asset);
        if (reserve == 0) return;
        uint256 amt = uint256(amount) % reserve;
        if (amt == 0) return;
        collateralVault.mockTransferOut(asset, address(vault), trader, amt);
        vm.prank(feesManagerV2);
        vault.onRebatePaid(asset, amt);
        observedRebates += amt;
    }

    function allocate(uint128 amount) external {
        uint256 fb = vault.feeBalance(asset);
        if (fb == 0) return;
        uint256 amt = uint256(amount) % fb;
        if (amt == 0) return;
        vm.prank(owner);
        vault.allocateToRebateReserve(asset, amt);
        if (vault.rebatesPaused()) {
            // Allocate during pause is allowed; reserve changes
            // outside of the rebate path. Refresh snapshot so the
            // invariant tracks the new baseline.
            pauseReserveSnapshot = vault.rebateReserve(asset);
        }
    }

    function withdraw(uint128 amount) external {
        uint256 fb = vault.feeBalance(asset);
        if (fb == 0) return;
        uint256 amt = uint256(amount) % fb;
        if (amt == 0) return;
        vm.prank(owner);
        vault.withdrawRevenue(asset, revenueReceiver, amt);
    }

    function pause() external {
        if (vault.rebatesPaused()) return;
        vm.prank(owner);
        vault.pauseRebates();
        pauseReserveSnapshot = vault.rebateReserve(asset);
    }

    function unpause() external {
        if (!vault.rebatesPaused()) return;
        vm.prank(owner);
        vault.unpauseRebates();
        pauseReserveSnapshot = type(uint256).max;
    }
}
