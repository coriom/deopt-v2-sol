# PERPS_BASE_SEPOLIA_INFRA_BROADCAST_V1 — FROZEN MANIFEST

Scope: Base Sepolia (chain id **84532**) only. This document is the **frozen** on-chain infrastructure sequence required before any Perps closed-test trade. It contains NO broadcast, NO secrets, NO private-key material.

Perps stays **fail-closed** for the duration of this milestone. Nothing here enables public perps, enables closed-test allowlist access, enables per-market funding, submits any order, or opens any position. Those are separate, later, explicitly-authorized actions.

Predecessor: `BASE_SEPOLIA_CLOSED_TEST_PROVISIONING_V1.md` (operator provisioning inventory).
Companion script: `script/BaseSepoliaInfraBroadcastPreview.s.sol` (view-only, fork-simulated, no `vm.startBroadcast` anywhere).

Sources of truth:

- `deopt-v2-sol/src/oracle/{ChainlinkPriceSource,PythPriceSource,OracleRouter}.sol`
- `deopt-v2-sol/src/matching/PerpMatchingEngine.sol`
- `deopt-v2-sol/src/gouvernance/ProtocolTimelock.sol`
- `deopt-v2-sol/test/oracle/OracleRouterDualSourceInvariant.t.sol` (canonical `DEV_BPS = 100`)
- `deopt-v2-sol/deployments/base-sepolia.manifest.draft.json`
- On-chain reads captured **2026-09-07** at Base Sepolia block **46,487,688** (timestamp `1788743664`).

---

## 1. Authoritative oracle inputs (verified live)

All four inputs verified via `cast call` against `https://sepolia.base.org` at chain id 84532. Full deployed bytecode present at each address; all four probes returned non-zero.

| Input                              | Address / bytes32                                                              | Provenance                                                                                                              | Live probe result (capture window)                              |
|------------------------------------|--------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|
| Chainlink ETH/USD proxy            | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`                                   | `https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-base-1.json` (name = "ETH / USD"), decimals=8, heartbeat=1200s | `answer = 250929000000` (=$2 509.29), `updatedAt` age 138s     |
| Chainlink BTC/USD proxy            | `0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298`                                   | Same directory (name = "BTC / USD"), decimals=8, heartbeat=1200s                                                        | `answer = 8002096791898` (=$80 020.97), `updatedAt` age 314s   |
| Pyth core contract (Base Sepolia)  | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`                                   | `https://docs.pyth.network/price-feeds/contract-addresses/evm` (Base Sepolia Testnet "Upgraded Address")                | `getPriceUnsafe` responds for both feed IDs                     |
| Pyth ETH/USD feed id (bytes32)     | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`           | `https://hermes.pyth.network/v2/price_feeds?query=ETH/USD&asset_type=crypto` (`Crypto.ETH/USD`), chain-agnostic          | expo `-8`, publishTime age **65 932 s ≈ 18.3 h**                |
| Pyth BTC/USD feed id (bytes32)     | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`           | `https://hermes.pyth.network/v2/price_feeds?query=BTC/USD&asset_type=crypto` (`Crypto.BTC/USD`), chain-agnostic          | expo `-8`, publishTime age **69 500 s ≈ 19.3 h**                |

Cross-source deviation at capture (Chainlink vs on-chain Pyth on the same asset):
- ETH: `|250929000000 − 250601722002| / 250601722002 ≈ 0.13 %`
- BTC: `|8002096791898 − 7997953914549| / 7997953914549 ≈ 0.052 %`

Both are well under the frozen `maxDeviationBps = 100` cap (see §4).

### `CLOSED_TEST_ACCEPTED_LIMITATION` — Pyth staleness on Base Sepolia

Pyth EVM feeds are **pull-based**: a keeper must call `updatePriceFeeds` on the Pyth core for `publishTime` to advance. At capture, on-chain Pyth `publishTime` was ~18–19 h stale for both ETH and BTC feeds. With the frozen per-feed `maxDelay = 1500 s`, the router treats Pyth as stale and — via `_readConfiguredFeed` — degrades to Chainlink-only reads (`if (ok1 && !ok2) return (true, p1, t1, Ok);`).

