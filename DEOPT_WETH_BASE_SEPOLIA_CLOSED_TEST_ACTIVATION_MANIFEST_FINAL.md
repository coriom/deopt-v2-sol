# DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_ACTIVATION_MANIFEST_FINAL

---

## ⛔ NOT AUTHORIZED — SUPERSEDED BY DEFERRAL

**Status**: `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_BLOCKED_BY_IMMUTABLE_VAULT_GATING`

The 18 transactions (`WETH-TX-01` through `WETH-TX-18`) frozen in this
document are **NOT AUTHORIZED for broadcast** under any circumstance.

Milestone `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_RELEASE_CLOSURE_V1`
Part B audit determined that executing WETH-TX-03..07 would open WETH
collateral deposit + margin usage to every EOA on Base Sepolia — not
just the intended closed-test cohort — because the deployed
CollateralVault at `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` has
no per-caller allowlist and is immutable (no upgrade hook).

Base Sepolia WETH activation is **DEFERRED**. Closed-test coverage
continues on local Anvil (`DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1_COMPLETE`).

**The authorization sentence template at the bottom of this document
is REVOKED.** Issuing that sentence verbatim in any future directive
does NOT authorize broadcast; the deferral supersedes it.

See `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_DEFERRAL_V1.md` for the full
decision record, rationale, and future Vault V1.1 launch-control
design guidance.

The material below is retained as **historical design documentation
only** — every technical detail (addresses, calldata, risk parameters,
fork-sim numbers) remains accurate as an audit artefact but describes
work that will not be executed.

---

Freeze of the exact package required to activate WETH as a second
collateral **ONLY** for Base Sepolia (chain 84532) closed-test users.

- **Scope**: Base Sepolia only. No Base mainnet. No second chain.
- **Broadcast**: NONE performed during preparation. Broadcast is
  gated on the explicit authorization sentence at the end of this
  document.
- **Adjacent-product posture**:
  - cbBTC: DISABLED (unchanged).
  - Public Perps: OFF (unchanged; disabled at the route boundary).
  - Funding: OFF (unchanged).
  - Settlement/PnL: USDC only (unchanged, immutable in Solidity via
    `MarginEngineV2.QUOTE_TOKEN` and `OptionsRiskModuleV2.QUOTE_TOKEN`).
  - USDC collateral: remains supported (unchanged).

## Freeze pointers

| Component | Commit SHA | Working tree |
|-----------|------------|--------------|
| Solidity  | `9fa86ddf078d0d0e5059f4544917a37fe069dc9e` | clean |
| Backend   | `126a857addb765625a6576e2d55d7e735584a9cb` | clean |
| Frontend  | `9cd8dce1aad9686ddfe2893d0219123a690f1b25` | clean |

Design reference: `DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_MANIFEST_V1.md`
(this document freezes and supersedes only the transaction table and
operator sequence; the design analysis in V1 remains authoritative).

Fork simulation reference: `script/WethBaseSepoliaActivationDryRun.s.sol`
(runs against Base Sepolia via `--fork-url https://sepolia.base.org`,
pranks timelock, applies the full sequence, verifies postconditions).

Closed-test correctness proof reference:
- `deopt-v2-backend/src/risk/closed_test_flows.rs` (51 unit tests)
- `deopt-v2-frontend/tests/node/multicollateral-closed-test.contract.mjs`
  (8 contract tests)
- `deopt-v2-sol/script/WethLiveClosedTest.s.sol` +
  `deopt-v2-sol/scripts/live_weth_closed_test.sh` (live-Anvil closure
  proven in `DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1`).

---

## PART A — FROZEN 18-TX MANIFEST

### A.1 On-chain addresses (Base Sepolia 84532)

| Role | Address |
|---|---|
| CollateralVault | `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` |
| OracleRouter | `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` |
| RiskModule | `0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B` |
| ProtocolTimelock | `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` |
| Timelock signer (proposer + executor) | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` |
| WETH (Base Sepolia canonical) | `0x4200000000000000000000000000000000000006` |
| mUSDC (production collateral base) | `0x6eAe407f5640B006faC9965182e238582A3B412E` |
| Chainlink ETH/USD proxy | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |
| Pyth core | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` |
| Pyth ETH/USD feed id | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |

### A.2 Function selectors (frozen from live `cast sig`)

| Selector | Signature |
|---|---|
| `0xcd3b691c` | `setMaxOracleDelay(uint256)` |
| `0xccbf0808` | `setCollateralToken(address,bool,uint8,uint16)` |
| `0xdffbb14d` | `setTokenDepositCap(address,uint256)` |
| `0xf5f7afc8` | `setLaunchActiveCollateral(address,bool)` |
| `0x36a9da37` | `setFeed(address,address,address,address,uint256,uint256,bool)` |
| `0x23bcafc7` | `setFeedStatus(address,address,bool)` |
| `0x57c8c184` | `setCollateralConfig(address,uint64,bool)` |

### A.3 Deterministic inner-call calldata (queued via Timelock)

