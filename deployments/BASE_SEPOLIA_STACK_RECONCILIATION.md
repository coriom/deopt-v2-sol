# Base Sepolia Stack Reconciliation Before OptionMatchingEngine

Date: 2026-05-20

This is a documentation-only preflight. No deployment, broadcast, private key use, ownership change, contract change, backend change, frontend change, commit, or push was performed.

## Summary

Local evidence shows three Base Sepolia `DeployCore.s.sol` stacks. The newest `DeployCore` artifact is not the stack targeted by the newest wiring/configuration artifacts. The canonical target for `DeployOptionMatchingEngine.s.sol` appears to be the older wired/configured stack from `broadcast/DeployCore.s.sol/84532/run-1777480640667.json`, because the latest `WireCore`, `ConfigureCore`, `ConfigureMarkets`, and `TransferOwnerships` artifacts all reference that stack.

The OptionMatchingEngine should not be deployed or wired until an operator confirms onchain bytecode, current owners/pending owners, current `MarginEngine.matchingEngine()`, and the intended canonical stack in the filled Base Sepolia env/manifest.

## Candidate Stacks

| Stack | Evidence | Key option addresses | Key perp/governance addresses | Follow-up evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Stack A: wired/configured candidate | `broadcast/DeployCore.s.sol/84532/run-1777480640667.json` | `MarginEngine` `0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8`; `OptionProductRegistry` `0x3d52b033fab00ed6104dd3bc0a715f8648344eca`; legacy `MatchingEngine` `0x93a6d3f540b72f05b4edbe071fa611af942423da` | `PerpEngine` `0xb36395b67d0798ada981731c9fa5239f4362b53b`; replacement `PerpMatchingEngine` `0x774d96e5739bffadee91508b4d3d74f5be29f165`; `ProtocolTimelock` `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588`; `RiskGovernor` `0x7918ea95c2791b6b587ff02ae481fa52403877a0` | Latest `WireCore` targets Stack A and sets option ingress to legacy `MatchingEngine`; latest `ConfigureCore`, `ConfigureMarkets`, and `TransferOwnerships` target Stack A addresses. | Recommended canonical target pending onchain confirmation. |
| Stack B: intermediate deploy-only stack | `broadcast/DeployCore.s.sol/84532/run-1777797227377.json` | `MarginEngine` `0x0297fe8b76f71d0ba817e64f6ceb576905e88c1b`; `OptionProductRegistry` `0xcf1904bf8fb0b507fec7c595bb8c2c41aee78b66`; `MatchingEngine` `0x9b488b0d2f9f791e8793d0112510fb638c3c02d8` | `PerpEngine` `0x7dbb34cfd572a3d25276111c7f577dbd6b8072b4`; `PerpMatchingEngine` `0xacf4fb7f8b2716a83981e6e7d058985ce6566a9e`; `ProtocolTimelock` `0xed57a8116f5bfcd503108366de1792c8ff4367d9`; `RiskGovernor` `0xe798528e691e419c7fd0e28514e8070dfb4eb2c0` | No latest wiring/config/ownership evidence targets this stack. | Stale unless an operator supplies contrary onchain evidence. |
| Stack C: latest DeployCore artifact | `broadcast/DeployCore.s.sol/84532/run-1777911603287.json` and `run-latest.json` | `MarginEngine` `0x4034e1e6ca70bcb8ca73c73d651683bc84b9d79b`; `OptionProductRegistry` `0x546ae8820f569d49c5df9039b9ed94c41982b0ca`; `MatchingEngine` `0x83fd0ba0051cd71bc6bcc93f54ba10c4535a8b18` | `PerpEngine` `0xe0bd9f2d58a6d007f2ae50009666f32153d8ffd0`; `PerpMatchingEngine` `0x6ad81f429e288848f756aeda4d9bd9fbf5692e6c`; `ProtocolTimelock` `0x32c9a91faa1ef37451090bad25141f4a90f1957e`; `RiskGovernor` `0xa274391ba48adbc1d4542ac99686611e4c5f38bb` | Despite being latest `DeployCore`, latest `WireCore`, `ConfigureCore`, `ConfigureMarkets`, and `TransferOwnerships` do not target these addresses. | Stale/unwired by local evidence. Do not use for OptionMatchingEngine unless explicitly recanonized. |

