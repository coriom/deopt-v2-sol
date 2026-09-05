# PERPS_BASE_SEPOLIA_INFRA_BROADCAST_V1

Scope: Base Sepolia (chain id **84532**) only. This document is the **preparation package** for the minimal on-chain infrastructure required before any Perps closed-test trade. It contains NO broadcast, NO secrets, NO private-key material.

Perps stays **fail-closed** for the duration of this milestone. Nothing in this manifest enables public perps, enables closed-test allowlist access, enables per-market funding, submits any order, or opens any position. Those are separate, later, explicitly-authorized actions.

Predecessor: `BASE_SEPOLIA_CLOSED_TEST_PROVISIONING_V1.md` (operator provisioning inventory).
Companion script: `script/BaseSepoliaInfraBroadcastPreview.s.sol` (view-only, fork-simulated).

Sources of truth:

- `deopt-v2-sol/src/oracle/{ChainlinkPriceSource,PythPriceSource,OracleRouter}.sol`
- `deopt-v2-sol/src/matching/PerpMatchingEngine.sol`
- `deopt-v2-sol/src/gouvernance/ProtocolTimelock.sol`
- `deopt-v2-sol/deployments/base-sepolia.manifest.draft.json`
- On-chain reads captured **2026-09-05** at Base Sepolia block **46,417,549** (timestamp `1788603386`).

---

## 1. Authoritative oracle inputs (verified live)

All four inputs verified via read against `https://sepolia.base.org` at chain id 84532. Full deployed bytecode present at each address; all four `getLatestPrice`-equivalent probes returned non-zero.

| Input                              | Address / bytes32                                                              | Provenance                                                                                                                                       | Live probe result                                              |
|------------------------------------|--------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|
| Chainlink ETH/USD proxy            | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`                                   | `https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-base-1.json` (name = "ETH / USD"), decimals=8, heartbeat=1200s        | `latestRoundData` returned answer `245999365671`, updatedAt fresh |
| Chainlink BTC/USD proxy            | `0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298`                                   | Same directory entry (name = "BTC / USD"), decimals=8, heartbeat=1200s                                                                            | `latestRoundData` returned answer `7967580000000`, updatedAt fresh |
| Pyth core contract (Base Sepolia)  | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`                                   | `https://docs.pyth.network/price-feeds/contract-addresses/evm` (Base Sepolia Testnet "Upgraded Address")                                          | `getPriceUnsafe` responds for both feed IDs below              |
| Pyth ETH/USD feed id (bytes32)     | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`           | `https://hermes.pyth.network/v2/price_feeds?query=ETH/USD&asset_type=crypto` (`Crypto.ETH/USD`), chain-agnostic                                    | expo `-8`, publishTime `1788594957` (age ~2.3h at capture)     |
| Pyth BTC/USD feed id (bytes32)     | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`           | `https://hermes.pyth.network/v2/price_feeds?query=BTC/USD&asset_type=crypto` (`Crypto.BTC/USD`), chain-agnostic                                    | expo `-8`, publishTime `1788589584` (age ~3.8h at capture)     |

**Cross-source deviation at capture** (Chainlink vs Pyth on same asset):
- ETH: `|245855246759 − 245784403792| / 245784403792 ≈ 0.03 %` → **well under** the proposed `maxDeviationBps=1000` (10 %).
- BTC: `|7964158000000 − 7963219153807| / 7963219153807 ≈ 0.012 %` → same conclusion.

**Pyth staleness observation on Base Sepolia** (non-blocking, but must be understood):
Pyth EVM feeds are **pull-based** — a keeper must call `updatePriceFeeds` on the core contract for `publishTime` to advance. At capture, on-chain Pyth `publishTime` was ~2.3h (ETH) and ~3.8h (BTC) older than `block.timestamp`. With the proposed per-feed `maxDelay = 1500 s` (25 min), the router's `_readConfiguredFeed` will treat Pyth as stale most of the time, degrade to Chainlink single-source (still safe, `_readConfiguredFeed` returns `(true, p1, t1, Ok)` when `!ok1 && ok2` swap or vice-versa), and skip the deviation cross-check for those reads. This is fail-closed acceptable but reduces the practical value of the dual-source configuration. Options to close this later, in decreasing preference:
1. Run a small Pyth-update keeper on Base Sepolia (out of scope for this milestone).
2. Accept single-source-Chainlink operational reality for closed-test.
3. Add a redundant Chainlink-only secondary (offers no independence — not recommended).

