# PERPS_V2_BASE_SEPOLIA_GOVERNANCE_CONTROLLED_REPLACEMENT_SOURCE_AND_TESTS_V1

Local source, deterministic artifacts and test evidence only. No public transaction, wallet access, Safe/Timelock operation, backend start or trade was performed. Starting Solidity HEAD was `6112c2843b283c80183e66dfe337f8604c20c083` with a clean worktree; memory at entry was 7.6 GiB total / 4.4 GiB available / 2.0 GiB swap. All Foundry jobs used `-j 1`.

**Local source/test verdict: PASS. Deployment remains unauthorized.** The later deployment package must resolve external library addresses, recheck live shared ACL/configuration, and review exact linked bytecode before any public action.

## Frozen logical set and authority

The replacement logical set remains **exactly six**: `PerpMarketRegistry`, `FeesManagerV2`, `CollateralSeizer`, `PerpEngineV2`, `PerpRiskModule`, and `PerpMatchingEngineV2`. All six constructors accept the existing ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` directly as owner; local construction leaves no pending owner or deployer authority. The proposed guardian is OPS Safe `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, and the sole routine PME executor is `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8`. The PME constructor initially authorizes its owner as executor; local Timelock-context configuration removes that routine permission and enables only the runtime executor. These are **source/test policies**, not live ACL changes.

Engine and PMR `setEmergencyModes` now reject any Safe/guardian transition that clears an active flag, including mixed tighten/relax calls. Owner/Timelock can release. Engine `setMarketEmergencyCloseOnly` lets the guardian **enable** close-only but only the owner **clear** it; this retains the shared V1 source's tested emergency-tightening behavior. Risk and PME already had owner-only release functions. No upgradeability was added. The full function/authority inventory is in `authority_manifest.json`.

The first owner-only per-market implementation failed the shared V1 `testGuardianMarketEmergencyCloseOnlyStillAllowsTwoSidedReduction` regression. It was replaced with the tighten-only guardian check above; the final V1 suite passes 23/23. The shared-source compatibility constraint also leaves only 13 bytes of Engine runtime headroom.

The source policy is **current FeesManagerV2 with `protocolFeeVault == address(0)`**. Git history shows that commit `5badb64` added only the optional ProtocolFeeVault storage/setter and `consumeFees` callbacks relative to `b3bc000`; fee schedule, fee recipient selection, rebate-budget accounting and Merkle claim logic were not changed by that diff. The historical live runtime was 6,204 bytes; the targeted current artifact is 6,727 bytes. With the hook unset, there is no external hook call. Activating a hook later is a separate Timelock governance decision and may revert fee consumption if its callback fails.

The legacy FMV2's 999,977 raw mUSDC rebate budget is **an accounting cap, not token custody**. Its nonzero Merkle root's recorded validity window had already expired at the pinned block; a nonzero root does not make new tier claims currently valid. Per-account claimed tiers are not enumerable here, and the lost legacy owner cannot be assumed able to renew the root. Existing claim state and rebate accounting remain on legacy FMV2. The replacement starts with zero root, zero rebate budget and no ProtocolFeeVault hook. The local test proves the replacement cannot accept a copied legacy Merkle claim or debit a copied rebate budget. No shared Vault funds are credited for this purpose.

## Source and state binding

The [source manifest](../artifacts/perps_v2_replacement/source_manifest.json) records all six compiler artifacts, source/dependency SHA-256s, constructor ABIs, optimizer settings, creation hashes and runtime identity where deterministic. Targeted compilation used Solidity 0.8.30, via-IR, optimizer runs 0, effective Prague EVM target. Current Engine artifact runtime size is **24,563 bytes**, 13 bytes under the 24,576-byte EIP-170 cap. This small margin makes exact compiler/settings/link verification mandatory in the later deployment package. Engine creation/runtime bytecode contains external `PerpEngineLiquidationLib` and `PerpEngineSeizureLib` link references. PME's EIP-712 implementation has constructor immutables. Therefore their **future deployed** runtime hashes are not represented by hashes of unresolved artifact templates; the source manifest marks them unresolved. The separate [local recovery context](../artifacts/perps_v2_replacement/recovery_context_manifest.json) binds the fixture's six actual local addresses and runtime Keccak hashes to the canonical snapshot and source/PMR/authority/migration manifest hashes. It is explicitly a local fixture commitment, not an on-chain deployment identifier.