## Important Address Evidence

| Address | Value | Evidence source | Notes |
| --- | --- | --- | --- |
| `CollateralVault` | `0x00340c360353a5ab784c5bc5c44322a6af0625d3` | Stack A `DeployCore` plus latest `WireCore`/`ConfigureCore` targets | Recommended canonical pending onchain code and owner checks. |
| `OracleRouter` | `0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureMarkets` feed targets | Used by configured option/perp markets. |
| `OptionProductRegistry` | `0x3d52b033fab00ed6104dd3bc0a715f8648344eca` | Stack A `DeployCore`; latest `ConfigureCore`; latest `ConfigureMarkets`; latest `TransferOwnerships` | Must be the constructor `OPTION_PRODUCT_REGISTRY` for OptionMatchingEngine. |
| `MarginEngine` | `0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureCore`; latest `ConfigureMarkets` | Must be the constructor `MARGIN_ENGINE` for OptionMatchingEngine. |
| Current option ingress | `0x93a6d3f540b72f05b4edbe071fa611af942423da` | Latest `WireCore` calls `MarginEngine.setMatchingEngine(0x93A6...)` | This is legacy `MatchingEngine`; confirm onchain before replacing. |
| `OptionMatchingEngine` | `null` | No `broadcast/DeployOptionMatchingEngine.s.sol/84532` artifacts found | Not deployed in local Base Sepolia evidence. |
| `PerpMatchingEngine` | `0x774d96e5739bffadee91508b4d3d74f5be29f165` | `DeployPerpMatchingEngine.s.sol/84532/run-latest.json`; latest `WireCore` calls `PerpEngine.setMatchingEngine(0x774d...)` | Replaces Stack A original `0xec4769...`. |
| `PerpEngine` | `0xb36395b67d0798ada981731c9fa5239f4362b53b` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureMarkets` | Configured market ids 1 and 2. |
| `PerpMarketRegistry` | `0xb4fcf45e57b93274441def8f0f68bd30f6d677ec` | Stack A `DeployCore`; latest `ConfigureCore`; latest `ConfigureMarkets`; latest `TransferOwnerships` | Configured settlement asset and market status. |
| `RiskModule` | `0xc0f019005a25524a34f2ee8839dcdcc50715dd7b` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureCore` | Base collateral risk configured to mock USDC. |
| `PerpRiskModule` | `0xf1b46040147632d0b46a2153cc842506b4d7fee5` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureCore` | Base collateral and oracle delay configured. |
| `CollateralSeizer` | `0x39f928b959cf58369e7c7a3b925e6cbffa62b669` | Stack A `DeployCore`; latest `WireCore` | Used by `PerpEngine` wiring. |
| `FeesManager` | `0xaef73f10224712e1312963be11662061481aa0f0` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureCore` | Default fee config present in latest `ConfigureCore`. |
| `InsuranceFund` | `0x009f38440f058d095b61e0e2ee7fabdf05be7500` | Stack A `DeployCore`; latest `WireCore`; latest `ConfigureCore` | Backstop callers include Stack A `MarginEngine` and `PerpEngine` by artifact. |
| `ProtocolTimelock` | `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588` | Stack A `DeployCore`; latest `TransferOwnerships` | Ownership acceptance state still requires onchain confirmation. |
| `RiskGovernor` | `0x7918ea95c2791b6b587ff02ae481fa52403877a0` | Stack A `DeployCore`; latest `TransferOwnerships` proposer configuration | Timelock proposer allowed in local artifact. |
| Mock USDC | `0x6eae407f5640b006fac9965182e238582a3b412e` | `DeployTestnetAssets.s.sol/84532/run-latest.json`; latest `ConfigureCore` | Used as base collateral in latest config artifacts. |
| Mock WETH | `0x4deebc5f537f3b8ba0e3393807b4d699d72bdd02` | `DeployTestnetAssets.s.sol/84532/run-latest.json`; latest `ConfigureMarkets` | ETH underlying in latest market config. |
| Mock WBTC | `0x9d871ac7595e8da271e866608e5145252047967c` | `DeployTestnetAssets.s.sol/84532/run-latest.json`; latest `ConfigureMarkets` | BTC underlying in latest market config. |
| ETH/USDC feed sources | `0x3eb9cdd2c2115c3f0df5e30da53d7245f9a5f6cc`, `0x2103a84c0cab9cf7680d602c8931faded7064517` | `DeployTestnetMockFeeds.s.sol/84532/run-latest.json`; latest `ConfigureMarkets` | Mock feed prices refreshed by latest `RefreshTestnetMockFeeds`. |
| BTC/USDC feed sources | `0x8cba01b3f4e818ffffd6c1ae1f9a18a656e918bb`, `0x7206e7c2c1c3d6e6273020163eb1f0e9339b970c` | `DeployTestnetMockFeeds.s.sol/84532/run-latest.json`; latest `ConfigureMarkets` | Mock feed prices refreshed by latest `RefreshTestnetMockFeeds`. |

