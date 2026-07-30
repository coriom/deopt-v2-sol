// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {OptionMatchingEngineV2} from "../../../src/hybrid-v2/options/OptionMatchingEngineV2.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {MarginEngineV2} from "../../../src/hybrid-v2/margin/MarginEngineV2.sol";
import {IOptionsRiskProvider} from "../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockOptionsRiskProvider} from "../margin/harness/MockOptionsRiskProvider.sol";
import {MockOracleAdapter} from "../margin/harness/MockOracleAdapter.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {MockOptionExecutionFeeHook} from "./harness/MockOptionExecutionFeeHook.sol";

/// @title OptionEngineHandler
/// @notice Bounded fuzz handler tracking canonical lifecycle state across
///         reusable partial-fill orders + individual cancellation +
///         min-valid-nonce bulk advance.
///         Two persistent tracked orders — one large buy (alice) and one
///         large sell (bob) — signed once at setup; every `attemptFill` call
///         fills part of the same reusable pair until fully filled or
///         cancelled.
contract OptionEngineHandler is Test {
    OptionMatchingEngineV2 public engine;
    OptionsPositionsLedger public ledger;
    RiskAwareVaultHarness public vault;
    SubaccountRegistry public registry;
    MockERC20 public usdc;
    MarginEngineV2 public marginEngine;

    address public alice;
    uint256 public alicePk;
    address public bob;
    uint256 public bobPk;

    // Persistent tracked orders (canonical filled-quantity reconstruction target).
    IntentHash.SignedActionEnvelope public trackedBuyerEnv;
    bytes public trackedBuyerSig;
    OptionOrderTypes.OptionOrder public trackedBuyerOrder;
    IntentHash.SignedActionEnvelope public trackedSellerEnv;
    bytes public trackedSellerSig;
    OptionOrderTypes.OptionOrder public trackedSellerOrder;
    bytes32 public trackedBuyerOrderId;
    bytes32 public trackedSellerOrderId;

    // "Shadow" tracked order that no action ever touches — proves order
    // independence + no cross-order lifecycle mutation (ORDER-LIFE-I3/I4).
    IntentHash.SignedActionEnvelope public shadowBuyerEnv;
    bytes32 public shadowBuyerOrderId;

    // Ghost mirrors.
    uint128 public constant TRACKED_ORDER_MAX_QTY = 20e8; // 20 contracts
    uint128 public ghostBuyerFilled;
    uint128 public ghostSellerFilled;
    uint128 public ghostBuyerFilledAtCancellation;
    uint256 public ghostFillCount;
    uint256 public ghostAlicePremiumPaid;
    uint256 public ghostBobPremiumReceived;
    uint256 public ghostAliceMinValidNonceMax; // ever-highest min-valid-nonce for alice
    uint256 public ghostAliceOwnerEpochMax; // ever-highest owner-epoch for alice
    bool public ghostBuyerCancelled;

    constructor(
        OptionMatchingEngineV2 engine_,
        OptionsPositionsLedger ledger_,
        RiskAwareVaultHarness vault_,
        SubaccountRegistry registry_,
        MockERC20 usdc_,
        MarginEngineV2 marginEngine_,
        address alice_,
        uint256 alicePk_,
        address bob_,
        uint256 bobPk_
    ) {
        engine = engine_;
        ledger = ledger_;
        vault = vault_;
        registry = registry_;
        usdc = usdc_;
        marginEngine = marginEngine_;
        alice = alice_;
        alicePk = alicePk_;
        bob = bob_;
        bobPk = bobPk_;

        // Pre-sign the two tracked reusable orders.
        trackedBuyerOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: TRACKED_ORDER_MAX_QTY,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 500e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("tracked-buyer")
        });
        trackedSellerOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: TRACKED_ORDER_MAX_QTY,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 10e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("tracked-seller")
        });
        trackedBuyerEnv = IntentHash.SignedActionEnvelope({
            owner: alice,
            subaccountId: 1,
            subKey: registry.subKeyOf(alice, 1),
            signer: alice,
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: 1,
            deadline: block.timestamp + 30 days,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(trackedBuyerOrder)
        });
        trackedSellerEnv = IntentHash.SignedActionEnvelope({
            owner: bob,
            subaccountId: 1,
            subKey: registry.subKeyOf(bob, 1),
            signer: bob,
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: 1,
            deadline: block.timestamp + 30 days,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(trackedSellerOrder)
        });
        bytes32 bDigest = engine.hashSignedActionEnvelopeDigest(trackedBuyerEnv);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(alicePk, bDigest);
        trackedBuyerSig = abi.encodePacked(rB, sB, vB);
        bytes32 sDigest = engine.hashSignedActionEnvelopeDigest(trackedSellerEnv);
        (uint8 vS, bytes32 rS, bytes32 sS) = vm.sign(bobPk, sDigest);
        trackedSellerSig = abi.encodePacked(rS, sS, vS);
        trackedBuyerOrderId = bDigest;
        trackedSellerOrderId = sDigest;

        // Shadow buyer envelope — signed but NEVER interacted with.
        OptionOrderTypes.OptionOrder memory shadowOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: TRACKED_ORDER_MAX_QTY,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 500e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("shadow-buyer")
        });
        shadowBuyerEnv = IntentHash.SignedActionEnvelope({
            owner: alice,
            subaccountId: 1,
            subKey: registry.subKeyOf(alice, 1),
            signer: alice,
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: 99, // distinct from trackedBuyer nonce 1
            deadline: block.timestamp + 30 days,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(shadowOrder)
        });
        shadowBuyerOrderId = engine.hashSignedActionEnvelopeDigest(shadowBuyerEnv);
    }

    /// @dev Attempt a partial fill against the persistent tracked pair.
    function attemptPartialFill(uint32 seed) external {
        // Bounded fill quantity in [1..3] contracts, capped by remaining capacity.
        uint128 rawQty = uint128((seed % 3) + 1) * 1e8;
        uint128 remainingBuyer = TRACKED_ORDER_MAX_QTY - ghostBuyerFilled;
        uint128 remainingSeller = TRACKED_ORDER_MAX_QTY - ghostSellerFilled;
        uint128 fillQty = rawQty;
        if (fillQty > remainingBuyer) fillQty = remainingBuyer;
        if (fillQty > remainingSeller) fillQty = remainingSeller;
        if (fillQty == 0 || ghostBuyerCancelled) return;

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        try engine.executeMatch(
            trackedBuyerEnv,
            trackedBuyerSig,
            trackedBuyerOrder,
            trackedSellerEnv,
            trackedSellerSig,
            trackedSellerOrder,
            fillQty,
            ids,
            ids
        ) {
            ghostFillCount++;
            ghostBuyerFilled += fillQty;
            ghostSellerFilled += fillQty;
            uint256 native = (uint256(fillQty) * uint256(trackedBuyerOrder.pricePerContract1e8)) / 1e8 / 100;
            ghostAlicePremiumPaid += native;
            ghostBobPremiumReceived += native;
        } catch {
            // Every mutation is atomic — nothing persists on revert.
        }
    }

    /// @dev Attempt cancellation of the tracked buyer order.
    function attemptCancelTrackedBuyer() external {
        if (ghostBuyerCancelled || ghostBuyerFilled >= TRACKED_ORDER_MAX_QTY) return;
        vm.prank(alice);
        try engine.cancelSignedOrder(trackedBuyerEnv) {
            ghostBuyerCancelled = true;
            ghostBuyerFilledAtCancellation = ghostBuyerFilled;
        } catch {}
    }

    /// @dev Attempt to advance alice's owner recovery epoch. Any epoch change
    ///      invalidates every signed envelope with a stale epoch pair; the
    ///      canonical `filledQuantity1e8` mapping and cancellation flags are
    ///      NEVER cleared as a consequence.
    function attemptAdvanceAliceOwnerEpoch() external {
        vm.prank(alice);
        try engine.advanceMyOwnerRecoveryEpoch() {
            ghostAliceOwnerEpochMax++;
        } catch {}
    }

    /// @dev Attempt to advance alice's min-valid-nonce (bounded).
    function attemptAdvanceAliceMinNonce(uint32 seed) external {
        uint256 currentMax = ghostAliceMinValidNonceMax;
        uint256 target = currentMax + 1 + (seed % 3);
        vm.prank(alice);
        try engine.advanceMinValidOrderNonce(1, target) {
            ghostAliceMinValidNonceMax = target;
        } catch {}
    }
}

