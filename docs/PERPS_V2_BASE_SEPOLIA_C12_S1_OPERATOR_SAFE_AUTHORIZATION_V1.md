# C12 S1 operator checkpoint

Status: **AWAITING_OPERATOR_SAFE_ACTION**. Exact offline transaction review: **PASS**. Final public approval and execution remain with the operator. Codex sent no public transaction, proposal, or signature.

Pinned Base Sepolia block **48595437**, hash `0x2724faf2efbe39e4b1b636055bca66ac16528c1439683c52e4d659195195c05e`, timestamp **2026-10-22T03:49:16Z**. Chain ID 84532. The block hash was rechecked after pinned reads. The supported C12/C20 gate independently passed at block 48595906 (`0x76baff1df07a5abbb52f2a404a89c1ef811a4c8c1fffff694399944863709fd4`); these are separate snapshots.

C20 has a canonical successful receipt, its queue entry is consumed, and D5 `maxOracleDelay` reads 600 at both receipt and checkpoint. D4's four emergency flags remain true; migration is OPEN, Risk and MatchingEngine pointers zero, and Vault/Insurance D4 authorizations absent. D6 remains paused. Checks are bounded to supported getters and scoped events.

- OPS Safe: `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, nonce **25**, threshold **2/3**, owner set and modules/guard/fallback unchanged.
- Destination: ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`; one **CALL (0)**, **0 wei**.
- Inner action: D4 `0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB` `setRiskModule(0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110)`; inner calldata Keccak `0x793e647f899a70e7ad9bb5b3fd503eec492225662b0e64a76e46b16f8947fcd5`.
- Timelock operation: `0xd15ec63a22daebd4eb015de23561089547af9b02945fb8ae6dd7028ae7581229`; ETA **1792756800** (2026-10-23 12:00 UTC). Exact outer calldata Keccak `0xa2c1e022d78cd6f666743082e69a91d68a7f60a41fc9627842d8c636db388e29`. The operation is absent from the queue; pinned `eth_call` from the Safe address returns the expected ID. This does not prove real Safe signatures.
- Buffered scheduling cutoff: **1792666800** (2026-10-22 11:00 UTC). Remaining margin at checkpoint: **25844 seconds**. The actual scheduling block must satisfy `ETA >= timestamp + live minDelay + 3600`.
- Safe envelope: nonce 25, safeTxGas 0, baseGas 0, gasPrice 0, gasToken zero address, refundReceiver zero address. Local EIP-712 and deployed `getTransactionHash` both return `0x6cce2c2dcde9635050713acf875793ae2d6767d35f0f755318c9eec72260b9bf`. The zero refund fields do not make outer wallet gas free.
- Existing import file: `/home/corio/DEOPT/deopt-v2-sol/artifacts/perps_v2_replacement_deployment/c12_risk_wiring_fast_s1_safe_builder_v1.json`; SHA-256 `6f66db71d432e071ce0a7d23ed0db8f31e29998cfd941da7a818be1859bf5177`. Preserve this file and the reviewed intent unchanged.
- Read-only direct Timelock gas estimate from the Safe address: **57139**; gas price observation **6000000 wei**. Full Safe/wallet gas, executing wallet balance, pending Safe proposal inventory, and Safe UI simulation: **PENDING_OPERATOR_SAFE_UI**.

Before any manual Safe action, the operator must confirm no duplicate proposal, exact single CALL and hash, nonce/owners/threshold, successful Safe UI simulation, acceptable full wallet gas and balance, and two genuine owner confirmations. Refresh Timelock queue, delay, D4/D5/D6 state, and the actual block timestamp immediately before execution. A changed field or missed cutoff requires a new review. Scheduling does not execute C12; a separate execution review and authorization after ETA are mandatory.

Checkpoint evidence: `/home/corio/DEOPT/deopt-v2-sol/artifacts/perps_v2_replacement_deployment/c12_risk_wiring_s1_operator_checkpoint_v1.json`; SHA-256 `388ae92120dabac40df4da4f30b7f9e2c4e6ca7f53e0ccb533c7f3f5712ccbd8`. Previous focused tests: 37 passed; not rerun because no material drift. Current evidence validation: pinned direct reads, canonical ABI/hash recomputation, on-chain Safe hash cross-check, direct eth_call, and supported C12/C20 preflight passed.