## Canonical Stack Recommendation

Use Stack A as the canonical target for the OptionMatchingEngine deployment preflight, subject to operator confirmation onchain.

Rationale:

- Latest `WireCore.s.sol/84532/run-latest.json` targets Stack A addresses and sets `MarginEngine.matchingEngine` to Stack A legacy `MatchingEngine`.
- Latest `ConfigureCore.s.sol/84532/run-latest.json` targets Stack A `CollateralVault`, `RiskModule`, `PerpRiskModule`, `OptionProductRegistry`, `PerpMarketRegistry`, `MarginEngine`, `FeesManager`, and `InsuranceFund`.
- Latest `ConfigureMarkets.s.sol/84532/run-latest.json` targets Stack A `OracleRouter`, `OptionProductRegistry`, `MarginEngine`, `PerpMarketRegistry`, and `PerpEngine`.
- Latest `TransferOwnerships.s.sol/84532/run-latest.json` targets Stack A `OptionProductRegistry`, `PerpMarketRegistry`, `ProtocolTimelock`, and `RiskGovernor`.
- There are no Base Sepolia `DeployOptionMatchingEngine` artifacts.

Stack C is the newest core deployment artifact, but local evidence does not show it as wired or market-configured. Treat it as stale/unwired unless an operator intentionally recanonizes it and updates the manifest/env/runbooks first.

## Risk: Wrong MarginEngine

`DeployOptionMatchingEngine.s.sol` permanently constructs the OptionMatchingEngine with `MARGIN_ENGINE` and `OPTION_PRODUCT_REGISTRY`. If either value points at Stack C while the active protocol and backend use Stack A, option intent settlement will be bound to the wrong accounting and product registry surface.

The worst unsafe pattern is:

1. Deploy `OptionMatchingEngine` with Stack C `MARGIN_ENGINE` or `OPTION_PRODUCT_REGISTRY`.
2. Set Stack A `OPTION_MATCHING_ENGINE_ADDR` to that new engine.
3. Run `WireCore`, causing Stack A `MarginEngine.matchingEngine` to point at an OptionMatchingEngine whose constructor dependencies reference Stack C.

That can cause execution failures, inconsistent backend indexing, or trades settling against an unintended stack. Before any broadcast, the operator must confirm:

- `OptionMatchingEngine.marginEngine() == 0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8`.
- `OptionMatchingEngine.optionRegistry() == 0x3d52b033fab00ed6104dd3bc0a715f8648344eca`.
- After wiring, `MarginEngine.matchingEngine() == OPTION_MATCHING_ENGINE_ADDR`.
- `VerifyDeployment.s.sol` passes with the same canonical env values.

## Missing Information

