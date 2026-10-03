# PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_QUEUE_V1

Status: **G2_QUEUE_VERIFIED; RECOVERY_GOVERNANCE_BOTH_OPERATIONS_QUEUED**. This report verifies two operator-submitted Base Sepolia Safe transactions. Verification was read-only on chain and database. No keystore, signature, transaction submission, Timelock execution, backend start or trade occurred during verification.

## Source and verification scope

The approved queue files remain exactly as committed in `d6e7dbb4ccf10bd7422c0e74f94d7e7c1dca135f`. The verifier compared both public Safe calls, including destination, value, CALL operation, complete Timelock calldata, Safe gas/refund fields and consumed Safe nonces, with the respective committed review manifests. It matched each public transaction and receipt to a nonzero canonical block hash and block transaction list, required receipt status 1, then required a Safe `ExecutionSuccess` event with the expected **SafeTx hash**. The SafeTx hash is distinct from the public transaction hash. The inner Timelock `TransactionQueued` events were decoded, and the operation IDs were recomputed with Ethereum Keccak-256 over `abi.encode(target, value, data, eta)` and cross-checked against live `hashOperation`.

Chain ID was **84532**. The two queue calls had Safe destination `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, value zero and operation `CALL(0)`. No `executeTransaction` call occurred in either receipt. The Safe nonce was 15 immediately before G1, 16 after G1 and immediately before G2, 17 after G2 and at comparison block 47,614,194. No additional Safe nonce progression was observed at that block.

| Evidence | G1 Insurance queue | G2 Vault queue |
|---|---|---|
| Public transaction | `0x7b68dfe378952e2eae86915e1ae908027293506397443de5ba01b8de9fb68eb9` | `0x4bab77791496f15524f9a5a5b602e6e8369bbc636bef6400e3cfd73b332c354e` |
| Consumed Safe nonce | 15 | 16 |
| SafeTx hash in `ExecutionSuccess` | `0x98871782d3c1ca79e9e85504aff45f2974044054c00dc791a1b49f85afa90a51` | `0xfbcdb5ab155b4756f76d7d5ba329dd776b6dbd7807d9461d97708c4ff8ddc68f` |
| Canonical block | 47,613,107 | 47,613,842 |
| Block hash | `0x2f88c9ab9dfe9e9a36a20bd1dee8fb5f6eb6ca4e40ecc6486b224359a4f6ae7c` | `0xbe0102ec2e274b7b7bd0ea12628196bd2cf95cd25e2755ddc31dbe75b674a40d` |
| Block timestamp UTC | 2026-10-03 02:28:22 | 2026-10-03 02:52:52 |
| Receipt / nested Safe result | status 1 / `ExecutionSuccess` | status 1 / `ExecutionSuccess` |
| Timelock event | `TransactionQueued` | `TransactionQueued` |
| Operation ID | `0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6` | `0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846` |
| Timelock target | InsuranceFund `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` | CollateralVault `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` |
| Inner call | `setBackstopCaller(0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15,true)` | `setAuthorizedEngine(0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15,true)` |
| Queued at receipt block and comparison block | true / true | true / true |
| Target permission at receipt and comparison block | false / false | false / false |

Both operation IDs are separate; neither reuses the consumed OLD_ENGINE authorization. The approved inner and outer calldata bytes match the actual event and Safe call, respectively. The two queue inclusions met the deployed `minDelay=86,400` seconds: G1 had 6,032 seconds and G2 had 4,562 seconds of inclusion margin before the deadline. The shared ETA is **1791086934 = 2026-10-04 04:08:54 UTC**. With `GRACE_PERIOD=1,209,600` seconds, the current contract's execution window is **2026-10-04 04:08:54 through 2026-10-18 04:08:54 UTC**. This is timing information, not execution authorization. Recheck queue status, governance authority, Safe nonce and contract semantics before any later execute proposal.

## Combined state and non-interference

At pinned comparison block **47,614,194**, hash `0xae037dea5f6bd7fb2959806acd9f38489fb2502b6cf786359ff159de11c0167d`, timestamp **2026-10-03 03:04:36 UTC**, both operation IDs were queued. NEW_ENGINE Insurance and Vault permissions were still **false**; FMV2 fee-consumer permission was also **false**. This confirms the target setters had not executed by that block. PME_V2 and Risk V2 still pointed to OLD_ENGINE. Both PME contracts were paused. V1, OLD_ENGINE and NEW_ENGINE each retained all four emergency flags true.

The existing pinned-state verifier passed **114** economic/dependency checks against the prior migration postflight, plus **14** seed flags, **6** position indexes and **6** PME_V2 trader nonces. Both V2 migration hashes remained canonical, positions, funding, OI and residual debt matched the prior verified state, and the clearing Vault ledger remained **1,000,000,000 native mUSDC**. A bounded all-topic scan of the listed protocol, Safe and Timelock emitters over blocks **47,612,564–47,614,194** found exactly the six Safe/Timelock logs belonging to G1/G2, with no scoped trade, rebind, unpause or target-setter event. This emitter-bounded check does not establish the absence of transactions from every external address. The backend was STOPPED under local process/port checks; that does not rule out external callers.

Machine-readable evidence: [`postflight.json`](../artifacts/perps_v2_recovery_governance_queue/postflight.json). Verification helper: [`governance_queue_postflight.py`](../tools/perps_v2_cutover/governance_queue_postflight.py). The original [governance preparation report](PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_PREPARE_V1.md) and approved Builder/review files were not changed. No database query or mutation was needed for this queue verification; the signed-order inventory remains **UNRESOLVED**.

## Remaining boundaries

G1 and G2 are **queued, not executed**. Insurance and Vault have **not** authorized NEW_ENGINE. The OWNER-only FMV2/Risk/PME rebind has **not** occurred. Maintenance pauses remain active; trading is **not authorized**. The unresolved signed-order inventory remains a separate pre-unpause blocker. No Timelock execute, rebind, permission grant, unpause, backend start or trade is included in this result, and nothing will execute automatically when the ETA arrives.