---

## 2. Adapter deployments (permissionless, Phase A)

Deploys are stateless with respect to any DeOpt-owned contract — anyone can send them, and the addresses will be deterministic per (deployer nonce, chain). The verifications in Phase A rely on the deployed adapter addresses being fed forward into Phase B's `setFeed(...)` calldata, so the operator MUST capture the four resulting addresses from Group-1 receipts before building/broadcasting Group 2.

For each of TX-01..TX-04, `bytecode = type(<Adapter>).creationCode ++ abi.encode(<constructor args>)`. Full creation code can be regenerated at build time by running `forge inspect <Adapter> bytecode`; the operator's broadcast script SHOULD build these deploy transactions in-place rather than caching a pinned bytecode blob.

| TX  | Kind   | Deploy                              | Constructor arg(s)                                                                                                                                    | Gas (sim) | Rollback                                                    |
|-----|--------|-------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------|-----------|-------------------------------------------------------------|
| TX-01 | deploy | `ChainlinkPriceSource`             | `_aggregator = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` (Chainlink ETH/USD)                                                                        | 215 302   | Simply do not reference this adapter in later `setFeed(...)`. Deployed contract is inert and holds no funds. |
| TX-02 | deploy | `ChainlinkPriceSource`             | `_aggregator = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298` (Chainlink BTC/USD)                                                                        | 215 275   | Same.                                                       |
| TX-03 | deploy | `PythPriceSource`                  | `_pyth = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, `_priceId = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`                | 225 564   | Same.                                                       |
| TX-04 | deploy | `PythPriceSource`                  | `_pyth = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, `_priceId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`                | 225 584   | Same.                                                       |

**Post-Phase-A verification (view-only, off-chain)**:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
# operator supplies RPC_URL and the 4 addresses observed in the receipts
for addr in "$CHAINLINK_ETH_ADAPTER" "$CHAINLINK_BTC_ADAPTER" "$PYTH_ETH_ADAPTER" "$PYTH_BTC_ADAPTER"; do
  cast call --rpc-url "$RPC_URL" "$addr" "getLatestPrice()(uint256,uint256)"
done
```

Expected: each call returns a non-zero `price` (Chainlink adapters normalise to 1e8 in the constructor because the aggregator's `decimals()==8`; Pyth adapters normalise 1e8 in-call with `expo == -8`), and a non-zero `updatedAt`. Any revert → **abort broadcast**; do not proceed to Phase B.

---

## 3. OracleRouter reconfiguration via ProtocolTimelock (Phase B)

**Authority**: `OracleRouter.setFeed(...)` and `OracleRouter.setMaxOracleDelay(...)` are `onlyOwner`. The current owner is `ProtocolTimelock` at `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` (verified read at capture). The timelock's owner is `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (also serves as guardian).

**IMPORTANT**: `deployer = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` is currently **NOT** a timelock proposer AND **NOT** a timelock executor (`proposers(deployer) = false`, `executors(deployer) = false` — verified reads). The keys that MUST send the queue/execute pair belong to `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`.

**Timelock parameters** (verified reads at capture):
- `minDelay()` = **86 400 s** (24 h).
- `queuePaused()` = false.
- `GRACE_PERIOD` = 14 days (compile-time constant).

**Timelock op-hash formula**: `keccak256(abi.encode(target, value, data, eta))`. Precomputable via `ProtocolTimelock.hashOperationBytes(...)`. Included in each TX row below so the operator can independently verify what they are queueing/executing.

**Tunables applied here** (chosen for Base Sepolia Chainlink heartbeat = 1200 s):
- Global `maxOracleDelay` : `600 → 1500` (25 min ceiling; Chainlink heartbeat + 300 s margin).
- Per-feed `maxDelay`     : `60 → 1500` (same reasoning, applied per feed).
- `maxDeviationBps`       : `1000` (10 %) — unchanged from the current mock-feed value.
- `isActive`              : `true` — keeps the feed enabled through the swap. Because `setFeed` is a full config replacement (writes the whole `FeedConfig`), the transition is atomic on-chain: at no point does the feed sit in a "half-configured" intermediate state.