This is **fail-closed acceptable for closed-test** because:

- public Perps stays OFF (`PERPS_PUBLIC_TRADING_ENABLED=false`, refused on mainnet at startup);
- funding V2 stays OFF (per-market env flag AND deployed bytecode does not route the funding setter selectors);
- Chainlink freshness remains enforced (per-feed 1500 s bound, `_isTimestampUsable` in `_readConfiguredFeed`);
- stale Pyth is **never** used as "fresh corroboration"; when Pyth is stale, deviation is not checked; only when both are fresh is `_deviationBps` compared to the cap.

**Explicit label**: `CLOSED_TEST_ACCEPTED_LIMITATION`. This is **NOT** final public-production dual-source readiness. Before flipping `PERPS_PUBLIC_TRADING_ENABLED=true`, the operator MUST address one of:

1. Run a small Pyth-update keeper on Base Sepolia (calls `pyth.updatePriceFeeds` at a bounded cadence).
2. Replace Pyth with a different **independently-refreshed** secondary source (e.g., a second Chainlink-style provider or a custom TWAP contract that is actively pushed).
3. Explicitly document that the router is operating single-source-Chainlink and accept the concentration risk (not recommended for mainnet).

This gate is a **hard prerequisite** for any future `PERPS_PUBLIC_TRADING_ENABLED=true` broadcast on any chain.

---

## 2. Frozen tunables

All chosen for Base Sepolia with the CLOSED_TEST_ACCEPTED_LIMITATION above:

| Parameter               | Value  | Rationale                                                                                                                                  |
|-------------------------|--------|--------------------------------------------------------------------------------------------------------------------------------------------|
| Global `maxOracleDelay` | `1500` | Chainlink Base Sepolia heartbeat = 1200 s; 1500 s = heartbeat + 300 s safety margin. Effective delay = min(nonzero feed, nonzero global). |
| Per-feed `maxDelay`     | `1500` | Same reasoning; applied per feed for parity with the global cap.                                                                            |
| `maxDeviationBps`       | `100`  | See §4 — matches the codebase's canonical `OracleRouterDualSourceInvariantTest.DEV_BPS = 100` (1 %).                                        |
| `isActive`              | `true` | Feed swap is atomic (`setFeed` writes the full `FeedConfig` struct in one write) — no half-configured window.                              |
| Timelock `eta` margin   | `1 h`  | `eta = queueBlockTimestamp + 86400 + 3600`. Absorbs block-time drift and RPC lag when the queue tx lands.                                  |
| Executor rotation       | swap   | `setExecutor(newExec, true)` **then** `setExecutor(deployer, false)`; ordering constraint documented at TX-12.                             |

---

## 3. Timelock role map — proven on-chain (2026-09-07 block 46 487 688)

`OracleRouter.setFeed(...)` and `OracleRouter.setMaxOracleDelay(...)` are `onlyOwner`. Owner = `ProtocolTimelock @ 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`. Every router config change therefore requires the timelock's `queueTransaction` → wait ≥`minDelay` → `executeTransaction` path.

Read via `cast call --rpc-url https://sepolia.base.org 0xa67f...b588 ...` and re-asserted with `require(...)` inside the preview script (script aborts loudly if any of these drift):