Where a calldata value is `<CHAINLINK_ADAPTER>` or `<PYTH_ADAPTER>`,
the value is derived from the receipt of the corresponding G1 deploy
transaction. This is NOT a placeholder in the "TBD" sense — it is a
frozen data-flow dependency (`address = keccak256(RLP([DEPLOYER, NONCE_AT_TX])[12:]`
for CREATE, or the CREATE2 address if the deployer chooses CREATE2).
The setFeed calldata (WETH-TX-06) is assembled at Phase-2 execute time
from the confirmed G1 receipts and the queued values MUST match.

**Prerequisite (WETH-TX-00)** — OracleRouter.setMaxOracleDelay(1500)

- Target: `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- Calldata: `0xcd3b691c00000000000000000000000000000000000000000000000000000000000005dc`
- Idempotent: no-op if router already reports `maxOracleDelay >= 1500`.

**WETH-TX-03 inner** — CollateralVault.setCollateralToken(WETH, true, 18, 7500)

- Target: `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3`
- Calldata: `0xccbf08080000000000000000000000004200000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000001d4c`
- keccak256(calldata): `0x9e674d8185516f97d3a221956a33634ac857f3f9b5540d36bee2c88fe3947809`

**WETH-TX-04 inner** — CollateralVault.setTokenDepositCap(WETH, 100e18)

- Target: `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3`
- Calldata: `0xdffbb14d00000000000000000000000042000000000000000000000000000000000000060000000000000000000000000000000000000000000000056bc75e2d63100000`
- keccak256(calldata): `0x6cf236641e469acc675eab98ba222effa0a301e8e08901ca2a6ec0c93e7a4572`

**WETH-TX-05 inner** — CollateralVault.setLaunchActiveCollateral(WETH, true)

- Target: `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3`
- Calldata: `0xf5f7afc800000000000000000000000042000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000001`
- keccak256(calldata): `0x5b55caf362b23fa152a152069ed242b5231359e7c0766b3504da198a3d15d4ea`

**WETH-TX-06 inner** — OracleRouter.setFeed(WETH, mUSDC, <CHAINLINK_ADAPTER>, <PYTH_ADAPTER>, 1500, 200, true)

- Target: `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- Assembly: `abi.encodeCall(OracleRouter.setFeed, (0x4200…0006, 0x6eAe…412E, <CHAINLINK_ADAPTER>, <PYTH_ADAPTER>, 1500, 200, true))`
- Adapters are the results of WETH-TX-01/02 respectively (constructor args frozen below).
- keccak256(calldata): computed at Phase-2 preparation, MUST be re-verified
  against the value queued at Phase-1 before execute.

**WETH-TX-07 inner** — RiskModule.setCollateralConfig(WETH, 7500, true)

- Target: `0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B`
- Calldata: `0x57c8c18400000000000000000000000042000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000001d4c0000000000000000000000000000000000000000000000000000000000000001`
- keccak256(calldata): `0x40d146473514d5ade1a1db836bc05ae2db0bbc91a864d99784a5a30052ba60d5`

### A.4 The 18-transaction table

