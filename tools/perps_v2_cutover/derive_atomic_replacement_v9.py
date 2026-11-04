#!/usr/bin/env python3
"""Derive review-only C02/MKT1 replacement bytes from previously reviewed calldata.

No RPC, signatures, private keys, Safe proposals or broadcast paths are used.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
TL = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
D1 = "0x6B3D846536116082dC4E7227861C341Bb85Ee963"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
MULTISEND = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
OLD_C02 = "0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e"
OLD_MKT = "0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268"
OLD_C02_ETA = 1792929600
OLD_MKT_ETA = 1793534400
SNAPSHOT_TIME = 1793799782
DEFAULT_ETA = 1794312000  # 2026-11-10 12:00 UTC


def cast(*args: str) -> str:
    return subprocess.check_output(["cast", *args], text=True).strip()


def calldata(fn: str, inner: str, eta: int) -> str:
    return cast("calldata", f"{fn}(address,uint256,bytes,uint256)", D1, "0", inner, str(eta))


def operation_id(inner: str, eta: int) -> str:
    abi = cast("abi-encode", "f(address,uint256,bytes,uint256)", D1, "0", inner, str(eta))
    return cast("keccak", abi)


def keccak(encoded: str) -> str:
    return cast("keccak", encoded)


def read_inner(path: str) -> str:
    obj = json.loads((ART / path).read_text())
    return obj["transactions"][0]["contractInputsValues"]["data"]


def action(label: str, method: str, inner: str, eta: int) -> dict:
    data = calldata(method, inner, eta)
    return {"label": label, "to": TL, "value": "0", "operation": 0, "method": method,
            "target": D1, "innerCalldata": inner, "eta": eta, "calldata": data,
            "calldataKeccak256": keccak(data), "operationId": operation_id(inner, eta)}


def packed_call(data: str) -> bytes:
    raw = bytes.fromhex(data[2:])
    return b"\x00" + bytes.fromhex(TL[2:]) + bytes(32) + len(raw).to_bytes(32, "big") + raw


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--eta", type=int, default=DEFAULT_ETA)
    p.add_argument("--out", type=Path, default=ART / "c02_atomic_replacement_v9_conditional.json")
    p.add_argument("--cancel-builder", type=Path, default=ART / "c02_cancel_v9_unsigned_builder.json")
    args = p.parse_args()
    if args.eta < SNAPSHOT_TIME + 86400:
        raise SystemExit("ETA has insufficient Timelock delay at pinned snapshot")

    c02 = read_inner("c02_market_creation_s1_safe_builder_review_v1.json")
    mkt = read_inner("mkt1_inactive_early_s1_safe_builder_final_review_v1.json")
    if operation_id(c02, OLD_C02_ETA).lower() != OLD_C02 or operation_id(mkt, OLD_MKT_ETA).lower() != OLD_MKT:
        raise SystemExit("previously reviewed operation identity drift")
    if not c02.startswith("0xbdb9df9a") or not mkt.startswith("0x85477fb3"):
        raise SystemExit("unexpected market selectors")

    actions = [
        action("CANCEL_OLD_C02", "cancelTransaction", c02, OLD_C02_ETA),
        action("CANCEL_OLD_MKT", "cancelTransaction", mkt, OLD_MKT_ETA),
        action("QUEUE_NEW_C02", "queueTransaction", c02, args.eta),
        action("QUEUE_NEW_MKT", "queueTransaction", mkt, args.eta),
    ]
    first = calldata("executeTransaction", c02, args.eta)
    second = calldata("executeTransaction", mkt, args.eta)
    batch_inner = "0x" + (packed_call(first) + packed_call(second)).hex()
    batch_outer = cast("calldata", "multiSend(bytes)", batch_inner)
    package = {
        "schema": "deopt.c02.atomic_replacement.conditional.v9",
        "status": "UNAPPROVED_POLICY_NOT_OPERATOR_READY_NO_PUBLIC_ACTION",
        "chainId": 84532,
        "snapshot": {"blockNumber": 54389568,
                     "blockHash": "0x70fd3860be640620a167d6d84ad0a0ace054071953d9f734e5afabef909ff6f9",
                     "timestamp": SNAPSHOT_TIME, "safeNonce": 43},
        "addresses": {"safe": SAFE, "timelock": TL, "marketRegistry": D1, "multiSendCallOnly": MULTISEND},
        "oldOperations": {"c02": OLD_C02, "mkt1": OLD_MKT},
        "newEta": args.eta,
        "queueCutoffAtMinimumDelay": args.eta - 86400,
        "newExpiryInclusive": args.eta + 14 * 86400,
        "newOperations": {"c02": actions[2]["operationId"], "mkt1": actions[3]["operationId"]},
        "safeActions": actions,
        "atomicExecution": {"to": MULTISEND, "value": "0", "operation": 1,
                            "method": "multiSend(bytes)", "subcallOrder": ["NEW_C02", "NEW_MKT"],
                            "innerTransactions": batch_inner, "data": batch_outer,
                            "calldataKeccak256": keccak(batch_outer)},
        "noncePolicy": "All Safe transaction hashes and signatures require fresh nonce/state at each separate authorization. No signatures are stored.",
        "governancePolicy": "Current C02-S2 postflight dependency forbids this batch. Explicit new operator policy approval is required before any scheduling or execution.",
    }
    builder = {
        "version": "1.0", "chainId": "84532", "createdAt": SNAPSHOT_TIME * 1000,
        "meta": {"name": "UNAPPROVED_C02_CANCEL_V9_REVIEW_ONLY", "description": "One-action unsigned Safe cancellation candidate; fresh state and separate operator authorization required.",
                 "txBuilderVersion": "1.18.0", "createdFromSafeAddress": SAFE, "createdFromOwnerAddress": ""},
        "transactions": [{"to": TL, "value": "0", "data": actions[0]["calldata"],
                          "contractMethod": {"name": "cancelTransaction", "payable": False,
                                             "inputs": [{"name": "target", "type": "address", "internalType": "address"},
                                                        {"name": "value", "type": "uint256", "internalType": "uint256"},
                                                        {"name": "data", "type": "bytes", "internalType": "bytes"},
                                                        {"name": "eta", "type": "uint256", "internalType": "uint256"}]},
                          "contractInputsValues": {"target": D1, "value": "0", "data": c02, "eta": str(OLD_C02_ETA)}}],
    }
    args.out.write_text(json.dumps(package, indent=2) + "\n")
    args.cancel_builder.write_text(json.dumps(builder, indent=2) + "\n")
    print("NEW_C02_OPERATION=" + package["newOperations"]["c02"])
    print("NEW_MKT_OPERATION=" + package["newOperations"]["mkt1"])
    print("CANCEL_BUILDER_SHA256=" + hashlib.sha256(args.cancel_builder.read_bytes()).hexdigest())
    print("PACKAGE_SHA256=" + hashlib.sha256(args.out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