| Timelock property            | Value                                                                   | Consequence                                                                        |
|------------------------------|-------------------------------------------------------------------------|------------------------------------------------------------------------------------|
| `owner()`                    | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`                            | Only this key can add/remove proposers/executors and change `minDelay`.            |
| `guardian()`                 | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (same as owner)            | Can cancel queued ops and pause queueing; cannot execute.                          |
| `minDelay()`                 | **`86400`** seconds (24 h)                                              | Every queued op must set `eta >= block.timestamp + 86400` at queue time.           |
| `queuePaused()`              | `false`                                                                 | `queueTransaction` is currently allowed.                                            |
| `proposers[0xA6B9…dcD46]`    | **`true`**                                                              | The gov key is the sole proposer.                                                   |
| `executors[0xA6B9…dcD46]`    | **`true`**                                                              | The gov key is the sole executor.                                                   |
| `proposers[deployer=0xc35F…3C27]` | `false`                                                            | Deployer **cannot** queue timelock ops. **No deployer bypass exists.**             |
| `executors[deployer=0xc35F…3C27]` | `false`                                                            | Deployer **cannot** execute timelock ops.                                          |
| `proposers[address(0)]`      | `false`                                                                 | No open-execution loophole.                                                        |
| `executors[address(0)]`      | `false`                                                                 | Same.                                                                              |
| `GRACE_PERIOD` (constant)    | 14 days                                                                 | Execute window is `[eta, eta + 14 days]`.                                          |

**Queue → execute pairing** (proved by identical `operation hash = keccak256(abi.encode(target, 0, innerCalldata, eta))`, reproduced by the preview script for every pair at the capture eta `1788833664`):

| Router op                            | Inner calldata                                                                                                                                                              | Queue TX | Execute TX | Operation hash (at capture eta)                                    |
|--------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------|------------|--------------------------------------------------------------------|
| `setMaxOracleDelay(1500)`            | `0x80cea4a2000…5dc`                                                                                                                                                          | TX-05    | TX-08      | `0x3c431b5efa0eede628920cfc29c7c5b3dd4ada9b48fb64dc9a2b43f16191ffec` |
| `setFeed(mWETH,mUSDC,chEth,pyEth,1500,100,true)` | see script output                                                                                                                                              | TX-06    | TX-09      | `0xa3e4cee947052b26c291edebef6dd6434ec1e05934480bd73b5ecf84068ab803` |
| `setFeed(mWBTC,mUSDC,chBtc,pyBtc,1500,100,true)` | see script output                                                                                                                                              | TX-07    | TX-10      | `0xb4acf739b2bc35f72c1b28b02c80e36a593ba0e50ba5a79259187648da0de5e8` |

Note: the operation-hash values above pin `eta = 1788833664`. At real broadcast time the operator picks a fresh `eta` from `queueBlockTimestamp + 86400 + 3600` and the three hashes shift correspondingly. The preview script re-emits fresh hashes for whatever `block.timestamp` the fork reports.

---

## 4. Deviation cap: 100 bps (1 %) — rationale

Frozen at `maxDeviationBps = 100`.

**Why this value:**

- **Matches the codebase's own canonical fixture.** `test/oracle/OracleRouterDualSourceInvariant.t.sol:33` declares `uint16 internal constant DEV_BPS = 100; // 1%`. This is the value against which the router's dual-source invariant is asserted in the audit-driven test suite for PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 Part A. Broadcasting with the same value keeps production semantics aligned with tested semantics.
- **Well below the perp exec-price guard cap** (`test/perp/PerpEngineExecutionPriceGuard.t.sol:134 -- GUARD_BAND_BPS = 200`). Defense-in-depth: the oracle read rejects a >1 % oracle-vs-oracle divergence before the exec-price guard ever sees the reference mark. Two cascading bounds catch different failure modes.
- **>30× above observed live divergence.** At capture, on-chain Chainlink/Pyth divergence was 0.13 % (ETH) and 0.052 % (BTC). Note ETH is higher because on-chain Pyth is ~18 h stale — the actual "when both fresh" divergence is expected to be closer to 0.03 % based on the previous capture window.
- **>6× above Chainlink's own on-chain deviation trigger** (0.15 % for ETH / 0.1 % for BTC per the Chainlink reference-directory manifest). Even at ~10 heartbeats worth of drift the cap still holds.
- **Rejects unambiguous anomalies.** A 1 % gap between two independent USD-pricing providers on BTC/ETH is very rare in normal operation and warrants a hard fail. On-chain: `if (dev > maxDev) return (false, 0, 0, ReadStatus.Deviation);` → caller reverts `DeviationTooHigh`.

**Simulation against expected scenarios:**

