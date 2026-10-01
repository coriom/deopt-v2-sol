# PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_PREPARE_V1

Status: **governance queue preparation READY_FOR_OPERATOR_REVIEW; signed-order inventory UNRESOLVED; trading readiness BLOCKED**. This milestone prepared two independent queue files and performed read-only investigation. No Safe proposal, signature, Timelock queue/execute, keystore unlock, public-chain send, backend start, or database write occurred. The completed maintenance lock remains active; historical PARTIAL maintenance and BLOCKED rebind reports retain their original outcomes.

## Checkpoint and non-interference

- Solidity HEAD `1b8aa78fceb6dae229b4a95e14e7938899ff6280`; backend HEAD `ad8dd7466aeba6963d28687e825fe4df58ef32ee`; both clean at entry. Production Solidity, backend source, canonical migration artifacts and historical reports were not edited.
- Base Sepolia chain ID **84532**; comparison block **47529723**, hash `0x7746b84f4314e2e1e54c80e308a0386e76243e9e9f378590168ef522ccefd03a`, timestamp **2026-10-01T04:08:54+00:00**. This is the fixed reference for both ETAs.
- The existing verifier passed **114** economic/dependency comparisons plus **14** seed flags, **6** position indexes and all six PME trader nonces. NEW_ENGINE runtime equals the frozen 24,321-byte artifact, Ethereum Keccak-256 `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`. Both V2 Engines remain SEALED with `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`; all six positions, both markets (including market 2 funding timestamp), OI, indexes, exposures and residual debt match the migration report. Clearing remains 1,000,000,000 native mUSDC.
- PME_V1 and PME_V2 are paused. V1, OLD and NEW Engines each have trading, liquidation, funding and collateral-operations pause flags true. PME_V2 and RISK_V2 still point to OLD_ENGINE. NEW_ENGINE Vault, FMV2 and Insurance permissions are false. V1/OLD Vault permissions remain true.
- Scoped all-topic log scan from block **47529108** through **47529723** over the recorded protocol emitters, Timelock and Safe found **0 events**. It is a bounded emitter scan, not a proof that no external address sent a transaction.
- OWNER confirmed/pending EOA nonce **812/812**; runtime executor **1/1**; Safe on-chain nonce **15**. Backend STOPPED by local /proc executable/comm and port 8080 checks only. Docker status showed monitoring containers and no DeOpt backend/PostgreSQL container; local PostgreSQL still listens on 127.0.0.1:5432. This does not rule out external callers.

## Live authority and setter semantics

| Contract | Live owner | Relevant authority/effect |
|---|---|---|
| INSURANCE | `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588` | onlyOwner setBackstopCaller; mapping and BackstopCallerSet only |
| VAULT | `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588` | onlyOwner setAuthorizedEngine; mapping plus authorized-engine list if first authorization, then AuthorizedEngineSet |
| FMV2 | `0xc35f7a8a103a9a4464adfaa76b9b514093d23c27` | OWNER-only future fee consumer call; no call now |
| RISK_V2 | `0xc35f7a8a103a9a4464adfaa76b9b514093d23c27` | OWNER-only future engine pointer call; no call now |
| PME_V2 | `0xc35f7a8a103a9a4464adfaa76b9b514093d23c27` | OWNER-only future engine pointer call; no call now |

Timelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` is owned and guarded by OPS_SAFE. OPS_SAFE is both proposer and executor; OWNER EOA is neither proposer nor executor at the pinned block. `minDelay=86400` seconds, `GRACE_PERIOD=1209600` seconds; queuePaused=false. Its live runtime matches the committed ProtocolTimelock artifact. `queueTransaction` checks proposer/queue pause/ETA, sets only `queuedTransactions[operationId]`, and emits TransactionQueued; target setters are not called until a separate future `executeTransaction`. Two separate Safe CALLs are required; there is no reviewed batch or MultiSend. OPS_SAFE `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` has threshold **2/3**, owners ``0xb9f8de807ff98d5730035a8bfed4bda33e886d06`, `0x0e7dcb5b9fd969e4fdc6f3a7b7993819ddc5a35d`, `0xa774c46c41064524df895bd7be9f294409798dfc`, and **0** enabled modules at the comparison block. Safe on-chain nonce **15**; pending proposal inspection was inaccessible: the attempted public transaction-service GET returned HTTP 404 and client-gateway GET returned HTTP 403. No conclusion about off-chain pending proposals is made. Refresh nonce and pending proposals before any future signature.

## Independent G1/G2 QUEUE review

