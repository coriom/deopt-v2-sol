# PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1

Design + implementation record for the V2 Perps engine that fixes the
V1 mutual-close realized-PnL double-count bug.

Supersedes the earlier backend-repo doc
`docs/PERPS_CLOSE_PNL_BUG_V2_ACCOUNTING_DESIGN.md` in two important
places:

- adds explicit **clearing vs insurance** distinction
- notes the same double-count bug **also affects liquidation** because
  `liquidate()` reuses `_applyRealizedCashflow` with a synthesized
  liquidator-side realized PnL that is deliberately equal-and-opposite
  to the trader-side. The fix must therefore land in one function that
  serves both `applyTrade` and `liquidate`.

---

## 1. Confirmed Root Cause (V1)

`src/perp/PerpEngineTrading.sol:417-436` (V1):

```solidity
function _applyRealizedCashflow(
    address settlementAsset,
    address buyer,
    address seller,
    int256 buyerRealizedPnl1e8,
    int256 sellerRealizedPnl1e8
) internal {
    int256 netToBuyer1e8 = _checkedSubInt256(buyerRealizedPnl1e8, sellerRealizedPnl1e8);
    if (netToBuyer1e8 == 0) return;

    uint256 absNetNative = _value1e8ToSettlementNative(settlementAsset, _absInt256(netToBuyer1e8));
    if (absNetNative == 0) return;

    if (netToBuyer1e8 > 0) {
        _routeIncomingCashflowWithDebtFirst(settlementAsset, seller, buyer, absNetNative);
    } else {
        _routeIncomingCashflowWithDebtFirst(settlementAsset, buyer, seller, absNetNative);
    }
}
```

For the confirmed Base Sepolia mutual-close case
(buyerRealized = −244_274 raw mUSDC, sellerRealized = +244_274 raw
mUSDC), `netToBuyer = −244_274 − 244_274 = −488_548`. V1 transferred
488_548 buyer → seller. Correct transfer is 244_274. **2× exactly.**

The same call site is reached from `liquidate()` at
`PerpEngineTrading.sol:693-694`:

```solidity
int256 liquidatorRealizedPnl1e8 = 0 - traderRealizedPnl1e8;
_applyRealizedCashflow(m.settlementAsset, liquidator, trader, liquidatorRealizedPnl1e8, traderRealizedPnl1e8);
```

By construction `buyerRealized = −sellerRealized`, so
`netToBuyer = ±2·|traderRealized|`. The liquidation cashflow is
therefore also 2×. V2 fixes both.

## 2. Cases where `buyerRealized + sellerRealized ≠ 0`

A single V2 must cover all six:

1. **Asymmetric historical entry**: two traders with different open
   notional close against each other; the sum reflects the
   entry-price mismatch, not a bug.
2. **Nonzero funding**: `_closedFundingPortion1e8` charges each side
   independently; the sum is a real economic quantity.
3. **Partial closes**: `removedBasis` prorates each side's own
   `openNotional`; independent bases → nonzero sum.
4. **Position flips**: closing beyond zero realizes on the closed
   portion at that side's own basis, opens fresh basis at execution
   price. Independent.
5. **Rounding asymmetry**: 1e8 → mUSDC (1e6) conversion is
   floor-abs; the sum of native conversions may differ from the
   conversion of the sum.
6. **Multi-side effects across the same trade**: e.g. liquidation
   where the trader may realize funding on top of a mark move; the
   synthetic counterparty leg does not.

Peer-to-peer subtraction is provably wrong in every case except
`buyerRealized == −sellerRealized` and cannot be patched by
`max(abs, abs)` (which handles only case (1) with symmetric basis).

## 3. Chosen V2 accounting equation

For each trader independently:

```
realizedPnl1e8 =
    closedMarkValue1e8
  − removedBasis1e8
  − closedFunding1e8
```

Converted to settlement-native per side:

```
realizedNative = _value1e8ToSettlementNative(asset, |realized1e8|)
                 · sign(realized1e8)
```

Conservation invariant for every trade, at native precision:

```
Δvault(buyer)  + Δvault(seller)
+ Δvault(clearing) + Δvault(feeSink)   = 0
```

Isolating realized PnL from fees (V2 keeps fees identical to V1):

```
Δvault(buyer)_realized + Δvault(seller)_realized + Δvault(clearing) = 0
```

