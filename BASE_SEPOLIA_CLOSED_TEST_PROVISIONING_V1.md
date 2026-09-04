# PERPS_BASE_SEPOLIA_CLOSED_TEST_PROVISIONING_V1

Scope: Base Sepolia (chain id **84532**) only. **NO broadcast.** **NO secrets logged.** Perps stays **fail-closed** for the duration of this milestone. This document is the operator-facing provisioning inventory for Parts A (oracle configuration), C (deployment/authority), D (executor readiness — shape audit only), and E (closed-test allowlist plan).

Sources of truth used (relative to `~/DEOPT/`):

- `deopt-v2-sol/.env.base-sepolia.example`
- `deopt-v2-sol/deployments/base-sepolia.manifest.draft.json`
- `deopt-v2-sol/src/oracle/{ChainlinkPriceSource,PythPriceSource,OracleRouter}.sol`
- `deopt-v2-sol/src/perp/{PerpEngineAdmin,PerpEngineStorage,PerpEngineTrading,PerpEngineTypes}.sol`
- `deopt-v2-sol/src/matching/PerpMatchingEngine.sol`
- `deopt-v2-backend/src/config/env.rs`
- `deopt-v2-backend/src/api/{http.rs,routes.rs}`
- `deopt-v2-backend/src/auth/write_authorization.rs`
- `deopt-v2-backend/src/perps/observability.rs`
- `deopt-v2-backend/src/monitoring.rs`
- `deopt-v2-backend/src/execution/{transaction.rs,perp_trade.rs,mod.rs}`
- `deopt-v2-backend/src/signing/nonce.rs`
- `deopt-v2-backend/src/nonce_sync/mod.rs`
- `deopt-v2-frontend/src/lib/perps-closed-test-flag.ts`

Chainlink public docs (public infrastructure, not secrets):
- <https://docs.chain.link/data-feeds/price-feeds/addresses?network=base&page=1&search=sepolia>

Pyth public docs:
- <https://docs.pyth.network/price-feeds/contract-addresses/evm> (Pyth core contract per chain)
- <https://pyth.network/developers/price-feed-ids> (chain-agnostic feed IDs)

> **Note on this document's evidence for Chainlink / Pyth Base Sepolia**: This session's WebFetch tool was denied at runtime for the Chainlink and Pyth URLs above. This document therefore does not commit to any specific Chainlink adapter address or Pyth core address for Base Sepolia — it flags them as **OPERATOR MUST FETCH FROM CITED PUBLIC DOCS**. Fabricating an address here would violate the "do not invent addresses" rule. Once the operator (or a follow-up session with WebFetch enabled) has retrieved the values, the exact string replacements needed in this doc are called out explicitly in §1.

---

## 1. Oracle Configuration (Part A)

### 1.1 Contract-level shape

- Adapter for Chainlink: `ChainlinkPriceSource(address _aggregator)` — `src/oracle/ChainlinkPriceSource.sol:41`. Consumes `AggregatorV3Interface.latestRoundData()` (line 57), normalizes to 1e8 (constant `TARGET_DECIMALS = 8` at line 27). Reverts on any of: zero aggregator, `decimals > 36`, non-monotonic round, zero/future `updatedAt`, `answer <= 0`, scale overflow. OracleRouter catches revert and falls back to the secondary source.
- Adapter for Pyth: `PythPriceSource(address _pyth, bytes32 _priceId)` — `src/oracle/PythPriceSource.sol:43`. Consumes `IPyth.getPriceUnsafe(bytes32 id)` (line 57). Router applies the staleness gate via `maxDelay`.
- Router: `src/oracle/OracleRouter.sol`. Each feed carries `primarySource`, `secondarySource`, `maxDelay`, `maxDeviationBps`, `active`. Global cap `ORACLE_ROUTER_MAX_DELAY=600` (`.env.base-sepolia.example:131`).

### 1.2 Per-market configuration (BTC-PERP, ETH-PERP)

Base collateral token (`BASE_COLLATERAL_TOKEN`): **`0x6eae407f5640b006fac9965182e238582a3b412e`** (mUSDC, 6 decimals) — evidence: `deployments/base-sepolia.manifest.draft.json` `tokens.base_collateral.address`.

