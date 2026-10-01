# PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_FINISH

Status: **PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_COMPLETE** after the separately approved one-call Stage B. Stage A was read-only and did not unlock a keystore. The operator subsequently approved the exact continuation package SHA-256 below for one Base Sepolia write. The earlier four-call approval did not authorize the increased local fee allowance.

## Separately approved Stage B — final result

The continuation runner independently derived the keystore address as OWNER, verified the package hash and original ordinal-4 calldata, refreshed chain ID 84532, confirmed/pending OWNER nonce 811/811, the partial-lock flags, all 114 canonical economic/dependency checks and the scoped event history. It sent only the reviewed V1 call. The durable fresh fee decision was written before the send callback at block **47,528,932**, hash `0xbcc78defbfd521450b556d0e73bde474062885e5fd5f702c7d7f14a729543d63` (timestamp 1,790,826,152): the 512-byte oracle bound was **27,035,363,539 wei**, doubled to **54,070,727,078 wei**, below the fixed approved **66,749,085,998-wei** allowance. Observed gas estimate was **37,269**, within the approved 48,450 limit; max fee and priority caps remained 11,000,000 and 1,000,000 wei/gas. The reviewed total planning budget was **599,699,085,998 wei**, below the OWNER balance. Decision: `PASS / WITHIN_APPROVED_LIMITS`. The original PARTIAL report's historical trigger remains `UNKNOWN_NOT_RECORDED`.

**Only continuation transaction:** `0x3787c2b2b6a88e6688ff71eb6b01b4dddf4fee6b8014aa739c8e691818bf4a50`.

| Receipt field | Verified value |
|---|---|
| From / nonce | OWNER `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` / **811** |
| To / ETH value | V1_ENGINE `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` / **0** |
| Input | Exact approved `setEmergencyModes(true,true,true,true)` bytes shown below |
| Block / block hash | **47,528,958** / `0xed6b2baa63105fd5c472b7a3149e0afc801952e6dfff73bfb105076abab4bd4f` |
| Status / gas used | **1** / **36,905** |
| Effective gas price | **6,000,000 wei/gas** |
| Events | Exact `TradingPauseSet(true)`, `FundingPauseSet(true)`, `CollateralOpsPauseSet(true)`, `EmergencyModeUpdated(true,true,true,true)` |
| L2 execution / settled L1 fee | **221,430,000,000 / 5,835,777,308 wei** |
| OWNER expenditure | **227,265,777,308 wei**, equal to the two fee components |

The transaction, receipt and containing block have matching nonzero hashes. Receipt sender, target, nonce, zero value, calldata, gas limit and fee caps match the approved package. The four log emitters, topics and data match the expected V1 events. Receipt status is 1. The settled fee equals the OWNER balance decrease; the fee decision's allowance was a local planning gate, not the charged L1 fee.

At postflight comparison block **47,528,961**, hash `0xf4d4e3a61ccd69b655570aa98d115cf0917bd93ace8b9416c844b28079cd6fbc`, PME_V1 and PME_V2 remain paused; V1_ENGINE, OLD_ENGINE and NEW_ENGINE each read `[trading,liquidation,funding,collateralOps] = [true,true,true,true]`. All **114** canonical economic/dependency checks pass. Both V2 engines remain SEALED with the canonical snapshot hash; all positions, funding timestamps, OI, indexes, exposure, debt, clearing ledger, pointers, authorizations, PME domain and six trader nonces remain unchanged. The scoped scan finds exactly **15** pause events across the original three writes and this continuation, with no unexpected trade/configuration event. All **15 exact maintenance-error probes** pass via `eth_call` only; no negative probe was broadcast. Essential reads remain available.

OWNER confirmed/pending nonce moved **811 → 812**. This continuation contains exactly **one** public send and, together with the three preserved original receipts, the maintenance policy comprises exactly **four** approved OWNER writes. Safe nonce remains **15** and runtime-executor nonce remains **1**. The backend remains locally **STOPPED**. No rebind, Vault/Insurance/FMV2 authorization, governance action, token movement, migration, unpause, database operation or trade was performed by this continuation. The temporary mode-0600 password file was removed and verified absent; no claim of physical shredding is made.