- Filled, non-secret Base Sepolia manifest does not exist yet; only templates/examples and this draft are present.
- Onchain bytecode was not checked in this task.
- Current onchain `MarginEngine.matchingEngine()` was not checked in this task.
- Current onchain owners, pending owners, guardians, and executor allowlists were not checked in this task.
- Whether `AcceptOwnerships.s.sol` has been run on Base Sepolia is not shown by local `84532` broadcast artifacts.
- Final operator decision is needed to confirm Stack A and explicitly retire Stack B/Stack C.
- `OPTION_MATCHING_ENGINE_OWNER`, `OPTION_MATCHING_EXECUTOR`, `OPTION_MATCHING_EXECUTORS`, and `OPTION_MATCHING_EXECUTOR_ALLOWED` need final operator confirmation.
- Broadcast tx hashes, block numbers, and finality confirmations for the intended OptionMatchingEngine deploy/wire steps are not available yet.
- Backend runtime config values must be updated only after the deployed OptionMatchingEngine address is captured and verified.

## Required Env Alignment Before OptionMatchingEngine Broadcast

For the recommended Stack A path, the filled env used by `DeployOptionMatchingEngine.s.sol` must include:

```bash
CHAIN_ID=84532
MARGIN_ENGINE=0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8
OPTION_PRODUCT_REGISTRY=0x3d52b033fab00ed6104dd3bc0a715f8648344eca
INITIAL_OWNER=TODO_CONFIRM
```

For the follow-up `WireCore.s.sol` broadcast, every core address must be the Stack A address, `PERP_MATCHING_ENGINE` must be the replacement `0x774d96e5739bffadee91508b4d3d74f5be29f165`, and `OPTION_MATCHING_ENGINE_ADDR` must be the newly deployed OptionMatchingEngine.

## Safe Commands Prepared

These commands are safe local validation commands and do not broadcast:

```bash
forge fmt --check
forge build
forge test
python3 -m json.tool deployments/base-sepolia.manifest.draft.json >/dev/null
```

These read-only onchain checks are safe to run manually with a non-secret RPC URL:

```bash
cast chain-id --rpc-url "$RPC_URL"
cast code "$MARGIN_ENGINE" --rpc-url "$RPC_URL"
cast code "$OPTION_PRODUCT_REGISTRY" --rpc-url "$RPC_URL"
cast code "$MATCHING_ENGINE" --rpc-url "$RPC_URL"
cast call "$MARGIN_ENGINE" "matchingEngine()(address)" --rpc-url "$RPC_URL"
cast call "$MATCHING_ENGINE" "marginEngine()(address)" --rpc-url "$RPC_URL"
cast call "$PERP_ENGINE" "matchingEngine()(address)" --rpc-url "$RPC_URL"
cast call "$PERP_MATCHING_ENGINE" "perpEngine()(address)" --rpc-url "$RPC_URL"
```

After OptionMatchingEngine deployment, also run:

```bash
cast code "$OPTION_MATCHING_ENGINE_ADDR" --rpc-url "$RPC_URL"
cast call "$OPTION_MATCHING_ENGINE_ADDR" "marginEngine()(address)" --rpc-url "$RPC_URL"
cast call "$OPTION_MATCHING_ENGINE_ADDR" "optionRegistry()(address)" --rpc-url "$RPC_URL"
cast call "$MARGIN_ENGINE" "matchingEngine()(address)" --rpc-url "$RPC_URL"
forge script script/VerifyDeployment.s.sol --rpc-url "$RPC_URL" -vvvv
```

## Dangerous Manual-Only Broadcast Commands

Do not run these as part of preflight. They are shown only so an operator can review the intended manual sequence after all checklist items are complete.

```bash
# MANUAL ONLY: deploys OptionMatchingEngine bound to the canonical Stack A MarginEngine and OptionProductRegistry.
forge script script/DeployOptionMatchingEngine.s.sol --rpc-url "$RPC_URL" --broadcast --slow --non-interactive

# MANUAL ONLY: broad rewiring script. Confirm every env address is Stack A and OPTION_MATCHING_ENGINE_ADDR is the newly deployed address.
forge script script/WireCore.s.sol --rpc-url "$RPC_URL" --broadcast --slow --non-interactive
```

