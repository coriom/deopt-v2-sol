# BASE_SEPOLIA_CLOSED_TEST_READINESS

Milestone: `PERPS_CLOSED_TEST_E2E_V1` — Part I audit.

Scope: what the operator must provision on Base Sepolia (chainId `84532`)
before the closed test can broadcast a first live round-trip. This milestone
does NOT itself broadcast; it produces the checklist below.

No addresses have been invented. Every "current state" citation is
`file:line` against the working tree.

---

## 1. Chainlink / Pyth Base Sepolia sources

**Required state.** Two independent Base Sepolia price adapters per market
(ETH/USDC, BTC/USDC), deployed and encoded in env vars that
`ConfigureMarkets.s.sol` reads via `_configureFeed(...)`.

**Current state.**
- No real Chainlink or Pyth Base Sepolia addresses are tracked anywhere:
  - The manifest template has all zero addresses and status
    `NOT_DEPLOYED`
    (`deployment-manifest/base-sepolia-template-v1.json:12,15-19`).
  - The env template ships `REQUIRED_ETH_USDC_PRIMARY_SOURCE` /
    `REQUIRED_ETH_USDC_SECONDARY_SOURCE_OR_ZERO` /
    `REQUIRED_BTC_USDC_PRIMARY_SOURCE` /
    `REQUIRED_BTC_USDC_SECONDARY_SOURCE_OR_ZERO` placeholders
    (`.env.base-sepolia.example:151-161`).
- Adapter constructors:
  - `ChainlinkPriceSource(address _aggregator)`
    (`src/oracle/ChainlinkPriceSource.sol:41-48`) — one aggregator address,
    output normalized to 1e8.
  - `PythPriceSource(address _pyth, bytes32 _priceId)`
    (`src/oracle/PythPriceSource.sol:43-48`) — Pyth entrypoint + priceId,
    output normalized to 1e8.

**Operator action.**
1. Deploy one `ChainlinkPriceSource` per market pointing at the Base Sepolia
   ETH/USD and BTC/USD Chainlink aggregators (aggregator addresses NOT in
   this repo — operator sources from the Chainlink Base Sepolia feed
   registry).
2. Deploy one `PythPriceSource` per market pointing at the Base Sepolia Pyth
   entrypoint contract and the ETH/USD / BTC/USD priceIds (NOT in this
   repo).
3. Populate `.env.base-sepolia`:
   - `ETH_USDC_PRIMARY_SOURCE`, `ETH_USDC_SECONDARY_SOURCE`
   - `BTC_USDC_PRIMARY_SOURCE`, `BTC_USDC_SECONDARY_SOURCE`

**Env vars / roles.** Per market:
`<MARKET>_PRIMARY_SOURCE`, `<MARKET>_SECONDARY_SOURCE`,
`<MARKET>_MAX_DELAY`, `<MARKET>_MAX_DEVIATION_BPS`,
`<MARKET>_FEED_ACTIVE`
(consumed at `script/ConfigureMarkets.s.sol:152-158`).

---

## 2. Dual-source OracleRouter config

**Required state.** Every active feed carries `secondarySource != 0` AND
`maxDeviationBps > 0`.

**Current state.** Enforced at `src/oracle/OracleRouter.sol:311-321`:

```
if (isActive) {
    if (address(primarySource) == address(0) && address(secondarySource) == address(0)) revert NoSource();
    if (address(secondarySource) == address(0) || maxDeviationBps == 0) revert SecondarySourceRequired();
}
```

Re-validated on `setFeedStatus` at `src/oracle/OracleRouter.sol:348-357`.

Default env values ship `ETH_USDC_MAX_DEVIATION_BPS=1000` /
`BTC_USDC_MAX_DEVIATION_BPS=1000`
(`.env.base-sepolia.example:154,160`).

**Operator action.** For each market provide TWO source addresses AND keep
`_MAX_DEVIATION_BPS > 0` and `_FEED_ACTIVE=true`. A zero secondary or a
zero deviation bound will revert `setFeed` — this is the fail-closed
posture from the prior milestone.

---

## 3. Executor / operator signer