Therefore:

```
Δvault(clearing) = −(buyerRealizedNative + sellerRealizedNative)
```

This is the canonical V2 mutation. **No peer-to-peer subtraction.**

## 4. Atomic settlement order (debit-before-credit)

Inside one trade, V2 processes realized PnL in this order:

1. For each trader with `realizedNative < 0`: transfer
   `|realizedNative|` from trader → clearing.
2. For each trader with `realizedNative > 0`: transfer
   `realizedNative` from clearing → trader.

Rationale: losses realized in the same trade fund gains realized in the
same trade before any pre-existing clearing liquidity is required.
Only the **net** deficit (if any) draws from the clearing balance.

**Insufficient-clearing revert**: after step (1), if clearing does not
hold enough native units to satisfy step (2), the entire trade reverts
atomically with a dedicated error `ClearingLiquidityInsufficient()`.
No partial state mutation. No socialized loss. No implicit fallback to
the insurance fund.

## 5. Signed native rounding rule (explicit)

Internal accounting is 1e8; mUSDC settlement is 1e6.

For each trader independently:

```
realizedNativeAbs = floor(|realizedPnl1e8| * 10^decimals / 1e8)
                  = _value1e8ToSettlementNative(asset, |realizedPnl1e8|)
signedNative = sign(realizedPnl1e8) * realizedNativeAbs
```

This is the identical helper V1 uses (`_value1e8ToSettlementNative`),
applied per-side rather than to a peer-to-peer difference. Sub-native
residuals are deterministic and asymmetrically distributed across the
two traders only by their own signs. The clearing account absorbs the
deterministic native-unit difference:

```
Δclearing_rounding
    = −(sign(bR)·floor(|bR|·10^d / 1e8)
      + sign(sR)·floor(|sR|·10^d / 1e8))
```

The residual is bounded by `2 · (10^(-d) native units)` per trade
(one native unit of asymmetric rounding on each of the two sides,
worst case). For mUSDC (d=6), that is at most 2 mUSDC-units per trade.

## 6. Clearing account vs Insurance fund (**mandatory distinction**)

**PerpClearingAccount** (this milestone):

- Deterministic settlement intermediary.
- Receives negative-realized PnL debits; pays positive-realized PnL
  credits.
- Bridges timing differences: A wins vs opener C ↔ paired loser B still
  open with unrealized loss. Clearing pays A now; B's later realized
  loss replenishes clearing.
- Failure = temporary insolvency for a specific market → V2 reverts
  the offending trade; the market becomes untradable on the winning
  side until clearing is topped up.
- Governance-controlled address (any address the vault ACL treats as
  authorised to hold balance; can be an EOA in tests, a
  no-withdraw contract in production).
- Aggregate vault deltas from clearing over the lifetime of a market
  sum to ≤ 0 net (in the ideal case; nonzero rounding drift is
  bounded, see §5).

**Insurance / Backstop Reserve** (already in V1 — NOT this milestone):

- Covers *actual* insolvency: bad debt when a trader's vault does not
  cover their realized loss (liquidation shortfall).
- Interacts with clearing only downstream of a liquidation.
- Not called by ordinary trade settlement.

They must not be conflated. Clearing exists so that ordinary
in-the-money legs can be paid at the moment of close even when the
matching out-of-the-money leg has not yet realized. Insurance covers
the accounting hole when a trader is *unable* to pay their realized
loss at all. Different problem, different mechanism, different
governance stance.

## 7. V1/V2 architectural isolation

### 7a. Solidity inheritance choice

`_applyRealizedCashflow` in V1 is `internal` and **not `virtual`**.
Adding `virtual` in-place would be a semantically visible change to
V1's source (even though the compiled bytecode is unchanged for an
`internal` function). Per the operator directive "V1 Solidity files
MUST remain semantically untouched," V2 is built as parallel
contracts:

```
V1: PerpEngine → PerpEngineTrading → PerpEngineViews → …

V2: PerpEngineV2 → PerpEngineTradingV2 → PerpEngineViews (V1, reused)
```

V2 skips `PerpEngineTrading` (V1) and directly extends V1's
`PerpEngineViews`. V1 code files are untouched; V2 reimplements
`applyTrade`, `liquidate`, and `_applyRealizedCashflow` from scratch.
All V1 helpers, storage, admin, types, and view functions are shared
by ordinary inheritance from `PerpEngineViews`.

