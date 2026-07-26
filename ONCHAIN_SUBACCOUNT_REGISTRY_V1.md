# ONCHAIN_SUBACCOUNT_REGISTRY_V1

## Status

**IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL** — 2026-07-26.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-review sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base
mainnet or real user funds. Independent human internal reviewer status
remains `PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit
remains `PENDING_EXTERNAL_REVIEW`.

## Purpose

Freeze the canonical immutable `SubaccountRegistry` implementation for the
DeOpt V2 hybrid on-chain economic-subaccount architecture. This milestone
lands the identity + discoverability layer consumed by WP-03 through WP-10
(capability controller, vault, ledgers, engines, risk module, recovery).

The registry owns identity ONLY. It does not own collateral, positions,
margin, fees, settlements, liquidation state, recovery balances, or
off-chain metadata. It carries no admin, no proxy, no pause, no
governance escape hatch.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization (2026-07-25) + its non-blocking
   conditions.
2. Tracked designs in `deopt-v2-sol/`:
   - `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
   - `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
   - `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`
   - `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md`
   - `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
   - `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`
   - `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`
3. Detailed contract specification, in particular
   - `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/02_SUBACCOUNT_REGISTRY_SPEC.md`
   - `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/13_EVENTS_AND_RECONSTRUCTION.md`
   - `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/14_STATE_MACHINES.md`
   - `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/15_SOLIDITY_INTERFACES.md`
   - `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/17_SECURITY_INVARIANT_MAPPING.md`
   - `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/18_TEST_SPECIFICATION.md`
4. WP-01 canonical interfaces and shared libraries.
5. Detailed experimental-implementation-plan (WP-02).
6. Repository conventions.

Where guidance was silent, this milestone documents the choice
explicitly rather than inventing behavior.

## Files created

```
src/hybrid-v2/registry/
└── SubaccountRegistry.sol

test/hybrid-v2/registry/
├── SubaccountRegistry.t.sol
├── SubaccountRegistryInvariant.t.sol
├── handlers/
│   └── SubaccountRegistryHandler.sol
└── mocks/
    └── MockCapabilityAuthority.sol
```

No existing source or test was modified. No deployment script, address
configuration, or backend/frontend change.

## Interface compatibility

`SubaccountRegistry.sol` implements `ISubaccountRegistry` (WP-01) verbatim.
No interface change was required. The following functions are present:

- `registerNext()` — owner-initiated monotonic id assignment.
- `registerLazyDefault(address owner)` — engine-initiated Account 1 lazy
  registration.
- `subKeyOf(address, uint32)` — canonical derivation view.
- `existsOf(address, uint32)` — O(1) existence check.
- `ownerOf(bytes32)` / `subaccountIdOf(bytes32)` — reverse lookup.
- `nextIdFor(address)` — next assignable id (returns 1 before any
  registration).
- `subaccountsOfPage(address, uint32 offset, uint32 limit)` — bounded
  paged enumeration.
- `deploymentChainId()` / `deploymentBlock()` / `version()` — deployment
  metadata.

Events + errors match `ISubaccountRegistry` + spec 16 exactly:

- `SubaccountCreated`, `SubaccountLazyRegistered`.
- `InvalidOwner`, `RegistrationOverflow`, `NotAuthorized`.

One additional constructor-only error, not on the interface:

- `InvalidCapabilityAuthority()` — reverted when the constructor is
  supplied with a zero authority address.

## Storage model (final)

```
uint256 public immutable DEPLOYMENT_CHAIN_ID;
uint64  public immutable DEPLOYMENT_BLOCK;
address public immutable capabilityAuthority;
string  public constant  VERSION        = "1";
uint32  public constant  MAX_BATCH_SIZE = 256;

mapping(address => uint32)  private _nextIdOfOwner;      // 0 == never registered
mapping(bytes32 => bool)    private _existsOfKey;
mapping(bytes32 => address) private _ownerOfKey;
mapping(bytes32 => uint32)  private _subaccountIdOfKey;
```

Discussion:

- `_nextIdOfOwner` is the smallest per-owner counter that supports
  monotone assignment without holes. The sentinel `0` maps to "next
  assignable = 1" in `nextIdFor`.
- Reverse-lookup mappings (`_ownerOfKey` + `_subaccountIdOfKey`) are
  retained per spec 02 storage layout so views like `ownerOf(subKey)` and
  `subaccountIdOf(subKey)` remain O(1) without event-scan. This closes
  INV-ID-01 + INV-ID-02 with pure chain reads.
- No per-owner dynamic id array is stored: enumeration is derivable from
  the counter, because ids are contiguous and never deleted.
- No global owner list is stored (avoids unbounded state).
- No metadata (labels, colors, tags) — per INV-META-01/02/03.

## Registration state machine

State per `(owner, subaccountId)` is one of:

- `NON_EXISTENT` — no entry.
- `EXISTS` — permanent.

Transitions:

| From          | To     | Caller                            | Preconditions                                                     | Event                     |
|---------------|--------|------------------------------------|-------------------------------------------------------------------|---------------------------|
| `NON_EXISTENT`| `EXISTS` | owner via `registerNext()`         | `msg.sender != 0`; next id != `type(uint32).max`                  | `SubaccountCreated`       |
| `NON_EXISTENT`| `EXISTS` | engine via `registerLazyDefault()` | caller holds `CAP_REGISTER_DEFAULT_ACCOUNT`; owner != 0           | `SubaccountLazyRegistered`|
| `EXISTS`      | `EXISTS` (no-op) | `registerLazyDefault()`   | idempotent when owner already has any registered account          | none                      |

No transition exits `EXISTS`. There is no deletion, deactivation, id
reuse, transfer, or admin owner reassignment (SM-1 in spec 14).

## Caller model + capability authority

Two callers, two paths, one authority:

1. **Owner path** — `msg.sender == owner`. Any address may register its
   own next monotonic id via `registerNext()`. No capability check.
2. **Engine path** — capability-holding engine calls
   `registerLazyDefault(owner)` on behalf of the owner. Capability check
   is delegated to the vault's `engineCapabilityBits(engine)` bitmap:
   the caller must have `CAP_REGISTER_DEFAULT_ACCOUNT` (bit 0) set.

The vault reference is an **immutable** `capabilityAuthority` supplied at
construction. Non-zero is enforced. This satisfies Part E acceptable
outcome 2 in the milestone brief: the registry exposes a narrowly
specified function whose authorization is bound to an immutable authority
without implementing capability storage inside the registry.

## Deployment cycle + how it is resolved

The vault also holds an immutable reference to the registry (for `deposit`
existence checks). This is a two-way immutable dependency. The intended
resolution is **CREATE2 salt prediction**:

1. Compute the deterministic address `V` of the future
   `CollateralVault` via CREATE2.
2. Deploy `SubaccountRegistry(V)` with `V` supplied as the constructor
   argument (`V` need not exist yet — the registry never calls it at
   construction).
3. Deploy the `CollateralVault` at `V` with the registry's address
   supplied as its constructor argument.

An equivalent alternative is to deploy both via a factory in a single
transaction. Deployment scripts are OUT of scope for this milestone.

## Lazy Account 1 conclusion

Implemented. Approved-caller model resolved. `registerLazyDefault(owner)`
is authorized ONLY when the caller has bit 0
(`CAP_REGISTER_DEFAULT_ACCOUNT`) set on the immutable capability
authority. Idempotent: any previously-registered id for the owner short-
circuits the call to a no-op.

## Enumeration model

`subaccountsOfPage(address owner, uint32 offset, uint32 limit)` returns
a contiguous slice `[startId, endId)` with:

- `startId = offset == 0 ? 1 : offset` (Account 0 excluded).
- `endId   = min(startId + limit, nextIdOfOwner(owner))`.
- `limit` is silently capped at `MAX_BATCH_SIZE = 256` before slicing.

Properties:

