# DeOpt D2/D3 S1 run: fresh resume and tier 0 checkpoint

At pinned Base Sepolia block **50,285,641** (`0xf3ed8276bfbde7fc302759ef5bdd130daab66bca823e7a7f366dc58f1c33037f`, 2026-10-26 01:43:17 UTC), OPS Safe nonce was **31** with its reviewed three owners, threshold 2, no modules and zero guard. The custom ProtocolTimelock minimum delay was 86,400 seconds; Safe remained an authorized proposer and executor. The D3_TOKEN operation was queued. All five reviewed D2 fee operations were unqueued. A scoped Timelock event scan from the prior D3 postflight through this block found no later D2/D3 queue, execute or cancel event. The Safe Transaction Service showed two old unexecuted proposals at nonces 10 and 11, with no nonce-31 proposal observed; the operator must refresh Safe UI because the service can lag.

All four D4 emergency flags remained true, D4 migration OPEN, its D5 risk pointer intact and PME pointer zero. D6 remained paused. D3 retained its compatible collateral RiskModule, with mUSDC seizure configuration still unset. D2's five PERP profiles, ProtocolTimelock recipient and zero replacement rebate budget were unchanged; the separate legacy rebate budget remained 999,977 raw units. C02 stayed queued, market 1 absent, and D4 had no Vault or Insurance authorization. Four sampled **internal Vault mUSDC ledger balances** matched the prior postflight. This is bounded non-drift evidence, not an exhaustive storage audit. The [read-only reconciliation](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_resume_readonly_v3.json) records the pinned state and the exact source limitations.

## Operator action 2/6: D2 PERP contract tier 0

Import the existing [one-action Builder JSON](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_0_s1_safe_builder_v1.json), SHA-256 `a96781dd681977695a19137de80e79f2f487afb89b28d7f1b010e2fdfea7d6be`, into the Base Sepolia OPS Safe. It schedules one zero-ETH `CALL` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`; the Timelock target is D2 `0x9947F42cC29A32992bbf2030ee49E35C839EDEd5` and the exact setter is `setFeeProfile(0,1,0,200)`, meaning PERP tier 0, 0 maker bps and 2 taker bps. Scheduling leaves the current `(50,300)` ppm profile unchanged until a separately authorized S2 execution.

| Field | Reviewed value |
| --- | --- |
| Safe nonce / threshold | 31 / 2 of 3 |
| Timelock operation ID | `0x1976519a08a3a7e65cbe1a2f77fcf0f5fa0f783ccb6c7ef0e6c87b7481caf45b` |
| Inner calldata Keccak-256 | `0x9d9a42e1dd2b52e774708826b8be513d438b994581f9025da7c350a79ab1f5ef` |
| Full scheduling calldata Keccak-256 | `0x3c14289bb55200f8ef87686f2f961090aeeb24f46748acf39347cd1692885340` |
| Conditional SafeTx hash | `0xf0063ea75d9f6e6b2ce521d73cd924cf460ea4443b49179217fbda616565e61b` |
| Safe gas/refund envelope | `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, zero gas token and refund receiver |
| ETA | 2026-10-27 12:00 UTC |
| Buffered scheduling cutoff | 2026-10-26 11:00 UTC |
| Remaining cutoff margin at review block | 33,403 seconds (9h 16m 43s) |

The deployed Timelock recomputed all five reviewed operation IDs. The deployed Safe recomputed this tier's conditional SafeTx hash. An `eth_call` from Safe to Timelock returned the exact tier-0 operation ID; no public state change occurred. The [fresh tier-0 checkpoint](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_0_s1_operator_checkpoint_v2.json) preserves the complete transaction envelope.

**Stop for separate manual approval.** Immediately before submission, refresh chain 84532, Safe nonce 31, owners, threshold, modules, guard, pending proposals, operation state, D3/D4/D5/D6 maintenance, C02 queue and market absence. The actual scheduling block must satisfy `ETA >= block.timestamp + live minDelay + 3600`; if it cannot, stop and review a new ETA and all derived identities for unscheduled tiers. In Safe UI require the exact one-action transaction and SafeTx hash, successful simulation, acceptable full wallet gas and balance, and two genuine owner confirmations. Codex must not propose, sign or broadcast. After the operator submits one transaction, supply its public hash for canonical tier-0 postflight. Do not advance to tier 1 on an outer receipt alone.

The [cumulative ledger](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_run_progress_v3.json) records **1/6** scheduled operations. Six separate S2 execution packages and a runbook become relevant only after all six S1 public postflights PASS; no S2 execution is authorized now. C02 execution remains blocked pending separate active-market operational evidence and, for the proposed accelerated sequence, separate MKT1 early-queue policy approval. D2/D3 scheduling does not change those C02 gates.
