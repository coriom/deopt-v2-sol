# DEOPT_C02_SAFE_REPLACEMENT_V9

**Scope:** Base Sepolia 84532, read-only canonical chain evidence and isolated Anvil fork. No public transaction, Safe signing, Timelock action or production modification. V9 artifacts are **UNAPPROVED_POLICY_NOT_OPERATOR_READY**. The V8 commit alone was pushed with explicit authorization; V9 remains local.

## Fresh canonical evidence

Pinned block **54,389,568**, hash `0x70fd3860be640620a167d6d84ad0a0ace054071953d9f734e5afabef909ff6f9`, timestamp **2026-11-04 13:43:02 UTC**. Public read-only RPC returned chainId 84532. Deployed `ProtocolTimelock` runtime code hash `0xb20f9fa764b46a832c7665f07c1b9c3cd6506a58f6885c0e12e88e9bbc55233c` exactly equals `forge inspect src/gouvernance/ProtocolTimelock.sol:ProtocolTimelock deployedBytecode | cast keccak`. D1 code hash `0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5` also exactly equals its local deployed bytecode. Thus the role and market semantics below are checked against the deployed code, not inferred from OpenZeppelin TimelockController.

| Read | Result at pinned block |
| --- | --- |
| Safe | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, threshold 2/3, nonce 43; three reviewed owners unchanged; modules `[]`, guard zero. |
| Timelock authority | Owner **Safe**, guardian **Safe**, pendingOwner zero, proposer(Safe)=true, executor(Safe)=true, executor(address(0))=false, proposer(address(0))=false, executor(old deployer `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`)=false, executor(runtime `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8`)=false. minDelay 86,400 seconds; queue not paused. |
| Operations | C02 `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e` and MKT1 `0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268` both queued and ready, unexecuted. C02 expires **2026-11-08 12:00:00 UTC inclusive**, MKT1 **2026-11-15 12:00:00 UTC inclusive**. Timelock rejects execution only when `block.timestamp > eta + 14 days`; cancellation is available while queued. |
| D1 and maintenance | totalMarkets 0, market 1 absent; D1 owner Timelock, guardian zero, Timelock market creator true, deployment signer market creator false, creation/config not paused. D4 four emergency flags true; D6 paused true. |

Custom Timelock `onlyExecutor` checks `executors[msg.sender]` exactly. `setExecutor` and `setExecutors` reject zero address; there is **no open executor role**. `cancelTransaction` requires `msg.sender == guardian || msg.sender == owner`, both currently the Safe. Blockscout's indexed `ExecutorSet` history has three events and no next page: initial deployer=true at block 40,856,177 (`0xaab103bc…40fae0`), Safe=true at 42,572,343 (`0x2fb062a0…f4bcec`), deployer=false at 42,578,781 (`0x00041e1f…b74a98`). Each event was independently retrieved from its exact block through public RPC, and current mappings agree. Mapping enumeration is not native to Solidity, so the event-index completeness is an evidence limit; no other executor was observed. The Safe Transaction Service returned only two unexecuted proposals at stale nonces **10 and 11**, none at current nonce 43. This does not rule out privately held off-service Safe signatures.

**C02_EXECUTOR_PERMISSIONS = SAFE 2/3 ONLY among verified roles. LIVE_C02_EXECUTION_RISK = NO independent third-party executor observed; YES if a valid Safe transaction is separately authorized or already signed outside the checked service.** A relayer, Railway worker or Vercel Function with an RPC key alone cannot call `executeTransaction` successfully. The fork rejects both an unrelated address and the revoked deployer. The Safe has no module/guard route that bypasses the observed 2/3 signature threshold. Never interpret this as permission to submit C02 by itself.

D1 `createMarket` always writes `isActive=true`. The only reviewed direct setter `setMarketStatus` requires D1 owner Timelock. MKT1 alone reaches D1 before market 1 exists and reverts; the fork confirms it remains queued. Another D1 creator could create a market only if Timelock had separately authorized that creator; no such current grant was found in the indexed logs, but an allowlist mapping is not enumerable. The reviewed deployment constructor granted market creation to Timelock; current getter confirms it. The old deployment signer getter is false.