Across the full maintenance milestone, OWNER balance moved from **1,706,833,527,156,533** to **1,705,631,017,782,088 wei**. The decrease, **1,202,509,374,445 wei**, equals the original three settled receipts' **975,243,597,137 wei** plus the continuation receipt's **227,265,777,308 wei**. No fifth transaction was submitted. A separate read-only postflight at block **47,529,107** again confirmed all 15 exact maintenance errors, all controls paused, nonce 812/812 and the locally stopped backend.

Machine-readable evidence: `artifacts/perps_v2_recovery_maintenance_lock_finish/fee_decision_broadcast.json`, `execution_journal.json`, `receipt.json`, `postflight.json` and `postflight_negative_probes.json`. The original successful-prefix journal, three receipts and PARTIAL report are preserved without edits. Insurance governance and signed-order inventory remain unresolved. This completed maintenance lock is **not** a rebind or trading authorization; do not resume either automatically.

The historical [PARTIAL maintenance report](PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1.md), the original four-step package SHA-256 `41ea29ebdbcde48dd43733d6f288bd819ad8274738bd008501d03c9d528b6697`, all three receipts, the successful-prefix journal and the BLOCKED rebind evidence remain unchanged. Pre-existing uncommitted work was inventoried; no reset or cleanup was used. The first unapproved continuation draft is retained in `artifacts/perps_v2_recovery_maintenance_lock_finish/*_draft_1.json`; the active reviewed package is `execution_package.json` in that same directory.

## Live checkpoint and scope

Solidity HEAD `fe5a7e4588504fdaf50db2ea940943c75442a8e7`; backend HEAD `ad8dd7466aeba6963d28687e825fe4df58ef32ee`, locally stopped. Chain ID 84532. Comparison block **47,528,512**, hash `0xae36eb48b4de74952ce0b3588411662795e95f4e7b02653e905bd74542fe26aa`, timestamp **1,790,825,312**. OWNER confirmed and pending nonce **811/811**, balance **1,705,858,283,559,396 wei**.

The three original writes at nonces 808–810 each still have status-1 receipts, exact OWNER/target/nonce/input, expected event topics/data, matching nonzero transaction/receipt/block hashes and inclusion in the referenced block. The original execution journal contains exactly three send invocations and no fourth record or receipt. An unconsumed confirmed/pending nonce 811 independently rules out a confirmed or pending OWNER transaction at that nonce. No transaction in this continuation has been submitted.

Live controls: PME_V2 paused; NEW_ENGINE and OLD_ENGINE each `[trading, liquidation, funding, collateralOps] = [true,true,true,true]`; PME_V1 paused; V1_ENGINE `[false,true,false,false]`. V1 is **not** fully paused. The 114 canonical economic/dependency checks pass, including all six position tuples, both market funding timestamps, OI, exposure/indexes, seed bookkeeping, residual debt, canonical V2 migration hashes, clearing ledger of 1,000,000,000 native mUSDC, shared pointers, authorizations and PME trader nonces. The scoped all-topic emitter scan since the original prebroadcast block found exactly the 11 expected pause events from the three known transactions. The backend remains locally stopped; this says nothing about independent external callers. In particular, V1 `updateFunding` stays callable until the remaining pause lands.

## Exact sole proposed transaction

| Field | Value |
|---|---|
| Network | Base Sepolia, chain ID 84532 |
| Sender | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| Nonce | **811**; expected post-nonce **812** |
| Target | V1_ENGINE `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` |
| ETH value | **0** |
| Function | `setEmergencyModes(bool,bool,bool,bool)` |
| Selector | `0xf64e345d` |
| Arguments | `true,true,true,true` in trading/liquidation/funding/collateral order |
| Expected controls | `[false,true,false,false] -> [true,true,true,true]` |
| Expected events | `TradingPauseSet(true)`, `FundingPauseSet(true)`, `CollateralOpsPauseSet(true)`, `EmergencyModeUpdated(true,true,true,true)` |
| Expected economic change | **none** |

Full calldata, unchanged from original approved ordinal 4:

```text
0xf64e345d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001
```

The deployed V1 runtime is not assumed identical to the current local V1 artifact. The artifact ABI confirms four booleans; the selector and four 32-byte ABI words decode independently to the call above. Live OWNER-context `eth_call` of those exact bytes returns successfully at the comparison block. The previous isolated-fork maintenance rehearsal exercised this same V1 call and verified four events and a pause-only storage effect. The current live V1 pre-state matches that rehearsal's V1 pre-state. The current `eth_call` is a read-only single-call simulation; it does not prove the future transaction is included or that fee quotes will remain unchanged.

