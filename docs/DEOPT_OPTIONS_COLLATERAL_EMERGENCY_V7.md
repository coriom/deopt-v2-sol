# DEOPT_OPTIONS_COLLATERAL_EMERGENCY_V7

Read-only snapshot: Base Sepolia chain 84532, block **55,041,332** (`0x9b564eb1555b83897087d3d3f50607b53c0ef3ff877713f23c3c53ba082d4fcc`). The script `tools/options_v7_readonly_preflight.py` uses only `RPC_URL`, pins all reads to one block, and prints no signer material. No public-chain transaction, contract deployment, Safe signature, hosted change or GitHub push occurred.

## Collateral architecture and replacement decision

| Component | Observed live address | Evidence |
| --- | --- | --- |
| CollateralVault | `0x00340c360353a5ab784c5bc5c44322a6af0625d3` | 15,664 runtime bytes; SHA-256 `ad5e47f340d0ce48046ac90a854587cd2d2d4e2c63efc87c0fb2c8dcd57fbe6c`; ERC-1967 implementation, admin and beacon slots empty; no EIP-1167 minimal-proxy prefix. |
| MarginEngine | `0x506cd65a63c53c66ab572b9f9dd819b7bfe00d30` | `vault.marginEngine` and engine dependency reads agree. |
| RiskModule | `0xc0f019005a25524a34f2ee8839dcdcc50715dd7b` | `vault.riskModule` and `engine.riskModule` agree before intervention. |
| OptionProductRegistry | `0x3d52b033fab00ed6104dd3bc0a715f8648344eca` | `engine.optionRegistry` agrees. |
| OptionMatchingEngine | `0x5a5ebf9a9ccd7c012518569de8283982982670f6` | Active `engine.matchingEngine` pointer. |

The Vault's constructor-based source and runtime shape support **non-upgradeable** treatment. Empty ERC-1967 slots alone are not a universal proof of non-upgradeability, so no upgrade transaction is proposed. The Vault has **224,066,000,000 native units of six-decimal mUSDC** in accounting, equal to its token balance at the pinned block. The ETH Call series has **7 short contracts open**; the BTC Call has zero and is inactive. No Put appears in `getAllOptionIds`. Two previously documented test accounts still hold `+4` and `-4` contracts, with vault balances 1,500,999,893 and 1,503,000,053 native units respectively. This is a snapshot, not an exhaustive per-account balance enumeration.

1. **Upgrade existing Vault:** unavailable on the observed contract; no proxy slots or upgrade path was demonstrated.
2. **Replace Vault:** requires explicit migration of 224,066,000,000 native units, user balances, open positions, yield/engine relationships and permissions. It is not a configuration change and is rejected for this release.
3. **Use the existing Vault risk hook:** selected. The deployed Vault calls `getWithdrawableAmount(trader,token)` on its configurable risk-module pointer for every path through `_withdrawInternal`. The new `OptionWithdrawalRiskGate` delegates to the original RiskModule, checks live Engine/Risk/Registry/Oracle wiring, requires fresh positive prices for all open series, and allows only a bound whose full withdrawal passes the original risk preview and liquidation threshold. It holds no assets. The Engine and other consumers keep the original RiskModule.

On a fork of the pinned live bytecode and state, an impersonated Timelock owner switched only `Vault.riskModule` to the adapter. Vault accounting, token balance and the `-4` short position remained unchanged. Invalid oracle readings blocked direct `withdraw`, engine `withdrawFor`, and `transferFromInternalAccount`; a short account's excess withdrawal failed; a long account's safe one-unit withdrawal succeeded. An unauthorized internal transfer and unauthorized adapter installation failed. Wiring drift failed closed. The guardian's existing `pauseWithdrawals` stopped withdrawals before the governance switch. These are **fork simulations**, not Safe approvals or Base Sepolia transactions.

The Vault is shared with other protocol components. The adapter delegates ordinary risk calculations to the original module, but a live activation must also prove representative non-Options withdrawals, fee-account behavior, and any strategy or insurance paths under the exact proposed configuration. The fork checks above do not establish that wider compatibility. The engine-only `transferBetweenAccounts` path is not a withdrawal and does not invoke this adapter; it remains protected by its separate caller restriction and protocol rules.

The adapter bounds its per-account oracle scan at 64 series. Exceeding that bound fails closed and can prevent a legitimate withdrawal; the currently observed Registry has only two series. Reassess this operational limit before listing many additional series.