| Scenario                                 | Expected Chainlink | Expected Pyth (fresh) | Deviation | Outcome under 100 bps cap |
|------------------------------------------|--------------------|------------------------|-----------|----------------------------|
| Normal quiet market (observed)           | reference          | ≈ reference ± 0.03 %   | 0.03 %    | **Pass** (dual-source Ok)  |
| Elevated market (observed at capture)    | reference          | ≈ reference ± 0.13 %   | 0.13 %    | **Pass** (dual-source Ok)  |
| Chainlink 1200 s stale, Pyth 60 s fresh  | stale but usable   | fresh                  | 0.3–0.6 % typical | **Pass**                   |
| Pyth stale (Base Sepolia baseline)       | fresh              | stale (>1500 s)        | n/a       | **Pass** (single-source Chainlink) |
| Genuine 1.5 % divergence (rare stress)   | reference          | reference × 1.015      | 1.5 %     | **Fail-closed** — `DeviationTooHigh` — good |
| 3 % divergence (very rare / mispriced)   | reference          | reference × 1.03       | 3 %       | **Fail-closed** — good     |
| Boundary case exactly at cap             | reference          | reference × 1.01       | 1.0 %     | Passes (`dev > maxDev` is strict `>`)   |

**If 100 bps proves too tight in operation** (e.g., frequent `DeviationTooHigh` reverts during rapid market moves), the widen-up path is a new `setFeed(...)` through the timelock — a 24 h owner action, not an emergency. The safer default is: start tight, widen only with evidence. If the operator ever needs an emergency loosen path, the pattern is `router.pauseReads()` from guardian (immediate freeze) followed by a normal `setFeed` cycle, not a bypass.

---

## 5. Frozen manifest — TX-01 through TX-12

Every row is immutable in this document. The preview script and the operator's broadcast script MUST use exactly this numbering. All addresses are Base Sepolia (chain id 84532).

Shared column semantics:
- **Signer**: the EOA whose key must sign the tx.
- **Timelocked**: whether the tx is a `queueTransaction`/`executeTransaction` wrapper.
- **Depends on**: TXs whose successful confirmation is a prerequisite.
- **Earliest exec**: earliest wall-clock condition under which the tx may be broadcast.
- **Rollback**: how to revert this specific tx if the operator changes intent after landing.

### TX-01 — Deploy `ChainlinkPriceSource(ETH/USD)`

- kind             : contract deployment (permissionless)
- creation code    : `type(ChainlinkPriceSource).creationCode ++ abi.encode(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1)`
- constructor arg  : `_aggregator = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` (Chainlink ETH/USD Base Sepolia proxy)
- signer           : any funded EOA (recommended: same deployer key `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` for provenance parity)
- timelocked       : no
- depends on       : none
- earliest exec    : now
- gas (sim)        : **215 308**
- postcondition    : new adapter contract at deterministic address; `IPriceSource(adapter).getLatestPrice()` returns Chainlink normalized-to-1e8 price + fresh updatedAt; deployment address captured for TX-06 / TX-09 calldata
- rollback         : simply do not reference this adapter in TX-06 / TX-09; deployed contract is inert, holds no funds

### TX-02 — Deploy `ChainlinkPriceSource(BTC/USD)`

- kind             : contract deployment (permissionless)
- creation code    : `type(ChainlinkPriceSource).creationCode ++ abi.encode(0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298)`
- constructor arg  : `_aggregator = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298` (Chainlink BTC/USD Base Sepolia proxy)
- signer           : any funded EOA
- timelocked       : no
- depends on       : none
- earliest exec    : now
- gas (sim)        : **215 281**
- postcondition    : new adapter; `getLatestPrice` returns 1e8-normalized BTC/USD; address captured for TX-07 / TX-10
- rollback         : same as TX-01

### TX-03 — Deploy `PythPriceSource(pythCore, ETH/USD feedId)`

