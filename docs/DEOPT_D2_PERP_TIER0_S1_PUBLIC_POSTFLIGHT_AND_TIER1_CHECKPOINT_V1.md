# DeOpt D2 PERP tier 0 S1 postflight and tier 1 operator checkpoint

## Tier 0: VERIFIED_SCHEDULED, postflight PASS

The operator-supplied transaction hash `0x2a953395e8de17d6f5064576eda37647bb537e36dff5bffc7c96f7c8195d056` is malformed: it has an odd number of hexadecimal digits. The reported Base Sepolia block **50,291,180** and timestamp **2026-10-26 02:01:44 UTC** contain the exact Safe and Timelock events under the canonical hash **`0x2a953395e8de17d6f5064576eda37647bb537e36dff5bffc7c96f7fc8195d056`**. The canonical block hash is `0x6f665622e0e04f0b4a99e1f87f06e6cedc73c294db17618a62be8f938c875c70`. The supplied hash omitted one `f` near its suffix; it was not silently accepted as a valid hash.

The canonical receipt succeeded. Its Safe input decoded to exactly one zero-value `CALL` to ProtocolTimelock using the reviewed tier-0 scheduling calldata, with the reviewed zero gas/refund envelope. Safe emitted `ExecutionSuccess` for `0xf0063ea75d9f6e6b2ce521d73cd924cf460ea4443b49179217fbda616565e61b` and no `ExecutionFailure`. The deployed Safe recomputed that hash. Safe nonce advanced **31 → 32**.

ProtocolTimelock emitted exactly one `TransactionQueued` for operation `0x1976519a08a3a7e65cbe1a2f77fcf0f5fa0f783ccb6c7ef0e6c87b7481caf45b`: target D2 `0x9947F42cC29A32992bbf2030ee49E35C839EDEd5`, value zero, calldata `setFeeProfile(0,1,0,200)`, ETA **2026-10-27 12:00 UTC**. The deployed Timelock recomputed the operation ID. Queue state was **false before → true at receipt → true at fresh block**. The scheduling block exceeded the 86,400-second minimum delay by **35,896 seconds**, including the required one-hour operational margin.

Pinned getter comparisons changed only Safe nonce and the tier-0 Timelock queue bit at the receipt block. The current D2 tier-0 fee profile remained `(50,300)` ppm; scheduling has not applied the approved future `(0,200)` ppm profile. At fresh block **50,295,433**, hash `0x520cd66206d4850e99f6fe6bdc0d95b489999ece2c4d77e3e89a5fc149a62ba3`, D3 and tier 0 remained queued, tiers 1–4 unqueued, C02 queued, market 1 absent, D4 four emergency flags true, D4 migration OPEN, D6 paused and shared Vault/Insurance authorization absent. Sampled internal Vault mUSDC balances, replacement rebate budget zero and separate legacy budget 999,977 raw units were unchanged. This is bounded non-drift evidence. See the [sanitized postflight](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_0_s1_public_postflight_v1.json).

## Separate manual action 3/6: D2 PERP contract tier 1

Import the existing [one-action Builder JSON](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_1_s1_safe_builder_v1.json), SHA-256 `c94660b2f674b412966bde08347477ad5f81be00def9554d184a366970c5c923`, into the Base Sepolia OPS Safe. It schedules one zero-ETH `CALL` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, targeting D2 `setFeeProfile(1,1,0,200)`: PERP tier 1, 0 maker bps and 2 taker bps. The current tier-1 profile remains `(0,250)` ppm until a separately authorized S2 execution.

| Field | Reviewed value |
| --- | --- |
| Safe nonce / threshold | 32 / 2 of 3 |
| Timelock operation ID | `0xb79986810ad3e08b5495a8edeaed0654da513ef6acfa15e8ff1d496ff2ef4a11` |
| Inner calldata Keccak-256 | `0xa038494c5f3cc048f040ef76bf6afafc01c564e91127c822139102d165f19fc0` |
| Full scheduling calldata Keccak-256 | `0x1569a47e119eb93af51462c2a08863addc2cc7fe0d87054af22f9f3dd6437998` |
| Conditional SafeTx hash | `0xf976a20a5648c068fae109f796edaadfc32b28b8dd64f45101d2dfa4422cf5c4` |
| Safe gas/refund envelope | `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, zero gas token and refund receiver |
| ETA / buffered cutoff | 2026-10-27 12:00 UTC / 2026-10-26 11:00 UTC |
| Cutoff margin at review block | 31,445 seconds (8h 44m 5s) |

The deployed Timelock and Safe independently matched the tier-1 operation ID and nonce-32 SafeTx hash. A read-only queue call from the Safe address returned the reviewed operation ID. The Safe Transaction Service showed only old unexecuted proposals at nonces 10 and 11; the operator must refresh the real Safe UI because indexing may lag. The [checkpoint](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_1_s1_operator_checkpoint_v1.json) records the complete calldata and envelope.

**Stop before public action.** The operator must refresh chain ID 84532, Safe nonce 32, pending proposals, Tier 1 unqueued state, D3/tier-0/C02 queues and D4/D6 maintenance. The actual scheduling block must satisfy `ETA >= block.timestamp + live minDelay + 3600`. In Safe UI, verify exactly one reviewed CALL and its hash, require simulation PASS, acceptable full wallet gas and ETH balance, and two genuine owner confirmations. If any field differs or the cutoff is missed, stop for renewed review. After one operator-submitted transaction, supply its public hash for independent tier-1 postflight before tier 2.

The [cumulative ledger](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_run_progress_v4.json) records **2/6** scheduling postflights PASS. No D2/D3 S2 execution, C02 execution, market creation, migration or trading is authorized.
