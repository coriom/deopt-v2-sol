# OptionMatchingEngine Base Sepolia Preflight

## Scope

This is a preflight document only. Do not deploy, broadcast, use private keys, change ownership, or modify protocol logic from this document.

Target network: Base Sepolia, chain id `84532`.

## Detected Current Deployment State

Observed artifacts:

- Deployment templates only are present in `deployments/`: `DEPLOYMENT_MANIFEST.example.json`, `testnet.template.json`, `local.template.json`, and `mainnet.template.json`.
- No filled Base Sepolia deployment manifest was found in `deployments/`.
- No `broadcast/DeployOptionMatchingEngine.s.sol/84532/` artifact exists. No Base Sepolia `OptionMatchingEngine` deployment was detected from local artifacts.
- `broadcast/DeployPerpMatchingEngine.s.sol/84532/run-latest.json` exists and deployed `PerpMatchingEngine` at `0x774d96e5739bffadee91508b4d3d74f5be29f165`.
- `broadcast/WireCore.s.sol/84532/run-latest.json`, `ConfigureCore`, and `ConfigureMarkets` point at the older wired core stack below, not the latest `DeployCore` stack.

Wired Base Sepolia stack inferred from latest `WireCore`, `ConfigureCore`, and `ConfigureMarkets` artifacts:

| Contract | Address |
| --- | --- |
| `CollateralVault` | `0x00340c360353a5ab784c5bc5c44322a6af0625d3` |
| `OracleRouter` | `0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581` |
| `OptionProductRegistry` | `0x3d52b033fab00ed6104dd3bc0a715f8648344eca` |
| `MarginEngine` | `0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8` |
| `RiskModule` | `0xc0f019005a25524a34f2ee8839dcdcc50715dd7b` |
| `PerpMarketRegistry` | `0xb4fcf45e57b93274441def8f0f68bd30f6d677ec` |
| `PerpEngine` | `0xb36395b67d0798ada981731c9fa5239f4362b53b` |
| `PerpRiskModule` | `0xf1b46040147632d0b46a2153cc842506b4d7fee5` |
| `CollateralSeizer` | `0x39f928b959cf58369e7c7a3b925e6cbffa62b669` |
| `FeesManager` | `0xaef73f10224712e1312963be11662061481aa0f0` |
| `InsuranceFund` | `0x009f38440f058d095b61e0e2ee7fabdf05be7500` |
| `MatchingEngine` | `0x93a6d3f540b72f05b4edbe071fa611af942423da` |
| `PerpMatchingEngine` | `0x774d96e5739bffadee91508b4d3d74f5be29f165` |
| `ProtocolTimelock` | `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588` |
| `RiskGovernor` | `0x7918ea95c2791b6b587ff02ae481fa52403877a0` |

Current inferred option ingress for the wired stack:

- `WireCore.s.sol/84532/run-latest.json` called `MarginEngine.setMatchingEngine(0x93A6D3F540b72f05b4EdbE071fA611af942423dA)`.
- Because no `OPTION_MATCHING_ENGINE_ADDR` was present, the legacy `MatchingEngine` is the detected option ingress.

Conflicting artifact checkpoint:

- `broadcast/DeployCore.s.sol/84532/run-latest.json` contains a later, separate core deployment with `MarginEngine` `0x4034e1e6ca70bcb8ca73c73d651683bc84b9d79b` and `OptionProductRegistry` `0x546ae8820f569d49c5df9039b9ed94c41982b0ca`.
- The later `DeployCore` stack is not the stack used by latest `WireCore`, `ConfigureCore`, or `ConfigureMarkets` artifacts.
- Manual checkpoint: choose and record the canonical target stack in a filled manifest before any `OptionMatchingEngine` deployment.

Detected testnet mock support artifacts:

