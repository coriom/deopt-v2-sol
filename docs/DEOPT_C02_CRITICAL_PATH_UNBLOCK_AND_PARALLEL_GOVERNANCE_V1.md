# DeOpt C02 critical path: current evidence and operator decision

Review snapshot: Base Sepolia block **50,386,725**, hash `0x0dc37c85c14733d680ad01c1dbaab5b1abd4fcd1b28b3452e60cb599b59972d5`, 2026-10-26 07:20:13 UTC. Safe nonce **36**. C02 and all six D2/D3 operations remain queued. Market 1 is absent, D4's four emergency flags are true, D4 migration is OPEN, D4 PME is zero, D5 delay is 600, D6 is paused, and D4 has no shared Vault or Insurance authorization. C02 is ready but execution remains blocked.

## What the infrastructure records actually establish

| Component | Finding | Limit |
|---|---|---|
| Canonical Vercel project `prj_YADz33AWNuLnbnXYvQZOINFIhTTG` | READY production deployment `dpl_DF4Gsa4f3B9zuaRnRXQuZAr8rdXp` tracks `coriom/deopt-v2-frontend` commit `e0b28fb6f30600c832ef084a3e678b60f21947e7`. Exact commit source has one server API route, the bounded client-error collector. Production source gates trading POSTs and the testnet faucet. | Vercel deployment-file API returned 404. Built Functions, Cron Jobs, effective public build configuration and backend URL are not verified. READY is not worker isolation. |
| Rust backend GitHub deployments | All **46** GitHub deployment records have status history containing only `failure`; latest attempt was 2026-07-12. Current three GitHub Actions workflows are CI, with no deployment or schedule job in their source. | No successful GitHub-recorded deployment was found. Manual/provider-side deployment is still possible; Rust backend or worker host and effective flags remain UNKNOWN. |
| Local WSL | Docker lists four DeOpt monitoring containers and no backend container; user systemd lists no matching unit. | Local status says nothing about remote hosts. |
| Historical Railway reference | GitHub attempted deployment to `awake-ambition / production` and failed. Railway is **not** DeOpt's intended active hosting platform. | Historical status is unverified at the provider; no current Railway service is established. No Railway screenshot is requested unless it is identified as an actual current host. |

The remaining C02-specific contract change is that market 1 becomes **ACTIVE immediately**. Prior source/fork work found D4's owner-only position and market-funding seeding become market-eligible once it exists; those still require separate Timelock/Safe governance. Generic Vault/Clearing operations predate C02. Whether a remote backend or worker can intake orders, submit transactions, or act through a legacy authorization is an operational UNKNOWN. Bounded on-chain containment remains intact at this snapshot; it is not a remote deployment attestation.

**Smallest evidence request:** In the canonical Vercel project, provide timestamped views of production deployment `dpl_DF4Gsa4f3B9zuaRnRXQuZAr8rdXp` **Functions** and project **Cron Jobs**, including empty-state views. The connected Vercel deployment-file API returned 404 and offers no Cron Jobs inventory. Separately answer one question: **Is any DeOpt Rust backend, order relayer, keeper or broadcaster deployed outside local WSL today?** If yes, identify its actual host and provide one service-status view with revision, chain ID, public contract targets and non-secret order/broadcast/worker booleans. If no, explicitly attest that there is no separate running host or managed worker. Omit secret values, credentials, RPC tokens, headers and wallet material.

## Exact MKT1 policy decision after operational evidence

The committed technical proposal and fork rehearsal remain intact. The approved DAG is unchanged.

- **Remove scheduling edge:** `C02-S2 canonical postflight PASS -> MKT1_INACTIVE S1 scheduling eligible`.
- **Add scheduling edge:** `C02-S1 canonical queue postflight PASS -> MKT1_INACTIVE S1 scheduling eligible`.
- **Preserve execution edge:** `C02-S2 canonical postflight PASS` **and** `MKT1_INACTIVE S1 queue postflight PASS -> MKT1_INACTIVE S2 execution eligible`.
- **Add C02 checkpoint gates:** both Timelock operations ready; remote operational attestation PASS; fresh maintenance and containment PASS.

The fork previously demonstrated queue-before-market succeeds and does not create a market, early MKT1 execution fails before market creation, C02 then MKT1 succeeds in order, wrong caller/ID and replay fail. It used synthetic Safe impersonation, not real 2-of-3 signatures. Formal policy approval is **not granted** by this review. The prior candidate MKT1 ETA/operation ID is diagnostic only; its buffered cutoff was 2026-10-26 11:00 UTC and must not be reused without a fresh scheduling review.

**Decision once evidence is supplied:** explicitly approve this exact scheduling-edge amendment or retain the existing DAG. Approval changes scheduling eligibility only. It grants no Safe proposal, signature, scheduling or execution permission. Under the existing DAG, market 1 must remain ACTIVE for at least the 86,400-second Timelock delay after C02; the additional one-hour scheduling margin makes a practical minimum 90,000 seconds. With a ready early MKT1 queue, the interval may shrink to C02 postflight plus separate human Safe approval and inclusion. Either path has an **unbounded worst case** if MKT1 fails or operators/RPC are unavailable. A shorter interval does not replace economic containment.

## Future sequence and stopping points

1. Establish remote isolation and obtain explicit policy approval. Independently review a fresh MKT1 S1 ETA, operation ID, calldata and Safe nonce; obtain separate human 2-of-3 approval and schedule it once.
2. Canonically verify MKT1 queue state. Wait until both C02 and MKT1 are ready. Refresh containment, remote state and maintenance; independently authorize C02 S2. Execute C02 once and require canonical postflight PASS showing the exact ACTIVE market and bounded non-drift.
3. Independently authorize MKT1 S2 using its current Safe nonce. Execute once and require canonical postflight PASS showing market 1 INACTIVE. There is no automatic second transaction.
4. If C02 fails or is cancelled, do not execute MKT1; reconcile and separately review cancellation/expiry. If MKT1 fails after C02, keep D4/D6 closed, halt downstream work, reconcile queue/market/nonce and separately review a retry or new schedule. Do not blindly resubmit.

**Nonce interaction:** D2/D3 S2 hashes assume Safe nonces 36–41. An MKT1 scheduling action before D3 changes the next nonce to 37 and invalidates **all six conditional SafeTx hashes**; their Timelock IDs and ETAs remain intact. If D2/D3 executes first, MKT1 must use the later live nonce. Never change a Builder nonce/envelope silently. Six D2/D3 executions remain separately approved and postflight-verified, starting with a fresh D3_TOKEN checkpoint after 2026-10-27 12:00 UTC.

Independent read-only preparation can proceed for `GUARDIAN_POLICY`, `EXECUTOR_IDENTITY_REVIEW` and `ACL_POLICY_REVIEW`; all are maintenance-gated review nodes in the approved DAG. No further governance action is authorized here.