- kind             : contract deployment (permissionless)
- creation code    : `type(PythPriceSource).creationCode ++ abi.encode(0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83, 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace)`
- constructor args : `_pyth = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, `_priceId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`
- signer           : any funded EOA
- timelocked       : no
- depends on       : none
- earliest exec    : now
- gas (sim)        : **225 569**
- postcondition    : new adapter; `getLatestPrice()` returns Pyth's `getPriceUnsafe(ETH)` normalized to 1e8; per §1 the on-chain publishTime is currently stale — router will degrade to Chainlink-only for the ETH market
- rollback         : same as TX-01

### TX-04 — Deploy `PythPriceSource(pythCore, BTC/USD feedId)`

- kind             : contract deployment (permissionless)
- creation code    : `type(PythPriceSource).creationCode ++ abi.encode(0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83, 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43)`
- constructor args : `_pyth = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, `_priceId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`
- signer           : any funded EOA
- timelocked       : no
- depends on       : none
- earliest exec    : now
- gas (sim)        : **225 591**
- postcondition    : new adapter; same behavioural shape as TX-03 for BTC
- rollback         : same as TX-01

### TX-05 — `timelock.queueTransaction(router, 0, setMaxOracleDelay(1500), eta)`

- kind             : timelock queue
- inner target     : `OracleRouter = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- inner function   : `setMaxOracleDelay(uint32)` selector `0x80cea4a2`
- inner calldata   : `0x80cea4a200000000000000000000000000000000000000000000000000000000000005dc`
- semantic args    : `_delay = 1500`
- signer           : `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (only proposer; verified §3)
- timelocked       : yes (queue side)
- depends on       : none (may be sent in the same block as TX-01..04, TX-06, TX-07)
- earliest exec    : now (queue-side is `whenQueueNotPaused` only)
- `eta`            : must satisfy `eta >= block.timestamp + 86400`; recommended `queueBlockTimestamp + 86400 + 3600`
- postcondition    : `timelock.isQueued(router, 0, innerCalldata, eta) == true`
- rollback         : `timelock.cancelTransaction(router, 0, innerCalldata, eta)` from owner or guardian (both = `0xA6B9…dcD46`)

### TX-06 — `timelock.queueTransaction(router, 0, setFeed(mWETH, mUSDC, chEth, pyEth, 1500, 100, true), eta)`

- kind             : timelock queue
- inner target     : `OracleRouter = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- inner function   : `setFeed(address,address,address,address,uint32,uint16,bool)` selector `0x93240036`
- inner calldata   : regenerate via `cast calldata "setFeed(...)" 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02 0x6eAe407f5640B006faC9965182e238582A3B412E $CHAINLINK_ETH_ADAPTER $PYTH_ETH_ADAPTER 1500 100 true` (adapter addresses from TX-01/03 receipts)
- semantic args    : `baseAsset = mWETH (0x4DeE…Bdd02)`, `quoteAsset = mUSDC (0x6eAe…412E)`, `primarySource = <TX-01 addr>`, `secondarySource = <TX-03 addr>`, `maxDelay = 1500`, `maxDeviationBps = 100`, `isActive = true`
- signer           : `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`
- timelocked       : yes (queue side)
- depends on       : **TX-01, TX-03** (adapter addresses must exist to encode calldata)
- earliest exec    : after TX-01 + TX-03 confirmations are captured
- `eta`            : same value used for TX-05, TX-07 for atomic Group-2 execution
- postcondition    : `timelock.isQueued(router, 0, innerCalldata, eta) == true`
- rollback         : `timelock.cancelTransaction(...)` from owner or guardian

### TX-07 — `timelock.queueTransaction(router, 0, setFeed(mWBTC, mUSDC, chBtc, pyBtc, 1500, 100, true), eta)`

- kind             : timelock queue
- inner target     : `OracleRouter = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- inner function   : `setFeed(address,address,address,address,uint32,uint16,bool)` selector `0x93240036`
- inner calldata   : regenerate via `cast calldata "setFeed(...)" 0x9D871aC7595E8Da271E866608E5145252047967c 0x6eAe407f5640B006faC9965182e238582A3B412E $CHAINLINK_BTC_ADAPTER $PYTH_BTC_ADAPTER 1500 100 true` (adapter addresses from TX-02/04 receipts)
- semantic args    : `baseAsset = mWBTC (0x9D87…967c)`, `quoteAsset = mUSDC (0x6eAe…412E)`, `primarySource = <TX-02 addr>`, `secondarySource = <TX-04 addr>`, `maxDelay = 1500`, `maxDeviationBps = 100`, `isActive = true`
- signer           : `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`
- timelocked       : yes (queue side)
- depends on       : **TX-02, TX-04**
- earliest exec    : after TX-02 + TX-04 confirmations are captured
- `eta`            : same value used for TX-05, TX-06
- postcondition    : `timelock.isQueued(router, 0, innerCalldata, eta) == true`
- rollback         : `timelock.cancelTransaction(...)` from owner or guardian