| # | Phase | Target | Function | Semantic params | Signer | Timelock dep | ETA | Gas | Postcondition | Rollback |
|---|---|---|---|---|---|---|---|---|---|---|
| WETH-TX-00 | G0 prereq (may be no-op) | OracleRouter | `setMaxOracleDelay(uint256)` | 1500 s | Timelock proposer+executor | queue+execute (24h) | now+24h | ~30k | `router.maxOracleDelay() >= 1500` | not needed (raising the delay is inherently safe) |
| WETH-TX-01 | G1 deploy | new `ChainlinkPriceSource` | constructor(address proxy) | proxy=`0x4aDC67…7cb1` | any funded EOA | none | immediate | ~500k | address recorded as `<CHAINLINK_ADAPTER>`; returns 8-decimal ETH/USD | reference dropped (adapter uncalled if not wired) |
| WETH-TX-02 | G1 deploy | new `PythPriceSource` | constructor(address core, bytes32 feedId) | core=`0x5f52…EB83`, feedId=`0xff614…0ace` | any funded EOA | none | immediate | ~500k | address recorded as `<PYTH_ADAPTER>` | reference dropped |
| WETH-TX-03 | G2 queue | Timelock -> CollateralVault | queue → `setCollateralToken(WETH, true, 18, 7500)` | see A.3 | proposer | none | eta = now+86400 | ~60k | ScheduledCall in timelock ledger | cancel via `cancelTransaction(id)` |
| WETH-TX-04 | G2 queue | Timelock -> CollateralVault | queue → `setTokenDepositCap(WETH, 100e18)` | see A.3 | proposer | none | eta = now+86400 | ~55k | ScheduledCall in ledger | cancel |
| WETH-TX-05 | G2 queue | Timelock -> CollateralVault | queue → `setLaunchActiveCollateral(WETH, true)` | see A.3 | proposer | none | eta = now+86400 | ~55k | ScheduledCall in ledger | cancel |
| WETH-TX-06 | G2 queue | Timelock -> OracleRouter | queue → `setFeed(WETH, mUSDC, <CHAINLINK_ADAPTER>, <PYTH_ADAPTER>, 1500, 200, true)` | see A.3 | proposer | requires WETH-TX-01/02 addresses | eta = now+86400 | ~90k | ScheduledCall in ledger | cancel |
| WETH-TX-07 | G2 queue | Timelock -> RiskModule | queue → `setCollateralConfig(WETH, 7500, true)` | see A.3 | proposer | none | eta = now+86400 | ~55k | ScheduledCall in ledger | cancel |
| WETH-TX-08 | G3 execute (T+24h) | Timelock -> CollateralVault | executeTransaction(id-of-TX03) | matches TX-03 calldata byte-exactly | executor | after TX-03 eta | now+24h | ~75k | `vault.collateralConfigsRaw(WETH).isSupported == true` | WETH-TX-14 (setCollateralToken(WETH, false, 18, 0)) |
| WETH-TX-09 | G3 execute (T+24h) | Timelock -> CollateralVault | executeTransaction(id-of-TX04) | matches TX-04 | executor | after TX-04 eta | now+24h | ~65k | `vault.tokenDepositCap(WETH) == 100e18` | WETH-TX-15 (cap=0) |
| WETH-TX-10 | G3 execute (T+24h) | Timelock -> CollateralVault | executeTransaction(id-of-TX05) | matches TX-05 | executor | after TX-05 eta | now+24h | ~65k | `vault.isLaunchActiveCollateral(WETH) == true` | WETH-TX-16 (isActive=false; PRIMARY rollback lever) |
| WETH-TX-11 | G3 execute (T+24h) | Timelock -> OracleRouter | executeTransaction(id-of-TX06) | matches TX-06 | executor | after TX-06 eta AND WETH-TX-01/02 | now+24h | ~110k | `router.getPriceSafe(WETH, mUSDC)` returns fresh price with `ok=true` | WETH-TX-17 (setFeedStatus(WETH, mUSDC, false)) |
| WETH-TX-12 | G3 execute (T+24h) | Timelock -> RiskModule | executeTransaction(id-of-TX07) | matches TX-07 | executor | after TX-07 eta | now+24h | ~65k | `RiskModule.collateralConfig(WETH).isActive == true, weightBps == 7500` | WETH-TX-18 (weightBps=0, isActive=false) |
| WETH-TX-13 | G4 release | off-chain | backend + frontend release with `WETH` closed-test config | backend Base Sepolia AllowList opens WETH row; frontend env var `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED=true` for closed-test build | deployer | after G3 verify | immediate | n/a | Balances API returns WETH row with `is_deposit_enabled=true`, `is_withdrawal_enabled=true`, `is_collateral_active=true` for allowlisted subaccounts | flip env var off + backend revert (Part I.1) |
| WETH-TX-14 | G5 rollback | Timelock -> CollateralVault | queue+execute `setCollateralToken(WETH, false, 18, 0)` | inner calldata: `0xccbf0808…0…12…0` (see A.3) | proposer+executor | 24h queue | now+24h | `isSupported == false` → deposits refused, withdrawals preserved | n/a (rollback itself) |
| WETH-TX-15 | G5 rollback | Timelock -> CollateralVault | queue+execute `setTokenDepositCap(WETH, 0)` | inner calldata: `0xdffbb14d…0` | proposer+executor | 24h queue | now+24h | cap=0 (no-op once TX-14 lands) | n/a |
| WETH-TX-16 | G5 rollback (PRIMARY LEVER) | Timelock -> CollateralVault | queue+execute `setLaunchActiveCollateral(WETH, false)` | inner calldata: `0xf5f7afc8…0` | proposer+executor | 24h queue | now+24h | new deposits refused; existing WETH still withdrawable; risk view continues to value WETH so accounts remain solvent | n/a |
| WETH-TX-17 | G5 rollback (oracle) | Timelock -> OracleRouter | queue+execute `setFeedStatus(WETH, mUSDC, false)` | inner calldata: `0x23bcafc7…0` | proposer+executor | 24h queue | now+24h | WETH contributes 0 to risk value; use ONLY if oracle compromised (contracts state; accounts may become liquidatable) | n/a |
| WETH-TX-18 | G5 rollback (risk) | Timelock -> RiskModule | queue+execute `setCollateralConfig(WETH, 0, false)` | inner calldata: `0x57c8c184…0…0` | proposer+executor | 24h queue | now+24h | risk module treats WETH as zero-weight; withdrawal path preserved | n/a |

**Total gas budget**: ~1.65M gas across G0-G3 (≈9 transactions actually
sent by the timelock signer; G1 is separate; G4 is off-chain; G5 is
contingent). Two 24h separated windows.

### A.5 Fork-simulation re-run

The fork-sim script `script/WethBaseSepoliaActivationDryRun.s.sol` was
re-run in this session against `https://sepolia.base.org`. See the
attached transcript at end of this document (Appendix F). The prior
run (recorded in `DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_MANIFEST_V1.md`)
matched the on-chain simulation numbers: gross `$14 998.83`, adjusted
`$13 749.12`, 200-WETH deposit rejected by cap, price crash to $1500
drops adjusted to `$11 125`, rollback preserves exit path.

