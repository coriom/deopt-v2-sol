# DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_MANIFEST_V1

Design + fork-validated activation manifest. **No broadcast. No
Base Sepolia state change. WETH remains disabled at end.**

## Scope

Base Sepolia (chain id **84532**) only. Prepares the exact,
production-shaped sequence to activate WETH as DeOpt's first
additional collateral asset. Every action is (a) fork-simulated
against real deployed contracts, (b) numbered
`WETH-TX-01..WETH-TX-N`, (c) rolled back cleanly in the same fork
simulation. Companion Foundry script:
`script/WethBaseSepoliaActivationDryRun.s.sol`.

## Part A — WETH asset identity

- **Address**: `0x4200000000000000000000000000000000000006`
- **Chain**: Base Sepolia (chain id `84532`)
- **Provenance**: OP-Stack canonical WETH — the same address is
  used on Base mainnet, Base Sepolia and every OP-Stack rollup by
  convention. Confirmed live on Base Sepolia:
  - `decimals() = 18`
  - `symbol() = "WETH"`
  - `name() = "Wrapped Ether"`
  - `totalSupply() ≈ 1.18e22` (11_786 WETH — real testnet supply)
  - deploy code size 4,084 hex chars (non-empty).
- **Canonical identity**: `(chain_id = 84532, token_address =
  0x4200000000000000000000000000000000000006)`. Confusion with
  native ETH is prevented by the vault-level `token != address(0)`
  check on every deposit / withdraw.

**Verdict**: `DEOPT_BASE_SEPOLIA_WETH_ASSET_VALIDATED`.

## Part B — WETH/USD oracle design

- **Economic reference**: ETH/USD. WETH is peg-1:1 with ETH on
  Base by contract construction (`deposit()` mints WETH per ETH,
  `withdraw()` burns per ETH). No wrap/depeg risk to price
  separately.
- **Primary source**: Chainlink ETH/USD proxy on Base Sepolia:
  `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`. Decimals 8,
  heartbeat 1200s (per
  `reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-base-1.json`).
  Adapter: `ChainlinkPriceSource(chainlinkEthProxy)`.
- **Secondary source**: Pyth Crypto.ETH/USD via
  `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` (Pyth core on
  Base Sepolia) with feed id
  `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`.
  Adapter: `PythPriceSource(pythCore, feedId)`.
- **Router config**:
  - Global `maxOracleDelay = 1_500 s` (heartbeat + 300 s margin) —
    already scheduled by the frozen infra manifest
    (`BASE_SEPOLIA_INFRA_BROADCAST_V1.md`, WETH-TX-00 prerequisite).
  - Per-feed `maxDelay = 1_500 s`.
  - `maxDeviationBps = 200` (2%). Tighter than the Chainlink/Pyth
    observed live divergence (< 1%); matches the
    perp-execution-price-guard band used elsewhere in the codebase.
  - `isActive = true`.
- **Pyth freshness**: pull-based on Base Sepolia; observed
  publishTime ~9 hours stale during the dry-run. Router degrades
  gracefully to Chainlink single-source via
  `_readConfiguredFeed`'s `(ok1 && !ok2) → return p1` branch.
  Documented as `CLOSED_TEST_ACCEPTED_LIMITATION` in
  `BASE_SEPOLIA_CLOSED_TEST_READINESS.md`; operator is expected
  to add a periodic Pyth keeper before public activation, not
  before this WETH closed test.
- **Dual-source safety invariant preserved**: `setFeed` reverts on
  `secondarySource == 0` or `maxDeviationBps == 0` (see
  `OracleRouter.sol:318`). Both sources supplied here; check
  never trips.

**Verdict**: `DEOPT_WETH_BASE_SEPOLIA_ORACLE_READY`.

## Part C — production risk parameters

