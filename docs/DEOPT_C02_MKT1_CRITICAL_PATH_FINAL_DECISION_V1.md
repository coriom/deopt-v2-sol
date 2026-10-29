# DeOpt C02 / MKT1 decision checkpoint — Base Sepolia

**Status:** C02 remains queued and executable, but its public execution is blocked. The early MKT1 scheduling rule is technically supported and still requires explicit operator policy approval. No public action was taken in this review.

## Fresh state and scope

At Base Sepolia block **51,570,848** (`2026-10-29 01:07:18 UTC`, hash `0x3bffa7f541f895e377beb1cea5d907c5f2d64d4e1dd0f08f1be7dc3130a5dbfd`), 40 pinned read-only calls confirmed Safe nonce 42, three owners, threshold 2, no enabled Safe module, Timelock delay 86,400 seconds, C02 operation `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e` queued, market count zero, and market 1 absent. C02's ETA is `2026-10-25 12:00 UTC`; execution expires after `2026-11-08 12:00 UTC` (inclusive).

D4's four emergency flags are true, D6 is paused, migration remains OPEN, D4 points to D5 and to no matching engine, and D4 lacks shared Vault/Insurance access. D3 mUSDC is explicitly enabled at 5 bps with its compatible collateral RiskModule. D2's five PERP profiles read `0/200 ppm`, recipient is the Timelock, and mUSDC rebate budget is zero. These are bounded reads, not an exhaustive proof of every historical balance. Exact fields are in [the decision artifact](../artifacts/perps_v2_replacement_deployment/c02_mkt1_critical_path_final_decision_v1.json).

## Remaining operational proof

The Vercel connector identifies production deployment `dpl_4Ah6VNmKyFVzVdAUH1mbeptz93XS` of project `prj_YADz33AWNuLnbnXYvQZOINFIhTTG` as READY at frontend commit `a32c5cc1b6dee30a0676b4adc156718687a0a727`, serving `deoptv2-frontend.vercel.app`. The project name returned by Vercel is `deopt-v2-frontend`; the ID and alias identify the canonical project. Its deployed file-tree API returned `404 File tree not found` with and without explicit team ID. The connector has no Cron Jobs listing. Consequently the deployed Functions, Cron Jobs, effective production flags, and any external backend target remain **unknown**.

At that deployed source commit, the only `src/app/api` route is the bounded client-error collector; it has no server-side wallet or broadcaster. Production frontend source rejects non-GET trading requests, and the client faucet claim path is hidden by the production trading gate. This source check does not attest the deployed Functions or separate remote Rust processes. The local backend's default-off broadcaster is likewise no proof of remote inactivity. Historical failed Railway deployment references are not evidence of current hosting.

**Smallest evidence request:** In Vercel team `corioms-projects`, open project ID `prj_YADz33AWNuLnbnXYvQZOINFIhTTG` → production deployment `dpl_4Ah6VNmKyFVzVdAUH1mbeptz93XS` → **Functions**, and project **Settings → Cron Jobs**. Provide timestamped captures of both complete lists, including empty-state views, with function paths/runtimes and cron schedules/enabled state visible. Redact tokens, cookies, secret values, request bodies and credential-bearing URLs. In the same response, state whether any DeOpt Rust backend, order relay, keeper or broadcaster runs outside local WSL today. If yes, provide its actual provider/service, running status, revision, chain/contract targets and non-secret order/broadcast/worker flags. If no, explicitly attest that none runs remotely. No Railway screenshot is requested unless Railway is the actual host.

Until this evidence is reviewed, remote backend and relayer/keeper isolation remain `NOT_VERIFIED`; C02 S2 remains blocked.

## Exact policy decision for the operator

| Rule | Current approved edge | Proposed edge |
|---|---|---|
| MKT1 **scheduling** | `C02 execution canonical postflight PASS → MKT1 S1 eligible` | `C02 S1 canonical queue postflight PASS → MKT1 S1 eligible` |
| MKT1 **execution** | `C02 S2 canonical postflight PASS → MKT1 S2 eligible` | **Preserved exactly**; MKT1 S1 canonical queue postflight is also required. |

The approved DAG file is unchanged. The prior proposal and bounded fork proof passed integrity checks; the new fork below repeated the decisive ordering with the fresh candidate. A policy approval would change **only** scheduling eligibility. It would not approve any Safe transaction, C02 execution, MKT1 execution, migration, or trading. An explicit **approve or reject this exact edge amendment** decision is required; approval should be recorded separately before updating the approved DAG or promoting any Builder file.