**Verdict: `DEOPT_WETH_BASE_SEPOLIA_TX_MANIFEST_FROZEN`**

---

## PART B — FROZEN RISK PARAMETERS (CLOSED-TEST ONLY)

| Parameter | Value | Notes |
|---|---|---|
| `collateral_factor_bps` | **7 500** (75%) | Matches `WETH-TX-03` calldata byte 68-99 = `0x1d4c` = 7500 |
| `liquidation_factor_bps` | **8 200** (82%) | +7% buffer over collateral factor; enforced off-chain by risk model (Solidity V1 uses single `weightBps`; asymmetric factor is a documented backend/liquidation-time policy) |
| `protocol_global_cap` | **100 WETH** = `100e18` = `100000000000000000000` | Matches `WETH-TX-04` calldata trailing 32B = `0x56bc75e2d63100000` |
| `oracle_max_delay` | **1 500 seconds** | Matches `WETH-TX-00` and `WETH-TX-06` |
| `oracle_max_deviation_bps` | **200** (2%) | Matches `WETH-TX-06` parameter 5 |

**These are CLOSED-TEST parameters, not final production parameters.**

Production activation (Base mainnet) requires a separate design pass that
addresses Part C's Pyth-freshness limitation, revisits factor levels
against 30-day Base Sepolia telemetry, and re-evaluates the cap in USD
terms at the mainnet price of WETH.

**Verdict: `DEOPT_WETH_CLOSED_TEST_RISK_PARAMETERS_FROZEN`**

---

## PART C — PYTH FRESHNESS LIMITATION

**Behavior preserved from `DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_MANIFEST_V1`
(fork simulation observed Pyth ETH/USD ≈9 h stale during the run)**:

- Router's `PriceRouteConfig.freshnessSeconds` is set to `1 500` seconds.
- When Pyth returns a timestamp older than `now - 1 500`, the Pyth source
  is not treated as a fresh secondary corroboration.
- The router's existing single-source degradation policy takes over:
  Chainlink alone is used, deviation check between two sources is
  skipped, and the price is stamped with the Chainlink observation
  timestamp.
- The fail-closed guard is preserved: if Chainlink is ALSO stale, the
  router returns `ok=false`, which the risk module treats as zero
  contribution from WETH.

**`PYTH_STALE_FALLBACK_CLOSED_TEST_ACCEPTED_LIMITATION`** — this behavior
is explicitly acknowledged and accepted for the closed-test scope.
Rationale: Base Sepolia Pyth pushes are sparse (community-run relayers),
Chainlink Automation on Base Sepolia is dense and reliable. Under-
corroboration on Chainlink alone is bounded by the router's `maxDeviationBps`
default relative to the prior stored price plus the OracleRouter's
inherent staleness check.

### Hard readiness rule (public production)

> WETH public-production activation MUST NOT be declared ready until a
> reliable secondary-source freshness strategy exists on the target
> chain. This will not be solved by weakening the freshness constraints
> (`maxDelay`, `maxDeviationBps`, `freshnessSeconds`); it will be solved
> by either (a) subscribing a Pyth push relayer under our operational
> control, (b) adding a third source (Chronicle / API3), or (c) using
> Pyth's pull-mode with per-transaction freshness proofs. Until one of
> these lands and is proven in a separate design pass, public WETH
> activation is BLOCKED.

This is a `MUST` at the manifest level; do not remove without a
follow-on milestone.

---

## PART D — BACKEND ACTIVATION PACKAGE

### D.1 Package summary

Backend must, immediately after G3 verify:

1. **Register a Base-Sepolia-specific "closed-test allowlist"** for the
   WETH collateral asset (see D.3 for the code change).
2. Report WETH in `GET /accounts/{subaccount}/balances` with:
   - `symbol: "WETH"`
   - `token: "0x4200000000000000000000000000000000000006"`
   - `decimals: 18`
   - `collateral_factor_bps: 7500`
   - `liquidation_factor_bps: 8200`
   - `is_deposit_enabled: true` (only for allowlisted subaccounts on 84532)
   - `is_withdrawal_enabled: true` (only for allowlisted subaccounts on 84532)
   - `is_collateral_active: true`
   - Cap surfaced via existing per-token cap query (100 WETH global).
3. Continue to report `settlement_pnl_asset() = "USDC"` unchanged.
4. Keep the closed-test asset registry OFF for non-allowlisted subaccounts
   even on 84532.

### D.2 Explicit configuration values (mirror on-chain)

The backend's authoritative WETH config for Base Sepolia closed-test
MUST equal the on-chain values byte-exactly:

- `asset_symbol = "WETH"`
- `decimals = 18`
- `collateral_factor_bps = 7500` (matches vault + risk module)
- `liquidation_factor_bps = 8200` (backend-owned buffer)
- `deposit_enabled = true`
- `withdrawal_enabled = true`
- `deposit_cap = 100 * 10^18` (advisory mirror; vault enforces
  authoritatively)
- Oracle identity: OracleRouter feed `(WETH, mUSDC)` — backend reads
  through the same router contract, does not carry a duplicate off-chain
  price source.

