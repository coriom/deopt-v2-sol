#!/usr/bin/env python3
"""Read-only Base Sepolia runtime identity and M2 transaction-boundary verifier.

RPC_URL is read from the environment and is never printed. No signing, writes,
CBOR generation, or subprocess invocation of forge is performed here.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import urllib.request

from snapshot_hash import keccak256

ROOT = Path(__file__).resolve().parents[2]
OWNER = "0xc35F7A8A103A9A4464adfaa76B9B514093D23C27"
OLD = "0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9"
PMR = "0xAD8B0855d1fd649539A344AD594bf86929cf0FF7"
VAULT = "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3"
ORACLE = "0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581"
ENGINE_HASH = "0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a"
PMR_HASH = "0x70a03433c8f58ac8e97e6caa5c0e488db1440c05aa1dce46b0fef4930e8194f5"
SNAPSHOT_HASH = "0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d"
LIBRARIES = {
    "PerpEngineLiquidationLib": "0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D",
    "PerpEngineSeizureLib": "0xf0C5652277CF88B508E05F7aB54949fCDF0360A5",
}
SETTERS = [
    ("setMatchingEngine(address)", "0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2"),
    ("setRiskModule(address)", "0x8C3d9F71cA59B908Fa200546A63ea62F9C932998"),
    ("setClearingAccount(address)", "0x54d49c088DD27cFc82685b867c182b4bB4aC435c"),
    ("setInsuranceFund(address)", "0x009f38440F058d095b61E0E2ee7fAbDF05BE7500"),
    ("setCollateralSeizer(address)", "0x39F928b959cF58369E7C7a3B925e6cBfFA62B669"),
    ("setFeesManagerV2(address)", "0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f"),
    ("setUseFeesManagerV2(bool)", "true"),
    ("setGuardian(address)", OWNER),
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def digest(data):
    return "0x" + keccak256(data).hex()


def rpc(method, params):
    require(method in {"eth_chainId", "eth_getBlockByNumber", "eth_getCode", "eth_getTransactionCount"},
            "RPC method outside read-only verifier allowlist")
    try:
        req = urllib.request.Request(
            os.environ["RPC_URL"],
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.load(response)
    except Exception:
        raise RuntimeError("Read-only RPC transport/configuration failure; endpoint redacted") from None
    if "error" in result:
        raise RuntimeError(f"Read-only RPC failed for {method}; provider details redacted")
    return result["result"]


def linked(artifact, field):
    data = artifact[field]["object"].removeprefix("0x")
    for libraries in artifact[field].get("linkReferences", {}).values():
        for name, refs in libraries.items():
            address = LIBRARIES[name].removeprefix("0x")
            for ref in refs:
                require(ref["length"] == 20, "unexpected link reference length")
                start = ref["start"] * 2
                data = data[:start] + address + data[start + 40:]
    return bytes.fromhex(data)


def predict(nonce):
    # Independent RLP construction, cross-checked with Foundry's CREATE helper.
    raw = nonce.to_bytes((nonce.bit_length() + 7) // 8, "big")
    encoded = raw if 0 < nonce < 128 else bytes([128 + len(raw)]) + raw
    payload = b"\x94" + bytes.fromhex(OWNER[2:]) + encoded
    address = "0x" + keccak256(bytes([192 + len(payload)]) + payload)[-20:].hex()
    require(cast("compute-address", OWNER, "--nonce", str(nonce)).split()[-1].lower() == address,
            "CREATE derivations disagree")
    if nonce == 790:
        require(address == "0xa2bdc0efe80806ffda20189294dd8a5a1b426f15", "nonce-790 prediction drift")
    return address


def verify_transactions(path, artifact, nonce, predicted):
    run = json.loads(path.read_text())
    require(int(run["chain"]) == 84532, "wrong dry-run chain")
    require(not run.get("receipts") and not run.get("pending"), "expected an unbroadcast dry-run")
    txs = run["transactions"]
    require(len(txs) == 9, "M2 must contain exactly nine transactions, including no library deploys")
    constructor = [OWNER, PMR, VAULT, ORACLE]
    creation = linked(artifact, "bytecode") + b"".join(bytes.fromhex(a[2:]).rjust(32, b"\0") for a in constructor)
    records = []
    for i, item in enumerate(txs):
        tx = item["transaction"]
        require(tx["from"].lower() == OWNER.lower(), "unexpected transaction sender")
        require(int(tx["nonce"], 16) == nonce + i, "unexpected nonce sequence")
        require(int(tx["chainId"], 16) == 84532, "unexpected transaction chain")
        require(int(tx.get("value", "0x0"), 16) == 0, "nonzero transaction value")
        require(not item.get("additionalContracts"), "unexpected nested deployment")
        if i == 0:
            require(item["transactionType"] == "CREATE" and not tx.get("to"), "first transaction is not CREATE")
            require(item["contractAddress"].lower() == predicted, "CREATE target mismatch")
            require(bytes.fromhex(tx["input"][2:]) == creation, "creation code, libraries or constructor mismatch")
            function, selector, args, target = "constructor(address,address,address,address)", None, constructor, "CREATE"
        else:
            function, argument = SETTERS[i - 1]
            expected = cast("calldata", function, argument)
            require(item["transactionType"] == "CALL", "setter is not CALL")
            require(tx["to"].lower() == predicted, "shared dependency or unexpected target mutation")
            require(tx["input"].lower() == expected.lower(), "unexpected setter or argument")
            selector, args, target = expected[:10], [argument], predicted
        records.append({"ordinal": i + 1, "nonce": nonce + i, "target": target,
                        "function": function, "selector": selector, "args": args})
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "out")
    parser.add_argument("--dry-run", type=Path)
    args = parser.parse_args()
    require(int(rpc("eth_chainId", []), 16) == 84532, "Base Sepolia chain ID required")
    block = rpc("eth_getBlockByNumber", ["latest", False])
    report = {"chainId": 84532, "block": int(block["number"], 16), "blockHash": block["hash"], "runtimes": {}}
    engine_artifact = None
    for name, address, size, expected in [("PerpEngineV2", OLD, 24321, ENGINE_HASH),
                                           ("PerpMarketRegistry", PMR, 13217, PMR_HASH)]:
        artifact = json.loads((args.artifacts / (name + ".sol") / (name + ".json")).read_text())
        local = linked(artifact, "deployedBytecode")
        live = bytes.fromhex(rpc("eth_getCode", [address, block["number"]])[2:])
        require(local == live, name + " live/local byte mismatch")
        require(len(local) == size and digest(local) == expected, name + " frozen identity mismatch")
        report["runtimes"][name] = {"bytes": size, "ethereumKeccak256": expected, "byteIdentical": True}
        if name == "PerpEngineV2":
            engine_artifact = artifact
    report["snapshotHash"] = digest((ROOT / "artifacts/perps_v2_final_snapshot/manifest.cbor").read_bytes())
    require(report["snapshotHash"] == SNAPSHOT_HASH, "canonical CBOR hash drift")
    nonce = int(rpc("eth_getTransactionCount", [OWNER, "latest"]), 16)
    pending = int(rpc("eth_getTransactionCount", [OWNER, "pending"]), 16)
    require(nonce == pending, "pending OWNER transaction; prediction is not safe")
    predicted = predict(nonce)
    require(rpc("eth_getCode", [predicted, "latest"]) == "0x", "predicted address already has code")
    report.update(ownerNonce=nonce, pendingNonce=pending, predictedEngine=predicted, predictedCode="0x")
    if args.dry_run:
        report["transactions"] = verify_transactions(args.dry_run, engine_artifact, nonce, predicted)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