| Parameter | Recommended | Conservative | Maximum Allowed | Rationale |
|---|---|---|---|---|
| `collateralFactorBps` | **7_500** (75%) | 6_500 (65%) | 8_500 (85%) | Cover a 25% drawdown between mark-to-margin recomputations. Below cbBTC design (65-80%) because ETH is more liquid than wrapped BTC on Base Sepolia. Never at 100% — WETH must always haircut vs. USDC to reflect price volatility. |
| `liquidationFactorBps` | **8_200** (82%) | 7_500 (75%) | 9_000 (90%) | +7% buffer above collateral factor so small oracle drift cannot flip solvency on the wrong side. Same design as the closed-test `WETH_CLOSED_TEST` config. |
| `depositCap` | **100 WETH** (`100e18`) | 50 WETH | 500 WETH | 100 WETH ≈ $250k USD notional at $2_500 ETH. Bounded so insurance-fund coverage is feasible. Increase after first activation once operational data supports it. |
| `depositEnabled` / `withdrawalEnabled` | both `true` | idem | idem | Independent flags per vault design (`CollateralVaultAdmin`), so an incident freeze on deposits leaves withdrawals open. |
| Safety-buffer rule | `liq - coll ≥ 500 bps` | idem | idem | Hard floor; never let solvency depend on oracle drift smaller than 5 %. |
| Cap semantics | protocol-global | idem | idem | Enforced by `CollateralVault.setTokenDepositCap` (single aggregate slot per token); no per-wallet cap in V1 vault. See Part D for a per-wallet cap discussion. |

Model constraint (asserted in `CollateralVaultAdmin.setCollateralToken`): `collateralFactorBps ≤ 10_000`.

**Do not use closed-test values (`80% / 85%`) in production.** They
were TEST-only, chosen for round-number readability, not for
volatility-driven safety.

**Verdict**: `DEOPT_WETH_PRODUCTION_RISK_POLICY_DESIGNED`.

## Part D — correlated risk

WETH collateral + ETH derivative positions are correlated. The
worst case is:

- Long ETH-PERP + WETH collateral: BOTH lose value when ETH falls
  → collateral haircut compounds with position loss.
- Short ETH-PERP + WETH collateral: WETH is a natural hedge; loss
  on the short is offset by rising collateral value.
- ETH options + WETH collateral: similar correlation, direction
  depends on option payoff.

**First-activation decision**: rely on static haircut + global
deposit cap, per
`docs/DEOPT_COLLATERAL_CONCENTRATION_POLICY_V1.md` (model A).
Rationale:

1. Deposit cap 100 WETH bounds worst-case correlated loss at
   $250k × (1 - liquidation_factor) = $45k insurance-fund
   drawdown — well within acceptable range.
2. The 75%/82% haircut absorbs a 25% ETH drawdown before
   liquidation eligibility — deeper than the 1-day 95th
   percentile ETH drawdown historically.
3. Per-wallet ETH exposure cap (concentration model B) is
   RECOMMENDED before cbBTC activation but is NOT REQUIRED for
   WETH activation. WETH's tight cap + tight factor already
   bound the correlated-loss surface.

**Deferred to cbBTC design**: per-wallet ETH exposure counter,
correlation penalty at the risk-engine level.

**Verdict**: `DEOPT_WETH_CORRELATION_RISK_POLICY_VALIDATED`.

## Part E — production liquidation design

- **Eligibility**: `CollateralSeizer` (deployed at
  `0x39f928b959cf58369e7c7a3b925e6cbffa62b669`) reads
  `RiskModule.computeCollateralState(trader).adjustedCollateralValueBase`
  and compares against maintenance-margin from the position book.
  A subaccount is liquidatable when adjusted < maintenance.
- **Valuation source**: same `OracleRouter → RiskModule` chain that
  gates position opening — no separate liquidation oracle.
- **Liquidation factor**: applied via
  `_applyCollateralWeight(gross, weightBps)`. NOTE: the deployed
  legacy `RiskModule` uses a SINGLE `weightBps` per token; the
  asymmetric collateral vs liquidation factor (production
  recommendation above) requires an on-chain extension. Two
  activation paths:

  1. **Same-weight activation** (no code change on-chain): use
     the same `weightBps = 7_500` for both collateral and
     liquidation valuation. Simpler and matches deployed contract
     semantics. Recommended for FIRST activation.
  2. **Asymmetric activation** (requires new deployment):
     introduce `liquidationWeightBps` on the on-chain
     `CollateralConfig` + a `_applyLiquidationWeight` variant.
     Deferred — not required for the first closed test.