Each router-level call is wrapped in a `queueTransaction` + (24h wait) + `executeTransaction` pair sent to the timelock. `eta` MUST satisfy `eta >= block.timestamp + minDelay` at the time of `queueTransaction`; recommended safety margin `eta = queueBlockTimestamp + 86400 + 3600` to absorb block-time drift.

### TX-05 — `router.setMaxOracleDelay(1500)`

- target (inner) : `OracleRouter` = `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- selector       : `0x80cea4a2`  (`setMaxOracleDelay(uint32)`)
- inner calldata : `0x80cea4a200000000000000000000000000000000000000000000000000000000000005dc`
- value          : `0`
- eta hint       : `queueBlockTimestamp + 90000` (must be ≥ `queueBlockTimestamp + 86400`)
- operation hash : reproducible via `ProtocolTimelock.hashOperationBytes(0xB416..A581, 0, <inner calldata>, eta)`
- sender (queue) : any address with `proposers[.] = true` (currently only `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`)
- sender (exec)  : any address with `executors[.] = true` (currently only `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`)
- effect         : `router.maxOracleDelay: 600 → 1500`
- gas (inner sim): **5 782** (execute call cost above timelock overhead)
- verify         : `cast call --rpc-url $RPC_URL 0xB416...A581 "maxOracleDelay()(uint32)"` → `1500`
- rollback       : queue+execute `setMaxOracleDelay(600)` through the timelock (24h). Emergency accelerated rollback via `router.pauseReads()` from guardian/owner (freezes reads immediately; not owner-blocking).

### TX-06 — `router.setFeed(mWETH, mUSDC, chEth, pyEth, 1500, 1000, true)`

- target (inner) : `OracleRouter` = `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- selector       : `0x93240036`  (`setFeed(address,address,address,address,uint32,uint16,bool)`)
- inner calldata : depends on TX-01 (`chEth`) and TX-03 (`pyEth`) addresses; regenerate via `cast calldata "setFeed(...)" 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02 0x6eAe407f5640B006faC9965182e238582A3B412E $CHAINLINK_ETH_ADAPTER $PYTH_ETH_ADAPTER 1500 1000 true`
- value          : `0`
- eta hint       : `queueBlockTimestamp + 90000`
- operation hash : `ProtocolTimelock.hashOperationBytes(0xB416..A581, 0, <inner calldata>, eta)`
- sender roles   : same as TX-05
- effect         : `feeds[keccak256(abi.encode(mWETH, mUSDC))]` replaced with `{primary: chEth, secondary: pyEth, maxDelay: 1500, maxDeviationBps: 1000, isActive: true}`
- gas (inner sim): **12 583**
- postcondition  : `router.hasActiveFeed(mWETH, mUSDC) == true` AND `router.getPriceSafe(mWETH, mUSDC).ok == true` AND `getPriceSafe.price` ≈ Chainlink ETH latest answer (Pyth degraded to stale — see §1 note).
- rollback       : queue+execute a `setFeed(mWETH, mUSDC, <oldPrimary=0x3eb9cdd2C2115c3f0DF5E30da53D7245F9a5f6Cc>, <oldSecondary=0x2103a84C0CAB9cf7680d602C8931FaDeD7064517>, 60, 1000, true)` to restore the pre-broadcast mock-feed configuration exactly (values captured on-chain). Emergency: `router.pauseReads()` from guardian.

### TX-07 — `router.setFeed(mWBTC, mUSDC, chBtc, pyBtc, 1500, 1000, true)`

- target (inner) : `OracleRouter` = `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`
- selector       : `0x93240036`
- inner calldata : regenerate via `cast calldata "setFeed(...)" 0x9D871aC7595E8Da271E866608E5145252047967c 0x6eAe407f5640B006faC9965182e238582A3B412E $CHAINLINK_BTC_ADAPTER $PYTH_BTC_ADAPTER 1500 1000 true`
- value          : `0`
- eta hint       : `queueBlockTimestamp + 90000`
- operation hash : `ProtocolTimelock.hashOperationBytes(0xB416..A581, 0, <inner calldata>, eta)`
- sender roles   : same as TX-05
- effect         : `feeds[keccak256(abi.encode(mWBTC, mUSDC))]` replaced with `{primary: chBtc, secondary: pyBtc, maxDelay: 1500, maxDeviationBps: 1000, isActive: true}`
- gas (inner sim): **12 574**
- postcondition  : `router.hasActiveFeed(mWBTC, mUSDC) == true` AND `router.getPriceSafe(mWBTC, mUSDC).ok == true` AND `getPriceSafe.price` ≈ Chainlink BTC latest answer.
- rollback       : queue+execute `setFeed(mWBTC, mUSDC, 0x8cbA01B3f4e818ffffD6c1aE1f9a18A656e918bB, 0x7206E7c2c1C3D6e6273020163EB1f0E9339b970C, 60, 1000, true)` to restore the pre-broadcast mock-feed configuration exactly. Emergency: `router.pauseReads()`.