Both operations use Timelock `queueTransaction(address target,uint256 value,bytes data,uint256 eta)` with selector `0x8e361cdf`, ETH value 0 and operation ID `keccak256(abi.encode(target,0,data,eta))`. Local Ethereum Keccak IDs exactly equal live `hashOperation` reads. Both `queuedTransactions(id)` values were false. OWNER cannot directly execute the target setters; TIMELOCK-context target `eth_call` succeeded. OPS_SAFE-context queue `eth_call` succeeded. These calls discarded state and do not prove later Safe execution.

Reference timestamp is **2026-10-01T04:08:54+00:00**. The shared proposed ETA is **2026-10-04T04:08:54+00:00** (`1791086934`), computed as timestamp + max(72h, minDelay+48h) = +72h. Latest inclusion deadline for either queue is **2026-10-03T04:08:54+00:00**; a signature or submission before that deadline is insufficient unless its queue transaction is included. Future execution window is **2026-10-04T04:08:54+00:00 through 2026-10-18T04:08:54+00:00** inclusive. If a Safe transaction cannot be included before the deadline, regenerate the ETA/ID/payload under a new review; do not edit an approved file in place.

| Item | G1 Insurance | G2 Vault |
|---|---|---|
| Safe nonce for review | 15 | 16 |
| Safe destination/operation/value | TIMELOCK / CALL(0) / 0 | TIMELOCK / CALL(0) / 0 |
| Timelock target | `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` | `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` |
| Inner selector | `0x0f62e507` | `0x3331c56e` |
| Decoded inner call | `setBackstopCaller(NEW_ENGINE,true)` | `setAuthorizedEngine(NEW_ENGINE,true)` |
| Operation ID | `0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6` | `0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846` |
| Current queued state | false | false |
| Expected immediate effect of queue | pending Timelock record only | pending Timelock record only |
| Future execute effect | NEW_ENGINE backstop mapping true | NEW_ENGINE Vault mapping true; list entry if new |

**G1_INSURANCE inner calldata**

```text
0x0f62e507000000000000000000000000a2bdc0efe80806ffda20189294dd8a5a1b426f150000000000000000000000000000000000000000000000000000000000000001
```

**G1_INSURANCE outer queue calldata**

```text
0x8e361cdf000000000000000000000000009f38440f058d095b61e0e2ee7fabdf05be750000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000006ac1d15600000000000000000000000000000000000000000000000000000000000000440f62e507000000000000000000000000a2bdc0efe80806ffda20189294dd8a5a1b426f15000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000
```

**G2_VAULT inner calldata**

```text
0x3331c56e000000000000000000000000a2bdc0efe80806ffda20189294dd8a5a1b426f150000000000000000000000000000000000000000000000000000000000000001
```

**G2_VAULT outer queue calldata**

```text
0x8e361cdf00000000000000000000000000340c360353a5ab784c5bc5c44322a6af0625d300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000006ac1d15600000000000000000000000000000000000000000000000000000000000000443331c56e000000000000000000000000a2bdc0efe80806ffda20189294dd8a5a1b426f15000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000
```

The ABI is [`queue_transaction_abi.json`](../artifacts/perps_v2_recovery_governance_prepare/queue_transaction_abi.json). Each operation has one independently importable Safe Transaction Builder file and a separate review manifest binding Safe nonce, CALL, target, calldata, and zero safeTxGas/baseGas/gasPrice/gasToken/refundReceiver fields:

- G1: [`g1_insurance_safe_builder.json`](../artifacts/perps_v2_recovery_governance_prepare/g1_insurance_safe_builder.json) and [`g1_insurance_safe_review_manifest.json`](../artifacts/perps_v2_recovery_governance_prepare/g1_insurance_safe_review_manifest.json).
- G2: [`g2_vault_safe_builder.json`](../artifacts/perps_v2_recovery_governance_prepare/g2_vault_safe_builder.json) and [`g2_vault_safe_review_manifest.json`](../artifacts/perps_v2_recovery_governance_prepare/g2_vault_safe_review_manifest.json).

Transaction Builder import does **not** lock Safe nonce, gas or refund fields. Compare the actual constructed Safe transaction, including nonce, operation and full calldata, before computing/checking any SafeTx hash or collecting signatures. No SafeTx hash or signature is asserted here. The future `executeTransaction` arguments are isolated in [`future_execute_args_NOT_AUTHORIZED.json`](../artifacts/perps_v2_recovery_governance_prepare/future_execute_args_NOT_AUTHORIZED.json); that file is **planning only**, not a queue import or execution approval. The consumed OLD_ENGINE Vault operation is not reused.

## Bounded signed-order inventory

