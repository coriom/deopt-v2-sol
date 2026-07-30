// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IEscapeController} from "../../../src/hybrid-v2/interfaces/IEscapeController.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {RecoveryState} from "../../../src/hybrid-v2/libraries/RecoveryTypes.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {RiskAwareVaultHarness} from "../risk/harness/RiskAwareVaultHarness.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {EscapeControllerV1} from "../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {RecoveryFinalizerV1} from "../../../src/hybrid-v2/recovery/RecoveryFinalizerV1.sol";

/// @title HybridV2GlobalHandler
/// @notice Protocol-wide stateful handler for WP-12. Drives the fully-wired
///         Hybrid V2 stack (real Registry / Vault / Ledger / EscapeController /
///         RecoveryFinalizer) through a bounded action mix that combines:
///           - Vault mutations (deposit / depositFor / withdraw / engine
///             lock+unlock / governance token enable / recovery finalization);
///           - Recovery state-machine transitions;
///           - Unauthorized-caller probes (should revert with no state change).
///
///  Maintains an independent shadow model. The invariant contract compares
///  the shadow against canonical vault + escape views after every call.
///
///  Bounded actor + token universe:
///    - 3 EOA owners + protocol-fee + rebate-budget + insurance-fund;
///    - 2 collateral tokens (usdc, weth);
///    - 2 non-vault engines (0xE1, 0xE2) with LOCK + UNLOCK capabilities.
contract HybridV2GlobalHandler is Test {
    SubaccountRegistry public immutable registry;
    RiskAwareVaultHarness public immutable vault;
    EscapeControllerV1 public immutable escape;
    RecoveryFinalizerV1 public immutable finalizer;
    IOptionsPositionsLedger public immutable ledger;
    MockERC20 public immutable usdc;
    MockERC20 public immutable weth;

    address public immutable governance;
    address public immutable guardian;

    address[] internal _owners;
    address[] internal _engines;
    address[] internal _tokens;

    /*//////////////////////////////////////////////////////////////
                              GHOST STATE
    //////////////////////////////////////////////////////////////*/

    // Per (owner, subaccountId, token) balance and reservations.
    mapping(bytes32 => mapping(address => uint256)) public ghostBalance; // by subKey → token
    mapping(bytes32 => mapping(address => mapping(address => uint256))) public ghostEngineLocked; // subKey → token → engine
    mapping(bytes32 => mapping(address => uint256)) public ghostAggregateLocked; // subKey → token
    mapping(address => uint256) public ghostTotalAccounted; // token
    mapping(bytes32 => RecoveryState) public ghostRecoveryState; // subKey
    mapping(bytes32 => bool) public ghostFinalized; // subKey → true when RECOVERED
    mapping(bytes32 => bool) public ghostKnown; // subKey → recognised in universe

    // Ordered list of known subKeys for iteration during invariant checks.
    bytes32[] internal _knownSubKeys;

    // Ordered list of tokens for iteration during invariant checks.
    address[] internal _knownTokens;
    mapping(address => bool) internal _knownTokenSeen;

    // Rejection counters (informational).
    uint256 public rejectedActions;
    uint256 public successfulActions;

    constructor(
        SubaccountRegistry registry_,
        RiskAwareVaultHarness vault_,
        EscapeControllerV1 escape_,
        RecoveryFinalizerV1 finalizer_,
        IOptionsPositionsLedger ledger_,
        MockERC20 usdc_,
        MockERC20 weth_,
        address governance_,
        address guardian_,
        address[] memory owners_,
        address[] memory engines_
    ) {
        registry = registry_;
        vault = vault_;
        escape = escape_;
        finalizer = finalizer_;
        ledger = ledger_;
        usdc = usdc_;
        weth = weth_;
        governance = governance_;
        guardian = guardian_;
        for (uint256 i = 0; i < owners_.length; i++) {
            _owners.push(owners_[i]);
        }
        for (uint256 i = 0; i < engines_.length; i++) {
            _engines.push(engines_[i]);
        }
        _tokens.push(address(usdc));
        _tokens.push(address(weth));
        _addKnownToken(address(usdc));
        _addKnownToken(address(weth));
    }

    /*//////////////////////////////////////////////////////////////
                              HANDLERS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 ownerSeed, uint256 tokenSeed, uint96 amount) external {
        if (amount == 0) return _reject();
        address owner = _pickOwner(ownerSeed);
        address token = _pickToken(tokenSeed);
        _ensureAccount(owner, 1);
        bytes32 sk = registry.subKeyOf(owner, 1);
        if (ghostFinalized[sk]) return _reject();

        _mintAndApprove(owner, token, amount);
        vm.prank(owner);
        try vault.deposit(1, token, amount) {
            ghostBalance[sk][token] += amount;
            ghostTotalAccounted[token] += amount;
            _touchSubKey(sk);
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function depositFor(uint256 payerSeed, uint256 recipientSeed, uint256 tokenSeed, uint96 amount) external {
        if (amount == 0) return _reject();
        address payer = _pickOwner(payerSeed);
        address recipient = _pickOwner(recipientSeed);
        address token = _pickToken(tokenSeed);
        _ensureAccount(recipient, 1);
        bytes32 sk = registry.subKeyOf(recipient, 1);
        if (ghostFinalized[sk]) return _reject();

        _mintAndApprove(payer, token, amount);
        vm.prank(payer);
        try vault.depositFor(recipient, 1, token, amount) {
            ghostBalance[sk][token] += amount;
            ghostTotalAccounted[token] += amount;
            _touchSubKey(sk);
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function withdraw(uint256 ownerSeed, uint256 tokenSeed, uint96 amount) external {
        if (amount == 0) return _reject();
        address owner = _pickOwner(ownerSeed);
        address token = _pickToken(tokenSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        if (ghostFinalized[sk]) return _reject();
        if (
            ghostRecoveryState[sk] == RecoveryState.RECOVERY_PENDING
                || ghostRecoveryState[sk] == RecoveryState.RECOVERY_ACTIVE
        ) return _reject();
        uint256 avail = ghostBalance[sk][token] - ghostAggregateLocked[sk][token];
        if (avail < amount) return _reject();

        vm.prank(owner);
        try vault.withdraw(1, token, amount) {
            ghostBalance[sk][token] -= amount;
            ghostTotalAccounted[token] -= amount;
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function engineLock(uint256 ownerSeed, uint256 engineSeed, uint256 tokenSeed, uint96 amount) external {
        if (amount == 0) return _reject();
        address owner = _pickOwner(ownerSeed);
        address engine = _pickEngine(engineSeed);
        address token = _pickToken(tokenSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        if (ghostFinalized[sk]) return _reject();
        if (
            ghostRecoveryState[sk] == RecoveryState.RECOVERY_PENDING
                || ghostRecoveryState[sk] == RecoveryState.RECOVERY_ACTIVE
        ) return _reject();
        uint256 avail = ghostBalance[sk][token] - ghostAggregateLocked[sk][token];
        if (avail < amount) return _reject();

        vm.prank(engine);
        try vault.applyLock(sk, token, amount) {
            ghostEngineLocked[sk][token][engine] += amount;
            ghostAggregateLocked[sk][token] += amount;
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function engineUnlock(uint256 ownerSeed, uint256 engineSeed, uint256 tokenSeed, uint96 amount) external {
        if (amount == 0) return _reject();
        address owner = _pickOwner(ownerSeed);
        address engine = _pickEngine(engineSeed);
        address token = _pickToken(tokenSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        uint256 owned = ghostEngineLocked[sk][token][engine];
        if (owned < amount) return _reject();

        vm.prank(engine);
        try vault.applyUnlock(sk, token, amount) {
            ghostEngineLocked[sk][token][engine] = owned - amount;
            ghostAggregateLocked[sk][token] -= amount;
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function activateRecovery(uint256 ownerSeed) external {
        address owner = _pickOwner(ownerSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        if (ghostFinalized[sk]) return _reject();
        RecoveryState st = ghostRecoveryState[sk];
        // Transitions NORMAL/CANCELLED → PENDING; if PENDING and delay passed, → ACTIVE.
        vm.prank(owner);
        try escape.activateRecovery(1) {
            RecoveryState now_ = escape.recoveryStateOf(sk);
            ghostRecoveryState[sk] = now_;
            _touchSubKey(sk);
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function cancelRecovery(uint256 ownerSeed) external {
        address owner = _pickOwner(ownerSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        if (ghostFinalized[sk]) return _reject();
        vm.prank(owner);
        try escape.cancelRecovery(1) {
            ghostRecoveryState[sk] = RecoveryState.CANCELLED;
            successfulActions++;
        } catch {
            _reject();
        }
    }

    function advanceTime(uint256 seed) external {
        // Advance block.timestamp within a bounded window to permit
        // RECOVERY_PENDING → RECOVERY_ACTIVE transitions to fire on the next
        // activateRecovery call.
        uint256 delta = bound(seed, 1, escape.ACTIVATION_DELAY() + 1);
        vm.warp(block.timestamp + delta);
        vm.roll(block.number + 1);
        successfulActions++;
    }

    function finalizeIfReady(uint256 ownerSeed) external {
        address owner = _pickOwner(ownerSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        if (ghostFinalized[sk]) return _reject();
        // Only attempt when we KNOW zero reservations to keep the negative
        // path off the successful branch — reservation-blocked attempts are
        // covered explicitly in the atomicity matrix test.
        if (ghostAggregateLocked[sk][address(usdc)] != 0) return _reject();
        if (ghostAggregateLocked[sk][address(weth)] != 0) return _reject();
        if (escape.recoveryStateOf(sk) != RecoveryState.RECOVERY_ACTIVE) return _reject();

        vm.prank(owner);
        try finalizer.finalize(1) {
            ghostFinalized[sk] = true;
            ghostRecoveryState[sk] = RecoveryState.RECOVERED;
            // Every canonical token balance was atomically debited to the
            // owner and totalAccounted decremented — mirror it.
            uint256 usdcBal = ghostBalance[sk][address(usdc)];
            uint256 wethBal = ghostBalance[sk][address(weth)];
            if (usdcBal > 0) {
                ghostBalance[sk][address(usdc)] = 0;
                ghostTotalAccounted[address(usdc)] -= usdcBal;
            }
            if (wethBal > 0) {
                ghostBalance[sk][address(weth)] = 0;
                ghostTotalAccounted[address(weth)] -= wethBal;
            }
            successfulActions++;
        } catch {
            _reject();
        }
    }

    /// @notice Adversarial probe: an unauthorized caller tries to lock. Must
    ///         revert and MUST NOT change any state.
    function attemptUnauthorizedLock(uint256 ownerSeed, uint256 tokenSeed, uint96 amount) external {
        address rogue = address(uint160(uint256(keccak256(abi.encode("rogue", ownerSeed, tokenSeed, amount)))));
        if (rogue == address(0)) return _reject();
        address owner = _pickOwner(ownerSeed);
        address token = _pickToken(tokenSeed);
        if (!registry.existsOf(owner, 1)) return _reject();
        bytes32 sk = registry.subKeyOf(owner, 1);
        vm.prank(rogue);
        try vault.applyLock(sk, token, uint256(amount)) {
            // If this ever succeeds, the invariant contract will catch the
            // divergence — do NOT reflect the change in the ghost.
            successfulActions++;
        } catch {
            _reject();
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    function ownerAt(uint256 i) external view returns (address) {
        return _owners[i];
    }

    function engineCount() external view returns (uint256) {
        return _engines.length;
    }

    function engineAt(uint256 i) external view returns (address) {
        return _engines[i];
    }

    function tokenCount() external view returns (uint256) {
        return _knownTokens.length;
    }

    function tokenAt(uint256 i) external view returns (address) {
        return _knownTokens[i];
    }

    function subKeyCount() external view returns (uint256) {
        return _knownSubKeys.length;
    }

    function subKeyAt(uint256 i) external view returns (bytes32) {
        return _knownSubKeys[i];
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _pickOwner(uint256 seed) internal view returns (address) {
        return _owners[seed % _owners.length];
    }

    function _pickEngine(uint256 seed) internal view returns (address) {
        return _engines[seed % _engines.length];
    }

    function _pickToken(uint256 seed) internal view returns (address) {
        return _tokens[seed % _tokens.length];
    }

    function _mintAndApprove(address who, address token, uint96 amount) internal {
        MockERC20(token).mint(who, amount);
        vm.prank(who);
        MockERC20(token).approve(address(vault), type(uint256).max);
    }

    function _ensureAccount(address owner, uint32 id) internal {
        if (!registry.existsOf(owner, id)) {
            // Only Account 1 can be lazy-registered by the vault; higher IDs
            // must be explicitly created by the owner.
            if (id == 1) return; // vault will lazy-register on first deposit
            vm.prank(owner);
            registry.registerNext();
        }
    }

    function _touchSubKey(bytes32 sk) internal {
        if (!ghostKnown[sk]) {
            ghostKnown[sk] = true;
            _knownSubKeys.push(sk);
        }
    }

    function _addKnownToken(address token) internal {
        if (!_knownTokenSeen[token]) {
            _knownTokenSeen[token] = true;
            _knownTokens.push(token);
        }
    }

    function _reject() internal {
        unchecked {
            rejectedActions++;
        }
    }
}
