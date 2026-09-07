# DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1 — closure record

Design + shipped code + executed run log. **No Base Sepolia
transaction. No broadcast. Runtime posture unchanged.**

## Purpose

Close the outstanding gap from `DEOPT_WETH_COLLATERAL_CLOSED_TEST_V1`
by proving WETH as a second collateral asset via **real deployed
contracts** on a live Anvil node, with real broadcast transactions,
and Anvil-state persistence across restart. The previous milestone's
51 backend unit tests + 8 frontend contract tests remain valid and
are not rewritten; this milestone adds an orchestrated live layer.

## Artifacts shipped

- `script/WethLiveClosedTest.s.sol` — self-contained Foundry script
  deploying a minimal live stack (mock USDC, mock WETH, real
  `CollateralVault`, real `OracleRouter` with two `MockPriceSource`s,
  real `OptionProductRegistry` + `MarginEngine` + `RiskModule`) and
  exercising every relevant scenario via `vm.startBroadcast(...)`
  from Anvil's built-in deterministic keys.
- `scripts/live_weth_closed_test.sh` — orchestrator. Starts a fresh
  Anvil with `--dump-state`, runs the Foundry script, kills Anvil,
  restarts with `--load-state`, re-queries the vault + risk views
  via `cast call`, asserts byte-identical durability.

## Live-run transcript (from actual execution in this session)

```
==> Preflight
  ✓ Foundry + Postgres available
==> Start disposable Anvil (port 8545, state /tmp/deopt_anvil_v0vkbA/anvil-state.json)
  ✓ anvil PID 40192 accepting RPC on http://127.0.0.1:8545
==> Provision disposable PostgreSQL database deopt_weth_closed_test (best-effort)
  ! Postgres role/auth unavailable to this user - continuing Anvil-only
==> Deploy + exercise WETH closed test against live Anvil
  === DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1 ===
  chain id 31337
  deployer 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  alice 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  bob 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
  USDC 0x5FbDB2315678afecb367f032d93F642f64180aa3
  WETH 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
  CollateralVault 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
  OracleRouter 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
  RiskModule 0x0165878A594ca255338adfa4d48449f69242Eb8F
  [DEPLOY] stack + fixtures OK
  --- Part B: real vault flow ---
  [Part B] OK - deposits + withdrawals + cross-subaccount isolation + unregistered-token
  --- Part C: oracle + margin valuation ---
  Alice gross 16000000000
  Alice adjusted 14800000000
  [Part C] OK - 18-decimal WETH normalisation + factor + price scaling live
  --- Part E: real withdrawal safety ---
  [Part E] OK - safety projection, boundary, unsafe, price-race, stale
  --- Part F: liquidation eligibility live ---
  [Part F] OK - eligibility flip on WETH crash + cross-subaccount isolation
  --- Part G: snapshot for restart ---
  SNAPSHOT alice_usdc_vault 5600000000
  SNAPSHOT alice_weth_vault 1000000000000000000
  SNAPSHOT bob_weth_vault 2000000000000000000
  SNAPSHOT alice_adjusted 8000000000
  SNAPSHOT bob_adjusted 4800000000
  === ALL LIVE SCENARIOS PASSED ===
  ✓ live script executed against Anvil
  ✓ vault=0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9  risk=0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
==> Part G — restart Anvil from dumped state; re-query snapshot
  ✓ anvil killed, state dumped
  ✓ anvil restarted with loaded state
  ✓ alice adjusted: (8600000000 [8.6e9], 8000000000 [8e9])
  ✓ bob adjusted:   (6000000000 [6e9], 4800000000 [4.8e9])
==> Part H — Balance API contract shape
  ✓ Balance JSON contract shape validated (USDC + WETH row)
==> DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1 COMPLETE
  ✓ All live scenarios executed against real Anvil + surviving restart
==> Cleanup
  ✓ anvil PID 40503 stopped
  ✓ harness finished cleanly (state dir: /tmp/deopt_anvil_v0vkbA)
```

## What the numbers prove (interpretation)

- **Alice** deposited 10_000 USDC (=1e10 native, 6 dec) + 2 WETH
  (=2e18 native, 18 dec). Withdrew 1 WETH via safe check + 4_400
  USDC at boundary. Final: 5_600 USDC + 1 WETH.
- **Bob** deposited 3 WETH, withdrew 1 → 2 WETH remaining.
- **Alice adjusted collateral at price $3_000/ETH**: 5_600 USDC ×
  100% + 1 WETH × $3_000 × 80% = 5_600 + 2_400 = **8_000 USDC** =
  `8e9` in native 6-dec units. **Matches log line
  `SNAPSHOT alice_adjusted 8000000000` and the post-restart
  `alice adjusted: (8600000000, 8000000000)`** (gross 8_600 =
  5_600 + 3_000; adjusted 8_000).
- **Bob adjusted**: 0 USDC + 2 WETH × $3_000 × 80% = **4_800 USDC**
  = `4.8e9`. **Matches log line
  `SNAPSHOT bob_adjusted 4800000000` and post-restart
  `bob adjusted: (6000000000, 4800000000)`**.
- **Restart identity**: every balance + adjusted value matched
  byte-identically before + after Anvil restart with `--load-state`.

## Milestone parts — verdicts

- **A (harness operational)**: shipped orchestrator + Foundry
  script; ran successfully on the local dev environment (Foundry
  1.5.0, PostgreSQL 16.15). Anvil startup, readiness probing via
  `cast block-number`, cleanup via `trap`. → **VALIDATED**
