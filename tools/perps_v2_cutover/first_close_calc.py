#!/usr/bin/env python3
"""
PERPS_V2_CUTOVER — Local first-V2-close calculator.

Reproduces the exact settlement math implemented in `PerpEngineV2` for a
single matched close between one long and one short position at a given
execution price. Emits realized PnL, funding delta, maker/taker fee,
clearing residual, and per-account Vault deltas SEPARATELY so the
operator can compare each component against on-chain settlement post-trade.

Nothing here signs, broadcasts, or reads the chain. All inputs are
supplied on the CLI or as JSON.

USAGE:
  python3 first_close_calc.py trade.json

trade.json schema:
  {
    "marketId": 1,
    "settlementDecimals": 6,          # mUSDC
    "closeSize1e8": 1001002,          # |sizeDelta| — the amount being closed on each side

    "buyer": {                        # long side (positive size1e8)
      "address": "0x...",
      "size1e8": 1001002,
      "openNotional1e8": 246831000000,
      "lastCumFundingRate1e18": 0
    },
    "seller": {                       # short side (negative size1e8)
      "address": "0x...",
      "size1e8": -1001002,
      "openNotional1e8": -246831000000,
      "lastCumFundingRate1e18": 0
    },

    "executionPrice1e8": 249273743964,
    "cumFundingRate1e18": 0,          # current market cumulative

    "buyerIsMaker": true,             # matches PerpTrade.buyerIsMaker
    "feeManagerV2": {
      "makerPpm": 50,                 # 50 ppm on notional
      "takerPpm": 300
    }
  }

MATHS (mirrors PerpEngineTradingV2 apply-trade path with V2 fee wiring):
  notional_native = |closeSize1e8| * executionPrice1e8 / 1e8    (rescaled to settlementDecimals)
  realizedPnl_long_1e8  =  +closeSize1e8 * executionPrice1e8 / 1e8  -  |buyer.openNotional1e8 * closeSize / |buyer.size1e8||
  realizedPnl_short_1e8 = -closeSize1e8 * executionPrice1e8 / 1e8  +  seller.openNotional1e8 * closeSize / seller.size1e8
  funding_long_1e8  = (cumFundingRate - buyer.lastCum) * buyer.size1e8 / 1e18
  funding_short_1e8 = (cumFundingRate - seller.lastCum) * seller.size1e8 / 1e18   (positive size ⇒ funding-paying long)

  All PnL/funding quantities are then converted from 1e8 to settlement
  native units by dividing by 1e8 and re-scaling by 10**settlementDecimals
  (settlement asset assumed 1:1 with USD in the model).

Fee math (post-milestone-A: V2 path is unconditional when useFeesManagerV2):
  fee_maker_native = notional_native * makerPpm / 1_000_000
  fee_taker_native = notional_native * takerPpm / 1_000_000
  buyer_fee_native  = fee_maker if buyerIsMaker else fee_taker
  seller_fee_native = fee_taker if buyerIsMaker else fee_maker

Clearing routing (§T of preflight doc):
  loser  = side with realized < 0    → pays |realized|      to clearing account
  winner = side with realized > 0    → receives realized    from clearing account
  clearing_residual = |loser_realized| - winner_realized     (0 for symmetric close, small for rounding)

Vault deltas:
  buyer_vault_delta_native  = realizedPnl_buyer_native  - funding_buyer_native  - buyer_fee_native
  seller_vault_delta_native = realizedPnl_seller_native - funding_seller_native - seller_fee_native
  clearing_vault_delta_native = -(buyer_vault_delta_native + seller_vault_delta_native + total_fee_native)
"""
import json, sys

PRICE_1E8 = 10**8
FUND_1E18 = 10**18
PPM = 1_000_000

def native(pnl_1e8, dec):
    # pnl_1e8 is in 1e8 units of settlement asset assumed 1 USD ≈ 1 unit
    # convert to native: pnl_1e8 * 10**(dec) / 1e8
    sign = -1 if pnl_1e8 < 0 else 1
    mag = abs(pnl_1e8) * (10**dec) // PRICE_1E8
    return sign * mag