The [PMR configuration manifest](../artifacts/perps_v2_replacement/pmr_config_manifest.json) records the pinned Base Sepolia read at block **47,789,885**, hash `0x87f35645d28adaae2c5a43a3ccb6996d87e6f4778aafe19e6b14c1a956abe8ca`: exactly market IDs 1 and 2, next ID 3, complete market/risk/liquidation/funding/status/metadata/deviation tuples, settlement allowance, and shared OracleRouter feed configuration. The local fixture reproduces the economic/risk parameter tuples; its mock asset and oracle addresses are local stand-ins and are **not** the future deployment address manifest. A later deployment package must bind the live token/underlying/router addresses and re-read state. An attempted later RPC refresh of the Insurance-to-Vault ACL returned a redacted transport failure; no current ACL claim is made from that attempt.

The replacement wiring fixture uses: Engine→replacement PMR, shared Vault, Oracle, replacement Risk/PME/FMV2/Seizer, shared Insurance and Clearing; Risk→replacement Engine; PME→replacement Engine; Seizer→shared Vault/Oracle and the Timelock-owned legacy collateral RiskModule. All owner-only wiring was invoked from Timelock context. `risk.setMaxOracleDelay(600)` is mandatory: its constructor default is zero. The local Router test proves a quote still accepted at the Router's 1,500-second threshold is excluded by Risk after 601 seconds. The local Oracle and token mocks do not prove live feed liveness.

The [migration manifest](../artifacts/perps_v2_replacement/migration_manifest.json) retains snapshot block `47,354,411`, its canonical block hash, and Engine seal hash `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`. Local replay seeds the six exact position tuples, market-1 OI `1,001,002/1,001,002`, zero cumulative funding, funding timestamp `1,789,715,546`, market-2 zero state and zero residual debt. It checks duplicate seed rejection, complete readback and shared Vault/Clearing ledger and custody before sealing with the **same** canonical hash. The off-chain recovery-context commitment does not replace `sealMigration`'s input. Replaying Engine accounting does **not** mint mUSDC, re-fund Clearing, copy collateral or fee budgets, or replay realized PnL. The local shared ledger stays `1,000,000,000` raw mUSDC.

The replacement PME has a new verifying contract/domain. Historical PME signatures fail on it; fresh synthetic-domain bilateral signatures execute once and nonce replay fails. Intent fills retain separate `intentNonceUsed`/`intentFilled` semantics; a partial fill may continue on the same intent until exhausted. Historical signatures are **forbidden** for reuse. The new PME starts with clean constructor nonces/fills and accepts only freshly approved signatures. No real trader key was used.

The first-trade guard and one-shot test adapter now accept a separately hashed deployment policy that binds replacement PME/Engine runtime identity, complete approved trade package, exact signed type-2 bytes, signer, chain, domain, deadline, fees and journal. Existing fixed two-trader/market-1/close-only and no-batch rules remain. The sender remains a recording fake only. The replacement collector can read pinned replacement state but cannot be exercised against a real replacement until one exists. This does **not** arm live execution.

## Test evidence and limits

All focused tests run sequentially. Counts below are per **test file**, so no pass is double-counted in the total; the scenario categories overlap by design.