Because V2 is a new deployment at a new address, the storage layout
of `PerpEngineTradingV2` may append new slots (e.g. `clearingAccount`)
without touching V1's live storage — V1's engine instance keeps its
own slot layout at its own address.

### 7b. Matching engine EIP-712 domain

V1 constructs `EIP712("DeOptV2-PerpMatchingEngine", "1")` in
`src/matching/PerpMatchingEngine.sol:315`.

V2 uses:

```solidity
EIP712("DeOptV2-PerpMatchingEngine", "2")
```

Combined with the different `verifyingContract` (V2 deploys at a new
address), this produces a distinct domain separator. **V1 signatures
cannot verify on V2 and vice versa.** Proof in
`test/matching/PerpMatchingEngineV2Domain.t.sol`.

V2's `PerpMatchingEngineV2` is otherwise a duplication of V1 — the
matching logic itself is not buggy; only the settlement math in the
engine is. The duplication is a hard code-safety fence: V2 signers
sign a domain that cannot be replayed against V1's engine.

## 8. Clearing account implementation

The vault ACL (`CollateralVaultStorage.sol:124`,
`_isAuthorizedEngine`) supports V1 and V2 engines simultaneously via
independent `isAuthorizedEngine[engine] = true` flags. No exclusive
lock; V2 can be authorised in parallel with V1.

For the settlement account, V2 uses an ordinary vault-holding
address. Requirements the account must satisfy:

1. Must be able to hold a `balances[clearing][mUSDC]` position — any
   address qualifies (`CollateralVault.deposit` accepts any depositor).
2. Must not be a trader address (checked in V2 constructor).
3. Must not be a fee recipient (avoids double-role ambiguity).
4. Should not be able to call `CollateralVault.withdraw` on its own
   balance without governance oversight — enforced operationally in
   this milestone; a `PerpClearingAccountV2` contract with no
   withdraw path is a follow-up hardening.

The clearing address is stored in the V2 engine's own storage
(`address public clearingAccount`) with a governance setter. All V2
realized-PnL transfers use `_collateralVault.transferBetweenAccounts`
between trader vault balances and `clearingAccount`. V2 checks
`_collateralVault.balances(clearingAccount, settlementAsset)` before
executing a positive-realized credit and reverts atomically on
shortfall.

## 9. V1 vault-authority analysis (§15 from directive)

V1 and V2 can co-exist as authorised engines on the *same*
CollateralVault instance without corruption **provided**:

- The market registry directs all matching engines to a single canonical
  perp engine per market. If two engines simultaneously mutate the same
  trader positions, the trader accounting diverges.
- **V1 and V2 must not simultaneously accept trades on the same market.**
  The migration plan (§10) freezes V1 (pause trading + close-only)
  before V2 is enabled for that market.
- The vault has `setAuthorizedEngine(engine, false)` — call this to
  revoke V1 once V2 is proven live.
- The vault has no pauseGuardV1 / pauseGuardV2 distinction. Because a
  paused V1 cannot mutate collateral, revocation is sufficient.

Result: **Vault reuse is safe** given the migration sequence. A
separate V2 vault is not required.

## 10. Migration hook design (design-only; no execution)

For the specific migrated state on Base Sepolia today
(A = +1_000_000 @ open 246_831_000_000; B = −1_000_000; fee-sink and
vault balances as documented in the backend `docs/`), the migration is
trivial: aggregate PnL asymmetry is zero and both positions can be
closed on V2 at the mark price to reach flat.

For a general migration:

1. Freeze V1 (pause trading, close-only, disable matching).
2. Snapshot every V1 position (size, openNotional, funding checkpoint).
3. Deploy PerpEngineV2 + PerpMatchingEngineV2 + clearing address.
4. `setAuthorizedEngine(V2, true)` on the vault.
5. `adminSeedPosition(trader, marketId, size, openNotional, funding)`
   for each position from the snapshot; assert per-market invariants
   after each seed.
6. Compute per-market unrealized PnL asymmetry; pre-fund clearing to
   at least the worst-case one-sided realizable exposure under
   position caps and current mark.
7. `sealAdminSeeding()` — irreversible; disables `adminSeedPosition`
   forever.