def calc(t):
    dec = int(t["settlementDecimals"])
    cs = abs(int(t["closeSize1e8"]))
    x = int(t["executionPrice1e8"])
    m = int(t["cumFundingRate1e18"])
    buyer = t["buyer"]; seller = t["seller"]
    buyerIsMaker = bool(t["buyerIsMaker"])
    makerPpm = int(t["feeManagerV2"]["makerPpm"])
    takerPpm = int(t["feeManagerV2"]["takerPpm"])

    # Notional native
    notional_1e8 = cs * x // PRICE_1E8       # units 1e8 of settlement
    notional_native = notional_1e8 * (10**dec) // PRICE_1E8

    # Realized PnL on close of |cs| out of buyer.size1e8 (long +) and seller.size1e8 (short -)
    # Long realized: cs * (x - avgEntry_long) where avgEntry_long = buyer.openNotional/buyer.size
    b_avg_1e8 = int(buyer["openNotional1e8"]) * PRICE_1E8 // abs(int(buyer["size1e8"]))
    s_avg_1e8 = abs(int(seller["openNotional1e8"])) * PRICE_1E8 // abs(int(seller["size1e8"]))
    realized_long_1e8  =  cs * (x - b_avg_1e8) // PRICE_1E8
    realized_short_1e8 =  cs * (s_avg_1e8 - x) // PRICE_1E8  # short gains when price falls

    # Funding delta (per side, on the portion being closed)
    # funding is positive when position pays funding
    b_fund_cum_delta = m - int(buyer["lastCumFundingRate1e18"])
    s_fund_cum_delta = m - int(seller["lastCumFundingRate1e18"])
    # long owes when rate increased (positive funding): funding_long = +size1e8 * delta / 1e18
    # engine convention (payer viewpoint): if delta > 0, longs pay
    funding_long_1e8  =  cs * b_fund_cum_delta // FUND_1E18
    funding_short_1e8 = -cs * s_fund_cum_delta // FUND_1E18

    # Fees native
    buyer_fee_native  = notional_native * (makerPpm if buyerIsMaker else takerPpm) // PPM
    seller_fee_native = notional_native * (takerPpm if buyerIsMaker else makerPpm) // PPM
    total_fee_native = buyer_fee_native + seller_fee_native

    # Native settlement per side (before clearing routing)
    long_pnl_native   = native(realized_long_1e8, dec)
    short_pnl_native  = native(realized_short_1e8, dec)
    long_fund_native  = native(funding_long_1e8, dec)
    short_fund_native = native(funding_short_1e8, dec)

    buyer_vault_delta  = long_pnl_native  - long_fund_native  - buyer_fee_native
    seller_vault_delta = short_pnl_native - short_fund_native - seller_fee_native

    # Clearing residual: sum-to-zero minus fees (fees leave through FMV2 to feeRecipient)
    clearing_vault_delta = -(buyer_vault_delta + seller_vault_delta + total_fee_native)

    return {
        "notional_native": notional_native,
        "buyer": {
            "address": buyer["address"], "isMaker": buyerIsMaker,
            "realizedPnl_1e8": realized_long_1e8,  "realizedPnl_native": long_pnl_native,
            "funding_1e8": funding_long_1e8,       "funding_native": long_fund_native,
            "fee_native": buyer_fee_native,
            "vault_delta_native": buyer_vault_delta,
        },
        "seller": {
            "address": seller["address"], "isMaker": not buyerIsMaker,
            "realizedPnl_1e8": realized_short_1e8, "realizedPnl_native": short_pnl_native,
            "funding_1e8": funding_short_1e8,      "funding_native": short_fund_native,
            "fee_native": seller_fee_native,
            "vault_delta_native": seller_vault_delta,
        },
        "total_fee_native": total_fee_native,
        "clearing_vault_delta_native": clearing_vault_delta,
    }

def pretty(r, dec):
    def fmt(v): return f"{v} ({v/(10**dec):+.6f})"
    print(f"notional_native                     = {r['notional_native']} ({r['notional_native']/(10**dec):.6f})")
    for side_key, side_label in [("buyer","BUYER (long)"), ("seller","SELLER (short)")]:
        s = r[side_key]
        print(f"\n{side_label}  {s['address']}   maker={s['isMaker']}")
        print(f"  realized_pnl_1e8              = {s['realizedPnl_1e8']}")
        print(f"  realized_pnl_native           = {fmt(s['realizedPnl_native'])}")
        print(f"  funding_1e8                   = {s['funding_1e8']}")
        print(f"  funding_native                = {fmt(s['funding_native'])}")
        print(f"  fee_native                    = {s['fee_native']}")
        print(f"  vault_delta_native            = {fmt(s['vault_delta_native'])}")
    print()
    print(f"total_fee_native                    = {r['total_fee_native']} ({r['total_fee_native']/(10**dec):.6f})")
    print(f"clearing_vault_delta_native         = {fmt(r['clearing_vault_delta_native'])}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: first_close_calc.py trade.json", file=sys.stderr); sys.exit(2)
    t = json.load(open(sys.argv[1]))
    r = calc(t)
    pretty(r, int(t["settlementDecimals"]))
