#!/usr/bin/env python3
"""Pinned-block, read-only MKT1 S1 preflight after the canonical C02 S1 queue."""

import argparse
import hashlib
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import prepare_atomic_governance_v21 as v21

ART = v21.ART
V10 = v21.v10
TOPIC_QUEUED = "0x4efebf40a8244d219085e74f928a18e8c9d17adc6b39270b8706cca0a92b648d"
TOPIC_SAFE_SUCCESS = "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e"
C02_S1_TX = "0xc394fa4952f0a346a0a8c7f94789dbb8d0597b4205874880a5ae09f7529f38b6"
C02_SAFE_HASH = "0x6116c8250c4602fb17b9a93faf582f0d52574a78ece1e7504545cf5f83c96784"
MKT_SAFE_HASH = "0xd8dae05f3362d3dea6fd23497c14ec61ed3db2e2a78c4361e2192e1d60290e84"


def rpc(rpc_url: str, *args: str) -> str:
    return subprocess.check_output(
        ["cast", *args, "--rpc-url", rpc_url], text=True, timeout=45
    ).strip()


def receipt_proof(rpc_url: str, block: int, c02: dict, eta: int) -> dict:
    receipt = json.loads(rpc(rpc_url, "receipt", C02_S1_TX, "--json"))
    transaction = json.loads(rpc(rpc_url, "tx", C02_S1_TX, "--json"))
    v21.must(receipt["status"], "0x1", "C02 receipt status")
    v21.must(transaction["to"], v21.SAFE, "C02 Safe target")
    v21.must(transaction["input"][:10], "0x6a761202", "Safe execTransaction selector")
    receipt_block = int(receipt["blockNumber"], 16)
    if receipt_block > block:
        raise SystemExit("STOP: C02 receipt is after pinned preflight block")
    canonical_hash = rpc(rpc_url, "block", str(receipt_block), "--field", "hash")
    v21.must(canonical_hash, receipt["blockHash"], "C02 canonical block hash")
    queue_logs = [
        log for log in receipt["logs"]
        if log["address"].lower() == v21.TL.lower()
        and log["topics"][0].lower() == TOPIC_QUEUED
    ]
    if len(queue_logs) != 1 or len(receipt["logs"]) != 3:
        raise SystemExit("STOP: C02 receipt event count drift")
    event = queue_logs[0]
    v21.must(event["topics"][1], c02["operationId"], "C02 queued operation ID")
    v21.must("0x" + event["topics"][2][-40:], v21.D1, "C02 queued target")
    raw = bytes.fromhex(event["data"][2:])
    value = int.from_bytes(raw[:32], "big")
    offset = int.from_bytes(raw[32:64], "big")
    logged_eta = int.from_bytes(raw[64:96], "big")
    data_size = int.from_bytes(raw[offset:offset + 32], "big")
    inner = "0x" + raw[offset + 32:offset + 32 + data_size].hex()
    v21.must(str(value), "0", "C02 queued ETH value")
    v21.must(str(logged_eta), str(eta), "C02 queued ETA")
    v21.must(inner, c02["innerCalldata"], "C02 queued calldata")
    safe_success = [
        log for log in receipt["logs"]
        if log["address"].lower() == v21.SAFE.lower()
        and log["topics"][0].lower() == TOPIC_SAFE_SUCCESS
    ]
    if len(safe_success) != 1:
        raise SystemExit("STOP: C02 Safe execution success event absent")
    v21.must(safe_success[0]["topics"][1], C02_SAFE_HASH, "C02 Safe transaction hash")
    return {"transactionHash": C02_S1_TX, "blockNumber": receipt_block,
            "blockHash": canonical_hash, "status": receipt["status"],
            "queuedEvents": 1, "operationId": c02["operationId"],
            "safeTransactionHash": C02_SAFE_HASH}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", default="https://sepolia.base.org")
    parser.add_argument("--block", required=True, type=int)
    parser.add_argument("--eta", type=int, default=1794657600)
    parser.add_argument("--out", type=Path, default=Path("/tmp/deopt-v22-mkt1-s1-preflight.json"))
    parser.add_argument("--builder-out", type=Path,
                        default=Path("/tmp/deopt-v22-mkt1-s1-unsigned.json"))
    args = parser.parse_args()
    v21.must(rpc(args.rpc, "chain-id"), "84532", "chain ID")
    approved = ART / "c02_atomic_governance_v10_conditional.json"
    v21.must(hashlib.sha256(approved.read_bytes()).hexdigest(),
             "40bf7c13bfe839e23bd8a257a045969ad8de56f58c53a0be56c9049eca79937f",
             "V10 package SHA256")
    source = ART / "c02_atomic_governance_v21_conditional.json"
    v21.must(hashlib.sha256(source.read_bytes()).hexdigest(),
             "8af8f6e97a07ae64914896eaf2887f55d5756e2d08ca746d64aaafc4592c938b",
             "V21 package SHA256")
    original = json.loads(source.read_text())
    package = V10.derive(args.eta)
    c02, mkt = package["separatelyAuthorizedSafeActions"][:2]
    for index, action in enumerate((c02, mkt)):
        saved = original["separatelyAuthorizedSafeActions"][index]
        for field in ("operationId", "to", "calldata", "innerCalldata", "operation"):
            v21.must(str(action[field]), str(saved[field]), "V21 " + action["label"] + " " + field)
    block_hash = rpc(args.rpc, "block", str(args.block), "--field", "hash")
    timestamp = int(rpc(args.rpc, "block", str(args.block), "--field", "timestamp"))
    proof = receipt_proof(args.rpc, args.block, c02, args.eta)
    if args.eta < timestamp + 86400 + 43200:
        raise SystemExit("STOP: ETA lacks 12-hour queue margin")
    checks = {
        "oldC02Queued": (v21.TL, "queuedTransactions(bytes32)(bool)", V10.v9.OLD_C02),
        "oldC02Ready": (v21.TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                        v21.D1, "0", c02["innerCalldata"], str(V10.v9.OLD_C02_ETA)),
        "oldMktQueued": (v21.TL, "queuedTransactions(bytes32)(bool)", V10.v9.OLD_MKT),
        "oldMktReady": (v21.TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                        v21.D1, "0", mkt["innerCalldata"], str(V10.v9.OLD_MKT_ETA)),
        "newC02Queued": (v21.TL, "queuedTransactions(bytes32)(bool)", c02["operationId"]),
        "newC02Ready": (v21.TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                        v21.D1, "0", c02["innerCalldata"], str(args.eta)),
        "newMktQueued": (v21.TL, "queuedTransactions(bytes32)(bool)", mkt["operationId"]),
        "markets": (v21.D1, "totalMarkets()(uint256)"),
        "nextMarketId": (v21.D1, "nextMarketId()(uint256)"),
        "registryOwner": (v21.D1, "owner()(address)"),
        "registryCreator": (v21.D1, "isMarketCreator(address)(bool)", v21.TL),
        "registryCreationPaused": (v21.D1, "creationPaused()(bool)"),
        "registryConfigPaused": (v21.D1, "configPaused()(bool)"),
        "safeVersion": (v21.SAFE, "VERSION()(string)"),
        "safeNonce": (v21.SAFE, "nonce()(uint256)"),
        "safeThreshold": (v21.SAFE, "getThreshold()(uint256)"),
        "safeOwners": (v21.SAFE, "getOwners()(address[])"),
        "safeModules": (v21.SAFE, "getModulesPaginated(address,uint256)(address[],address)",
                        "0x" + "0" * 39 + "1", "10"),
        "safeGuard": (v21.SAFE, "getStorageAt(uint256,uint256)(bytes)",
                      str(v21.GUARD_SLOT), "1"),
        "timelockOwner": (v21.TL, "owner()(address)"),
        "timelockGuardian": (v21.TL, "guardian()(address)"),
        "timelockPendingOwner": (v21.TL, "pendingOwner()(address)"),
        "timelockDelay": (v21.TL, "minDelay()(uint256)"),
        "timelockQueuePaused": (v21.TL, "queuePaused()(bool)"),
        "safeProposer": (v21.TL, "proposers(address)(bool)", v21.SAFE),
        "safeExecutor": (v21.TL, "executors(address)(bool)", v21.SAFE),
        "openExecutor": (v21.TL, "executors(address)(bool)", v21.ZERO),
        "d4TradingPaused": (v21.D4, "tradingPaused()(bool)"),
        "d4LiquidationPaused": (v21.D4, "liquidationPaused()(bool)"),
        "d4FundingPaused": (v21.D4, "fundingPaused()(bool)"),
        "d4CollateralPaused": (v21.D4, "collateralOpsPaused()(bool)"),
        "d6Paused": (v21.D6, "paused()(bool)"),
    }
    def read(item):
        name, spec = item
        return name, v21.call(args.rpc, args.block, "call", spec[0], spec[1], *spec[2:])
    with ThreadPoolExecutor(max_workers=3) as pool:
        state = dict(pool.map(read, checks.items()))
    expected = {
        "oldC02Queued": "true", "oldC02Ready": "false",
        "oldMktQueued": "true", "oldMktReady": "true",
        "newC02Queued": "true", "newC02Ready": "false", "newMktQueued": "false",
        "markets": "0", "nextMarketId": "1",
        "registryOwner": v21.TL, "registryCreator": "true",
        "registryCreationPaused": "false", "registryConfigPaused": "false",
        "safeVersion": '"1.4.1"', "safeNonce": "44", "safeThreshold": "2",
        "safeGuard": "0x" + "0" * 64,
        "timelockOwner": v21.SAFE, "timelockGuardian": v21.SAFE,
        "timelockPendingOwner": v21.ZERO,
        "timelockQueuePaused": "false", "safeProposer": "true",
        "safeExecutor": "true", "openExecutor": "false",
        "d4TradingPaused": "true", "d4LiquidationPaused": "true",
        "d4FundingPaused": "true", "d4CollateralPaused": "true", "d6Paused": "true",
    }
    for key, value in expected.items():
        v21.must(state[key], value, key)
    if int(state["timelockDelay"].split()[0]) != 86400:
        raise SystemExit("STOP: Timelock delay drift")
    owners = {x.lower() for x in state["safeOwners"].strip("[]").split(", ")}
    if owners != v21.OWNERS or not state["safeModules"].startswith(
        "[]\n" + "0x" + "0" * 39 + "1"
    ):
        raise SystemExit("STOP: Safe owners or modules drift")
    references = {
        x["stage"]: (x["address"], x["runtimeHash"])
        for x in json.loads((ART / "m1_d6_pause_scheduling_final_review_v1.json").read_text()
        )["canonicalDeployments"] if x.get("stage") in ("D1", "D2", "D3", "D4", "D6")
    }
    references.update({
        "Safe": (v21.SAFE, "0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c"),
        "Timelock": (v21.TL, "0xb20f9fa764b46a832c7665f07c1b9c3cd6506a58f6885c0e12e88e9bbc55233c"),
        "MultiSendCallOnly": (V10.v9.MULTISEND,
                              "0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939"),
    })
    with ThreadPoolExecutor(max_workers=3) as pool:
        hashes = dict(pool.map(
            lambda row: (row[0], v21.call(args.rpc, args.block, "codehash", row[1][0])),
            references.items()))
    for name, (_, expected_hash) in references.items():
        v21.must(hashes[name], expected_hash, name + " code hash")
    safe_hash = v21.call(
        args.rpc, args.block, "call", v21.SAFE,
        "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
        mkt["to"], "0", mkt["calldata"], "0", "0", "0", "0",
        v21.ZERO, v21.ZERO, "44")
    v21.must(safe_hash, MKT_SAFE_HASH, "MKT1 S1 Safe transaction hash")
    builder = {
        "version": "1.0", "chainId": "84532", "createdAt": timestamp * 1000,
        "meta": {
            "name": "UNSIGNED_V22_NEW_MKT1_S1_ONLY",
            "description": "One authorized queue action only; never execute either Timelock operation alone.",
            "txBuilderVersion": "1.18.0", "createdFromSafeAddress": v21.SAFE,
            "createdFromOwnerAddress": "",
        },
        "transactions": [{
            "to": v21.TL, "value": "0", "data": mkt["calldata"],
            "contractMethod": {"name": "queueTransaction", "payable": False, "inputs": [
                {"name": "target", "type": "address", "internalType": "address"},
                {"name": "value", "type": "uint256", "internalType": "uint256"},
                {"name": "data", "type": "bytes", "internalType": "bytes"},
                {"name": "eta", "type": "uint256", "internalType": "uint256"},
            ]},
            "contractInputsValues": {
                "target": v21.D1, "value": "0", "data": mkt["innerCalldata"],
                "eta": str(args.eta),
            },
        }],
    }
    evidence = {
        "schema": "deopt.perps.v22.mkt1.s1.preflight",
        "status": "READ_ONLY_PREFLIGHT_PASS_NO_SIGNATURE_NO_BROADCAST",
        "snapshot": {"blockNumber": args.block, "blockHash": block_hash,
                     "timestamp": timestamp, "safeNonce": 44},
        "c02CanonicalReceipt": proof,
        "readOnlyPreflight": {"checks": state, "runtimeCodeHashes": hashes},
        "mkt1": {"operationId": mkt["operationId"], "eta": args.eta,
                 "calldata": mkt["calldata"], "safeTransactionHash": safe_hash,
                 "safeTxGas": 0, "baseGas": 0, "gasPrice": 0,
                 "gasToken": v21.ZERO, "refundReceiver": v21.ZERO},
        "referenceV21Sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
    }
    args.out.write_text(json.dumps(evidence, indent=2) + "\n")
    args.builder_out.write_text(json.dumps(builder, indent=2) + "\n")
    print("V22_PREFLIGHT=PASS")
    print("BLOCK=" + str(args.block) + " HASH=" + block_hash)
    print("C02_RECEIPT=" + proof["transactionHash"])
    print("MKT1_OPERATION=" + mkt["operationId"])
    print("SAFE_NONCE=44")
    print("SAFE_TX_HASH=" + safe_hash)
    print("ETA=" + str(args.eta))
    print("PACKAGE_SHA256=" + hashlib.sha256(args.out.read_bytes()).hexdigest())
    print("BUILDER_SHA256=" + hashlib.sha256(args.builder_out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
