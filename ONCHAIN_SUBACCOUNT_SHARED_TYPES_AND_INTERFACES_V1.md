# ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1

## Status

**IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL** — 2026-07-25.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-review sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base
mainnet or real user funds. Independent human internal reviewer status
remains `PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit
remains `PENDING_EXTERNAL_REVIEW`.

## Purpose

Freeze the shared type + library + interface foundation for the DeOpt V2
hybrid on-chain economic-subaccount architecture. This milestone lands
compile-only ABI headers that downstream implementation milestones
(WP-02 through WP-10) will consume verbatim.

No contract in this milestone owns or mutates economic state.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization (2026-07-25) + its non-blocking
   conditions.
2. Tracked designs in `deopt-v2-sol/`:
   - `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
   - `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
   - `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
   - `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`
   - `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`
   - `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md`
3. Detailed contract specification — especially
   `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/15_SOLIDITY_INTERFACES.md`.
4. Detailed escape-hatch interface specification —
   `~/DEOPT/docs/onchain-subaccounts-v1/escape-hatch/15_SOLIDITY_INTERFACE_SPEC.md`.
5. Detailed experimental-implementation-plan package.
6. Current repository conventions (`^0.8.20` pragma target for
   consumer-facing files; BSL-1.1 license; `@openzeppelin/contracts`
   remapping; NatSpec-heavy comments).

Any conflict is resolved by the higher-precedence source. Where
guidance is silent, this milestone documents the choice explicitly
below rather than inventing behavior.

## Source directory convention

New code lives under `src/hybrid-v2/` and `test/hybrid-v2/`. Legacy
source paths are untouched.

```
src/hybrid-v2/
├── libraries/
│   ├── SubKey.sol            — canonical subKey derivation
│   ├── Capabilities.sol      — CAP_* least-privilege constants (14 bits + 1 recovery)
│   ├── Versions.sol          — EVENT_VERSION + ARCHITECTURE_VERSION constants
│   ├── PositionTypes.sol     — OptionPosition + PerpPosition + LiquidationStatus
│   └── RecoveryTypes.sol     — RecoveryState + RecoveryScope + FinalizationStatus + FallbackSource
└── interfaces/
    ├── ISubaccountRegistry.sol
    ├── ICollateralVault.sol
    ├── IOptionsPositionsLedger.sol
    ├── IPerpsPositionsLedger.sol
    ├── IRiskModule.sol
    ├── IReplayProtected.sol
    ├── IEscapeController.sol
    ├── IRecoveryFinalizer.sol
    ├── IFallbackOracle.sol
    └── IRecoveryView.sol

test/hybrid-v2/
├── libraries/
│   ├── SubKey.t.sol
│   ├── Capabilities.t.sol
│   └── Versions.t.sol
└── interfaces/
    └── InterfacesCompile.t.sol
```

Naming decisions:

- Chosen path separator convention: `hybrid-v2` (hyphenated). Rationale:
  matches file plan `05_REPOSITORY_FILE_PLAN.md`, keeps grep + linter
  filtering unambiguous, and is consistent across all three
  repositories per D-IMP-03.
- All new interfaces prefixed `I`; all new libraries are `library`
  contracts.
- All Solidity files carry the `hybrid-v2` path segment so any legacy
  grep tooling can exclude the new tree by pattern.

## Solidity pragma + license

- License identifier: `BSL-1.1` (matches existing repo).
- Solidity pragma: `^0.8.20` (matches existing consumer-facing
  contracts; foundry.toml pins `solc_version = "0.8.30"` and
  `via_ir = true` so all new files compile under 0.8.30 while remaining
  consumer-compatible with 0.8.20+).
- No compiler upgrade proposed in this milestone.

## Canonical shared types

### Subaccount identity

- `address owner` — canonical owner. May be an EOA or a smart-wallet
  contract address per INV-ID-06. Zero address is invalid.
- `uint32 subaccountId` — monotonic per-owner id. `0` reserved and
  invalid for user operations. `1` is the lazy default account
  (D-03).
- `bytes32 subKey` — deployment-scoped internal key. Derivation is
  the single source of truth in `src/hybrid-v2/libraries/SubKey.sol`
  (see below).