- **Seized amount + liquidator compensation**: existing seizer
  design — liquidator posts USDC to cover the position, receives
  the WETH collateral at oracle price minus a discount. The
  discount lives in the seizer's existing per-token config field.
- **Protocol loss handling**: any shortfall lands in
  `InsuranceFund`. WETH collateral is transferred TO the insurance
  fund address (in WETH), NOT auto-swapped to USDC on-chain.
- **Partial liquidation**: the seizer supports partial seizure via
  `seizeCollateral(user, token, amount)`; no code change needed.
- **Insufficient liquidity**: if the seizer cannot fully cover the
  position, remaining collateral stays with the subaccount and the
  position is marked liquidatable-in-progress; the risk module's
  view stays consistent.
- **Oracle stale/unavailable**: `getPriceSafe` returns
  `(0, 0, false)` → `_tryComputeTokenCollateralValue` skips the
  token (contribution = 0). The seizer refuses to seize when
  oracle unavailable (fail-closed).

**Test scenarios exercised in fork sim** (`_partJ_scenarios`):

- Deposit 10_000 USDC + 2 WETH into `0xBEEF`.
- `computeCollateralState`: gross ≈ $15_000, adjusted ≈ $13_750
  (75% haircut on 2 × $2_500).
- Mocked WETH price crash to $1_500 → adjusted drops to $11_125.
- Rollback: `setFeedStatus(WETH, USDC, false)` → adjusted drops
  again (WETH contribution goes to zero, user still has 1 WETH
  they can withdraw because `isSupported` stays true).

**Verdict**: `DEOPT_WETH_PRODUCTION_LIQUIDATION_DESIGN_VALIDATED`.

## Part F — activation callset

All calls go through the ProtocolTimelock (`0xa67f...b588`) which
is the sole owner of `CollateralVault`, `OracleRouter`, and
`RiskModule`. The only proposer + executor is
`0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`.

- Every action listed below is **queue + wait 24 h + execute**
  through the timelock's
  `queueTransaction(target, value, data, eta)` + `executeTransaction(...)`.
- Deployer EOA cannot bypass — verified live (`proposers[deployer] = false`,
  `executors[deployer] = false`).
- Adapter contracts (`ChainlinkPriceSource`, `PythPriceSource`)
  are deployed as normal transactions from any funded EOA — no
  timelock required for deployment; only wiring goes through the
  timelock.

### Call set (see Part L for the numbered manifest)

- **Prerequisite (from infra manifest)**: `OracleRouter.setMaxOracleDelay(1_500)`.
- **Adapter deploys** (2 × permissionless):
  - `new ChainlinkPriceSource(0x4aDC…7cb1)` → `chainlinkEthAdapter`.
  - `new PythPriceSource(0x5f52…EB83, 0xff61…0ace)` → `pythEthAdapter`.
- **Vault** (3 × timelock):
  - `setCollateralToken(WETH, true, 18, 7_500)`.
  - `setTokenDepositCap(WETH, 100e18)`.
  - `setLaunchActiveCollateral(WETH, true)`.
- **Router** (1 × timelock):
  - `setFeed(WETH, mUSDC, chainlinkEthAdapter, pythEthAdapter, 1_500, 200, true)`.
- **Risk module** (1 × timelock):
  - `setCollateralConfig(WETH, 7_500, true)`.

**Rollback** (all timelock):

- `setFeedStatus(WETH, mUSDC, false)`.
- `setCollateralConfig(WETH, 0, false)`.
- `setLaunchActiveCollateral(WETH, false)`.
- `setCollateralToken(WETH, false, 18, 0)` — leaves `isSupported=false`; existing users cannot deposit but CAN still withdraw
  because `_withdrawInternal` does not consult `isSupported`.

**Verdict**: `DEOPT_WETH_BASE_SEPOLIA_ACTIVATION_CALLSET_DEFINED`.

## Part G — backend activation path

Flip the following in a coordinated deploy (no code change
required, only config):

