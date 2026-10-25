# DeOpt D3_TOKEN S1 public postflight and D2 tier-0 operator checkpoint

## D3_TOKEN scheduling: VERIFIED_SCHEDULED, postflight PASS

The operator's Base Sepolia transaction `0x0498427a855c3ee6584bdffe1375f8c965673029f38e3c240f434797985c38f4` has a canonical successful receipt at block **50,002,737**, block hash `0xa2fd0ba057bb29ab7adc9415a8a6c4ee89756a1808770606a95909d10d7550f4`, timestamp **2026-10-25 10:00:16 UTC**. The public transaction called OPS Safe `execTransaction` directly. Decoding the complete Safe input, while omitting signature material from evidence, showed exactly one zero-value `CALL` to ProtocolTimelock with the committed D3 scheduling calldata, all reviewed zero gas/refund fields and no MultiSend or delegatecall.

The receipt emitted exactly one Safe `ExecutionSuccess` for SafeTx hash `0x9d0b933d4297d637a8ce2adcf32af319ce88dfc590260acf6bc8614dfc25c9d9`, no `ExecutionFailure`, and exactly one ProtocolTimelock `TransactionQueued` for operation `0x6678a5eefb1b1a1b7a9ff4aa5795e1ba7d09fba63ee59917d454e07fe2208c0d`. The queue event independently decodes to D3 `0x43Ac3782e75018981a8F8d210049f2A185b07331`, value zero, exact `setTokenSeizeConfig(mUSDC,5,true)` calldata, and ETA **2026-10-27 12:00 UTC**. The scheduling block satisfied the live 86,400-second Timelock minimum delay with **93,584 seconds of extra margin**, exceeding the required one-hour operational buffer.

Pinned Safe nonce was **30 before → 31 at receipt → 31 at fresh block 50,004,105**. The D3 operation was unqueued before, queued at receipt, and still queued at the fresh block. No later D3 Timelock queue/cancel/execute event appeared through that block. D3 `seizeConfigs(mUSDC)` stayed **unset (0, false, false)**; scheduling did not configure the token. All tracked protocol readbacks were identical before, at receipt and fresh block except Safe nonce. D4's four emergency flags stayed true; migration OPEN; D4 risk pointer D5; PME pointer zero; D6 paused; C02 still queued; market 1 absent; no D4 shared Vault/Insurance permission. D2 profiles and recipient remained unchanged. Four sampled mUSDC Vault balances (Safe, Timelock, D2, D3) were unchanged, as were the separate D2 zero and legacy 999,977-raw-unit rebate budgets. This is **bounded** economic non-drift, not exhaustive storage verification.

The public RPC returned HTTP 401 for `debug_traceTransaction`. The matching complete Safe input, Safe success event, exact Timelock queue event, queue getter and target readbacks independently establish this scheduling path. The [sanitized postflight evidence](../artifacts/perps_v2_replacement_deployment/d3_token_s1_public_postflight_v1.json) records exact pinned blocks, decoded fields and readbacks. No D3 Timelock execution is authorized by this result.

## Separate manual action 2/6: D2 PERP contract tier 0

At fresh pinned block **50,004,105**, hash `0x3a8517428d927fbfec563adb2fc82df88d6ad32045b63a1c8d409abab842618c`, timestamp **2026-10-25 10:04:49 UTC**, Safe nonce was **31**, threshold **2/3**, with reviewed owners, no modules and zero guard. ProtocolTimelock minimum delay remained 86,400 seconds. D3_TOKEN remained queued, D2 tier 0 was unqueued, and all other D2 operations were unqueued. The public Safe Transaction Service showed only two old unexecuted proposals at nonces 10 and 11; the operator must check Safe UI again because that service can lag.

Import the existing [D2 tier-0 Safe Builder JSON](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_0_s1_safe_builder_v1.json), SHA-256 `a96781dd681977695a19137de80e79f2f487afb89b28d7f1b010e2fdfea7d6be`, into the Base Sepolia OPS Safe. It contains exactly one zero-ETH `CALL` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, scheduling D2 FeesManagerV2 `0x9947F42cC29A32992bbf2030ee49E35C839EDEd5` `setFeeProfile(0, PERP, 0, 200)`. `PERP=1`; 0 and 200 ppm equal **0 maker bps and 2 taker bps**. Current tier-0 profile remains `(50,300)` ppm until a separate future Timelock execution.

- Inner calldata Keccak-256: `0x9d9a42e1dd2b52e774708826b8be513d438b994581f9025da7c350a79ab1f5ef`.
- Full Timelock scheduling calldata Keccak-256: `0x3c14289bb55200f8ef87686f2f961090aeeb24f46748acf39347cd1692885340`.
- Timelock operation ID: `0x1976519a08a3a7e65cbe1a2f77fcf0f5fa0f783ccb6c7ef0e6c87b7481caf45b`.
- Safe nonce **31**; `CALL (0)`; zero ETH, `safeTxGas`, `baseGas`, `gasPrice`, gas token and refund receiver.
- Conditional SafeTx hash, matched with deployed `getTransactionHash`: `0xf0063ea75d9f6e6b2ce521d73cd924cf460ea4443b49179217fbda616565e61b`.
- ETA: **2026-10-27 12:00 UTC**. Buffered cutoff: **2026-10-26 11:00 UTC**. At the pinned review block **89,711 seconds** remained before cutoff.

The exact full calldata and envelope are in the [tier-0 checkpoint](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_0_s1_operator_checkpoint_v1.json) and the reviewed Builder. A read-only Timelock queue `eth_call` from the Safe address succeeded; it does not simulate genuine Safe signatures or full wallet gas.

**Stop at the operator checkpoint.** Before any separately approved manual submission, refresh chain ID 84532, Safe nonce 31 and pending proposals, Timelock queue and minDelay, ETA margin against the **actual** scheduling block, D3/D4/D5/D6 maintenance, C02 queue and absent market 1. In Safe UI verify the exact one-action calldata and SafeTx hash, require simulation PASS, acceptable full wallet gas and balance, and two genuine owner confirmations. If any field differs or the cutoff is missed, stop for renewed review. After one operator-submitted public transaction, provide its hash for a separate canonical tier-0 scheduling postflight. Do not continue to tier 1 without PASS.

The versioned [cumulative ledger](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_run_progress_v2.json) now records **1/6** scheduled operations. Codex sent no public transaction and did not propose or sign a Safe action.