Underlyings:
- `ETH_UNDERLYING` = `0x4deebc5f537f3b8ba0e3393807b4d699d72bdd02` (mWETH, 18 decimals) — same manifest, `tokens.underlyings[0]`.
- `BTC_UNDERLYING` = `0x9d871ac7595e8da271e866608e5145252047967c` (mWBTC, 8 decimals) — same manifest, `tokens.underlyings[1]`.

| Market   | Base / Quote          | Primary source                                                                     | Secondary source                                                                   | `maxDelay` | Global `maxOracleDelay` | `maxDeviationBps` | Decimals |
| -------- | --------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------- | ----------------------- | ----------------- | -------- |
| ETH-PERP | mWETH / mUSDC         | `OPERATOR_MUST_SUPPLY_ETH_USD_PRIMARY_SOURCE` — see §1.3 for construction rules    | `OPERATOR_MUST_SUPPLY_ETH_USD_SECONDARY_SOURCE`                                    | 60 s       | 600 s                   | 1000 (10 %)       | 1e8      |
| BTC-PERP | mWBTC / mUSDC         | `OPERATOR_MUST_SUPPLY_BTC_USD_PRIMARY_SOURCE`                                       | `OPERATOR_MUST_SUPPLY_BTC_USD_SECONDARY_SOURCE`                                    | 60 s       | 600 s                   | 1000 (10 %)       | 1e8      |

Per-feed defaults come from `.env.base-sepolia.example` lines 122–130 (`*_MAX_DELAY=60`, `*_MAX_DEVIATION_BPS=1000`, `*_FEED_ACTIVE=true`). Global default at line 131 (`ORACLE_ROUTER_MAX_DELAY=600`). The current draft manifest at `deployments/base-sepolia.manifest.draft.json` lines 91–117 records `source_type: "mock"` at `0x3eb9…f6cc` (ETH primary), `0x2103…4517` (ETH secondary), `0x8cba…18bb` (BTC primary), `0x7206…970c` (BTC secondary) — these are `MockPriceSource` deployments, **not** dual-source production oracles, and MUST be replaced (or supplemented) before any closed-test participant is trusted to submit real intents.

### 1.3 Adapter provenance the operator must fill

The operator must produce EACH of these four adapter addresses. They are deployed by the operator (using existing repo scripts or manual `forge create ChainlinkPriceSource` / `forge create PythPriceSource`) but the **feed inputs** they consume come from public Chainlink / Pyth infrastructure.

1. **Chainlink ETH/USD proxy on Base Sepolia**
   - Look up at: `https://docs.chain.link/data-feeds/price-feeds/addresses?network=base&page=1&search=sepolia`.
   - If listed: construct `ChainlinkPriceSource(<proxy_address>)`.
   - If **not listed**: Chainlink has never guaranteed Base Sepolia data feeds. In that case the dual-source invariant cannot be satisfied with Chainlink; operator's only production-adjacent options are (a) Pyth-only, which **violates the dual-source invariant** and is therefore **blocked for closed-test** unless a governance carve-out is filed, or (b) deploy a second, independently-refreshed `MockPriceSource` (still a mock — acceptable for closed-test smoke but MUST NOT be treated as a real second source).
2. **Chainlink BTC/USD proxy on Base Sepolia** — same procedure as (1).
3. **Pyth core contract address on Base Sepolia**
   - Look up at: `https://docs.pyth.network/price-feeds/contract-addresses/evm`. Pyth has an EVM deployment on Base Sepolia; the operator must copy the exact `Pyth` contract address (there is only one per chain).
4. **Pyth feed IDs** (chain-agnostic bytes32; same values on every chain):
   - Crypto.ETH/USD and Crypto.BTC/USD — retrieve from `https://pyth.network/developers/price-feed-ids`.
   - Construct `PythPriceSource(<pyth_core_addr>, <feed_id_bytes32>)` twice (once per market).

**Dual-source invariant** (asserted): every active market feed MUST have a nonzero `primarySource` AND a nonzero, distinct-provider `secondarySource` before that market's `active` flag is set true in `OracleRouter`. This mirrors the shape enforced by the ETH_USDC_SECONDARY_SOURCE / BTC_USDC_SECONDARY_SOURCE variables in `.env.base-sepolia.example:120,127`, whose canonical resolution is "primary from provider P, secondary from provider Q ≠ P". Two mock feeds do NOT satisfy the invariant for a closed-test trusted with real capital.

### 1.4 Blocker classification (Part A)