### TX-08 — `timelock.executeTransaction(router, 0, setMaxOracleDelay(1500), eta)`

- kind             : timelock execute
- inner target     : `OracleRouter`
- inner calldata   : identical to TX-05
- semantic args    : identical to TX-05
- signer           : `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (only executor)
- timelocked       : yes (execute side)
- depends on       : **TX-05** landed
- earliest exec    : `block.timestamp >= eta` (i.e. **T + 24 h + margin**) AND `block.timestamp <= eta + 14 days` (grace period)
- inner gas (sim)  : **5 782** (execute wrapper cost is above this — reserve ~50 k)
- postcondition    : `router.maxOracleDelay() == 1500`; `timelock.isQueued(...) == false` (mark cleared)
- rollback         : queue+execute `setMaxOracleDelay(600)` through the timelock (another 24 h round). Emergency: `router.pauseReads()` from guardian to freeze reads immediately.

### TX-09 — `timelock.executeTransaction(router, 0, setFeed(mWETH, ...), eta)`

- kind             : timelock execute
- inner target     : `OracleRouter`
- inner calldata   : identical to TX-06
- semantic args    : identical to TX-06
- signer           : `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`
- timelocked       : yes (execute side)
- depends on       : **TX-06** landed (also implicitly TX-01, TX-03 via TX-06's own deps)
- earliest exec    : `block.timestamp >= eta` AND `block.timestamp <= eta + 14 days`
- inner gas (sim)  : **12 590** (reserve ~60 k for execute wrapper)
- postcondition    : `feeds[keccak256(abi.encode(mWETH, mUSDC))]` replaced; `router.hasActiveFeed(mWETH, mUSDC) == true`; `router.getPriceSafe(mWETH, mUSDC).ok == true`; `.price` ≈ Chainlink ETH latest answer (Pyth degraded to stale — expected)
- rollback         : queue+execute `setFeed(mWETH, mUSDC, 0x3eb9cdd2C2115c3f0DF5E30da53D7245F9a5f6Cc, 0x2103a84C0CAB9cf7680d602C8931FaDeD7064517, 60, 1000, true)` to restore the pre-broadcast mock-feed configuration byte-for-byte. Emergency: `router.pauseReads()`.

### TX-10 — `timelock.executeTransaction(router, 0, setFeed(mWBTC, ...), eta)`

- kind             : timelock execute
- inner target     : `OracleRouter`
- inner calldata   : identical to TX-07
- semantic args    : identical to TX-07
- signer           : `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`
- timelocked       : yes (execute side)
- depends on       : **TX-07** landed (also TX-02, TX-04 via TX-07)
- earliest exec    : `block.timestamp >= eta` AND `block.timestamp <= eta + 14 days`
- inner gas (sim)  : **12 581** (reserve ~60 k)
- postcondition    : `feeds[keccak256(abi.encode(mWBTC, mUSDC))]` replaced; `router.hasActiveFeed(mWBTC, mUSDC) == true`; `router.getPriceSafe(mWBTC, mUSDC).ok == true`
- rollback         : queue+execute `setFeed(mWBTC, mUSDC, 0x8cbA01B3f4e818ffffD6c1aE1f9a18A656e918bB, 0x7206E7c2c1C3D6e6273020163EB1f0E9339b970C, 60, 1000, true)` to restore the pre-broadcast mock-feed configuration. Emergency: `router.pauseReads()`.

### TX-11 — `pme.setExecutor($NEW_PERP_MATCHING_EXECUTOR, true)`

- kind             : direct call (not timelocked)
- target           : `PerpMatchingEngine = 0x774d96E5739bffadEE91508b4D3D74F5BE29F165`
- function         : `setExecutor(address,bool)` selector `0x1e1bff3f`
- semantic args    : `executor = $NEW_PERP_MATCHING_EXECUTOR` (unresolved — operator supplies at broadcast time, see §6), `allowed = true`
- signer           : `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (PME owner — verified on-chain, still direct-owned; NOT timelock-gated)
- timelocked       : no
- depends on       : none (independent of Group-1/2 oracle work — may be broadcast at any wall-clock time)
- earliest exec    : now
- gas (sim)        : **24 644**
- postcondition    : `pme.isExecutor($NEW_PERP_MATCHING_EXECUTOR) == true`
- rollback         : `pme.setExecutor($NEW_PERP_MATCHING_EXECUTOR, false)` from owner