- Mock USDC: `0x6eae407f5640b006fac9965182e238582a3b412e`
- Mock WETH: `0x4deebc5f537f3b8ba0e3393807b4d699d72bdd02`
- Mock WBTC: `0x9d871ac7595e8da271e866608e5145252047967c`
- ETH primary mock source: `0x3eb9cdd2c2115c3f0df5e30da53d7245f9a5f6cc`
- ETH secondary mock source: `0x2103a84c0cab9cf7680d602c8931faded7064517`
- BTC primary mock source: `0x8cba01b3f4e818ffffd6c1ae1f9a18a656e918bb`
- BTC secondary mock source: `0x7206e7c2c1c3d6e6273020163eb1f0e9339b970c`

## Required Env Vars

Common operator env:

- `RPC_URL`
- `CHAIN_ID=84532`
- `DEPLOYER_PRIVATE_KEY` for state-changing scripts only. Never print or commit it.
- `DEPLOYER_ADDRESS`
- `INITIAL_OWNER`
- `INITIAL_GUARDIAN`

`DeployOptionMatchingEngine.s.sol`:

- `DEPLOYER_PRIVATE_KEY`
- `INITIAL_OWNER` optional in script, but should be set explicitly for preflight
- `MARGIN_ENGINE`
- `OPTION_PRODUCT_REGISTRY`

`WireCore.s.sol`:

- `DEPLOYER_PRIVATE_KEY`
- `INITIAL_GUARDIAN` optional in script, but should be set explicitly
- `COLLATERAL_VAULT`
- `RISK_MODULE`
- `MARGIN_ENGINE`
- `PERP_ENGINE`
- `PERP_RISK_MODULE`
- `ORACLE_ROUTER`
- `COLLATERAL_SEIZER`
- `FEES_MANAGER`
- `INSURANCE_FUND`
- `MATCHING_ENGINE`
- `OPTION_MATCHING_ENGINE_ADDR`
- `PERP_MATCHING_ENGINE`
- `OPTION_PRODUCT_REGISTRY`

`VerifyDeployment.s.sol` core and config requirements:

- All `WireCore` addresses plus `PROTOCOL_TIMELOCK`, `RISK_GOVERNOR`, `BASE_COLLATERAL_TOKEN`, `ETH_UNDERLYING`, and `BTC_UNDERLYING`
- Core params: `BASE_COLLATERAL_DECIMALS`, `BASE_MAINTENANCE_MARGIN_PER_CONTRACT_BASE`, `IM_FACTOR_BPS`, `ORACLE_DOWN_MM_MULTIPLIER_BPS`, `RISK_MAX_ORACLE_DELAY`, `PERP_RISK_MAX_ORACLE_DELAY`, `COLLATERAL_RESTRICTION_MODE`, `ORACLE_ROUTER_MAX_DELAY`, `FEE_BPS_CAP`, and default fee vars
- Collateral arrays: `COLLATERAL_TOKENS`, `COLLATERAL_DECIMALS`, `COLLATERAL_FACTORS_BPS`, `COLLATERAL_WEIGHTS_BPS`, `COLLATERAL_DEPOSIT_CAPS`, `COLLATERAL_LAUNCH_ACTIVE`, `COLLATERAL_RISK_ENABLED`, `INSURANCE_TOKEN_ALLOWED`
- Oracle feed vars for `ETH_USDC_*` and `BTC_USDC_*`
- Option vars for `ETH_OPTION_*`, `BTC_OPTION_*`, `ETH_OPTION_SERIES_*`, and `BTC_OPTION_SERIES_*`
- Perp vars for `ETH_PERP_*` and `BTC_PERP_*`
- Optional option matching checks: `OPTION_MATCHING_ENGINE_OWNER`, `OPTION_MATCHING_EXECUTOR`, `OPTION_MATCHING_EXECUTORS`, `OPTION_MATCHING_EXECUTOR_ALLOWED`

Ownership scripts if handoff is performed later:

- `GOVERNANCE_OWNER`
- `TIMELOCK_OWNER`
- `RISK_GOVERNOR_OWNER`
- `FINAL_GOVERNANCE_OWNER`
- `GOVERNANCE_GUARDIAN`
- `TIMELOCK_PROPOSERS`
- `TIMELOCK_PROPOSER_ALLOWED`
- `TIMELOCK_EXECUTORS`
- `TIMELOCK_EXECUTOR_ALLOWED`
- `MATCHING_EXECUTORS`
- `MATCHING_EXECUTOR_ALLOWED`
- `OPTION_MATCHING_EXECUTORS` and `OPTION_MATCHING_EXECUTOR_ALLOWED` when `OPTION_MATCHING_ENGINE_ADDR` is nonzero
- `PERP_MATCHING_EXECUTORS`
- `PERP_MATCHING_EXECUTOR_ALLOWED`
- Optional `PRICE_SOURCES` and `PRICE_SOURCE_OWNERS`