### D.3 Code deltas required (NOT applied by this milestone)

The current backend explicitly REFUSES `MULTICOLLATERAL_CLOSED_TEST_ENABLED`
on chain 84532 (see `deopt-v2-backend/src/config/collateral_closed_test.rs:106-110`),
which was the correct posture until this milestone authorized WETH on
Base Sepolia. The activation release must:

1. **Replace the coarse env-var gate with a per-subaccount allowlist gate**:
   - `MULTICOLLATERAL_CLOSED_TEST_ENABLED` remains a build-time env
     var but its Base Sepolia refusal is replaced by:
     - `MULTICOLLATERAL_CLOSED_TEST_ALLOWLIST` (comma-separated
       0x-addresses) — WETH row + deposit/withdraw exposure only
       returned for these subaccounts.
     - Public users on Base Sepolia still see USDC-only exactly as
       today.
   - Base mainnet (8453) and Ethereum mainnet (1) refusals **STAY** in
     `refuse_closed_test_on_forbidden_chain`. Only 84532 is opened,
     and only for allowlisted subaccounts.
2. Adjust `WETH_CLOSED_TEST` constant factors from the current
   `8_000 / 8_500` to the frozen `7_500 / 8_200` (or introduce a
   `WETH_BASE_SEPOLIA_CLOSED_TEST` variant so the local-Anvil closed-
   test path is unaffected).
3. Populate `BalanceRow.is_collateral_active` (already-existing field at
   `deopt-v2-backend/src/api/trading.rs:479`) based on the allowlist +
   on-chain state read from vault + risk module.
4. Wire `assert_v1_single_collateral_invariant` around the allowlist
   check so the invariant remains true for non-allowlisted subaccounts.
5. New unit tests:
   - Non-allowlisted subaccount on 84532 sees USDC-only row set.
   - Allowlisted subaccount on 84532 sees USDC + WETH rows with
     correct flags.
   - Allowlisted subaccount on 8453 still refused (env-var refusal
     preserved).
   - Empty allowlist ⇒ WETH hidden for everyone.

### D.4 Rollback (Part I.1)

Emergency backend rollback: `MULTICOLLATERAL_CLOSED_TEST_ALLOWLIST=`
(empty) OR `MULTICOLLATERAL_CLOSED_TEST_ENABLED=false`. Either flip
takes effect on the next process restart; no data migration needed.

**Verdict: `DEOPT_WETH_BACKEND_CLOSED_TEST_ACTIVATION_READY`**

---

## PART E — FRONTEND ACTIVATION PACKAGE

### E.1 Current state (verified)

- `deopt-v2-frontend/src/lib/multicollateral-closed-test.ts` ships the
  dual-gate logic: env-flag + per-row backend flag. USDC always renders
  (immune to the flag). Non-USDC (WETH) is gated behind BOTH gates.
- `deopt-v2-frontend/src/lib/trading-types.ts:257-289` `Balance` type
  already carries every field this manifest requires.
- `deopt-v2-frontend/src/components/trading/BalancesCard.tsx` currently
  renders every row the backend returns (no client-side filter). The
  backend flags are therefore the authoritative gate; the frontend env
  var is a defense-in-depth kill switch that must ALSO be true for
  deposit/withdraw forms.
- No hardcoded WETH price, haircut, enable-state, or address elsewhere
  in the frontend. All values come from the backend Balance row.

### E.2 Frontend release change list

1. **Environment (closed-test build only)**:
   `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED=true` in the
   closed-test Vercel preview environment. Production env stays unset
   (implicit false).
2. **BalancesCard integration** (currently missing gate call — see
   E.1): update `BalancesCard.tsx:53` to filter via
   `shouldRenderBalanceRow(row)` from `multicollateral-closed-test.ts`.
3. **Deposit/Withdraw forms** (not yet present in frontend — see
   Explore report Part 3): when built, they must call
   `shouldExposeDeposit(row)` / `shouldExposeWithdraw(row)` before
   enabling controls for a token. Deposit form must consume the
   `token` field of the selected `Balance` row (no hardcoded USDC).
4. **Row rendering**: USDC + WETH rows show:
   - Symbol
   - Raw balance
   - USD value (`raw_usd_value_1e8`)
   - Margin value (`risk_adjusted_usd_value_1e8`)
   - Deposit button (only if `shouldExposeDeposit(row)`)
   - Withdraw button (only if `shouldExposeWithdraw(row)`)
5. No client-side collateral-factor math. All USD + margin values come
   from backend `raw_usd_value_1e8` and `risk_adjusted_usd_value_1e8`.
6. **Rollback**: unset `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED`
   → gate returns `false` → non-USDC rows disappear → USDC-only UI.
   Redeploy is not required; env-var flip on Vercel + preview restart
   is sufficient.

### E.3 Frontend does NOT expose WETH until backend confirms

Both gates (env flag AND `is_deposit_enabled=true`) are required. If
the backend accidentally serves `is_deposit_enabled=true` with the env
flag off (production build), WETH stays hidden. If a closed-test build
sees the flag on but the backend serves `is_deposit_enabled=false`,
WETH stays hidden. Either gate closes = row hidden.