Proposed activation, only after separate approval: fresh pinned-block preflight and bytecode/source verification; guardian freeze of withdrawals if incident risk warrants it; deploy immutable adapter with the five reviewed dependencies; queue and execute **only** `Vault.setRiskModule(adapter)` through its owner Timelock; verify pointer, current totals, positions, all withdrawal paths and unrelated RiskModule consumers; owner unpauses after postflight. The Timelock's observed `minDelay` is **86,400 seconds**. Retain original RiskModule address for an owner-controlled rollback of the pointer, but freeze withdrawals again before any rollback that could remove the guard. No user collateral or position should move. A new preflight is mandatory at execution time; the snapshot above will age.

## Oracle outage and emergency settlement

| Operation | Fail-closed policy |
| --- | --- |
| Open/increase and all negotiated trades | Block without a valid fresh OracleRouter price. The current matching path cannot prove a reduction is harmless for both counterparties, fees and collateral; no reduction bypass is enabled. |
| Cancel an unfilled nonce | Remains available without a price, since it does not increase obligations. |
| Deposit | Remains possible subject to token/pauses; no withdrawal right is inferred from deposit. |
| Withdraw | Adapter returns no authority if any open series lacks a positive, fresh, non-future safe price, or if original risk preview fails. Guardian may freeze all withdrawals while awaiting Timelock action. |
| Expire | Time may pass, but no arbitrary cash settlement follows merely from expiry. |
| Exercise/settle | Require a Registry final price. With no verified reference at expiry, obligations remain pending; no automatic last-known price. |

**Selected emergency policy:** defer settlement until a historically verifiable reference for the actual expiry can be assembled and approved. For the currently configured Chainlink/Pyth pair, an evidence package must identify series/expiry, canonical chain block, Chainlink aggregator round and `updatedAt`, Pyth feed ID and signed historical update/publish time, units, asset/quote identities, source independence, freshness, deviation and any unavailable feed. Chainlink documents `getRoundData` for historical rounds; Pyth documents timestamped signed updates, but availability for a particular expiry is **not yet proven**. Existing live OracleRouter limits are 1,500 seconds and 100 bps; applying them to historical settlement is a proposed rule, not an approved financial parameter. If a reliable historical reference cannot be established, keep settlement pending and seek a distinct governance decision; do not substitute a current spot price.

At the pinned block, ETH source adapters are Chainlink `0x09bcd126feb91e13007b2c69644c12ab56260473` and Pyth `0x1a6302edc9e9dc5efae8dd5e931089ac6dc5322b`. BTC source adapters are `0x78bfe7a71bd7c39d53d71b8a688bfb4afb216867` and `0x690821211ca653b966db07ded385cfa4c547a6c2`. The ETH Pyth feed ID is `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace`; BTC is `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`. The live configuration supersedes the manifest's old mock-feed entries. These are source identities, not a claim that a valid historical expiry price exists.

The adapters expose Chainlink aggregators `0x4adc67696ba383f43dd60a9e78f2c97fbbfc7cb1` (ETH) and `0x0fb99723aee6f420bead13e6bbb79b7e6f034298` (BTC), both configured with eight decimals; both Pyth adapters point to `0x5f52e4dbea21f5b23523b6e20d50c29ae0a4eb83`. At the same block, the ETH adapter updates were 678 and 221 seconds old, while the BTC Pyth update was 10,654 seconds old, exceeding the live 1,500-second limit. This illustrates why source presence alone is not a valid settlement reference.

`OptionProductRegistry` currently has owner `0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588` (ProtocolTimelock), no settlement operator, `settlementFinalityDelay=0`, and settlement unpaused. Its two-phase path can propose, cancel and finalize after a configurable delay up to seven days. A Foundry negative control demonstrated that the Registry will finalize an arbitrary positive value (`1`) after that delay: **source verification is not enforced on-chain**. A separate test showed unauthorized proposal rejection, cancellation, refusal to finalize before the test delay, and no double account settlement. For meaningful contestability, the operator must approve a delay **strictly longer than the Timelock's one-day minimum plus the time needed to detect, queue and execute a challenge**, within the contract's seven-day cap. No numeric delay, emergency price source, or new operator power is chosen here. A governance process alone does not make an incorrect price impossible; until the evidence rule and challenge path are approved, emergency price verification is BLOCKED.

The deployed cancellation function is restricted to the owner or settlement operator and also requires settlement operations to be unpaused. Pausing settlement therefore does **not** itself provide a working cancellation path. Any challenge procedure must verify the live role and pause state before relying on cancellation; otherwise the safest response is to leave settlement pending and seek a separately authorized contract change.