## Expected Artifacts To Capture After Manual Broadcast

- `broadcast/DeployOptionMatchingEngine.s.sol/84532/run-*.json`.
- New `OPTION_MATCHING_ENGINE_ADDR`.
- Deploy tx hash, block number, deployer address, and finality confirmation.
- Constructor dependency reads:
  - `OptionMatchingEngine.marginEngine()`.
  - `OptionMatchingEngine.optionRegistry()`.
- Optional ownership/executor reads:
  - `OptionMatchingEngine.owner()`.
  - `OptionMatchingEngine.isExecutor(<operator-approved executor>)`.
- Wiring read:
  - `MarginEngine.matchingEngine()`.
- Post-broadcast `VerifyDeployment.s.sol` output.
- Updated filled deployment manifest and backend runtime config values.

## Backend Follow-Up Values

After successful manual deploy and wire, backend/runtime config should point at the same canonical Stack A values:

```bash
CHAIN_ID=84532
BASE_COLLATERAL_TOKEN=0x6eae407f5640b006fac9965182e238582a3b412e
COLLATERAL_VAULT=0x00340c360353a5ab784c5bc5c44322a6af0625d3
ORACLE_ROUTER=0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581
OPTION_PRODUCT_REGISTRY=0x3d52b033fab00ed6104dd3bc0a715f8648344eca
MARGIN_ENGINE=0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8
MATCHING_ENGINE=0x93a6d3f540b72f05b4edbe071fa611af942423da
OPTION_MATCHING_ENGINE_ADDR=TODO_CAPTURE_AFTER_DEPLOY
PERP_ENGINE=0xb36395b67d0798ada981731c9fa5239f4362b53b
PERP_MARKET_REGISTRY=0xb4fcf45e57b93274441def8f0f68bd30f6d677ec
PERP_MATCHING_ENGINE=0x774d96e5739bffadee91508b4d3d74f5be29f165
```

Do not switch backend option execution to the new OptionMatchingEngine until the post-broadcast reads and `VerifyDeployment.s.sol` confirm the same address.

## Operator Checklist Before Broadcast

1. Confirm `cast chain-id --rpc-url "$RPC_URL"` returns `84532`.
2. Confirm the filled env uses Stack A addresses, not Stack C `run-latest` `DeployCore` addresses.
3. Confirm all Stack A contract addresses have bytecode.
4. Confirm `MARGIN_ENGINE=0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8`.
5. Confirm `OPTION_PRODUCT_REGISTRY=0x3d52b033fab00ed6104dd3bc0a715f8648344eca`.
6. Confirm current `MarginEngine.matchingEngine()` is the legacy Stack A `MatchingEngine` before replacement.
7. Confirm owner/pendingOwner/guardian state allows the intended `WireCore` caller to set the new matching engine.
8. Confirm `OPTION_MATCHING_ENGINE_OWNER` and executor allowlist policy.
9. Confirm the operator explicitly chooses Stack A as canonical and records Stack B/Stack C as stale.
10. Broadcast `DeployOptionMatchingEngine.s.sol` manually only after the above checks pass.
11. Capture `OPTION_MATCHING_ENGINE_ADDR` and constructor dependency reads.
12. Set `OPTION_MATCHING_ENGINE_ADDR` in the env and review every `WireCore` address again.
13. Broadcast `WireCore.s.sol` manually only after confirming it will not point any module at Stack B/Stack C.
14. Run read-only `cast` checks and `VerifyDeployment.s.sol`.
15. Update the final manifest and backend config only after verification passes.

## Final Recommendation

Proceed toward OptionMatchingEngine deployment only against Stack A, and only after onchain confirmation proves Stack A remains the live configured stack. Do not use Stack C merely because it is the latest `DeployCore` artifact; local evidence marks it as deploy-only/unwired. Do not wire any OptionMatchingEngine unless its constructor `marginEngine` and `optionRegistry` exactly match the recommended canonical Stack A values.
