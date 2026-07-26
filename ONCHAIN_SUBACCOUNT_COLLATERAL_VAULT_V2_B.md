# ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_B

## Status

**IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL** — 2026-07-26.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-review sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base
mainnet or real user funds. Internal reviewer:
`PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit:
`PENDING_EXTERNAL_REVIEW`.

## Purpose

Extend `CollateralVaultV2Core` (WP-04A) with the second half of the
canonical Vault accounting model (WP-04B):

- aggregate locked collateral + per-engine reservation storage;
- capability-gated `applyLock` / `applyUnlock`;
- owner-direct `withdraw` with abstract risk hook;
- same-owner `internalTransfer` with abstract risk hook;
- deposit / withdrawal / internal-transfer pause matrix;
- governance-timelocked `governanceReleaseOrphanedLock`;
- reserved storage slot for future escape-controller integration.

Every un-implemented `ICollateralVault` function is deferred to its
approved owner milestone; the production Vault remains **abstract**.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization (2026-07-25) + non-blocking conditions.
2. Tracked designs (WP-01 through WP-04A milestone docs +
   architecture / contract-spec / plan / escape-hatch /
   chain-reconstruction / migration).
3. Detailed contract specs 03, 06, 07, 08, 10, 11, 12, 13, 14, 15, 16,
   17, 18, 21.
4. Frozen WP-01 ABI (post-`setAuthorizedEngine` removal).
5. Validated WP-02 (registry), WP-03 (capability), WP-04A (custody).
6. Implementation-plan package.
7. Repository conventions.

## Files created

```
src/hybrid-v2/vault/
└── CollateralVaultV2.sol                     (abstract; V2-B extension)

test/hybrid-v2/vault/
├── CollateralVaultV2.t.sol                    (41 unit + fuzz)
├── CollateralVaultV2Invariant.t.sol           (14 VAULT-B-I* invariants)
├── handlers/CollateralVaultV2Handler.sol      (bounded fuzz handler)
└── harness/CollateralVaultV2Harness.sol       (concrete test harness with
                                                 configurable risk hooks)