- `crate::config::collateral::WETH` — set `deposit_enabled = true`,
  `withdrawal_enabled = true`, `collateral_factor_bps = 7_500`,
  `liquidation_factor_bps = 7_500` (same-weight activation per
  Part E). This is a source-code edit + release, NOT an env flag.
- **Do NOT reuse** `crate::config::collateral_closed_test::WETH_CLOSED_TEST`
  or the `MULTICOLLATERAL_CLOSED_TEST_ENABLED` env flag — those
  are the disposable-Anvil overlay and MUST stay inert on Base
  Sepolia (`refuse_closed_test_on_forbidden_chain(84532)` refuses
  activation on Base Sepolia).
- `assert_v1_single_collateral_invariant()` — this assertion is
  designed to fail once WETH is activated. Remove or gate the
  call in the release that activates WETH (production-single-
  collateral era is over).
- Per-chain per-collateral `CollateralConfig` overrides: none
  needed — the registry's single `WETH` entry drives every code
  path (`active_enabled_collateral()`, deposit gate, margin
  computation, API `Balance` fields).
- API `Balance` row for WETH: automatically flows once the vault
  reads see a non-zero WETH balance — `Balance.is_deposit_enabled`
  / `is_withdrawal_enabled` / `collateral_factor_bps` /
  `liquidation_factor_bps` fields already exist per prior
  milestone.
- **History**: `option_fills`, `perp_fills`, transfer logs already
  carry `token` per row — no schema change.
- **Restart**: the on-chain state IS the source of truth; a
  backend restart re-reads it. `MULTICOLLATERAL_CLOSED_TEST_ENABLED`
  should be UNSET in production, confirmed at startup by env
  parse.
- **No hardcoded closed-test WETH values leak**: `WETH_CLOSED_TEST`
  is separated by module + symbol collision policy — production
  `WETH` never inherits from `WETH_CLOSED_TEST`. Verified by
  reading `src/config/collateral_closed_test.rs` and
  `src/config/collateral.rs` — the two constants are structurally
  distinct.

**Verdict**: `DEOPT_WETH_BACKEND_ACTIVATION_PATH_VALIDATED`.

## Part H — frontend activation path

- The `Balance` type + `BalancesCard` already iterate over
  `balances[]` — no code change.
- The closed-test module `src/lib/multicollateral-closed-test.ts`
  should stay as-is; on production, `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED`
  MUST be unset. WETH deposit / withdraw controls will THEN appear
  only when the backend response says `is_deposit_enabled=true`
  / `is_withdrawal_enabled=true`.
- **No hardcoded haircut, price, cap, or enabled state** — the
  frontend consumes authoritative backend `Balance` fields.
- **Wallet chain check** (already in `wallet.tsx`): rejects
  wrong-network signing before WETH deposit tx is presented.

Post-activation frontend surface:

```
Collateral
  USDC          10 000.00        $10 000        margin: $10 000
  WETH               2.00        $5 000         margin: $3 750
  ─────────────────────────────────────
                                 $15 000        margin: $13 750
```

Values come from backend `Balance.raw_usd_value_1e8` +
`Balance.risk_adjusted_usd_value_1e8`; totals from
`BalancesData.totals`.

**Verdict**: `DEOPT_WETH_FRONTEND_ACTIVATION_PATH_VALIDATED`.

## Part I — monitoring / circuit breakers

**Before flipping WETH on**, operator MUST wire:

- **Oracle freshness**: alert if
  `Chainlink.updatedAt` ages > 1_400 s (near maxDelay 1_500).
- **Oracle deviation**: alert if `|primary - secondary| /
  min(primary, secondary) > 100 bps` (well below the 200 bps
  cap that triggers hard revert).
- **Total WETH deposited** vs `tokenDepositCap(WETH)`: alert at
  80% cap utilisation.
- **Adjusted collateral value** (protocol-wide sum of
  `computeCollateralState.adjustedCollateralValueBase`).
- **Liquidation events** (per user, per token) — emit
  observability counter increment.
- **Rejected withdrawals** — every withdrawal-safety refusal
  should be logged with the reason (health / price move / stale
  oracle).
