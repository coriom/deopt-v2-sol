#!/usr/bin/env python3
"""Pinned, read-only Base Sepolia Options oracle diagnosis. No transaction calls.

Uses a public RPC by default. An alternate DEOPT_READONLY_RPC_URL is read only
from the environment and is never included in output or command arguments.
"""

import argparse
import json
import os
import sys
import urllib.request

ROUTER = "0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581"
QUOTE = "0x6eAe407f5640B006faC9965182e238582A3B412E"
PAIRS = {
    "ETH/USD": "0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02",
    "BTC/USD": "0x9D871aC7595E8Da271E866608E5145252047967c",
}
SELECTORS = {
    "getFeed": "d2edb6dd",
    "getPriceSafe": "63851ea3",
    "getLatestPrice": "8e15f473",
    "aggregator": "245a7bfc",
    "priceId": "31189334",
    "pyth": "f98d06f0",
    "getPriceUnsafe": "96834ad3",
    "latestRoundData": "feaf968c",
    "decimals": "313ce567",
    "maxOracleDelay": "52f1edcc",
    "readPaused": "8e943bce",
    "paused": "5c975abb",
}


def words(result):
    if not isinstance(result, str) or not result.startswith("0x") or (len(result) - 2) % 64:
        raise ValueError("invalid ABI response")
    return [result[i : i + 64] for i in range(2, len(result), 64)]


def unsigned(word):
    return int(word, 16)


def signed(word, bits=256):
    value = int(word, 16) & ((1 << bits) - 1)
    return value - (1 << bits) if value >= 1 << (bits - 1) else value


def address(word):
    return "0x" + word[-40:].lower()


def encode_address(value):
    return value.lower().removeprefix("0x").rjust(64, "0")


def deviation_bps(a, b):
    return abs(a - b) * 10_000 // min(a, b) if min(a, b) > 0 else None


def normalize_1e8(raw, exponent):
    shift = exponent + 8
    return raw * 10 ** shift if shift >= 0 else raw // 10 ** -shift


def timestamp_usable(updated_at, block_time, delay):
    return updated_at > 0 and updated_at <= block_time and (delay == 0 or block_time - updated_at <= delay)


def direct_expected(primary_price, primary_time, secondary_price, secondary_time,
                    block_time, delay, max_bps, active, read_paused):
    """Mirror the direct-feed accept/reject rule, including single-source fallback."""
    if not active or read_paused:
        return (0, 0, False)
    usable_primary = primary_price > 0 and timestamp_usable(primary_time, block_time, delay)
    usable_secondary = secondary_price > 0 and timestamp_usable(secondary_time, block_time, delay)
    if usable_primary and usable_secondary:
        if deviation_bps(primary_price, secondary_price) > max_bps:
            return (0, 0, False)
        return (primary_price, min(primary_time, secondary_time), True)
    if usable_primary:
        return (primary_price, primary_time, True)
    if usable_secondary:
        return (secondary_price, secondary_time, True)
    return (0, 0, False)


class Rpc:
    def __init__(self, url):
        if not url.startswith("https://"):
            raise ValueError("read-only RPC must use HTTPS")
        self.url = url

    def request(self, method, params):
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.url, payload, {"Content-Type": "application/json", "User-Agent": "deopt-options-oracle-preflight/2"})
        with urllib.request.urlopen(req, timeout=15) as response:
            body = json.load(response)
        if "error" in body or "result" not in body:
            raise RuntimeError(f"RPC {method} failed")
        return body["result"]

    def call(self, to, selector, args, block):
        return words(self.request("eth_call", [{"to": to, "data": "0x" + selector + args}, block]))