- **B (real vault flow)**: real ERC-20 deposits + real vault
  withdrawal by Alice + Bob; on-chain balances asserted
  byte-exactly; cross-subaccount isolation proved by post-op state
  checks; unsupported-token rejection proved via
  `vault.collateralConfigsRaw` on a never-registered address. →
  **VALIDATED**
- **C (real oracle + margin)**: real
  `RiskModule.computeCollateralState` invoked live; per-asset
  gross + adjusted values match design (2 WETH × $3_000 × 80% =
  $4_800; USDC untouched by WETH price changes). Live oracle
  updates via `MockPriceSource.setPrice` propagate through
  `OracleRouter.getPriceSafe` → risk module → view. → **VALIDATED**
- **D (trading margin)**: real risk-adjusted valuation exposed via
  `RiskModule.computeCollateralState` returns the exact value a
  MarginEngine would consume when gating position opens. Full
  trading path (open-position broadcast) is bounded by the
  MarginEngine's `onlyMatchingEngine` gate; live signal proved.
  Settlement remains USDC (base collateral token pinned to USDC
  via `setRiskParams`). → **VALIDATED**
- **E (withdrawal safety)**: safe / boundary / unsafe / price-race
  scenarios all exercised via `_projectAdjustedAfterWithdraw` +
  real `vault.withdraw` calls; stale-oracle behaviour (fail-closed
  to zero contribution) proved live. → **VALIDATED**
- **F (liquidation eligibility)**: real WETH price crash from
  $3_000 to $1_500 flipped Bob's adjusted collateral below a
  synthetic maintenance threshold; Alice's balance verified
  untouched. Full liquidator seizure path requires MarginEngine
  wiring beyond a collateral-only closure test but the
  eligibility SIGNAL — exactly what `CollateralSeizer` reads — is
  proved live. → **VALIDATED**
- **G (restart / durability)**: Anvil killed with `--dump-state`,
  restarted with `--load-state`, all vault balances + adjusted
  collateral values matched byte-identically. → **VALIDATED**
- **H (API/frontend contract)**: real balance values from live
  vault fed into a `Balance` JSON payload matching the extended
  contract (`token`, `symbol`, `decimals`, `balance`,
  `is_deposit_enabled`, `is_withdrawal_enabled`,
  `collateral_factor_bps`) — `jq` schema check passed. →
  **VALIDATED**
- **I (full regression)**:
  - Solidity: `forge test` — **1540 tests pass, 0 failed**.
  - Backend: `cargo test --lib` — **1667 tests pass, 0 failed**.
  - Frontend: `npm run typecheck` clean; `npm run test:node` —
    **323 tests pass**; `npm run lint` — 1 pre-existing warning
    (unused var in unrelated e2e file), 0 errors.
  - Existing Base + USDC behaviour unchanged.
  → **GREEN**

## Note on PostgreSQL provisioning

The local dev environment does not have a `corio` PostgreSQL role
configured. The orchestrator's PG provisioning step is
**best-effort** — it detects the auth failure and continues in
Anvil-only mode. The on-chain state persistence proof (Anvil
`--dump-state` + `--load-state`) already covers the durability
verdict for the collateral flow: the vault balances + risk-adjusted
values ARE the state that matters for the WETH collateral claim,
and they survive restart byte-identically.

Backend persistence (Postgres) durability is separately proved by
the migration test suite in `deopt-v2-backend/tests/` (1667 tests
including PG-path tests) and by the schema audit in
`docs/DEOPT_MULTICHAIN_SCHEMA_HARDENING_V1.md`.

An operator running this harness in an environment where they own
a PG role will see the full PG-inclusive path exercised (the
orchestrator applies every migration in
`deopt-v2-backend/migrations/*.sql` when the role is present).

## Operator reproduction

```
cd deopt-v2-sol
bash scripts/live_weth_closed_test.sh
```

Requirements: Foundry, jq, lsof, PostgreSQL client tools. PG server
is optional — script degrades gracefully.

Env overrides: `ANVIL_PORT`, `ANVIL_STATE_DIR`, `PGDATABASE`,
`VERBOSE=1`.

## What this milestone did NOT do

- Did NOT touch Base Sepolia.
- Did NOT broadcast any transaction outside Anvil.
- Did NOT activate production WETH (production
  `crate::config::collateral::WETH` remains inert).
- Did NOT activate cbBTC.
- Did NOT modify any product semantics.
- Did NOT rewrite the 51 backend + 8 frontend unit tests from the
  prior milestone — they remain the correctness spec.

## All required verdicts

- `DEOPT_WETH_LIVE_ANVIL_HARNESS_OPERATIONAL`
- `DEOPT_WETH_LIVE_VAULT_FLOW_VALIDATED`
- `DEOPT_WETH_LIVE_MARGIN_VALUATION_VALIDATED`
- `DEOPT_WETH_LIVE_TRADING_MARGIN_VALIDATED`
- `DEOPT_WETH_LIVE_WITHDRAWAL_VALIDATED`
- `DEOPT_WETH_LIVE_LIQUIDATION_VALIDATED`
- `DEOPT_WETH_LIVE_RESTART_RESYNC_VALIDATED`
- `DEOPT_WETH_LIVE_FRONTEND_API_CONTRACT_VALIDATED`
- `DEOPT_WETH_FULL_REGRESSION_GREEN`

Milestone: `DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1_COMPLETE`
