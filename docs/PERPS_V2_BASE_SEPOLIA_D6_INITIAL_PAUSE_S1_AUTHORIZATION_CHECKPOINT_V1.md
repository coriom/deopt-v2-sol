# D6 M1 pause: S1 Safe scheduling authorization checkpoint

**Terminal status: `AWAITING_OPERATOR_SAFE_ACTION`.** The read-only preflight and exact offline transaction review passed. This workspace has no connected OPS Safe UI or Safe owner signing capability. No Safe proposal, owner confirmation, public submission, Timelock scheduling, or D6 pause was attempted. The machine-readable [checkpoint evidence](../artifacts/perps_v2_replacement_deployment/m1_d6_pause_s1_scheduling_authorization_v1.json) records the pinned reads and the exact reviewed fields.

## Fresh preflight

Base Sepolia chain ID **84532**, block **48,009,885**, hash `0x79ddad7bf3c46f73335eaf77c177ed7bfbb9fb19ebd43a266d28b4af1abdda25`, timestamp **1791788058**. Repository HEAD was `bb10c9b011863a66f348066347020792074cfccc`, with a clean worktree. The committed M1 preparation, scheduling final review and unsigned Safe intent retain their expected SHA-256 hashes. Frozen Solidity source is unchanged. D1–D6 runtime hashes and owners match the canonical deployments; D1 markets remain empty. D4 remains OPEN with zero Risk/PME pointers, zero snapshot and residual debt, false emergency flags and no Vault/Insurance authorization. D5 `maxOracleDelay` remains zero. D6 is owned by ProtocolTimelock, has zero pending owner and guardian, points to D4, and is **unpaused**. The M1 Timelock operation is neither queued nor ready.

OPS Safe `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` still reports version 1.4.1, threshold **2/3**, the reviewed three owners, nonce **19**, no enabled modules and zero guard. It retains the deployed custom ProtocolTimelock's proposer and executor roles. Timelock minimum delay remains **86,400 seconds**. A pinned read-only simulation of the exact queue call from the Safe address returned the reviewed operation ID. The Safe's read-only transaction-hash getter returned the reviewed conditional SafeTx hash.

## Exact operator transaction review

`S1_EXACT_TRANSACTION_REVIEW = PASS` for the offline fields below. This is a checkpoint for **explicit operator approval in the normal Safe workflow**, not a Safe proposal or signature.

| Field | Reviewed value |
| --- | --- |
| Chain | Base Sepolia, 84532 |
| Safe | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` |
| Safe nonce observed | `19`; refresh before any Safe action |
| Destination | ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` |
| Value / Safe operation | `0 wei` / `CALL` (`0`), no MultiSend or delegatecall |
| Timelock function | `queueTransaction(address,uint256,bytes,uint256)` |
| Inner target / value / data | D6 `0xeeA4e5d891B90D3d99E9C4e2c61069911477110E` / `0` / `0x8456cb59` (`pause()`) |
| ETA | `1792029034` = 2026-10-15 01:50:34 UTC |
| Timelock operation ID | `0xce251e4c40b88520a90eab4f2e955ff6bd810f25f6e28c3e3d253dcafc93db02` |
| Outer calldata Keccak-256 | `0xf6b1c5b1a0b6df93df2c8b863e850ed06fc8499a6ae069c56136f09e4e319b05` |
| Conditional SafeTx hash | `0x3fb35cf8215315d5da8d157c5f2631a251f59a525a4a55eb9a6df9eed951320b` |
| Safe gas/refund fields | `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, zero gas token and refund receiver, exactly as committed |

Exact outer calldata:

```text
0x8e361cdf000000000000000000000000eea4e5d891b90d3d99e9c4e2c61069911477110e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000006ad0316a00000000000000000000000000000000000000000000000000000000000000048456cb5900000000000000000000000000000000000000000000000000000000
```

The theoretical latest valid scheduling-block timestamp is **1791942634** (2026-10-14 01:50:34 UTC). The requested additional one-hour operational buffer makes **1791939034** (2026-10-14 00:50:34 UTC) the latest acceptable timestamp at the final pre-execution gate. At the pinned review block, **154,576 seconds** remain to the theoretical deadline, with **150,976 seconds** beyond the one-hour buffer. A later Safe proposal, confirmation or execution must recheck the live timestamp, nonce, roles, threshold, owners, operation state and D4/D6 state. Missing the buffered cutoff, or any change to the reviewed Safe fields, requires stopping for a new review. Do not silently change ETA, operation ID or calldata.

The fresh direct Safe-address-to-Timelock queue estimate is **56,489 gas**. This excludes Safe `execTransaction`, signature validation and outer transaction overhead. A full Safe-mediated gas estimate and outer execution gas limit remain **unreviewed**; no gas envelope is approved. A Safe UI that constructs materially different gas/refund fields changes the SafeTx hash and must be reviewed before signing.

## Operator and postflight boundary

The operator must use the normal OPS Safe 2-of-3 workflow. No owner secrets or impersonation are available to this agent. Before any public Safe execution, independently verify two valid owner confirmations, the exact SafeTx hash and fields, nonce 19, the D6 unpaused state, the Timelock's empty M1 queue, and `ETA >= actual scheduling-block timestamp + live minDelay + 3600`. The current SafeTx hash is **not** a public Ethereum transaction hash or the Timelock operation ID.

If a Safe submission is ambiguous, reconcile read-only; do not retry automatically. Successful S1 postflight requires a canonical receipt, Safe `ExecutionSuccess` without an inner failure, exact Timelock `TransactionQueued` event and queued readback, ETA and operation ID exact, Safe nonce advancement, D6 still `paused=false`, and D4/shared state unchanged. A queued operation is not an executed pause. Timelock execution of M1 (S2) and all M2 activity require separate review and authorization.