- Chainlink ETH/USD Base Sepolia adapter address — **UNKNOWN in this session; operator must consult cited Chainlink URL**.
- Chainlink BTC/USD Base Sepolia adapter address — **UNKNOWN in this session; operator must consult cited Chainlink URL**.
- Pyth core address on Base Sepolia — **UNKNOWN in this session; operator must consult cited Pyth URL**.
- Pyth ETH/USD, BTC/USD feed IDs — **UNKNOWN in this session; operator must consult cited Pyth URL** (chain-agnostic).

---

## 2. Deployment / Authority Inventory (Part C)

Addresses that appear in `deopt-v2-sol/deployments/base-sepolia.manifest.draft.json` (canonical stack: `stack_a_wired_configured`) with follow-on rewires (`marginEngineV2`, `perpEngineV2`, `marginEngineV2gp`) are classified `DEPLOYED_AND_VALID`. Addresses that live only in `.env.base-sepolia.example` as `FILL_*` / `REQUIRED_*` placeholders and are not yet visible in the manifest are `NEEDS_DEPLOYMENT`. Addresses whose contract is on-chain but whose role wiring is not yet asserted for closed-test are `NEEDS_CONFIGURATION`.

| Component                             | Expected Addr                                                                                     | Source of Truth                                                                                          | Status                                             |
|---------------------------------------|---------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|----------------------------------------------------|
| CollateralVault                       | `0x00340c360353a5ab784c5bc5c44322a6af0625d3`                                                      | `deployments/base-sepolia.manifest.draft.json:16`; env `COLLATERAL_VAULT`                                | DEPLOYED_AND_VALID                                 |
| OracleRouter                          | `0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581`                                                      | manifest `contracts.OracleRouter` (line 17); env `ORACLE_ROUTER`                                         | DEPLOYED_AND_VALID (mock-only feeds — see §1.2)    |
| OptionProductRegistry                 | `0x3d52b033fab00ed6104dd3bc0a715f8648344eca`                                                      | manifest line 18; env `OPTION_PRODUCT_REGISTRY`                                                          | DEPLOYED_AND_VALID (options; not perps-critical)   |
| MarginEngine (V2G-P canonical)        | `0x506cD65a63C53c66ab572B9f9dd819B7BfE00D30`                                                      | manifest `marginEngineV2gp.newMarginEngine` (line 803)                                                   | DEPLOYED_AND_VALID                                 |
| MarginEngineLiquidationLib            | `0xB72A7BC82747cE2a0e11df1307B8cB7Ef085cc18`                                                      | manifest `marginEngineV2gp.newMarginEngineLiquidationLib` (line 804)                                     | DEPLOYED_AND_VALID                                 |
| RiskModule (Options)                  | `0xc0f019005a25524a34f2ee8839dcdcc50715dd7b`                                                      | manifest line 20; env `RISK_MODULE`                                                                      | DEPLOYED_AND_VALID                                 |
| PerpMarketRegistry                    | `0xb4fcf45e57b93274441def8f0f68bd30f6d677ec`                                                      | manifest line 21; env `PERP_MARKET_REGISTRY`                                                             | DEPLOYED_AND_VALID                                 |
| PerpEngine (V2 canonical)             | `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c`                                                      | manifest `perpEngineV2Phase1A3.perpEngineV2` (line 322); backend `PERP_ENGINE`                           | DEPLOYED_AND_VALID                                 |
| PerpEngineSeizureLib                  | `0x5D72a4e10207Da027eDF202B4EB40e3F92458a95`                                                      | manifest `perpEngineV2Phase1A3.perpEngineSeizureLib` (line 323)                                          | DEPLOYED_AND_VALID                                 |
| PerpEngine (OLD, stranded)            | `0xB36395b67D0798ADA981731c9Fa5239F4362b53B`                                                      | manifest `perpEngineV2Phase1A3.oldPerpEngine` (line 321); a3 fallback, NOT canonical                     | DEPRECATED_STRANDED                                |
| PerpRiskModule                        | `0xf1b46040147632d0b46a2153cc842506b4d7fee5`                                                      | manifest line 23; env `PERP_RISK_MODULE`                                                                 | DEPLOYED_AND_VALID                                 |
| CollateralSeizer                      | `0x39f928b959cf58369e7c7a3b925e6cbffa62b669`                                                      | manifest line 24                                                                                          | DEPLOYED_AND_VALID                                 |
| FeesManager (V1)                      | `0xaef73f10224712e1312963be11662061481aa0f0`                                                      | manifest line 25; env `FEES_MANAGER`                                                                     | DEPLOYED_AND_VALID                                 |
| FeesManagerV2                         | `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f`                                                      | manifest `feesManagerV2` (line 33), `perpFeesManagerV2` (line 591), wired+enabled on NEW PerpEngine      | DEPLOYED_AND_VALID                                 |
| InsuranceFund                         | `0x009f38440f058d095b61e0e2ee7fabdf05be7500`                                                      | manifest line 26                                                                                          | DEPLOYED_AND_VALID                                 |
| MatchingEngine (legacy option)        | `0x93a6d3f540b72f05b4edbe071fa611af942423da`                                                      | manifest line 27                                                                                          | DEPLOYED_AND_VALID (legacy path)                   |
| OptionMatchingEngine (V2G-P canon.)   | `0x5a5EBF9A9CCd7c012518569DE8283982982670f6`                                                      | manifest `marginEngineV2gp.newOptionMatchingEngineCanonical` (line 805)                                  | DEPLOYED_AND_VALID                                 |
| PerpMatchingEngine                    | `0x774d96E5739bffadEE91508b4D3D74F5BE29F165`                                                      | manifest `contracts.PerpMatchingEngine` (line 29); backend `PERP_MATCHING_ENGINE`                        | DEPLOYED_AND_VALID (unpaused: manifest line 640)   |
| ProtocolTimelock                      | `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588`                                                      | manifest line 30; env `PROTOCOL_TIMELOCK`                                                                | DEPLOYED_AND_VALID                                 |
| RiskGovernor                          | `0x7918ea95c2791b6b587ff02ae481fa52403877a0`                                                      | manifest line 31; env `RISK_GOVERNOR`                                                                    | DEPLOYED_AND_VALID                                 |
| MockUSDC (base collateral)            | `0x6eae407f5640b006fac9965182e238582a3b412e`                                                      | manifest `tokens.base_collateral.address` (line 71)                                                      | DEPLOYED_AND_VALID (testnet mock)                  |
| MockWETH (ETH underlying)             | `0x4deebc5f537f3b8ba0e3393807b4d699d72bdd02`                                                      | manifest `tokens.underlyings[0].address` (line 78)                                                       | DEPLOYED_AND_VALID (testnet mock)                  |
| MockWBTC (BTC underlying)             | `0x9d871ac7595e8da271e866608e5145252047967c`                                                      | manifest `tokens.underlyings[1].address` (line 84)                                                       | DEPLOYED_AND_VALID (testnet mock)                  |
| Chainlink ETH/USD adapter             | *n/a — see §1.3*                                                                                  | Constructor: `ChainlinkPriceSource(address _aggregator)` at `src/oracle/ChainlinkPriceSource.sol:41`      | NEEDS_DEPLOYMENT (no aggregator address available) |
| Chainlink BTC/USD adapter             | *n/a — see §1.3*                                                                                  | Same constructor as above                                                                                | NEEDS_DEPLOYMENT                                   |
| Pyth ETH/USD adapter                  | *n/a — see §1.3*                                                                                  | Constructor: `PythPriceSource(address _pyth, bytes32 _priceId)` at `src/oracle/PythPriceSource.sol:43`   | NEEDS_DEPLOYMENT                                   |
| Pyth BTC/USD adapter                  | *n/a — see §1.3*                                                                                  | Same constructor as above                                                                                | NEEDS_DEPLOYMENT                                   |
| Governance owner (deployer EOA)       | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`                                                      | manifest `marginEngineV2Phase1.deployer` (line 301); `perpEngineV2Phase1A3.deployer` (line 326)          | DEPLOYED_AND_VALID (EOA — not yet a multisig)      |
| Governance owner (target multisig)    | *n/a*                                                                                             | env `FINAL_GOVERNANCE_OWNER`; still `REQUIRED_FINAL_GOVERNANCE_OWNER` in the example file                | NEEDS_CONFIGURATION                                |
| Guardian                              | *n/a*                                                                                             | env `GOVERNANCE_GUARDIAN` / `INITIAL_GUARDIAN`; `.env.base-sepolia.example:53,70`                        | NEEDS_CONFIGURATION                                |
| Executor (perp matching engine EOA)   | *pending operator (env `PERP_MATCHING_EXECUTOR`); manifest `preconditionsObserved.PerpMatchingEngine.isExecutor_deployer=true` shows deployer EOA is currently the sole allowlisted executor (line 453)* | `PerpMatchingEngine.setExecutor(address,bool)` at `src/matching/PerpMatchingEngine.sol:373`              | NEEDS_CONFIGURATION (rotate off deployer)          |
| Impact-mid publisher EOA              | *not set on-chain in current manifest*                                                            | `PerpEngine.setImpactMidSource(address)` at `src/perp/PerpEngineAdmin.sol:176`                            | NEEDS_CONFIGURATION (funding is disabled anyway — see §4) |

Notes:
- **Perp matching engine is currently `unpaused=false`** (manifest `perpEngineV2Phase3aUnpause.postReads.PerpMatchingEngine.paused: false`, line 640) and `isExecutor[deployer] = true` (line 453). For closed-test, the operator MUST rotate this to a dedicated hot executor EOA (not the deployer key) via `setExecutor(newExec, true)` followed by `setExecutor(deployer, false)`.
- **FeesManagerV2 is enabled** on `PerpEngine` (manifest line 45, 505–511) and has completed a V2 fees smoke (line 513–589). No config change needed for closed-test fees.
- **`impactMidSource` is unset** for the canonical PerpEngine because funding V2 is not being exercised in this milestone. `ETH_PERP_IMPACT_MID_MAX_DELAY=0` and `BTC_PERP_IMPACT_MID_MAX_DELAY=0` (`.env.base-sepolia.example:235,260`) short-circuit the keeper read. This is intentional: no keeper EOA, no funding rate. See §3.

---

## 3. Executor Provisioning Readiness (Part D)

Read-only permission audit only. No key material, no funding, no broadcast.

### 3.1 Matching-engine executor EOA

- **Role assignment (contract → function)**: `PerpMatchingEngine.setExecutor(address executor, bool allowed)` — `deopt-v2-sol/src/matching/PerpMatchingEngine.sol:373`. `onlyOwner`-gated. Reverts `ZeroAddress` on zero (line 374).
- **State query**: `PerpMatchingEngine.isExecutor(address) → bool` (public mapping declared at line 151).
- **Fail-closed on missing role**: any call to `executeTrade(...)` from an unauthorized EOA reverts `NotAuthorized()` via `onlyExecutor` modifier — line 301, applied on the four external execution entrypoints at lines 607, 617, 650.
- **Chain-id target**: 84532 (Base Sepolia). Enforced backend-side by `execution/remote_signer::BASE_SEPOLIA_CHAIN_ID` export (`deopt-v2-backend/src/execution/mod.rs:37`), and cross-checked in startup validation via `PERPS_PUBLIC_TRADING_ENABLED=true` on mainnet chain ids being **explicitly refused** (`config/env.rs:836-838, 847-849`).
- **Signer interface**: **EIP-1559**. See `assemble_eip1559_signed_transaction` and `eip1559_transaction_prehash` re-exports (`deopt-v2-backend/src/execution/mod.rs:48-50`) and `ExecutionTransactionRequest.chain_id: u64` / `max_fee_per_gas_wei` / `max_priority_fee_per_gas_wei` (`deopt-v2-backend/src/execution/transaction.rs:72-75`).
- **Nonce handling (per-EOA)**: two layers.
  - Off-chain nonce ledger for signed intents: `deopt-v2-backend/src/signing/nonce.rs::NonceStore` — `reserve(&mut self, account, nonce)` rejects zero and duplicates; `NonceAlreadyUsed` on collision.
  - On-chain matching-engine nonce sync: `deopt-v2-backend/src/nonce_sync/mod.rs::read_perp_nonce` (lines 153-172) reads `PerpMatchingEngine.nonces(address)` and `validate_order_perp_nonce` (line 211) rejects mismatched user nonces before submission. The backend errors out with a clear message if `RPC_URL` is unset (line 266).
- **Gas estimation**: use `cast estimate --rpc-url <BASE_SEPOLIA_RPC>` against `PerpMatchingEngine.executeTrade(...)` calldata built via `execution::build_perp_execution_call_from_intent` (`execution/tx_builder.rs:76`). Suggested per-op ceiling: **1.5 M gas** for `executeTrade` (measured broadcast at manifest line 866140 gasUsed for the V1 smoke and 633692 for the V2 smoke → generous ceiling of 1.5 M covers both fee dispatch paths). Set `max_fee_per_gas` off Base Sepolia base fee + 2 gwei priority tip.
- **NO** private-key material read, logged, printed, or committed in this milestone.
- **NO** funding step in this milestone. Executor EOA funding is a separate operator task and MUST use the same "operator supplies via env, never echoed, never committed" pattern already used for `PERP_SMOKE_BUYER_PRIVATE_KEY` / `PERP_SMOKE_SELLER_PRIVATE_KEY` (see manifest `keyHandling` at line 672).

**Read-only validation the operator can perform** (once an executor address is chosen; NO address is being supplied by this session):

```bash
export PATH="$HOME/.foundry/bin:$PATH"
# NOTE: RPC_URL is supplied by the operator via env; never committed.
PERP_MATCHING_ENGINE=0x774d96E5739bffadEE91508b4D3D74F5BE29F165
cast call --rpc-url "$RPC_URL" \
  "$PERP_MATCHING_ENGINE" \
  "isExecutor(address)(bool)" \
  "$CANDIDATE_EXECUTOR_ADDR"