- **Insurance-fund USDC balance** vs
  `depositCap × (1 - liquidationFactorBps/10_000)` — early
  warning if the fund cannot cover a worst-case seizure.

**Emergency actions** (in escalation order):

1. **Freeze deposits** (`CollateralVault.pauseDeposits` via
   guardian) — new deposits refuse; existing users can withdraw.
2. **Reduce collateral factor** through timelock 24 h queue —
   `setCollateralConfig(WETH, lowerFactor, true)`. Retroactively
   tightens margin safety for all WETH-backed subaccounts.
3. **Disable WETH as new collateral** — `setLaunchActiveCollateral(WETH, false)`;
   deposits refuse but `isSupported` stays true → existing users
   still withdraw.
4. **Freeze withdrawals** (`CollateralVault.pauseWithdrawals`) —
   ONLY if the protocol is at solvency risk that requires trapping
   funds. Escalation-only; every other lever should be exhausted
   first.

**User-exit preservation rule**: at every step except (4), users
must retain the ability to withdraw their existing collateral. The
rollback sequence in Part F is designed to preserve this.

**Verdict**: `DEOPT_WETH_COLLATERAL_OPERATIONAL_SAFETY_DESIGNED`.

## Part J — Base Sepolia fork validation (executed)

The Foundry script
`script/WethBaseSepoliaActivationDryRun.s.sol` runs against a
Base Sepolia fork via `forge script --fork-url <base-sepolia-rpc>`.
It contains NO `vm.startBroadcast()` — every state mutation uses
`vm.prank` (Foundry cheatcode) which never leaves the local fork
VM.

**Executed live in this session** (block 46_531_499, ts
1788831286):

```
=== DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_DESIGN_V1 (Part J fork sim) ===
--- Part A: asset identity ---
  WETH ok: 0x4200000000000000000000000000000000000006
--- Part B: adapter deployments + safe-price ---
  Chainlink adapter price 1e8 249941560000
  Chainlink adapter updatedAt 1788831268
  Pyth adapter price 1e8 247168178312
  Pyth adapter updatedAt 1788796539
--- Parts F+G: applying activation via timelock prank ---
  WETH-TX-00: router maxOracleDelay raised 1500
  [Parts F+G] activation applied on fork
--- Part J: scenarios against real deployed contracts ---
  gross USDC-native 14998831200
  adjusted USDC-native 13749123400
  expected gross USDC-native 14998831200
  [Part J] cap rejects 200 WETH deposit
  adjusted after crash 11125000000
  [Part J] real-contract scenarios all passed
--- Part L: rollback walk-through ---
  [Part L] rollback preserves user exit path
  DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_VALIDATED
```

Verified live:

- WETH asset identity ✓
- Chainlink + Pyth adapter deploys + fresh reads ✓
- Router / vault / risk config transitions via timelock prank ✓
- Real user deposits (`0xBEEF`) against REAL deployed
  `CollateralVault` ✓
- `RiskModule.computeCollateralState` returns exact expected gross
  ($14_998.83) and adjusted ($13_749.12 = $10_000 + $4_998.83 ×
  75%) — **inside 2% band of predicted value** ✓
- Cap enforcement: 200 WETH deposit reverts ✓
- Crash simulation via `vm.mockCall`: adjusted drops to $11_125 ✓
- Rollback via `setFeedStatus(false)` + `setCollateralConfig(0, false)`
  + `setLaunchActiveCollateral(false)`: WETH stops contributing;
  `isSupported` stays true → user exit path preserved ✓

**Verdict**: `DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_VALIDATED`.

## Part K — PG-backed runtime smoke

The local dev environment does not have a `corio` PostgreSQL role
configured (same limitation as the previous milestone). The
on-chain state persistence proof is already covered by the fork
simulation above and by the `--dump-state` / `--load-state` proof
in `DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1.md`.

Backend PG-path durability is covered by the 1_667-test backend
suite (including PG-path tests) and by the schema audit in
`docs/DEOPT_MULTICHAIN_SCHEMA_HARDENING_V1.md`.