The previously absent database named by `.env.perps_closed_test_prepare_only.local` is now reachable on loopback. We used its existing credentials in process only and forced PostgreSQL `default_transaction_read_only=on`, a 5-second statement timeout and bounded SELECTs. No signature bytes, raw signed transaction or connection string was selected or printed. This is one local database, not an exhaustive survey of all stores. The same DB contains a V1 confirmed hash with a matching Base Sepolia receipt at block 46,973,629, so it contains at least some real operational history as well as fixture-like rows.

The queried V2 slice has **14** intents and **13** rows with both signature fields populated. Lifecycle: 8 confirmed, 4 simulation_ok, 1 simulation_failed, 1 pending. There are **11** V2 broadcast rows (8 claimed confirmed and 3 prepared). None targets the reused PME_V2. All 11 claimed hashes lack a Base Sepolia transaction/receipt and all 11 targets have no deployed code. The three prepared targets equal the backend test constant `PME_V2_ADDR` in `tests/perps_broadcast_durability_pg_integration.rs`; chain ID 84532 alone was not used as provenance proof. The table lacks a verifyingContract field; five signature-bearing V2 intents have no broadcast target. Their signer/domain provenance remains unknown. A record marked confirmed is not accepted as chain-confirmed without a matching canonical receipt.

The current prepare-only config points to V1 PME and has real broadcast false. Other `.env` backups carry the same database identity per the historical inventory; the current backend `.env` is absent. Docker shows no PostgreSQL container and the bounded project backup-name inventory found no dump. Safe and external operational stores were not exhaustively inspected. A reachable mixed-use DB does **not** prove that no same-domain PME_V2 signatures exist elsewhere. Inventory verdict: **UNRESOLVED**. [Metadata and chain cross-checks](../artifacts/perps_v2_recovery_governance_prepare/signed_order_inventory.json). The missing authoritative all-store provenance and any live unexpired order assessment remain blockers before unpause/trading, not before queue review.

## Dependency-aware continuation

1. G1 and G2 may be independently queued by the 2-of-3 OPS Safe during the same review window, then their 1-day minimum delays run concurrently. Each queue and each later execute must have its own fresh nonce, operation ID, status and receipt checks. No queue or execute is approved in this report.
2. The OWNER-only FMV2 consumer and Risk/PME pointer calls remain a separate rebind package; PME should switch last after prerequisites. Insurance is Timelock-owned and cannot be folded into an all-OWNER plan. The OLD Engine still shares Risk and retains historical permissions; assess residual authority before switching.
3. Complete a provenance-aware signed-order inventory for the reused PME_V2 domain, trader nonces, deadlines, fill state and prepared broadcasts. Any cancellation/invalidation needs a separate authorization. Legacy trade deadline 0 means no expiry; order intents use their own deadline and first-fill nonce/fill rules. Maintenance pauses do not cancel signatures.
4. Even after G1/G2 execution, maintain the pause policy. A future selective unpause must account for `applyTrade` internally invoking `updateFunding`; leaving fundingPaused true causes a trade revert. Review only required pause changes and first controlled trade separately. Do not silently clear all flags. V1/OLD retirement and permission revocations remain separate future decisions.

## File integrity and scope

| File | SHA-256 |
|---|---|
| `readback_and_operations.json` | `3002fac329cf2a55100756acf7156112ddc1c0efe710cc8d8e9234fe40281816` |
| `queue_transaction_abi.json` | `1bf38b88ad150f3bf8535caf62cccfff576b4455b9cdd917b8b26797bbf97570` |
| `g1_insurance_safe_builder.json` | `2985d63b97aa9c6a4018d1cf9cddb38f133690fe82708455b6112cc3934374db` |
| `g1_insurance_safe_review_manifest.json` | `a6f15c813c292761c85d445ed6af9337a168bfb569aac8397e27517fc8e383ba` |
| `g2_vault_safe_builder.json` | `518ae066c43a35304f77fc6387ce9b64d102e30891186854404ea9fe1762208e` |
| `g2_vault_safe_review_manifest.json` | `1e41cc95d801268a7c78eeb398be8af3c3bba27652d81f36300d489fc48c0e65` |
| `future_execute_args_NOT_AUTHORIZED.json` | `0c7ae3058eb48f2de3b4d52c247926af4f444ddb03864bd14fcd032b18e9e6d0` |
| `signed_order_inventory.json` | `3a4d9890d05eef48c27be9fdabbb1634ff43d839dd83d2b9cdfd502f905e2424` |

Verification used existing Solidity artifacts, pinned ABI decoding, independent local ABI encoding/Keccak, live Timelock hashOperation, owner-context setter simulations and scoped RPC reads. No broad Forge/Cargo build ran. Available memory was checked before work. No public write, keystore access, signature collection, backend/database service start, production-code change, canonical-artifact change, or database mutation occurred.