---

## 4. PerpMatchingEngine executor rotation (Phase C, direct)

**Authority**: `PerpMatchingEngine.setExecutor(address, bool)` is `onlyOwner`. Current owner (verified read) is `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` — the deployer EOA (still direct-owned, NOT the timelock). `isExecutor[deployer] = true` (verified read); this is the only allowlisted executor at capture. The rotation swaps this to a dedicated closed-test executor and revokes the deployer's role.

**Operator-supplied input**: `NEW_PERP_MATCHING_EXECUTOR` = the closed-test executor EOA address. The private key MUST NOT be included, logged, or committed anywhere. Use the same "operator supplies via env, never echoed" pattern already in place for `PERP_SMOKE_BUYER_PRIVATE_KEY` / `PERP_SMOKE_SELLER_PRIVATE_KEY`. The preview script accepts this value via `NEW_PERP_MATCHING_EXECUTOR` env var — when missing it substitutes a dummy `0xEeEc...EEEC` purely for calldata display and the on-fork prank simulation still confirms the shape of the state change.

### TX-08 — `pme.setExecutor(NEW_EXECUTOR, true)`

- target       : `PerpMatchingEngine` = `0x774d96E5739bffadEE91508b4D3D74F5BE29F165`
- selector     : `0x1e1bff3f`  (`setExecutor(address,bool)`)
- calldata     : regenerate via `cast calldata "setExecutor(address,bool)" $NEW_PERP_MATCHING_EXECUTOR true`
- sender       : `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (deployer, owner)
- effect       : `isExecutor[NEW_EXECUTOR] : false → true`
- gas (sim)    : **24 644**
- verify       : `cast call --rpc-url $RPC_URL 0x774d...F165 "isExecutor(address)(bool)" $NEW_PERP_MATCHING_EXECUTOR` → `true`
- rollback     : `pme.setExecutor($NEW_PERP_MATCHING_EXECUTOR, false)` sent by owner.

### TX-09 — `pme.setExecutor(deployer, false)`

- target       : `PerpMatchingEngine` = `0x774d96E5739bffadEE91508b4D3D74F5BE29F165`
- selector     : `0x1e1bff3f`
- calldata     : `0x1e1bff3f000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c270000000000000000000000000000000000000000000000000000000000000000`
- sender       : `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (deployer, owner — signs its own eviction)
- effect       : `isExecutor[deployer] : true → false`
- gas (sim)    : **5 582**
- verify       : `cast call --rpc-url $RPC_URL 0x774d...F165 "isExecutor(address)(bool)" 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` → `false`
- **ordering constraint**: TX-09 MUST NOT be broadcast before TX-08 lands **and** the operator confirms the new executor EOA is funded, key-controlled, and can sign against Base Sepolia. Broadcasting TX-09 alone (or before TX-08 confirmation) leaves the matching engine with zero allowlisted executors — matching **cannot happen** until a new `setExecutor(..., true)` succeeds. Reversible via `setExecutor(deployer, true)` from owner, so this is a soft-fail, not a permanent lockout.
- rollback     : `pme.setExecutor(0xc35F7A8A103A9A4464adfaa76B9B514093D23C27, true)` sent by owner.

---

## 5. Steps intentionally NOT in this manifest

Per the milestone's own "Do NOT" list, these are explicitly excluded from this preparation package. Each is documented so the operator understands why the corresponding transaction is absent:

- **Enable public Perps** — controlled by backend env `PERPS_PUBLIC_TRADING_ENABLED`. This is a backend restart, NOT an on-chain tx. Startup validation in `deopt-v2-backend/src/config/env.rs:836-838` refuses `true` on mainnet chain ids.
- **Enable per-market funding** — governed by contract-level `FundingConfig` (per market). `.env.base-sepolia.example` lines 229 and 254 set `ETH_PERP_FUNDING_ENABLED=false` / `BTC_PERP_FUNDING_ENABLED=false`. No `updateImpactMid` (`onlyImpactMidSource` at `PerpEngineStorage.sol:236-239`) call is included. Additionally, a live selector probe against the deployed canonical `PerpEngine` at `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` shows the `setImpactMidSource(address)` and `impactMidSource()` selectors **revert** — the deployed bytecode does not include the funding-V2 keeper surface. Enabling funding V2 requires deploying a NEW PerpEngine build, which is out of scope for this milestone. Item 6 of the milestone's own safety sequence therefore reduces to a documented no-op in this run.
- **Enable unrestricted closed-test access** — backend flag `PERPS_CLOSED_TEST_ENABLED` stays `false`. `PERPS_CLOSED_TEST_ALLOWLIST` stays empty. See `BASE_SEPOLIA_CLOSED_TEST_PROVISIONING_V1.md` §4 for the layered fail-closed gate.
- **Submit a Perp order / create a position** — no order-signing tx anywhere in this package. Frontend `NEXT_PUBLIC_PERPS_TICKET_ENABLED` stays `false`; backend `perps_public_trading_enabled` stays `false`.
- **`updateImpactMid`** — see funding note above.
- **Perp market re-registrations** — `PerpMarketRegistry` already carries `(mWETH → OracleRouter)` and `(mWBTC → OracleRouter)` per prior deployment. Because Phase B replaces the router's *feeds* rather than the *router address*, no market registry write is needed. Item 5 of the milestone's own safety sequence is therefore already-satisfied ambient state.

---

## 6. Broadcast grouping and sequencing

The 12 broadcast transactions (9 numbered TX-IDs, expanded to 12 including the queue/execute pairs) can be grouped as follows. Each group is one atomic operator action; the wait between groups is mandated by the timelock, not by any external dependency.

### Group 1 (T = broadcast start) — 7 transactions

Send from any funded EOA(s). No timelock role needed for the four deploys. The three timelock queues MUST come from `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`.

1. TX-01 — deploy `ChainlinkPriceSource(ETH aggregator)` (permissionless)
2. TX-02 — deploy `ChainlinkPriceSource(BTC aggregator)` (permissionless)
3. TX-03 — deploy `PythPriceSource(pythCore, ETH feedId)` (permissionless)
4. TX-04 — deploy `PythPriceSource(pythCore, BTC feedId)` (permissionless)
5. TX-05a — `timelock.queueTransaction(router, 0, setMaxOracleDelay(1500), eta)`
6. TX-06a — `timelock.queueTransaction(router, 0, setFeed(mWETH, ..., chEth, pyEth, 1500, 1000, true), eta)`
7. TX-07a — `timelock.queueTransaction(router, 0, setFeed(mWBTC, ..., chBtc, pyBtc, 1500, 1000, true), eta)`

After Group 1 lands: run the Phase A verifications from §2. If any `getLatestPrice()` reverts, **do not proceed**; either the aggregator/Pyth core is misbehaving OR the deploy artifact is wrong. Cancel each timelock queue individually via `timelock.cancelTransaction(...)` (guardian OR owner allowed).

### Group 2 (T + 24 h + margin) — 3 transactions

Must come from `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (only holder of `executors[]=true`). Send after `eta` has elapsed AND before `eta + 14 days` (grace period).

8. TX-05b — `timelock.executeTransaction(router, 0, setMaxOracleDelay(1500), eta)`
9. TX-06b — `timelock.executeTransaction(router, 0, setFeed(mWETH, ...), eta)`
10. TX-07b — `timelock.executeTransaction(router, 0, setFeed(mWBTC, ...), eta)`

After Group 2 lands: verify router state per §3 postconditions.

### Group 3 (independent of Groups 1/2) — 2 transactions

Can be sent at any time (before, during, or after Groups 1/2) since the PerpMatchingEngine executor set is entirely orthogonal to the router. Must come from `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (PME owner). TX-09 MUST NOT be sent before TX-08 confirms.

