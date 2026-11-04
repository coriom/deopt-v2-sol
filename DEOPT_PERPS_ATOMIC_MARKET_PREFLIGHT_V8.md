# DEOPT_PERPS_ATOMIC_MARKET_PREFLIGHT_V8

Read-only Base Sepolia review and **local Anvil fork only**, 2026-11-04 UTC. No public transaction, signature, Safe proposal or Timelock action was made. This is a technical rehearsal, not an authorization.

## Canonical snapshot and exact operations

Pinned block **54,323,530**, hash `0xd66e4f5e7d8901eb461af3d3d8acc7b2e4c91a61297c713a73b3246e337fb67d`, timestamp `2026-11-04T10:02:54Z`, chain ID **84532**. The block hash was read twice and matched. `https://sepolia.base.org` rate-limited some batched reads; those getters were retried individually at the same block. All results below are pinned to this block, not a promise about later state.

| Item | Pinned result |
| --- | --- |
| OPS Safe | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, version 1.4.1, threshold 2, nonce **43**; owners `0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d`, `0xa774C46C41064524dF895BD7bE9F294409798dFC`, `0xb9f8de807ff98d5730035a8bfed4bda33e886d06` |
| ProtocolTimelock | `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`; minDelay 86,400 s, grace 1,209,600 s; Safe is owner, guardian, authorized proposer and executor. Its deployed execution API is `executeTransaction(address,uint256,bytes,uint256)`, not `executeBatch`. |
| C02 | Operation `0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e` queued, ready, unexecuted; ETA 2026-10-25 12:00 UTC, last executable instant **2026-11-08 12:00 UTC inclusive**. Target D1 `0x6B3D846536116082dC4E7227861C341Bb85Ee963`, `createMarket` calldata selector `0xbdb9df9a`, 644 bytes. |
| MKT1_INACTIVE | Operation `0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268` queued, ready, unexecuted; ETA 2026-11-01 12:00 UTC, last executable instant **2026-11-15 12:00 UTC inclusive**. Same D1, `setMarketStatus(1,false,false)` selector `0x85477fb3`. |
| D1 / maintenance | D1 totalMarkets 0, market 1 absent, next ID 1, Timelock is owner and market creator, configuration and creation unpaused. D4 trading, liquidation, funding and collateral operations paused; D6 paused. D2 five PERP tiers maker 0/taker 200 ppm, recipient Timelock; D3 mUSDC enabled with 5 bps seizure spread. |

The test reconstructs both calldata values from the reviewed source-backed parameters and asserts **both queued operation IDs** against `ProtocolTimelock.hashOperation`. The C02 payload is `ETH-PERP`, the reviewed underlying/settlement/oracle, risk `(1000,750,500,10000000000,50000000000,true)`, liquidation `(5000,100,50,60)`, funding disabled. The MKT1 payload fixes market ID 1. Existing S1 receipts and runbooks remain the source of the public queue evidence; no new queue action was attempted.

## Atomic execution feasibility