**Verdict: `DEOPT_WETH_FRONTEND_CLOSED_TEST_ACTIVATION_READY`**

---

## PART F — FROZEN ACTIVATION ORDER

### PHASE 1 — Adapter deploy + timelock queue (T = 0)

Owner: multisig signer at `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`,
funded with Base Sepolia ETH.

1. WETH-TX-01 (deploy `ChainlinkPriceSource`).
2. WETH-TX-02 (deploy `PythPriceSource`).
3. Record `<CHAINLINK_ADAPTER>` + `<PYTH_ADAPTER>` in the operator log.
4. Assemble WETH-TX-06 inner calldata using the recorded addresses.
5. Optionally: WETH-TX-00 (if `router.maxOracleDelay() < 1500`; the
   fork sim confirmed the current live router value; run one probe
   before deciding).
6. WETH-TX-03 through WETH-TX-07 (queue five inner calls via Timelock).
   Record each ScheduledCall id + ETA (`now + 86400 s`).

**Application exposure remains DISABLED throughout Phase 1.**
No backend deploy. No frontend flag flip. No user-visible WETH.

### WAIT ≥ 24 h

The Timelock's `minDelay` is 86 400 s. No timing tricks or delay
reductions. Explicit wait for all five ETAs to elapse.

### PHASE 2 — Execute (T = 24 h + Δ)

7. WETH-TX-08 (execute setCollateralToken).
8. WETH-TX-09 (execute setTokenDepositCap).
9. WETH-TX-10 (execute setLaunchActiveCollateral).
10. WETH-TX-11 (execute setFeed). **Immediately** run a `cast call`
    postcondition: `router.getPriceSafe(WETH, mUSDC)` must return
    `(price>0, timestamp, ok=true)`. If `ok=false`, STOP and open
    incident.
11. WETH-TX-12 (execute setCollateralConfig).

### VERIFY ON-CHAIN (T = 24 h + Δ + verify-window)

- `vault.collateralConfigsRaw(WETH) == (true, 18, 7500)` (isSupported, decimals, factor)
- `vault.tokenDepositCap(WETH) == 100e18`
- `vault.isLaunchActiveCollateral(WETH) == true`
- `router.getPriceSafe(WETH, mUSDC)` returns `ok=true`
- `RiskModule.collateralConfig(WETH) == (7500, true)` (weightBps, isActive)
- `RiskModule.computeCollateralState(<TESTER_SUBACCOUNT>)` returns
  `(gross=usdc_bal + weth_bal * price, adjusted=usdc_bal + weth_bal * price * 0.75)`

### PHASE 3 — Application release (T = verify + Δ)

12. WETH-TX-13a: deploy backend with new closed-test allowlist config
    (see D.3), `MULTICOLLATERAL_CLOSED_TEST_ENABLED=true`,
    `MULTICOLLATERAL_CLOSED_TEST_ALLOWLIST=<comma-separated tester
    subaccounts>`. Verify read-only: `GET /accounts/<tester>/balances`
    returns WETH row with correct flags; `GET /accounts/<non-tester>/balances`
    returns USDC-only.
13. WETH-TX-13b: enable frontend closed-test build with
    `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED=true`.
14. Announce closed-test window to allowlisted testers only.

**No public activation.** Closed-test cohort is a fixed allowlist,
communicated out-of-band. No marketing, no landing page changes, no
public Perps flip, no cbBTC flip.

---

## PART G — POST-ACTIVATION REAL E2E PLAN

Execute with very small test amounts (dust). No liquidation seizure on
real Base Sepolia unless separately authorized. Full plan (14 steps):

1. Deposit `10 USDC` from allowlisted tester A into subaccount 0.
2. Deposit `0.01 WETH` (≈$25) from tester A into subaccount 0.
3. `GET /accounts/A:0/balances` — verify raw balance rows match
   on-chain `vault.balances(A, USDC/WETH)` byte-exactly.
4. Verify `raw_usd_value_1e8` = 10 * 1e8 + 0.01 * eth_usd * 1e8 within
   deviation cap.
5. Verify `risk_adjusted_usd_value_1e8` = 10 * 1e8 * 1.00 +
   0.01 * eth_usd * 0.75 * 1e8 (75% haircut on WETH row).
6. Open one small derivative: 0.001 ETH-USD 0-DTE option position at
   ~$0.10 premium. Verify MarginEngine accepts using WETH margin.
7. Verify `RiskModule.computeCollateralState` decrement matches the
   required margin the engine locked.
8. Realize small ±PnL by closing the position or letting it settle.
9. Verify PnL was credited/debited in USDC only — WETH balance did
   NOT change from the trade (only USDC did).
10. Withdraw `0.001 WETH` — safe withdrawal path succeeds.
11. Attempt withdraw `0.009 WETH` (would leave insufficient margin
    for open positions) — must be refused with unsafe reason code.
12. Deposit from tester A subaccount 1: verify subaccount 0's WETH
    balance is untouched (subaccount isolation preserved on real chain).
