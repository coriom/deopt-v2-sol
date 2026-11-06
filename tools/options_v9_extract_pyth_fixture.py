#!/usr/bin/env python3
"""Extract one public Pyth Core payload from a pinned Base Sepolia transaction.

The transaction was already broadcast by another actor. This script only reads
its public calldata and receipt; it never broadcasts or handles an API key.
"""

import hashlib
import sys
from pathlib import Path

from options_v7_readonly_preflight import Rpc, rpc_url


TX = "0xf9ac3c02fb1626391f372b269a19acf69c075e14415a93ff128c64ef51162426"
PYTH = "0x5f52e4dbea21f5b23523b6e20d50c29ae0a4eb83"
ETH_ID = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace"
TOPIC = "0xd06a6b7f4918494b3719217d1802786c1f5112a6c1d88fe2cfec00b4584f6aec"
OUTPUT = Path(__file__).resolve().parents[1] / "test/fixtures/options_v9_pyth_core_eth_payload.hex"


def word(data, offset):
    return int.from_bytes(data[offset:offset + 32], "big")


def main():
    rpc = Rpc(rpc_url())
    if int(rpc.call("eth_chainId", []), 16) != 84532:
        raise RuntimeError("wrong chain")
    tx = rpc.call("eth_getTransactionByHash", [TX])
    receipt = rpc.call("eth_getTransactionReceipt", [TX])
    if not tx or not receipt or tx["input"][:10].lower() != "0x65a14ce4":
        raise RuntimeError("unexpected source transaction")
    if int(receipt["status"], 16) != 1 or int(receipt["blockNumber"], 16) != 55064570:
        raise RuntimeError("source transaction not final at pinned block")
    calldata = bytes.fromhex(tx["input"][2:])
    # ABI bytes[] with one element. All offsets are checked before extraction.
    if word(calldata, 4) != 32 or word(calldata, 36) != 1 or word(calldata, 68) != 32:
        raise RuntimeError("unexpected calldata layout")
    size = word(calldata, 100)
    payload = calldata[132:132 + size]
    if size < 64 or len(payload) != size or payload[:4] != b"PNAU":
        raise RuntimeError("not a Pyth Core accumulator update")
    matching = [
        log for log in receipt["logs"]
        if log["address"].lower() == PYTH
        and len(log["topics"]) >= 2
        and log["topics"][0].lower() == TOPIC
        and log["topics"][1].lower() == ETH_ID
    ]
    if len(matching) != 1:
        raise RuntimeError("expected one matching Pyth price event")
    publish_time = word(bytes.fromhex(matching[0]["data"][2:]), 0)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("0x" + payload.hex())
    print("PYTH_FIXTURE_SOURCE_TX=" + TX)
    print("PYTH_FIXTURE_BLOCK=55064570")
    print("PYTH_FIXTURE_PUBLISH_TIME=" + str(publish_time))
    print("PYTH_FIXTURE_BYTES=" + str(size))
    print("PYTH_FIXTURE_SHA256=" + hashlib.sha256(payload).hexdigest())


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("PYTH_FIXTURE_BLOCKED=" + type(exc).__name__, file=sys.stderr)
        raise SystemExit(1)
