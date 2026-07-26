# ONCHAIN_SUBACCOUNT_CAPABILITY_CONTROLLER_V1

## Status

**IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL** — 2026-07-26.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-review sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base
mainnet or real user funds. Independent human internal reviewer status
remains `PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit
remains `PENDING_EXTERNAL_REVIEW`.

## Purpose

Freeze the least-privilege engine capability subsystem for the DeOpt V2
hybrid on-chain economic-subaccount architecture. This milestone lands an
abstract Vault-owned component (WP-03) consumed later by
`CollateralVaultV2` and consulted right now by `SubaccountRegistry` for
the lazy Account 1 authorization path.

The abstract owns identity of ONLY three things:

1. `governance` (immutable) — the authority permitted to grant/revoke
   capability bits.
2. `guardian` (mutable, governance-only setter) — the authority permitted
   to defensively revoke an engine.
3. `_engineCapabilityBits[engine]` — the `uint256` bitmap of granted
   capabilities per engine.

No collateral. No balances. No supported-token whitelist. No reservations.
No pause matrix. No admin.

## Vault-owned decision

`CAPABILITY_SUBSYSTEM_IS_VAULT_OWNED`.

Contract-spec 07 explicitly co-locates capability storage with
`CollateralVault`, and spec 15 places `setEngineCapability`,
`engineCapabilityBits`, `isAuthorizedEngine`, and `guardianRevokeEngine`
on the `ICollateralVault` interface. WP-03 therefore implements an
abstract `VaultCapabilityController` intended to be inherited by
`CollateralVaultV2` in WP-04A. It is NOT a standalone production
capability authority; it is a compile-time factor of the future vault.

The current `SubaccountRegistry` (WP-02) already consults this authority
via its immutable `capabilityAuthority` field. In production the
authority will be the deployed vault; in tests it is the harness derived
from `VaultCapabilityController`. The registry ABI is unchanged.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization (2026-07-25) + non-blocking conditions.
2. Tracked designs:
   - `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
   - `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
   - `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`
   - `ONCHAIN_SUBACCOUNT_REGISTRY_V1.md`
   - `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md`
   - `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
   - `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`
   - `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`
3. Detailed contract specifications:
   - `contract-spec/07_ENGINE_CAPABILITIES_SPEC.md`
   - `contract-spec/12_PAUSE_AND_GOVERNANCE.md`
   - `contract-spec/13_EVENTS_AND_RECONSTRUCTION.md`
   - `contract-spec/15_SOLIDITY_INTERFACES.md`
   - `contract-spec/16_ERRORS_AND_EVENTS_CATALOGUE.md`
   - `contract-spec/17_SECURITY_INVARIANT_MAPPING.md`
   - `contract-spec/18_TEST_SPECIFICATION.md`
4. WP-01 canonical libraries (`Capabilities`, `Versions`) and
   `ICollateralVault` interface — MUST NOT be silently altered.
5. WP-02 `SubaccountRegistry` implementation.
6. Implementation-plan package.
7. Repository conventions.

## Files created

```
src/hybrid-v2/vault/
└── VaultCapabilityController.sol            (abstract)

test/hybrid-v2/vault/
├── VaultCapabilityController.t.sol          (49 unit + fuzz)
├── VaultCapabilityControllerInvariant.t.sol (7 CAP-I* invariants)
├── RegistryCapabilityIntegration.t.sol      (8 registry integration)
├── handlers/
│   └── VaultCapabilityControllerHandler.sol
└── harness/
    └── VaultCapabilityControllerHarness.sol
```

No existing source, test, deployment script, backend, frontend, or
database change.

## Interface compatibility

- `ICollateralVault` is unchanged. The abstract implements a subset of
  its capability surface (`setEngineCapability`, `guardianRevokeEngine`,
  `engineCapabilityBits`, `isAuthorizedEngine`). The vault-level
  `setAuthorizedEngine` boolean setter is deliberately DEFERRED — see
  "Deferred: `setAuthorizedEngine`" below.
- `Capabilities` library is unchanged. Bits 0..14 assigned; bits 15..255
  reserved and rejected by the validator.
- `SubaccountRegistry` is unchanged. Its `capabilityAuthority` immutable
  points at whichever concrete inheritor of `VaultCapabilityController`
  is deployed.

