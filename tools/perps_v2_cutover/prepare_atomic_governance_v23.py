#!/usr/bin/env python3
"""Read-only, fail-closed S2 preflight and unsigned Safe package."""

import argparse
import hashlib
import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import prepare_atomic_governance_v22 as v22

V21_FILE = v22.ART / "c02_atomic_governance_v21_conditional.json"
V21_SHA256 = "8af8f6e97a07ae64914896eaf2887f55d5756e2d08ca746d64aaafc4592c938b"
MKT_S1_TX = "0xd0fa2915b6db15415b97eaf45987625f8ff94f95b42d9c748cb8414de3a8d1de"
ETA = 1794657600


def require(actual: object, expected: object, label: str) -> None:
    v22.v21.must(str(actual), str(expected), label)


def queued_receipt(rpc_url: str, pinned_block: int, tx_hash: str,
                   action: dict, safe_hash: str) -> dict:
    receipt = json.loads(v22.rpc(rpc_url, "receipt", tx_hash, "--json"))
    require(receipt["status"], "0x1", "S1 receipt status")
    height = int(receipt["blockNumber"], 16)
    if height > pinned_block:
        raise SystemExit("STOP: S1 receipt after pinned block")
    require(v22.rpc(rpc_url, "block", str(height), "--field", "hash"),
            receipt["blockHash"], "S1 canonical block hash")
    queued = [
        log for log in receipt["logs"]
        if log["address"].lower() == v22.v21.TL.lower()
        and log["topics"][0].lower() == v22.TOPIC_QUEUED
    ]
    success = [
        log for log in receipt["logs"]
        if log["address"].lower() == v22.v21.SAFE.lower()
        and log["topics"][0].lower() == v22.TOPIC_SAFE_SUCCESS
    ]
    if len(queued) != 1 or len(success) != 1:
        raise SystemExit("STOP: S1 receipt lacks unique queue or Safe success")
    event = queued[0]
    require(event["topics"][1], action["operationId"], "S1 queued ID")
    require("0x" + event["topics"][2][-40:], v22.v21.D1, "S1 queued target")
    require(success[0]["topics"][1], safe_hash, "S1 Safe hash")
    raw = bytes.fromhex(event["data"][2:])
    value = int.from_bytes(raw[:32], "big")
    offset = int.from_bytes(raw[32:64], "big")
    eta = int.from_bytes(raw[64:96], "big")
    n = int.from_bytes(raw[offset:offset + 32], "big")
    inner = "0x" + raw[offset + 32:offset + 32 + n].hex()
    require(value, 0, "S1 ETH value")
    require(eta, ETA, "S1 ETA")
    require(inner, action["innerCalldata"], "S1 queued calldata")
    if any(log["address"].lower() in {
        v22.v21.D1.lower(), v22.v21.D4.lower(), v22.v21.D6.lower()
    } for log in receipt["logs"]):
        raise SystemExit("STOP: S1 receipt has market or pause event")
    return {"transactionHash": tx_hash, "blockNumber": height,
            "blockHash": receipt["blockHash"], "operationId": action["operationId"],
            "queuedEvents": 1, "safeSuccessEvents": 1}


def unpack_multisend(calldata: str) -> list[dict]:
    raw = bytes.fromhex(calldata[2:])
    require("0x" + raw[:4].hex(), "0x8d80ff0a", "MultiSend selector")
    offset = int.from_bytes(raw[4:36], "big")
    length = int.from_bytes(raw[4 + offset:4 + offset + 32], "big")
    packed = raw[4 + offset + 32:4 + offset + 32 + length]
    if len(packed) != length:
        raise SystemExit("STOP: malformed MultiSend packed length")
    calls = []
    pos = 0
    while pos < len(packed):
        if len(packed) - pos < 85:
            raise SystemExit("STOP: malformed MultiSend packed call")
        op = packed[pos]
        to = "0x" + packed[pos + 1:pos + 21].hex()
        value = int.from_bytes(packed[pos + 21:pos + 53], "big")
        n = int.from_bytes(packed[pos + 53:pos + 85], "big")
        data = "0x" + packed[pos + 85:pos + 85 + n].hex()
        if len(data) != 2 + 2 * n:
            raise SystemExit("STOP: truncated MultiSend call")
        calls.append({"operation": op, "to": to, "value": value, "data": data})
        pos += 85 + n
    if pos != length:
        raise SystemExit("STOP: MultiSend trailing bytes")
    return calls


