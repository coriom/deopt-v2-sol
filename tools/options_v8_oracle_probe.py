#!/usr/bin/env python3
"""Read-only, pinned Base Sepolia checks for the historical settlement design."""

import json
import os
import subprocess
import sys
from pathlib import Path

from options_v7_readonly_preflight import Rpc, rpc_url, words


FEEDS = {
    "eth_chainlink": "0x4adc67696ba383f43dd60a9e78f2c97fbbfc7cb1",
    "btc_chainlink": "0x0fb99723aee6f420bead13e6bbb79b7e6f034298",
}
PYTH = "0x5f52e4dbea21f5b23523b6e20d50c29ae0a4eb83"
IDS = {
    "eth_pyth": "ff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
    "btc_pyth": "e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
}


def call(rpc, target, selector, args=""):
    return words(rpc.call("eth_call", [{"to": target, "data": "0x" + selector + args}, rpc.block]))


def main():
    if sys.argv[1:] == ["--fork-test"]:
        environment = os.environ.copy()
        environment["RPC_URL"] = rpc_url()
        raise SystemExit(subprocess.call(
            ["forge", "test", "--match-path", "test/fork/VerifiedOptionSettlementOwnerFork.t.sol", "-vv"],
            cwd=Path(__file__).resolve().parents[1], env=environment,
        ))
    rpc = Rpc(rpc_url())
    if int(rpc.call("eth_chainId", []), 16) != 84532:
        raise RuntimeError("Wrong chain")
    block = rpc.call("eth_getBlockByNumber", ["latest", False])
    rpc.block = block["number"]
    result = {"chain_id": 84532, "block": int(rpc.block, 16), "hash": block["hash"], "feeds": {}}
    for name, address in FEEDS.items():
        latest = call(rpc, address, "feaf968c")
        if len(latest) != 5:
            raise RuntimeError("Malformed Chainlink latest round")
        round_id = latest[0]
        previous = call(rpc, address, "9a6fc8f5", f"{round_id - 1:064x}")
        if len(previous) != 5:
            raise RuntimeError("Malformed Chainlink previous round")
        dec = call(rpc, address, "313ce567")
        result["feeds"][name] = {
            "address": address,
            "decimals": dec[0],
            "latest_round": round_id,
            "latest_phase": round_id >> 64,
            "latest_updated_at": latest[3],
            "previous_round": previous[0],
            "previous_updated_at": previous[3],
            "historical_get_round_data": previous[0] == round_id - 1,
        }
    for name, price_id in IDS.items():
        value = call(rpc, PYTH, "96834ad3", price_id)
        if len(value) != 4:
            raise RuntimeError("Malformed Pyth price")
        result["feeds"][name] = {
            "contract": PYTH,
            "price_id": "0x" + price_id,
            "publish_time": value[3],
            "readable": value[3] != 0,
        }
    try:
        # Empty update list probes the fee API only. It does not prove that
        # historical signed updates are available or accepted.
        result["pyth_empty_update_fee"] = call(rpc, PYTH, "d47eed45", f"{32:064x}{0:064x}")[0]
    except RuntimeError:
        result["pyth_empty_update_fee"] = "UNAVAILABLE"
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("ORACLE_PROBE_BLOCKED=" + type(exc).__name__)
        raise SystemExit(1)