The current DAG imposes at least one additional 86,400-second Timelock delay after C02. Under the proposed DAG, both queues can mature before C02 and no additional protocol delay need follow C02. Actual ACTIVE exposure still includes separate C02 postflight, human MKT1 approval and public inclusion; its worst case is **unbounded**. A short interval is not proof of economic containment. Owner-only migration seeding becomes market-eligible when market 1 exists, and remains unauthorized. D4/D6 closure and absent shared ACL must persist throughout the interval.

## Conditional MKT1 S1 candidate — do not import

The [unsigned one-action Builder candidate](../artifacts/perps_v2_replacement_deployment/mkt1_inactive_early_s1_unapproved_policy_safe_builder_v1.json) is labeled `UNAPPROVED_POLICY_NOT_OPERATOR_READY`. Its [manifest](../artifacts/perps_v2_replacement_deployment/mkt1_inactive_early_s1_conditional_candidate_v1.json) binds the exact calldata and checksums:

| Field | Conditional value at reviewed block |
|---|---|
| Inner call | D1 `setMarketStatus(1,false,false)`, zero ETH |
| Outer call | One Safe CALL to Timelock `queueTransaction(D1,0,inner,eta)` |
| Proposed ETA | `2026-11-01 12:00 UTC` |
| Expiry, inclusive | `2026-11-15 12:00 UTC` |
| Buffered scheduling cutoff | `2026-10-31 11:00 UTC` |
| Operation ID | `0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268` |
| Builder SHA-256 | `663c2ca2738d4657648506b59a0b12f180c9da50be09b22fdb57cc79df48f845` |
| SafeTx hash at nonce 42 | `0xc80e676251c36b9323620d3d520b317e622dadcd3174a9bf769398c43074ebb5` |

The candidate ETA is the next UTC noon at least 48 hours beyond the live 86,400-second minimum delay, using pinned chain time. Read-only Timelock `hashOperation`, queue simulation from the Safe, and Safe `getTransactionHash` matched independently calculated identities. The same-state pre-market setter and unscheduled execution calls rejected. **No Safe UI simulation, gas review, owner confirmation or public submission was performed.** Any Safe nonce, ETA, Timelock state, or maintenance change invalidates the conditional checkpoint and requires a new exact S1 review.

On an isolated Anvil fork of block 51,570,848, a local MKT1 queue transaction left D1 market count zero; execution before ETA and execution after ETA without a market rejected. A local C02 cancellation prevented C02 execution, and MKT1 still could not execute. After reverting that fork branch, local C02 execution created market 1 ACTIVE, then local MKT1 execution made it INACTIVE. Wrong market ID and MKT1 replay rejected; D4's four flags and D6 pause remained true. The local-only hashes and block identifiers are in the decision artifact. The fork impersonated the Safe and did not prove real Safe 2/3 signatures or public inclusion.

## Shortest safe sequence and stopping points

1. Review the exact remote evidence above and decide the policy amendment separately. If rejected, retain the current DAG and its minimum extra delay.
2. If approved, independently review a **fresh** MKT1 S1 envelope, nonce, ETA, operation ID, simulation, gas and balance. Obtain separate real Safe 2/3 authorization and queue once; verify canonical public postflight.
3. Wait until **both** C02 and MKT1 are executable, and before C02 expiry. Recheck remote isolation, D4/D6 and economic containment. Obtain separate C02 S2 authorization; execute once manually; require canonical postflight PASS showing market 1 ACTIVE.
4. Recheck the MKT1 queue, nonce, market ID and maintenance. Obtain separate MKT1 S2 authorization; execute once manually; require canonical postflight PASS showing market 1 INACTIVE and bounded non-drift. Never chain the two executions automatically.

If C02 fails or is cancelled, do not execute MKT1; keep maintenance and separately review cancellation or expiry. If MKT1 fails after C02, keep D4/D6 closed, do not grant shared ACL, migrate or trade, and stop downstream work. Reconcile actual Safe, Timelock and market state, then separately review a retry within the grace period or a new governed schedule. No blind retry or automatic fallback. Each intervening Safe action changes the nonce and invalidates a conditional SafeTx hash; D2/D3 S2 operations are already consumed and are not part of this candidate.

## Independent preparation while blocked

Prepare guardian capability policy and shared ACL cutover review without grants. Review executor identity only once its real service is identified. Oracle/risk parameters and market-2 parameters can be reviewed off-chain against their DAG prerequisites. C03 market-2 creation follows MKT1_INACTIVE; migration preflight and eight seeds follow their separate configuration gates; equality, seal, selective D4/D6 release and restricted first trade remain later independent reviews. None of these is authorized to schedule here.