def check_remote_evidence(path: Path, snapshot_time: int, strict: bool) -> dict:
    if not path.is_file():
        if strict:
            raise SystemExit("STOP: remote executor evidence file missing")
        return {"status": "UNKNOWN", "reason": "remote executor evidence file missing"}
    evidence = json.loads(path.read_text())
    required = ("vercel", "railway", "netcup")
    states = evidence.get("providers", {})
    if strict:
        checked = evidence.get("checkedAtUnix")
        if not isinstance(checked, int) or checked > snapshot_time or snapshot_time - checked > 6 * 3600:
            raise SystemExit("STOP: remote executor evidence missing or stale")
        for name in required:
            row = states.get(name, {})
            if row.get("status") not in ("VERIFIED_INACTIVE", "NOT_DEPLOYED"):
                raise SystemExit("STOP: remote executor isolation not proved for " + name)
            if not row.get("providerProof"):
                raise SystemExit("STOP: provider proof missing for " + name)
    return {
        "status": "VERIFIED" if strict else "PREVIEW_ONLY",
        "checkedAtUnix": evidence.get("checkedAtUnix"),
        "providers": {name: {
            "status": states.get(name, {}).get("status", "UNKNOWN"),
            "providerProof": states.get(name, {}).get("providerProof", "")
        } for name in required},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", default="https://sepolia.base.org")
    parser.add_argument("--block", type=int,
                        help="Pin a specific block; omit to pin current latest")
    parser.add_argument("--prepare-pending", action="store_true",
                        help="Draft only before ETA; never signals S2 readiness")
    parser.add_argument("--remote-evidence", type=Path,
                        default=Path("artifacts/perps_v2_replacement_deployment/v23_remote_executor_evidence.json"))
    parser.add_argument("--out", type=Path, default=Path("/tmp/deopt-v23-s2-preflight.json"))
    parser.add_argument("--builder-out", type=Path,
                        default=Path("/tmp/deopt-v23-s2-builder-unsigned.json"))
    args = parser.parse_args()
    strict = not args.prepare_pending
    require(v22.rpc(args.rpc, "chain-id"), "84532", "chain ID")
    block = args.block or int(v22.rpc(args.rpc, "block-number"))
    block_hash = v22.rpc(args.rpc, "block", str(block), "--field", "hash")
    timestamp = int(v22.rpc(args.rpc, "block", str(block), "--field", "timestamp"))
    if strict and timestamp < ETA:
        raise SystemExit("STOP: ETA not reached")
    if timestamp > ETA + 14 * 86400:
        raise SystemExit("STOP: operation grace expired")
    require(hashlib.sha256(V21_FILE.read_bytes()).hexdigest(), V21_SHA256, "V21 package SHA256")
    saved = json.loads(V21_FILE.read_text())
    derived = v22.V10.derive(ETA)
    c02, mkt, batch = derived["separatelyAuthorizedSafeActions"]
    for old, new in zip(saved["separatelyAuthorizedSafeActions"], (c02, mkt, batch), strict=True):
        for field in ("to", "operation", "calldata", "calldataKeccak256"):
            require(new[field], old[field], "V21 action " + field)
    receipts = [
        queued_receipt(args.rpc, block, v22.C02_S1_TX, c02, v22.C02_SAFE_HASH),
        queued_receipt(args.rpc, block, MKT_S1_TX, mkt, v22.MKT_SAFE_HASH),
    ]
    calls = unpack_multisend(batch["calldata"])
    if len(calls) != 2:
        raise SystemExit("STOP: S2 is not exactly two inner calls")
    for index, action in enumerate((c02, mkt)):
        require(calls[index]["operation"], 0, "S2 inner CALL")
        require(calls[index]["to"], v22.v21.TL, "S2 inner Timelock target")
        require(calls[index]["value"], 0, "S2 inner ETH value")
        execute = subprocess.check_output(
            ["cast", "calldata", "executeTransaction(address,uint256,bytes,uint256)",
             v22.v21.D1, "0", action["innerCalldata"], str(ETA)],
            text=True, timeout=30,
        ).strip()
        require(calls[index]["data"], execute, "S2 inner execute calldata")
    checks = {
        "oldMktQueued": (v22.v21.TL, "queuedTransactions(bytes32)(bool)", v22.V10.v9.OLD_MKT),
        "c02Queued": (v22.v21.TL, "queuedTransactions(bytes32)(bool)", c02["operationId"]),
        "mktQueued": (v22.v21.TL, "queuedTransactions(bytes32)(bool)", mkt["operationId"]),
        "c02Ready": (v22.v21.TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                     v22.v21.D1, "0", c02["innerCalldata"], str(ETA)),
        "mktReady": (v22.v21.TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                     v22.v21.D1, "0", mkt["innerCalldata"], str(ETA)),
        "safeNonce": (v22.v21.SAFE, "nonce()(uint256)"),
        "safeVersion": (v22.v21.SAFE, "VERSION()(string)"),
        "safeThreshold": (v22.v21.SAFE, "getThreshold()(uint256)"),
        "safeOwners": (v22.v21.SAFE, "getOwners()(address[])"),
        "safeModules": (v22.v21.SAFE, "getModulesPaginated(address,uint256)(address[],address)",
                        "0x" + "0" * 39 + "1", "10"),
        "safeGuard": (v22.v21.SAFE, "getStorageAt(uint256,uint256)(bytes)",
                      str(v22.v21.GUARD_SLOT), "1"),
        "timelockOwner": (v22.v21.TL, "owner()(address)"),
        "timelockGuardian": (v22.v21.TL, "guardian()(address)"),
        "timelockDelay": (v22.v21.TL, "minDelay()(uint256)"),
        "timelockQueuePaused": (v22.v21.TL, "queuePaused()(bool)"),
        "safeProposer": (v22.v21.TL, "proposers(address)(bool)", v22.v21.SAFE),
        "safeExecutor": (v22.v21.TL, "executors(address)(bool)", v22.v21.SAFE),
        "openExecutor": (v22.v21.TL, "executors(address)(bool)", v22.v21.ZERO),
        "oldDeployerExecutor": (v22.v21.TL, "executors(address)(bool)",
                                "0xc35F7A8A103A9A4464adfaa76B9B514093D23C27"),
        "backendRuntimeExecutor": (v22.v21.TL, "executors(address)(bool)",
                                   "0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8"),
        "markets": (v22.v21.D1, "totalMarkets()(uint256)"),
        "nextMarketId": (v22.v21.D1, "nextMarketId()(uint256)"),
        "registryOwner": (v22.v21.D1, "owner()(address)"),
        "registryCreator": (v22.v21.D1, "isMarketCreator(address)(bool)", v22.v21.TL),
        "registryCreationPaused": (v22.v21.D1, "creationPaused()(bool)"),
        "registryConfigPaused": (v22.v21.D1, "configPaused()(bool)"),
        "d4TradingPaused": (v22.v21.D4, "tradingPaused()(bool)"),
        "d4LiquidationPaused": (v22.v21.D4, "liquidationPaused()(bool)"),
        "d4FundingPaused": (v22.v21.D4, "fundingPaused()(bool)"),
        "d4CollateralPaused": (v22.v21.D4, "collateralOpsPaused()(bool)"),
        "d6Paused": (v22.v21.D6, "paused()(bool)"),
    }
    def read(item):
        name, spec = item
        return name, v22.v21.call(args.rpc, block, "call", spec[0], spec[1], *spec[2:])
    with ThreadPoolExecutor(max_workers=3) as pool:
        state = dict(pool.map(read, checks.items()))
    expected = {
        "oldMktQueued": "true", "c02Queued": "true", "mktQueued": "true",
        "c02Ready": "true" if strict else "false",
        "mktReady": "true" if strict else "false",
        "safeNonce": "45", "safeVersion": '"1.4.1"', "safeThreshold": "2",
        "safeGuard": "0x" + "0" * 64,
        "timelockOwner": v22.v21.SAFE, "timelockGuardian": v22.v21.SAFE,
        "timelockQueuePaused": "false", "safeProposer": "true",
        "safeExecutor": "true", "openExecutor": "false",
        "oldDeployerExecutor": "false", "backendRuntimeExecutor": "false",
        "markets": "0", "nextMarketId": "1", "registryOwner": v22.v21.TL,
        "registryCreator": "true", "registryCreationPaused": "false",
        "registryConfigPaused": "false", "d4TradingPaused": "true",
        "d4LiquidationPaused": "true", "d4FundingPaused": "true",
        "d4CollateralPaused": "true", "d6Paused": "true",
    }
    for name, value in expected.items():
        require(state[name], value, name)
    if int(state["timelockDelay"].split()[0]) != 86400:
        raise SystemExit("STOP: Timelock delay drift")
    owners = {x.lower() for x in state["safeOwners"].strip("[]").split(", ")}
    if owners != v22.v21.OWNERS or not state["safeModules"].startswith(
        "[]\n" + "0x" + "0" * 39 + "1"
    ):
        raise SystemExit("STOP: Safe owners/modules drift")
    refs = {
        item["stage"]: (item["address"], item["runtimeHash"])
        for item in json.loads(
            (v22.ART / "m1_d6_pause_scheduling_final_review_v1.json").read_text()
        )["canonicalDeployments"]
        if item.get("stage") in ("D1", "D2", "D3", "D4", "D6")
    }
    refs.update({
        "Safe": (v22.v21.SAFE, "0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c"),
        "Timelock": (v22.v21.TL, "0xb20f9fa764b46a832c7665f07c1b9c3cd6506a58f6885c0e12e88e9bbc55233c"),
        "MultiSendCallOnly": (v22.V10.v9.MULTISEND,
                              "0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939"),
    })
    with ThreadPoolExecutor(max_workers=3) as pool:
        hashes = dict(pool.map(
            lambda row: (row[0], v22.v21.call(args.rpc, block, "codehash", row[1][0])),
            refs.items()))
    for name, (_, digest) in refs.items():
        require(hashes[name], digest, name + " code hash")
    safe_hash = v22.v21.call(
        args.rpc, block, "call", v22.v21.SAFE,
        "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
        batch["to"], "0", batch["calldata"], "1", "0", "0", "0",
        v22.v21.ZERO, v22.v21.ZERO, "45")
    require(safe_hash, saved["safeTransactionHashes"][2]["hash"], "fresh S2 Safe hash")
    remote = check_remote_evidence(args.remote_evidence, timestamp, strict)
    evidence = {
        "schema": "deopt.perps.v23.atomic.s2.unsigned",
        "status": "PREVIEW_ONLY_NO_S2_AUTHORIZATION" if not strict else "PREFLIGHT_PASS_NO_S2_AUTHORIZATION",
        "snapshot": {"blockNumber": block, "blockHash": block_hash, "timestamp": timestamp},
        "canonicalS1Receipts": receipts,
        "state": state, "codeHashes": hashes, "remoteExecutors": remote,
        "atomicBatch": {
            "to": batch["to"], "valueWei": 0, "operation": 1,
            "data": batch["calldata"], "dataHash": batch["calldataKeccak256"],
            "innerCalls": calls, "safeNonce": 45, "safeTransactionHash": safe_hash,
            "safeTxGas": 0, "baseGas": 0, "gasPrice": 0,
            "gasToken": v22.v21.ZERO, "refundReceiver": v22.v21.ZERO,
        },
        "referenceV21Sha256": V21_SHA256,
        "warning": "Unsigned package only. Synthetic fork approvals are not Safe signatures.",
    }
    args.out.write_text(json.dumps(evidence, indent=2) + "\n")
    builder = {
        "version": "1.0", "chainId": "84532", "createdAt": timestamp * 1000,
        "meta": {
            "name": "UNSIGNED_V23_ATOMIC_S2_TWO_CALLS_ONLY",
            "description": "Review only; S2 requires separate operator approval after ETA.",
            "txBuilderVersion": "1.18.0", "createdFromSafeAddress": v22.v21.SAFE,
            "createdFromOwnerAddress": "",
        },
        "transactions": [
            {"to": v22.v21.TL, "value": "0", "data": call["data"],
             "contractMethod": {"name": "executeTransaction", "payable": True,
                                "inputs": [
                                    {"name": "target", "type": "address", "internalType": "address"},
                                    {"name": "value", "type": "uint256", "internalType": "uint256"},
                                    {"name": "data", "type": "bytes", "internalType": "bytes"},
                                    {"name": "eta", "type": "uint256", "internalType": "uint256"},
                                ]},
             "contractInputsValues": {
                 "target": v22.v21.D1, "value": "0",
                 "data": action["innerCalldata"], "eta": str(ETA),
             }}
            for call, action in zip(calls, (c02, mkt), strict=True)
        ],
    }
    args.builder_out.write_text(json.dumps(builder, indent=2) + "\n")
    print("V23_PREFLIGHT=" + ("PASS" if strict else "PREVIEW_ONLY"))
    print("BLOCK=" + str(block) + " HASH=" + block_hash)
    print("C02=" + c02["operationId"] + " MKT1=" + mkt["operationId"])
    print("SAFE_NONCE=45 SAFE_HASH=" + safe_hash)
    print("INNER_CALLS=2 ORDER=C02_THEN_MKT1 OPERATION=DELEGATECALL")
    print("REMOTE_EXECUTORS=" + remote["status"])
    print("PACKAGE_SHA256=" + hashlib.sha256(args.out.read_bytes()).hexdigest())
    print("BUILDER_SHA256=" + hashlib.sha256(args.builder_out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
