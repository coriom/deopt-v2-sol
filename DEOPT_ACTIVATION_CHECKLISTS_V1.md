# DEOPT_ACTIVATION_CHECKLISTS_V1

Design-only. No activation. No broadcast. Base + USDC only remain
active.

Three separate ordered checklists:

1. WETH collateral on Base
2. cbBTC collateral on Base
3. Second EVM chain (using Arbitrum as the running example)

Each checklist is written so a future operator can execute it top-
to-bottom, ticking items as they go, without re-deriving the design.
Rollback / disable path is included at the end of each.

---

## Checklist 1 — WETH collateral on Base

### Preconditions

- [ ] Milestone `DEOPT_MULTICHAIN_MULTICOLLATERAL_FOUNDATION_V1_COMPLETE`
      has landed.
- [ ] Milestone
      `DEOPT_MULTICHAIN_SCHEMA_HARDENING_AND_MULTICOLLATERAL_ACTIVATION_DESIGN_V1_COMPLETE`
      has landed.
- [ ] `DEOPT_WETH_COLLATERAL_ACTIVATION_DESIGN_V1.md` reviewed by
      risk committee.
- [ ] Insurance fund holds ≥ `depositCap × 0.20` USDC (empirical
      loss-cover ratio; adjust to your loss model).
- [ ] Chainlink WETH/USD proxy on Base identified and verified.
- [ ] Pyth WETH/USD feed id identified and verified against Hermes.

### Contract calls (all timelock-queued, `minDelay` wait, executed)

1. [ ] `CollateralVault.addCollateralToken(WETH_ADDRESS, 18)`.
2. [ ] `CollateralVault.setCollateralTokenConfig(WETH, depositCap=<C>,
       depositEnabled=true, withdrawalEnabled=true)`.
3. [ ] Deploy `ChainlinkPriceSource(chainlinkWethUsdAggregator)`.
4. [ ] Deploy `PythPriceSource(pythCore, pythWethUsdFeedId)`.
5. [ ] `OracleRouter.setMaxOracleDelay(1500)` (idempotent — no-op if
       already 1500).
6. [ ] `OracleRouter.setFeed(WETH, USDC, chainlinkAdapter,
       pythAdapter, maxDelay=1500, maxDeviationBps=100,
       isActive=true)`.

### Backend config

7. [ ] Flip `crate::config::collateral::WETH`:
       `deposit_enabled=true`, `collateral_factor_bps=<F>`,
       `liquidation_factor_bps=<L>`. `<F>` and `<L>` chosen by risk
       committee within bounds documented in
       `DEOPT_WETH_COLLATERAL_ACTIVATION_DESIGN_V1.md`.
8. [ ] Update `assert_v1_single_collateral_invariant` — it MUST
       still refuse V1 posture; activating WETH is an explicit
       "V1 done" event.
9. [ ] Wire vault balance reader to include WETH in `Balance` list
       with `is_deposit_enabled=true`, `is_withdrawal_enabled=true`,
       `collateral_factor_bps=<F>`.

### Frontend

10. [ ] `chains.ts::BASE_SEPOLIA` gains `collateralRegistry` entry
        for WETH (address, decimals). No code change to
        `BalancesCard`.
11. [ ] Deposit form: gate on `is_deposit_enabled === true` per
        `DEOPT_MULTICOLLATERAL_FRONTEND_CONTRACT_V1.md`.
12. [ ] E2E test: deposit 1 WETH → verify balance row appears with
        risk-adjusted USD value = `1 × oracle price × F/10_000`.

### Tests

13. [ ] Solidity: WETH-specific `OracleRouter` invariant tests.
14. [ ] Solidity: WETH-backed subaccount fuzz for open/reduce/close
        under WETH price ±30% and oracle failure.
15. [ ] Backend: `risk` module tests already validate the math; add
        an integration test asserting `assert_v1_single_collateral_invariant`
        now fails (proving the milestone crossed).
16. [ ] Frontend: e2e "deposit → open USDC-quoted position backed by
        WETH → close" flow.

### Rollback / disable