13. Backend graceful restart: restart the API server process. Re-fetch
    balances — verify byte-identical to pre-restart snapshot (no
    duplication, no loss, no divergence).
14. Reconstructed state check: run backend against a fresh Postgres
    (recreated from Solidity events + user-op ledger). Verify final
    balances match on-chain vault state byte-exactly.

**Non-goals**: DO NOT trigger destructive liquidation on Base Sepolia
real state; DO NOT open positions large enough to hit deposit cap; DO
NOT test with more than a handful of allowlisted testers.

**Verdict: `DEOPT_WETH_BASE_SEPOLIA_POST_ACTIVATION_E2E_READY`**

---

## PART H — MONITORING (pre-deposit-enable checklist)

Before deposits are enabled for allowlisted subaccounts, verify each
of the following metrics is being emitted and has an operator dashboard
row + alert rule.

| Metric | Source | Alert threshold |
|---|---|---|
| Chainlink ETH/USD freshness (seconds since `updatedAt`) | RPC probe of feed proxy | warn > 900 s, page > 1 500 s |
| Pyth ETH/USD freshness | RPC probe of Pyth core `getPriceUnsafe` timestamp | warn > 1 200 s (accepted CLOSED_TEST limitation — do not page on staleness alone; page only if BOTH sources stale) |
| Source deviation (Chainlink vs Pyth) | derived: `abs(c - p) / p` | warn > 100 bps, page > 200 bps |
| `getPriceSafe(WETH, mUSDC)` returning `ok=false` | contract call polled every 30 s | page immediately on any `ok=false` |
| Total WETH deposited (raw) | `vault.tokenTotalDeposits(WETH)` | warn > 80e18 (80% cap), page > 95e18 (95% cap) |
| Cap utilization % | `vault.tokenTotalDeposits(WETH) / vault.tokenDepositCap(WETH)` | warn 80%, page 95% |
| WETH collateral USD value (aggregate) | derived from vault totals × router price | warn > $200 000 |
| Liquidation events | `CollateralSeizer.CollateralSeized` events | page on any event during closed test |
| Withdrawal rejection rate | backend histogram of `withdraw_refused_*` outcomes | warn > 5% over 15 min |
| Backend WETH allowlist size drift | poll `MULTICOLLATERAL_CLOSED_TEST_ALLOWLIST` byte-hash | page on unexpected change |

Immediate paging routes to on-call operator. Warn routes to the closed-
test Slack channel. Do NOT enable deposits until every row above
returns fresh data in the operator dashboard.

---

## PART I — EMERGENCY ROLLBACK

Two rollback modes, chosen by incident nature. Both preserve user
withdrawal path except when the oracle itself is compromised.

### I.1 Fast off-chain rollback (application-only, ≈2 min)

Preferred first response when the on-chain state is fine but a
downstream issue (backend bug, frontend rendering error, allowlist
drift) needs to be shut off immediately.

1. Set `MULTICOLLATERAL_CLOSED_TEST_ALLOWLIST=` (empty) OR
   `MULTICOLLATERAL_CLOSED_TEST_ENABLED=false` on the backend Vercel
   env; restart. Backend now reports USDC-only for all subaccounts.
2. Unset `NEXT_PUBLIC_MULTICOLLATERAL_CLOSED_TEST_ENABLED` on the
   frontend Vercel env; restart. Frontend now renders USDC-only.

**Effect**: WETH invisible in UI within 2 minutes. Existing WETH
balances remain in the vault; the router still prices WETH; users can
still withdraw via direct contract call (fallback UI or Etherscan).

**No on-chain change required.**

### I.2 On-chain rollback (24h, ≈4 txs)

Required when on-chain state itself is the problem (misconfigured
factor, cap needs immediate reduction, feed compromise).

Execute rollback set in this order:

1. **WETH-TX-16** (queue + execute `setLaunchActiveCollateral(WETH, false)`)
   — PRIMARY LEVER. Refuses new deposits at the vault contract.
   Existing WETH balances still withdrawable (withdraw path does not
   consult `isLaunchActiveCollateral`). Users retain full unwind.
2. **WETH-TX-14** (queue + execute `setCollateralToken(WETH, false, 18, 0)`)
   — flips `isSupported=false`. Reinforces the deposit block.
   Withdrawals still allowed because `_withdrawInternal` only checks
   balance, not `isSupported`.
3. **WETH-TX-18** (queue + execute `setCollateralConfig(WETH, 0, false)`)
   — risk module aggregation stops crediting WETH toward margin.
   Existing WETH-backed positions may become undercollateralized;
   liquidation is possible. **Only run if margin credit itself is the
   problem**. If executed in isolation without I.1 first, users cannot
   reduce positions fast enough — front-run with I.1 for the UI
   shutdown before this queue's ETA lands.
4. **WETH-TX-17** (queue + execute `setFeedStatus(WETH, mUSDC, false)`)
   — deactivates the oracle route. WETH contributes 0 to any risk
   view. USE ONLY IF ORACLE IS COMPROMISED. This traps WETH-backed
   accounts in unsafe state until the feed is restored, so it is the
   last-resort lever.

