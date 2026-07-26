# ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A

## Status

**IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL** — 2026-07-26.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-review sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base
mainnet or real user funds. Independent human internal reviewer status
remains `PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit
remains `PENDING_EXTERNAL_REVIEW`.

## Purpose

Freeze the custody + isolated balance + token-policy + deposit foundation
of the DeOpt V2 hybrid on-chain collateral vault as an abstract component
(`CollateralVaultV2Core`, WP-04A). Ready for extension by
`ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-B` (WP-04B) which adds per-engine
reservations, total-locked accounting, withdrawals, internal transfers,
fee/rebate hooks, orphaned-lock release, and pause matrix.

## Vault-owned scope resolved this milestone

- One shared physical Vault (abstract, harnessed for tests).
- Logical balances isolated by `(subKey, token)`.
- Canonical Registry validation (`existsOf` on every mutation).
- Allowlisted standard ERC-20 collateral only.
- Exact balance-delta validation (rejects fee-on-transfer + rebasing).
- Aggregate per-token accounted liability (`_totalAccounted`).
- Independently verifiable vault solvency views
  (`physicalBalance`, `totalAccounted`, `surplus`, `isSolvent`).
- Reconstructible deposit + token-policy events with `eventVersion`.
- Inherits the validated Vault-owned capability subsystem
  (`VaultCapabilityController`, WP-03).

## `setAuthorizedEngine` resolution (Part C)

**Verdict:** `SET_AUTHORIZED_ENGINE_IS_OBSOLETE_AND_REMOVED`.

Rationale: contract-spec 07 defines `isAuthorizedEngine(engine) =
(engineCapabilityBits(engine) != 0)` — a derived read. The parallel
boolean setter in `ICollateralVault` had no clean semantics: setting it
to `true` without a capability mask leaves the engine with zero
authority; setting it to `false` duplicates the effect of
`setEngineCapability(engine, currentBits, false)`. Retaining it would
introduce a second source of engine authority + potential storage
divergence.

Concrete changes:

- `ICollateralVault.setAuthorizedEngine(address engine, bool allowed)` — REMOVED.
- `ICollateralVault.AuthorizedEngineSet(address indexed engine, bool allowed, uint16 eventVersion)` — REMOVED.
- WP-01 tracked doc `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md` — patched with an "ABI corrections after initial land" section.

The `InterfacesCompile.t.sol` selector-guard did NOT reference either
symbol, so the removal is invisible to compile tests. All 39 baseline
suites still green after the removal (verified before writing WP-04A).

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization (2026-07-25) + non-blocking conditions.
2. Tracked designs (`ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`,
   `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`,
   `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`,
   `ONCHAIN_SUBACCOUNT_REGISTRY_V1.md`,
   `ONCHAIN_SUBACCOUNT_CAPABILITY_CONTROLLER_V1.md`,
   `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md`).
3. Detailed contract specifications (spec 03 vault, spec 07 capabilities,
   spec 10 internal transfers, spec 12 pause+governance, spec 13 events,
   spec 15 solidity interfaces, spec 16 errors+events, spec 17 invariant
   mapping, spec 18 test spec, spec 21 decision register).
4. Frozen WP-01 ABI (post-`setAuthorizedEngine` removal).
5. Validated Registry (WP-02) + capability (WP-03) implementations.
6. Implementation-plan package.
7. Repository conventions (BSL-1.1, ^0.8.20 pragma, foundry 1.5.0-stable,
   solc 0.8.30 via_ir, OZ v5).

## Files created

```
src/hybrid-v2/vault/
└── CollateralVaultV2Core.sol            (abstract)

test/hybrid-v2/vault/
├── CollateralVaultV2Core.t.sol          (45 unit + fuzz)
├── CollateralVaultV2CoreInvariant.t.sol (9 VAULT-A-I* invariants)
├── VaultRegistryCapabilityIntegration.t.sol (10 integration)
├── handlers/
│   └── CollateralVaultV2CoreHandler.sol
├── harness/
│   └── CollateralVaultV2CoreHarness.sol
└── mocks/
    ├── MockERC20.sol
    └── MaliciousTokens.sol   (FoT, false-return, reentrant, donation)
