# PERPS_V2_BASE_SEPOLIA_GOVERNANCE_CONTROLLED_REPLACEMENT_DEPLOYMENT_PACKAGE_V1

**Package verdict: BLOCKED_DEPLOYMENT_SIGNER_UNDESIGNATED.** This is an offline, non-executable package at frozen source commit `25c36670883604c1ef5229642ee6548aea6796c3`. The starting worktree was clean; `free -h` showed 7.6 GiB RAM, 5.1 GiB available and 2.0 GiB swap. No source, public state, Safe or Timelock state, backend, wallet or keystore was changed. There is no designated suitable deployment-only signer in the inspected project scripts, runbooks or configuration references. The lost OWNER and runtime executor are explicitly excluded. No new key was made. No package commit or push is appropriate while the acceptance gate remains blocked.

The [deployment package](../artifacts/perps_v2_replacement_deployment/deployment_package.json) binds the frozen source and six SHA-256s, all 16 package JSON artifacts, live comparison block, library links, staged D1–D6 constructors, and the no-broadcast boundary. Its SHA-256 is recorded below. A future signer setup must supply only a public address and verified creation/gas role, followed by fresh confirmed/pending nonce, balance and authorization checks. `DIRECT_CREATE` is the reviewed address mode for the six logical replacements. The existing Foundry/Safe CREATE2 mechanisms are not a reviewed deterministic replacement-deployment path. No address is predicted from an undesignated signer or stale nonce; each later stage depends on the previous canonical receipt and postflight.

## Live Base Sepolia checkpoint

Read-only EIP-1898 block-hash-pinned calls at block **47,829,878**, hash `0x607e68bdceb65b18221606598dc7dbdc139f7bbfd05717bc62f56c1fd61e5763`, verified chain ID **84532**. The [live state artifact](../artifacts/perps_v2_replacement_deployment/live_shared_state.json) records Safe owners, threshold **2/3**, empty enabled-module page, nonce **19**, Timelock owner/guardian = OPS Safe, Safe proposer/executor rights, and `minDelay=86400`. Vault, Insurance and Oracle owners are Timelock and their guardians are Safe. Clearing points to the shared Vault; its Vault ledger remains **1,000,000,000 raw mUSDC**. Vault's Insurance ledger is **2,100,010 raw mUSDC** at this block; this is not an activation or future liquidity guarantee.

The [PMR comparison](../artifacts/perps_v2_replacement_deployment/live_shared_state.json) records **67 MATCH, 6 EXPECTED_DIFFERENCE, 0 UNEXPECTED_DRIFT, 0 UNREADABLE** field classifications. Both complete market tuples, IDs `[1,2]`, next ID `3`, deviation limits, settlement allowance, Router feeds and freshness/deviation limits match the frozen PMR manifest. Differences concern the newer comparison block and *future replacement* owner/guardian/maintenance settings. The live source PMR remains a distinct, open registry owned by the lost EOA; its open controls are not substituted for the replacement's intended closed state. A later final review must refresh all values.

The [shared runtime comparison](../artifacts/perps_v2_replacement_deployment/shared_runtime_comparison.json) resolves the earlier Vault source mismatch. Live Vault runtime is **15,664 bytes**, Keccak `0xf834554ab8eea4ea97136a7c627a3f36bc166c94e5eb360b400d1f2d925b1349`, exactly reproduced by historical source revision `2ee93cad8d4ecd092ae95bec84d7f1c7654375bb` under the same compiler/settings. Current source adds only `transferFromInternalAccount` in commit `5badb64`; the Vault `transferBetweenAccounts` and `onlyMarginEngine`/`_isAuthorizedEngine` path is unchanged. Live Insurance runtime equals its current artifact outside declared constructor-immutable ranges. `InsuranceFund.coverVaultShortfall` calls Vault `transferBetweenAccounts` as InsuranceFund itself. Its Vault `isAuthorizedEngine(InsuranceFund)` and effective `isEngineAuthorized(InsuranceFund)` both read **true**. Vault and Insurance still authorize stranded NEW_ENGINE; the replacement is not yet deployed. Existing Seizer points to collateral RiskModule `0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B`, whose owner is Timelock and whose Vault/Oracle pointers match. Live Seizer `seizeConfigs(mUSDC)` is unset `(0,false,false)`, so source default spread zero/enabled applies.

## Frozen build and staged constructors

