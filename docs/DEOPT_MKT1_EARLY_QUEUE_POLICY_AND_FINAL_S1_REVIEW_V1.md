# DeOpt MKT1 early queue policy and S1 checkpoint

**Verdict:** The operator approved the Base Sepolia scheduling-policy amendment only. The amended [DAG v3](../artifacts/perps_v2_replacement_deployment/post_maintenance_dependency_dag_v3.json) supersedes v2 and preserves the D2/D3 compatibility correction. The [approval record](../artifacts/perps_v2_replacement_deployment/mkt1_early_queue_policy_approval_v1.json) grants no public transaction authorization. MKT1 S1 passes **offline** exact-transaction review and is ready for a **separate** operator authorization; C02 S2 remains blocked by remote-isolation evidence.

## Exact policy change

The v2 edge `C02 → MKT1_INACTIVE` now applies to **MKT1 S2 execution**. MKT1 S1 scheduling requires `C02_S1_CANONICAL_QUEUE_POSTFLIGHT_PASS`; MKT1 S2 requires both `C02_S2_CANONICAL_POSTFLIGHT_PASS` and `MKT1_INACTIVE_S1_CANONICAL_QUEUE_POSTFLIGHT_PASS`. All other 82 edges, other nodes, topological order, D3/D2 corrections, maintenance gates and independent Safe/Timelock approvals are unchanged. Scheduling does not call D1 and cannot create or activate market 1. If C02 fails, expires or is cancelled, do not execute MKT1; separately review its cancellation or expiry. If MKT1 execution fails after C02, keep D4/D6 closed, stop downstream work, reconcile the queue and market state, and separately review any retry or replacement.

## Fresh pinned preflight

At Base Sepolia block **51,576,155**, timestamp `2026-10-29 01:24:59 UTC`, block hash `0x0cf2bac2fd59092cfc571b37713cb7e384ef5d431b5e081fd767c2d3bc7f3609`, 40 pinned read-only calls found:

- OPS Safe nonce **42**, the three previously reviewed owners, threshold **2/3**, no enabled module.
- Timelock owner = OPS Safe; minDelay **86,400 seconds**, grace period **1,209,600 seconds**, queue unpaused, Safe proposer/executor enabled.
- C02 `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e` queued, ready, unexecuted, unexpired. Its last execution time remains **2026-11-08 12:00 UTC inclusive**.
- D1 market count **0**, market 1 absent, mUSDC settlement allowed. D4 four emergency flags true, migration OPEN, D5 risk pointer, zero matching/insurance/fee pointers; D6 paused.
- D3 mUSDC explicit config `(5 bps, enabled, set)` and compatible collateral RiskModule unchanged. D2 five PERP profiles `(maker 0 ppm, taker 200 ppm)`, Timelock recipient, mUSDC rebate budget zero. D4 has no shared Vault/Insurance authorization or D2 fee-consumer role.

These checks are bounded economic non-drift evidence. Pending Safe UI proposals, full wallet balance/gas and deployed remote execution-service state require separate operator verification.

## Final unsigned MKT1 S1 envelope

The [final review](../artifacts/perps_v2_replacement_deployment/mkt1_inactive_early_s1_final_review_v1.json) binds one [Safe Builder file](../artifacts/perps_v2_replacement_deployment/mkt1_inactive_early_s1_safe_builder_final_review_v1.json):