# Expected: true after setExecutor; false if not yet allowlisted.
```

If it returns `false`, the operator must `setExecutor(candidate, true)` **as owner** before the closed-test tester can be matched.

### 3.2 Impact-mid publisher EOA

- **Role assignment**: `PerpEngine.setImpactMidSource(address source)` — `deopt-v2-sol/src/perp/PerpEngineAdmin.sol:176`. `onlyOwner`-gated. Reverts `InvalidImpactMidSource()` on zero (line 177). Emits `ImpactMidSourceSet(old, source)`.
- **State query**: `PerpEngine.impactMidSource()` (public state var at `src/perp/PerpEngineStorage.sol:182`).
- **Fail-closed on missing role**: `PerpEngine.updateImpactMid(marketId, mid1e8)` — `src/perp/PerpEngineTrading.sol:223` — carries the `onlyImpactMidSource` modifier defined in `PerpEngineStorage.sol:236-239`. Reverts **`NotImpactMidSource()`** (error declared at `src/perp/PerpEngineTypes.sol:258`) from any caller ≠ configured `impactMidSource`. Also reverts if funding is globally paused (`whenFundingNotPaused`), if the market does not exist, or if `mid1e8 == 0` (`OraclePriceUnavailable()`).
- **Funding disabled in this milestone**: `.env.base-sepolia.example` sets `ETH_PERP_FUNDING_ENABLED=false` (line 229) and `BTC_PERP_FUNDING_ENABLED=false` (line 254). `ETH_PERP_IMPACT_MID_MAX_DELAY=0` (line 235) and `BTC_PERP_IMPACT_MID_MAX_DELAY=0` (line 260) short-circuit the keeper read. `impactMidSource` MAY remain unset for closed-test smoke; if the operator sets it, use the "operator supplies via env, never echoed" pattern.
- **NO** funding tick issued in this milestone. `admin_perps_funding_tick` route (`api/routes.rs:345`) exists but is admin-gated and not part of this provisioning package.

### 3.3 Verdict shape (this section)

Both role setters exist, are `onlyOwner`, revert on zero, and the runtime paths fail-closed with named revert reasons (`NotAuthorized`, `NotImpactMidSource`). The shape audit is **PASS**. Actual EOA provisioning + on-chain `setExecutor` broadcast is an operator step outside this milestone.

---

## 4. Closed-Test Allowlist Plan (Part E)

### 4.1 Operator env-var block (backend)

```
# Public trading MUST remain false for this milestone. Startup validation
# refuses PERPS_PUBLIC_TRADING_ENABLED=true on mainnet chain ids
# (config/env.rs:836-838).
PERPS_PUBLIC_TRADING_ENABLED=false

