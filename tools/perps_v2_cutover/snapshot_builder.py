#!/usr/bin/env python3
"""
PERPS_V2_CUTOVER — Snapshot manifest builder.

Reads Base Sepolia state at an explicit block and produces the canonical
manifest JSON per docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1.md §P.

USAGE:
  python3 snapshot_builder.py \
      --rpc <RPC_URL> \
      --block <BLOCK_NUMBER> \
      --traders <trader1> [trader2 ...] \
      --markets 1 2 \
      [--out manifest.json]

Trader-universe discovery is left to the caller (typically: union of
`PerpEngine.TradeExecuted` event topic1+topic2 across the full V1
lifetime, plus backend `indexed_perp_trades DISTINCT trader`). This
script consumes an explicit trader list.

Dependencies:
  requests    (usual venv install)
  cbor2       (for hash generation with snapshot_hash.py)
"""
import argparse, json, sys, subprocess

def cast_call(rpc, addr, sig, *args, block=None):
    cmd = ["cast", "call", addr, sig, *[str(a) for a in args], "--rpc-url", rpc]
    if block is not None: cmd += ["--block", str(block)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"cast call failed: {' '.join(cmd)}\nstdout: {r.stdout}\nstderr: {r.stderr}")
    return r.stdout.strip()

def cast_block_hash(rpc, block):
    r = subprocess.run(["cast", "block", str(block), "--rpc-url", rpc, "--field", "hash"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"cast block failed: rc={r.returncode}\nstdout: {r.stdout}\nstderr: {r.stderr}")
    return r.stdout.strip()

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--rpc", required=True)
    p.add_argument("--block", type=int, required=True)
    p.add_argument("--traders", nargs="*", default=[])
    p.add_argument("--markets", nargs="+", type=int, required=True)
    p.add_argument("--engine", default="0xc6C592100723Fe0C66343A16e95eC34cC0c2141c")
    p.add_argument("--pme",    default="0x774d96E5739bffadEE91508b4D3D74F5BE29F165")
    p.add_argument("--vault",  default="0x00340C360353a5AB784c5Bc5c44322A6AF0625D3")
    p.add_argument("--musdc",  default="0x6eAe407f5640B006faC9965182e238582A3B412E")
    p.add_argument("--out", default="/dev/stdout")
    a = p.parse_args()

    blk = a.block
    block_hash = cast_block_hash(a.rpc, blk)
    if not block_hash.startswith("0x") or len(block_hash) != 66:
        raise SystemExit(f"bad blockHash: {block_hash}")

    manifest = {
        "schemaVersion": 1,
        "chainId": 84532,
        "engineV1": a.engine,
        "pmeV1": a.pme,
        "snapshotBlockNumber": blk,
        "snapshotBlockHash": block_hash,
        "markets": [],
        "positions": [],
        "residualBadDebt": [],
        "pmeNonces": [],
        "vaultBalances": [],
    }

    # Markets — struct MarketState = (uint256 longOI, uint256 shortOI, int256 cumFundingRate1e18, uint64 lastFundingTs)
    for mid in a.markets:
        out = cast_call(a.rpc, a.engine, "marketState(uint256)((uint256,uint256,int256,uint64))", mid, block=blk)
        vals = out.strip("()").split(", ")
        loi = int(vals[0].split(" ")[0])
        soi = int(vals[1].split(" ")[0])
        cum = int(vals[2].split(" ")[0])
        ts  = int(vals[3].split(" ")[0])
        manifest["markets"].append({
            "marketId": mid,
            "cumulativeFundingRate1e18": cum,
            "lastFundingTimestamp": ts,
            "longOI1e8": loi,
            "shortOI1e8": soi,
        })

    # Positions + residualBadDebt + PME nonces + vault balances per trader
    for tr in a.traders:
        rbd = int(cast_call(a.rpc, a.engine, "getResidualBadDebt(address)(uint256)", tr, block=blk).split(" ")[0])
        if rbd != 0:
            manifest["residualBadDebt"].append({"trader": tr, "amountBase": rbd})

        for mid in a.markets:
            size = int(cast_call(a.rpc, a.engine, "getPositionSize(address,uint256)(int256)", tr, mid, block=blk).split(" ")[0])
            if size == 0: continue
            pos = cast_call(a.rpc, a.engine, "positions(address,uint256)((int256,int256,int256))", tr, mid, block=blk)
            pv = pos.strip("()").split(", ")
            size1e8   = int(pv[0].split(" ")[0])
            openN     = int(pv[1].split(" ")[0])
            lastCum   = int(pv[2].split(" ")[0])
            manifest["positions"].append({
                "trader": tr,
                "marketId": mid,
                "size1e8": size1e8,
                "openNotional1e8": openN,
                "lastCumulativeFundingRate1e18": lastCum,
            })

        # PME nonce (public `nonces` mapping in PerpMatchingEngine)
        nonce = int(cast_call(a.rpc, a.pme, "nonces(address)(uint256)", tr, block=blk).split(" ")[0])
        if nonce != 0:
            manifest["pmeNonces"].append({"trader": tr, "nonce": nonce})

        # Vault balance in mUSDC
        bal = int(cast_call(a.rpc, a.vault, "balances(address,address)(uint256)", tr, a.musdc, block=blk).split(" ")[0])
        if bal != 0:
            manifest["vaultBalances"].append({"user": tr, "token": a.musdc, "balance": bal})

    out_path = a.out
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2)
    if out_path != "/dev/stdout":
        print(f"wrote {out_path} ({len(manifest['positions'])} positions, "
              f"{len(manifest['markets'])} markets, {len(manifest['residualBadDebt'])} bad-debt entries, "
              f"{len(manifest['pmeNonces'])} pme nonces, {len(manifest['vaultBalances'])} vault balances)")

if __name__ == "__main__":
    main()