def read_pair(rpc, label, base, block, block_time, global_delay, read_paused):
    args = encode_address(base) + encode_address(QUOTE)
    feed = rpc.call(ROUTER, SELECTORS["getFeed"], args, block)
    if len(feed) != 5:
        raise ValueError("unexpected router feed shape")
    primary, secondary = address(feed[0]), address(feed[1])
    max_delay, max_bps, active = unsigned(feed[2]), unsigned(feed[3]), bool(unsigned(feed[4]))
    safe = rpc.call(ROUTER, SELECTORS["getPriceSafe"], args, block)
    if len(safe) != 3:
        raise ValueError("unexpected router price shape")

    chainlink_aggregator = address(rpc.call(primary, SELECTORS["aggregator"], "", block)[0])
    round_data = rpc.call(chainlink_aggregator, SELECTORS["latestRoundData"], "", block)
    if len(round_data) != 5:
        raise ValueError("unexpected Chainlink round shape")
    decimals = unsigned(rpc.call(chainlink_aggregator, SELECTORS["decimals"], "", block)[0])
    raw_chainlink = signed(round_data[1])
    chainlink_price = unsigned(rpc.call(primary, SELECTORS["getLatestPrice"], "", block)[0])
    chainlink_time = unsigned(round_data[3])
    if unsigned(round_data[0]) == 0 or unsigned(round_data[4]) < unsigned(round_data[0]):
        raise ValueError("invalid Chainlink round")
    if chainlink_price != normalize_1e8(raw_chainlink, -decimals):
        raise ValueError("Chainlink adapter normalization mismatch")

    pyth_contract = address(rpc.call(secondary, SELECTORS["pyth"], "", block)[0])
    price_id = "0x" + rpc.call(secondary, SELECTORS["priceId"], "", block)[0]
    pyth_data = rpc.call(pyth_contract, SELECTORS["getPriceUnsafe"], price_id[2:], block)
    if len(pyth_data) != 4:
        raise ValueError("unexpected Pyth price shape")
    raw_pyth = signed(pyth_data[0], 64)
    confidence = unsigned(pyth_data[1]) & ((1 << 64) - 1)
    exponent = signed(pyth_data[2], 32)
    pyth_time = unsigned(pyth_data[3])
    pyth_price = unsigned(rpc.call(secondary, SELECTORS["getLatestPrice"], "", block)[0])
    if pyth_price != normalize_1e8(raw_pyth, exponent):
        raise ValueError("Pyth adapter normalization mismatch")
    delays = [value for value in (max_delay, global_delay) if value > 0]
    effective_delay = min(delays) if delays else 0
    expected = direct_expected(chainlink_price, chainlink_time, pyth_price, pyth_time,
                               block_time, effective_delay,
                               max_bps, active, read_paused)
    actual = (unsigned(safe[0]), unsigned(safe[1]), bool(unsigned(safe[2])))
    if actual != expected:
        raise ValueError(f"{label}: router output disagrees with direct feed calculation")
    primary_usable = timestamp_usable(chainlink_time, block_time, effective_delay)
    secondary_usable = timestamp_usable(pyth_time, block_time, effective_delay)
    source_mode = ("dual" if primary_usable and secondary_usable else
                   "primary_only" if primary_usable else
                   "secondary_only" if secondary_usable else "none")
    return {
        "pair": label,
        "active": active,
        "router_max_delay_seconds": max_delay,
        "max_deviation_bps": max_bps,
        "primary": {"adapter": primary, "aggregator": chainlink_aggregator, "raw_answer": raw_chainlink,
                    "decimals": decimals, "price_1e8": chainlink_price, "updated_at": chainlink_time,
                    "age_seconds": block_time - chainlink_time},
        "secondary": {"adapter": secondary, "pyth": pyth_contract, "price_id": price_id,
                      "raw_price": raw_pyth, "confidence": confidence, "exponent": exponent,
                      "price_1e8": pyth_price, "updated_at": pyth_time,
                      "age_seconds": block_time - pyth_time},
        "deviation_bps": deviation_bps(chainlink_price, pyth_price),
        "source_mode": source_mode,
        "get_price_safe": {"price_1e8": actual[0], "updated_at": actual[1], "ok": actual[2]},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--block", type=int, help="Base Sepolia block; defaults to current head")
    args = parser.parse_args()
    rpc = Rpc(os.environ.get("DEOPT_READONLY_RPC_URL", "https://sepolia.base.org"))
    if int(rpc.request("eth_chainId", []), 16) != 84532:
        raise ValueError("RPC is not Base Sepolia")
    number = args.block if args.block is not None else int(rpc.request("eth_blockNumber", []), 16)
    tag = hex(number)
    before = rpc.request("eth_getBlockByNumber", [tag, False])
    if before is None:
        raise ValueError("block unavailable")
    block_time = int(before["timestamp"], 16)
    global_delay = unsigned(rpc.call(ROUTER, SELECTORS["maxOracleDelay"], "", tag)[0])
    read_paused = bool(unsigned(rpc.call(ROUTER, SELECTORS["readPaused"], "", tag)[0]))
    paused = bool(unsigned(rpc.call(ROUTER, SELECTORS["paused"], "", tag)[0]))
    data = [read_pair(rpc, label, base, tag, block_time, global_delay, read_paused or paused)
            for label, base in PAIRS.items()]
    after = rpc.request("eth_getBlockByNumber", [tag, False])
    if after is None or after["hash"] != before["hash"]:
        raise RuntimeError("pinned block changed during probe")
    print(json.dumps({"chain_id": 84532, "block": number, "block_hash": before["hash"],
                      "timestamp": block_time, "router": ROUTER, "global_max_delay_seconds": global_delay,
                      "read_paused": read_paused, "paused": paused, "pairs": data}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"ORACLE_PREFLIGHT=FAIL: {type(exc).__name__}", file=sys.stderr)
        sys.exit(1)