### TX-12 — `pme.setExecutor(deployer, false)`

- kind             : direct call (not timelocked)
- target           : `PerpMatchingEngine = 0x774d96E5739bffadEE91508b4D3D74F5BE29F165`
- function         : `setExecutor(address,bool)`
- inner calldata   : `0x1e1bff3f000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c270000000000000000000000000000000000000000000000000000000000000000`
- semantic args    : `executor = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`, `allowed = false`
- signer           : `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (owner signs its own eviction)
- timelocked       : no
- depends on       : **TX-11** confirmed AND operator has independently verified that the new executor key controls the intended address and is funded on Base Sepolia; otherwise the matching engine ends up with zero allowlisted executors (reversible via a new `setExecutor(..., true)`, but blocks matching until fixed)
- earliest exec    : after TX-11 confirmation and out-of-band operator confirmation of executor key control
- gas (sim)        : **5 583**
- postcondition    : `pme.isExecutor(0xc35F…3C27) == false`
- rollback         : `pme.setExecutor(0xc35F7A8A103A9A4464adfaa76B9B514093D23C27, true)` from owner

---

## 6. `NEW_PERP_MATCHING_EXECUTOR` — unresolved

Fabricating this address would defeat the whole point of the rotation. It remains **unresolved** in the frozen manifest and the operator must supply it at broadcast time.

Validation gates the operator MUST clear before signing TX-11:

1. Address is non-zero (both `PerpMatchingEngine.setExecutor` and the manifest reject `address(0)`).
2. Address is on Base Sepolia (chain id 84532) — i.e., a funded EOA the operator controls a private key for.
3. Current PME executor state confirmed via `cast call ... "isExecutor(address)(bool)" $NEW_PERP_MATCHING_EXECUTOR` returns `false` **before** TX-11 broadcast.
4. Final PME executor state confirmed via the same call returns `true` **after** TX-11 and `false` for the deployer **after** TX-12.
5. Operator has verified out-of-band that the key controlling `$NEW_PERP_MATCHING_EXECUTOR` is a **hot** key controlled by the backend, not a cold key.

**Do not** request, display, echo, log, persist, or commit the private key anywhere. The rotation only needs the **address**. Follow the same pattern already in use for `PERP_SMOKE_BUYER_PRIVATE_KEY` / `PERP_SMOKE_SELLER_PRIVATE_KEY` (env-supplied at signer boundary, never touched by application code).

The preview script accepts the address via `NEW_PERP_MATCHING_EXECUTOR` env var. If unset, it substitutes a display dummy `0xEeEc…EEEC` and the fork-prank still confirms the shape of the state change; the calldata printed with the dummy MUST NOT be broadcast.

---

## 7. Steps intentionally NOT in this manifest

- **Enable public Perps** — backend env only (`PERPS_PUBLIC_TRADING_ENABLED`), not on-chain.
- **Enable per-market funding** — governed by contract-level `FundingConfig` (per market) and env flags. Kept `false`. `PerpEngineAdmin.setImpactMidSource(address)` **must not** be attempted: the deployed canonical `PerpEngine` at `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` **does not route** the `setImpactMidSource(address)` / `impactMidSource()` selectors (probed: reverts even from owner with valid args). Enabling funding V2 requires a NEW PerpEngine deployment — out of scope.
- **Enable unrestricted closed-test access** — backend `PERPS_CLOSED_TEST_ENABLED` stays `false`; allowlist stays empty.
- **Submit a Perp order / create a position** — no order-signing anywhere in this manifest.
- **`updateImpactMid`** — not part of this package.
- **Perp market re-registrations** — `PerpMarketRegistry` already routes `(mWETH → router)` and `(mWBTC → router)` per prior deployment. TX-06 / TX-09 and TX-07 / TX-10 replace the router's *feeds*, not the *router address*; the registry stays valid.

---

## 8. Broadcast grouping (matches TX numbering)

Grouping is a broadcast-cadence hint, not a re-ordering. The TX-01..TX-12 numbering is the source of truth.

- **Group 1 (T = 0)** — any order among these 7:
  - TX-01, TX-02, TX-03, TX-04 (4 permissionless adapter deploys, any funded EOA)
  - TX-05, TX-06, TX-07 (3 timelock queues, signer `0xA6B9…dcD46`)
  - TX-06/07 require TX-01/03 and TX-02/04 addresses to encode calldata; capture receipts before building the queues.
- **Group 2 (T + 24 h + margin)** — must be in `[eta, eta + 14 days]`:
  - TX-08, TX-09, TX-10 (3 timelock executes, signer `0xA6B9…dcD46`)
- **Group 3 (any time)** — orthogonal to router work:
  - TX-11 (deployer signs, requires `NEW_PERP_MATCHING_EXECUTOR`)
  - TX-12 (deployer signs, MUST follow TX-11 with out-of-band verification per §6)

Total broadcast tx count: **12**. Rough combined gas: ~1.2 M (see per-TX sims).

---

## 9. Final fork simulation

Re-run against Base Sepolia fork at capture window:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd deopt-v2-sol
forge script script/BaseSepoliaInfraBroadcastPreview.s.sol:BaseSepoliaInfraBroadcastPreview \
  --rpc-url https://sepolia.base.org \
  -vv
```