| Suite | Passed | Failed | Skipped | Scope |
| --- | ---: | ---: | ---: | --- |
| Replacement guardian | 5 | 0 | 0 | PMR/Engine monotonic tightening, owner release, unauthorized actors |
| Replacement topology | 17 | 0 | 0 | six owners/wiring, PMR tuples, replay/custody, fee liability, ACL, Risk/Router, Seizer, liquidation, PnL, lost deployer |
| Replacement PME domain/intent | 4 | 0 | 0 | new domain, wrong chain, nonce replay, partial-fill accounting |
| Existing V2 migration | 33 | 0 | 0 | seed/seal/economic regressions, including exact close |
| Existing V2 production PnL | 1 | 0 | 0 | real Risk/FMV2, fees separate, ±244,274 |
| Existing V2 liquidation | 5 | 0 | 0 | liquidation orchestration; this suite uses a mock Risk |
| Existing CollateralSeizer | 8 | 0 | 0 | planner and haircut behavior |
| Existing funding | 21 | 0 | 0 | shared funding code; this suite exercises the V1 façade |
| Existing OracleRouter | 14 | 0 | 0 | dual-source configuration |
| Shared V1 Engine regression | 23 | 0 | 0 | guardian close-only tightening preserved after shared-source change |
| Python guard/adapter | 29 | 0 | 0 | 26 prior guard/adapter plus 3 replacement-policy synthetic tests |

**Scenario accounting:** replacement governance/ownership 3/3, guardian 6/6, wiring 2/2, PMR tuple equivalence 1/1, replacement migration 1/1, shared-Vault double-counting 1/1, FMV2 liability 1/1, replacement PME domain/nonce/fill 4/4, replacement-topology PnL 1/1, replacement funding/Risk/Router 3/3, replacement liquidation/Seizer 3/3, dual Vault/Insurance ACL 1/1, replacement first-trade guard 3/3, explicit lost-deployer lifecycle 1/1; all 0 failed/0 skipped. These categories overlap the test-file totals and do not represent independent additional tests.

The replacement close test uses local Engine-context impersonation of its PME address solely to isolate Engine cashflow; signature/domain verification is covered in the separate replacement PME suite. Source `_settleRealizedPnlV2` debits negative realized PnL before positive credits. The test observes long +244,274 and short −244,274 raw mUSDC before separate maker/taker fees, a zero net Clearing delta, and unchanged Vault token custody. The integrated liquidation test exercises the replacement Engine/Risk/Seizer with shared Vault and a real InsuranceFund; its separate, local Insurance payout probe requires InsuranceFund itself to be Vault-authorized. The **live shared Vault authorization for InsuranceFund remains to be verified** before relying on the backstop. The test does not claim that this ACL has been granted publicly.

The broad repository `forge build -j 1` was stopped under the limited-RAM constraint after several minutes; targeted build of all six replacement sources completed successfully. This milestone does not claim a full-repository build or all-repository test suite. The existing historical and signed-order evidence was not rewritten. No public state was changed.

## Deterministic manifest SHA-256

| File under `artifacts/perps_v2_replacement/` | SHA-256 |
| --- | --- |
| `source_manifest.json` | `2526f2fcfa8386b34d6b44638929e8b68d90875754d4dce636f0924ccdcdfc1b` |
| `authority_manifest.json` | `47c483b8ca5c8aec7e2107870124a9bcd2ddf4750ca13ba6c445a334f7c3e713` |
| `pmr_config_manifest.json` | `accf5770fed96c52cb869c868822697e98a3acc2b6b9f35ab6922e2fc945d20c` |
| `fee_liability_manifest.json` | `5bf7cb0159054f4127e49501009c793fed9a240fa2d9a6fab8558c02fa9953fe` |
| `executor_manifest.json` | `960a12192a8aca4520a647b54d83e1f4e5087b2bd52a121c520b9ed80e97b361` |
| `migration_manifest.json` | `4bfcf23520716532acf5aef967042f3fe7b19ca2182b19dc7e698c332d59337e` |
| `recovery_context_manifest.json` | `2215c301a24de9a82268fd3d2deb0a2b39718a654879c875149bc5f7b19e0735` |

## Later deployment-package gates

Resolve and approve the Engine library link addresses and constructor-dependent PME runtime identity; verify the complete PMR manifest against a fresh canonical block; verify the shared Vault's InsuranceFund authorization and, if absent, prepare a **separate** Timelock ACL operation; verify all shared dependencies/authorities and balances; stage deployment/configuration/replay/ACL changes one transaction at a time under full maintenance. Every actual address and hash must be recomputed after deployment. Keep stranded OLD/NEW Engines maintained. No deployment, migration, Timelock action, unpause or first trade is authorized by this local evidence.
