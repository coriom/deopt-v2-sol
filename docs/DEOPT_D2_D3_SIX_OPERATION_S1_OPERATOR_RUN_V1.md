# DeOpt D2/D3 six-operation S1 operator run — checkpoint 1/6

**D3_TOKEN = AWAITING_OPERATOR. Completed scheduling operations = 0/6.** This is a read-only checkpoint. No Safe proposal, signature, public transaction, or Timelock state change was performed by Codex.

At Base Sepolia block **49,996,402**, hash `0x1134b971a4a76c716af6c9b1975367eaacf8a6370ecc7c54e0e3530f284e3215`, timestamp **2026-10-25 09:39:09 UTC**, the OPS Safe remained at nonce **30**, threshold **2/3**, with the reviewed owners, no modules, and zero guard. The custom ProtocolTimelock minimum delay remained **86,400 seconds**, with the Safe authorized as proposer. The D3_TOKEN operation was unqueued; scoped D3 Timelock queue/cancel/execute events since the prior approved review were absent. The public Safe Transaction Service reported two unexecuted historical proposals at nonces 10 and 11, with no observed nonce-30 conflict. Its off-chain index can lag, so the operator must inspect the actual Safe UI immediately before approval.

All tracked maintenance and economic readbacks matched the prior approved snapshot: D4's four emergency flags true, migration OPEN, D4 risk pointer D5, D4 PME pointer zero, D6 paused, D3's compatible collateral RiskModule unchanged, D5 oracle delay 600, no D4 shared Vault/Insurance authorization, C02 still queued, market 1 absent, and D2/legacy rebate ledgers separate. D3's mUSDC seize config remains unset. These are bounded readbacks, not exhaustive storage verification.

## Exact manual action 1/6

Import the existing [D3_TOKEN Safe Builder JSON](../artifacts/perps_v2_replacement_deployment/d3_token_s1_safe_builder_v1.json), SHA-256 `d4979b07fbe862ac423d0746317e2ae75570559b4b661bf8d4a7f159a4144c40`, into the **Base Sepolia OPS Safe** `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`. It contains exactly one zero-ETH `CALL` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`: `queueTransaction(D3,0,setTokenSeizeConfig(mUSDC,5,true),1793102400)`.

- D3 target: `0x43Ac3782e75018981a8F8d210049f2A185b07331`.
- mUSDC: `0x6eAe407f5640B006faC9965182e238582A3B412E`; spread **5 bps**, enabled **true**.
- Inner calldata Keccak-256: `0x457d5f8405645d8abca5f4052fb45164ac921ac32fbdca61b32bdf0ebef40c87`.
- Full Timelock scheduling calldata Keccak-256: `0x7eb90b45c3f44dd1df2220abc23be59f6688d5dd6947344705547479ff81b3a2`.
- Operation ID: `0x6678a5eefb1b1a1b7a9ff4aa5795e1ba7d09fba63ee59917d454e07fe2208c0d`.
- Reviewed Safe nonce: **30**; complete envelope is zero `safeTxGas`, `baseGas`, `gasPrice`, `gasToken` and `refundReceiver`; operation `CALL (0)`.
- Recomputed SafeTx hash, matching deployed `getTransactionHash`: `0x9d0b933d4297d637a8ce2adcf32af319ce88dfc590260acf6bc8614dfc25c9d9`.
- ETA: **2026-10-27 12:00 UTC**. Buffered latest scheduling block time: **2026-10-26 11:00 UTC**. At the pinned review block **91,251 seconds** remained until cutoff.

The exact full bytes are in the [reviewed unsigned intent](../artifacts/perps_v2_replacement_deployment/d2_d3_s1_unsigned_intents_v1.json) and [checkpoint evidence](../artifacts/perps_v2_replacement_deployment/d3_token_s1_operator_checkpoint_v1.json). The pinned read-only Safe-address `eth_call` to queue this operation succeeded, but it did not test a real Safe execution or genuine signatures.

## Operator gate and stop point

Before a separately approved manual submission, recheck chain ID **84532**, Safe nonce **30**, Safe owner set and threshold, absence of a conflicting pending proposal, operation still unqueued, D3/D4/D5/D6 maintenance, C02 queue and absent market 1. The **actual public scheduling block** must satisfy `ETA >= block.timestamp + live minDelay + 3600`; stop if it does not. Verify the exact one-action Builder bytes, envelope and SafeTx hash in Safe UI, require simulation PASS, acceptable **full wallet** gas estimate and ETH balance, and two genuine owner confirmations. These operator-side checks are **PENDING**, so this checkpoint itself is not authorization to submit.

After the operator sends one approved transaction and supplies its public hash, perform independent receipt, Safe `ExecutionSuccess`, nonce, Timelock `TransactionQueued`, queued/unexecuted state and maintenance postflight. Only `POSTFLIGHT = PASS` allows the next D2 tier's fresh operator checkpoint. Do not resubmit after an ambiguous outcome. The cumulative [six-operation progress ledger](../artifacts/perps_v2_replacement_deployment/d2_d3_six_operation_s1_run_progress_v1.json) records **0/6** completed, with all D2 actions waiting on earlier canonical postflights.
