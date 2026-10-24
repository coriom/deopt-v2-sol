# C02 remote execution isolation and early MKT1 policy review

Review date: 2026-10-24 UTC. Public chain activity in this review was read only. The isolated Anvil fork used Safe-address impersonation and synthetic local transactions; it did not test genuine Safe owner confirmations or submit a public transaction.

## Decision

**Partial review. C02-S2 remains ineligible.** C02 is queued at operation ID `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e`, ETA `2026-10-25 12:00 UTC`, inclusive expiry `2026-11-08 12:00 UTC`. At pinned Base Sepolia block **49,538,864**, hash `0xb12b9ca70f684679bd5125366d6a5c58955320c2288062e9f23d997bd342910c`, timestamp `2026-10-24 08:14:01 UTC`, it was queued and unexecuted. Market count was zero. D4 retained four true emergency flags, migration OPEN, D5 Risk pointer, zero PME pointer, and no Vault or Insurance authorization. D5 delay was 600; D6 remained paused. Safe nonce was 30, threshold 2/3, with the reviewed three owners, no modules or guard. Timelock delay was 86,400 seconds. The RPC block hash was rechecked. These are snapshot findings, not guarantees about future state.

The frozen `src` tree matches revision `25c36670883604c1ef5229642ee6548aea6796c3`; prior containment, feasibility, C02-S1 and approved DAG SHA-256 commitments matched. The detailed pinned readbacks and runtime hashes are in [the attestation artifact](../artifacts/perps_v2_replacement_deployment/c02_remote_execution_isolation_attestation_v1.json).

## Actual infrastructure evidence

The operator corrected the hosting assumption: **Vercel is the current DeOpt hosting lead.** Connected Vercel inspection found one accessible team (`corioms-projects`) and two DeOpt projects. Both have READY production deployment metadata and live aliases, so neither can be called stopped. The project API also reports `live:false`; that flag does not prove an API or write path is disabled. No secret-bearing environment values were read.

| Component | Observed provider state | Execution or order capability | Confidence and limit |
| --- | --- | --- | --- |
| `deoptv2-frontend` | Vercel project `prj_YADz33AWNuLnbnXYvQZOINFIhTTG`; production `dpl_FoAjCa4Z4D49pos1KuQ2z8Zntq3U` READY, built from `938ab3d...`; three production deployments returned | **UNKNOWN** | Connected project, deployment and alias metadata verified. No deployed function, cron, effective network or backend-routing inventory. |
| `deopt-frontend` | Vercel project `prj_TgSgRYiGQrwKfqhZTGW9UziiGggj`; production `dpl_VPtyktyXfAbaieSDxPmUUYwuF2MT` READY, built from `e4d8a3e...`; an older READY preview `dpl_7QfMNWSstJVAMHZPxAQNN1YHrJTS` exists | **UNKNOWN** | Connected deployment metadata verified. A historical preview may remain addressable. |
| Vercel project routing | Zero project-level custom routes returned for both projects | **UNKNOWN** | This API does not enumerate Next.js app routes or serverless functions. The GitHub-built deployment file-tree API returned 404. Functions and cron jobs remain unverified. |
| Rust backend | Local backend source has real broadcaster, funding/liquidation worker and impact-mid keeper capabilities; source defaults for execution and workers are false | **UNKNOWN deployed state** | Local source HEAD `ad8dd746...` is not proof of any deployed revision or effective flags. |
| Historical Railway reference | GitHub deployment records point to `awake-ambition / production`, Railway project `5d110969-6d5a-4f78-ab01-60dc3efd55e3`, environment `9fa9cad6-cb27-43ad-b4ed-c8af4e416365`; latest recorded GitHub status was **failure** on 2026-07-12 | **UNKNOWN now** | This establishes provenance of an old Railway attempt. No current Railway service state was available. Railway is not assumed to host the active backend. |
| GitHub Actions | Three active backend workflows: CI, runtime E2E and PostgreSQL integrity. Reviewed triggers are push/PR, with no schedule trigger; reviewed CI/E2E definitions disable execution/broadcast | No broadcaster found **within these three workflow definitions** | Other repositories, provider jobs and continuously running hosts are outside this observation. |
| Local WSL/Docker/systemd | Docker has DeOpt L0 monitoring/webhook containers; no DeOpt backend container or DeOpt systemd unit found in the local inventory | **UNKNOWN remotely** | Local host inspection says nothing about Vercel, another VPS or a hosted Rust service. The webhook sink was not treated as an execution service without configuration evidence. |

