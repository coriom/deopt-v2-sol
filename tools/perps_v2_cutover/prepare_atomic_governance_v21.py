#!/usr/bin/env python3
"""Read-only, pinned-block V21 Safe package. Never signs or broadcasts."""

import argparse
import hashlib
import json
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import derive_atomic_governance_v10 as v10

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
SAFE = v10.v9.SAFE
TL = v10.v9.TL
D1 = v10.v9.D1
D4 = "0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB"
D6 = "0xeeA4e5d891B90D3d99E9C4e2c61069911477110E"
ZERO = "0x" + "0" * 40
OWNERS = {
    "0x0e7dcb5b9fd969e4fdc6f3a7b7993819ddc5a35d",
    "0xa774c46c41064524df895bd7be9f294409798dfc",
    "0xb9f8de807ff98d5730035a8bfed4bda33e886d06",
}
GUARD_SLOT = int("4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8", 16)


def call(rpc: str, block: int, *args: str) -> str:
    command = ["cast", *args, "--block", str(block), "--rpc-url", rpc]
    for attempt in range(3):
        try:
            return subprocess.check_output(command, text=True, timeout=40).strip()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)
    raise AssertionError("unreachable")


def must(actual: str, expected: str, label: str) -> None:
    if actual.lower() != expected.lower():
        raise SystemExit(f"STOP {label}: {actual} != {expected}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", default="https://sepolia.base.org")
    parser.add_argument("--block", required=True, type=int)
    parser.add_argument("--eta", required=True, type=int)
    parser.add_argument("--out", type=Path, default=ART / "c02_atomic_governance_v21_conditional.json")
    parser.add_argument("--builder-out", type=Path, default=ART / "c02_s1_safe_builder_v21_unsigned.json")
    args = parser.parse_args()

    approved = ART / "c02_atomic_governance_v10_conditional.json"
    must(hashlib.sha256(approved.read_bytes()).hexdigest(),
         "40bf7c13bfe839e23bd8a257a045969ad8de56f58c53a0be56c9049eca79937f",
         "V10 package SHA256")
    chain = subprocess.check_output(["cast", "chain-id", "--rpc-url", args.rpc], text=True, timeout=40).strip()
    must(chain, "84532", "chain ID")
    timestamp = int(subprocess.check_output(
        ["cast", "block", str(args.block), "--field", "timestamp", "--rpc-url", args.rpc],
        text=True, timeout=40).strip())
    block_hash = subprocess.check_output(
        ["cast", "block", str(args.block), "--field", "hash", "--rpc-url", args.rpc],
        text=True, timeout=40).strip()
    if timestamp <= v10.v9.OLD_C02_ETA + 14 * 86400:
        raise SystemExit("STOP: old C02 expiry not proven by canonical time")
    package = v10.derive(args.eta)
    acts = package["separatelyAuthorizedSafeActions"]

    checks = {
        "oldC02Queued": (TL, "queuedTransactions(bytes32)(bool)", v10.v9.OLD_C02),
        "oldC02Ready": (TL, "isOperationReady(address,uint256,bytes,uint256)(bool)", D1, "0",
                        acts[0]["innerCalldata"], str(v10.v9.OLD_C02_ETA)),
        "oldMktQueued": (TL, "queuedTransactions(bytes32)(bool)", v10.v9.OLD_MKT),
        "oldMktReady": (TL, "isOperationReady(address,uint256,bytes,uint256)(bool)", D1, "0",
                        acts[1]["innerCalldata"], str(v10.v9.OLD_MKT_ETA)),
        "markets": (D1, "totalMarkets()(uint256)"),
        "nextMarketId": (D1, "nextMarketId()(uint256)"),
        "registryOwner": (D1, "owner()(address)"),
        "registryCreator": (D1, "isMarketCreator(address)(bool)", TL),
        "registryCreationPaused": (D1, "creationPaused()(bool)"),
        "registryConfigPaused": (D1, "configPaused()(bool)"),
        "safeVersion": (SAFE, "VERSION()(string)"),
        "safeNonce": (SAFE, "nonce()(uint256)"),
        "safeThreshold": (SAFE, "getThreshold()(uint256)"),
        "safeOwners": (SAFE, "getOwners()(address[])"),
        "safeModules": (SAFE, "getModulesPaginated(address,uint256)(address[],address)",
                        "0x" + "0" * 39 + "1", "10"),
        "safeGuard": (SAFE, "getStorageAt(uint256,uint256)(bytes)", str(GUARD_SLOT), "1"),
        "timelockOwner": (TL, "owner()(address)"),
        "timelockGuardian": (TL, "guardian()(address)"),
        "timelockPendingOwner": (TL, "pendingOwner()(address)"),
        "timelockDelay": (TL, "minDelay()(uint256)"),
        "timelockQueuePaused": (TL, "queuePaused()(bool)"),
        "safeProposer": (TL, "proposers(address)(bool)", SAFE),
        "safeExecutor": (TL, "executors(address)(bool)", SAFE),
        "openExecutor": (TL, "executors(address)(bool)", ZERO),
        "newC02Queued": (TL, "queuedTransactions(bytes32)(bool)", acts[0]["operationId"]),
        "newMktQueued": (TL, "queuedTransactions(bytes32)(bool)", acts[1]["operationId"]),
        "d4TradingPaused": (D4, "tradingPaused()(bool)"),
        "d4LiquidationPaused": (D4, "liquidationPaused()(bool)"),
        "d4FundingPaused": (D4, "fundingPaused()(bool)"),
        "d4CollateralPaused": (D4, "collateralOpsPaused()(bool)"),
        "d6Paused": (D6, "paused()(bool)"),
    }
    def read(item):
        key, spec = item
        return key, call(args.rpc, args.block, "call", spec[0], spec[1], *spec[2:])
    with ThreadPoolExecutor(max_workers=3) as pool:
        state = dict(pool.map(read, checks.items()))
    expected = {
        "oldC02Queued": "true", "oldC02Ready": "false", "oldMktQueued": "true",
        "oldMktReady": "true", "markets": "0", "nextMarketId": "1",
        "registryOwner": TL, "registryCreator": "true",
        "registryCreationPaused": "false", "registryConfigPaused": "false",
        "safeVersion": '"1.4.1"', "safeThreshold": "2",
        "safeGuard": "0x" + "0" * 64, "timelockOwner": SAFE,
        "timelockGuardian": SAFE, "timelockPendingOwner": ZERO,
        "timelockQueuePaused": "false", "safeProposer": "true",
        "safeExecutor": "true", "openExecutor": "false",
        "newC02Queued": "false", "newMktQueued": "false",
        "d4TradingPaused": "true", "d4LiquidationPaused": "true",
        "d4FundingPaused": "true", "d4CollateralPaused": "true", "d6Paused": "true",
    }
    for key, value in expected.items():
        must(state[key], value, key)
    if int(state["timelockDelay"].split()[0]) != 86400:
        raise SystemExit("STOP: Timelock delay drift")
    if not state["safeModules"].startswith("[]\n" + "0x" + "0" * 39 + "1"):
        raise SystemExit("STOP: Safe modules drift")
    owners = {x.lower() for x in state["safeOwners"].strip("[]").split(", ")}
    if owners != OWNERS:
        raise SystemExit("STOP: Safe owners drift")
    if args.eta < timestamp + 86400 + 43200:
        raise SystemExit("STOP: ETA lacks 12-hour queue margin")

    references = {x["stage"]: (x["address"], x["runtimeHash"]) for x in json.loads(
        (ART / "m1_d6_pause_scheduling_final_review_v1.json").read_text()
    )["canonicalDeployments"] if x.get("stage") in ("D1", "D2", "D3", "D4", "D6")}
    references.update({"Safe": (SAFE, "0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c"),
                       "Timelock": (TL, "0xb20f9fa764b46a832c7665f07c1b9c3cd6506a58f6885c0e12e88e9bbc55233c"),
                       "MultiSendCallOnly": (v10.v9.MULTISEND,
                            "0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939")})
    with ThreadPoolExecutor(max_workers=3) as pool:
        hashes = dict(pool.map(lambda it: (it[0], call(args.rpc, args.block, "codehash", it[1][0])),
                               references.items()))
    for label, (_, known) in references.items():
        must(hashes[label], known, f"{label} code hash")

    nonce = int(state["safeNonce"].split()[0])
    safe_hashes = []
    for offset, action in enumerate(acts):
        safe_hashes.append(call(args.rpc, args.block, "call", SAFE,
            "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)",
            action["to"], "0", action["calldata"], str(action["operation"]),
            "0", "0", "0", ZERO, ZERO, str(nonce + offset)))
    package["schema"] = "deopt.c02.atomic_governance.conditional.v21"
    package["status"] = "POLICY_APPROVED_ACTION_NOT_AUTHORIZED_NO_SIGNATURE_NO_BROADCAST"
    package["snapshot"] = {"blockNumber": args.block, "blockHash": block_hash,
                           "timestamp": timestamp, "safeNonce": nonce}
    package["referenceV10Sha256"] = hashlib.sha256(approved.read_bytes()).hexdigest()
    package["readOnlyPreflight"] = {"checks": state, "runtimeCodeHashes": hashes}
    package["safeTransactionHashes"] = [
        {"action": action["label"], "nonceIfSequential": nonce + i, "hash": safe_hashes[i],
         "safeTxGas": 0, "baseGas": 0, "gasPrice": 0, "gasToken": ZERO,
         "refundReceiver": ZERO, "status": "CONDITIONAL_ONLY_NOT_FOR_SIGNATURE"}
        for i, action in enumerate(acts)]
    package["oldMktPolicy"] = "Leave queued; it cannot create or activate market 1. Never execute it."
    package["forkGasEvidence"] = {
        "block": 57250691,
        "test": "test/perp/PerpsV21ResumeFork.t.sol",
        "note": "Safe execution gas with fork-only owner preapprovals; not a public gas limit or genuine Safe signatures",
        "newC02S1SafeExecution": 69809,
        "newMkt1S1SafeExecution": 49392,
        "atomicS2SafeExecution": 380632,
        "operatorTransactionGasLimitCandidates": {"newC02S1": 250000, "newMkt1S1": 250000, "atomicS2": 1000000},
        "gate": "Re-estimate with the exact Safe payload and real signing path immediately before each action",
    }
    package["stopConditions"] = [
        "Any drift in Safe nonce, owners, threshold, guard, modules, Timelock roles/code/delay, registry code/market count or D4/D6 pauses",
        "Any new C02/MKT1 operation already queued, changed ETA, or missing 12-hour minimum queue margin",
        "Any inability to establish remote executor isolation before atomic S2",
        "Any mismatch in Safe UI target, operation CALL, value 0, calldata, nonce or gas fields",
    ]
    args.out.write_text(json.dumps(package, indent=2) + "\n")
    builder = {
        "version": "1.0", "chainId": "84532", "createdAt": timestamp * 1000,
        "meta": {
            "name": "UNSIGNED_V21_NEW_C02_S1_ONLY",
            "description": "Review-only Safe transaction. Separate operator authorization required. Never execute C02 alone.",
            "txBuilderVersion": "1.18.0", "createdFromSafeAddress": SAFE,
            "createdFromOwnerAddress": "",
        },
        "transactions": [{
            "to": TL, "value": "0", "data": acts[0]["calldata"],
            "contractMethod": {"name": "queueTransaction", "payable": False, "inputs": [
                {"name": "target", "type": "address", "internalType": "address"},
                {"name": "value", "type": "uint256", "internalType": "uint256"},
                {"name": "data", "type": "bytes", "internalType": "bytes"},
                {"name": "eta", "type": "uint256", "internalType": "uint256"},
            ]},
            "contractInputsValues": {"target": D1, "value": "0", "data": acts[0]["innerCalldata"],
                                     "eta": str(args.eta)},
        }],
    }
    builder_path = args.builder_out
    builder_path.write_text(json.dumps(builder, indent=2) + "\n")
    print("V21_PREFLIGHT=PASS")
    print("BLOCK=" + str(args.block) + " HASH=" + block_hash)
    print("ETA=" + str(args.eta))
    print("NEW_C02_OPERATION=" + acts[0]["operationId"])
    print("NEW_MKT1_OPERATION=" + acts[1]["operationId"])
    print("SAFE_NONCE=" + str(nonce))
    print("PACKAGE_SHA256=" + hashlib.sha256(args.out.read_bytes()).hexdigest())
    print("S1_BUILDER_SHA256=" + hashlib.sha256(builder_path.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
