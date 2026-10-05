# PERPS_V2_BASE_SEPOLIA_V2_REBIND_OWNER_ONLY_V1 — preparation only

**Status: `REBIND_PREFLIGHT=PASS`; R1/R2/R3 prepared, none authorized or sent.** This report supersedes the previously blocked four-OWNER proposal only for the three OWNER-owned setters. Insurance and Vault were separately executed through Timelock; their history and operation IDs are unchanged. No executor change, unpause, backend start or trade is part of this package.

## Pinned public-chain checkpoint

Base Sepolia chain ID **84532**, block **47,702,782**, hash `0x6a68a91b97103a8494c2a97404ca3cf78e05f5b38f87048809b050563f7c0b19`, timestamp **2026-10-05 04:17:32 UTC**. OWNER `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` had confirmed/pending transaction nonce **812/812** when the preflight completed; the helper reread both after its simulations. Equal counts rule out a visible nonce-consuming pending transaction at that RPC, but cannot exclude a later/private submission. Refresh both before any future transaction review.

At the pinned block, G1 and G2 `queuedTransactions` were both false; Insurance `isBackstopCaller(NEW_ENGINE)` and Vault `isAuthorizedEngine(NEW_ENGINE)` were both true. FMV2's NEW_ENGINE fee-consumer permission was false; RISK_V2 and PME_V2 still pointed to OLD_ENGINE. Live `owner()` on **each** of FMV2, RISK_V2 and PME_V2 returned OWNER. The NEW_ENGINE runtime was 24,321 bytes with Ethereum Keccak-256 `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`, SEALED with canonical snapshot hash `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.

The comparison passed **114** migration/economic/dependency reads, **14** seed flags, **6** position indexes and **6** PME trader nonces against the committed reseal baseline, accounting only for the two intended G1/G2 permission changes. Both matching engines were paused. All four emergency flags were true on V1, OLD_ENGINE and NEW_ENGINE. Clearing Vault balance for CLEARING_V2 remained **1,000,000,000** native mUSDC. A bounded scan of relevant protocol emitters from the block after E2 through the comparison block found no events. The local backend process check reported **STOPPED**; that is not proof about external callers. No chain transaction, keystore operation or database write was made by this preparation.

## Reviewed calls

All three direct calls use OWNER as sender, Base Sepolia chain ID 84532 and **zero ETH value**. `eth_call` from OWNER succeeded for each at the initial pinned state. Gas estimates below are initial-state observations, **not** approved gas limits or fee caps. R2 and R3 must be re-estimated after their prerequisite transaction is canonically verified.

| Step | Proposed nonce | Target | Signature / selector | Args | Gas estimate | Expected event | Conditional postcondition |
| --- | ---: | --- | --- | --- | ---: | --- | --- |
| R1 | 812 | FMV2 `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f` | `setFeeConsumer(address,bool)` / `0x677682c4` | `(NEW_ENGINE,true)` | 48,311 | `FeeConsumerSet(address,bool)` | FMV2 NEW=true; Risk and PME stay OLD |
| R2 | 813 | RISK_V2 `0x8C3d9F71cA59B908Fa200546A63ea62F9C932998` | `setPerpEngine(address)` / `0xb619daf7` | `(NEW_ENGINE)` | 31,324 | `PerpEngineSet(address,address)` | Risk NEW; PME OLD; OLD remains paused |
| R3 | 814 | PME_V2 `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` | `setEngine(address)` / `0x0e830e49` | `(NEW_ENGINE)` | 30,752 | `EngineSet(address,address)` | PME and Risk NEW; all maintenance remains active |

`NEW_ENGINE` means `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`; `OLD_ENGINE` means `0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9`. Complete calldata, expected event topic, per-call `eth_call` result, and **review-only rollback calldata** are in each JSON file. The reviewed rollback calls would be R1 `setFeeConsumer(NEW_ENGINE,false)`, R2 `setPerpEngine(OLD_ENGINE)` and R3 `setEngine(OLD_ENGINE)`; none is authorized or automatically safe to execute.