- [ ] Timelock: `OracleRouter.setFeed(WETH, ..., isActive=false)`.
- [ ] Timelock: `CollateralVault.setCollateralTokenConfig(WETH,
      depositEnabled=false, withdrawalEnabled=true)` — freezes
      deposits, users can still exit.
- [ ] Backend: revert step 7 (`collateral_factor_bps=0`).
- [ ] Frontend: revert step 11 (deposit gate flips back to USDC-only).

---

## Checklist 2 — cbBTC collateral on Base

Preconditions include all of Checklist 1's preconditions + all of
Checklist 1 completed (WETH activation validated in production for
at least one closed-test cycle before cbBTC lands).

### Additional preconditions

- [ ] Concentration-cap change from
      `DEOPT_COLLATERAL_CONCENTRATION_POLICY_V1.md` model (B) SHIPPED
      before cbBTC is activated.
- [ ] Per-wallet BTC exposure cap chosen by risk committee.

### Contract calls (all timelock-queued)

1. [ ] `CollateralVault.addCollateralToken(CBBTC_ADDRESS, 8)`.
2. [ ] `CollateralVault.setCollateralTokenConfig(CBBTC, depositCap=<C>,
       depositEnabled=true, withdrawalEnabled=true)`.
3. [ ] Reuse existing BTC/USD `ChainlinkPriceSource` +
       `PythPriceSource` adapters deployed during Base Sepolia infra
       broadcast (see `BASE_SEPOLIA_INFRA_BROADCAST_V1.md`) — cbBTC
       is priced off BTC/USD spot per design.
4. [ ] `OracleRouter.setFeed(CBBTC, USDC, chainlinkBtcAdapter,
       pythBtcAdapter, maxDelay=1500, maxDeviationBps=100,
       isActive=true)`.

### Backend

5. [ ] Flip `crate::config::collateral::CBBTC`:
       `deposit_enabled=true`, `collateral_factor_bps=<F>`,
       `liquidation_factor_bps=<L>` per design doc bounds.
6. [ ] Concentration-cap enforcement wired into the position-open
       gate.
7. [ ] Backend `Balance` row for cbBTC.

### Frontend

8. [ ] `chains.ts::BASE_SEPOLIA.collateralRegistry` gains cbBTC.
9. [ ] Deposit gate + e2e as with WETH.

### Tests

10. [ ] Solidity: cbBTC-backed subaccount fuzz including
        concentration cases (cbBTC collateral + long BTC-PERP).
11. [ ] Backend: concentration-cap unit test proving cap enforcement.
12. [ ] Backend: issuer-freeze simulation (cbBTC transferFrom
        reverts) — router falls back to fail-closed.
13. [ ] Frontend: e2e including a "cbBTC + BTC-PERP long" flow that
        should be blocked when it exceeds the cap.

### Rollback / disable

- [ ] Same three-step timelock/config/frontend revert as WETH.
- [ ] Concentration cap remains in place (a WETH-only future does
      not require removing it).

---

## Checklist 3 — Second EVM chain (Arbitrum as example)

Preconditions include all foundation + hardening milestones landed.

### 1. Solidity deployments (on Arbitrum)

- [ ] Deploy the full engine set on Arbitrum using the existing
      Foundry scripts (no source change required — SubKey,
      DeploymentManifest, OracleRouter are all `block.chainid`-aware).
- [ ] Deploy a fresh `SubaccountRegistry` on Arbitrum (its immutable
      `DEPLOYMENT_CHAIN_ID` binds to Arbitrum).
- [ ] Deploy `ChainlinkPriceSource` + `PythPriceSource` adapters
      against Arbitrum's Chainlink + Pyth addresses.
- [ ] `OracleRouter` configured with Arbitrum-native BTC/ETH/USD
      feeds.
- [ ] Timelock roles configured mirroring Base Sepolia posture.

### 2. Backend

- [ ] `crate::config::chains`: add `ARBITRUM` entry with
      `enabled=true`. Update `assert_v1_single_chain_invariant` (V1
      is done — this becomes a v-two invariant).