- No unbounded array return; array length is at most `MAX_BATCH_SIZE`.
- Explicit ascending order by subaccount id.
- Empty result when `startId >= endId` (offset past end or limit 0).
- Rationale for the `MAX_BATCH_SIZE = 256` cap: bounds gas + memory
  allocation while giving indexers a meaningful page. Not an economic
  invariant. Not governance-mutable.

Alternative enumeration path: subscribe to `SubaccountCreated` +
`SubaccountLazyRegistered` from `DEPLOYMENT_BLOCK` and rebuild the full
`(owner, id) → subKey` mapping (INV-ESC-01 + spec 13).

## Events + errors

```
event SubaccountCreated(
    address indexed owner,
    uint32  indexed subaccountId,
    bytes32 indexed subKey,
    uint256 chainId,
    uint16  eventVersion
);

event SubaccountLazyRegistered(
    address indexed owner,
    uint32  indexed subaccountId,
    bytes32 indexed subKey,
    uint256 chainId,
    address viaEngine,
    uint16  eventVersion
);

error InvalidOwner();
error RegistrationOverflow();
error NotAuthorized();
error InvalidCapabilityAuthority();  // contract-local only
```

Every registration is independently reconstructible: subKey (indexed) +
owner (indexed + readable) + subaccountId (indexed + readable) + chainId
+ eventVersion. `viaEngine` on the lazy variant identifies which engine
performed the lazy registration. No hash-only opacity.

## Invariant mapping

| Invariant | Enforcement in this milestone |
|---|---|
| INV-ID-01 canonical owner verifiable without Postgres | STORAGE: `ownerOf(subKey)` + `existsOf(owner, id)` |
| INV-ID-02 deterministic id independently discoverable | STORAGE: `subKeyOf` + events emitted at registration |
| INV-ID-03 unique owner per subaccount | STORAGE: `_ownerOfKey[subKey]` set once, never rewritten (proved by REG-I5) |
| INV-ID-04 DB mutation cannot change ownership | STORAGE: registry has no admin, no setter of `_ownerOfKey` |
| INV-ID-05 transfer safety (N/A in V1) | STORAGE: no transfer function exists |
| INV-ID-06 smart-wallet controller rotation | STORAGE: registry keys on address; wallet-signer changes are transparent to the registry (unit-tested) |
| INV-META-01/02/03 UX metadata off-chain | STORAGE: no metadata surface exists |
| INV-GOV-01 upgrade cannot silently change ownership | STORAGE: registry immutable, no admin |
| INV-ESC-01 user enumerates without frontend | STORAGE: `subaccountsOfPage` + event history |

Local registry invariants proved by the Foundry invariant suite:

- **REG-I1** No owner ever has a registered Account 0.
- **REG-I2** For every owner, registered ids form the exact contiguous
  range `[1, lastRegisteredId]`.
- **REG-I3** No two distinct `(owner, subaccountId)` identities produce
  the same registered subKey within the tested domain.
- **REG-I4** A registered identity never becomes unregistered.
- **REG-I5** Registration never changes the canonical owner of a prior
  identity.
- **REG-I6** The registry never mutates collateral / position / token
  state (structurally: no payable path, no external mutating call).
- **REG-I7** Sum of per-owner registered counts equals the total
  successful registrations tracked by the handler.

## Gas / DoS posture (observed, non-normative)

Observed from unit tests (development configuration, not a mainnet
benchmark):

- `registerNext` first call: ~101k gas.
- `registerNext` subsequent call: ~72k gas incremental.
- `existsOf` view: cold ~9k, warm sub-3k.
- `subKeyOf` view (pure): ~7k.
- `nextIdFor` view: ~8k cold.
- `subaccountsOfPage` at MAX_BATCH_SIZE (256): ~287k gas (test fixture).

Structural properties confirmed:

- Registration is O(1): three storage writes + one event.
- Existence lookup is O(1): one storage read.
- Key lookup is deterministic keccak + one read.
- Pagination is O(limit), bounded by MAX_BATCH_SIZE.
- No transaction iterates over every account or every owner.
- Mass registration requires the registering party to pay gas per call.
- No third party can create Account 2..N for another owner (only
  `msg.sender == owner` in `registerNext()`; lazy default writes id 1
  only).