# Closed-test flag. Startup validation refuses this flag on mainnet chain
# ids (config/env.rs:847-849). Default false; operator flips to true only
# after allowlist below is non-empty AND the frontend rebuild carries a
# matching NEXT_PUBLIC_PERPS_CLOSED_TEST_ENABLED=true.
PERPS_CLOSED_TEST_ENABLED=false

# Comma-separated 0x addresses (hex, case-insensitive). Default empty =
# nobody is allowed even when the flag above is true — this is the
# "honest closed test with no allowlisted wallets" fail-closed
# posture documented at http.rs:833-834.
PERPS_CLOSED_TEST_ALLOWLIST=

# Per-market funding stays off in this milestone (contract-side config,
# already committed to .env.base-sepolia.example:229,254). Do not enable.
# There is no top-level FUNDING_ENABLED env — funding is enabled per
# market via ETH_PERP_FUNDING_ENABLED / BTC_PERP_FUNDING_ENABLED which
# MUST remain `false`.
```

### 4.2 Frontend env-var block (Next.js public build)

```
NEXT_PUBLIC_PERPS_TICKET_ENABLED=false        # keeps the submit button non-interactive
NEXT_PUBLIC_PERPS_CLOSED_TEST_ENABLED=false   # UI-only signal (deopt-v2-frontend/src/lib/perps-closed-test-flag.ts:16); default false
```

### 4.3 Backend authority — the layered gate

- **Layer 1 (default fail-closed)** — `api/routes.rs:3076-3079` and `api/routes.rs:3221`. Both `perps_public_trading_enabled` and `perps_closed_test_enabled` false → `PerpsNotLive` (503) at handler entry, before any envelope, subaccount, or signature work. This is the "hard public-route disable" invariant that this codebase's non-live products always enforce.
- **Layer 2 (allowlist filter)** — `api/routes.rs:3085-3088` and `api/routes.rs:3508-3511`. When `perps_closed_test_enabled == true`, caller wallet must be present in `perps_closed_test_allowlist`; else `PerpsNotLive` (503, deliberately NOT 401/403 so the endpoint cannot be probed as an allowlist oracle).
- **Layer 3 (envelope v2)** — `api/routes.rs:3094-3098`. Perps never shipped a v1 wire.
- **Layer 4 (subaccount resolve + ownership)** — `api/routes.rs:3100-3103, 3513+`.
- **Layer 5 (EIP-712 verify)** — `api/routes.rs:3491-3502` (signed-intent surface at `/perps/orders/signed`).

`perps_closed_test_allows(caller)` is defined at `api/http.rs:836-844`:
- returns `false` if the flag is off
- returns `false` if the allowlist is empty
- returns `true` only if a case-insensitive match is present in `perps_closed_test_allowlist`

**Observability**: `deopt-v2-backend/src/perps/observability.rs::record_closed_test_access_denied` (line 192-195) increments `closed_test_access_denied_total`; exported as Prometheus counter `deopt_perps_closed_test_access_denied_total` (`monitoring.rs:359-361`). The complementary counter `deopt_perps_not_live_reject_total` (`monitoring.rs` around line 355) covers Layer 1 rejects. Operator MUST watch both during rollout.

### 4.4 Frontend flag independence

`deopt-v2-frontend/src/lib/perps-closed-test-flag.ts` (whole file: 33 lines) hardcodes the flag as **informational UI copy only**. Comment block at lines 1-14 explicitly states "nothing here bypasses the backend allowlist". Even with `NEXT_PUBLIC_PERPS_CLOSED_TEST_ENABLED=true`, submit stays disabled unless `NEXT_PUBLIC_PERPS_TICKET_ENABLED=true`, and the backend is the real gate. The frontend flag cannot open the backend gate; the backend flag cannot open the ticket UI on its own.

### 4.5 Activation sequence for the operator

1. **Choose closed-test tester wallets** (EOAs owned by trusted testers). Do NOT include the deployer key, the executor EOA, or the impact-mid keeper EOA in this allowlist — those are protocol operators, not testers.
2. **Populate `PERPS_CLOSED_TEST_ALLOWLIST`** as a comma-separated 0x string. Keep `PERPS_CLOSED_TEST_ENABLED=false` at this stage; the backend will remain fail-closed regardless of the allowlist contents. Verify via `curl -s /admin/perps/closed-test-config` or reading `/metrics` (`deopt_perps_closed_test_enabled` snapshot gauge derived from `state.perps_closed_test_enabled`, `monitoring.rs:134`).
3. **Flip `PERPS_CLOSED_TEST_ENABLED=true`** on the backend deploy that already carries the populated allowlist. Restart. Confirm `/metrics` reports `deopt_perps_closed_test_enabled 1` and both counters are 0.
4. **Rebuild the frontend with `NEXT_PUBLIC_PERPS_TICKET_ENABLED=true` and `NEXT_PUBLIC_PERPS_CLOSED_TEST_ENABLED=true`** so allowlisted testers see the correct copy AND the ticket UI is interactive. The old build (both flags false) MUST NOT be reachable at the same URL during this window.
5. **Tester submits a signed intent** to `POST /perps/orders/signed`. Backend traverses Layers 1→5. On success the intent is queued for execution against `PerpMatchingEngine` at `0x774d96E5739bffadEE91508b4D3D74F5BE29F165`. On any failure the tester sees a 503 or 401 — no probing surface is exposed.
6. **Rollback path**: flip `PERPS_CLOSED_TEST_ENABLED=false` on the backend and restart. All signed-intent submissions immediately fail-close with 503 `PerpsNotLive` at Layer 1. The frontend flag becomes irrelevant.

---

## 5. Verdicts

- **PERPS_BASE_SEPOLIA_ORACLE_CONFIG_WAITING_FOR_OPERATOR**

  Concrete missing addresses:
  1. Chainlink ETH/USD aggregator proxy on Base Sepolia (from `https://docs.chain.link/data-feeds/price-feeds/addresses?network=base&page=1&search=sepolia`).
  2. Chainlink BTC/USD aggregator proxy on Base Sepolia (same URL).
  3. Pyth core contract address on Base Sepolia (from `https://docs.pyth.network/price-feeds/contract-addresses/evm`).
  4. Pyth Crypto.ETH/USD feed id `bytes32` (from `https://pyth.network/developers/price-feed-ids`).
  5. Pyth Crypto.BTC/USD feed id `bytes32` (same URL).
  6. Deployed `ChainlinkPriceSource(<3.1.1>)` and `ChainlinkPriceSource(<3.1.2>)` adapter addresses.
  7. Deployed `PythPriceSource(<3.1.3>, <3.1.4>)` and `PythPriceSource(<3.1.3>, <3.1.5>)` adapter addresses.

  Until 1–7 exist, `ETH_USDC_PRIMARY_SOURCE`, `ETH_USDC_SECONDARY_SOURCE`, `BTC_USDC_PRIMARY_SOURCE`, `BTC_USDC_SECONDARY_SOURCE` in `.env.base-sepolia` remain `REQUIRED_*` placeholders (per example lines 119-128) OR the four existing `MockPriceSource` addresses (manifest §oracles.feeds), which do **not** satisfy the dual-source invariant for closed-test.