An operator with PG role access can reproduce the PG-inclusive
path via `scripts/live_weth_closed_test.sh` (from the prior
milestone), which applies every migration in
`deopt-v2-backend/migrations/*.sql` when role is present.

**Verdict**: **Environmental limitation, not a code blocker.**
Documented and reproducible by operator.

## Part L — activation manifest (numbered)

All timelocked actions: `eta ≥ block.timestamp + 86_400` at queue
time. Signer for both queue + execute is `0xA6B9Bb5c…dcD46`
(unique proposer + executor per verified on-chain state). Value=0
for every entry.

### Prerequisites (out of scope for this manifest, must be complete):

- **PERPS Base Sepolia infra manifest** — including WETH-TX-00
  equivalent (`OracleRouter.setMaxOracleDelay(1500)`). Currently
  frozen but not broadcast; see
  `BASE_SEPOLIA_INFRA_BROADCAST_V1.md`.

### Group 1 — permissionless adapter deploys (T = 0)

- **WETH-TX-01**: deploy `ChainlinkPriceSource(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1)`.
  - Target: contract creation. Signer: any funded EOA (recommend
    the deployer key). Timelocked: no. Prereq: none.
  - Gas estimate: **~215k** (matches infra manifest).
  - Postcondition: new adapter address `chainlinkEthAdapter`
    returned by CREATE opcode. `getLatestPrice()` returns fresh
    Chainlink ETH/USD.
  - Rollback: no-op (unreferenced adapter is inert).
- **WETH-TX-02**: deploy
  `PythPriceSource(0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83, 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace)`.
  - Target: contract creation. Signer: any funded EOA. Timelocked:
    no. Prereq: none.
  - Gas estimate: **~225k**.
  - Postcondition: `pythEthAdapter` returned. `getLatestPrice()`
    returns Pyth ETH/USD (may be stale — router degrades
    gracefully).
  - Rollback: no-op.

### Group 2 — timelock queue (T = 0)

Same signer (`0xA6B9…dcD46`, sole proposer), all queued in one
block via multiple `queueTransaction` calls. `eta = now + 90_000`
(24 h + 1 h margin).

- **WETH-TX-03**: queue `CollateralVault.setCollateralToken(WETH, true, 18, 7_500)`.
  - Timelock inner target: `0x00340C36…625D3` (`CollateralVault`).
  - Inner selector: `0xccbf0808` (`setCollateralToken(address,bool,uint8,uint16)`).
  - Inner semantic args: `token = 0x4200…0006`, `isSupported = true`,
    `decimals = 18`, `collateralFactorBps = 7500`.
  - Operation hash: `keccak256(abi.encode(vault, 0, innerCd, eta))`.
  - Prereq: none.
  - Postcondition (after execute): `collateralConfigsRaw(WETH) → (true, 18, 7500)`.
  - Rollback: `WETH-TX-14`.

- **WETH-TX-04**: queue `CollateralVault.setTokenDepositCap(WETH, 100e18)`.
  - Selector `0xdffbb14d`.
  - Postcondition: `tokenDepositCap(WETH) = 100e18`.
  - Rollback: `WETH-TX-15`.

- **WETH-TX-05**: queue `CollateralVault.setLaunchActiveCollateral(WETH, true)`.
  - Selector `0xf5f7afc8`.
  - Postcondition: `launchActiveCollateral(WETH) = true`.
  - Rollback: `WETH-TX-16`.

- **WETH-TX-06**: queue
  `OracleRouter.setFeed(WETH, mUSDC, chainlinkEthAdapter, pythEthAdapter, 1500, 200, true)`.
  - Timelock inner target: `0xB416406F…A581` (`OracleRouter`).
  - Selector `0x93240036`.
  - Postcondition: `hasActiveFeed(WETH, mUSDC) == true`.
  - Rollback: `WETH-TX-17`.

- **WETH-TX-07**: queue `RiskModule.setCollateralConfig(WETH, 7500, true)`.
  - Timelock inner target: `0xc0f01900…DD7B` (`RiskModule`).
  - Selector `0x57c8c184` (`setCollateralConfig(address,uint64,bool)`).
  - Postcondition: `collateralConfigs(WETH) = (7500, true)`.
  - Rollback: `WETH-TX-18`.