## Authority model

| Role | Storage | Rotatable | By whom | Powers |
|---|---|---|---|---|
| `governance` | `immutable` | ❌ | n/a | grant/revoke capability bits; rotate guardian |
| `guardian` | mutable | ✅ | `setGuardian(newGuardian) onlyGovernance` | revoke an engine (full-engine bulk zeroing) |
| engine | `_engineCapabilityBits[engine]` | ❌ (can only be mutated by governance/guardian) | n/a | perform gated economic actions in downstream milestones |

Guardian rotation:

- `setGuardian(address)` is `onlyGovernance`.
- Zero guardian is rejected (`InvalidGuardian`).
- `GuardianChanged(oldGuardian, newGuardian, eventVersion)` is emitted
  on every real change (no-op on identical rotation).
- Initial guardian assignment at construction emits
  `GuardianChanged(address(0), guardian_, eventVersion)`.

Governance is IMMUTABLE. Rotation is intentionally deferred: in
production `governance` is the `ProtocolTimelock`, whose own ownership
rotation is handled by the timelock's own scheduling. Adding a
setGovernance path here would either weaken (mutable authority without
timelock) or duplicate (nested timelock) that mechanism.

## Storage model

```
address public immutable governance;
address internal _guardian;
mapping(address => uint256) internal _engineCapabilityBits;
```

- `isAuthorizedEngine(engine)` is DERIVED (`bits != 0`) per spec 07. No
  separate boolean is stored.
- `_engineCapabilityBits` is the sole capability truth. Every mutation
  goes through one of two paths (`setEngineCapability` or
  `guardianRevokeEngine`). Both validate the engine and both emit the
  add/remove masks. Reserved bits are always rejected by
  `_validateCapabilityMask`.

## Mutation semantics

### `setEngineCapability(engine, mask, allowed)` — governance-only

- Validation:
  - `engine != 0` (`InvalidEngine`).
  - `mask != 0` (`InvalidCapabilityMask`).
  - `mask & ~ALL_CAPABILITIES == 0` (`InvalidCapabilityMask`).
- Compute: `oldBits = _engineCapabilityBits[engine]`;
  `newBits = allowed ? (oldBits | mask) : (oldBits & ~mask)`.
- If `newBits == oldBits` → no-op, no event.
- Else store + emit
  `EngineCapabilityChanged(engine, added, removed, eventVersion)` where:
  - `added = newBits & ~oldBits`  (bits flipped 0 → 1)
  - `removed = oldBits & ~newBits`  (bits flipped 1 → 0)

Adopts spec 07's mask-based OR-in / AND-out semantics. No full-bitmap
replacement mode. Idempotent no-op skips event emission for gas + log
noise; reconstruction still holds because the state was unchanged.

### `guardianRevokeEngine(engine)` — guardian-only

- Validation: `engine != 0` (`InvalidEngine`).
- Zeros `_engineCapabilityBits[engine]`.
- Emits `EngineCapabilityChanged(engine, 0, previousBits, eventVersion)`
  only if `previousBits != 0`.
- ALWAYS emits `EngineGuardianRevoked(engine, guardian, eventVersion)`
  as an audit signal (even when the engine was already at zero bits).
- Cannot grant. Cannot restore. Cannot mutate reservations (proved by
  invariant CAP-I5).

### `setGuardian(newGuardian)` — governance-only

- Validation: `newGuardian != 0` (`InvalidGuardian`).
- No-op if `newGuardian == currentGuardian` (no event).
- Emits `GuardianChanged(oldGuardian, newGuardian, eventVersion)`.

## All-of vs any-of semantics

`hasCapabilities(address engine, uint256 requiredMask)` returns `true`
iff:

1. `requiredMask != 0`, AND
2. `requiredMask & ~ALL_CAPABILITIES == 0` (no reserved bits), AND
3. `(engineCapabilityBits[engine] & requiredMask) == requiredMask` (every
   required bit is present).

This is ALL-OF subset semantics — the recommended check in the milestone
brief. Downstream engines call this directly, or reproduce the formula
inline via `engineCapabilityBits(msg.sender) & cap == cap` per spec 07.