Safe v1.4.1 `MultiSendCallOnly` at `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` has code hash `0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939` on the pinned fork, matching the [official Safe deployment artifact](https://github.com/safe-global/safe-deployments/blob/main/src/assets/v1.4.1/multi_send_call_only.json). A Safe `DELEGATECALL` to this library issues two ordered `CALL`s to the custom Timelock. Both `executeTransaction` calls therefore see `msg.sender=Safe`. A Safe `CALL` to MultiSendCallOnly would present the library address to Timelock and is not equivalent. The Timelock itself has no batch execution method. No on-chain predecessor field exists in its operation hash; the dependency is in the approved governance DAG.

The fork test uses only local `vm.prank` approvals from two known Safe owners. It exercises the **actual deployed Safe, MultiSendCallOnly, Timelock and D1 bytecode**. It is not proof of real owner signatures or operator approval. Conditional fork-only SafeTx hash at nonce 43: `0x5ceeb6b9b86f604f62991bc309b156ddba8258a4e767a2372562db5a3bdf03b9`. This is **not a broadcast transaction hash** and must not be reused without fresh nonce/state and independent review.

Success trace, in one local Safe execution:

1. `Safe.execTransaction(MultiSendCallOnly, operation=DELEGATECALL)`;
2. `Timelock.executeTransaction(D1,0,C02 calldata,C02 ETA)` → D1 `MarketCreated(1)` → `TransactionExecuted(C02 ID)`;
3. `Timelock.executeTransaction(D1,0,MKT1 calldata,MKT1 ETA)` → D1 `MarketStatusUpdated(1,false,false)` → `TransactionExecuted(MKT1 ID)`;
4. Safe success; market count 1, market 1 exists and is **INACTIVE**, both queue entries consumed, Safe nonce 44, D4/D6 maintenance unchanged.

Foundry reported 584,853 gas inside the fork-only Safe batch measurement (656,514 for the full test). This is a rehearsal measurement, not a final transaction gas limit. D1 `createMarket` always sets `isActive=true`; its validators and key derivation are internal pure functions, with no external call before returning to Timelock. The temporary ACTIVE storage value exists inside this transaction, but this specific D1 implementation exposes no external callback during creation. Logs are finalized only if the transaction succeeds. A separately submitted C02 transaction would leave an ACTIVE market between blocks and is a different risk.

Failure evidence: artificially pausing D1 configuration inside the fork lets C02 creation proceed while MKT1 status change fails. MultiSendCallOnly failure propagates to Safe `GS013`, which reverts **all** state including market creation, Timelock queue consumption and Safe nonce. Reversing the two subcalls fails without creating a market. Expired or locally cancelled C02 fails without creating a market. A separate local Safe call advances nonce to 44; approvals made for nonce 43 cannot execute the old batch. These are local fault injections, not public state changes.

Reproduce with `RPC_URL=http://127.0.0.1:8547 forge test --match-path test/perp/PerpsV2C02Mkt1AtomicFork.t.sol -vv` after starting an isolated Anvil fork pinned to block 54,323,530. Six tests passed on the fork; the successful call tree was also captured with `-vvvv`. No real transaction hash exists for a Foundry test.

## Governance policy and executor inventory

**Current DAG incompatibility:** `artifacts/perps_v2_replacement_deployment/mkt1_early_queue_policy_approval_v1.json` and `post_maintenance_dependency_dag_v3.json` retain `C02_S2_CANONICAL_POSTFLIGHT_PASS → MKT1_INACTIVE_S2_EXECUTION_ELIGIBLE`, separate authorization and canonical public postflight. A single batch cannot obtain a canonical postflight of C02 before its MKT1 call. Technical batch feasibility therefore **does not authorize** using these queued operations atomically. A new explicit governance policy decision and independent Safe transaction review would be needed. It must address the lost intermediate C02 postflight and define atomic postflight/recovery rules.

| Environment | Current evidence and status | Automatic Base Sepolia execution isolation |
| --- | --- | --- |
| Netcup/Coolify | 2026-11-04 10:16 UTC SSH: `deopt-v2-backen` process present; only DeOpt backup/watchdog systemd timers appeared in bounded service/timer check. V7 root Docker inspection found the read-only backend and PostgreSQL, with economic flags off. **VERIFIED_ACTIVE** for the read-only backend. | Known backend configuration: **VERIFIED_INACTIVE** for its broadcaster; separate unknown services elsewhere are not disproved by this check. |
| Vercel current production | Provider `get_project` and `get_deployment`: project `prj_YADz33AWNuLnbnXYvQZOINFIhTTG`, READY production deployment `dpl_5ryUVNmVQR8tmL5pGEDQJc5g1fwY`, source `f277f72254df52eb0974c4232fb1de03cd1adc9b`. Provider production environment names are only `DEOPT_BACKEND_HTTPS_ORIGIN` and `NEXT_PUBLIC_DEOPT_WALLET_READ_AUTH` (values not read). Current `src/app/api/deopt` routes implement read/auth forwarding; no server signer path found. **VERIFIED_ACTIVE** frontend gateway. | Current source has no automatic transaction path. Provider cron inventory was observed empty in V7, but no fresh complete Functions/Cron inventory for all historical deployments; older READY deployments remain **UNKNOWN** as potential distinct execution surfaces. Client-side faucet `walletClient.sendTransaction` is user-triggered, not an infrastructure broadcaster. |
| Railway historical project | Project `5d110969-6d5a-4f78-ab01-60dc3efd55e3`, environment `9fa9cad6-cb27-43ad-b4ed-c8af4e416365` from historical GitHub deployment references. No authenticated Railway CLI/connector available; historical failures are not current provider status. **UNKNOWN**. | **UNKNOWN**. |
| GitHub runners / other hosts | V7 repository review identified monitoring/build workflows, no confirmed economic runner. Current `gh` authentication is invalid, so provider-backed runner inventory was not refreshed. **UNKNOWN** for unlisted remote executors. | **UNKNOWN**. |

The minimum remaining provider evidence is a timestamped Railway project/environment **Services + Deployments** list (or deletion record), plus current Vercel Functions/Cron inventory and older deployment access/runtime status. Redact environment values and credentials. Until this is resolved, global remote execution isolation is **UNKNOWN**, even though the atomic path has no inter-transaction ACTIVE interval.

## Decision

| Strategy | Result |
| --- | --- |
| A: batch the two existing operations | **Technically PASS on fork, governance BLOCKED.** Requires a new explicit policy amendment, fresh public state, owner signatures and independent Safe review. Current DAG cannot be silently replaced. |
| B: let C02 expire and reprogram safely | **RECOMMENDED.** Do not execute C02 just to beat its deadline. Draft a replacement queue with an approved atomic C02→INACTIVE execution policy, or a reviewed single operation that reaches INACTIVE atomically. Recheck exact operation identity, ETA, expiry, market ID, gas, remote executor inventory and postflight before any later authorization. MKT1's existing queue entry must not be assumed reusable after replacement C02. |
| C: change creation mechanism | Potential future route only if governance cannot approve a safe atomic wrapper; requires contract design, review and deployment. Not needed for this technical feasibility result. |

`createMarket` cannot directly create an INACTIVE market in the currently deployed D1. A new operation that merely calls it once would still create ACTIVE. An atomic wrapper is technically possible through Safe MultiSend for these existing queued calls, subject to an explicit policy change. If the amended policy or executor isolation cannot be established in time, let C02 expire and prepare a replacement. Never schedule or execute MKT1 independently of a proven market-1 creation path.

**Next single operation:** commission an explicit governance decision for a replacement, atomic market-1 creation/deactivation policy after C02 expiry, while obtaining the exact Railway and Vercel provider inventories before any public execution authorization. No public-chain action is authorized by this report.
