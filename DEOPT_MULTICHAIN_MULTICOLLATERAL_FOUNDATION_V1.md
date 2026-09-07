# DEOPT_MULTICHAIN_MULTICOLLATERAL_FOUNDATION_V1 — Solidity layer

## Purpose

Document what the current Solidity layer already guarantees at the
protocol level for a future second EVM chain or additional collateral
asset, and what would still have to change on-chain (as opposed to in
the backend or frontend) before those futures could be activated.

**Runtime posture is unchanged by this milestone.** Base is the only
enabled chain; USDC is the only enabled collateral; the frozen
Base-Sepolia broadcast manifest at `BASE_SEPOLIA_INFRA_BROADCAST_V1.md`
is untouched.

## What is already chain-aware

### SubKey — chain-embedded subaccount identity

`src/hybrid-v2/libraries/SubKey.sol` derives every subaccount handle as
`keccak256(chainId, registry, owner, subaccountId)` via two entry
points:

* `deriveHere(...)` — uses `block.chainid` (on-chain callers).
* `derive(chainId, ...)` — pure form (off-chain deterministic
  reproduction).

Result: the same wallet on Chain A and Chain B produces two distinct
subkeys, so no state slot on either chain can ever be dereferenced by a
subkey computed against the other chain.

### EIP-712 domain — automatic chainId binding

Every intent-signing engine (`OptionMatchingEngineV2`, `MatchingEngine`,
`PerpMatchingEngine`, `OptionMatchingEngine`) inherits OpenZeppelin's
`EIP712` base, which embeds `block.chainid` into the domain separator
at signature-verification time. Signatures produced against a Chain A
domain cannot verify against a Chain B domain even if the intent bytes
are identical.

### Deployment manifest — chainId witness

`src/hybrid-v2/deployment/DeploymentManifestV1.sol` captures
`CHAIN_ID = block.chainid` at construction as an immutable, plus
refuses `block.chainid == 8453` (Base mainnet) at every deployment
site. These are safety guards and MUST NOT be abstracted away.

### Registry — subKey scoping

`SubaccountRegistry.sol` stores `DEPLOYMENT_CHAIN_ID = block.chainid`
at construction (`src/hybrid-v2/registry/SubaccountRegistry.sol:49`)
and uses it in every subkey derivation. A future second-chain
deployment therefore instantiates its own registry and its own subkey
space with no possibility of collision.

## What is already multi-token at the vault layer

`src/collateral/CollateralVault.sol` +
`src/collateral/CollateralVaultStorage.sol` are structured for
arbitrary ERC-20 collateral:

* `mapping(address user => mapping(address token => uint256))
  balances` — per-user, per-token balances.
* `mapping(address token => CollateralTokenConfig)` — per-token
  decimals + configuration.
* `collateralTokens[]` — dynamic list of supported collateral.

`src/risk/RiskModuleCollateral.sol` normalises any token amount to a
base-value scale (1e8) via
`_tokenAmountToBaseValue(token, amount, price1e8)`, reading
`_vaultCfg(token).decimals` from the vault config. There is no
hardcoded USDC 6-decimals literal in the valuation math.

## What is intentionally single-asset at the product layer

`src/hybrid-v2/risk/OptionsRiskModuleV2.sol` and
`src/hybrid-v2/margin/MarginEngineV2.sol` both freeze a single
`QUOTE_TOKEN` as an `immutable` per deployment. Every options series
in a deployment MUST settle in that `QUOTE_TOKEN` (asserted at
`OptionMatchingEngineV2:735-736`), and
`DeploymentManifestV1` cross-validates that the risk module, margin
engine and matching engine all agree on the same `QUOTE_TOKEN`.

This is a deliberate V2 launch invariant, not an oversight. A future
multi-quote deployment would either:

1. Deploy a second full set of engines with a different `QUOTE_TOKEN`
   pinned at construction — no code change required, only a second
   `DeploymentManifestV1`. This is the "additive" path and remains
   safe because engines never share state across manifests.
2. Refactor to a per-series `quoteToken` field — this **would** be a
   protocol rewrite. It is explicitly out of scope for this
   milestone.

## What is out of scope on-chain

Explicitly not shipped on-chain by this milestone (mirrors the
architectural rules stated in the milestone spec):

* No bridge contract.
* No cross-chain messaging (LayerZero / CCIP / …).
* No shared margin across chains.
* No cross-chain liquidation.
* No global cross-chain nonce coordinator.

The economic-isolation rule is enforced by the absence of any
cross-chain state channel — a Chain-A subkey has no representation on
Chain B, so there is nothing on Chain B for a Chain-A subkey to
touch.

## What a future second chain would need on-chain

Given the invariants above, adding e.g. Arbitrum is a **deployment
operation**, not a protocol rewrite:

1. Deploy the full engine set on Arbitrum with the standard Foundry
   scripts.
2. Instantiate a fresh `SubaccountRegistry` (its immutable
   `DEPLOYMENT_CHAIN_ID` will bind to Arbitrum's chain id).
3. Instantiate `OracleRouter` / `MarginEngineV2` / `OptionsRiskModuleV2`
   / `OptionMatchingEngineV2` / `PerpMatchingEngine` with the target
   `QUOTE_TOKEN` on Arbitrum. Every EIP-712 signature is
   automatically Arbitrum-scoped via OZ `EIP712` + `block.chainid`.
4. Register the new deployment in the backend's `ChainConfig` registry
   with `enabled = true` and wire a second `ChainRuntimeHandle`.

No Solidity source change is required for the on-chain layer.

## What a future additional collateral would need on-chain

`CollateralVault` already accepts new tokens via
`addCollateralToken(...)`. The margin path already handles per-token
decimals. What is intentionally not supported today:

* Multi-`QUOTE_TOKEN` per deployment (see above). Adding e.g. WETH as
  a *collateral* backing a USDC-quoted position is supported today at
  the vault + risk layer, but the position's PnL and premium are
  always denominated in the deployment's frozen `QUOTE_TOKEN`.
* Per-token haircut in the vault. The vault today reads a single
  `CollateralTokenConfig` per token; introducing a
  `collateralFactorBps` field would be an additive change and is
  represented as a config field in the backend's
  `CollateralConfig` registry (`crate::config::collateral::WETH.
  collateral_factor_bps = 0`).

## Related files

* Backend registry: `crate::config::chains`, `crate::config::collateral`.
* Backend runtime scaffold: `crate::chain_runtime::ChainRuntimeHandle`.
* Backend safety migration: `migrations/0061_multichain_multicollateral_foundation.sql`.
* Frontend registry: `deopt-v2-frontend/src/lib/chains.ts` (extended
  with per-chain `writeAuthDomain`).
* Frontend write-auth adapter:
  `deopt-v2-frontend/src/lib/write-auth.ts` — now looks the domain up
  from the active chain instead of hard-coding a Base-Sepolia
  literal. Byte-identical for Base Sepolia (asserted by
  `tests/node/write-auth-canonical.contract.mjs`).