- **Part C classification summary**
  - `DEPLOYED_AND_VALID`: CollateralVault, OracleRouter (router only — feeds mock), OptionProductRegistry, MarginEngine (V2G-P), MarginEngineLiquidationLib, RiskModule, PerpMarketRegistry, PerpEngine (V2), PerpEngineSeizureLib, PerpRiskModule, CollateralSeizer, FeesManager V1, FeesManagerV2, InsuranceFund, legacy MatchingEngine, OptionMatchingEngine (V2G-P canonical), PerpMatchingEngine, ProtocolTimelock, RiskGovernor, MockUSDC, MockWETH, MockWBTC, Governance-owner-as-deployer-EOA.
  - `NEEDS_DEPLOYMENT`: Chainlink ETH/USD adapter, Chainlink BTC/USD adapter, Pyth ETH/USD adapter, Pyth BTC/USD adapter.
  - `NEEDS_CONFIGURATION`: FINAL_GOVERNANCE_OWNER (multisig hand-off), Guardian, dedicated perp matching executor EOA (rotate off deployer), impact-mid publisher EOA (optional in this milestone since funding is disabled).
  - `DEPRECATED_STRANDED`: OLD PerpEngine `0xB363…b53B` (a3 fallback; not authorized in Vault/InsuranceFund per manifest `postRewireReads` lines 372-380).

- **PERPS_BASE_SEPOLIA_EXECUTOR_READINESS_VALIDATED** — shape audit only, per §3. `setExecutor` and `setImpactMidSource` present, `onlyOwner`, zero-guarded, revert-named on unauthorized runtime calls (`NotAuthorized`, `NotImpactMidSource`). Backend uses EIP-1559 signer, per-EOA nonce ledger (`NonceStore`), and chain-id-bound signing (`BASE_SEPOLIA_CHAIN_ID = 84532`).

- **PERPS_BASE_SEPOLIA_CLOSED_TEST_ACCESS_READY** — the layered fail-closed gate is in place. Default posture is: backend 503s every Perps mutation, frontend keeps the ticket disabled, allowlist is empty. Operator activation sequence is documented in §4.5. Rollback is single-env-flag + restart.