```

Files modified (WP-04A minimal refactor to enable clean override):

- `src/hybrid-v2/vault/CollateralVaultV2Core.sol` — added `virtual` to
  `deposit` + `depositFor`; factored bodies into internal
  `_executeDeposit` + `_executeDepositFor` so V2-B can override the
  external functions with additional modifiers without a super-call
  colliding with the parent's reentrancy guard. Behavior unchanged.

## Scope audit result (Part C)

**Verdict:** `VAULT_V2_B_SCOPE_RESOLVED`.

| Function | Owner | Implemented in V2-B? | Reason |
|---|---|:-:|---|
| `deposit` | WP-04A | already | Pause modifier added in V2-B override |
| `depositFor` | WP-04A | already | Pause modifier added in V2-B override |
| `applyLock` | WP-04B | ✅ | Capability-gated reservation primitive |
| `applyUnlock` | WP-04B | ✅ | Capability-gated own-reservation release |
| `withdraw` (owner) | WP-04B | ✅ | Owner-direct + abstract risk hook |
| `internalTransfer` (owner) | WP-04B | ✅ | Same-owner + abstract risk hook |
| `governanceReleaseOrphanedLock` | WP-04B | ✅ | Governance-only; engine bits == 0 |
| `pauseDeposits/Withdrawals/InternalTransfers` | WP-04B | ✅ | Guardian-or-governance pause + governance-only unpause |
| `pauseYieldOps` | WP-later | ❌ | No yield adapter integration yet |
| `withdrawFor` | WP-08 | ❌ | Depends on relayed-authorization path (matching engine) |
| `creditCollateral` | WP-08 | ❌ | Requires clear source/context (matching + margin engine) |
| `applyFeeDebit` | WP-09 | ❌ | Depends on FeesManager + protocolFeeVaultSubKey |
| `applyRebateCredit` | WP-09 | ❌ | Depends on FeesManager |
| `applyLiquidationDebit` | WP-08 | ❌ | Depends on positions ledger + insurance fund |
| `applySettlementCreditDebit` | WP-08 | ❌ | Depends on options settlement engine |
| `protocolFeeVaultSubKey`, `insuranceFundSubKey` | WP-09 / WP-08 | ❌ | Well-known subKeys require fee vault + insurance wiring |
| Yield adapter (`moveToStrategy` etc.) | WP-later | ❌ | Orthogonal integration; unchanged interface from V1 |
| Recovery reservation | WP-10 | ❌ | Owned by escape controller |

The concrete `is ICollateralVault` implementation therefore lives in a
later milestone; V2-B remains abstract by design.

## Implementation form

`abstract contract CollateralVaultV2 is CollateralVaultV2Core`. Does NOT
declare `is ICollateralVault`. Test-only concrete
`CollateralVaultV2Harness` provides configurable risk hooks (allow /
reject globally + per-`(subKey, token)`) for tests.

## Reservation storage

```
mapping(bytes32 => mapping(address => uint256)) internal _totalLocked;
mapping(bytes32 => mapping(address => mapping(address => uint256))) internal _lockedByEngine;
```

- Aggregate and per-engine kept in lockstep by every mutation path.
- No global engine enumeration required.
- Storage names + shape match spec 03 verbatim.

## Capability mapping

- `applyLock` requires `Capabilities.CAP_LOCK_COLLATERAL`.
- `applyUnlock` requires `Capabilities.CAP_UNLOCK_OWN_RESERVATION`.
- `governanceReleaseOrphanedLock` requires `msg.sender == governance`
  AND target engine bits == 0.
- Pauses require guardian OR governance; unpauses require governance.

## Lock / unlock / consume semantics

**`applyLock(subKey, token, amount)`:**

- Capability: `CAP_LOCK_COLLATERAL`.
- Reverts on zero subKey, zero amount, or `available < amount`.
- Increments `_lockedByEngine[subKey][token][msg.sender]` AND
  `_totalLocked[subKey][token]` by `amount`. Balance unchanged.
- Emits `CollateralLocked(subKey, token, engine, amount, eventVersion)`.

**`applyUnlock(subKey, token, amount)`:**

- Capability: `CAP_UNLOCK_OWN_RESERVATION`.
- Reverts on zero subKey / zero amount / caller reservation < amount.
- Decrements caller's OWN reservation AND aggregate `_totalLocked`.
- CANNOT touch another engine's reservation
  (`InsufficientEngineReservation(requested, reserved=0)` reverts).
- Emits `CollateralUnlocked(subKey, token, engine, amount, eventVersion)`.

**Consume (specialized fee/rebate/liquidation/settlement/withdrawFor):**

DEFERRED. Each specialized consume has a distinct destination (fee
subKey, insurance subKey, external receiver, signed settlement delta)
that depends on downstream milestones (WP-08 engines, WP-09 fees). V2-B
introduces NO broad "arbitrary consume" primitive. This satisfies
Part O's requirement not to add unrestricted engine-callable debits.

## Available-balance model

```
availableOf(subKey, token) = balanceOf(subKey, token) - lockedOf(subKey, token)
```

- Reverts `CorruptedLockInvariant(subKey, token)` if `locked > balance`
  (structural integrity — never silently underflow).
- O(1). No iteration.

## Withdrawal boundary

Owner-only direct withdrawal implemented:

- `msg.sender == owner`; requires `existsOf(owner, subaccountId)`.
- `amount <= availableOf(subKey, token)`.
- Abstract risk hook `_requireWithdrawalAllowed(subKey, token, amount)`
  MUST NOT be permissively defaulted in production. Test harness
  provides configurable allow / reject.
- Decrements balance + `_totalAccounted` BEFORE `SafeERC20.safeTransfer`
  (CEI order).
- Validates exact outbound delta: `physicalBefore - physicalAfter == amount`.
  Rejects fee-on-transfer on outbound.
- `nonReentrant` + `whenWithdrawalsNotPaused`.
- Token disablement DOES NOT block withdrawal (Part L).

**Verdict:** `RISK_BOUNDARY_ABSTRACT_PENDING_WP_07`. Production
concrete vault cannot be deployed until WP-07 wires a real `IRiskModule`
and overrides `_requireWithdrawalAllowed`.

## Internal-transfer semantics

Same-owner only:

- `msg.sender == owner`; both accounts must be registered for the
  caller. Destination lazy-registers ONLY when `toSubaccountId == 1`
  (spec 10). `fromSubaccountId != toSubaccountId`.
- Token MUST be currently enabled (spec 10 — stricter than withdrawal).
- `amount <= available` on source.
- Abstract risk hook `_requireInternalTransferAllowed(fromSubKey, token, amount)`.
- Atomic debit + credit. `_totalAccounted` UNCHANGED. Physical custody
  UNCHANGED. Reservations on both sides UNCHANGED.
- `nonReentrant` + `whenInternalTransfersNotPaused`.

## Risk-boundary verdict

`RISK_BOUNDARY_ABSTRACT_PENDING_WP_07`.

- Production `CollateralVaultV2` is `abstract` — the two risk hooks are
  pure `virtual`.
- No always-true production hook. No permissive default.
- Test harness overrides with configurable behavior (default allow,
  toggleable to reject globally or per-`(subKey, token)`).
- WP-07 `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-V1` will wire an immutable
  `IRiskModule` reference and override the hooks to call
  `riskModule.withdrawalAllowed` and `riskModule.transferAllowed`.

## Pause model

Owned by V2-B:

| Flag | Pause caller | Unpause caller |
|---|---|---|
| `_depositsPaused` | guardian OR governance | governance |
| `_withdrawalsPaused` | guardian OR governance | governance |
| `_internalTransfersPaused` | guardian OR governance | governance |

Rules:

- Guardian CANNOT unpause (matches spec 12).
- Pause + unpause emit `PauseFlagChanged(flag, paused, by, eventVersion)`.
- Idempotent (no event when state is unchanged).
- Pause cannot rewrite accounting (proved by VAULT-B-I12).
- Pause never silently releases reservations.
- Views remain available under any pause.

Deferred pauses: `pauseYieldOps` (no yield adapter integration in
V2-B). `withdrawPauseAutoClearBlock` is a `uint64 public` reserved
storage slot; V2-B DOES NOT write it. WP-10 escape controller plugs
into it for time-based auto-clear.

## Orphaned-lock conclusion

**Verdict:** `ORPHANED_LOCK_RELEASE_IMPLEMENTED_SAFELY`.

`governanceReleaseOrphanedLock(subKey, token, engine, amount, reason)`:

- Governance-only.
- Reverts `EngineStillAuthorized(engine)` if `engineCapabilityBits(engine) != 0`.
- Reverts `InsufficientEngineReservation(amount, reserved)` on over-release.
- Decrements the per-engine reservation and the aggregate `_totalLocked`.
- No token transfer. No third-party recipient. Released amount becomes
  `available` again for the same subaccount.
- Emits `OrphanedLockReleased(subKey, token, engine, amount, reason, eventVersion)`.

Governance timelock delay (external, held by `ProtocolTimelock`) is the
safeguard against premature release; the on-chain check ensures the
engine has been fully revoked.

## Deferred fee / rebate / settlement / recovery hooks

- `applyFeeDebit`, `applyRebateCredit`, `applyLiquidationDebit`,
  `applySettlementCreditDebit`, `withdrawFor`, `creditCollateral` →
  WP-08 + WP-09.
- `protocolFeeVaultSubKey`, `insuranceFundSubKey` → WP-08 / WP-09
  (requires FeesManager + InsuranceFund wiring).
- Recovery reservation + escape flags → WP-10.

Each deferral is explicitly documented in the tracked doc and validated
by the scope audit above.

## Events

- `CollateralLocked(subKey, token, engine, amount, eventVersion)`.
- `CollateralUnlocked(subKey, token, engine, amount, eventVersion)`.
- `Withdraw(subKey, owner, subaccountId, token, amount, receiver, eventVersion)`.
- `InternalTransfer(fromSubKey, toSubKey, token, amount, owner, fromSubaccountId, toSubaccountId, eventVersion)`.
- `OrphanedLockReleased(subKey, token, engine, amount, reason, eventVersion)`.
- `PauseFlagChanged(flag, paused, by, eventVersion)`.

All carry `Versions.EVENT_VERSION`. No hash-only events.

## Errors

Contract-local on `CollateralVaultV2`:

- `OnlyGuardianOrGovernance()`.
- `InsufficientAvailableCollateral(uint256 requested, uint256 available)`.
- `InsufficientEngineReservation(uint256 requested, uint256 reserved)`.
- `UnsafeWithdrawal()` (thrown by concrete risk hook).
- `UnsafeTransfer()` (thrown by concrete risk hook).
- `InternalTransferSameSubaccount()`.
- `InternalTransferCrossOwner()` (reserved for future delegate variant).
- `PausedOperation(bytes32 flag)`.
- `SubKeyRequired()`.
- `CorruptedLockInvariant(bytes32 subKey, address token)` — MUST-NOT-HAPPEN guard.
- `EngineStillAuthorized(address engine)`.

Inherited from V2-A / capability layer: `AmountZero`, `InvalidOwner`,
`InvalidToken`, `InvalidSubaccountId`, `SubaccountNotFound`,
`TokenNotSupported`, `InvalidTokenBalanceDelta(requested, credited)`,
`MissingCapability(requiredBits, caller)`, `OnlyGovernance`,
`OnlyGuardian`, `InvalidEngine`.

## Storage review

New V2-B storage:

- `mapping(bytes32 => mapping(address => uint256)) _totalLocked`.
- `mapping(bytes32 => mapping(address => mapping(address => uint256))) _lockedByEngine`.
- `bool _depositsPaused`, `_withdrawalsPaused`, `_internalTransfersPaused`.
- `uint64 public withdrawPauseAutoClearBlock` (RESERVED for WP-10; never
  written by V2-B).

Inherited from V2-A / capability layer:

- `_tokenEnabled`, `_balanceOf`, `_totalAccounted` (V2-A).
- `_guardian`, `_engineCapabilityBits` (V2-C-C).
- `_status` (`ReentrancyGuard`).

Immutables: `REGISTRY` (V2-A), `governance` (V2-C-C).

Storage safety:

- V2-A balances / liabilities unchanged.
- Capability storage inherited exactly once via the linear inheritance
  chain `V2-C-C ← V2-A ← V2-B`.
- Reservation state appended once at V2-B.
- No pause-field overlap.
- No duplicated Registry / governance / guardian.
- No address-keyed legacy balance state.
- No recovery / debt / bad-debt fields prematurely invented.
- Future WP-07 (RiskModule reference immutable) + WP-10 (escape
  controller state) can append cleanly.

## Tests

- 41 unit + fuzz (`CollateralVaultV2.t.sol`):
  locks (exact, above-available, multi-engine, missing-cap, zero-subKey,
  zero-amount); unlocks (partial, full, excessive, cross-engine,
  missing-cap); guardian revoke preserves reservation; orphaned-release
  (happy, engine-still-authorized, non-gov, excessive); withdrawals
  (owner happy, locked-not-withdrawable, risk-reject, per-subKey veto,
  unknown-account, zero-amount, disabled-token-still-allows-exit,
  pause + governance-unpause); internal transfers (Account 1 → 2, lazy
  destination Account 1, same-account, cross-owner-impossible,
  locked-not-transferable, risk-reject, disabled-token-reverts, pause,
  locks-unchanged-on-both-sides); pauses (deposits/withdrawals/transfers
  guardian-or-governance, governance-only-unpause, idempotent,
  attacker-cannot); reentrancy blocked on withdraw path;
  fuzz(lockUnlockRoundTrip, withdrawRespectsLocks).
- 14 VAULT-B-I* invariants (bounded handler, ~4096 calls each via
  inline `forge-config: 64 runs × 64 depth`, ~6.85s wall clock).

## Gas / DoS posture (development-run, non-normative)

- `applyLock`: ~74k first, ~52k warm.
- `applyUnlock`: ~30k.
- `withdraw`: ~90k (including SafeERC20 outbound).
- `internalTransfer`: ~65k.
- `governanceReleaseOrphanedLock`: ~28k.
- `pauseX / unpauseX`: ~20k.
- Views: 2–5k.

Structural: every mutation O(1). No engine / token / subaccount
iteration. Malicious tokens cannot force unbounded work.

## Non-goals (owned by later milestones)

- `withdrawFor`, `creditCollateral`, `applyFeeDebit`,
  `applyRebateCredit`, `applyLiquidationDebit`,
  `applySettlementCreditDebit` (WP-08 / WP-09).
- `protocolFeeVaultSubKey`, `insuranceFundSubKey`.
- Yield adapter integration.
- Real `IRiskModule` wiring (WP-07).
- Recovery reservations (WP-10).
- EIP-712 + replay (WP-05).
- Positions / margin math / matching (WP-06 / WP-08).

## Downstream dependencies

- **WP-05 (Replay + epoch)** — orthogonal foundation for engines.
- **WP-07 (RiskModule V2)** — finalizes the risk boundary; provides the
  concrete override of `_requireWithdrawalAllowed` and
  `_requireInternalTransferAllowed`; wires an immutable `IRiskModule`
  reference into a concrete `CollateralVaultV2` production contract.
- **WP-08 / WP-09** — matching engines, margin engine, fees manager —
  each will add their own specialized capability-gated debit/credit
  primitives on top of the V2-B foundation.
- **WP-10 (Escape controller)** — writes `withdrawPauseAutoClearBlock`
  + adds recovery-side reservations.

## Repository state at milestone close

- `deopt-v2-sol` moves from `144a443` to the milestone-close head
  recorded in
  `~/DEOPT/docs/ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_B_RESULT.md`.
- Full suite: 44 suites, 662 tests, 0 failed (baseline was 42/607).
  Delta: +2 suites, +55 tests.
- `deopt-v2-backend` untouched. `deopt-v2-frontend` untouched.

No audit sign-off. No security-review sign-off. No deployment approval.