R1 changes only the FMV2 consumer mapping. R2 changes the shared RiskModule's `perpEngine` pointer. Since OLD_ENGINE still references this same RiskModule, its risk reads may then use **NEW_ENGINE** economics. OLD_ENGINE is therefore not isolated or retired; the current four-flag maintenance lock, stopped local backend and no operational use of OLD_ENGINE remain conditions of this order. R3 switches PME last. PME's reused address, EIP-712 domain, trader nonces and executor mapping are not reset by its setter. The source setter bodies have no external calls. Their deployed runtimes differ from the present `out/` build, so the preparation also exercised the **actual deployed code** in a sequential local fork before relying on expected effects.

The isolated Anvil fork at public source block 47,702,782 reported chain ID 84532 but was bound to loopback. A read-only relay refused upstream send methods. Local OWNER impersonation, without a real keystore, executed R1 → R2 → R3 one at a time. Each local receipt had status 1 and the expected event; after each, fee permission and Risk/PME pointers matched the table. Market states, six positions on both V2 Engines, migration metadata, clearing, six trader nonces and every emergency flag stayed unchanged. This was a **local rehearsal**, not a public transaction, and standard EVM execution does not model OP L1 fee settlement. The first local attempt stopped on an immediate null receipt; the successful attempt waited for each local receipt. Neither attempt sent to Base Sepolia.

PME trading entrypoints require `whenNotPaused` and NEW_ENGINE `applyTrade` requires the trading pause to be clear. Both remain paused, so this rebind preparation does not activate trading. The local backend being stopped does not itself prohibit external contract callers; maintain the on-chain locks until a separately reviewed activation.

## Exact review files

| File | SHA-256 |
| --- | --- |
| `artifacts/perps_v2_rebind_owner_only/preflight.json` | `41c8c672a0174f2679f458c5f948dd6fe33f56d7bb090582c7dd36fc1a9248f7` |
| `artifacts/perps_v2_rebind_owner_only/r1_fmv2_review.json` | `f45e8d50c1f24ccff91c524847be66229c5ffb6f636987bdef01ee14700a5601` |
| `artifacts/perps_v2_rebind_owner_only/r2_risk_review.json` | `03568d7616d5ec2d078c32145e1e719550277ee165b737190d75756bccefcf53` |
| `artifacts/perps_v2_rebind_owner_only/r3_pme_review.json` | `cc0342458aeb02f805081b50dd11f30c8664cf47529367405ae416a94d573c9c` |
| `artifacts/perps_v2_rebind_owner_only/local_rehearsal.json` | `d7e784b0ddf6596773fb8de8640decc34093e13176a2278d48a494742ec1d425` |

## Operator execution boundary

R1 is the **only next candidate for separate review**. This package does not approve its broadcast. Before any separately authorized R1, refresh chain ID, OWNER confirmed/pending nonce, three live owners, G1/G2 effects, maintenance, economics, gas and fee envelope. Obtain the actual public hash after operator submission and require canonical status 1, exact OWNER/from, FMV2/to, nonce and calldata, `FeeConsumerSet` event, consumer=true, pointers still OLD, and unchanged economics and maintenance. Only then refresh nonce and separately review R2. After R2, verify `PerpEngineSet`, Risk=NEW, PME=OLD and OLD fully paused before separately reviewing R3. R3 is last; its receipt and `EngineSet` must precede any claim that rebind is complete. No automatic retry, rollback, next-step authorization or trade follows any receipt.

No deployer password file was created. Any later OWNER signing requires its separate, approved `/run/user/$(id -u)/deopt-deployer.pw` workflow with mode 0600 and cleanup. G1/G2 governance execution, executor policy, selective unpause and the controlled first trade are separate milestones. Public trading remains unauthorized.
