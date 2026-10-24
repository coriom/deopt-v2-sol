# C02 S1 SHA reconciliation and operator review V2

**Checkpoint:** `AWAITING_OPERATOR_SAFE_ACTION`. This review authorizes no public transaction by Codex. Operator approval remains pending.

## Corrected commitment

The previous prompt supplied `32275799536bc5bdcbea5effe58f3a3fd6bda608af79c2dd39c0999bee7a8b9c`. SHA-256 of the exact file bytes, OpenSSL, the original Git blob, the current Git blob and the original C02 final review all agree on **`32275799536bc5bdcbea5effe58f3a3fd6dba608af79c2dd39c0999bee7a8b9c`**. The Builder bytes are unchanged since commit `e77e8bad933bad12f0b09267328694bb8246dc30`. The earlier blocked checkpoint remains intact. This is a prompt transcription error, established with independent payload and ABI checks. Builder: [`c02_market_creation_s1_safe_builder_review_v1.json`](/home/corio/DEOPT/deopt-v2-sol/artifacts/perps_v2_replacement_deployment/c02_market_creation_s1_safe_builder_review_v1.json).

## Fresh pinned state

Base Sepolia block 49461442 (`0x1db257e629b763da804fc51eda42cf1390ea712f690749706b76e961c0beb193`), 2026-10-24T03:55:57Z; pinned hash rechecked. One configured RPC provider supplied pinned reads and canonical receipts. C01 and C12 receipts contain matching Safe `ExecutionSuccess` and Timelock `TransactionExecuted` events and both operations are consumed. Safe v1.4.1 has nonce **29**, threshold **2/3**, reviewed three owners, no modules and zero guard. Timelock minimum delay is **86400 seconds** and Safe proposer authority remains true.

D1 mUSDC settlement allowance is true, market count is zero and market 1 is absent. D4 Risk pointer is D5, PME pointer is zero, migration OPEN and four emergency flags true. D5 maxOracleDelay is 600; D6 remains paused. D4 Vault/Insurance authorizations are false. Bounded Vault/Clearing/Insurance readbacks match the prior checkpoint. The proposed C02 operation is absent; no new D1 target queue events occurred since the original final review. The public Safe Transaction Service reports zero pending nonce-29 proposals; this off-chain view must be checked again in Safe UI.

## Exact reviewed transaction

One Safe `CALL (0)` to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, value zero, scheduling one D1 `createMarket` operation. Market ID **1**; underlying `0x4deebc5f537f3b8ba0e3393807b4d699d72bdd02`, settlement `0x6eae407f5640b006fac9965182e238582a3b412e`, oracle `0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581`, symbol `0x4554482d50455250000000000000000000000000000000000000000000000000`; risk [1000, 750, 500, 10000000000, 50000000000, True], liquidation [5000, 100, 50, 60], funding [False, 0, 0, 0, 0, 0]. Exact `createMarket` calldata Keccak-256: `0x976f360139a3069605b3baa59c1d4bb8c2dc0591c676e6deaf3a5d142089067f`. Exact Timelock scheduling calldata Keccak-256: `0x22c021db87f3dc1a148f0ceb49131260b771cf330551740075a71b233780f315`. Operation ID: `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e`. The custom Timelock hashes target, value, data and ETA; it uses no salt or predecessor.

ETA **1792929600** (2026-10-25 12:00 UTC). Buffered cutoff **1792839600** (2026-10-24 11:00 UTC); at the pinned block **25443 seconds** remained. The actual scheduling block must satisfy `ETA >= block.timestamp + liveMinDelay + 3600`; otherwise stop and review a new operation. Scheduling itself only queues the operation.

Safe nonce **29**; `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, `gasToken=0x0000000000000000000000000000000000000000`, `refundReceiver=0x0000000000000000000000000000000000000000`. Locally derived and on-chain `getTransactionHash` agree: **`0x25599e842b539a2b3aeeb5f6ab7691183127dbd3e578f29e16aa2da65d51ccfe`**, conditional on all fields remaining identical. The Builder JSON does not bind these Safe envelope fields. Read-only Timelock scheduling simulation returned the exact operation ID. Direct Timelock scheduling gas estimate **65766**; this is not the full Safe/wallet cost. Safe UI simulation, full wallet gas and executing-wallet balance remain **PENDING_OPERATOR**.

## Active-market safeguard and operator boundary

Future C02 execution creates market 1 **ACTIVE immediately**. Source and the recorded 33-check isolated fork support bounded isolation while D4's four restrictions, D6 pause, zero PME pointer and missing shared ACLs persist. The fork used Safe-address impersonation; genuine signatures were not tested. Remote backend, relayer and keeper state was **not independently verified**. Before any separately authorized C02 execution, confirm external operational isolation and the active-market interval; `MKT1_INACTIVE` requires its own governance and cannot be presumed immediate. There is no market creation at scheduling.

The operator must manually import the unchanged Builder JSON, review the exact one-action call and all fields, obtain a passing Safe UI simulation, verify full wallet gas and ETH balance, secure genuine 2-of-3 confirmations, and refresh nonce, ETA margin, queue state, proposal inventory and maintenance immediately before one submission. Any drift stops this package. Public scheduling and future execution each require separate canonical postflight and authorization. No signing, proposal, broadcast or public chain mutation was performed by Codex.

Focused fresh checks: **23 passed, 0 failed, 0 skipped**. Historical fork: **33 passed, reused, not rerun**. No Solidity build was run because frozen source and Builder bytes are unchanged.