- [ ] Per-chain env var fanout at `AppConfig::from_env`:
      `BASE_RPC_URL` + `ARBITRUM_RPC_URL`, `BASE_EXECUTOR_*` +
      `ARBITRUM_EXECUTOR_*`, etc. See
      `DEOPT_SECOND_CHAIN_RUNTIME_ARCHITECTURE_V1.md` for the full
      slot list.
- [ ] Instantiate `ChainRuntime::build(ARBITRUM_CHAIN_ID,
      arbitrum_plumbing)` alongside the existing Base runtime.
- [ ] Spawn per-chain workers: one `IndexerRunner` per chain, one
      `HybridV2Runner` per chain, one funding worker per chain, etc.
      All existing workers already carry no shared mutable state.

### 3. DB / indexers

- [ ] No new migrations required for the two hardened tables
      (`indexer_cursors`, `indexed_perp_trades` — chain-scoped since
      migration 0062).
- [ ] Schema flip for `subaccounts`: current PK
      `(owner_address, subaccount_id)` → `(chain_id, owner_address,
      subaccount_id)`. Backfill existing rows to `chain_id = 84532`.
- [ ] Schema flip for `perp_positions` partial unique index:
      `(lower(account), market_id) WHERE status='open'` →
      `(chain_id, lower(account), market_id) WHERE status='open'`.
- [ ] Add `chain_id` column to any legacy table still classified
      **INTENTIONALLY_DEFERRED** in `DEOPT_MULTICHAIN_SCHEMA_HARDENING_V1.md`.

### 4. Frontend config

- [ ] `chains.ts`: flip `ARBITRUM` entry `enabled=true`. Add a
      network selector to the header. Wallet-mismatch banner already
      handles arbitrary chains.
- [ ] Per-chain deployment-address map in `chains.ts` (Options /
      Perps / Subaccounts contract addresses per chain).
- [ ] EIP-712 write-auth domain for Arbitrum (byte-frozen literal
      similar to Base Sepolia entry). Add to `chains.ts`.
- [ ] Signing paths: no code change required — `write-auth.ts`
      already derives the domain from `expectedChain()`.

### 5. Oracle configuration

- [ ] Arbitrum-native Chainlink BTC/USD + ETH/USD proxies.
- [ ] Arbitrum-native Pyth core + feed ids (chain-agnostic feed ids
      but confirm availability via Hermes).

### 6. EIP-712

- [ ] Confirm every intent-signing engine on Arbitrum uses OZ EIP712
      base (`block.chainid` → automatically bound to Arbitrum's
      chainid). No source change.

### 7. Executor

- [ ] Arbitrum executor EOA funded with ETH for gas.
- [ ] `PerpMatchingEngine.setExecutor(arbitrumExecutor, true)`
      timelock-mediated call.
- [ ] Confirm no shared nonce between chains (each executor's nonce
      is per-chain by construction).

### 8. Isolated collateral / margin state

- [ ] Confirm subaccount balances on Arbitrum cannot be dereferenced
      by a Base-chain SubKey (proven by `block.chainid` in SubKey
      derivation).
- [ ] Confirm no bridge / cross-chain-messaging module is deployed.
- [ ] Confirm insurance fund is per-chain (a Base liquidation cannot
      draw from an Arbitrum insurance fund).

### Rollback / disable

- [ ] `crate::config::chains::ARBITRUM.enabled = false`. Workers
      stop spawning against Arbitrum on next restart.
- [ ] Frontend: hide Arbitrum from the network selector.
- [ ] No contract calls required to "roll back" — the Arbitrum
      deployment simply becomes read-only from the platform's
      perspective (users can still call the Arbitrum contracts
      directly via a block explorer if they hold funds there).

---

## Global out-of-scope items (all three checklists)

- No bridge. Ever.
- No cross-chain shared margin.
- No cross-chain nonce coordinator.
- No mainnet activation (separate M-P7 gate).
- No production-parameter number in any of these checklists — every
  `<F>`, `<L>`, `<C>` is a risk-committee decision at activation
  time.
