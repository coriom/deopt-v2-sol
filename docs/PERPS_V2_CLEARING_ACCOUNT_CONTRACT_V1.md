# PERPS_V2_CLEARING_ACCOUNT_CONTRACT_V1

Hardens the settlement-liquidity custody of PerpEngineV2. Supersedes the
"any address can be clearing" stance of the prior V2 milestone.

Companion to `docs/PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1.md`. That doc
established V2's per-side realized-PnL accounting model routed through
a clearing address. This doc establishes what that clearing address
must actually **be**, and how it is funded, defended, and integrated.

---

## 1. Confirmed CollateralVault ACL surface

Traced from `src/collateral/CollateralVaultActions.sol` + `.../Storage.sol`.

| Function | Caller gate | Balance mutated | Attack risk |
|---|---|---|---|
| `deposit(token, amt)` | anyone | credits `msg.sender` only | additive, no drain |
| `depositFor(user, token, amt)` | `onlyMarginEngine` | pulls from `user`, credits `user` | requires user's ERC20 approval; not a drain vector |
| `withdraw(token, amt)` | anyone | debits `msg.sender`, sends ERC20 to `msg.sender` | **EOA-clearing: full drain** |
| `withdrawFor(user, token, amt)` | `onlyMarginEngine` | debits `user`, sends to `user` | any authorized engine can force-withdraw clearing to clearing's ERC20 wallet |
| `transferBetweenAccounts(token, from, to, amt)` | `onlyMarginEngine` | moves internal balance | any authorized engine can drain clearing to arbitrary account |
| `transferFromInternalAccount(asset, to, amt)` | anyone (`msg.sender` is source) | debits `msg.sender`, sends to `to` | **EOA-clearing: full drain to arbitrary address** |
| `moveToStrategy/moveToIdle`, `setYieldOptIn` | anyone (self) | own balance shifts | none |
| `syncAccountFor(user, token)` | `onlyAuthorizedEngine` | none | none |

Key implication: any address holding a Vault balance can drain itself
via `withdraw` or `transferFromInternalAccount` **unless the address is
a contract whose code contains no such call**.

## 2. Attack model comparison

| Candidate | Self-drain via `withdraw` | Self-drain via `transferFromInternalAccount` | Drain by authorized engine |
|---|---|---|---|
| A. Governance EOA | governance drains at will | governance drains at will | any auth'd engine drains |
| B. Safe/multisig | multisig drains via ceremony | multisig drains via ceremony | any auth'd engine drains |
| C. Inert contract (no self-drain path) | impossible | impossible | any auth'd engine drains |
| D. **PerpClearingAccountV2** (deposit-only surface) | **impossible** | **impossible** | any auth'd engine drains |

Row-1/2 (self-drain) is eliminated by making the identity a contract
with no drain code. Row-3 (engine drain) is orthogonal to identity type
and is defended by **the vault authorization ACL** — governance MUST
revoke V1 via `setAuthorizedEngine(V1, false)` before enabling V2 on
the same market (see §7).

## 3. Chosen custody architecture — D

**`PerpClearingAccountV2`** — bespoke deposit-only contract:

- Constructor: `constructor(address _vault)` — sets an immutable
  `collateralVault` reference. No owner, no upgrade path.
- Single public method: `fundClearing(address asset, uint256 amount)`
  — permissionless. Pulls `amount` of `asset` from `msg.sender` via
  `SafeERC20.safeTransferFrom`, approves the vault for exactly the
  received amount, calls `Vault.deposit(asset, received)`, then resets
  the approval to zero.
- No `withdraw`, no `withdrawFor`, no `transferBetweenAccounts`,
  no `transferFromInternalAccount`, no `moveToStrategy/moveToIdle`,
  no `setYieldOptIn`, no fallback, no receive, no emergency, no
  delegatecall, no arbitrary call.
- No storage state (`collateralVault` is `immutable`); no state variables
  to corrupt via reentrancy.
- Events: `ClearingFunded(indexed funder, indexed asset, amount)`.
- Errors: `ZeroAddress`, `AmountZero`, `ReceivedZero`.

Approval hygiene: scoped per call; reset to zero after
`Vault.deposit` returns. No dangling live allowances.

## 4. Funding path (proven)

```
FUNDER --[ERC20.approve(clearing, X)]--> clearing
FUNDER --[clearing.fundClearing(asset, X)]--> clearing
   |
   +-- IERC20.safeTransferFrom(FUNDER, this, X)   -> clearing holds X in ERC20
   +-- IERC20.forceApprove(vault, X)              -> vault authorised for X
   +-- vault.deposit(asset, X)
       |
       +-- safeTransferFrom(clearing, this, X)    -> vault holds X in ERC20
       +-- balances[clearing][asset] += X          -> clearing credited internally
   +-- IERC20.forceApprove(vault, 0)              -> approval cleared
```

