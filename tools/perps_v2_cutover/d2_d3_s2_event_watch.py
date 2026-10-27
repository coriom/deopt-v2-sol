#!/usr/bin/env python3
"""Bounded, read-only Safe event watcher for one reviewed D2/D3 S2 action.

This discovers a public transaction hash. It does not establish postflight PASS;
the full receipt, Timelock event, state transition and non-drift checks follow.
No signing, proposal, send, or other write-capable RPC method is present.
"""

import argparse
import json
import re
import time
import urllib.error
import urllib.request

RPC = "https://sepolia.base.org"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
SUCCESS_TOPIC = "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e"
MAX_RANGE = 100


def rpc(method, params):
    if method not in {"eth_chainId", "eth_getBlockByNumber", "eth_getLogs"}:
        raise ValueError("RPC method is not read-only allowlisted")
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        RPC, data=body,
        headers={"Content-Type": "application/json", "User-Agent": "deopt-readonly-postflight/1.0"},
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        data = json.load(response)
    if "error" in data:
        raise RuntimeError(str(data["error"])[:300])
    return data["result"]


def scan(start, end, safe_tx_hash):
    for first in range(start, end + 1, MAX_RANGE):
        last = min(first + MAX_RANGE - 1, end)
        events = rpc("eth_getLogs", [{
            "address": SAFE,
            "fromBlock": hex(first),
            "toBlock": hex(last),
            "topics": [SUCCESS_TOPIC, safe_tx_hash],
        }])
        if len(events) > 1:
            raise RuntimeError("multiple matching Safe successes; reconcile manually")
        for event in events:
            if (event["address"].lower() != SAFE.lower()
                    or [topic.lower() for topic in event["topics"]] !=
                    [SUCCESS_TOPIC, safe_tx_hash.lower()]):
                raise RuntimeError("event filter returned an unexpected log")
            yield {"txHash": event["transactionHash"],
                   "block": int(event["blockNumber"], 16),
                   "blockHash": event["blockHash"],
                   "safeTxHash": safe_tx_hash}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--safe-tx-hash", required=True)
    parser.add_argument("--from-block", type=int, required=True)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--interval", type=int, default=8)
    args = parser.parse_args()
    if not (re.fullmatch(r"0x[0-9a-fA-F]{64}", args.safe_tx_hash)
            and args.from_block > 0 and 0 <= args.timeout <= 600
            and 2 <= args.interval <= 60):
        parser.error("invalid hash, block, timeout, or interval")
    deadline = time.monotonic() + args.timeout
    cursor = args.from_block
    failures = 0
    while True:
        try:
            if int(rpc("eth_chainId", []), 16) != 84532:
                raise RuntimeError("wrong chain")
            head = rpc("eth_getBlockByNumber", ["safe", False])
            end = int(head["number"], 16)
            match = next(scan(cursor, end, args.safe_tx_hash), None) if cursor <= end else None
            if match:
                print(json.dumps({"status": "CANDIDATE_ONLY", **match}, sort_keys=True), flush=True)
                return
            # Revisit a few safe blocks if a provider's log index lags its head.
            cursor = max(args.from_block, end - 2)
            failures = 0
        except (OSError, TimeoutError, ValueError, RuntimeError, urllib.error.URLError) as error:
            failures += 1
            if failures >= 3:
                print(json.dumps({"status": "RPC_UNRELIABLE", "error": str(error)[:180]}), flush=True)
                raise SystemExit(2)
        if time.monotonic() >= deadline:
            print(json.dumps({"status": "TIMEOUT_NO_EVENT", "nextFromBlock": cursor}), flush=True)
            return
        time.sleep(min(args.interval * (2 ** min(failures, 2)), max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    main()