`isAuthorizedEngine(engine)` is a separate "any capability?" gate
(`bits != 0`) matching the frozen `ICollateralVault` single-arg
signature. Downstream code that needs a specific capability MUST use
`hasCapabilities` or `engineCapabilityBits`.

## Guardian behavior summary

- May revoke (`guardianRevokeEngine`) — zeros the target engine's bitmap.
- May NOT grant (`setEngineCapability` reverts `OnlyGovernance` when
  called by the guardian).
- May NOT touch reservations, registry identities, or any other state.
- May NOT rotate itself (`setGuardian` is `onlyGovernance`).
- May not increase authority via any code path (proved by invariants
  CAP-I2 + CAP-I3).

## Event / error model

Events (all carry `Versions.EVENT_VERSION`):

- `EngineCapabilityChanged(address indexed engine, uint256 addedBits, uint256 removedBits, uint16 eventVersion)` — matches `ICollateralVault`.
- `EngineGuardianRevoked(address indexed engine, address indexed guardian, uint16 eventVersion)` — matches `ICollateralVault`.
- `GuardianChanged(address indexed oldGuardian, address indexed newGuardian, uint16 eventVersion)` — new (not on `ICollateralVault` because `setGuardian` is not on that interface either).

Errors:

- `OnlyGovernance()` — caller is not the immutable `governance` address.
- `OnlyGuardian()` — caller is not the currently configured `_guardian`.
- `InvalidEngine()` — engine argument is `address(0)`.
- `InvalidCapabilityMask(uint256 mask)` — empty mask OR mask references reserved bit(s).
- `InvalidGovernance()` — constructor received `address(0)` governance.
- `InvalidGuardian()` — guardian is `address(0)` at construction or rotation.
- `MissingCapability(uint256 requiredBits, address caller)` — mirrors `ICollateralVault.MissingCapability`; not emitted by this abstract itself but provided for inheritors that gate economic paths via `_requireCapability`.

No duplicated interface errors with incompatible selectors. All errors
are declared once on the abstract.

## Registry integration

The abstract has been validated end-to-end against the real
`SubaccountRegistry` via `RegistryCapabilityIntegration.t.sol`:

- Engine without `CAP_REGISTER_DEFAULT_ACCOUNT` → `NotAuthorized`.
- Governance grants → engine can lazy-register Account 1.
- Second call is idempotent (no event, no state change).
- Guardian revokes → engine cannot lazy-register for a new owner.
- Governance re-grants → engine can lazy-register again.
- Unrelated capability bits do NOT authorize the registry action.
- Guardian cannot self-grant `CAP_REGISTER_DEFAULT_ACCOUNT`.
- Engine cannot self-grant.
- Multi-bit grants do not break single-bit authorization.
- Registered accounts are inert w.r.t. capability mutations
  (survive guardian revoke, survive re-grant, etc.).
- Owner `registerNext()` path is independent of capabilities.

## Outstanding-reservation behavior

Guardian revocation intentionally does NOT release reservations. In
production this couples with `CollateralVaultV2` (WP-04B) which owns:

- `lockedByEngine[subKey][token][engine]` per-engine reservations;
- `applyLock` / `applyUnlock` (both capability-gated);
- `governanceReleaseOrphanedLock` (timelocked release of frozen
  reservations after an engine revocation).

The abstract in WP-03 owns none of these. Invariant CAP-I5 asserts a
harness-level "reservation counter" is never mutated by any code path
under fuzz. Production reservation accounting arrives in WP-04B.

## Deferred: `setAuthorizedEngine`

The `ICollateralVault` interface also declares
`setAuthorizedEngine(address engine, bool allowed) external;`. Spec 07
makes `isAuthorizedEngine` a DERIVED read (`bits != 0`), leaving no
clean semantics for an independent boolean setter (and creating a risk
of two setters with overlapping intent). Resolution is deferred to
`ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-A` so the semantic tie to
supported-token whitelist / vault initialization can be reconciled in
one place. This abstract implements only the two capability-mutation
entrypoints frozen by spec 07.

## Deployment order dependency

Recorded and forwarded — unchanged from the registry milestone:

- `SubaccountRegistry` needs the future Vault address at construction
  (its `capabilityAuthority` immutable).