```

Files modified (WP-01 ABI correction):

- `src/hybrid-v2/interfaces/ICollateralVault.sol` — removed
  `setAuthorizedEngine` + `AuthorizedEngineSet`.
- `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md` — added the ABI
  corrections note.

No deployment script. No backend, frontend, database, or config change.

## Implementation form

`abstract contract CollateralVaultV2Core is VaultCapabilityController,
ReentrancyGuard`. Deliberately does NOT declare `is ICollateralVault`
because it implements only the WP-04A subset of that interface. V2-B
will extend this core, add the remaining functions, and complete the
interface conformance.

## Inheritance model

```
VaultCapabilityController         (WP-03, abstract)
        │
        │  onlyGovernance / onlyGuardian / capability bitmap
        │
        ▼
CollateralVaultV2Core             (WP-04A, abstract)
        │
        │  custody + token policy + deposit + solvency views
        │
        ▼
CollateralVaultV2                 (WP-04B, concrete)  ← reservations,
                                                        withdrawals,
                                                        transfers,
                                                        fees, etc.
```

Test-only concrete harness `CollateralVaultV2CoreHarness` derives from
V2-A core without adding behavior — solely to enable unit + integration
+ invariant fuzzing of the abstract.

## Constructor + immutables

```
constructor(address registry_, address governance_, address guardian_)
    VaultCapabilityController(governance_, guardian_);

ISubaccountRegistry public immutable REGISTRY;
```

Validation:

- `registry_ != address(0)` (`InvalidRegistry`).
- `governance_ != 0` (`InvalidGovernance`) — inherited.
- `guardian_ != 0` (`InvalidGuardian`) — inherited.

Registry immutability is preserved. No admin may change the reference.

## Registry / Vault deployment cycle (unchanged)

Two-way immutable reference resolved at deployment time via
CREATE / CREATE2 address prediction, deterministic-nonce prediction, or
a single-transaction factory. In tests we use `vm.computeCreateAddress`
to predict the vault's address before deploying the registry with that
address as `capabilityAuthority`. Production deployment scripts owned by
`ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-MANIFEST-V1` +
`ONCHAIN-SUBACCOUNT-BASE-SEPOLIA-DRY-RUN-V1`. Immutability is NOT
weakened by V2-A.

## Token policy

```
mapping(address token => bool enabled) internal _tokenEnabled;

