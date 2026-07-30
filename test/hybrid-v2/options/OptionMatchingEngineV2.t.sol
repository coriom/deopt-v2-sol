// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {OptionMatchingEngineV2} from "../../../src/hybrid-v2/options/OptionMatchingEngineV2.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {IOptionExecutionFeeHook} from "../../../src/hybrid-v2/interfaces/IOptionExecutionFeeHook.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IOptionsRiskProvider} from "../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsRiskModuleV2} from "../../../src/hybrid-v2/risk/OptionsRiskModuleV2.sol";
import {MarginEngineV2} from "../../../src/hybrid-v2/margin/MarginEngineV2.sol";
import {ReplayAndEpochController} from "../../../src/hybrid-v2/security/ReplayAndEpochController.sol";

import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockOptionsRiskProvider} from "../margin/harness/MockOptionsRiskProvider.sol";
import {MockOracleAdapter} from "../margin/harness/MockOracleAdapter.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {MockOptionExecutionFeeHook} from "./harness/MockOptionExecutionFeeHook.sol";
import {MockERC1271Wallet} from "./harness/MockERC1271Wallet.sol";

/// @title OptionMatchingEngineV2TestBase
/// @notice Shared setup for every WP-08B execution engine test suite. Wires the
///         full stack (Registry, Vault, Ledger, RiskModule, MarginEngine,
///         Engine, FeeHook) with two owners and USDC as the frozen quote token.
abstract contract OptionMatchingEngineV2TestBase is Test {
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
    // WP-09 protocol subaccount owners (deployment-fixed identities).
    address internal protocolFeeOwner = address(0xF001);
    address internal rebateBudgetOwner = address(0xF002);
    address internal insuranceFundOwner = address(0xF003);

    // EOA owners with known private keys via foundry `makeAddrAndKey`.
    address internal alice;
    uint256 internal alicePk;
    address internal bob;
    uint256 internal bobPk;
    address internal carol;
    uint256 internal carolPk;

    uint16 internal constant MOD_VERSION = 1;
    uint16 internal constant ENGINE_VERSION = 1;
    uint256 internal constant MAX_STALE = 1 hours;

    uint64 internal constant STRIKE_1E8 = 3000e8;

    function setUp() public virtual {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");
        (carol, carolPk) = makeAddrAndKey("carol");

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
            MOD_VERSION,
            address(provider),
            address(oracle),
            address(usdc),
            6,
            MAX_STALE
        );
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        marginEngine = new MarginEngineV2(address(vault), 1);
        engine = new OptionMatchingEngineV2(
            address(vault), address(marginEngine), address(feeHook), guardian, governance, ENGINE_VERSION
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

        // Register both counterparties.
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

        // Underlying + option risk config for a WETH-like underlying settled in USDC.
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

        _series(1, address(0xE7E7), STRIKE_1E8, true);
    }

    function _series(uint256 seriesId, address underlying, uint64 strike1e8, bool isCall) internal {
        provider.setSeries(
            seriesId,
            IOptionsRiskProvider.SeriesRiskView({
                underlying: underlying,
                settlementAsset: address(usdc),
                expiry: uint64(block.timestamp + 30 days),
                strike1e8: strike1e8,
                contractSize1e8: 1e8,
                isCall: isCall,
                isActive: true,
                exists: true
            })
        );
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    function _fund(address o, uint32 id, uint256 amt) internal {
        usdc.mint(o, amt);
        vm.prank(o);
        usdc.approve(address(vault), amt);
        vm.prank(o);
        vault.deposit(id, address(usdc), amt);
    }

    /// @dev Build a canonical envelope + order pair.
    function _makeEnvelope(
        address ownerAddr,
        uint32 subaccountId,
        uint256 signerNonce,
        uint256 deadline,
        bytes32 payloadHash
    ) internal view returns (IntentHash.SignedActionEnvelope memory) {
        return IntentHash.SignedActionEnvelope({
            owner: ownerAddr,
            subaccountId: subaccountId,
            subKey: registry.subKeyOf(ownerAddr, subaccountId),
            signer: ownerAddr,
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: signerNonce,
            deadline: deadline,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: payloadHash
        });
    }

    function _sign(uint256 privateKey, IntentHash.SignedActionEnvelope memory envelope)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = engine.hashSignedActionEnvelopeDigest(envelope);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build a matched pair for series 1, quantity 1 contract, price 100 USDC.
    function _buildDefaultMatch(uint256 buyerNonce, uint256 sellerNonce)
        internal
        view
        returns (
            IntentHash.SignedActionEnvelope memory bEnv,
            bytes memory bSig,
            OptionOrderTypes.OptionOrder memory bOrder,
            IntentHash.SignedActionEnvelope memory sEnv,
            bytes memory sSig,
            OptionOrderTypes.OptionOrder memory sOrder
        )
    {
        bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("buyer-salt")
        });
        sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            maxPositiveFeePpm: 100_000,
            salt: bytes32("seller-salt")
        });
        bytes32 bHash = OptionOrderTypes.hashOrder(bOrder);
        bytes32 sHash = OptionOrderTypes.hashOrder(sOrder);
        bEnv = _makeEnvelope(alice, 1, buyerNonce, block.timestamp + 1 hours, bHash);
        sEnv = _makeEnvelope(bob, 1, sellerNonce, block.timestamp + 1 hours, sHash);
        bSig = _sign(alicePk, bEnv);
        sSig = _sign(bobPk, sEnv);
    }
}