**Required state.** A funded Base Sepolia EOA authorized as executor on
`PerpMatchingEngine`, with a signing capability the backend can reach.

**Current state.**
- Backend expects the executor address at
  `src/execution/config.rs:46` (`perp_matching_engine_address`) and
  reads it from env at `src/config/env.rs:176-180`
  (`PERP_MATCHING_ENGINE_ADDRESS`).
- Backend signer wiring: `BACKEND_SIGNER_MODE` /
  `BACKEND_SIGNER_ENDPOINT` / `BACKEND_REMOTE_SIGNER_PROVIDER` at
  `src/config/env.rs:189-209`.
- The impact-mid keeper explicitly does NOT broadcast in this milestone:
  "No on-chain broadcast to `PerpEngine.updateImpactMid`. That is the
  follow-up milestone; the keeper produces the value and the Solidity
  interface is the target for a future broadcaster."
  (`src/perps/impact_mid_keeper.rs:37-39`).
- `PerpsReadConfig` is documented as read-only: "No writes, no signing,
  no broadcasts." (`src/perps/mod.rs:20`).
- Executor role deployment env: `PERP_MATCHING_EXECUTOR` at
  `.env.base-sepolia.example:63`; multi-executor array
  `PERP_MATCHING_EXECUTORS` / `PERP_MATCHING_EXECUTOR_ALLOWED` at
  `.env.base-sepolia.example:278-279`.
- On-chain executor wiring is handled by `TransferOwnerships.s.sol`
  which calls `matching.setExecutor(...)`
  (`script/TransferOwnerships.s.sol:256`) against
  `PerpMatchingEngine.setExecutor(address, bool)`
  (`src/matching/PerpMatchingEngine.sol:373-377`).

**Operator action.**
1. Generate / choose a Base Sepolia executor EOA; fund with test ETH.
2. Put its address in `PERP_MATCHING_EXECUTOR` and
   `PERP_MATCHING_EXECUTORS` in `.env.base-sepolia`.
3. Run `TransferOwnerships` which flips
   `PerpMatchingEngine.isExecutor(executor) == true`.
4. Wire the backend to sign as this executor: choose
   `BACKEND_SIGNER_MODE` (`local-dev` for closed-test, remote for
   production posture) and provide the key material via the chosen
   signer backend. No dedicated closed-test signer is committed.

---

## 4. Deployment addresses

**Required state.** Every DeOpt v2 module deployed on Base Sepolia and its
address recorded so backend + frontend can dial the correct contracts.

**Current state.**
- `.env.base-sepolia.example` is the committed template; the filled
  `.env.base-sepolia` (gitignored) is the operator's source of truth.
- All module addresses ship as `FILL_FROM_DEPLOY_CORE_*` placeholders:
  `COLLATERAL_VAULT`, `ORACLE_ROUTER`, `OPTION_PRODUCT_REGISTRY`,
  `MARGIN_ENGINE`, `RISK_MODULE`, `PERP_MARKET_REGISTRY`, `PERP_ENGINE`,
  `PERP_RISK_MODULE`, `COLLATERAL_SEIZER`, `FEES_MANAGER`,
  `INSURANCE_FUND`, `MATCHING_ENGINE`, `PERP_MATCHING_ENGINE`,
  `PROTOCOL_TIMELOCK`, `RISK_GOVERNOR`
  (`.env.base-sepolia.example:99-114`).
- Manifest draft carries no addresses either:
  `deployment-manifest/base-sepolia-template-v1.json` — every module
  address is `0x0...0` and `activationStatus == "NOT_DEPLOYED"`.
- Extra placeholder classes: `REQUIRED_*` role owners and market caps
  (e.g. `.env.base-sepolia.example:54-64,91-93,218-262`).

**Operator action.** Run `script/DeployCore.s.sol` (broadcast), harvest
printed addresses into `.env.base-sepolia`, then re-run every subsequent
script that reads those addresses (`WireCore`, `ConfigureCore`,
`ConfigureMarkets`, `TransferOwnerships`, `AcceptOwnerships`,
`VerifyDeployment`).

---

## 5. RPC configuration

**Required state.** One Base Sepolia RPC endpoint reachable from the
backend host and one `verifyingContract` address baked into the frontend
build.