## Immutability + non-transferability controls

Absent by design:

- No ownership transfer function.
- No subaccount transfer function.
- No deletion / deactivation.
- No reassignment / admin override.
- No balance mutation, position mutation, migration credit path.
- No pause that disables discovery.
- No proxy / upgrade entry point.
- No generic `initialize()`.

## Constructor input review

- Input: `address capabilityAuthority_`.
- Immutable field: `capabilityAuthority`.
- Requirement: non-zero (enforced by `InvalidCapabilityAuthority()`).
- Purpose: allow `registerLazyDefault` to consult the vault's capability
  bitmap without owning capability storage. Least-privilege delegation.
- Deployment cycle: two-way immutable with the vault; resolved by CREATE2
  salt prediction (see above). Not implemented in this milestone.

## Threat coverage in this milestone

| Threat surface | Mitigation |
|---|---|
| Third-party creates accounts for an unrelated owner | `registerNext` uses `msg.sender`; lazy default writes id 1 only + requires capability |
| Broad admin can rewrite ownership | No admin exists; storage mutation is limited to registration paths |
| ID inflation attack (T12 / ISR-003) | `registerNext` is the only per-owner mint path; caps at `type(uint32).max - 1`; costs gas per call |
| Cross-deployment subKey aliasing (ISR-005) | subKey binds `block.chainid` + `address(this)` via `SubKey.derive` |
| Owner reassignment via governance | No governance surface exposed by the registry |
| Metadata leakage | No metadata is stored on chain |
| Wallet-signer rotation removing entitlement | Registry keys on `address` only; wallet-internal signer changes are transparent |
| DoS via unbounded enumeration | `MAX_BATCH_SIZE` cap + O(limit) loop |

Threats NOT covered here (owned by downstream milestones):

- Capability bit allocation + timelock (WP-03).
- Collateral solvency + reservation cross-engine safety (WP-04).
- Signature / replay / recovery / escape (WP-05..WP-10).

## Non-goals

- No vault, ledger, engine, or risk module implementation.
- No capability storage on the registry (no admin, no bit map).
- No signature verification, EIP-712 domain, or replay/nonce logic.
- No deployment script or address configuration.
- No backend / frontend / database change.
- No production-readiness claim. No mainnet readiness claim.
- No public-testnet claim.
- No migration behavior.

## Downstream dependencies

Immediate consumer: WP-03
(`ONCHAIN-SUBACCOUNT-CAPABILITY-CONTROLLER-V1`) — the vault-owned
capability subsystem that owns `engineCapabilityBits`. The registry
consumes only the view side of that surface. WP-03 has no reason to
change the registry.

Later consumers: WP-04 (vault existence-check), WP-06/07 (ledgers,
identity assertions), WP-08 (matching engines), WP-10 (escape).

## Open items forwarded (non-blocking for this milestone)

- **REPLAY_DEPLOYMENT_VERSION_ABI** — spec-wide reconciliation of
  whether `deploymentVersion` appears as an explicit typed field in
  signed messages, is bound solely via `verifyingContract`, or is
  carried only by manifests + migration events. Not touched by the
  registry (which does not verify signed economic actions). Owner:
  `ONCHAIN-SUBACCOUNT-REPLAY-AND-EPOCH-FOUNDATION-V1`.

## Repository state at milestone close

- `deopt-v2-sol` moves from `46116c0` to the milestone-close head listed
  in `ONCHAIN_SUBACCOUNT_REGISTRY_V1_RESULT.md`.
- Full test suite: 36 suites, 479 tests, 0 failed (baseline was 34
  suites, 430 tests). Delta: +2 suites, +49 tests.
- Focused registry tests: 49 (42 unit + fuzz, 7 invariants).
- `deopt-v2-backend` untouched.
- `deopt-v2-frontend` untouched.

No audit sign-off. No security-review sign-off. No deployment approval.
