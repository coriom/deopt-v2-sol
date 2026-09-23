#!/usr/bin/env python3
"""
PERPS_V2_CUTOVER — Clearing seed sizing calculator.

Reads the canonical snapshot manifest (schema per
docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1.md §P) and a small
market-parameters JSON, then derives:

  MINIMUM_REQUIRED_CLEARING  — worst-case first-V2-close settlement
                               liquidity required from clearing
  OPERATIONAL_BUFFER         — operator safety headroom
  PROPOSED_CLEARING_SEED     — MINIMUM_REQUIRED + BUFFER (rounded)

All numbers are quoted in native settlement-asset units (mUSDC has
6 decimals: 1_000_000 native = 1 mUSDC).

USAGE:
  python3 clearing_sizing.py manifest.json market_params.json

market_params.json format:
  {
    "settlementAsset": "mUSDC",
    "settlementDecimals": 6,
    "worstMarkAssumptionUsd1e18": {
      "1": 5000000000000000000000,       # 5000 USD/ETH — conservative upper bound
      "2": 200000000000000000000000      # 200000 USD/BTC — conservative upper bound
    },
    "worstPnlSwingBps": 2000,            # 20% max deviation between snapshot and first close
    "roundingSlackPerPositionNative": 100,   # a few native units per position
    "operationalBufferMultiplier": 9,        # buffer = multiplier * MINIMUM (default 9× → total 10× MIN)
    "operationalMinimumNative": 100000000    # never propose less than 100 mUSDC total
  }

The math (per position in the manifest, per market):
  notional_native ≈ |size1e8| * markPrice1e8 / 1e8   (scaled to settlement decimals)
  worst_case_pnl_native ≈ notional_native * worstPnlSwingBps / 10000

Sum worst_case_pnl across all live positions to derive
MINIMUM_REQUIRED_CLEARING. Apply the multiplier for buffer.
"""
import json, sys, math

def load(p):
    return json.load(open(p))

def main(manifest_path, params_path):
    m = load(manifest_path)
    p = load(params_path)

    dec = int(p["settlementDecimals"])
    swing_bps = int(p["worstPnlSwingBps"])
    slack_per_pos = int(p["roundingSlackPerPositionNative"])
    buffer_mult = int(p["operationalBufferMultiplier"])
    op_min = int(p["operationalMinimumNative"])
    marks = {int(k): int(v) for k, v in p["worstMarkAssumptionUsd1e18"].items()}
    asset = p.get("settlementAsset", "settlement")

    n_pos = len(m["positions"])
    per_pos = []
    total_min = 0

    for pos in m["positions"]:
        mid = int(pos["marketId"])
        sz = abs(int(pos["size1e8"]))
        if mid not in marks:
            raise SystemExit(f"missing worstMarkAssumption for marketId {mid}")
        # notional in USD 1e18: sz * mark / 1e8
        notional_usd_1e18 = sz * marks[mid] // (10**8)
        # convert to native settlement units (assume settlementAsset ≈ 1 USD, e.g. mUSDC)
        notional_native = notional_usd_1e18 * (10**dec) // (10**18)
        worst_pnl_native = notional_native * swing_bps // 10000
        per_pos.append({
            "trader": pos["trader"], "marketId": mid, "size1e8": sz,
            "notional_native": notional_native,
            "worst_pnl_native": worst_pnl_native,
        })
        total_min += worst_pnl_native

    total_min += slack_per_pos * n_pos
    minimum = max(total_min, op_min)
    buffer = minimum * buffer_mult
    proposed = minimum + buffer

    print(f"positions considered: {n_pos}")
    for r in per_pos:
        print(f"  trader={r['trader']} mkt={r['marketId']} size1e8={r['size1e8']}"
              f" notional_native={r['notional_native']} worst_pnl_native={r['worst_pnl_native']}")
    print()
    print(f"settlement_asset:               {asset}")
    print(f"settlement_decimals:            {dec}")
    print(f"worst_swing_bps:                {swing_bps}")
    print(f"slack_per_position_native:      {slack_per_pos}")
    print(f"operational_minimum_native:     {op_min}   ({op_min / (10**dec):.6f} {asset})")
    print(f"MINIMUM_REQUIRED_CLEARING:      {minimum}   ({minimum / (10**dec):.6f} {asset})")
    print(f"OPERATIONAL_BUFFER (x{buffer_mult}):        {buffer}   ({buffer / (10**dec):.6f} {asset})")
    print(f"PROPOSED_CLEARING_SEED:         {proposed}   ({proposed / (10**dec):.6f} {asset})")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: clearing_sizing.py manifest.json market_params.json", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
