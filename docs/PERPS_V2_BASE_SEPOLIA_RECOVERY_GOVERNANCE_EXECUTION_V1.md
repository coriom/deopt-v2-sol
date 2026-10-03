# PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_EXECUTION_V1

Status: **PAYLOADS=PREPARED; TIME_GATE=NOT_YET_EXECUTABLE; SAFE_INTERFACE_COMPARISON=PENDING.** This is preparation for two distinct operator-controlled Safe execute calls, not an execution authorization or a completed milestone. No keystore, signature, Safe proposal, public transaction, Timelock execute, rebind, unpause, backend start or trade was used. The historical queue files and reports remain unchanged.

## Read-only checkpoint

Solidity HEAD `91be6559c9bc0bf810e5c116a4d17253886dbb3d`; backend HEAD `ad8dd7466aeba6963d28687e825fe4df58ef32ee`. Base Sepolia chain ID **84532**. Comparison used latest canonical block **47,624,415**, hash `0x677abfe5b414f5cb4e16661cc18c3b714ed1e7a5485cdd440d7e3e42c538e567`, timestamp **2026-10-03 08:45:18 UTC**. The provider's observed safe head was **47,624,333** and finalized head **47,623,564**; both exceed the G1/G2 queue blocks, but the comparison block and its economic reads are latest-head observations, not finalized-state claims.

The original G1 queue transaction `0x7b68dfe378952e2eae86915e1ae908027293506397443de5ba01b8de9fb68eb9` remains canonically included with status 1 at block **47,613,107** (hash `0x2f88c9ab9dfe9e9a36a20bd1dee8fb5f6eb6ca4e40ecc6486b224359a4f6ae7c`). G2 queue transaction `0x4bab77791496f15524f9a5a5b602e6e8369bbc636bef6400e3cfd73b332c354e` likewise remains included with status 1 at block **47,613,842** (hash `0xbe0102ec2e274b7b7bd0ea12628196bd2cf95cd25e2755ddc31dbe75b674a40d`). Each public receipt, nested Safe success, queue event and operation ID were rechecked against the approved queue manifest. These are queue receipts, not execution receipts.

Both operation IDs are still queued. Insurance `isBackstopCaller(NEW_ENGINE)` and Vault `isAuthorizedEngine(NEW_ENGINE)` are **false**. Both target contracts are Timelock-owned; the Timelock owner is OPS_SAFE and the Safe retains executor permission. `minDelay=86,400`, `GRACE_PERIOD=1,209,600`, `queuePaused=false`. Timelock runtime matched the committed artifact. Safe nonce is **17**, threshold **2/3**, with owners `0xb9f8de807ff98d5730035a8bfed4bda33e886d06`, `0x0e7dcb5b9fd969e4fdc6f3a7b7993819ddc5a35d`, `0xa774c46c41064524df895bd7be9f294409798dfc` and no enabled module. Off-chain pending Safe proposals were not established by the available transaction-service path; the operator must inspect the Safe queue before any signature.

The existing verifier passed **114** migration/economic/dependency checks, **14** seed flags, **6** position indexes and **6** PME trader nonces. Both PME contracts remain paused; V1, OLD and NEW Engines each have all four emergency flags true. Both V2 Engines remain SEALED with canonical snapshot hash `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`. Positions, both markets' funding/timestamps, OI and residual debt match prior postflight. Clearing Vault ledger remains **1,000,000,000** native mUSDC. PME_V2 and RISK_V2 still point to OLD_ENGINE; FMV2 NEW_ENGINE fee-consumer permission remains false. The backend was locally STOPPED under the existing process/port check; this does not exclude external callers. A bounded scan of reviewed protocol/governance emitters from block **47,614,195** through **47,624,415** found zero events; this is not a global absence-of-activity claim.

## Two separate execute calls

The deployed `ProtocolTimelock.executeTransaction(address,uint256,bytes,uint256)` has selector **`0x06a41d09`**, is payable, returns `bytes`, requires an authorized executor, a queued operation, `eta <= block.timestamp <= eta + GRACE_PERIOD`, and exact `msg.value == value`. It clears the queued flag, calls the target and emits `TransactionExecuted`; a failed target call reverts the whole transition. No batch or predecessor/salt is part of this interface. The inner calldata below was decoded from each canonical `TransactionQueued` event and compared with its approved queue manifest. Local IDs were recomputed as Ethereum Keccak-256 of `abi.encode(target,0,data,eta)` and matched live `hashOperation`.