The connected Vercel integration provides project/deployment status and aliases but did not supply a reliable deployed function/cron inventory or effective non-secret execution flags. The local frontend checkout is a different source revision from the Vercel V2 deployment and cannot stand in for deployed source. The deployment file-tree API was unavailable. `REMOTE_BACKEND_ISOLATION` and `RELAYER_KEEPER_ISOLATION` therefore remain **NOT_VERIFIED**; `EXECUTION_SERVICE_INVENTORY` is **PARTIAL**.

The next operator evidence checkpoint needs a sanitized provider export for each Vercel project and any hosted Rust service: deployment ID and revision, production and preview function routes, cron/scheduled jobs, effective chain ID, public old and replacement contract addresses, order-intake enablement, broadcast and worker flags, queue/retry policy, live service state, restart/auto-deploy policy, and provider timestamp. Identify transaction-capable roles without exposing private key or token values. Also obtain current Railway service inventory or deletion proof for the historical project, plus any VPS/container hosts. A July GitHub failure cannot establish October shutdown.

## Privileged economic reachability

The [attestation JSON](../artifacts/perps_v2_replacement_deployment/c02_remote_execution_isolation_attestation_v1.json) contains a 20-row source-backed matrix with entrypoints, frozen ABI selectors, caller authority, required wiring, guards, market dependency, live identity scope and post-C02 reachability. The material distinctions are:

| Path | Current authority and guard | Change when C02 creates ACTIVE market 1 | Finding |
| --- | --- | --- | --- |
| D6 trade / D4 `applyTrade` | D6 paused; reviewed runtime executor unauthorized; D4 PME pointer zero; D4 trading paused and migration OPEN | ACTIVE passes only a later market check | Rejected by independent maintained guards. |
| D4 liquidation, funding and impact-mid writes | Liquidation/funding paused, migration OPEN; impact-mid source zero | Market existence would pass a later check | Fork negative calls reverted after local C02 execution. |
| D4 `adminSeedPosition` (`0x0ef3a5f7`) and `adminSeedMarketFunding` (`0x2c96f1bc`) | Only ProtocolTimelock owner and migration OPEN; emergency flags do **not** block | **Become market-eligible** | Economically material path remains available to separately authorized Safe/Timelock governance. No migration call is authorized here. |
| D4 residual-debt seed and migration seal | Owner-only; seal also lacks PME/Clearing wiring | Debt seed is independent of market; seal remains blocked by missing pointers | Neither is made permissionless by C02. |
| D4 shared custody | D4 Vault and Insurance ACLs false | No change | Replacement Engine cannot take the shared economic permissions from market status alone. |
| Legacy custody paths | Vault still authorizes legacy/margin engines; Insurance backstop mapping includes legacy V1 and margin engine | No change | These are live separate permissions. Their remote operators and operational availability are unverified. |
| Generic Vault deposit/own-account withdrawal and Clearing `fundClearing` | User/token authority and Vault checks, separate from D4 flags | No change | Existing economic writes remain possible. “All economic activity impossible” would be false. |
| Insurance owner/operator and backstop functions; D2 fee functions | Their own ACLs, balances, pause and fee-consumer policy | No C02 trigger | Must remain in the independent service and role inventory. |

The on-chain result is **PASS within the reviewed D4/D6 and bounded shared-state scope**: C02 ACTIVE status did not reveal a new non-governance replacement perp economic write. This is not an exhaustive storage proof and does not establish remote process isolation. The live Vault authorized-engine list was read; Insurance permission mappings are not enumerable, so tested identities are bounded.

## Proposed MKT1 early queue amendment

The approved dependency DAG is unchanged. Its hard edge currently puts **C02 public execution and postflight before MKT1_INACTIVE scheduling**, requiring at least another 86,400-second Timelock delay with market 1 ACTIVE. Operational confirmation can make that interval much longer.

