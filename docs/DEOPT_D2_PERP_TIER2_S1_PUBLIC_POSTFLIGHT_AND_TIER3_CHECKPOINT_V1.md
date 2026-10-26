# DeOpt D2 PERP tier 2 S1 postflight and tier 3 operator checkpoint

## Tier 2: VERIFIED_SCHEDULED, postflight PASS

The operator's Base Sepolia transaction `0x1ebed3dfdf4e50dac89188fb7e1c71994ed897fb31666596914904011d483937` has a canonical successful receipt at block **50,302,633**, block hash `0xb651231c9c3280f734b20e70fa9a0ca036f915b1dac997075bbd145106fc8d09`, timestamp **2026-10-26 02:39:55 UTC**. Its outer destination `0xdb9b1e94b5b69df7e401ddbede43491141047db3` and selector `0xcef6d209` match the MetaMask Delegation Manager path previously traced in the [canonical C12-S1 postflight](../artifacts/perps_v2_replacement_deployment/c12_risk_wiring_s1_public_postflight_v1.json). The current public RPCs did not provide `debug_traceTransaction` (HTTP 401 or method unavailable). The current nested scheduling path is corroborated by the decoded Safe multisig event, Safe success event, exact Timelock queue event, calldata inclusion in the outer input and pinned state.

The Safe multisig event decoded to exactly one zero-value `CALL` to ProtocolTimelock with the reviewed tier-2 scheduling calldata and zero gas/refund envelope. Safe emitted `ExecutionSuccess` for `0xe23662c28fe27b9c920f7a4ebaacb3e554c26dc5c01d187fad8861ca4a05d90f`, without `ExecutionFailure`. The deployed Safe recomputed that hash. Safe nonce advanced **33 → 34**.

ProtocolTimelock emitted one `TransactionQueued` event for operation `0x48b66ca38c21064a6605af4038a657a191a56f327784dc1e0d0bffdc21075a62`, target D2 `0x9947F42cC29A32992bbf2030ee49E35C839EDEd5`, value zero, `setFeeProfile(2,1,0,200)`, ETA **2026-10-27 12:00 UTC**. The deployed Timelock recomputed the ID. Queue state was **false before → true at receipt → true at fresh block**. The actual scheduling block satisfied the minimum delay plus the extra hour.

The only tracked changes at receipt were Safe nonce and the tier-2 queue bit. D2 tier 2 stayed at its existing `(-50,200)` ppm profile; scheduling did not apply the future `(0,200)` ppm profile. At fresh block **50,319,494**, hash `0xe30748c0914f62dd740222dfe984834eb12b875fc62c8b05fdd9373d4b5497a6`, D3 and D2 tiers 0–2 remained queued, tiers 3–4 unqueued, C02 queued, market 1 absent, D4 four emergency flags true, migration OPEN, and D6 paused. D2 accounting, the separate 999,977-raw-unit legacy rebate budget, shared ACLs and sampled internal Vault balances remained unchanged. This is bounded non-drift evidence. See the [sanitized tier-2 postflight](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_2_s1_public_postflight_v1.json).

## Separate manual action 5/6: D2 PERP contract tier 3

Import the existing [one-action Builder JSON](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_3_s1_safe_builder_v1.json), SHA-256 `68782a3d3875e53929a9b491e7d6ab32fe1547cd2e27471c2348c80ee3da4dc9`, into the Base Sepolia OPS Safe. It schedules one zero-ETH `CALL` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, targeting D2 `setFeeProfile(3,1,0,200)`: PERP tier 3, 0 maker bps and 2 taker bps. The current tier-3 profile remains `(-75,175)` ppm until a separately authorized S2 execution.

| Field | Reviewed value |
| --- | --- |
| Safe nonce / threshold | 34 / 2 of 3 |
| Timelock operation ID | `0xaaf8ae230522b4a6b08a365be6e87f2544392e729b559db44968912b3a177f76` |
| Inner calldata Keccak-256 | `0x43db72a9006597fb8d828c0f94f08a778f231035dab0369cd49a953ce50597e1` |
| Full scheduling calldata Keccak-256 | `0x104ce968ca710aba9fbd6ea92c87d48867edbdc920350f3c9ba9f41df44024f5` |
| Conditional SafeTx hash | `0xf219f8384e48cee81511808c0f93e9a934ce3786a05b9e32c41b28f3c9893090` |
| Safe gas/refund envelope | `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, zero gas token and refund receiver |
| ETA / buffered cutoff | 2026-10-27 12:00 UTC / 2026-10-26 11:00 UTC |
| Cutoff margin at review block | 26,633 seconds (7h 23m 53s) |

The deployed Timelock and Safe matched the tier-3 operation ID and nonce-34 SafeTx hash. A read-only queue call from the Safe address returned the reviewed ID. The Safe Transaction Service showed only old unexecuted proposals at nonces 10 and 11; the operator must refresh Safe UI because indexing may lag. The [checkpoint](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_3_s1_operator_checkpoint_v1.json) contains the complete calldata and envelope.

**Stop before public action.** The operator must refresh chain ID 84532, Safe nonce 34, pending proposals, tier-3 unqueued state, D3/tier-0/tier-1/tier-2/C02 queues and D4/D6 maintenance. The actual scheduling block must satisfy `ETA >= block.timestamp + live minDelay + 3600`. In Safe UI, verify the exact single CALL and SafeTx hash, require simulation PASS, acceptable full wallet gas and ETH balance, and two genuine owner confirmations. If any field differs or the cutoff is missed, stop for renewed review. After one operator-submitted transaction, supply its public hash for independent tier-3 postflight before tier 4.

The [cumulative ledger](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_run_progress_v6.json) records **4/6** scheduling postflights PASS. No D2/D3 S2 execution, C02 execution, market creation, migration or trading is authorized.