/// @title OptionMatchingEngineV2ConstructorTest
/// @notice Constructor + dependency wiring.
contract OptionMatchingEngineV2ConstructorTest is OptionMatchingEngineV2TestBase {
    function test_bindsAllReferences() public view {
        assertEq(address(engine.VAULT()), address(vault));
        assertEq(address(engine.RISK_MODULE()), address(module));
        assertEq(address(engine.MARGIN_ENGINE()), address(marginEngine));
        assertEq(address(engine.OPTIONS_LEDGER()), address(ledger));
        assertEq(address(engine.RISK_PROVIDER()), address(provider));
        assertEq(engine.QUOTE_TOKEN(), address(usdc));
        assertEq(uint256(engine.QUOTE_DECIMALS()), 6);
        assertEq(address(engine.FEE_HOOK()), address(feeHook));
        assertEq(engine.GUARDIAN(), guardian);
        assertEq(engine.GOVERNANCE(), governance);
    }

    function test_constructor_rejectsZeroMarginEngine() public {
        vm.expectRevert(IOptionMatchingEngine.InvalidDependency.selector);
        new OptionMatchingEngineV2(address(vault), address(0), address(feeHook), guardian, governance, ENGINE_VERSION);
    }

    function test_constructor_rejectsZeroFeeHook() public {
        vm.expectRevert(IOptionMatchingEngine.InvalidDependency.selector);
        new OptionMatchingEngineV2(
            address(vault), address(marginEngine), address(0), guardian, governance, ENGINE_VERSION
        );
    }

    function test_constructor_rejectsZeroGuardian() public {
        vm.expectRevert(IOptionMatchingEngine.InvalidDependency.selector);
        new OptionMatchingEngineV2(
            address(vault), address(marginEngine), address(feeHook), address(0), governance, ENGINE_VERSION
        );
    }

    function test_constructor_rejectsZeroGovernance() public {
        vm.expectRevert(IOptionMatchingEngine.InvalidDependency.selector);
        new OptionMatchingEngineV2(
            address(vault), address(marginEngine), address(feeHook), guardian, address(0), ENGINE_VERSION
        );
    }

    function test_constructor_rejectsZeroVersion() public {
        vm.expectRevert(IOptionMatchingEngine.InvalidDependency.selector);
        new OptionMatchingEngineV2(address(vault), address(marginEngine), address(feeHook), guardian, governance, 0);
    }

    function test_pause_guardianOnly() public {
        vm.prank(guardian);
        engine.pauseExecution();
        assertTrue(engine.executionPaused());

        vm.prank(governance);
        engine.unpauseExecution();
        assertFalse(engine.executionPaused());
    }

    function test_pause_rejectsUnauthorized() public {
        vm.expectRevert(IOptionMatchingEngine.InvalidDependency.selector);
        engine.pauseExecution();
    }
}