function addSupportedToken(address token) external onlyGovernance;
function removeSupportedToken(address token) external onlyGovernance;
function supportedTokens(address token) external view returns (bool);
```

Rules:

- Zero token rejected (`InvalidToken`).
- Governance (i.e. ProtocolTimelock in production) is the SOLE authority.
- Guardian may NOT enable or disable tokens in V2-A. Spec 03 does not
  freeze a guardian token-policy authority; V2-A does not invent one.
  Emergency deposit pauses arrive with the WP-04B pause matrix.
- Disabling a token blocks new deposits but PRESERVES existing balances
  + aggregate liability (proved by unit test + VAULT-A-I6 invariant).
- Duplicate enable → `TokenAlreadySupported`. Duplicate disable →
  `TokenNotEnabled`.
- No global token enumeration required on-chain.

## Deposit semantics

Two entrypoints matching the frozen ABI:

```
function deposit(uint32 subaccountId, address token, uint256 amount) external nonReentrant;
function depositFor(address owner, uint32 subaccountId, address token, uint256 amount) external nonReentrant;
```

`deposit(subaccountId, token, amount)`:

1. `owner = msg.sender`.
2. Validate: `owner != 0`, `subaccountId != 0`, `token != 0`,
   `_tokenEnabled[token]`, `amount != 0`.
3. If `subaccountId == 1 && !REGISTRY.existsOf(owner, 1)`, call
   `REGISTRY.registerLazyDefault(owner)`. This requires the vault itself
   to hold `Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT` (granted by
   governance post-deployment via `setEngineCapability(address(vault),
   CAP_REGISTER_DEFAULT_ACCOUNT, true)`).
4. Require `REGISTRY.existsOf(owner, subaccountId)` else
   `SubaccountNotFound(owner, subaccountId)`.
5. Derive `subKey = REGISTRY.subKeyOf(owner, subaccountId)`.
6. Pull tokens + validate delta + credit + emit `Deposit`.

`depositFor(owner, subaccountId, token, amount)`:

Same validation and pull/credit path with two differences:

- Payer = `msg.sender`; credited owner = `owner`.
- NEVER lazily registers. Requires the target subaccount to already exist.

**Third-party deposit conclusion:** SUPPORTED per spec 03. Payer receives
no ownership or withdrawal authority; `Deposit.depositor` field records
the payer for reconstruction.

## Exact balance-delta policy

```
balanceBefore = IERC20(token).balanceOf(address(this));
IERC20(token).safeTransferFrom(payer, address(this), amount);
balanceAfter  = IERC20(token).balanceOf(address(this));
credited = balanceAfter - balanceBefore;
if (credited != amount) revert InvalidTokenBalanceDelta(amount, credited);
```

- Uses OZ `SafeERC20` (rejects false-return, missing-return, non-existent
  tokens with standard behavior).
- Requires the received amount to EXACTLY equal the requested amount.
- Rejects fee-on-transfer, rebasing, and other non-standard ERC-20 tokens
  even if governance mistakenly enables one (defense in depth).
- `nonReentrant` on both entrypoints; malicious tokens that call back
  into the vault mid-transfer trigger
  `ReentrancyGuardReentrantCall`.

## Balance storage

```
mapping(bytes32 subKey => mapping(address token => uint256 balance)) internal _balanceOf;
mapping(address token => uint256 totalAccounted)                   internal _totalAccounted;
```

Rules:

- All writes use `REGISTRY.subKeyOf(owner, subaccountId)` — the
  deployment-scoped registry address is bound into every key.
- The vault NEVER derives keys with `address(this)`.
- Aggregate liability changes exactly with account credits: `_balanceOf`
  and `_totalAccounted` both increment by `amount` on every deposit.
- No signed balances; no implicit debt; no rounding; no admin sweep of
  balances.
- No global iteration; all views are O(1).
- No `totalLocked` / `lockedByEngine` production storage in V2-A (owned
  by V2-B).

## Solvency views

```
function balanceOf(bytes32 subKey, address token) external view returns (uint256);
function balanceOfAccount(address owner, uint32 id, address token) external view returns (uint256);
function totalAccounted(address token) external view returns (uint256);
function physicalBalance(address token) external view returns (uint256);
function isSolvent(address token) external view returns (bool);
function surplus(address token) external view returns (uint256);
function supportedTokens(address token) external view returns (bool);
```

Core invariant: `IERC20(token).balanceOf(vault) >= _totalAccounted[token]`.

V2-A does NOT expose `availableOf`, `lockedOf`, `lockedByEngineOf`,
`protocolFeeVaultSubKey`, or `insuranceFundSubKey` — those semantics
belong to V2-B and would be actively misleading if implemented now (per
Part I).

## Donation / excess behavior

Direct ERC-20 transfers to the vault address bypass `deposit` and
`depositFor`. Behavior:

- `_totalAccounted[token]` is NOT incremented.
- No subaccount balance is credited.
- `physicalBalance(token) > totalAccounted(token)` and
  `surplus(token) == physicalBalance - totalAccounted`.
- `isSolvent(token) == true`.

No admin sweep exists. Excess-recovery mechanism is DEFERRED.

## Withdrawal boundary

**Verdict:** `FINAL_WITHDRAWAL_PATH_DEFERRED_SAFELY_TO_V2_B`.

Reason: V2-A does not yet have per-engine reservations, `totalLocked`,
RiskModule wiring, settlement obligations, or recovery reservations. A
"user can withdraw anything they deposited because nothing is locked
yet" function would silently change semantics when V2-B adds locks.

V2-A implements NO `withdraw` and NO `withdrawFor`. `depositFor` DOES
NOT confer withdrawal authority on the payer (the credited owner has
sole future authority). The full owner + engine withdrawal ABI is owned
by V2-B.

## Malicious-token policy

Coverage in `CollateralVaultV2Core.t.sol` + `CollateralVaultV2CoreHandler`
+ invariants:

| Category | Behavior | Test |
|---|---|---|
| Standard ERC-20 | credits exactly | `test_deposit_creditsExactAmount` |
| Fee-on-transfer (1%) | reverts `InvalidTokenBalanceDelta(amount, credited)`, no state change | `test_feeOnTransferToken_rejectedByDeltaCheck` + `tryFotDeposit` invariant path |
| False-returning `transferFrom` | reverts `SafeERC20FailedOperation`, no state change | `test_falseReturningToken_rejected` |
| Reentrant callback into `deposit`/`depositFor` | reverts `ReentrancyGuardReentrantCall` | `test_reentrantToken_blockedByGuard` |
| Direct donation | surplus only, no credit | `test_directDonation_createsSurplusOnly` + `directDonate` invariant path |
| Unsupported token | reverts `TokenNotSupported`, no state change | `test_deposit_unsupportedTokenReverts` + `tryUnsupportedTokenDeposit` invariant |

Missing rebasing-token mock is intentional: the delta check already
guarantees rejection because a rebase would drop the received amount
below `amount`.

## Event / error model

Events:

```
event Deposit(
    bytes32 indexed subKey,
    address indexed owner,
    uint32  indexed subaccountId,
    address token,
    uint256 amount,
    address depositor,
    uint16  eventVersion
);
event SupportedTokenAdded(address indexed token, uint16 eventVersion);
event SupportedTokenRemoved(address indexed token, uint16 eventVersion);
```

Deposit event includes indexed subKey + readable owner + subaccountId +
token + amount + depositor + eventVersion — fully reconstructible.

Errors (contract-local; not on ICollateralVault since ICollateralVault
does not declare these):

- `InvalidRegistry()`, `InvalidToken()`, `InvalidOwner()`,
  `InvalidSubaccountId()`.
- `SubaccountNotFound(address owner, uint32 subaccountId)`.
- `TokenNotSupported()`, `TokenAlreadySupported()`, `TokenNotEnabled()`.
- `AmountZero()`.
- `InvalidTokenBalanceDelta(uint256 requested, uint256 credited)` —
  parameterized so caller sees both values.

## Storage review

All new V2-A storage lives on the abstract:

```
CollateralVaultV2Core:
    mapping(address => bool)                                  _tokenEnabled;
    mapping(bytes32 => mapping(address => uint256))           _balanceOf;
    mapping(address => uint256)                               _totalAccounted;