- `CollateralVaultV2` will need the `SubaccountRegistry` address at
  construction (for `existsOf` checks in `deposit`).
- Neither uses a mutable post-deployment authority setter.

Deployment plans (owned by `ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-MANIFEST-V1`
and `ONCHAIN-SUBACCOUNT-BASE-SEPOLIA-DRY-RUN-V1`) MUST resolve the cycle
via CREATE2 salt prediction, deterministic-nonce prediction, or a
single-transaction factory. This capability milestone does not implement
deployment scripts and does not alter registry immutability.

## Governance/timelock integration note

- `governance` is the sole grant/revoke authority. In production it is
  the deployed `ProtocolTimelock`.
- The abstract does not implement its own timelock queue — that's owned
  by `ProtocolTimelock`.
- The abstract does not verify at construction that the supplied
  governance address IS the timelock. This is a deployment-integration
  concern to be validated in the base-sepolia dry-run milestone.

## Gas / DoS posture (development-run, non-normative)

- `engineCapabilityBits` view: cold ~9k / warm sub-3k.
- `isAuthorizedEngine` view: cold ~9k.
- `hasCapabilities` view: cold ~7k.
- `setEngineCapability` one-bit grant: ~39k gas.
- `setEngineCapability` all-bits grant: ~35k gas.
- `setEngineCapability` no-op: ~37k gas (SLOAD + branch).
- `guardianRevokeEngine`: ~31k gas.
- `setGuardian`: ~19k gas.
- Registry lazy-registration full path: one bounded view (SLOAD on
  authority + one `engineCapabilityBits` call).

Structural properties:

- Every mutation is O(1). No iteration over engines. No iteration over
  bits (all-of check is single bitwise op).
- No external calls in any mutation path.
- Caller pays gas.

## Invariant coverage

- **CAP-I1** Every stored bitmap is a subset of `ALL_CAPABILITIES`
  (reserved bits are never stored).
- **CAP-I2** Non-governance callers never increase any engine's bitmap.
- **CAP-I3** Guardian never increases any bitmap.
- **CAP-I4** Engine never modifies its own bitmap.
- **CAP-I5** Guardian revocation does not touch registry identities or
  the harness reservation counter.
- **CAP-I6** `hasCapabilities` is exactly all-of subset semantics.
- **CAP-I7** Event-derived bitmap reconstruction equals storage bitmap.
- **CAP-I8** An engine without `CAP_REGISTER_DEFAULT_ACCOUNT` cannot
  lazy-register a fresh owner via the real registry.

Each invariant is exercised by a bounded handler with ~4096 calls per
run (64 runs × 64 depth via inline `forge-config`).

## Non-goals (owned by later milestones)

- Vault deposits, withdrawals, internal transfers, yield adapters.
- Supported-token whitelist.
- Per-engine reservation accounting (`applyLock` / `applyUnlock`).
- `governanceReleaseOrphanedLock`.
- Fee / rebate / liquidation / settlement debits.
- Pause matrix flags.
- RiskModule integration.
- Positions ledgers.
- Signature / replay / recovery.
- Deployment scripts.

## Downstream dependencies

Direct consumer: WP-04A
(`ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-A`) — inherits this abstract as
part of `CollateralVaultV2`.

Indirect consumers:

- WP-04B — reservation accounting + `governanceReleaseOrphanedLock`.
- WP-06 / WP-07 — options + perps ledgers (capability-gated mutations).
- WP-08 / WP-09 — matching engines.

Existing consumer: WP-02 `SubaccountRegistry` already relies on this
authority for `registerLazyDefault` (validated in
`RegistryCapabilityIntegration.t.sol`).

## Repository state at milestone close

- `deopt-v2-sol` moves from `cdfb3db` to the milestone-close head
  listed in `~/DEOPT/docs/ONCHAIN_SUBACCOUNT_CAPABILITY_CONTROLLER_V1_RESULT.md`.
- Full suite: 39 suites, 543 tests, 0 failed (baseline was 36/479).
  Delta: +3 suites, +64 tests.
- Focused capability + integration + invariants: 64 tests.
- `deopt-v2-backend` untouched. `deopt-v2-frontend` untouched.

No audit sign-off. No security-review sign-off. No deployment approval.