| Field | Exact reviewed value |
|---|---|
| Safe | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, chain 84532 |
| Safe action | One CALL to `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, zero ETH; no MultiSend |
| Inner action | D1 `0x6B3D846536116082dC4E7227861C341Bb85Ee963`: `setMarketStatus(1,false,false)` |
| Inner calldata Keccak-256 | `0xd2c425cabaea425fd78ddf833de798c6548718078ade79a8c28f0c220ccb017e` |
| Outer scheduling calldata Keccak-256 | `0x0f573655055576ff23ed79da8a4d163faa635cf19c642a87a1664bf218dbb486` |
| ETA | **2026-11-01 12:00 UTC** |
| Buffered scheduling cutoff | **2026-10-31 11:00 UTC** |
| Execution expiry | **2026-11-15 12:00 UTC inclusive** |
| Timelock operation ID | `0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268` |
| Builder file SHA-256 | `822d3fe1a3a29943c83ae013b5291c6d1975da5f33f7bad18f75370db2fee3da` |
| Conditional SafeTx hash at nonce 42 | `0xc80e676251c36b9323620d3d520b317e622dadcd3174a9bf769398c43074ebb5` |

This ETA was rederived from the fresh block, current minDelay and an additional 48-hour preparation margin. The old conditional candidate remains unchanged. Live `hashOperation` and Safe `getTransactionHash` reads matched locally calculated identities. The operation was absent at the pinned block, and a read-only Safe-to-Timelock queue call returned the exact ID. The D1 setter rejected before market creation; executing an unqueued operation rejected.

On a fresh isolated Anvil fork of the pinned block, MKT1 scheduling left D1 at zero markets. MKT1 execution before ETA and after ETA without a market rejected. A locally cancelled C02 could not execute and did not enable MKT1. On the restored branch, local C02 execution created ACTIVE market 1, then local MKT1 execution made it INACTIVE. Wrong market ID and replay rejected; D4/D6 maintenance held. These are **fork-only** transactions with Safe impersonation; they do not establish genuine signatures or public postflight.

## Next operator checkpoint — MKT1 S1 only

The policy decision is recorded; **the public scheduling transaction is not authorized by this milestone**. For a separate authorization, the operator must confirm chain 84532 and the exact OPS Safe, inspect pending Safe proposals and current nonce, import exactly the reviewed one-action Builder file, and verify target, zero value, both calldata layers, ETA, ID and conditional SafeTx hash. Recheck the actual block timestamp: `ETA >= block.timestamp + live minDelay + 3600` and finish before the buffered cutoff. Require C02 still queued/unexpired, market 1 absent, D4/D6 intact, and no shared ACL drift. Run Safe UI simulation, review full wallet gas and ETH balance, obtain real 2/3 owner confirmations, then explicitly authorize and submit **only this S1 scheduling call**. If any predicate fails, stop and regenerate/review the package; do not silently change ETA or nonce.

After an operator-supplied public hash, the independent postflight must match the canonical successful receipt and block hash, exact Safe `ExecutionSuccess`/SafeTx hash and nonce increment, Timelock `TransactionQueued` event with the exact target, data, value, ETA and operation ID, and a queued but unexecuted state. D1 must still have no market; D4/D6 and shared economics must remain unchanged. A successful outer receipt alone is insufficient. **No C02 or MKT1 S2 execution follows automatically.**

The shortest later path is: MKT1 S1 postflight PASS → wait until both operations are ready → obtain missing remote-isolation proof → separate C02 S2 final review and approval → manual C02 execution and canonical ACTIVE-market postflight → separate MKT1 S2 approval and manual execution → canonical INACTIVE-market postflight. The ACTIVE interval may be prolonged without bound if the final Safe action, RPC or MKT1 call fails. Keep D4/D6 maintenance throughout.

## One remaining C02 operational evidence request

Vercel still shows canonical production deployment `dpl_4Ah6VNmKyFVzVdAUH1mbeptz93XS`, READY at frontend commit `a32c5cc1b6dee30a0676b4adc156718687a0a727`. The connected deployment-file inventory again returned `404 File tree not found`; the connector has no Cron Jobs listing. Request two timestamped captures from project ID `prj_YADz33AWNuLnbnXYvQZOINFIhTTG`: **production deployment → Functions** and **project Settings → Cron Jobs**, showing complete lists or empty states, paths/runtimes and enabled schedules. Redact credentials and secret values. In the same response, state whether any DeOpt Rust backend, relayer, keeper or broadcaster currently runs outside local WSL; if yes, provide the actual provider/service and non-secret runtime status, chain/contract targets and execution toggles. This evidence gates **C02 S2**, not the already approved MKT1 S1 policy or this offline package review.