The [versioned proposed amendment](../artifacts/perps_v2_replacement_deployment/mkt1_early_queue_policy_amendment_proposal_v1.json) changes only scheduling eligibility:

```text
Old: C02-S2 canonical PASS -> MKT1-S1 scheduling eligible
Proposed: C02-S1 canonical queue PASS -> MKT1-S1 scheduling eligible
Preserved: C02-S2 canonical PASS + MKT1-S1 canonical queue PASS -> MKT1-S2 execution eligible
Additional C02-S2 checkpoint: both operations ready + remote operational attestation PASS
```

Frozen D1 `setMarketStatus(uint256,bool,bool)` selector `0x85477fb3` uses `(1,false,false)` to mark market 1 inactive. Scheduling checks Timelock authority, delay and operation identity; it does not call D1 or require the market to exist. Execution requires market existence and reverts otherwise. C02 `createMarket` makes market 1 ACTIVE immediately. For a **conditional policy candidate only**, ETA `2026-10-27 12:00 UTC` (`1793102400`), buffered scheduling cutoff `2026-10-26 11:00 UTC` (`1793012400`), operation ID `0x9084148eadef227a5d6a93c30397474c6346f4b352585a153f66b6c0d8af448f` matched the deployed Timelock hash and a read-only queue simulation at the pinned block. The candidate was absent then. This ETA, ID and any Safe nonce are **not approved or committed**; a changed ETA requires new review.

A fresh isolated fork from block 49,541,233 rehearsed the existing DAG and the proposed early queue. It confirmed early scheduling without market creation; premature, wrong-ID, unauthorized, cancelled-C02 and failed-C02 paths; local C02 ACTIVE state; subsequent MKT1 INACTIVE state; bounded unchanged D4/D6/shared balances and ACLs; and replay rejection. The script used Safe-address impersonation, so it does not prove real 2/3 approvals. The existing DAG local path waited 90,000 seconds between C02 and the later status operation (86,400 minimum plus one-hour margin). The accelerated path can remove that protocol-imposed interval if MKT1 is already ready, but a separate C02 postflight, fresh MKT1 review, two real owner confirmations and public inclusion still take nonzero time. **Neither path has a guaranteed maximum ACTIVE interval.**

The technical amendment review **PASS** is not policy approval. It creates no operator-ready Builder JSON and authorizes no scheduling. Before adoption, the operator must separately approve this exact edge change and obtain complete remote execution attestation. A later MKT1-S1 scheduling review must refresh ETA, nonce and Timelock state, then seek separate Safe 2/3 authorization. Both operations should be ready before an independent C02-S2 review. C02-S2 must pass canonical public postflight before any MKT1-S2 approval. No MultiSend or automatic continuation is allowed.

If C02 fails or is cancelled, do not execute MKT1; leave the early queue untouched until an independently reviewed cancellation or expiry decision. If C02 succeeds and MKT1 fails, keep D4/D6 maintenance closed, halt downstream market, migration and trading work, reconcile the exact public outcome and use a separately authorized recovery decision. Never blindly retry.

## Independent preparation while blocked

All five branches have `MAINTENANCE_VERIFIED` as their direct approved DAG prerequisite and are eligible for **read-only preparation only**: `D3_TOKEN` (explicit token/spread policy still missing), `D2_FEE_POLICY` (recipient, rebates and legacy liability policy missing), `GUARDIAN_POLICY` (pause-only authority review), `EXECUTOR_IDENTITY_REVIEW` (runtime identity and first-trade guard), and `ACL_POLICY_REVIEW` (dual-engine custody and no-double-funding plan). None is authorized for public scheduling or execution.

## Validation and stopping point

Focused checks covered prior artifact hashes, frozen source, pinned governance and maintenance state, frozen ABI selectors, proposed Timelock hash and absent queue state, both fork sequences, negative paths, bounded economic non-drift and no public-chain writes. The full Foundry suite was not run; no Solidity was changed. See machine-readable artifacts for exact test flags and limits. **Next milestone: `C02_REMOTE_OPERATIONAL_EVIDENCE_CHECKPOINT`.** C02-S2 and MKT1 scheduling remain unauthorized.