The `Vault.deposit` semantics credit `msg.sender`, which is the clearing
contract at the outer call. No privileged balance setter is introduced.

## 5. Withdrawal / emergency policy

**No emergency recovery in this milestone** (per §4 of the operator
directive: "If a truly no-withdraw contract is safer for this stage,
prefer that.").

Consequences:
- Governance cannot drain clearing back to itself.
- A future milestone `PERPS_V2_CLEARING_EMERGENCY_RECOVERY_V1` may add
  a pause-first governance-gated emergency drain if the operational
  need arises. It would be gated by:
    - `onlyOwner` (Timelock)
    - explicit `engine.paused()` prerequisite
    - dedicated event `EmergencyClearingRecovered(...)`
    - unable to affect trader positions or balances
  Not added here to keep the current audit surface minimal.

To release clearing funds back to a wallet in the current design,
governance must:
1. `engine.pause()` (or freeze all V2 markets).
2. Route the balance via the existing engine's ordinary flow (e.g.
   settle a controlled position that transfers clearing's balance into
   a governance-controlled trader address) — cumbersome by design, so
   the primary release path is: don't overfund.

## 6. Engine integration

`PerpEngineTradingV2.setClearingAccount(address)` — additional gate:

```solidity
if (newClearing == address(0)) revert ZeroAddress();
if (newClearing.code.length == 0) revert ClearingAccountInvalid();  // NEW
if (newClearing == owner)         revert ClearingAccountInvalid();
if (newClearing == address(this)) revert ClearingAccountInvalid();
if (newClearing == matchingEngine)revert ClearingAccountInvalid();
if (newClearing == feeRecipient)  revert ClearingAccountInvalid();
```

The `code.length > 0` check is set-time; Solidity 0.8.30 makes it
durable (post-Cancun SELFDESTRUCT no longer reduces code.length for
newly-deployed contracts).

Engine behavior otherwise unchanged from
`PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1`:
- per-side realized PnL settlement;
- debit-negatives-first, single balance-check, then credit positives;
- `ClearingLiquidityInsufficient` atomic revert on shortfall;
- V1 bad-debt intercept via `_routeIncomingCashflowWithDebtFirst` for
  positive credits.

## 7. Authority isolation

- **Clearing self-drain**: impossible — no code path in
  `PerpClearingAccountV2` calls any Vault drain function.
- **Traders impersonating clearing**: impossible — only the contract's
  own bytecode can produce a call with `msg.sender = clearing`, and
  that bytecode contains no drain call.
- **V1 draining V2 clearing after V1 auth is revoked**: impossible —
  once `setAuthorizedEngine(V1, false)` is called, V1 fails the
  `onlyMarginEngine` gate on `transferBetweenAccounts`.
- **V2 mutating arbitrary balances**: bounded by existing V2 settlement
  rules (per-side realized PnL, position/margin checks). No new
  Vault privileges are granted to V2 by this milestone.

**Future migration ordering (must be observed):**

1. Freeze V1 (pause trading + close-only on all V1 markets).
2. Deploy `PerpClearingAccountV2` bound to the existing CollateralVault.
3. Deploy `PerpEngineV2` + `PerpMatchingEngineV2`.
4. `Vault.setAuthorizedEngine(V2, true)`.
5. Pre-fund clearing via `fundClearing` from governance.
6. Point backend at V2 engine + matching + domain "2".
7. Snapshot V1 positions.
8. `V2.adminSeedPosition(...)` per position (future milestone
   `PERPS_V2_MIGRATION_SEED_HOOK_V1`).
9. `V2.sealAdminSeeding()`.
10. **`Vault.setAuthorizedEngine(V1, false)`** — the moment beyond which
    V1 cannot drain clearing or mutate any position.
11. Unpause V2.

Between step 4 and step 10 both engines are Vault-authorized. During
that window, V1 remains frozen (step 1) so no trades run through V1's
engine authority. This is the required invariant.

## 8. Unit test coverage (§8)

`test/perp/PerpClearingAccountV2Security.t.sol` — **19/19 PASS**.

| # | Test | Coverage |
|---|---|---|
| 1 | canonical `fundClearing` succeeds | §3 flow |
| 2 | funded amount at exact Vault account | balance accounting |
| 3 | ordinary user cannot withdraw clearing | drain resistance |
| 4 | clearing has no withdraw surface | ABI surface proof |
| 5 | clearing cannot arbitrarily transfer trader funds | `onlyMarginEngine` gate |
| 6 | unauthorized engine cannot debit clearing | vault ACL |
| 7 | authorized V2 can debit clearing | positive credit path |
| 8 | authorized V2 can credit clearing | negative debit path |
| 9 | insufficient clearing → atomic revert | `ClearingLiquidityInsufficient` |
| 10 | fees remain independent of clearing | fee-routing invariant |
| 11 | zero-address clearing refused | `ZeroAddress` |
| 12 | non-contract clearing refused | §6 `code.length` gate |
| 13 | repeated funding accumulates | additive semantics |
| 14 | no residual ERC20 approval | `forceApprove(0)` hygiene |