inherited from VaultCapabilityController:
    address _guardian;
    mapping(address => uint256) _engineCapabilityBits;

immutables:
    ISubaccountRegistry REGISTRY (V2-A)
    address governance          (V2-A via V-C-C)

inherited from ReentrancyGuard:
    private uint256 _status (single slot, transient-friendly per OZ v5)
```

Storage safety:

- No collision within the inheritance chain (Solidity 0.8 packs
  automatically; each mapping/immutable is at a distinct slot).
- Capability storage is inherited exactly once.
- Governance + guardian are stored exactly once (in
  `VaultCapabilityController`).
- Registry is `immutable` (constructor bytecode, no storage slot).
- No proxy storage assumptions; the canonical Vault is not upgradable.
- V2-B additions (`_totalLocked`, `_lockedByEngine`, pause flags,
  `withdrawPauseAutoClearBlock`, `PROTOCOL_FEE_VAULT_SUBKEY`,
  `INSURANCE_FUND_SUBKEY`, yield mappings) can be appended without
  rewriting V2-A accounting.

## Registry + capability integration

Validated via `VaultRegistryCapabilityIntegration.t.sol` (10 tests):

- Capability views (`isAuthorizedEngine`, `engineCapabilityBits`) still
  function after deposits.
- `deposit(1)` lazily registers via the vault's own capability.
- External engine with `CAP_REGISTER_DEFAULT_ACCOUNT` can lazily
  register, then owner deposits work.
- External engine without the capability reverts on lazy registration.
- Account 2 requires explicit `registerNext` — deposit revert cleanly
  otherwise.
- Guardian revoke of the vault's capability blocks future lazy
  registration but preserves existing balances.
- Governance re-grant restores the lazy path.
- Capability mutations do not alter collateral balances.
- Token policy mutations do not alter registry state.
- Mixed lazy-register + explicit-register + engine-driven-only-register
  flows remain isolated.

## Gas / DoS posture (development-run observations, non-normative)

- `addSupportedToken`: ~50k.
- `removeSupportedToken`: ~17k.
- First deposit into `(owner, id, token)`: ~237k (registry lazy call
  cost + storage writes + SafeERC20 pull + event).
- Second deposit into same `(owner, id, token)`: ~50k less because the
  lazy path skips.
- `balanceOf` view: ~2k warm.
- `totalAccounted` view: ~2k warm.
- `physicalBalance` view: ~2.7k (single external call).
- `isSolvent` view: ~3k.

Structural properties:

- Deposits O(1).
- Token policy mutations O(1).
- All views O(1).
- No iteration over owners / subaccounts / tokens.
- Depositor pays gas.
- Mass account creation remains registry-priced (one registration per
  call, per owner).
- Malicious tokens cannot force unbounded iteration (all mutations are
  a single storage read + single storage write per branch).

## Invariant coverage

- **VAULT-A-I1** `physicalBalance(token) >= totalAccounted(token)` for
  every tracked token.
- **VAULT-A-I2** Sum of ghost per-subaccount balances == totalAccounted
  per token.
- **VAULT-A-I3 + I4** Ghost mirror per `(owner, id, token)` equals
  storage — any cross-subaccount mutation would surface as divergence.
- **VAULT-A-I5** FoT + unsupported + reverting paths never accumulate
  liability (`totalAccounted` for those tokens stays zero throughout).
- **VAULT-A-I6** Token disable/enable cycle preserves existing balances
  and aggregate (spot-checked at invariant time).
- **VAULT-A-I7** Capability mutations at invariant time do not alter
  balances or aggregate.
- **VAULT-A-I8** Event-derived aggregate (ghost incremented on each
  successful `Deposit`) equals `totalAccounted` — reconstructor can
  rebuild state from event stream alone.
- **VAULT-A-I9** `_balanceOf[subKeyOf(owner, 0)][token] == 0` for every
  tracked owner and token — Account 0 is uncreditable.
- **VAULT-A-I10** Donations create only `surplus`; never user credit.

Each invariant runs with 64 runs × 64 depth via inline `forge-config`
(~4096 handler calls per invariant, ~24s wall-clock for the suite).

## Non-goals (owned by V2-B or later)

- Per-engine collateral reservations (`applyLock` / `applyUnlock`).
- Aggregate `totalLocked[subKey][token]`.
- `applyFeeDebit`, `applyRebateCredit`, `applyLiquidationDebit`,
  `applySettlementCreditDebit`.
- User `withdraw` / `withdrawFor`.
- `internalTransfer`.
- `governanceReleaseOrphanedLock`.
- Pause matrix + `withdrawPauseAutoClearBlock`.
- Yield adapter integration (`moveToStrategy`, `moveFromStrategy`,
  `setYieldOptIn`).
- Well-known internal-account subKeys (`protocolFeeVaultSubKey`,
  `insuranceFundSubKey`).
- Bad-debt / socialization tracking.
- RiskModule integration.
- EIP-712 / signatures / replay.
- Recovery reservations.

## Downstream dependencies

- **V2-B (`ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-B`)** — extends this
  core, implements the remaining ICollateralVault surface. Consumes
  `_balanceOf` and `_totalAccounted` unchanged.
- **WP-05 replay/epoch foundation** — orthogonal to V2-A.
- **WP-06 / WP-07 ledgers** — will consume `subKeyOf` from the registry
  and eventually `applyLock` / `applyUnlock` from V2-B.

## Repository state at milestone close

- `deopt-v2-sol` moves from `aa6c93a` to the milestone-close head
  recorded in `~/DEOPT/docs/ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A_RESULT.md`.
- Full suite: 42 suites, 607 tests, 0 failed (baseline was 39/543).
  Delta: +3 suites, +64 tests.
- `deopt-v2-backend` untouched. `deopt-v2-frontend` untouched.

No audit sign-off. No security-review sign-off. No deployment approval.