| Field | E1: G1 Insurance | E2: G2 Vault |
|---|---|---|
| Original operation ID | `0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6` | `0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846` |
| Inner target/call | Insurance `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` / `setBackstopCaller(NEW_ENGINE,true)` | Vault `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` / `setAuthorizedEngine(NEW_ENGINE,true)` |
| Inner selector | `0x0f62e507` | `0x3331c56e` |
| Proposed Safe nonce | **17** | **18, only after E1 consumes 17 successfully** |
| Proposed SafeTx hash | `0xee4ad79dac2ddf37019731cd9bc255f85531e8f82607c1c56a02ef8eb457911d` | `0x6d2383e70c856f106dc92aa896755df6373d7968be103572f9b5eb2eb0bcf8c8` |
| Expected effect after a separately authorized execution | G1 queued false; NEW_ENGINE Insurance backstop permission true | G2 queued false; NEW_ENGINE Vault permission true and authorized-engine list updated if applicable |

Both Safe calls are direct **CALL(0)** transactions to Timelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, ETH value **0**, calling `executeTransaction` with the respective immutable queued target, inner data and original ETA **1791086934**. Each proposed Safe transaction has `safeTxGas=baseGas=gasPrice=0`, zero gas token and refund receiver. The complete inner/outer calldata, independently decoded arguments, proposed Safe fields and both local/on-chain SafeTx hashes are in the two review manifests. The local Safe EIP-712 hash implementation also reproduces both previously observed *queue* SafeTx hashes before hashing these new *execute* calls; neither queue SafeTx hash is reused. The minimal ABI is [`execute_transaction_abi.json`](../artifacts/perps_v2_recovery_governance_execute/execute_transaction_abi.json).

The original ETA is **2026-10-04 04:08:54 UTC** and the inclusive grace-window end is **2026-10-18 04:08:54 UTC**. At the recorded comparison block, **69,816 seconds (19h 23m 36s)** remained before ETA. `isOperationReady` was false for both; an `executeTransaction` simulation before ETA would revert `TransactionNotReady`. No state override or future-time simulation was used. Reaching ETA alone authorizes nothing: after ETA, refresh all gates and require `isOperationReady=true` and an OPS_SAFE-context `eth_call` of E1's exact execute calldata to succeed. If the operation expires, stop and separately review recovery; do not requeue automatically.

## Files and operator boundary

| File under `artifacts/perps_v2_recovery_governance_execute/` | SHA-256 |
|---|---|
| `execute_transaction_abi.json` | `e4d847269787f526fbd4e6f0b706a18bfbf2d8cf5ffe49973c24a9e4223aedb4` |
| `g1_insurance_execute_safe_builder.json` | `6990ae6126f88b9fcc12d05a109ee1615d18163984e3d923fd16aa4d9b34a4a4` |
| `g1_insurance_execute_review_manifest.json` | `af21bd6ad880ffa356db061a38b5e0b598d8e372e5b712f15e6ddeda026873f6` |
| `g2_vault_execute_safe_builder.json` | `d1ba5f3891c8bae2da9f608b11f2ca4955bce530fd524419f7ea09863e84abbe` |
| `g2_vault_execute_review_manifest.json` | `d91b928fd780c410e14af91e28f0f67078892b9d05b2132b2142829a6b8b828b` |
| `preparation_readback.json` | `86afbff9896e8c499de0c48423e30cc877d6518e91e386eb3112b64a64a92ea7` |

The Safe Builder imports do **not** bind nonce, gas/refund fields, operation or SafeTx hash. The operator should construct/review **E1 only** first, inspect pending proposals in Safe, and compare the actual Safe interface/export fields against E1's review manifest. `SAFE_INTERFACE_COMPARISON=PENDING`. Do not collect signatures while the time gate is closed or any comparison/gate differs. If E1 is later operator-submitted, obtain its public transaction hash and independently verify the canonical receipt, Safe `ExecutionSuccess`, exact `TransactionExecuted`, permission readback and non-interference before refreshing E2 nonce/timing and reviewing E2. E2 is conditional and is not cleared for signature or execution by these files.

The separately queued target operations remain **unexecuted**. Maintenance remains active; shared pointers and FMV2 consumer status are unchanged; trading is **NOT AUTHORIZED**. The later OWNER-only FMV2/Risk/PME rebind is a different milestone. No deployer password file is needed for these Safe operations. Preparation used the read-only [`governance_execute_prepare.py`](../tools/perps_v2_cutover/governance_execute_prepare.py) helper and no broad build.