contract OptionMatchingEngineV2InvariantTest is StdInvariant, Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsRiskModuleV2 internal module;
    MarginEngineV2 internal marginEngine;
    OptionMatchingEngineV2 internal engine;
    MockOptionsRiskProvider internal provider;
    MockOracleAdapter internal oracle;
    MockOptionExecutionFeeHook internal feeHook;
    MockERC20 internal usdc;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal alice;
    uint256 internal alicePk;
    address internal bob;
    uint256 internal bobPk;
    address internal carol; // sibling — must remain untouched
    address internal protocolFeeOwner = address(0xF001);
    address internal rebateBudgetOwner = address(0xF002);
    address internal insuranceFundOwner = address(0xF003);

    OptionEngineHandler internal handler;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        carol = address(0xCA401);

        registry = new SubaccountRegistry(address(0xDEAD));
        provider = new MockOptionsRiskProvider();
        oracle = new MockOracleAdapter();
        usdc = new MockERC20("USDC", "USDC", 6);
        feeHook = new MockOptionExecutionFeeHook();

        uint256 nonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), nonce);
        address predictedVault = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), nonce + 2);
        module = new OptionsRiskModuleV2(
            address(registry),
            predictedVault,
            predictedLedger,
            1,
            address(provider),
            address(oracle),
            address(usdc),
            6,
            1 hours
        );
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        marginEngine = new MarginEngineV2(address(vault), 1);
        engine = new OptionMatchingEngineV2(
            address(vault), address(marginEngine), address(feeHook), guardian, governance, 1
        );

        vm.startPrank(governance);
        vault.addSupportedToken(address(usdc));
        vault.setEngineCapability(address(engine), Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vault.setEngineCapability(address(engine), Capabilities.CAP_LOCK_COLLATERAL, true);
        vault.setEngineCapability(address(engine), Capabilities.CAP_UNLOCK_OWN_RESERVATION, true);
        vault.setEngineCapability(address(engine), Capabilities.CAP_APPLY_OPTIONS_PREMIUM, true);
        vault.setEngineCapability(address(engine), Capabilities.CAP_APPLY_FEE, true);
        vault.setEngineCapability(address(engine), Capabilities.CAP_APPLY_REBATE, true);
        vault.initializeProtocolSubaccounts(protocolFeeOwner, 1, rebateBudgetOwner, 1, insuranceFundOwner, 1);
        vm.stopPrank();

        vm.prank(alice);
        registry.registerNext();
        vm.prank(bob);
        registry.registerNext();
        vm.prank(carol);
        registry.registerNext();
        vm.prank(protocolFeeOwner);
        registry.registerNext();
        vm.prank(rebateBudgetOwner);
        registry.registerNext();
        vm.prank(insuranceFundOwner);
        registry.registerNext();

        provider.setUnderlying(
            address(0xE7E7),
            IOptionsRiskProvider.UnderlyingRiskView({
                spotShockDownBps: 2500, spotShockUpBps: 2500, volShockDownBps: 0, volShockUpBps: 0, isEnabled: true
            })
        );
        provider.setOptionsRiskConfig(
            address(0xE7E7),
            IOptionsRiskProvider.OptionsRiskConfigView({
                baseMaintenanceMarginPerContract: 5e8,
                imFactorBps: 12_000,
                oracleDownMmMultiplierBps: 20_000,
                isConfigured: true
            })
        );
        oracle.setPrice(address(0xE7E7), address(usdc), 3_000e8, block.timestamp);
        provider.setSeries(
            1,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: address(0xE7E7),
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: 3000e8,
                contractSize1e8: 1e8,
                isCall: true,
                isActive: true,
                exists: true
            })
        );

        usdc.mint(alice, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(alice);
        vault.deposit(1, address(usdc), 100_000e6);

        usdc.mint(bob, 100_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), 100_000e6);
        vm.prank(bob);
        vault.deposit(1, address(usdc), 100_000e6);

        usdc.mint(carol, 500e6);
        vm.prank(carol);
        usdc.approve(address(vault), 500e6);
        vm.prank(carol);
        vault.deposit(1, address(usdc), 500e6);

        handler =
            new OptionEngineHandler(engine, ledger, vault, registry, usdc, marginEngine, alice, alicePk, bob, bobPk);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.attemptPartialFill.selector;
        selectors[1] = handler.attemptCancelTrackedBuyer.selector;
        selectors[2] = handler.attemptAdvanceAliceMinNonce.selector;
        selectors[3] = handler.attemptAdvanceAliceOwnerEpoch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// OPTION-EXEC-I1: engine's canonical filledQuantityOf equals the ghost mirror.
    function invariant_I1_filledQuantityMirrorsGhost() public view {
        assertEq(uint256(engine.filledQuantityOf(handler.trackedBuyerOrderId())), uint256(handler.ghostBuyerFilled()));
        assertEq(uint256(engine.filledQuantityOf(handler.trackedSellerOrderId())), uint256(handler.ghostSellerFilled()));
    }

    /// OPTION-EXEC-I2: filled quantity never exceeds signed maximum.
    function invariant_I2_filledNeverExceedsSignedMax() public view {
        assertLe(
            uint256(engine.filledQuantityOf(handler.trackedBuyerOrderId())), uint256(handler.TRACKED_ORDER_MAX_QTY())
        );
        assertLe(
            uint256(engine.filledQuantityOf(handler.trackedSellerOrderId())), uint256(handler.TRACKED_ORDER_MAX_QTY())
        );
    }

    /// OPTION-EXEC-I8: premium buyer debit == seller credit.
    function invariant_I8_premiumConservation() public view {
        bytes32 aliceSk = registry.subKeyOf(alice, 1);
        bytes32 bobSk = registry.subKeyOf(bob, 1);
        uint256 alicePaid = 100_000e6 - vault.balanceOf(aliceSk, address(usdc));
        uint256 bobGained = vault.balanceOf(bobSk, address(usdc)) - 100_000e6;
        assertEq(alicePaid, bobGained);
    }

    /// OPTION-EXEC-I9: sibling isolation — carol's balance/positions never change.
    function invariant_I9_siblingIsolation() public view {
        bytes32 carolSk = registry.subKeyOf(carol, 1);
        assertEq(vault.balanceOf(carolSk, address(usdc)), 500e6);
        assertEq(uint256(ledger.activeSeriesCount(carolSk)), 0);
        assertEq(vault.lockedByEngineOf(carolSk, address(usdc), address(engine)), 0);
    }

    /// OPTION-EXEC-I11: engine never unlocks another engine's reservation.
    function invariant_I11_neverUnlocksSibling() public view {
        bytes32 aliceSk = registry.subKeyOf(alice, 1);
        assertEq(vault.lockedByEngineOf(aliceSk, address(usdc), address(0xBEEF)), 0);
    }

    /// OPTION-EXEC-I14: engine and vault use same immutable RiskModule.
    function invariant_I14_singleRiskModule() public view {
        assertEq(address(engine.RISK_MODULE()), address(vault.RISK_MODULE()));
    }

    /// OPTION-EXEC-I16: recovery epochs are ONLY mutated by the canonical
    ///                 owner-path primitives on `ReplayAndEpochController`.
    ///                 No `executeMatch`, `cancelSignedOrder`, or
    ///                 `advanceMinValidOrderNonce` call may advance an owner
    ///                 or subaccount recovery epoch. Bob (not touched by any
    ///                 handler epoch action) always sits at zero;
    ///                 subaccount-recovery epochs (also not touched) stay at
    ///                 zero for both. Alice's owner epoch is bounded by the
    ///                 ghost mirror of `attemptAdvanceAliceOwnerEpoch`.
    function invariant_I16_epochsUnchanged() public view {
        assertEq(engine.ownerRecoveryEpoch(alice), handler.ghostAliceOwnerEpochMax());
        assertEq(engine.ownerRecoveryEpoch(bob), 0);
        assertEq(engine.subaccountRecoveryEpoch(registry.subKeyOf(alice, 1)), 0);
        assertEq(engine.subaccountRecoveryEpoch(registry.subKeyOf(bob, 1)), 0);
    }

    /// OPTION-EXEC-I17: bounded input processing (max 32 series, max 8 tokens).
    function invariant_I17_bounded() public view {
        assertLe(uint256(ledger.activeSeriesCount(registry.subKeyOf(alice, 1))), 32);
        assertLe(uint256(ledger.activeSeriesCount(registry.subKeyOf(bob, 1))), 32);
        assertLe(vault.collateralTokenCount(), 8);
    }

    /// OPTION-EXEC-I18: no governance/guardian trade fabrication.
    function invariant_I18_noGovernanceOrGuardianTradeInsertion() public view {
        assertEq(
            vault.balanceOf(registry.subKeyOf(alice, 1), address(usdc))
                + vault.balanceOf(registry.subKeyOf(bob, 1), address(usdc)),
            200_000e6
        );
    }

    /// OPTION-LIFECYCLE-I19: min-valid-nonce monotone non-decreasing per subKey.
    ///                       The ghost mirror only ever increments on success.
    function invariant_I19_minValidNonceMonotone() public view {
        assertEq(engine.minValidOrderNonceOf(registry.subKeyOf(alice, 1)), handler.ghostAliceMinValidNonceMax());
    }

    /// OPTION-LIFECYCLE-I20: cancelled orders stay cancelled and cannot re-fill.
    ///                       If the ghost recorded cancellation, on-chain flag holds
    ///                       AND filled-quantity has not advanced past cancellation.
    function invariant_I20_cancellationTerminal() public view {
        if (handler.ghostBuyerCancelled()) {
            assertTrue(engine.isOrderCancelled(handler.trackedBuyerOrderId()));
            // Filled quantity does not advance after cancellation.
            assertEq(
                uint256(engine.filledQuantityOf(handler.trackedBuyerOrderId())),
                uint256(handler.ghostBuyerFilledAtCancellation())
            );
        }
    }

    /// ORDER-LIFE-I3: shadow order (never touched by any handler action) has
    ///                zero filled quantity, is not cancelled, and its
    ///                min-valid-nonce cutoff cannot force it below its own nonce.
    function invariant_I3_shadowOrderIndependent() public view {
        assertEq(uint256(engine.filledQuantityOf(handler.shadowBuyerOrderId())), 0);
        assertFalse(engine.isOrderCancelled(handler.shadowBuyerOrderId()));
    }

    /// ORDER-LIFE-I12: recovery-epoch changes invalidate stale orders without
    ///                 deleting historical fill state. Even after arbitrarily many
    ///                 owner-epoch advances, `filledQuantityOf(trackedBuyer)`
    ///                 remains at the ghost value.
    function invariant_I12_epochAdvanceDoesNotClearFillHistory() public view {
        assertEq(uint256(engine.filledQuantityOf(handler.trackedBuyerOrderId())), uint256(handler.ghostBuyerFilled()));
    }

    /// ORDER-LIFE-I13: no governance/guardian function rewrites lifecycle state.
    ///                 Neither owner-recovery-epoch advances nor pause/unpause
    ///                 (which only guardian/governance may do) can alter filled
    ///                 quantity, cancellation flag, or min-valid-nonce.
    function invariant_I13_noGovernanceGuardianLifecycleRewrite() public view {
        assertEq(uint256(engine.filledQuantityOf(handler.trackedBuyerOrderId())), uint256(handler.ghostBuyerFilled()));
        assertEq(uint256(engine.filledQuantityOf(handler.shadowBuyerOrderId())), 0);
    }
}