**Type policy:** these are plain Solidity primitive types. No
user-defined value types (UDVT) are introduced in this milestone. UDVTs
would complicate ABI decoding at the backend + frontend layers and add
no type-safety benefit that plain primitives don't already provide when
paired with named parameters + interface signatures. This decision is
recorded as `D-STI-01 FROZEN`; a downstream milestone MAY revisit if
concrete evidence of collision emerges.

### Position types

Directly transcribed from `contract-spec/15_SOLIDITY_INTERFACES.md`:

```solidity
struct OptionPosition {
    uint128 longQuantity1e8;
    uint128 shortQuantity1e8;
    uint128 premiumBasis1e8;
    uint128 shortPremiumRecv1e8;
    uint64  lastFillBlock;
    uint8   settlementState;      // 0 unsettled | 1 partially | 2 fully
    uint8   exerciseState;        // 0 unexercised | 1 partially | 2 fully
}

struct PerpPosition {
    int128  sizeSigned1e8;
    int128  costBasisSigned1e18;
    int128  fundingSnapshotSigned1e18;
    int128  realizedPnl1e18;
    uint64  lastMutationBlock;
    uint8   liquidationState;
}

enum LiquidationStatus { HEALTHY, WARN, ELIGIBLE_FOR_LIQUIDATION }
```

`PositionTypes.sol` owns both structs + the enum. Interfaces import
symbols from that library.

### Recovery types

Directly transcribed from
`escape-hatch/15_SOLIDITY_INTERFACE_SPEC.md`:

```solidity
enum RecoveryState {
    NORMAL,
    RECOVERY_PENDING,
    RECOVERY_ACTIVE,
    SETTLEMENT_PENDING,
    WITHDRAWAL_ELIGIBLE,
    RECOVERED,
    CANCELLED,
    MIGRATED
}
enum RecoveryScope { SUBACCOUNT, OWNER }
enum FinalizationStatus { NONE, REQUESTED, DISPUTED, FINALIZED }
enum FallbackSource {
    PRIMARY,            // F-A
    FALLBACK_ORACLE,    // F-B
    HISTORICAL_TWAP,    // F-C
    GOVERNANCE_BOUNDED  // F-D
}
```

`RecoveryTypes.sol` owns these enums.

## Canonical subKey derivation

The single canonical implementation lives in
`src/hybrid-v2/libraries/SubKey.sol`.

Formula (from contract-spec 02 + spec 15):

```solidity
subKey = keccak256(abi.encode(
    block.chainid,       // uint256
    registryAddress,     // address (SubaccountRegistry deployment address)
    owner,               // address
    subaccountId         // uint32
));
```

Requirements enforced by the library and its tests:

- Uses `abi.encode`, NEVER `abi.encodePacked` (avoids ambiguous
  concatenation collisions).
- Field order is fixed: chainId, registry, owner, subaccountId.
- Explicit-chain form `derive(uint256 chainId, address registry,
  address owner, uint32 subaccountId)` exposes deterministic
  derivation for tests + off-chain reproducibility.
- Current-chain form `deriveHere(address registry, address owner,
  uint32 subaccountId)` consumes `block.chainid`.
- No `owner == address(0)` or `subaccountId == 0` filtering in the
  library — the registry contract enforces those invariants and the
  library remains a pure helper.
- No architecture-version or deployment-version bytes injected into
  the hash. Domain separation for signatures lives in EIP-712 domain
  fields, not in subKey derivation (per spec 08 + INV-ID-02).

## Account 0 and Account 1 constants

- `SUBACCOUNT_ID_INVALID = uint32(0)` — reserved.
- `SUBACCOUNT_ID_DEFAULT = uint32(1)` — lazy default per D-03.

These live in `Versions.sol` alongside version constants for
convenience (they are consumed together by tests + downstream
implementations).

## Version representations

Four separate version families are recognised by the approved specs, each
identifying a distinct concept:

| Family | Solidity type | Purpose | Source |
|---|---|---|---|
| `EVENT_VERSION` | `uint16` | Event-schema version emitted in every subaccount-scoped event | contract-spec 13 |
| `ARCHITECTURE_VERSION` | `uint256` | Protocol architecture / schema family; bound in EIP-712 payloads | contract-spec 08 + INV-MIG-07 |
| `STORAGE_VERSION` | `uint16` | Storage / schema compatibility for replaceable modules; exposed via `IRiskModule.supportsCanonicalStorageVersion(uint16)` | contract-spec 06 |
| `deploymentVersion` | `uint256` (per-deployment immutable) | Per-deployment monotonic identifier; not a global constant | migration-design 10 + 15 + 16 + D-MIG-25 |

All three GLOBAL constants live in `Versions.sol`:

- `EVENT_VERSION = uint16(1)`.
- `ARCHITECTURE_VERSION = uint256(1)`.
- `STORAGE_VERSION = uint16(1)`.

`deploymentVersion` is per-deployment monotonic (D-MIG-25 FROZEN: "V2
deployment version bumped to `deploymentVersion = 2` (or operator's next
monotonic value)"). It is therefore NOT a compile-time global constant.
Instead the canonical Solidity type is documented as `uint256` (matches
migration event ABI `deploymentVersion: uint256` in
`migration-design/10_EVENTS_AND_MANIFESTS.md`). Downstream contracts
(WP-02 registry, WP-04 vault, WP-08 engines, etc.) supply the value at
deployment time via constructor `immutable`. `Versions.sol` exports
`INITIAL_DEPLOYMENT_VERSION = uint256(1)` as the sentinel value for a
first-ever fresh deployment and to pin the underlying type at compile
time.

`deploymentVersion` MUST NOT be embedded inside `subKey` derivation
(spec 02). Cross-deployment domain separation is achieved via:

1. `verifyingContract` in EIP-712 domain fields (spec 08); and
2. The deployment-scoped registry address encoded into `subKey` (spec 02).

`STORAGE_VERSION` and `deploymentVersion` are NOT equivalent:
`STORAGE_VERSION` describes a replaceable module's on-chain storage
layout compatibility (bumps on module storage refactors under the same
deployment); `deploymentVersion` describes the per-deployment namespace
(bumps on every deployment cutover regardless of module storage changes).

## Capability representation

Capabilities are represented as bit positions on a `uint256` bitmap.
The `ICollateralVault.setEngineCapability(engine, bits, allowed)`
admin function grants or revokes a mask.

`Capabilities.sol` owns the 14 named `CAP_*` constants from spec 07
plus `CAP_RECOVERY_ACTIVATE` (bit 14) from escape-hatch spec 15's
capability addition.

Bit layout (all values must be unique):

```
bit 0  — CAP_REGISTER_DEFAULT_ACCOUNT
bit 1  — CAP_CREDIT_COLLATERAL
bit 2  — CAP_WITHDRAW_FOR
bit 3  — CAP_LOCK_COLLATERAL
bit 4  — CAP_UNLOCK_OWN_RESERVATION
bit 5  — CAP_APPLY_OPTIONS_POSITION_DELTA
bit 6  — CAP_APPLY_PERP_POSITION_DELTA
bit 7  — CAP_APPLY_FEE
bit 8  — CAP_APPLY_REBATE
bit 9  — CAP_SETTLE_OPTION
bit 10 — CAP_LIQUIDATE_OPTIONS
bit 11 — CAP_LIQUIDATE_PERPS
bit 12 — CAP_EXECUTE_INTERNAL_TRANSFER
bit 13 — CAP_CONSUME_REPLAY_NONCE
bit 14 — CAP_RECOVERY_ACTIVATE (from escape-hatch/15)
bits 15..255 — RESERVED for future capabilities
```

A separate `ICapabilityController` interface is NOT introduced in this
milestone. Rationale: spec 07 and spec 15 both place the capability
model INSIDE `ICollateralVault` (`setEngineCapability` +
`engineCapabilityBits` + `isAuthorizedEngine` + `guardianRevokeEngine`
+ `governanceReleaseOrphanedLock`).

**Capability-controller ownership verdict:**
`CAPABILITY_CONTROLLER_IS_VAULT_OWNED`. Contract-spec 07 + spec 15 place
the capability grant/revoke/query surface as functions ON
`ICollateralVault`. Capability governance is therefore not a separate
canonical contract; it is an integrated subsystem of the vault. The
plan file names (`ONCHAIN-SUBACCOUNT-CAPABILITY-CONTROLLER-V1`,
`src/registry/CapabilityController.sol` in the file plan, `WP-03` in
work packages) refer to the SUB-MILESTONE that implements the vault's
capability subsystem BEFORE the wider vault accounting milestones
(WP-04A/B). That sub-milestone lands the capability storage + grant/
revoke behavior on the vault contract with its own commit boundary; it
does NOT deploy a separate `CapabilityController` contract, and no
separate `ICapabilityController` interface exists.

The plan doc rollout under
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/`
retains the WP-03 milestone name for continuity with prior decisions
and cross-references; downstream planning refresh will clarify inline
that WP-03 implements the vault-owned capability subsystem. No
interface file is required from WP-01. Recorded as `D-STI-02 FROZEN`
(see decision register at end).

## ABI encoding policy

- All shared struct + enum encodings follow the natural Solidity ABI
  (equivalent to `abi.encode`). No packed layouts.
- Event schemas match spec 13 verbatim, with `eventVersion` as the
  last unindexed parameter. Indexed parameters are as specified.
- Errors are `custom errors` (no `require(cond, string)`).

## EIP-712 compatibility constraints

- The engine milestones (WP-08, future perps) build EIP-712 domain +
  message types.
- This milestone does NOT introduce a shared EIP-712 domain builder
  library. Rationale: spec 08 mandates per-engine domain names
  (`DeOptV2-OptionMatchingEngine`, `DeOptV2-PerpMatchingEngine`, etc.)
  and each engine will use OpenZeppelin `EIP712`. Introducing a shared
  builder here would duplicate `EIP712.sol` without adding value.
  Recorded as `D-STI-03 FROZEN`. WP-05 (replay + epoch foundation)
  will introduce a mixin if the engines require it.

## Event and error ownership rules

- Shared identity errors (`InvalidOwner()`, `RegistrationOverflow()`,
  `NotAuthorized()`) live inside `ISubaccountRegistry` per spec.
- Module-specific errors live in their owning interface — no giant
  shared `Errors.sol` file.
- Events live in their owning interface. No shared events introduced
  in this milestone.

## Naming collisions with existing code

The existing repository has:

- `src/collateral/CollateralVault.sol` — legacy address-keyed vault.
  Legacy interface has partially overlapping method names
  (`deposit`, `withdraw`) but different parameter shapes (address-
  keyed, not subKey-keyed). No file-level collision because new code
  lives in `src/hybrid-v2/` and imports are explicit.
- `src/matching/OptionMatchingEngine.sol` — legacy engine with EIP-712.
  Legacy engine uses `nonces[address]` global mapping. No collision
  because new code is in `src/hybrid-v2/` and does not import legacy.
- `src/OptionProductRegistry.sol` — preserved, used by both v1 and v2
  engines. Not modified in this milestone.

No renames of legacy files. No modifications to legacy files.

## Files created by WP-01 (this milestone)

Interfaces (10):

- `src/hybrid-v2/interfaces/ISubaccountRegistry.sol`
- `src/hybrid-v2/interfaces/ICollateralVault.sol`
- `src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol`
- `src/hybrid-v2/interfaces/IPerpsPositionsLedger.sol`
- `src/hybrid-v2/interfaces/IRiskModule.sol`
- `src/hybrid-v2/interfaces/IReplayProtected.sol`
- `src/hybrid-v2/interfaces/IEscapeController.sol`
- `src/hybrid-v2/interfaces/IRecoveryFinalizer.sol`
- `src/hybrid-v2/interfaces/IFallbackOracle.sol`
- `src/hybrid-v2/interfaces/IRecoveryView.sol`

Libraries (5):

- `src/hybrid-v2/libraries/SubKey.sol`
- `src/hybrid-v2/libraries/Capabilities.sol`
- `src/hybrid-v2/libraries/Versions.sol`
- `src/hybrid-v2/libraries/PositionTypes.sol`
- `src/hybrid-v2/libraries/RecoveryTypes.sol`

Tests (4):

- `test/hybrid-v2/libraries/SubKey.t.sol`
- `test/hybrid-v2/libraries/Capabilities.t.sol`
- `test/hybrid-v2/libraries/Versions.t.sol`
- `test/hybrid-v2/interfaces/InterfacesCompile.t.sol`

Tracked documents:

- `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md` (this file).

## Explicit non-goals (this milestone)

- No SubaccountRegistry implementation. Deferred to
  `ONCHAIN-SUBACCOUNT-REGISTRY-V1`.
- No CollateralVaultV2 implementation. Deferred to
  `ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-A/B`.
- No OptionsPositionsLedger implementation. Deferred to
  `ONCHAIN-SUBACCOUNT-OPTIONS-POSITIONS-LEDGER-V1`.
- No RiskModuleV2 implementation. Deferred to
  `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-V1`.
- No engine implementation (Options, Perps). Deferred to
  `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` +
  `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (+ future perps).
- No EscapeController / RecoveryFinalizer / FallbackOracle /
  RecoveryView implementation. Deferred to
  `ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1-A/B`.
- No CapabilityController extraction. Capability model lives inside
  ICollateralVault per spec 07. Extraction, if needed, is a WP-03
  concern.
- No `IOptionMatchingEngine` / `IPerpMatchingEngine` /
  `IProtocolFeeVault` interfaces. These are engine-execution or
  fee-callback surfaces owned by their engine milestones (WP-08,
  future perps, WP-09). Adding them here would drift the engine ABI
  ahead of its owning milestone.
- No storage. No mutation. No pause. No governance. No deployment
  script. No backend or frontend change. No database migration.

## Deferred behavior + downstream ownership

| Deferred concept | Downstream milestone / WP |
|---|---|
| SubaccountRegistry implementation | `ONCHAIN-SUBACCOUNT-REGISTRY-V1` (WP-02) |
| CapabilityController extraction (if needed) | `ONCHAIN-SUBACCOUNT-CAPABILITY-CONTROLLER-V1` (WP-03) |
| CollateralVaultV2 implementation | WP-04A/B |
| Per-signer per-engine nonces + intent-hash + recoveryEpoch mixins | WP-05 |
| OptionsPositionsLedger implementation | WP-06 |
| RiskModuleV2 implementation | WP-07 |
| MarginEngineV2 + OptionMatchingEngineV2 (RFQ + multi-leg) | WP-08 |
| FeesManagerV2 subKey rewire + IProtocolFeeVault | WP-09 |
| EscapeController + RecoveryFinalizer + FallbackOracle + RecoveryView | WP-10A/B |
| Event schema finalization + deployment manifest | WP-11 |
| Consolidated invariant suite | WP-12 |
| Backend reconstruction | WP-13/14/15 |
| Frontend integration | WP-16 |
| Local E2E + Sepolia dry-run | WP-17/18 |
| Sepolia broadcast | WP-19 (separately authorized) |
| Legacy retirement | WP-20 |
| `IOptionMatchingEngine` full interface | WP-08 |
| `IPerpMatchingEngine` full interface | future perps milestone |

## Interface responsibility matrix (compile-only)

| Interface | Owning module milestone | Function count (approx) | Mutations | Views | Shared types used | Events | Errors | Replay boundary | Pause boundary | Compat/version boundary |
|---|---|---|---|---|---|---|---|---|---|---|
| ISubaccountRegistry | WP-02 | 11 | 2 | 8 (+1 pure) | subKey (bytes32), owner (address), subaccountId (uint32) | 2 | 3 | none (identity only) | none | version() |
| ICollateralVault | WP-04 | 32 | ~15 | 9 | subKey, tokens, engine, capability bits | 13 | (many, in own file) | none | pauseDeposits/Withdrawals/Transfers/Yield | isAuthorizedEngine + engineCapabilityBits |
| IOptionsPositionsLedger | WP-06 | 6 | 4 | 2 | subKey, seriesId, OptionPosition | 6 | (many, in own file) | none | none | via ledger version |
| IPerpsPositionsLedger | future perps | 4 | 3 | 1 | subKey, marketId, PerpPosition | 5 | (many, in own file) | none | none | via ledger version |
| IRiskModule | WP-07 | 10 | 0 | 10 | subKey, LiquidationStatus | 3 | 4 | none | none | moduleVersion + supportsCanonicalStorageVersion |
| IReplayProtected | WP-05 (mixin) | 4 | 2 | 2 | (address signer, bytes32 intentHash) | 0 (impl emits NonceCancelled) | 0 | YES | none | none |
| IEscapeController | WP-10A | 17 | 10 | 7 | subKey, RecoveryState, RecoveryScope, owner, subaccountId | (declared in impl per spec 14) | (declared in impl) | recoveryEpoch bump | pauseRecovery / unpauseRecovery | none |
| IRecoveryFinalizer | WP-10B | 7 | 5 | 2 | seriesId, FinalizationStatus, FallbackSource | (declared in impl) | (declared in impl) | none | governance queue window | none |
| IFallbackOracle | WP-10B | 2 | 0 | 2 | (underlying token address, price1e8) | 0 | 0 | none | none | none |
| IRecoveryView | WP-10A | 7 | 0 | 7 | subKey, token | 0 | 0 | none | none | none |

Total: **10 interfaces**, all consumer surfaces defined without state
or economic behavior.

## Verification of shared cross-module surface

- Registry functions do not mutate vault state. **Verified** — registry
  writes only its own storage (`SubaccountCreated`,
  `SubaccountLazyRegistered`); no vault call.
- Vault functions do not mutate position state. **Verified** — vault
  interface has no position storage; ledger owns positions.
- Risk interface does not own canonical balances or positions.
  **Verified** — every risk function is `view`.
- Capability model does not expose arbitrary balance mutation.
  **Verified** — capability grants are timelocked; only
  capability-gated functions mutate.
- Replay interface does not require PostgreSQL. **Verified** — nonces
  + intent-hash are chain-side.
- Perps interface is boundary-only. **Verified** — no engine
  implementation in this milestone; engine deferred.
- Escape/recovery interface does not permit unresolved-obligation
  withdrawal. **Verified** — safe-withdrawal computed by
  `IRecoveryView` per escape-hatch design; `escapeWithdraw` reverts
  when insufficient safe withdrawable.
- No interface silently preserves address-keyed legacy semantics.
  **Verified** — every subaccount-scoped function takes
  `bytes32 subKey` OR `(address owner, uint32 subaccountId)` at entry
  points.

## Decision register (this milestone)

| ID | Decision | Status |
|---|---|---|
| D-STI-01 | Use plain Solidity primitives; no UDVT wrappers in this milestone | FROZEN |
| D-STI-02 | No separate ICapabilityController; capability model inside ICollateralVault per spec 07 | FROZEN |
| D-STI-03 | No shared EIP-712 domain builder library; per-engine domain via OZ EIP712 | FROZEN |
| D-STI-04 | Interfaces for full IOptionMatchingEngine / IPerpMatchingEngine / IProtocolFeeVault DEFERRED to their engine milestones | FROZEN |
| D-STI-05 | Compiler pragma stays at `^0.8.20` for new files; foundry pins 0.8.30 with via_ir; matches existing repo | FROZEN |
| D-STI-06 | License stays BSL-1.1 for all new files | FROZEN |
| D-STI-07 | Directory convention: `src/hybrid-v2/` + `test/hybrid-v2/` (hyphen) | FROZEN |
| D-STI-08 | Capability set = 14 canonical + `CAP_RECOVERY_ACTIVATE` (bit 14) from escape-hatch/15 = 15 total | FROZEN |
| D-STI-09 | `deploymentVersion` is per-deployment `uint256` immutable (not a compile-time global); `INITIAL_DEPLOYMENT_VERSION = 1` documents the canonical type + sentinel | FROZEN |
| D-STI-10 | Capability-controller ownership = vault-owned; WP-03 implements the vault's capability subsystem (no separate contract, no separate interface) | FROZEN |

None BLOCKING. None DEFERRED_WITH_OWNER.

## Open questions carried forward

None specific to this milestone. Downstream milestones inherit
`IMP-Q1..IMP-Q40` from
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/22_OPEN_QUESTIONS.md`.

## Not a claim

This milestone does not claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval for downstream milestones;
- deployment approval;
- production readiness;
- suitability for real user funds.

Downstream implementation milestones remain individually authorized
per the product-owner authorization conditions dated 2026-07-25.
