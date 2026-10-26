# DeOpt D2 PERP tier 1 S1 postflight and tier 2 operator checkpoint

## Tier 1: VERIFIED_SCHEDULED, postflight PASS

Base Sepolia transaction `0x125df3da8578f009c28171daff53877b8d73391b19aa7d4277fdbf131b598496` has a canonical successful receipt at block **50,297,492**, hash `0x08b59e322d663351cad48a3ff47f91f38e0afa856abaf5834245507515d27c11`, timestamp **2026-10-26 02:22:47 UTC**. Its outer destination is `0xdb9b1e94b5b69df7e401ddbede43491141047db3`, selector `0xcef6d209`: the same MetaMask Delegation Manager path and sender previously traced in the [canonical C12-S1 postflight](../artifacts/perps_v2_replacement_deployment/c12_risk_wiring_s1_public_postflight_v1.json). Public RPCs did not provide a current `debug_traceTransaction`, so the current nested path is established by the decoded Safe multisig event, Safe success event, exact Timelock queue event and pinned state rather than a fresh trace.

The Safe multisig event decodes to exactly one zero-value `CALL` to ProtocolTimelock with the reviewed tier-1 scheduling calldata and zero gas/refund envelope. Its Safe `ExecutionSuccess` hash is `0xf976a20a5648c068fae109f796edaadfc32b28b8dd64f45101d2dfa4422cf5c4`; no Safe `ExecutionFailure` appeared. The deployed Safe recomputed the same hash. Safe nonce advanced **32 → 33**.

ProtocolTimelock emitted one `TransactionQueued` event for operation `0xb79986810ad3e08b5495a8edeaed0654da513ef6acfa15e8ff1d496ff2ef4a11`, target D2 `0x9947F42cC29A32992bbf2030ee49E35C839EDEd5`, value zero, `setFeeProfile(1,1,0,200)`, ETA **2026-10-27 12:00 UTC**. The deployed Timelock recomputed this operation ID. Queue state was **false before → true at receipt → true at fresh block**. The scheduling block exceeded the minimum delay by more than the required additional hour.

The only tracked changes at receipt were the Safe nonce and tier-1 queue bit. D2 tier 1 stayed at its existing `(0,250)` ppm profile; scheduling did not apply the future `(0,200)` ppm profile. At fresh block **50,300,500**, hash `0xd8072f28136fb6dd56876497af4bbf0002b6d91e763ea21813108048f37c894d`, D3 and D2 tiers 0–1 remained queued, tiers 2–4 unqueued, C02 queued, market 1 absent, D4 four emergency flags true, migration OPEN, and D6 paused. D2 accounting, the separate 999,977-raw-unit legacy rebate budget, shared ACLs and sampled internal Vault balances remained unchanged. This is bounded non-drift evidence. See the [sanitized tier-1 postflight](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_1_s1_public_postflight_v1.json).

## Separate manual action 4/6: D2 PERP contract tier 2

Import the existing [one-action Builder JSON](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_2_s1_safe_builder_v1.json), SHA-256 `862f6a62c33e73df98dbad816babb97cb60127f35d0547df80f2ae106822d33b`, into the Base Sepolia OPS Safe. It schedules one zero-ETH `CALL` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, targeting D2 `setFeeProfile(2,1,0,200)`: PERP tier 2, 0 maker bps and 2 taker bps. The current tier-2 profile remains `(-50,200)` ppm until a separately authorized S2 execution.

| Field | Reviewed value |
| --- | --- |
| Safe nonce / threshold | 33 / 2 of 3 |
| Timelock operation ID | `0x48b66ca38c21064a6605af4038a657a191a56f327784dc1e0d0bffdc21075a62` |
| Inner calldata Keccak-256 | `0xfea716384948ddb08493c32fb6519f7b6a957218b2269fe79c2e7a7a573c9b2a` |
| Full scheduling calldata Keccak-256 | `0xa2ed3e0aae9a40162505fd7a9f8edacd8fde80ca415f30cbef5330ef4d59def7` |
| Conditional SafeTx hash | `0xe23662c28fe27b9c920f7a4ebaacb3e554c26dc5c01d187fad8861ca4a05d90f` |
| Safe gas/refund envelope | `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, zero gas token and refund receiver |
| ETA / buffered cutoff | 2026-10-27 12:00 UTC / 2026-10-26 11:00 UTC |
| Cutoff margin at review block | 30,432 seconds (8h 27m 12s) |

The deployed Timelock and Safe matched the tier-2 operation ID and nonce-33 SafeTx hash. A read-only queue call from the Safe address returned the reviewed operation ID. The Safe Transaction Service showed only old unexecuted proposals at nonces 10 and 11; the operator must refresh the real Safe UI because indexing may lag. The [checkpoint](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_2_s1_operator_checkpoint_v1.json) contains complete calldata and envelope.

**Stop before public action.** The operator must refresh chain ID 84532, Safe nonce 33, pending proposals, tier-2 unqueued state, D3/tier-0/tier-1/C02 queues and D4/D6 maintenance. The actual scheduling block must satisfy `ETA >= block.timestamp + live minDelay + 3600`. In Safe UI, verify the exact single CALL and SafeTx hash, require simulation PASS, acceptable full wallet gas and ETH balance, and two genuine owner confirmations. If any field differs or the cutoff is missed, stop for renewed review. After one operator-submitted transaction, supply its public hash for independent tier-2 postflight before tier 3.

The [cumulative ledger](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_run_progress_v5.json) records **3/6** scheduling postflights PASS. No D2/D3 S2 execution, C02 execution, market creation, migration or trading is authorized.
