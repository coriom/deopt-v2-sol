# DEOPT_ATOMIC_GOVERNANCE_V10_APPROVED

**POLICY_APPROVAL = APPROVED for the Base Sepolia 84532 beta only.** The operator explicitly accepts that a valid Safe 2/3 can still execute a Timelock operation alone; the ban on doing so is an off-chain governance rule. This does not approve a mainnet architecture or authorize a Safe proposal, signature, queue action, cancellation, execution, trading release, or public transaction.

The [machine-readable approval](artifacts/perps_v2_replacement_deployment/c02_atomic_governance_v10_policy_approval.json) binds this decision to review commit `52d33c91bef21cbc7e030e00502be4da6f99b7df`, the exact [V10 DAG amendment](artifacts/perps_v2_replacement_deployment/c02_atomic_governance_v10_dag_proposal.json), and the [conditional calldata package](artifacts/perps_v2_replacement_deployment/c02_atomic_governance_v10_conditional.json) by SHA-256. Their historical `UNAPPROVED` labels describe the state when those files were authored; this separate approval supersedes the **policy** label only. The calldata package remains conditional and **not operator-ready** until fresh chain checks and a separate action-specific authorization. The approved v3 DAG file is preserved; this approval supplies a narrowly scoped replacement edge for the new pair only. Old C02/MKT1 approvals do not transfer.

## Current read-only checkpoint

At Base Sepolia block **54,403,895**, hash `0x7ee724affcb7ce65230375a3b230b40691ea339589694ab81b652cd2b0035882`, timestamp **2026-11-04 14:30:47 UTC**: old C02 and MKT1 are queued, Safe nonce 43 and threshold 2, D1 market count 0, D4 four flags true, D6 paused. Timelock owner/guardian and observed proposer/executor are the Safe, minDelay 86,400 seconds, queue unpaused; zero address is not an executor. **OLD_C02_STATUS = QUEUED, READY, UNEXECUTED, NOT EXPIRED at this checkpoint.** Its last executable timestamp is **2026-11-08 12:00:00 UTC inclusive**. No use of this checkpoint as a future transaction preflight is permitted.

## Exact post-expiry route and stop conditions

1. **Wait for canonical chain time later than 2026-11-08 12:00:00 UTC.** No old C02/MKT1 execution or cancellation is authorized. After that time, read a fresh pinned Base Sepolia block. Require chain ID 84532, old C02 still queued but `isOperationReady=false` because stale, D1 total markets 0 and next market ID 1, Safe owners/threshold/modules/guard and nonce reviewed anew, Timelock code/roles/delay unchanged, D4/D6 maintenance and risk/fee/oracle non-drift. If C02 was executed, market 1 exists, the queue status differs, any role changed, or any read is inconclusive: **STOP**. Never infer expiration merely from the local clock.
2. **First future Safe action: replacement C02 S1 queue**, target Timelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, value 0, operation CALL, exact `queueTransaction(D1,0,createMarket calldata,ETA)` from the conditional package. With the current conditional ETA **2026-11-12 12:00 UTC**, the expected new operation ID is `0xfa6cafb57e8bf8e19d1af04e22f2d9044510f24e70032f4b3b3a6ac705bff401`. A **new, separate operator authorization** and genuine Safe 2/3 confirmations are required. Do not submit from this runbook. Canonical postflight must prove Safe `ExecutionSuccess`, exact Timelock `TransactionQueued`, operation ID/ETA, queued state, Safe nonce advancement, market still absent and maintenance/economics unchanged. If any item fails: **STOP**.
3. **Second future Safe action: replacement MKT1 S1 queue**, only after the first canonical postflight. Separate authorization and Safe 2/3 confirmations; target the same Timelock, value 0, operation CALL, exact `setMarketStatus(1,false,false)` queue payload from the package. Conditional operation ID `0x1e0e7c2093a019133fa0c903005f866d34be6444a6c65d170b140ebf136dda51`. Verify a separate canonical queue postflight; market must still be absent. If not: **STOP**.
4. **Wait until both new operations are ready and unexpired.** Before S2, independently verify the existing remote-executor isolation prerequisite, D4/D6 and all v3 economic guards, current Safe nonce and exact two-call payload. Obtain a **third, separate authorization**. One Safe `DELEGATECALL` to canonical MultiSendCallOnly must contain exactly two zero-value `CALL`s to Timelock: execute new C02, then new MKT1. No third call or automatic chaining. A failed second call must revert the entire transaction. Canonical postflight must show one Safe success receipt, both Timelock execution events in order, market 1 created and then set INACTIVE, both new queue entries consumed, and no economic/maintenance drift. Otherwise halt downstream governance and reconcile chain state before any retry.