## Fee method and reviewed envelope

The deployed OP GasPriceOracle predeploy is `0x420000000000000000000000000000000000000F`. Its `getL1FeeUpperBound(uint256)` argument is the **unsigned, fully RLP-encoded transaction size in bytes**. The [OP Stack implementation](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/GasPriceOracle.sol) adds 68 bytes internally for the missing signature and returns a wei fee bound. The proposed type-2 unsigned RLP transaction is **178 bytes**; the preflight still queries the conservative **512-byte** size. It does not add another 68 bytes. At the recorded block, the current 178-byte quote is **10,301,847,742 wei**, and the current 512-byte quote is **26,699,634,399 wei**. The older halted transaction's transient trigger remains **UNKNOWN_NOT_RECORDED**; later quotes cannot reconstruct it.

The prior allowance was `2 ×` its then-current 512-byte oracle bound. That 2× factor is a policy margin applied once on top of the oracle's own compression bound, not a unit conversion. The new proposal retains the 2× pre-send requirement and adds 25% quote-volatility headroom to the absolute local allowance: `ceil(2.5 × 26,699,634,399) = 66,749,085,998 wei`. This is a **local runner gate**, not an on-chain maximum L1 fee guarantee. Signed transaction fee fields remain separately capped. The oracle's `getOperatorFee(gas)` readback is zero at both estimated gas and proposed gas limit; the reviewed additional operator-fee allowance is zero, so any positive future quote stops the runner.

| Fee field | Original ordinal 4 | Proposed continuation |
|---|---:|---:|
| L2 gas estimate | 36,905 | **37,269** |
| Gas limit | 47,977 | **48,450** (about 30% above fresh estimate) |
| Max fee per gas | 11,000,000 wei | **unchanged** |
| Priority cap | 1,000,000 wei | **unchanged** |
| Local L1 allowance | 57,175,216,312 wei | **66,749,085,998 wei** |
| Additional operator-fee allowance | 0 wei | **0 wei**, live getter 0 |
| Total planning budget for this one call | 584,922,216,312 wei | **599,699,085,998 wei** |

The current L2 base fee is 5,000,000 wei/gas, suggested priority 1,000,000 wei/gas, and RPC gas price 6,000,000 wei/gas. Twice base fee plus suggested priority equals the unchanged 11,000,000-wei cap. The balance exceeds the reviewed budget. A 512-byte oracle quote changing within the fixed allowance does not invalidate it; a doubled quote above the allowance stops before send. Fee settlement will be taken from the actual receipt and OWNER balance, not from this planning budget.

The original runner's failure was an observability gap: its pre-step L1 check evaluated the quote in an assertion before persisting its input or result. No evidence establishes a unit bug. The new single-call runner writes a durable `fee_decision_broadcast.json` before its only send callback. The record includes block number/hash/timestamp, oracle method and 512-byte input, returned quote, multiplier, estimated gas, gas limit, fee caps, additional fee, allowance, budget, balance, exact comparison and PASS/STOP reason. A missing/malformed quote, cap drift, insufficient balance or write failure stops before invoking send. Focused unit tests cover below/equal/above allowance, missing/malformed quote, additional fee drift, network price drift and no-send on STOP/persistence failure: **8/8 passed**. No broad Forge or Cargo build ran; memory was checked before work.

## Stage-A approval boundary (historical)

Active separate package: `artifacts/perps_v2_recovery_maintenance_lock_finish/execution_package.json`.

**SHA-256 `cd4509be30e9fc9baf39a7606a523018ea667f6c93a685a46d870334adc29adb`**.

The full Stage-A machine-readable report is `artifacts/perps_v2_recovery_maintenance_lock_finish/stage_a.json`; the read-only fee decision is `fee_decision_preview.json`. The final nonce, runtime, economics, quote and package hash were refreshed in Stage B. The one-call runner has no resume path and sent only OWNER nonce 811 to V1_ENGINE with the approved calldata and zero value. It was **not executed in Stage A**.

The signed-order inventory and InsuranceFund governance path remain unresolved. This pause does not cancel signatures or authorize rebind, Vault, Safe, Timelock, backend or trading activity.