11. TX-08 — `pme.setExecutor($NEW_PERP_MATCHING_EXECUTOR, true)`
12. TX-09 — `pme.setExecutor(0xc35F...3C27, false)`

**Total broadcast tx count: 12.** Approximate combined gas cost (rough): adapter deploys ~882 k + timelock queues ~150 k + timelock executes (base + inner) ~120 k + executor rotation ~30 k ≈ **1.2 M gas** across all groups. Base Sepolia base fee at capture window fits comfortably in a `max_fee_per_gas` of `baseFee + 2 gwei` per operator convention.

---

## 7. Preview script

`script/BaseSepoliaInfraBroadcastPreview.s.sol` reproduces every observation in this document. Run it against the live Base Sepolia RPC in fork mode with:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd deopt-v2-sol
# operator-supplied executor address for TX-08/TX-09 calldata (optional; if unset, dummy is used)
export NEW_PERP_MATCHING_EXECUTOR=0x...      # optional
forge script script/BaseSepoliaInfraBroadcastPreview.s.sol:BaseSepoliaInfraBroadcastPreview \
  --rpc-url https://sepolia.base.org \
  -vv
```

The script:
- asserts `block.chainid == 84532`;
- reads current owner / feed / executor state (preflight);
- deploys 4 adapters into the fork (not into real state);
- reads `getLatestPrice()` on each fork-deployed adapter and prints price + age;
- prints the calldata + `operation hash` for each timelock-wrapped router op;
- `vm.prank`s the timelock and applies `setMaxOracleDelay(1500)`, both `setFeed`s;
- reads `router.hasActiveFeed / getPriceSafe` postconditions;
- `vm.prank`s the deployer and applies both `setExecutor` calls;
- reads `pme.isExecutor` postconditions.

It contains **no `vm.startBroadcast()`, no `vm.broadcast()`, no `--broadcast`-compatible marker**. Even if the operator accidentally adds `--broadcast` to the CLI, `forge` will not submit any tx because there are no broadcast-scoped blocks.

Fork-simulation output captured on **2026-09-05, block 46,417,549, timestamp 1788603386** is preserved in the milestone conversation log.

---

## 8. Post-broadcast handoff

After all 12 transactions land, the state expected by `PERPS_CLOSED_TEST_HARDENING_V1` and `PERPS_BASE_SEPOLIA_CLOSED_TEST_PROVISIONING_V1` is fully in place:

- `OracleRouter` now consumes real Chainlink + Pyth data with a 1500 s staleness ceiling (per feed AND globally) and a 10 % deviation cap. Fail-closed graceful degradation still applies when one source is stale.
- `PerpMatchingEngine` accepts execution calls only from the closed-test executor EOA. The deployer key is no longer sufficient to execute perp trades.
- The closed-test allowlist gate (`PERPS_CLOSED_TEST_ENABLED` + `PERPS_CLOSED_TEST_ALLOWLIST`) remains untouched — still fail-closed.
- Funding V2 remains disabled (both by env config AND by deployed bytecode absence).
- Public perps remain disabled (both by env config AND by startup validation).

The next milestone can then be a small, explicitly-authorized closed-test smoke: one allowlisted tester wallet submits one signed perp order intent, the new executor EOA lands the match, and the position closes. That milestone is NOT part of this manifest.

---

## 9. Verdict

**PERPS_BASE_SEPOLIA_INFRA_BROADCAST_PACKAGE_READY**

Blockers cleared:
- Oracle inputs resolved from authoritative Chainlink + Pyth sources with live-probed on-chain confirmation.
- Adapter constructors, gas, and deploy semantics defined.
- OracleRouter authority path correctly identified as timelock-gated; queue/execute cadence documented.
- Executor rotation authority verified as still direct-owned by deployer.
- Full 12-tx sequence fork-simulated; every postcondition observed matches the spec.

Waiting for the user before any further action:
1. Explicit authorization to broadcast Group 1 (7 txs) on Base Sepolia chain 84532.
2. Operator supply of `NEW_PERP_MATCHING_EXECUTOR` (address only — key stays with operator) for TX-08 calldata.
3. Coordination with the holder of `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (timelock owner+guardian, and only proposer/executor) for TX-05a/06a/07a queues and TX-05b/06b/07b executes.

Nothing in this manifest broadcasts, enables public perps, opens the closed-test gate, enables funding, or submits any perp order.