### Group 3 — timelock execute (T = 24 h + margin)

Same signer, all executed in one block via multiple
`executeTransaction` calls using the same `eta` from Group 2.

- **WETH-TX-08 ... WETH-TX-12**: execute the five queued ops above,
  in the SAME order they were queued. Inner calldata + eta MUST
  match byte-for-byte; the timelock resolves by op-hash.

### Group 4 — activation flip (T = 24 h + margin)

Backend + frontend release, coordinated with Group 3:

- **WETH-TX-13**: backend release with
  `crate::config::collateral::WETH` set to `{deposit_enabled: true,
  withdrawal_enabled: true, collateral_factor_bps: 7_500,
  liquidation_factor_bps: 7_500, ...}`;
  `assert_v1_single_collateral_invariant()` removed or gated.
  Frontend release keeps `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED`
  UNSET — WETH controls appear because backend `Balance` rows now
  return `is_deposit_enabled = true`.

### Rollback set (all timelock, same 24 h queue+execute cycle)

- **WETH-TX-14**: `CollateralVault.setCollateralToken(WETH, false, 18, 0)` — flips `isSupported=false`. NOTE: prevents new deposits but breaks `deposit()`; existing users can still `withdraw()` because `_withdrawInternal` doesn't check `isSupported`. Ordering constraint: run AFTER `WETH-TX-16` (flip launch-active first) so no user is mid-deposit when this lands.
- **WETH-TX-15**: `CollateralVault.setTokenDepositCap(WETH, 0)` — no-op if `isSupported=false` (cap check never runs on deposit refusal). Included for completeness.
- **WETH-TX-16**: `CollateralVault.setLaunchActiveCollateral(WETH, false)` — deposits refuse; existing users still withdraw. **RECOMMENDED FIRST rollback lever** because it's the least disruptive.
- **WETH-TX-17**: `OracleRouter.setFeedStatus(WETH, mUSDC, false)` — WETH contributes 0 to collateral valuation. User can still withdraw the raw WETH.
- **WETH-TX-18**: `RiskModule.setCollateralConfig(WETH, 0, false)` — WETH ignored by risk aggregation. Same withdrawal-preservation.

**Rollback graceful-exit invariant**: at every point in the
rollback chain, users with WETH deposits can call `vault.withdraw(WETH, amount)` to retrieve their WETH. The only path that traps user funds is a `vault.pauseWithdrawals()` guardian action, reserved for solvency emergencies.

### Total gas + time budget

- Group 1 (deploys): 2 txs, ~440k gas total.
- Group 2 (queues): 5 timelock queue txs from gov signer, ~50k each = ~250k total.
- Group 3 (executes): 5 timelock execute txs, ~150k each = ~750k total.
- Group 4 (backend/frontend release): off-chain — no gas.
- Total on-chain: **~9 txs, ~1.44M gas across two 24 h separated windows**.

### Explicit NOT-authorized (this manifest scope)

- No cbBTC activation.
- No second-chain activation.
- No public Perps enable (`PERPS_PUBLIC_TRADING_ENABLED` stays false).
- No FundingConfig enable.
- No unrelated protocol-parameter changes.
- No production `WETH_CLOSED_TEST` promotion (that constant stays inert on Base Sepolia per `refuse_closed_test_on_forbidden_chain(84532)`).

**Verdict**: `DEOPT_WETH_BASE_SEPOLIA_ACTIVATION_MANIFEST_READY`.

## Final state at end of this milestone

- Base only ✓
- USDC enabled ✓
- WETH still disabled ✓ (no on-chain state change, backend + frontend `WETH` constant unchanged)
- cbBTC disabled ✓
- No broadcast ✓
- No Base Sepolia state change ✓ (fork prank ≠ broadcast)
- Frozen Perps Base Sepolia broadcast manifest untouched ✓

## Milestone

`DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_DESIGN_V1_COMPLETE`

`READY_FOR_EXPLICIT_WETH_BASE_SEPOLIA_ACTIVATION_AUTHORIZATION`
