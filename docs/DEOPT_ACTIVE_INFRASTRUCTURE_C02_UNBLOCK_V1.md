# DeOpt active infrastructure C02 review V1

## Decision

`C02_OPERATIONAL_EVIDENCE = PARTIAL`; `C02_S2_EXECUTION_ELIGIBLE = NO`. The canonical DeOpt Vercel project is `deoptv2-frontend` (`prj_YADz33AWNuLnbnXYvQZOINFIhTTG`). Its latest production deployment remains `dpl_FoAjCa4Z4D49pos1KuQ2z8Zntq3U`, READY at commit `938ab3d779c0109ab24a98068799174bcd06a0b2`, with the `deoptv2-frontend.vercel.app` alias. READY does not establish that server functions or workers are disabled. The project's `live:false` metadata is ambiguous.

The Vercel connector returned no project-level custom routes, connector connections, or environment-variable names with `decrypt=false`. The deployment file-tree endpoint returned 404, and the exact GitHub commit was inaccessible (404). These results do **not** enumerate bundled Next.js Functions, API routes or Cron Jobs. Their actual deployed inventory, write capabilities and backend/queue integrations remain UNKNOWN. The historical `deopt-frontend` project was excluded under the operator's product-scope correction; no current evidence links it to replacement D1–D6.

## Other active infrastructure

The Rust backend source at `ad8dd7466aeba6963d28687e825fe4df58ef32ee` contains gated real transaction broadcasting and execution paths. Default and CI-off settings do not prove remote runtime settings. Reviewed backend GitHub Actions workflow definitions use push/PR triggers; no cron trigger was found. Their CI execution and real-broadcast flags are false. GitHub's latest listed Railway deployment (`5416476893`, July 12) has a **failure** status; it is historical evidence, not proof of current Railway service state. Current Rust backend/relayer/keeper provider, revision, running status, effective chain/contract targets and flags remain UNKNOWN. Local Docker has DeOpt monitoring and webhook-sink containers but no DeOpt execution container; local systemd lists no running DeOpt execution unit. These local observations do not attest remote services.

## C02-specific economic change

The trusted prior contract/fork review found bounded on-chain containment. When C02 creates ACTIVE market 1, D4 owner-only migration seed functions become market-eligible; they still require Timelock/Safe authority and are not blocked merely by migration OPEN. ACTIVE status also satisfies a future market-status condition, but D4's four emergency flags, zero PME pointer, paused D6 and absent D4 Vault/Insurance grants currently contain the reviewed replacement economic routes. Generic Vault/Clearing paths and legacy-authorized actors existed before C02. Unknown deployed services and an unbounded ACTIVE interval if MKT1_INACTIVE is delayed are the remaining material C02-specific operational risks.

A fresh direct Base Sepolia read at block `49595281` (`2026-10-24 11:22:05 UTC`, hash `0x4cd11b161d4c151dc74c2a2dd2a4a24ee872d2b141a3df656abfbe5473da2f4c`) confirmed chain 84532, C02 queued, zero markets, D4's four flags true, Risk=D5, PME=zero, migration OPEN, D5 delay=600, D6 paused and D4 shared ACLs false. Safe nonce was 30, threshold 2, and Timelock minDelay 86400. This narrow snapshot does not establish remote isolation.

## Exact operator evidence request

1. In Vercel, open `deoptv2-frontend` → **Deployments** → `dpl_FoAjCa4Z4D49pos1KuQ2z8Zntq3U` → **Functions** (and deployment output if exposed). Provide a redacted screenshot/export with deployment ID and every Function/Edge route, path and runtime, or the empty-state view.
2. Open the same project's **Cron Jobs** page. Provide a redacted screenshot/export showing each path, schedule and enabled status, or the empty-state view.
3. For each discovered route/job, provide revision-matched deployed source or build manifest and only non-secret chain ID, D1–D6 targets, execution/broadcast flags and upstream backend/queue **hostnames**. Redact credential values, RPC URLs, keys, tokens, signatures and wallet material.
4. Identify the actual Rust backend/relayer/keeper provider and service, if any. Provide provider dashboard status, revision, worker/cron/restart inventory and non-secret effective chain/contract targets and execution/order-intake flags, or evidence of absence. For Railway project `5d110969-6d5a-4f78-ab01-60dc3efd55e3` / environment `9fa9cad6-cb27-43ad-b4ed-c8af4e416365`, provide current service status or deletion proof only if it remains relevant.

The smallest next step is **items 1 and 2**. Any route/job or upstream host shown there determines which part of items 3 and 4 must follow. No inaccessible service is treated as disabled.

## MKT1 policy

The hash-verified early-queue proposal remains technically reviewed and **ready for a separate operator policy decision**, with no approval granted. It would replace only the scheduling edge `C02-S2 postflight PASS → MKT1 scheduling eligible` with `C02-S1 queue postflight PASS → MKT1 scheduling eligible`. The execution edge `C02-S2 postflight PASS → MKT1 execution eligible` remains. Existing approved DAG is unchanged. Early scheduling could reduce the minimum ACTIVE interval if both operations are ready, but the maximum remains unbounded under human or technical delay. Any approval still needs fresh remote attestation and distinct Safe 2/3, Timelock, and postflight reviews for each operation. No Builder package or transaction is authorized here.

Evidence: [machine-readable review](../artifacts/perps_v2_replacement_deployment/c02_active_infrastructure_unblock_v1.json), [prior bounded review](../artifacts/perps_v2_replacement_deployment/c02_operational_evidence_mkt1_policy_decision_v2.json), [policy proposal](../artifacts/perps_v2_replacement_deployment/mkt1_early_queue_policy_amendment_proposal_v1.json).