## 9. Adversarial coverage (§9)

Same file, additional adversarial tests — **all PASS**:

- direct `Vault.withdraw` from random EOA cannot touch clearing;
- direct `Vault.transferBetweenAccounts` from random EOA rejected;
- self-transfer to same account rejected by vault;
- reentrancy via ERC777/hook-token during `fundClearing` is benign
  (no state to corrupt; balance correct post-callback);
- no emergency-recovery function exists (six common signature guesses
  all revert as expected).

## 10. Read-only solvency interface

The engine already exposes what an operator needs:

```solidity
address public clearingAccount;                              // configured id
vault.balances(clearingAccount, settlementAsset) returns uint256;  // current bal
```

No new read surface added. Off-chain solvency policy computes the
recommended floor per market cap (see
`docs/PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1.md` §14 — clearing-solvency
model) and monitors it. No on-chain automatic top-up. No socialized
loss. Insurance ≠ clearing (already established).

## 11. Preserved economic tests

All prior V2 tests updated to use the hardened `PerpClearingAccountV2`
and re-run:

- `test/perp/PerpEngineV2Cashflow.t.sol` — **24/24 PASS**
  (Base-Sepolia 244_274 regression, close matrix A-S, §11 asymmetric
  basis, §12 temporal liquidity, insufficient clearing atomic revert,
  liquidation 1×, admin gates).
- `test/fuzz/perp/PerpEngineV2Fuzz.t.sol` — **7/7 PASS** (256 runs each
  = 1792 iterations; 12 invariants covered).
- `test/matching/PerpMatchingEngineV2Domain.t.sol` — **3/3 PASS**
  (EIP-712 replay separation).

## 12. Full Solidity suite

```
Ran 108 test suites in 507.53s: 1593 tests passed, 0 failed, 0 skipped
```

## 13. Future deployment dependency graph

```
CollateralVault           <-- pre-existing
    ^
    |
    +--- PerpClearingAccountV2(vault)                [NEW; single arg]
    |
    +--- PerpEngineV2(owner, registry, vault, oracle)
    |        |
    |        +-- setMatchingEngine(PerpMatchingEngineV2)
    |        +-- setRiskModule(riskModule)
    |        +-- setFeesManagerV2(feesManagerV2)     [optional]
    |        +-- setInsuranceFund(insuranceFund)     [optional; needed for liquidations]
    |        +-- setClearingAccount(PerpClearingAccountV2)
    |
    +--- PerpMarketRegistry   <-- pre-existing
```

Constructor args:
- `PerpClearingAccountV2(address _vault)`
- `PerpEngineV2(address _owner, address registry_, address vault_, address oracle_)`
- `PerpMatchingEngineV2(address _owner, address _engine)`

Ownership matrix (post-deployment):

| Contract | owner / admin |
|---|---|
| CollateralVault | existing governance (unchanged) |
| PerpMarketRegistry | existing governance (unchanged) |
| PerpEngineV2 | governance (via `PerpEngineAdmin` 2-step) |
| PerpMatchingEngineV2 | governance (via 2-step) |
| PerpClearingAccountV2 | **NO OWNER** — immutable, no admin surface |

## 14. Migration compatibility

- Positions: preserved by future `adminSeedPosition` hook (own milestone).
- Vault balances: preserved unconditionally — V2 does not migrate trader
  balances, they remain in the shared CollateralVault.
- Clearing liquidity: seeded independently by governance via
  `fundClearing`, before V1 is deauthorized.
- Sealed migration: future milestone `PERPS_V2_MIGRATION_SEED_HOOK_V1`.
- V1 revocation: single `Vault.setAuthorizedEngine(V1, false)` call.
- V2 enable: unpause trading on V2.

No interface changes required in this milestone to enable the migration.

## 15. Follow-up milestones

- `PERPS_V2_MIGRATION_SEED_HOOK_V1` — `adminSeedPosition` +
  `sealAdminSeeding` on `PerpEngineV2` (position migration).
- `PERPS_V2_CLEARING_EMERGENCY_RECOVERY_V1` — optional pause-first
  governance-gated emergency clearing drain (only if operational need
  emerges).
- `PERPS_V2_BASE_SEPOLIA_DEPLOY_V1` — first real testnet deployment;
  runs the §7 sequence; closes the outstanding A/B positions at mark.
- `PERPS_V2_MAINNET_READINESS_AUDIT_V1` — external audit gate before
  any mainnet exposure.