Results (block 46 487 688, ts 1788743664, chain 84532):

- All 5 timelock role assertions pass (`require(...)` inside `_printOnchainPreflight`).
- TX-01..04 simulated deploys produce contracts whose `getLatestPrice()` returns non-zero.
- TX-05..07 queue-side calldata printed with matching operation hashes.
- TX-08..10 execute-side calldata printed with **identical** operation hashes to the corresponding queue ops (proof of pairing).
- Prank-apply of TX-08..10 by the timelock: `router.maxOracleDelay: 600 → 1500`; `feed(mWETH,mUSDC)` and `feed(mWBTC,mUSDC)` replaced with `(chLink*, pyth*, 1500, 100, true)`; `hasActiveFeed` true for both; `getPriceSafe` returns Chainlink price (Pyth degraded — see §1 `CLOSED_TEST_ACCEPTED_LIMITATION`).
- Prank-apply of TX-11/12 by the deployer: `isExecutor[newExec] = true`, `isExecutor[deployer] = false`.

No `vm.startBroadcast` / `vm.broadcast` present. `setImpactMidSource` is deliberately never touched. Funding remains OFF. Public Perps remains OFF.

---

## 10. Verdict

**`PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FROZEN`**

Once this document is committed, the manifest identity is anchored by that commit's SHA. The exact authorization sentence to be used at broadcast time is:

> `I explicitly authorize broadcast of TX-01 through TX-12 from manifest <manifest-commit-sha> on Base Sepolia chain 84532 only.`

Replace `<manifest-commit-sha>` with the sha printed at the tail of this milestone's commit log. Do NOT authorize by hash of this file's contents in isolation — the commit binds the file to a specific companion preview script.

Nothing in this manifest broadcasts, enables public perps, opens the closed-test gate, enables funding, or submits any perp order. Awaiting explicit user authorization.