**Current state.**
- Backend `PerpsReadConfig.rpc_url` is populated from the shared execution
  `RPC_URL` env (single-source policy noted in
  `src/config/env.rs:715-716`), lookup at
  `src/config/env.rs:170` (`rpc_url: lookup("RPC_URL").filter(...)`) and
  propagated to `PerpsReadConfig` at `src/config/env.rs:816-819`.
- The impact-mid keeper refuses to spawn without an RPC URL (log warning
  at `src/main.rs:224-225`: "perps impact-mid keeper is enabled but
  PERPS/RPC_URL is unset").
- Frontend reads
  `NEXT_PUBLIC_PERP_MATCHING_ENGINE_ADDRESS` at
  `src/components/trading/perps/PerpsTradeForm.tsx:644` and refuses to
  open a wallet prompt when unset
  (`src/components/trading/perps/PerpsTradeForm.tsx:220`). The env
  scaffold lives at `.env.example:22` and `.env.local.example:59`.

**Operator action.** Set `RPC_URL=<base-sepolia rpc>` in the backend env
and set `NEXT_PUBLIC_PERP_MATCHING_ENGINE_ADDRESS=<deployed PME>` in the
frontend build env before `npm run build`.

---

## 6. Impact-mid publisher authority

**Required state.** `PerpEngine.impactMidSource` set to the address that
will call `updateImpactMid`.

**Current state.**
- Setter: `PerpEngineAdmin.setImpactMidSource(address source)` at
  `src/perp/PerpEngineAdmin.sol:176-181` (`onlyOwner`, rejects zero).
- Storage / access-control gate: `impactMidSource` at
  `src/perp/PerpEngineStorage.sol:182` with modifier check at
  `src/perp/PerpEngineStorage.sol:235-238` (`NotImpactMidSource`).
- No dedicated Foundry script calls `setImpactMidSource`:
  `grep -l setImpactMidSource script/` returns nothing under
  `~/DEOPT/deopt-v2-sol/script/`. Operator must invoke it manually
  (e.g. via `cast send`).
- Backend keeper is compute-only in this milestone: it publishes to an
  in-process `ImpactMidCache` and never signs / broadcasts
  (`src/perps/impact_mid_keeper.rs:35-43`).

**Operator action.** For closed-test with `ETH_PERP_FUNDING_ENABLED=false`
and `BTC_PERP_FUNDING_ENABLED=false` (defaults, per
`.env.base-sepolia.example:229,254`), no keeper writer is exercised and
`setImpactMidSource` is not strictly required for a first round-trip. If
the operator plans to enable funding during the closed test, they must:
1. Choose a keeper EOA.
2. Call `PerpEngine.setImpactMidSource(<keeper EOA>)` manually (owner
   only; no script wraps this call).
3. Wire the backend broadcaster follow-up — NOT in scope of the
   PERPS_FULLSTACK_RUNTIME_INTEGRATION_V1 Part D scope.

---

## 7. Closed-test allowlist

**Required state.** Backend env holds the comma-separated set of test
wallet addresses (case-insensitive); `PERPS_CLOSED_TEST_ENABLED=true`.

**Current state.**
- Parse: `src/config/env.rs:851-861` — splits on `,`, trims, lowercases,
  wraps in `AccountId`.
- Mainnet-refusal guardrail: `src/config/env.rs:844-850` rejects
  `PERPS_CLOSED_TEST_ENABLED=true` on chain ids `1` and `8453`.
- Enforcement helper: `AppState::perps_closed_test_allows` at
  `src/api/http.rs:823-831` — empty allowlist means "nobody in" (fail
  closed).
- Enforcement sites:
  - Perps submit route: `src/api/routes.rs:3076-3088`.
  - Cancel route: `src/api/routes.rs:3215-3223`.
  - EIP-712 signed-intent route: `src/api/routes.rs:3454,3487-3489`.
- Observability counter: `src/perps/observability.rs:192-195`
  (`record_closed_test_access_denied`), surfaced as
  `deopt_perps_closed_test_access_denied_total`
  (`src/monitoring.rs:359-361`).

**Operator action.**
```
PERPS_CLOSED_TEST_ENABLED=true
PERPS_CLOSED_TEST_ALLOWLIST=0xabc...,0xdef...
```

---

## 8. Gas funding

**Required state.** Each Base Sepolia EOA the closed test exercises has
enough Sepolia ETH to broadcast its role's transactions.

**Current state.** Role EOAs enumerated in `.env.base-sepolia.example`:
- Deployer: `DEPLOYER_ADDRESS` (line 25)
- Governance owners: `GOVERNANCE_OWNER`, `TIMELOCK_OWNER`,
  `RISK_GOVERNOR_OWNER`, `FINAL_GOVERNANCE_OWNER` (lines 54-57)
- Guardian: `GOVERNANCE_GUARDIAN` (line 58)
- Executors: `MATCHING_EXECUTOR` (line 59), `PERP_MATCHING_EXECUTOR`
  (line 63)
- Insurance: `INSURANCE_OPERATOR` (line 64)
- Timelock: `TIMELOCK_EXECUTORS` (line 269)

Existing internal reference for the "fund via faucet" pattern:
`docs/GOVERNANCE_OPS_MULTISIG_INPUTS_V2G_GOV_D2_INPUTS.md:76` — "operator
funds via faucet, then re-verify".

No specific Base Sepolia faucet URLs are tracked in the repo. The
operator is expected to use the public Base Sepolia faucet channels they
already source for prior rehearsals.

**Operator action.** For closed test specifically, ensure funding for:
- Deployer EOA (contract deploy phase).
- `PERP_MATCHING_EXECUTOR` (per-trade broadcast).
- Impact-mid keeper EOA (only if funding is enabled in this closed test).
- Owner / guardian EOAs (governance calls during setup).
- Each allowlisted trader wallet (they broadcast their own deposit +
  approvals).

---

## 9. Contract activation sequence

Ordered sequence to move from "compiled" to "closed-test-ready":

a. **Deploy contracts.** `forge script script/DeployCore.s.sol
   --rpc-url $RPC_URL --broadcast`. Harvest printed addresses into
   `.env.base-sepolia`.

b. **Wire modules.** `forge script script/WireCore.s.sol ... --broadcast`
   + `ConfigureCore.s.sol`.

c. **Configure markets + feeds.** `forge script
   script/ConfigureMarkets.s.sol ... --broadcast`. This calls
   `router.setFeed(...)` (`ConfigureMarkets.s.sol:306-314`) which is the
   spot where the dual-source invariant fires
   (`OracleRouter.sol:311-321`). Per-market
   `setMaxExecutionDeviationBps` and `setMarketActivationState` are set
   here too (`ConfigureMarkets.s.sol:424-426`).

d. **Set impact-mid source (manual, only if funding enabled).**
   `cast send $PERP_ENGINE "setImpactMidSource(address)"
   $IMPACT_MID_KEEPER_ADDR` — no script wraps this call. For a
   funding-disabled closed test this step is skipped safely (funding
   defaults are OFF per `.env.base-sepolia.example:229,254`).

e. **Register perp matching executor.** `forge script
   script/TransferOwnerships.s.sol ... --broadcast` runs
   `matching.setExecutor(perpMatchingExecutor, true)` (line 256). Verify
   with `VerifyDeployment` (`script/VerifyDeployment.s.sol:441`).

f. **Per-market engine activation.** Set
   `ETH_PERP_ENGINE_ACTIVATION_STATE` / `BTC_PERP_ENGINE_ACTIVATION_STATE`
   in env (`0`=inactive, `1`=restricted, `2`=active — bound checked at
   `ConfigureMarkets.s.sol:289`). Closed test recommends `1` (restricted)
   so the market accepts trades only under the closed-test allowlist path.

g. **Backend env for closed test.**
   ```
   RPC_URL=<base sepolia>
   PERPS_READ_ENABLED=true
   PERPS_PUBLIC_TRADING_ENABLED=false
   PERPS_CLOSED_TEST_ENABLED=true
   PERPS_CLOSED_TEST_ALLOWLIST=<comma-separated addrs>
   PERPS_IMPACT_MID_KEEPER_ENABLED=<true only if funding enabled>
   PERP_MATCHING_ENGINE_ADDRESS=<deployed PME>
   PERP_ENGINE_ADDRESS=<deployed PerpEngine>
   PERPS_MARKET_REGISTRY_ADDRESS=<deployed PerpMarketRegistry>
   PERPS_ORACLE_ROUTER_ADDRESS=<deployed OracleRouter>
   PERPS_ETH_BASE_ADDRESS=<ETH_UNDERLYING>
   PERPS_ETH_QUOTE_ADDRESS=<BASE_COLLATERAL_TOKEN>
   PERPS_BTC_BASE_ADDRESS=<BTC_UNDERLYING>
   PERPS_BTC_QUOTE_ADDRESS=<BASE_COLLATERAL_TOKEN>
   ```
   (env parsing at `src/config/env.rs:719-806`.)

h. **Start backend, verify.**
   - `GET /perps/markets` — must return the seeded markets
     (`src/api/routes.rs:314,2369`).
   - `GET /perps/markets/:market_id/price` — must return a fresh dual-
     source price.
   - Any non-allowlisted mutation must 503 `PerpsNotLive` and increment
     `deopt_perps_closed_test_access_denied_total`
     (`src/perps/observability.rs:192-195`).

i. **Distribute the frontend build.** Build with
   `NEXT_PUBLIC_PERPS_TICKET_ENABLED=true`,
   `NEXT_PUBLIC_PERPS_CLOSED_TEST_ENABLED=true`, and
   `NEXT_PUBLIC_PERP_MATCHING_ENGINE_ADDRESS=<PME>`. Distribute to
   allowlisted testers. UI copy switch documented at
   `src/lib/perps-closed-test-flag.ts:1-14`.

---

## Fork Validation Harness Usage

Added in `PERPS_CLOSED_TEST_HARDENING_V1` Part G — the closed-test E2E
harness (`deopt-v2-backend/tests/perps_closed_test_e2e_harness.rs`)
accepts an optional Base Sepolia fork mode that spawns Anvil with
`--fork-url` so the operator can validate compatibility with the actual
Base Sepolia environment BEFORE any provisioning transaction is
authorized.

### Env vars (all optional)

- `PERPS_E2E_FORK_URL` — Base Sepolia RPC URL. When set, the harness
  spawns Anvil in fork mode; unset → vanilla behaviour (byte-identical
  to pre-Part-G).
- `PERPS_E2E_FORK_ETH_USDC_PRIMARY` — real Chainlink or Pyth ETH/USD
  adapter address deployed on Base Sepolia (if the operator has one
  wired). Enables the harness to call `getPriceSafe` against a real
  feed inside the fork.
- `PERPS_E2E_FORK_ETH_USDC_SECONDARY` — same for the secondary source
  (required for the `OracleRouter.setFeed` dual-source invariant).

### Verdicts (emitted by `part_g_fork_base_sepolia_smoke`)

- `PERPS_BASE_SEPOLIA_FORK_RUNTIME_VALIDATED` — fork mode exercised
  end-to-end with real oracle adapters returning fresh prices.
- `PERPS_BASE_SEPOLIA_FORK_WAITING_FOR_OPERATOR_ORACLE_CONFIG` —
  operator input (fork URL, oracle addresses) unavailable. NOT a
  milestone failure; the spec explicitly allows this outcome.

### Run

```bash
export PATH="$HOME/.foundry/bin:$PATH"
export PERPS_CLOSED_TEST_E2E_PG_URL=postgres://user:pass@host/db
export PERPS_E2E_FORK_URL=https://<your-base-sepolia-rpc-endpoint>
# optional (only if real oracle addresses are provisioned):
# export PERPS_E2E_FORK_ETH_USDC_PRIMARY=0x…
# export PERPS_E2E_FORK_ETH_USDC_SECONDARY=0x…
cargo test --test perps_closed_test_e2e_harness part_g_fork -- --nocapture
```

Do NOT broadcast on Base Sepolia via the fork harness — the fork is a
local Anvil that reads state from the RPC but never sends transactions
to the real network.

---

PERPS_BASE_SEPOLIA_CLOSED_TEST_READY_FOR_OPERATOR_PROVISIONING
