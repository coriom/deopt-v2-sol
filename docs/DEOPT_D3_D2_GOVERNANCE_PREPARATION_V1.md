# DeOpt D3 token and D2 fee policy preparation

## Scope and evidence

This is an offline preparation review on Base Sepolia (84532). Public RPC reads
were pinned to block **49,914,620**, hash
`0x5f36f967fa929392e1f7d02c9b36424e5ed4f151415144c55680ce8da2b11f34`
(2026-10-25 05:06:32 UTC). D2/D3 deployed runtime hashes matched the
approved roadmap. The frozen D2/D3 Solidity files match revision
`25c36670883604c1ef5229642ee6548aea6796c3`. The approved dependency DAG
was read unchanged. These are pinned observations, not a promise about later
blocks.

The D4 trading, liquidation, funding and collateral-operations flags all read
`true`; migration is OPEN, D6 is paused, and D4 has no Vault engine or
Insurance backstop authorization. D4's D3 and D2 pointers remain zero, and
`useFeesManagerV2` remains false. C02's execution remains outside this review.

## D3: CollateralSeizer token policy — REQUIRES_DECISION

The Vault lists only mUSDC (`0x6eAe407f5640B006faC9965182e238582A3B412E`)
as supported collateral: 6 decimals, 10,000 bps collateral factor. The D1
settlement allowlist also includes mUSDC. D3 points to the historical RiskModule,
whose mUSDC weight is 10,000 bps and enabled. D3's mUSDC `seizeConfigs` reads
`(spread=0, enabled=false, isSet=false)`. **Unset is treated as enabled with zero
spread**, so the current effective discount is 10,000 bps. D3 oracle freshness
limit is 600 seconds. The base token does not require a cross-token price; any
future non-base token needs a supported Vault config and a fresh, safe oracle
price. A zero weight or disabled policy yields no seizure value.

The setter is `setTokenSeizeConfig(address,uint16,bool)` (`0x20366617`),
owner-only. It checks nonzero token and spread at most 10,000 bps, but does
**not** require Vault support at configuration time. Fork tests confirmed that
an unsupported token can be marked configured while valuation rejects it.
They also covered unauthorized caller, zero token, out-of-range spread, and a
synthetic valid mUSDC setup. The 5 bps test vector is **not a proposal**.

**Compatibility blocker for downstream D3_RISK:** D3 calls
`collateralConfigs(address)` on its risk pointer. Deployed D5 does not expose
that getter; an on-chain read reverted, and an isolated fork confirmed that
locally pointing D3 at D5 makes `tokenDiscountBps(mUSDC)` revert. The approved
DAG's D3_RISK and C13 steps require a separately reviewed compatible design.
Do not wire D3 to D5 from the existing manifest as-is.

The operator's shortest D3 decision is to approve **whether mUSDC seizure is
enabled and the exact spread in bps**, together with a compatibility resolution
for the later D3_RISK step. A source comment's example stable spread range is
not an approved policy. Until then, keep D4 liquidation paused and D3 unwired
from D4. No C12-style Safe or Timelock candidate was generated.

## D2: FeesManagerV2 fee policy — REQUIRES_DECISION

D2's live OPTION/PERP fee profiles and RFQ discounts match its constructor's
five-tier launch schedules; exact values are in the versioned JSON evidence.
The owner and fee recipient are ProtocolTimelock. The Merkle root and validity
window, ProtocolFeeVault pointer, rebate funding account, and mUSDC rebate
budget are zero. D4 is not a fee consumer and has no D2 pointer. Positive fees
would route to the current recipient; nonzero rebates cannot be consumed with
the funding account unset. Optional fee-vault hooks are disabled at zero.

The legacy FeesManagerV2 remains separate at
`0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f`. At the pinned block its
mUSDC rebate-budget ledger was **999,977**, its existing Merkle root was
nonzero, and its root window ended at 1781913600. These historical claims and
balances must stay on the legacy manager. The new D2 ledger is zero; an
isolated fork fee-profile change left the legacy budget unchanged. D2
`fundRebateBudget` changes accounting only and must not be mistaken for an
ERC20 funding transfer. D4's consumer permission was checked; the full set of
other possible consumers is not enumerable from the mapping in this review.

The operator's shortest D2 decision is to approve **the launch fee/rebate
schedule and fee recipient**, then separately choose the fee vault/Insurance
routing, rebate backing and claims policy. Current constructor values are a
safe no-change planning posture, not approval to enable D2. No fee setter,
consumer grant, C14/C15 operation, Safe intent or Timelock calldata was
promoted.

## Governance and test boundary

The approved DAG requires maintenance for D3_TOKEN and D2_FEE_POLICY.
D3_TOKEN precedes D3_RISK and C13; D2_FEE_POLICY precedes C24 and C14, then
C15. Each eventual state-changing action needs its own exact-parameter review,
Safe 2/3 approval, custom Timelock delay, public postflight, and fresh D4/D6
maintenance checks. Neither policy is ready for unsigned transaction packaging.

The focused isolated-fork suite in
`test/fork/DeoptD3D2PolicyFork.t.sol` passed **6/6** tests at the pinned block
using `forge test -j 1`. It impersonated ProtocolTimelock locally and did not
test genuine Safe signatures. No public transaction, fee transfer, liquidation,
migration or trading was performed. Full repository tests were not run.

Evidence: `d3_token_policy_preparation_v1.json` and
`d2_fee_policy_preparation_v1.json` in the replacement-deployment artifact
directory. Their live readbacks are bounded getter evidence, not exhaustive
storage verification.