## Missing Env Vars / Information

Missing from committed files because only examples/templates are present:

- Filled, reviewed Base Sepolia manifest selecting the canonical target stack.
- Filled `.env.base-sepolia` values. The examples still contain `REQUIRED_*` and `FILL_*` placeholders.
- The intended `OPTION_MATCHING_ENGINE_ADDR`, because it has not been deployed.
- Expected `OPTION_MATCHING_ENGINE_OWNER` for verification.
- Intended `OPTION_MATCHING_EXECUTOR` or executor array for post-deploy operation.
- Whether the deployer still owns every module touched by `WireCore`. If not, wiring requires the current owner or an approved timelock/governance path.
- Confirmation whether the existing wired stack or the later `DeployCore` stack is the deployment target.
- Fresh post-deploy `VerifyDeployment.s.sol` result for the selected target stack.

## Safe Commands Prepared

No-RPC validation, safe to run without env or private keys:

```bash
forge fmt --check
forge build
forge test
```

Read-only script help, safe to run without env or private keys:

```bash
forge script script/DeployOptionMatchingEngine.s.sol --help
forge script script/WireCore.s.sol --help
forge script script/VerifyDeployment.s.sol --help
```

Manual operator dry-run commands. These omit `--broadcast`, but `DeployOptionMatchingEngine` and `WireCore` still read `DEPLOYER_PRIVATE_KEY` because the scripts use `vm.startBroadcast`. Run only in an operator shell with a reviewed env and never print secrets:

```bash
set -a
source .env.base-sepolia
set +a

forge script script/DeployOptionMatchingEngine.s.sol --rpc-url "$RPC_URL"
forge script script/WireCore.s.sol --rpc-url "$RPC_URL"
forge script script/VerifyDeployment.s.sol --rpc-url "$RPC_URL"
```

For the existing wired stack, populate at minimum before dry-run:

```bash
MARGIN_ENGINE=0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8
OPTION_PRODUCT_REGISTRY=0x3d52b033fab00ed6104dd3bc0a715f8648344eca
OPTION_MATCHING_ENGINE_ADDR=<new OptionMatchingEngine address after deployment>
```

## Dangerous Manual Broadcast Commands

Manual only. These mutate Base Sepolia. Do not run as validation.

```bash
set -a
source .env.base-sepolia
set +a

forge script script/DeployOptionMatchingEngine.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify

forge script script/WireCore.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Optional ownership and executor handoff after verification, manual only:

```bash
forge script script/TransferOwnerships.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast

forge script script/AcceptOwnerships.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast
```

## Post-Broadcast Verification Commands

Run after any manual broadcast and after refreshing mock feeds if their `maxDelay` is tight:

```bash
forge script script/VerifyDeployment.s.sol --rpc-url "$RPC_URL"
```

Additional read-only checks to run with the filled manifest values:

```bash
cast call "$OPTION_MATCHING_ENGINE_ADDR" "owner()(address)" --rpc-url "$RPC_URL"
cast call "$OPTION_MATCHING_ENGINE_ADDR" "marginEngine()(address)" --rpc-url "$RPC_URL"
cast call "$OPTION_MATCHING_ENGINE_ADDR" "optionRegistry()(address)" --rpc-url "$RPC_URL"
cast call "$OPTION_MATCHING_ENGINE_ADDR" "domainSeparatorV4()(bytes32)" --rpc-url "$RPC_URL"
cast call "$MARGIN_ENGINE" "matchingEngine()(address)" --rpc-url "$RPC_URL"
cast call "$OPTION_MATCHING_ENGINE_ADDR" "isExecutor(address)(bool)" "$OPTION_MATCHING_EXECUTOR" --rpc-url "$RPC_URL"
```

Expected post-broadcast assertions:

- `OptionMatchingEngine.owner()` equals the intended bootstrap owner before handoff or final protocol owner after handoff.
- `OptionMatchingEngine.marginEngine()` equals the selected `MARGIN_ENGINE`.
- `OptionMatchingEngine.optionRegistry()` equals the selected `OPTION_PRODUCT_REGISTRY`.
- `MarginEngine.matchingEngine()` equals `OPTION_MATCHING_ENGINE_ADDR`.
- Expected option executor addresses are allowed.
- `VerifyDeployment.s.sol` prints `DeOpt v2 deployment verification OK`.

## Expected Artifacts / Addresses To Capture

Capture in the filled manifest:

- Target stack decision: wired stack vs later `DeployCore` stack.
- `OPTION_MATCHING_ENGINE_ADDR`
- `DeployOptionMatchingEngine` tx hash, block number, deployer, constructor args, and explorer verification status.
- Updated `WireCore` tx hashes and block numbers.
- `MarginEngine.matchingEngine` before and after wiring.
- `OptionMatchingEngine.owner`, `pendingOwner`, `guardian`, `marginEngine`, `optionRegistry`, `paused`, and executor allowlist.
- EIP-712 domain values: name `DeOptV2-OptionMatchingEngine`, version `1`, chain id `84532`, verifying contract `OPTION_MATCHING_ENGINE_ADDR`, and `domainSeparatorV4`.
- Post-broadcast `VerifyDeployment.s.sol` status, block number, timestamp, and reviewer.
- Backend handoff status and exact config values listed below.

## Backend Follow-Up Config Values

Do not enable backend execution until deployment, wiring, verification, and executor authorization are complete.

- `OPTION_MATCHING_ENGINE_ADDRESS=<OPTION_MATCHING_ENGINE_ADDR>`
- `OPTION_EXECUTION_EIP712` verifying contract: `<OPTION_MATCHING_ENGINE_ADDR>`
- EIP-712 domain name: `DeOptV2-OptionMatchingEngine`
- EIP-712 domain version: `1`
- EIP-712 chain id: `84532`
- `OPTION_NONCE_SYNC`: keep disabled until backend can read `nonces(address)` from `OPTION_MATCHING_ENGINE_ADDR`; then enable against the verified address.
- `OPTION_EXECUTION_SIMULATION`: keep disabled until backend simulation targets the verified `OPTION_MATCHING_ENGINE_ADDR` and current `MarginEngine.matchingEngine` equals that address.

## Risks / Manual Checkpoints

- Choose one canonical Base Sepolia target stack before any future deployment. The latest `DeployCore` artifact conflicts with the stack used by the latest wiring/configuration artifacts.
- Confirm `MARGIN_ENGINE` and `OPTION_PRODUCT_REGISTRY` belong to the same target stack before deploying `OptionMatchingEngine`.
- Confirm the caller has owner authority for every module `WireCore` mutates. `WireCore` is not option-only; it rewires multiple module pointers and guardians.
- Confirm replacing legacy `MatchingEngine` is intended. When `OPTION_MATCHING_ENGINE_ADDR` is nonzero, `WireCore` makes `OptionMatchingEngine` the sole authorized option ingress for `MarginEngine.applyTrade`.
- Confirm option series stay inactive until after verification, handoff, executor authorization, backend nonce sync, backend simulation, and monitoring are ready.
- Confirm `OPTION_MATCHING_EXECUTORS` and `OPTION_MATCHING_EXECUTOR_ALLOWED` are set before ownership handoff if executor setup should be included in `TransferOwnerships`.
- If ownership has already moved away from the deployer, do not use deployer-only commands for wiring or executor setup. Use the approved owner or timelock path.
- Do not activate backend option execution until `VerifyDeployment.s.sol` passes and backend EIP-712 domain/config values match the manifest.

## Validation Results

- `forge fmt --check`: passed
- `forge build`: passed with existing compiler warnings/lint notes
- `forge test`: passed, 179 tests passed, 0 failed, 0 skipped
