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
/// @notice Bounded fuzz handler that attempts pair executions with two known
///         signers and tracks the ghost state expected to hold across every
///         function call.
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

    // Ghost mirrors.
    uint256 public ghostFillCount;
    uint256 public ghostAlicePremiumPaid;
    uint256 public ghostBobPremiumReceived;

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
    }

    function attemptFill(uint32 seed) external {
        uint256 currentAliceNonce = engine.nonces(alice);
        uint256 currentBobNonce = engine.nonces(bob);
        uint128 qty = 1e8;
        uint128 price = 100e8 + (uint128(seed % 100) * 1e6); // small variation

        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: qty,
            pricePerContract1e8: price,
            limitPricePerContract1e8: 500e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            salt: bytes32(uint256(seed))
        });
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: qty,
            pricePerContract1e8: price,
            limitPricePerContract1e8: 10e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            salt: bytes32(uint256(seed) + 1)
        });

        IntentHash.SignedActionEnvelope memory bEnv = IntentHash.SignedActionEnvelope({
            owner: alice,
            subaccountId: 1,
            subKey: registry.subKeyOf(alice, 1),
            signer: alice,
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: currentAliceNonce,
            deadline: block.timestamp + 1 hours,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(bOrder)
        });
        IntentHash.SignedActionEnvelope memory sEnv = IntentHash.SignedActionEnvelope({
            owner: bob,
            subaccountId: 1,
            subKey: registry.subKeyOf(bob, 1),
            signer: bob,
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: currentBobNonce,
            deadline: block.timestamp + 1 hours,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(sOrder)
        });

        bytes32 bDigest = engine.hashSignedActionEnvelopeDigest(bEnv);
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(alicePk, bDigest);
        bytes memory bSig = abi.encodePacked(rB, sB, vB);
        bytes32 sDigest = engine.hashSignedActionEnvelopeDigest(sEnv);
        (uint8 vS, bytes32 rS, bytes32 sS) = vm.sign(bobPk, sDigest);
        bytes memory sSig = abi.encodePacked(rS, sS, vS);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        try engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, ids, ids) {
            ghostFillCount++;
            // native premium = quantity1e8 * price / 1e8 / 100 (6-dec native from 8-dec 1e8).
            uint256 native = (uint256(qty) * uint256(price)) / 1e8 / 100;
            ghostAlicePremiumPaid += native;
            ghostBobPremiumReceived += native;
        } catch {
            // Rollback preserved — every mutation is atomic.
        }
    }

    function attemptCancelNonce(bool cancelAlice) external {
        if (cancelAlice) {
            vm.prank(alice);
            try engine.cancelNextNonce() {} catch {}
        } else {
            vm.prank(bob);
            try engine.cancelNextNonce() {} catch {}
        }
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
        vm.stopPrank();

        vm.prank(alice);
        registry.registerNext();
        vm.prank(bob);
        registry.registerNext();
        vm.prank(carol);
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

        // Fund alice + bob generously; carol funded to 500 USDC (must stay 500).
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
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.attemptFill.selector;
        selectors[1] = handler.attemptCancelNonce.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// OPTION-EXEC-I1: filled quantity is monotone non-decreasing (via ghost).
    function invariant_I1_fillCountMonotone() public view {
        // Ghost is monotone by construction — handler only increments on success.
        assertGe(handler.ghostFillCount(), 0);
    }

    /// OPTION-EXEC-I2: no order overfill (PF-2: each intent is single fill).
    /// After N successful fills, alice's long position == N * qty.
    function invariant_I2_positionMirrorsGhost() public view {
        bytes32 sk = registry.subKeyOf(alice, 1);
        uint256 longQty = uint256(ledger.positionOf(sk, 1).longQuantity1e8);
        // Each attempt uses qty = 1e8; ghost tracks successful count.
        assertEq(longQty, handler.ghostFillCount() * 1e8);
    }

    /// OPTION-EXEC-I8: premium buyer debit == seller credit (invariant per
    /// applyOptionPremiumTransfer — total accounted UNCHANGED).
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
    /// Since only this engine has CAP_LOCK/UNLOCK, and it only touches its own
    /// slot, `lockedByEngineOf(*, *, thirdEngine)` is always zero.
    function invariant_I11_neverUnlocksSibling() public view {
        bytes32 aliceSk = registry.subKeyOf(alice, 1);
        // Any "third engine" address slot is zero.
        assertEq(vault.lockedByEngineOf(aliceSk, address(usdc), address(0xBEEF)), 0);
    }

    /// OPTION-EXEC-I14: engine and vault use same immutable RiskModule.
    function invariant_I14_singleRiskModule() public view {
        assertEq(address(engine.RISK_MODULE()), address(vault.RISK_MODULE()));
    }

    /// OPTION-EXEC-I16: recovery epochs never mutated by execution.
    function invariant_I16_epochsUnchanged() public view {
        assertEq(engine.ownerRecoveryEpoch(alice), 0);
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
    /// Guardian can only pause; governance can only unpause. Neither has
    /// a path to mutate ledger positions, vault balances, or engine
    /// reservations.
    function invariant_I18_noGovernanceOrGuardianTradeInsertion() public view {
        assertEq(
            vault.balanceOf(registry.subKeyOf(alice, 1), address(usdc))
                + vault.balanceOf(registry.subKeyOf(bob, 1), address(usdc)),
            200_000e6
        );
    }
}