The [build manifest](../artifacts/perps_v2_replacement_deployment/build_manifest.json) contains the full linked creation bytecode, creation SHA-256/Keccak, source/dependency hashes, constructor ABI, exact metadata settings, link and immutable ranges, and constructor data wherever all arguments are known. Solidity is **0.8.30**, optimizer enabled/runs **0**, via-IR **true**, effective EVM **Prague**, metadata bytecode hash **none**, CBOR append **false**. The frozen six source-manifest SHA-256s were reverified before construction. Targeted compilation at the frozen HEAD reproduced the artifact templates.

The Engine links to existing Base Sepolia `PerpEngineSeizureLib` `0xf0C5652277CF88B508E05F7aB54949fCDF0360A5` and `PerpEngineLiquidationLib` `0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D`. Pinned live code lengths/hashes match frozen library artifacts after masking **only** their declared embedded self-address immutables; all other bytes match. No additional public library deployment is part of this six-contract package.

| Stage | Constructor arguments | Runtime Keccak | Read-only `eth_estimateGas` |
| --- | --- | --- | ---: |
| D1 PMR | Timelock | `0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5` | 3,034,081 |
| D2 FMV2 | Timelock, fee recipient Timelock | `0x732101d67fb112f6d3159f32852071bbf995f8bd1995335cf9a2b0f167d08726` | 1,984,130 |
| D3 Seizer | Timelock, shared Vault, Oracle, Timelock-owned collateral RiskModule | `0x6d199e027af598ee903513a1ab41e27e2937115c79b8ec85e386d739615befcb` | 1,564,663 |
| D4 Engine | Timelock, **conditional D1**, shared Vault, Oracle | `0x1ee5dc2756bea85a4ab327ff69f8652ef6aa0acf2883f00ad1a23c7f51f95785` | 5,679,125* |
| D5 Risk | Timelock, shared Vault, **conditional D4**, Oracle, mUSDC | `0x8c782209845865d35ecff80c00525ef3f0f335bea4e7b9846f01199c60fb5a2c` | 2,344,674* |
| D6 PME | Timelock, **conditional D4** | **unresolved future address/immutables** | 2,446,882* |

`*` D4–D6 estimates used local fixture dependency addresses in read-only RPC estimation. They are gas-unit planning observations, not final gas limits or fee envelopes. The future address-dependent D6 runtime and EIP-712 domain must be computed from canonical public D4/D6 receipts. The local fixture alone yielded PME runtime `0xdafeca3bb64ea22a03b12f3868b96b272aa0b031a57297025444b51b4e2a9d5c` and domain separator `0x426354fe64f3cb1f528755e722f155b24cc4f861524826c624f0bb59d882c007`; neither is a future public deployment commitment. No gas price is frozen.

D1–D3 exact ABI-encoded constructor args and full creation transaction data are in their review files. D4–D6 carry explicit unresolved address tokens and **no executable transaction data**. All six source constructors directly assign Timelock as owner. In the [local fork rehearsal](../artifacts/perps_v2_replacement_deployment/local_rehearsal.json), a non-secret impersonated local actor deployed D1–D6 in order at the pinned block; every code, owner, pending-owner and constructor pointer postflight passed (**1 test/0 failed/0 skipped**). D1–D5 runtime hashes matched the build manifest. The test also confirmed the new Engine starts OPEN/unsealed/unwired, has no Vault or Insurance authorization, and PME initially grants Timelock executor permission while unpaused. **Deployment alone does not establish the intended maintenance policy.** It must be applied and verified before any shared ACL grant. The local actor addresses are fixture evidence only.

## Offline continuation boundaries

The [Timelock configuration manifest](../artifacts/perps_v2_replacement_deployment/timelock_configuration_manifest.json) enumerates **26** separate owner/governance actions: 19 exact inner calldatas and 7 conditional on canonical deployment addresses. Market IDs must be created in order 1 then 2 while PMR config remains open. After configuring, PMR creation/config and global pause must be tightened; Engine's four emergency flags and PME pause must be active before shared Engine ACLs. Engine/Risk/PME reciprocal pointers, FMV2 fee consumer, Risk `maxOracleDelay=600`, guardians and restricted executor set each need their own postflight. No ETA or Timelock operation ID is invented: the deployed Timelock hashes `(target,value,data,eta)` and no ETA has been approved. Independent future queues may share a delay window only after exact addresses/calldata and timing are reviewed.