## Cancellation and replacement design

**C02_CANCELLATION_FEASIBILITY = PASS, not executed.** Safe may call custom `cancelTransaction(D1,0,exact C02 calldata,1792929600)` immediately, without Timelock delay. The [one-action unsigned Safe Builder candidate](artifacts/perps_v2_replacement_deployment/c02_cancel_v9_unsigned_builder.json) has SHA-256 `899747fa454bf11e0bfa67a3d9284cd697cabaa07f67553607b4583b0fcf20f2`. The [conditional package](artifacts/perps_v2_replacement_deployment/c02_atomic_replacement_v9_conditional.json) includes exact calldata and Keccak hashes for old C02/MKT1 cancellation, two new queue operations, and the atomic execution envelope. Its SHA-256 is `2c0a1729daac520fe4b6708e73357a686bbdc665595cf9c2fb6c8131c46f1f02`. These are offline bytes, **not** signed or operator-ready. The [derivation script](tools/perps_v2_cutover/derive_atomic_replacement_v9.py) checks both old operation identities before generating anything.

Recommended design **B**: separately authorize and canonically verify cancellation of both old queued operations; schedule two new exact D1 operations through the Safe and custom Timelock; wait the mandatory delay; execute the new C02 then new MKT1 inside **one** Safe `DELEGATECALL` to canonical MultiSendCallOnly. Its two inner Timelock calls are zero-value `CALL`s. The Safe 2/3 approval, execution payload, current nonce and gas must be reviewed afresh. No previous C02/MKT1 authorization is reused. If either inner action fails, MultiSendCallOnly and Safe revert the whole transaction, leaving market absent and both new operations queued. D1 creation has no external callback between ACTIVE assignment and return to Timelock; the ACTIVE intermediate storage value cannot persist between transactions in this design. D4/D6 pauses stay mandatory.

Approach **A**, a single new Timelock `executeBatch`, is **unavailable**: the deployed custom Timelock has no such method. A new wrapper contract would need new authority to call D1's owner-only status setter and would enlarge deployment and governance scope. Approach **C**, changing D1 to create inactive directly, requires a new contract/deployment; the deployed bytecode cannot do it. B reuses deployed contracts with the smallest on-chain change surface, but **requires an explicit DAG policy amendment**. The unapproved [DAG proposal](artifacts/perps_v2_replacement_deployment/c02_atomic_replacement_v9_dag_proposal.json) leaves the approved v3 DAG intact. It replaces the separate `C02_S2_CANONICAL_POSTFLIGHT_PASS → MKT1_S2` edge **only for a new replacement pair** with one atomic execution gate and a postflight proving both Timelock execution events and final market 1 INACTIVE. Existing downstream gates must depend on that combined postflight. Separate public authorizations remain required for cancellation, each scheduling action and the atomic execution. Execution of either new operation alone is forbidden by the proposed policy.

Conditional candidate ETA **2026-11-10 12:00 UTC**; it is valid only if each new queue call lands by **2026-11-09 12:00 UTC** at the absolute minimum delay, with an operator-chosen margin. New operation expiry would be **2026-11-24 12:00 UTC inclusive**. IDs:

- new C02: `0x0f743aa9d987ecf894342087c1a8d6d84a192fde779454ae1ad57a26b5db994f`;
- new MKT1: `0x57cbad9d63febe3b7b00b447ddbd989ada51f6a2c25f0a506eea2f22585b5c12`.

These IDs depend on the conditional ETA and **must be regenerated if timing changes**. Fork-only Safe hashes for the five actions at successive assumed nonces 43–47 are:

| Action | Assumed nonce | Conditional SafeTx hash |
| --- | ---: | --- |
| Cancel old C02 | 43 | `0x6156d45aa0f0471672a502491284d6497944bad7717370ffac269a8ee8b35ce6` |
| Cancel old MKT1 | 44 | `0x45c932b08b29fd2e929115a317f8ca743c40fd4a35ca981affee2663f60e451c` |
| Queue new C02 | 45 | `0xb7a730403fcd56c1c7976d5b17dd2883496faeb9a9870c6c8bef358e9aebf98a` |
| Queue new MKT1 | 46 | `0xed574e09db8de4c4fd53aa9c003fec6725d27249d656179af1d4802a9835e970` |
| Execute atomic batch | 47 | `0xf0c26d93dd894d0291136f4188b1e1374d3d634c7d10bbef0f081948d718c803` |

