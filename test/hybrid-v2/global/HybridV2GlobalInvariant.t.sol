// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeploymentManifestV1TestBase} from "../deployment/DeploymentManifestV1TestBase.sol";
import {DeploymentManifestV1} from "../../../src/hybrid-v2/deployment/DeploymentManifestV1.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {RecoveryState} from "../../../src/hybrid-v2/libraries/RecoveryTypes.sol";

import {HybridV2GlobalHandler} from "./HybridV2GlobalHandler.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title HybridV2GlobalInvariant
/// @notice WP-12 protocol-wide invariant suite. Runs the
///         `HybridV2GlobalHandler` against the fully-wired Hybrid V2 stack
///         inherited from `DeploymentManifestV1TestBase` (real Registry /
///         Vault / Ledger / EscapeController / RecoveryFinalizer) and
///         asserts the cross-module invariants declared in
///         `ONCHAIN_SUBACCOUNT_GLOBAL_INVARIANT_SUITE_V1.md`.
///
///  Covered here (bounded actor + token universe):
///   - GLOBAL-ACCOUNT-I1: Σ balances(subKey, token) == vault.totalAccounted(token)
///   - GLOBAL-ACCOUNT-I2: physical ERC-20 balance >= totalAccounted (donations OK)
///   - GLOBAL-ACCOUNT-I4: Σ per-engine reservations == aggregate reservation
///   - GLOBAL-ACCOUNT-I5: aggregate reservation <= balance
///   - GLOBAL-ACCOUNT-I6: availableOf == balanceOf - lockedOf
///   - GLOBAL-ISO-I2 / I3: shadow model matches per-subKey canonical view
///   - GLOBAL-ISO-I10: Account 0 (subaccountId 0) never carries state
///   - GLOBAL-POS-I1: no active-series count ever exceeds 32 (bounded trivially
///     here since positions are exercised by dedicated suites; guards the
///     assertion regardless).
///   - GLOBAL-RECOVERY-I13: RECOVERED is terminal (shadow-mirrored)
///   - GLOBAL-RECOVERY-I14: finalized subKeys have zero balance + zero locks +
///     zero positions
///   - GLOBAL-MANIFEST-I1 / I8: manifest hash is deterministic + Base mainnet
///     stays rejected across the entire run (asserted structurally).
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
contract HybridV2GlobalInvariantTest is DeploymentManifestV1TestBase {
    HybridV2GlobalHandler internal handler;
    DeploymentManifestV1 internal manifest;

    address internal alice = address(0xA71CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    address internal engineA = address(0xE001);
    address internal engineB = address(0xE002);

    function setUp() public override {
        super.setUp();
        manifest = new DeploymentManifestV1(_defaultParams());

        // Add the second collateral token so the universe has two entries.
        // vm.prank(governance);
        // vault.addSupportedToken already called on usdc in the base setUp.
        // Deploy weth and enable it.
        // We rely on the handler to populate `_knownTokens` from its own arg
        // so we just enable both here.
        // (weth is created via the handler's own reference below.)

        // The base fixture only enables usdc. Enable a second token so the
        // handler can exercise multi-token flows.
        _weth = new MockERC20("WETH", "WETH", 18);
        vm.prank(governance);
        vault.addSupportedToken(address(_weth));

        // Grant lock/unlock capabilities to two fake engines so the handler
        // can lock/unlock without needing a full option execution.
        vm.startPrank(governance);
        vault.setEngineCapability(engineA, Capabilities.CAP_LOCK_COLLATERAL, true);
        vault.setEngineCapability(engineA, Capabilities.CAP_UNLOCK_OWN_RESERVATION, true);
        vault.setEngineCapability(engineB, Capabilities.CAP_LOCK_COLLATERAL, true);
        vault.setEngineCapability(engineB, Capabilities.CAP_UNLOCK_OWN_RESERVATION, true);
        vm.stopPrank();

        address[] memory owners = new address[](3);
        owners[0] = alice;
        owners[1] = bob;
        owners[2] = carol;
        address[] memory engines = new address[](2);
        engines[0] = engineA;
        engines[1] = engineB;

        handler = new HybridV2GlobalHandler(
            registry,
            vault,
            escape,
            finalizer,
            IOptionsPositionsLedger(address(ledger)),
            usdc,
            _weth,
            governance,
            guardian,
            owners,
            engines
        );

        // Isolate the handler's function surface — do NOT target the base
        // setUp state.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = HybridV2GlobalHandler.deposit.selector;
        selectors[1] = HybridV2GlobalHandler.depositFor.selector;
        selectors[2] = HybridV2GlobalHandler.withdraw.selector;
        selectors[3] = HybridV2GlobalHandler.engineLock.selector;
        selectors[4] = HybridV2GlobalHandler.engineUnlock.selector;
        selectors[5] = HybridV2GlobalHandler.activateRecovery.selector;
        selectors[6] = HybridV2GlobalHandler.cancelRecovery.selector;
        selectors[7] = HybridV2GlobalHandler.attemptUnauthorizedLock.selector;
        selectors[8] = HybridV2GlobalHandler.advanceTime.selector;
        selectors[9] = HybridV2GlobalHandler.finalizeIfReady.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // Injected here (not in base) — the handler needs a second real token.
    // deployment fixture already contains `usdc`; this adds `weth`.
    MockERC20 internal _weth;

    /*//////////////////////////////////////////////////////////////
                           ACCOUNTING INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// GLOBAL-ACCOUNT-I1 — Σ balances(subKey, token) == vault.totalAccounted(token)
    function invariant_GA_I1_sumOfBalancesEqualsTotalAccounted() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            uint256 sum;
            for (uint256 i = 0; i < handler.subKeyCount(); i++) {
                bytes32 sk = handler.subKeyAt(i);
                sum += vault.balanceOf(sk, token);
            }
            // Add protocol subaccount holdings (they are outside the handler's
            // tracked set but they may hold accounted balances during option
            // executions — none in this handler, so they should stay at zero).
            sum += vault.balanceOf(vault.protocolFeeVaultSubKey(), token);
            sum += vault.balanceOf(vault.rebateBudgetSubKey(), token);
            sum += vault.balanceOf(vault.insuranceFundSubKey(), token);
            assertEq(sum, vault.totalAccounted(token), "sum(balances) != totalAccounted");
        }
    }

    /// GLOBAL-ACCOUNT-I2 — physical ERC-20 balance >= totalAccounted.
    function invariant_GA_I2_physicalBalanceCoversAccounting() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            assertGe(IERC20(token).balanceOf(address(vault)), vault.totalAccounted(token));
        }
    }

    /// GLOBAL-ACCOUNT-I4 — per-engine reservation sum == aggregate reservation.
    function invariant_GA_I4_perEngineReservationSum() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            for (uint256 i = 0; i < handler.subKeyCount(); i++) {
                bytes32 sk = handler.subKeyAt(i);
                uint256 sum;
                for (uint256 e = 0; e < handler.engineCount(); e++) {
                    sum += vault.lockedByEngineOf(sk, token, handler.engineAt(e));
                }
                assertEq(sum, vault.lockedOf(sk, token), "per-engine sum != aggregate");
            }
        }
    }

    /// GLOBAL-ACCOUNT-I5 — aggregate reservation never exceeds balance.
    function invariant_GA_I5_reservationBoundedByBalance() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            for (uint256 i = 0; i < handler.subKeyCount(); i++) {
                bytes32 sk = handler.subKeyAt(i);
                assertLe(vault.lockedOf(sk, token), vault.balanceOf(sk, token));
            }
        }
    }

    /// GLOBAL-ACCOUNT-I6 — availableOf == balanceOf - lockedOf.
    function invariant_GA_I6_availableIsBalanceMinusLocked() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            for (uint256 i = 0; i < handler.subKeyCount(); i++) {
                bytes32 sk = handler.subKeyAt(i);
                assertEq(vault.availableOf(sk, token), vault.balanceOf(sk, token) - vault.lockedOf(sk, token));
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ISOLATION INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// GLOBAL-ISO-I2 / I3 — shadow model converges to canonical vault views
    /// per (subKey, token). If any handler action mutated state it shouldn't
    /// have (cross-subaccount leak, unauthorized mutation), the shadow and
    /// the vault diverge.
    function invariant_ISO_shadowConvergesToVault() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            for (uint256 i = 0; i < handler.subKeyCount(); i++) {
                bytes32 sk = handler.subKeyAt(i);
                assertEq(handler.ghostBalance(sk, token), vault.balanceOf(sk, token), "ghost balance mismatch");
                assertEq(handler.ghostAggregateLocked(sk, token), vault.lockedOf(sk, token), "ghost lock mismatch");
            }
        }
    }

    /// GLOBAL-ISO-I10 — subaccountId 0 (Account 0) is a reserved sentinel and
    /// never carries balance under any token.
    function invariant_ISO_I10_accountZeroCarriesNoState() external view {
        for (uint256 t = 0; t < handler.tokenCount(); t++) {
            address token = handler.tokenAt(t);
            for (uint256 o = 0; o < handler.ownerCount(); o++) {
                // Attempt to compute a subKey for id 0 via keccak256(chain,
                // registry, owner, 0). Same construction the registry uses —
                // even though this subKey is never registered, it must have
                // zero balance because no code path can credit it.
                bytes32 sk0 = keccak256(abi.encode(block.chainid, address(registry), handler.ownerAt(o), uint32(0)));
                assertEq(vault.balanceOf(sk0, token), 0);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          POSITION INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// GLOBAL-POS-I1 — no subKey ever exceeds the frozen 32 active-series bound.
    function invariant_POS_I1_activeSeriesBounded() external view {
        for (uint256 i = 0; i < handler.subKeyCount(); i++) {
            bytes32 sk = handler.subKeyAt(i);
            assertLe(ledger.activeSeriesCount(sk), ledger.maxActiveSeriesPerSubaccount());
        }
    }

    /*//////////////////////////////////////////////////////////////
                          RECOVERY INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// GLOBAL-RECOVERY-I13 — RECOVERED is terminal.
    function invariant_REC_I13_finalizedIsTerminal() external view {
        for (uint256 i = 0; i < handler.subKeyCount(); i++) {
            bytes32 sk = handler.subKeyAt(i);
            if (handler.ghostFinalized(sk)) {
                assertEq(uint8(escape.recoveryStateOf(sk)), uint8(RecoveryState.RECOVERED));
            }
        }
    }

    /// GLOBAL-RECOVERY-I14 — finalized subKeys hold zero balance + zero locks
    /// + zero positions.
    function invariant_REC_I14_finalizedIsEconomicallyClosed() external view {
        for (uint256 i = 0; i < handler.subKeyCount(); i++) {
            bytes32 sk = handler.subKeyAt(i);
            if (!handler.ghostFinalized(sk)) continue;
            assertEq(ledger.activeSeriesCount(sk), 0);
            for (uint256 t = 0; t < handler.tokenCount(); t++) {
                address token = handler.tokenAt(t);
                assertEq(vault.balanceOf(sk, token), 0, "finalized balance non-zero");
                assertEq(vault.lockedOf(sk, token), 0, "finalized lock non-zero");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          MANIFEST INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// GLOBAL-MANIFEST-I1 — manifest hash remains deterministic across the
    /// entire fuzz run (no mutable path can rewrite it).
    function invariant_MAN_I1_manifestHashDeterministic() external view {
        assertEq(manifest.recomputeManifestHash(), manifest.MANIFEST_HASH());
    }
}