The alternative of a secondary source alone is insufficient if its historical update cannot be authenticated and compared at expiry. An exceptional Safe/Timelock price remains a last-resort governance action requiring separate approval, traceable evidence, an opportunity to contest, and explicit treatment of buyers' and sellers' claims. The currently deployed Registry cannot cryptographically enforce those conditions; a stronger on-chain attestation design would require a separately reviewed contract and migration/ownership decision.

## Reproduction and release gates

```bash
cd /home/corio/DEOPT/deopt-v2-sol
python3 tools/options_v7_readonly_preflight.py 0x77cA9DD6cCce2D692FB23877a2db7178807b0020 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274
python3 tools/options_v7_readonly_preflight.py --fork-test
forge test --match-path test/scenario/options/OptionSettlementFlow.t.sol -q
forge build --skip test -j 1
```

The fork test fixes block 55,041,332. It impersonates owner/guardian only inside Foundry and uses deterministic oracle responses to exercise failure and recovery, including stale and future timestamps. Four fork tests and the settlement scenario passed. The source build passed with existing repository warnings. A full test-inclusive `forge build` was stopped after heavy WSL memory use; it is not claimed as passing. The local scenario uses a test-only one-day finality delay and deterministic prices; it does not recommend that delay for the live Registry. No full browser E2E was repeated because the new adapter is not part of the V6 local product runner. Official references: [OpenZeppelin proxy storage](https://docs.openzeppelin.com/contracts/5.x/api/proxy), [Chainlink historical rounds](https://docs.chain.link/data-feeds/price-feeds/historical-data), [Pyth timestamped updates](https://docs.pyth.network/api-reference/hermes/price-updates-at-time).

| Required verdict | Result | Evidence / remaining gate |
| --- | --- | --- |
| `DEPLOYED_CONTRACT_ARCHITECTURE` | PARTIAL | Pinned live bytecode hash, pointers, admin slots and owner read; exact historical source-to-bytecode match was not established. No upgrade path is demonstrated. |
| `WITHDRAWAL_GUARD_COMPATIBILITY` | PARTIAL | Existing Vault risk hook accepts adapter on fork; tested withdrawal ingress paths fail closed. Shared Vault paths outside Options still require representative regression checks before live activation. |
| `EXISTING_POSITION_AND_COLLATERAL_STATE` | PARTIAL | Aggregate 224,066,000,000 native mUSDC and 7 short contracts; holder list not exhaustive. |
| `SAFE_MIGRATION_STRATEGY` | PARTIAL | Risk-pointer adapter avoids moving assets or rebuilding positions; fork preservation and rollback tested only locally. |
| `ORACLE_OUTAGE_POLICY` | PARTIAL | Fail-closed operations defined and tested locally; no safe close-only path. |
| `EMERGENCY_SETTLEMENT_DESIGN` | PARTIAL | Delayed historical reference selected; evidentiary and dispute parameters require approval. |
| `EMERGENCY_PRICE_VERIFICATION` | BLOCKED | Current Registry accepts any positive governed price; no expiry-specific historical reference has yet been verified. |
| `ECONOMIC_SECURITY_TESTS` | PARTIAL | Guard, ACL, delay, cancellation and double-settlement tests pass; arbitrary-price negative control proves remaining gap. |
| `COLLATERAL_PRESERVATION` | PASS | On fork, adapter installation leaves current Vault, token balance, accounting and positions unchanged. |
| `FORK_SIMULATION` | PASS | Four tests on pinned live state; no public transaction. |
| `BASE_SEPOLIA_RELEASE_PLAN` | PARTIAL | Adapter activation sequence ready; settlement rule and live Safe/Timelock actions require fresh preflight and separate approval. |
| `REMAINING_OPERATOR_DECISIONS` | BLOCKED | Approve historical reference methodology, challenge window, fallback for missing history and later distinct Safe transactions. |
| `GIT_STATUS` | PASS | Solidity V7 changes committed locally after targeted tests; no push. Backend and frontend remain unchanged. |

**Recommendation: NO-GO for economic launch.** Use the risk-pointer adapter architecture for collateral protection, while leaving price settlement pending until independent historical evidence and a challenge process have been approved. The next concrete operation is a focused operator decision on those two governance parameters; only then prepare a separately authorized adapter deployment and Timelock pointer update. No existing position, fund or oracle is changed by this report.
