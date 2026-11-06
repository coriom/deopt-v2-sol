# DEOPT_OPTIONS_BASE_SEPOLIA_RELEASE_READY_V14

2026-11-06. Scope: a dedicated Options Call stack for a closed Base Sepolia beta using test assets. This document records local and read-only fork evidence. It does not authorize deployment, funding, trading, a Safe signature, or a public release.

## Economic policy accepted for this testnet experiment

Historical Chainlink is primary; authenticated Pyth Core is secondary. The admissible boundary is 1,500 seconds before and after expiry, with at most 100 bps deviation and 100 bps Pyth confidence. The challenge period is a fixed 48 hours. When two admissible proofs diverge above 100 bps, automatic settlement stops. With no admissible proof, settlement remains pending; there is no administrator-selected price. This can lock positions and collateral indefinitely. The acceptance does not extend to public beta or mainnet.

The live risk OracleRouter and the historical settlement verifier have different jobs. The Router may accept one fresh source when the other is stale; that is not a two-source historical settlement proof. Initial release scope is ETH Call only. No BTC series is approved by this package.

## Read-only Base Sepolia evidence

- Chain ID 84532. Live oracle snapshot: block 55,171,429, timestamp 1,793,956,154. ETH Chainlink `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1`: bytecode present, 8 decimals, round `18446744073709842536`, updated 77 seconds before the block. The previous round was 230 seconds earlier. ETH Pyth Core `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83`, feed ID `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`: on-chain price updated 95 seconds before the block, confidence about 10 bps. The ETH sources differed by about 2.9 bps at this snapshot.
- BTC Chainlink `0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298`: 8 decimals, updated 101 seconds before the block. BTC Pyth feed `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` was 15,006 seconds old, outside the accepted 1,500-second window. The BTC Router returned `ok=true` using the fresh Chainlink source. This does not qualify BTC for the initial dual-source risk policy.
- At block 55,171,680, the existing OracleRouter `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` had active ETH/BTC feeds, max delay 1,500 seconds and deviation 100 bps. ETH source wrappers `0x09bcd126feb91e13007b2c69644c12ab56260473` and `0x1a6302edc9e9dc5efae8dd5e931089ac6dc5322b` pointed to the above Chainlink aggregator and Pyth Core/feed ID respectively. Their runtime code was present and their underlying pointers were read at block 55,172,044. Reusing these *read-only wrappers* for the new Router does not give the new stack access to the historical Vault.
- At block 55,173,161, the deployed Timelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` had a 86,400-second minimum delay; OPS Safe `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` was proposer and executor, threshold 2, observed nonce 43. All role and nonce facts require a fresh read immediately before any future transaction.
- The eight targeted fork tests in `test/fork/VerifiedOptionSettlementOwnerFork.t.sol` passed against pinned historical blocks. They include real Chainlink rounds, an authenticated Pyth Core payload, dispute behavior, Registry recovery and preservation of seven historical shorts and Vault balances. The fixture proves a particular historical payload, not future payload availability at a new expiry.

## Local implementation and checks

`script/DeployOptionsIsolatedV14.s.sol` creates nine new contracts by digest-independent CREATE order: OracleRouter, CollateralVault, OptionProductRegistry, MarginEngine, RiskModule, OptionMatchingEngine, FeesManagerV2, InsuranceFund and VerifiedOptionSettlementOwner. It requires chain 84532, presence of dependencies, and an explicit release flag. It creates no series, grants no matching executor, moves no collateral, and leaves the historical stack untouched. The flag is for a separately authorized future deployment; do not add `--broadcast` under this release gate.

The dry-run fork of Base Sepolia completed successfully with no public transaction. At block 55,176,381 the deployment address `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` had pending nonce 812. Conditional CREATE predictions, in deployment order, were:

| Contract | Address if nonce 812 is unchanged |
| --- | --- |
| OracleRouter | `0xcb7bc539ed4A5771F3420f498002e0fc4eE1bD27` |
| CollateralVault | `0x2C4589c88323009db372B4067702e6292ddD294C` |
| OptionProductRegistry | `0x63DE63912BB6743F72ea77847572503Cc93B7d80` |
| MarginEngine | `0xDbbfcE4b1fe6d78dE94084499A871b2BE62E2474` |
| RiskModule | `0x1a8Dc1E8C287199aB7E30241F4556cFCe78f386b` |
| OptionMatchingEngine | `0x81012092ecbB082F928C9D047280eC491f298A16` |
| FeesManagerV2 | `0xc3c813C801621e8aDEBE47bb74FB463c3ecE21A1` |
| InsuranceFund | `0xe92cd4659eA120F7b2A44d7CB6e62755A93ada95` |
| VerifiedOptionSettlementOwner | `0x064541c40FC80e7A6E9C192c8f401Ef043D191CF` |

The fork simulation printed the same addresses. These predictions expire when the deployer sends any transaction. A later deployment requires a fresh nonce, bytecode and gas check. The fork estimated 39,637,370 gas for the nine CREATE transactions, or about 0.000436 ETH at its 0.011 gwei fee estimate. This excludes Timelock scheduling and execution, configuration, verifier handoff, series creation, user funding, and test trades. It is not a spending authorization or a final gas budget. The MarginEngine runtime artifact is 24,463 bytes, 113 bytes below the EIP-170 limit; any bytecode change requires recompilation and a fresh size check.

The four focused tests in `DedicatedOptionsStackV14.t.sol` cover two signed fills, premium and fee conservation, expiry settlement, fail-closed dual-source outage and divergence, and liquidation under a real RiskModule/InsuranceFund with preservation of Vault assets. Their feeds and token are deterministic local fixtures, not Base Sepolia prices. The eight historical fork tests use real network state. The V14 browser bench uses the real product form, Rust handlers, disposable PostgreSQL, OracleRouter with two local sources, actual InsuranceFund, OptionMatchingEngine and VerifiedOptionSettlementOwner. Its last successful run indexed 27 real Anvil events; `PLAYWRIGHT_LIVE_POSITION`, `PLAYWRIGHT_SETTLED_POSITION`, `PLAYWRIGHT_REORG_POSITION_REMOVED`, invalid/stale oracle rejection, insufficient collateral rejection and real reorg orphan removal all passed. Local trade hash: `0x121bebd4b9fed6a756a1d824eeab5271ec4574b4265ca52a254b315e275cbc67`. It is not a Base Sepolia transaction. Two earlier attempts failed from browser timing and a disposable database pool timeout under concurrent load; the quiet rerun passed. These are bench reliability limits, not production proof.

Reproduce the local bench from `deopt-v2-backend`:

```bash
OPTIONS_V13_VERIFIED_SETTLEMENT=1 OPTIONS_V14_ROUTER=1 OPTIONS_V5_PRODUCT=1 OPTIONS_V4_CHAIN_ID=84532 OPTIONS_V4_BROWSER=1 bash scripts/run-options-anvil-indexer-v4.sh
```

Reproduce targeted Solidity checks from `deopt-v2-sol`:

```bash
forge test --match-path test/scenario/options/DedicatedOptionsStackV14.t.sol --threads 2
```

The fork test additionally requires a local `RPC_URL` kept out of Git and logs; `forge test --match-path test/fork/VerifiedOptionSettlementOwnerFork.t.sol --threads 2` is read-only. The deployment dry-run uses `OPTIONS_V14_DEPLOY_ALLOWED=true forge script script/DeployOptionsIsolatedV14.s.sol:DeployOptionsIsolatedV14 --fork-url options_v14 --sender <deployer-address>` without `--broadcast` and with a local, unlogged `RPC_URL`.

## Inert deployment sequence for a later, separate authorization

1. Freeze approved source commit, compiler settings and deployed bytecode hashes. Re-read chain ID, latest block, feed timestamps and confidence, Pyth contract, Timelock roles/delay, Safe threshold/nonce, deployer pending nonce, balance and gas fees. Reject mismatches. No economic services or public routes are enabled.
2. Simulate exactly the nine deployments at the fresh pending nonce, compare computed CREATE addresses with simulation, and verify constructor pointers and policy constants. Request a **separate** deployment authorization. On-chain deployment should stop before funding or series creation; check all nine receipts and runtime code before proceeding.
3. Queue Timelock operations for the new stack only. Configure the new Router with ETH Chainlink/Pyth wrappers, 1,500-second delay and 100-bps divergence. Configure the new Vault for mUSDC only, then connect the new MarginEngine and RiskModule. Configure the new Registry for mUSDC and ETH, new MatchingEngine, FeesManagerV2, InsuranceFund and guardians, matching the local `OptionsLocalAnvilE2E` sequence. Do not authorize any engine on the historical Vault. Every queued calldata, target, eta, hash and Safe nonce must be generated from the *actual deployed addresses* and reviewed before signing. The Timelock minimum delay is one day.
4. Keep matching executor disabled. Pause creation and settlement of the new Registry, verify zero series and zero legacy obligations, then transfer its ownership to the new verifier and call `acceptRegistryOwnership` via Timelock. Check owner, guardian, feed IDs, 48-hour challenge and no arbitrary settlement operator. Test guardian pause and the governed recovery path on a fork of the deployed state.
5. After separate approvals of strike, expiry, Vault deposit cap, short open-interest cap and fee schedule, create one ETH Call **inactive** through the verifier. Confirm it remains inactive. Backend/Frontend can be deployed under disabled economic flags; only then plan an independently authorized activation and one capped test trade. The historical Registry, Vault and seven shorts remain unchanged.
6. If any configuration or reconciliation fails, stop while contracts remain inert. For a later live series, pause new matching/creation and preserve Vault assets and obligations; do not roll back by deleting state or substituting a price. The verifier's recovery path is Timelock governed and its successor bytecode and policy must be rechecked.

## Gates remaining before deployment approval

- Exact Timelock transaction package for all configuration and ownership actions is **not frozen**; actual CREATE addresses and Safe nonces may change. No signed Safe transaction exists.
- A first Call strike, expiry, mUSDC deposit cap, short open-interest cap, and fee schedule require explicit economic approval. The six accepted oracle/challenge values alone do not authorize these values or user funding.
- Backend indexing and catalogue for simultaneous historical and new Registry identities `(registry, option_id)` are not deployed or fully qualified; no Netcup migration or frontend Vercel release occurred in V14.
- ETH Pyth and Chainlink were fresh at the observed block, but future historical Pyth payload availability, future feed freshness, and gas prices cannot be guaranteed. BTC Pyth was stale at observation, so BTC is outside this release scope.

**Decision: NO-GO for requesting execution of the complete Options release.** An inert nine-contract deployment is fork-simulated, but the configuration transaction package, initial series limits and hosted dual-Registry integration must be completed and approved before asking to deploy the full closed-beta stack. No public transaction or hosted change was made.