8. `setAuthorizedEngine(V1, false)` on the vault.
9. Point the backend at V2 engine + V2 matching + V2 domain separator.
10. Enable V2 trading; V1 is frozen.

`adminSeedPosition` and `sealAdminSeeding` are guarded by
`onlyOwner` + a `bool sealed` gate. They are NOT implemented in this
milestone (the current live state is trivially migratable) but the
design is fixed here to prevent scope drift.

## 11. Clearing solvency model (§14 from directive)

The clearing account is NOT the insurance fund. Its liquidity should
be sized against **temporary timing asymmetries** in realized PnL,
not against catastrophic loss.

Sizing quantities:

- Let `PmaxSize` = per-trader maximum absolute position size
  (`RiskConfig.maxPositionSize1e8`, market-configured).
- Let `MOI` = maximum per-market open interest
  (`RiskConfig.maxOpenInterest1e8`).
- Let `Dpx` = worst-case mark move between paired opens and paired
  closes (bounded by per-market execution-deviation guard + oracle
  freshness window).

Upper bound on single-trade clearing draw:

```
maxDraw = _value1e8ToSettlementNative(
    asset,
    PmaxSize * Dpx / PRICE_1E8
)
```

Recommended floor for clearing balance at market launch:

```
clearingFloor = 2 * maxDraw
```

Justification: enough to service one worst-case realized-gain leg
while its paired losing leg has not yet realized, plus a safety
factor of 2. Refunded by ordinary realized-loss flow.

**Not implemented in this milestone:**

- automatic governance minting;
- socialized loss;
- automatic top-up from insurance;
- automatic fee-sink drain into clearing.

Operator retains manual funding via ordinary
`CollateralVault.deposit(mUSDC, amount)` from the operator's own
address to the clearing address. A future milestone can add a
canonical `PerpClearingAccountV2` contract with a
`fundClearing(token, amount)` entry point.

## 12. What V2 keeps identical to V1

- Position math (`_computeNextPosition`).
- openNotional semantics.
- Funding math (`_fundingRateDelta1e18`, `_accruedFundingOnPosition`).
- Oracle execution-price guard (`_enforceExecutionPriceGuard`).
- Margin checks (`_enforcePostTradeRisk`).
- Bad-debt gate (`_enforceBadDebtTradingPolicy`).
- Fee logic (`_chargeTradingFee`, `_chargeTradingFeeV2`).
- Market activation gates.
- Position size / OI caps.
- Event semantics for `TradeExecuted`, `Liquidation`, funding events.

The only economic change is the settlement primitive.

## 13. Files added (V2 implementation)

Solidity (all under `src/perp/` and `src/matching/`):

- `src/perp/PerpEngineTradingV2.sol` (new)
- `src/perp/PerpEngineV2.sol` (new)
- `src/matching/PerpMatchingEngineV2.sol` (new)

Tests:

- `test/perp/PerpEngineV2Cashflow.t.sol`
- `test/perp/PerpEngineV2BaseSepoliaRegression.t.sol`
- `test/perp/PerpEngineV2TemporalLiquidity.t.sol`
- `test/perp/PerpEngineV2AsymmetricBasis.t.sol`
- `test/perp/PerpEngineV2LiquidationCashflow.t.sol`
- `test/perp/PerpEngineV2RoundingBoundaries.t.sol`
- `test/perp/PerpEngineV2CloseMatrix.t.sol`
- `test/fuzz/perp/PerpEngineV2Fuzz.t.sol`
- `test/matching/PerpMatchingEngineV2Domain.t.sol`

Docs:

- `docs/PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1.md` (this file).

V1 files: **unchanged**.

## 14. Follow-up milestones (not this one)

- `PERPS_V2_CLEARING_ACCOUNT_CONTRACT_V1` — deploy a no-withdraw
  `PerpClearingAccountV2` contract wrapping the vault balance;
  swap the raw address for the contract address.
- `PERPS_V2_MIGRATION_SEED_HOOK_V1` — implement `adminSeedPosition` +
  `sealAdminSeeding` on V2 for future non-trivial migrations.
- `PERPS_V2_BASE_SEPOLIA_DEPLOY_V1` — deploy V2 on Base Sepolia,
  configure the vault authorization pair, top up clearing, close A/B
  correctly, revoke V1.
- `PERPS_V2_MAINNET_READINESS_AUDIT_V1` — external audit gate before
  any mainnet deployment.
