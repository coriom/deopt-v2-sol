# C12 S2 operator checkpoint

Status: **AWAITING_OPERATOR_SAFE_ACTION**. This is a read-only checkpoint at Base Sepolia block 49441433 (`0x0453ff5ac2daa043ed50294a4ecc32548f4d651727fcdbb4c947605ac881ae6f`, 2026-10-24T02:49:15Z). No public transaction or Safe proposal was sent by this agent.

The canonical C01 receipt at block 49433335 has status 1, Safe ExecutionSuccess and C01 Timelock TransactionExecuted. At the pinned review block, D1 allows mUSDC and has zero markets. C12 remains queued and ready; no C12 execution or cancellation event appeared since the C01 postflight snapshot. The source-verified C12 window is 2026-10-23 12:00 UTC through 2026-11-06 12:00 UTC, inclusive. The queued operation ID is `0xd15ec63a22daebd4eb015de23561089547af9b02945fb8ae6dd7028ae7581229`.

The exact one-action Builder file is [c12_s2_safe_builder_v1.json](../artifacts/perps_v2_replacement_deployment/c12_s2_safe_builder_v1.json) (SHA-256 `e8d11801a404e944cffb0eefd8c5975bc6b224261c4ec0260bc6dff9b3c5e61e`). It calls ProtocolTimelock `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588` with value zero and CALL operation. The Timelock calls D4 `0xd0901de8f6de72aecc716ca1465c4cf58a0b99fb` with `setRiskModule(0x90caa6d5bc628577bc76d6cc8b775f983c75e110)`, value zero and ETA `1792756800`. Inner calldata Keccak-256: `0x793e647f899a70e7ad9bb5b3fd503eec492225662b0e64a76e46b16f8947fcd5`. Complete Timelock execution calldata Keccak-256: `0x963584c123980e342dc6ee8eb9855243b6c75e05240235f579c64470f2224619`.

Safe `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`: nonce **28**, threshold **2 of 3**, no modules or guard. The complete reviewed Safe envelope is `safeTxGas=0, baseGas=0, gasPrice=0, gasToken=0x0000000000000000000000000000000000000000, refundReceiver=0x0000000000000000000000000000000000000000`. Local EIP-712 computation and deployed `getTransactionHash` agree: **`0xb41d702689c8be0df90db46c02cd6896c60dd45ac9065575bbfa462d16781eed`**. This hash is conditional on the nonce and every envelope field remaining unchanged. The Builder file does not encode the Safe nonce or gas/refund envelope; confirm them in the Safe UI.

D4 Risk and MatchingEngine pointers remain zero, all four emergency flags are true, migration is OPEN, and D4 lacks Vault and Insurance authorization. D5 still points to D4 and reads `maxOracleDelay=600`. D6 remains paused. Selected Clearing and Insurance ledgers, Vault and Insurance token balances, D2 rebate state, D3 token configuration and D6 executor permissions match the C01 postflight baseline. These are bounded getter checks, not exhaustive storage proof.

A read-only direct Timelock `eth_call` from the Safe address succeeded; direct Timelock gas estimate was **64143** at the review snapshot. Observed network gas price was **6000000 wei**. This does not verify 2/3 Safe signatures or the full Safe/wallet gas cost. **Safe UI simulation, full wallet gas estimate and executing-wallet ETH balance remain pending operator checks.**

## Manual stopping point

1. Refresh chain ID, block timestamp, Safe nonce/owners/threshold, Timelock queue/readiness and C12 expiry, D1/D4/D5/D6 state, and shared ACLs immediately before action.
2. Import only the reviewed C12 Builder JSON. Confirm exactly one CALL to ProtocolTimelock, zero ETH, D4 target, D5 argument, ETA, operation ID, calldata hash, nonce 28 and all gas/refund fields.
3. Require Safe UI simulation PASS, acceptable full wallet gas estimate, sufficient wallet ETH, no conflicting Safe proposal and the exact SafeTx hash above.
4. Approve explicitly and obtain two genuine Safe owner confirmations. Execute manually exactly once. If submission is ambiguous, stop and reconcile read-only.
5. Provide the public transaction hash for a separate C12 postflight. A successful outer receipt alone is insufficient.

No C12 public execution, market creation, ACL change, migration or trading is authorized by this checkpoint. No further governance operation follows automatically.