The conditional queue window opens **2026-11-08 12:00:01 UTC**. For the proposed ETA, queue both by **2026-11-11 00:00 UTC** to retain a 12-hour margin over the absolute minDelay cutoff. If the window narrows, regenerate ETA, IDs, calldata and hashes from the reviewed derivation script, then obtain fresh action-specific approval. Never reuse historical nonce 43, SafeTx hashes, signatures or previous operator approvals. Old MKT1 remains a legacy queued operation until its own expiry on **2026-11-15 12:00 UTC inclusive**; do not execute it.

### Minimal read-only preflight after expiry

From the protocol repository, the following commands **read only** the public Base Sepolia RPC. They are a first gate, not a complete authorization or Safe UI review. The block number is pinned for the subsequent calls; record its hash and timestamp with the results.

```bash
set -euo pipefail
cd /home/corio/DEOPT/deopt-v2-sol
rpc=https://sepolia.base.org
tl=0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588
d1=0x6B3D846536116082dC4E7227861C341Bb85Ee963
safe=0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46
old_c02=0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e
pkg=artifacts/perps_v2_replacement_deployment/c02_atomic_governance_v10_conditional.json
printf '%s  %s\n' 40bf7c13bfe839e23bd8a257a045969ad8de56f58c53a0be56c9049eca79937f "$pkg" | sha256sum -c -
test "$(cast chain-id --rpc-url "$rpc")" = 84532
block=$(cast block latest --field number --rpc-url "$rpc")
timestamp=$(cast block "$block" --field timestamp --rpc-url "$rpc")
block_hash=$(cast block "$block" --field hash --rpc-url "$rpc")
test "$timestamp" -gt 1794139200
c02_data=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["separatelyAuthorizedSafeActions"][0]["innerCalldata"])' "$pkg")
test "$(cast call "$tl" 'queuedTransactions(bytes32)(bool)' "$old_c02" --block "$block" --rpc-url "$rpc")" = true
test "$(cast call "$tl" 'isOperationReady(address,uint256,bytes,uint256)(bool)' "$d1" 0 "$c02_data" 1792929600 --block "$block" --rpc-url "$rpc")" = false
test "$(cast call "$d1" 'totalMarkets()(uint256)' --block "$block" --rpc-url "$rpc")" = 0
test "$(cast call "$d1" 'nextMarketId()(uint256)' --block "$block" --rpc-url "$rpc")" = 1
test "$(cast call "$tl" 'minDelay()(uint256)' --block "$block" --rpc-url "$rpc")" = 86400
test "$(cast call "$tl" 'executors(address)(bool)' "$safe" --block "$block" --rpc-url "$rpc")" = true
test "$(cast call "$tl" 'executors(address)(bool)' 0x0000000000000000000000000000000000000000 --block "$block" --rpc-url "$rpc")" = false
test "$(cast call "$tl" 'queuedTransactions(bytes32)(bool)' 0xfa6cafb57e8bf8e19d1af04e22f2d9044510f24e70032f4b3b3a6ac705bff401 --block "$block" --rpc-url "$rpc")" = false
test "$(cast call "$tl" 'queuedTransactions(bytes32)(bool)' 0x1e0e7c2093a019133fa0c903005f866d34be6444a6c65d170b140ebf136dda51 --block "$block" --rpc-url "$rpc")" = false
printf 'C02_EXPIRY_MINIMAL_PREFLIGHT=PASS BLOCK=%s HASH=%s TIMESTAMP=%s\n' "$block" "$block_hash" "$timestamp"
```

**Stop even after this PASS** until the remaining Safe authority, D4/D6, code-hash, market/economic and operator authorization checks above are independently completed. This preflight has no `cast send`, signer or broadcast path.

## Delivery boundary

The only test-path adjustment in this milestone is that the fork suite skips itself when `RPC_URL` is absent in CI; with a fork RPC provided, **12/12 tests passed again**. The no-RPC path reports one skipped suite and no failure. The targeted file passes `forge fmt --check`. Repository-wide `forge fmt --check` still fails on preexisting formatting in `src/matching/PerpMatchingEngineV2.sol`; this milestone does not change that contract. GitHub push workflows were inspected: they run Foundry CI and contain no deploy or blockchain submission job. Their global formatting gate may therefore remain red for this unrelated baseline issue.

**NEXT_ACTION:** after C02 expiry, run the read-only preflight and obtain a separate operator decision on **replacement C02 S1 only**, using fresh state and a newly reviewed Safe nonce. No Safe proposal or signature is requested now.