The [ACL transition manifest](../artifacts/perps_v2_replacement_deployment/shared_acl_transition_manifest.json) keeps stranded NEW_ENGINE's existing Vault/Insurance authorizations untouched now. A future dual-authorization interval begins only after replacement replay/seal and both Engines' maintenance state are verified, backend remains stopped, and no custody is copied. Future replacement grants and two independent stranded revocations require separate Timelock reviews and receipts. The [migration package](../artifacts/perps_v2_replacement_deployment/migration_replay_package.json) reuses the eight exact historical seed calldatas (two funding, six positions) and canonical `sealMigration` hash, with a conditional replacement Engine target. It forbids second Vault/Clearing funding, mint, collateral copy, fee-liability copy and realized-PnL replay. The [guard binding](../artifacts/perps_v2_replacement_deployment/first_trade_guard_binding.json) remains **unarmed** and must be regenerated from future canonical Engine/PME addresses and the new PME domain. Historical signatures are forbidden for reuse.

Future public execution is **one stage at a time**: final review, separate authorization, one broadcast, canonical receipt, exact postflight, then the next stage. Each step is independently stoppable. Nonce or address drift, ambiguous submission, runtime mismatch, missed maintenance, or changed shared ACL stops the sequence. No auto-retry or six-deployment batch is authorized. D1's predicted address and live code nonexistence check remain unavailable until an operator designates a suitable signer and its fresh nonce is verified.

## Package artifact SHA-256

All values below are SHA-256 of the exact local files under `artifacts/perps_v2_replacement_deployment/`. The package JSON binds every other JSON artifact; its own hash is listed here.

| Artifact | SHA-256 |
| --- | --- |
| `build_manifest.json` | `1322a81caa734106cda3b625c3c31b7d322eb0e8a165c9b931077340b396493c` |
| `d1_pmr_deployment_review.json` | `f4fcefc30018e5f7b62225d818152a2b9c739e81719e7b1acf3e42e78f64be5e` |
| `d2_fmv2_deployment_template.json` | `209cf52b742314934eef93c432a48501072f954db26b558a87109652499da0e3` |
| `d3_seizer_deployment_template.json` | `b0649f1829517589661c090dec82c3f964fd28afe2cf57a408390ec809436ad5` |
| `d4_engine_deployment_template.json` | `25966b8a2d33b0d8fa184a86c4f1890873cc356bc189aa304919d77e386f4692` |
| `d5_risk_deployment_template.json` | `321d4c6126fe3afad9857342378609784ddefee67b24f788bc28be5e41d5d931` |
| `d6_pme_deployment_template.json` | `df0bf2335c0ec557140897ee55d9cc223eb08a94172f319d395b232794379b65` |
| `deployment_package.json` | `4d2940751d06471e3cd6ca3a298db4e68c1a4b1872d9ca51f3371b69a42ea8b9` |
| `first_trade_guard_binding.json` | `35706cf2bd294099e334a9426048154046cd0c3c87a818ea4fcfae91a1da190c` |
| `library_link_evidence.json` | `1228c81f40e8ae53937e0448a3c263930d55b0185f0384fb212e318233ee9085` |
| `live_shared_state.json` | `5096cf2960a0adac96d4a13cb603713f80b660e44d2f71d23b0a7c6e1029f8f0` |
| `local_rehearsal.json` | `30e7b1580632674906f752e4045d8d67c7f4de00bda898100a4833229bbd94f0` |
| `migration_replay_package.json` | `5f9fbfd7c2eb1b01042d6f2e9de37849575760db8bd6db56a4a66c3c1539bcbb` |
| `shared_acl_transition_manifest.json` | `d427cdd8e9a994146e0d6acc1695b10961c8042bd53e88248d5287feb3683fd9` |
| `shared_runtime_comparison.json` | `f6d6ab3d5f153322262eff7d5a03a6d26da3c47af40996f3d6dd0949a5b44ade` |
| `timelock_configuration_manifest.json` | `9e3e10daad602bfd3831cab3ee469d74a0aa88cf321fcb49381381cb44fd2b6a` |

Offline package tests passed **5/5**; targeted Foundry local fork test passed **1/1**. Full broad test/build suites were not run under the RAM constraint. No public transaction, Timelock queue/execute, Safe action, migration replay, ACL change or trade was performed. The next step is operator designation and independent review of an existing deployment-only signer, not D1 broadcast.