**Preserved behavior**: `pauseWithdrawals(WETH)` is NOT part of the
rollback set. Users always retain the ability to call
`vault.withdraw(WETH, ...)` for any balance they hold. The only path
that traps WETH is a guardian emergency pause, which is out of scope
for this rollback and requires separate authorization.

---

## FINAL PACKAGE — DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_ACTIVATION_MANIFEST_FINAL

- Solidity commit: `9fa86ddf078d0d0e5059f4544917a37fe069dc9e`
- Backend commit: `126a857addb765625a6576e2d55d7e735584a9cb`
  - Delta required at release time (see Part D.3) — package prepared,
    not applied
- Frontend commit: `9cd8dce1aad9686ddfe2893d0219123a690f1b25`
  - Delta required at release time (see Part E.2) — package prepared,
    not applied
- WETH-TX-01..18 mapping: Part A.4 above
- Fork simulation: `script/WethBaseSepoliaActivationDryRun.s.sol`
  passing (Appendix F transcript)
- Runtime rollout order: Part F above
- Rollback plan: Part I above
- Monitoring pre-checklist: Part H above

**No transaction has been broadcast.**

---

## Explicit non-authorization list

This manifest AUTHORIZES ONLY:

- WETH collateral closed-test activation on Base Sepolia (chain 84532).

This manifest does NOT authorize:

- cbBTC activation on any chain.
- WETH activation on Base mainnet or any chain other than 84532.
- Public Perps activation (Perps remain OFF at the route boundary per
  the frozen `PERPS_BASE_SEPOLIA_INFRA_BROADCAST_V1` manifest).
- Funding rate activation.
- Any second-chain broadcast.
- Any unrelated protocol transaction.

---

## Authorization sentence

An operator with signing authority for
`0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` may proceed with broadcast
only after issuing the following sentence verbatim in a subsequent
directive:

> I explicitly authorize broadcast of WETH-TX-01 through WETH-TX-18
> from manifest 9fa86dd on Base Sepolia chain 84532 only, for WETH
> collateral closed-test activation. No cbBTC activation, public Perps
> activation, Funding activation, second-chain action, Base mainnet
> action, or unrelated protocol transaction is authorized.

---

## APPENDIX F — Fork-simulation re-run transcript

Re-run executed in this session against `https://sepolia.base.org` via
`forge script script/WethBaseSepoliaActivationDryRun.s.sol:WethBaseSepoliaActivationDryRun --fork-url https://sepolia.base.org --sig "run()" -vv`.

Exit code: 0. Verbatim output:

```
No files changed, compilation skipped
Script ran successfully.

== Logs ==
  === DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_DESIGN_V1 (Part J fork sim) ===
  block 46533266
  ts 1788834820
  --- Part A: asset identity ---
  WETH ok: 0x4200000000000000000000000000000000000006
  --- Part B: adapter deployments + safe-price ---
  Chainlink adapter price 1e8 249700467073
  Chainlink adapter updatedAt 1788834580
  Pyth adapter price 1e8 247168178312
  Pyth adapter updatedAt 1788796539
  --- Parts F+G: applying activation via timelock prank ---
  WETH-TX-00: router maxOracleDelay raised 1500
  [Parts F+G] activation applied on fork
  --- Part J: scenarios against real deployed contracts ---
  gross USDC-native 14994009341
  adjusted USDC-native 13745507005
  expected gross USDC-native 14994009341
  [Part J] cap rejects 200 WETH deposit
  adjusted after crash 11125000000
  [Part J] real-contract scenarios all passed
  --- Part L: rollback walk-through ---
  [Part L] rollback preserves user exit path
  DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_VALIDATED
```

### Interpretation of the numbers

- Fork block: 46 533 266 (fresher than the V1 design snapshot).
- Chainlink ETH/USD: $2 497.00 fresh (`updatedAt` 240 s ago —
  well within the 1 500 s `maxDelay`).
- Pyth ETH/USD: $2 471.68 stale (`updatedAt` 38 281 s ago — router
  degrades to Chainlink single-source per Part C accepted limitation).
- Gross collateral: `10 000 USDC × $1 + 2 WETH × $2 497 = $14 994.01`.
  Matches log `14994009341` (USDC-native, 1e6 decimals).
- Adjusted collateral: `10 000 × 1.00 + 2 × 2 497 × 0.75 = $13 745.51`.
  Matches log `13745507005`. **Exact 75% haircut verified on WETH.**
- Cap enforcement: attempt to deposit 200 WETH into a 100 WETH cap
  reverts as expected.
- Crash simulation: WETH price mocked to $1 500 → adjusted drops to
  `10 000 × 1.00 + 2 × 1 500 × 0.75 = $11 125`. Matches log
  `11125000000`.
- Rollback: `setLaunchActiveCollateral(false)` + `setCollateralConfig(0, false)` +
  `setFeedStatus(false)` applied via timelock prank. Tester `vault.withdraw(WETH, 2 ether)`
  path still succeeds — user exit preserved.

`DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_VALIDATED`.