They are neither signatures nor reusable authorizations. Any intervening Safe transaction changes the nonce and invalidates this sequence.

## Fork evidence

Anvil was forked at the same block and hash. `test/perp/PerpsV2AtomicReplacementFork.t.sol` uses **fork-only owner impersonation** to execute four separate Safe actions: cancel old C02, cancel old MKT1, queue new C02, queue new MKT1. After the delay it executes the exact MultiSendCallOnly batch. The trace shows:

`Safe cancel old C02 → Safe cancel old MKT1 → Safe queue new C02 → Safe queue new MKT1 → Safe.delegatecall(MultiSendCallOnly) → Timelock.execute(new C02) → D1.MarketCreated(1) → Timelock.execute(new MKT1) → D1.MarketStatusUpdated(1,false,false)`.

**FORK_SIMULATION = PASS (6/6)**. Final market count 1, market 1 exists and is **INACTIVE**, old and new queue entries consumed as intended, Safe nonce 43→48 in this artificial sequence, D4/D6 pauses and sampled D2/D3 settings unchanged. The batch measurement is 539,217 fork gas, not a final gas limit. MKT1 alone, unrelated executor/canceller, premature batch, failing second step, and stale Safe approval all fail closed. The failing second step reverts the first market creation, both new queue entries remain, and the Safe nonce does not advance. No public transaction hash exists for the fork rehearsal.

Reproduce with `anvil --fork-url https://sepolia.base.org --fork-block-number 54389568 --chain-id 84532 --port 8547 --host 127.0.0.1`, then `RPC_URL=http://127.0.0.1:8547 forge test --match-path test/perp/PerpsV2AtomicReplacementFork.t.sol -vv`. The fork's block hash must equal the pinned hash above. Script and package validation: run `python3 tools/perps_v2_cutover/derive_atomic_replacement_v9.py --out /tmp/v9-package.json --cancel-builder /tmp/v9-cancel.json` and byte-compare the outputs to the committed candidates.

## Remote executor risk and decision

Vercel provider inventory on 2026-11-04: current production deployment `dpl_5ryUVNmVQR8tmL5pGEDQJc5g1fwY` is READY. Eight production deployments are listed. The current production environment exposes only the *names* `DEOPT_BACKEND_HTTPS_ORIGIN` and `NEXT_PUBLIC_DEOPT_WALLET_READ_AUTH`; no value was read. Source at all seven distinct deployed commits contains zero server API routes matching private-key, transaction broadcast or contract-write patterns and no `vercel.json` cron config. Current Vercel gateway is active, but an old deployment's exact environment and provider Functions inventory remain bounded unknowns. Railway historical project `5d110969-6d5a-4f78-ab01-60dc3efd55e3`, environment `9fa9cad6-cb27-43ad-b4ed-c8af4e416365`, remains **UNKNOWN** because no authenticated Railway connector is available. Netcup's read-only backend and disabled economic flags were verified in V7; this milestone did not modify it. Such services could matter for future trading, but they cannot execute **this Timelock C02** without either an executor grant or valid Safe 2/3 authorization. Provider inventories remain necessary before any broader economic release; they do not create an open Timelock role.

**Decision:** no emergency cancellation request based on a nonexistent public executor. Prepare the new atomic replacement under a **new, explicit policy decision**, then separately review and authorize each Safe action. The old C02 must never be executed alone. The policy and package remain unapproved; no C02 cancellation, queue action or market creation is authorized by this report.

**NEXT_ACTION:** operator governance reviewer decides whether to approve the scoped V9 DAG amendment and cancellation/requeue design. Public Safe actions require a later, separate transaction-specific authorization after fresh nonce, code, queue, expiry, maintenance and Safe UI checks.
