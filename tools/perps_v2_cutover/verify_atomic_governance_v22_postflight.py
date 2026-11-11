#!/usr/bin/env python3
"""Read-only canonical receipt and pinned-state proof for MKT1 S1."""

import argparse
import hashlib
import json
from pathlib import Path

import prepare_atomic_governance_v22 as v22

TX = "0xd0fa2915b6db15415b97eaf45987625f8ff94f95b42d9c748cb8414de3a8d1de"
SAFE = v22.v21.SAFE
TL = v22.v21.TL
D1 = v22.v21.D1
D4 = v22.v21.D4
D6 = v22.v21.D6


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", default="https://sepolia.base.org")
    parser.add_argument("--block", required=True, type=int)
    parser.add_argument("--out", type=Path,
                        default=Path("/tmp/deopt-v22-mkt1-s1-postflight.json"))
    args = parser.parse_args()
    v22.v21.must(v22.rpc(args.rpc, "chain-id"), "84532", "chain ID")
    approved = v22.ART / "c02_atomic_governance_v21_conditional.json"
    v22.v21.must(hashlib.sha256(approved.read_bytes()).hexdigest(),
                 "8af8f6e97a07ae64914896eaf2887f55d5756e2d08ca746d64aaafc4592c938b",
                 "V21 package SHA256")
    package = json.loads(approved.read_text())
    c02, mkt = package["separatelyAuthorizedSafeActions"][:2]
    receipt = json.loads(v22.rpc(args.rpc, "receipt", TX, "--json"))
    transaction = json.loads(v22.rpc(args.rpc, "tx", TX, "--json"))
    v22.v21.must(receipt["status"], "0x1", "MKT1 receipt status")
    # Safe's sponsored relay wraps execTransaction in a separate outer call.
    # Verify the exact outer envelope and the inner Safe/Timelock events.
    v22.v21.must(transaction["to"], "0xdb9b1e94b5b69df7e401ddbede43491141047db3",
                 "MKT1 outer relay target")
    v22.v21.must(transaction["input"][:10], "0xcef6d209", "MKT1 outer relay selector")
    v22.v21.must(transaction["value"], "0x0", "MKT1 outer ETH value")
    receipt_block = int(receipt["blockNumber"], 16)
    if receipt_block > args.block:
        raise SystemExit("STOP: receipt after pinned postflight block")
    canonical_hash = v22.rpc(args.rpc, "block", str(receipt_block), "--field", "hash")
    v22.v21.must(canonical_hash, receipt["blockHash"], "MKT1 canonical block hash")
    queue_logs = [
        log for log in receipt["logs"]
        if log["address"].lower() == TL.lower()
        and log["topics"][0].lower() == v22.TOPIC_QUEUED
    ]
    if len(receipt["logs"]) != 5 or len(queue_logs) != 1:
        raise SystemExit("STOP: MKT1 receipt event count drift")
    observed_emitters = {log["address"].lower() for log in receipt["logs"]}
    expected_emitters = {
        SAFE.lower(), TL.lower(), "0x04658b29f6b82ed55274221a06fc97d318e25416",
        "0xdb9b1e94b5b69df7e401ddbede43491141047db3",
    }
    if observed_emitters != expected_emitters:
        raise SystemExit("STOP: unexpected receipt event emitter")
    event = queue_logs[0]
    v22.v21.must(event["topics"][1], mkt["operationId"], "MKT1 queued operation ID")
    v22.v21.must("0x" + event["topics"][2][-40:], D1, "MKT1 queued target")
    raw = bytes.fromhex(event["data"][2:])
    queued_value = int.from_bytes(raw[:32], "big")
    offset = int.from_bytes(raw[32:64], "big")
    eta = int.from_bytes(raw[64:96], "big")
    data_size = int.from_bytes(raw[offset:offset + 32], "big")
    inner = "0x" + raw[offset + 32:offset + 32 + data_size].hex()
    v22.v21.must(str(queued_value), "0", "MKT1 queued ETH value")
    v22.v21.must(str(eta), "1794657600", "MKT1 queued ETA")
    v22.v21.must(inner, mkt["innerCalldata"], "MKT1 queued calldata")
    safe_logs = [
        log for log in receipt["logs"]
        if log["address"].lower() == SAFE.lower()
        and log["topics"][0].lower() == v22.TOPIC_SAFE_SUCCESS
    ]
    if len(safe_logs) != 1:
        raise SystemExit("STOP: Safe ExecutionSuccess event absent")
    v22.v21.must(safe_logs[0]["topics"][1], v22.MKT_SAFE_HASH,
                 "MKT1 Safe transaction hash")
    check_specs = {
        "safeNonce": (SAFE, "nonce()(uint256)", (), "45"),
        "c02Queued": (TL, "queuedTransactions(bytes32)(bool)",
                      (c02["operationId"],), "true"),
        "mktQueued": (TL, "queuedTransactions(bytes32)(bool)",
                      (mkt["operationId"],), "true"),
        "oldMktQueued": (TL, "queuedTransactions(bytes32)(bool)",
                         (v22.V10.v9.OLD_MKT,), "true"),
        "c02Ready": (TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                     (D1, "0", c02["innerCalldata"], "1794657600"), "false"),
        "mktReady": (TL, "isOperationReady(address,uint256,bytes,uint256)(bool)",
                     (D1, "0", mkt["innerCalldata"], "1794657600"), "false"),
        "markets": (D1, "totalMarkets()(uint256)", (), "0"),
        "nextMarketId": (D1, "nextMarketId()(uint256)", (), "1"),
        "d4TradingPaused": (D4, "tradingPaused()(bool)", (), "true"),
        "d4LiquidationPaused": (D4, "liquidationPaused()(bool)", (), "true"),
        "d4FundingPaused": (D4, "fundingPaused()(bool)", (), "true"),
        "d4CollateralPaused": (D4, "collateralOpsPaused()(bool)", (), "true"),
        "d6Paused": (D6, "paused()(bool)", (), "true"),
    }
    state = {}
    for label, (address, signature, params, expected) in check_specs.items():
        value = v22.v21.call(
            args.rpc, args.block, "call", address, signature, *params
        )
        v22.v21.must(value, expected, label)
        state[label] = value
    c02_proof = v22.receipt_proof(args.rpc, args.block, c02, 1794657600)
    output = {
        "schema": "deopt.perps.v22.mkt1.s1.postflight",
        "verdict": "PASS",
        "chainId": 84532,
        "snapshot": {
            "blockNumber": args.block,
            "blockHash": v22.rpc(args.rpc, "block", str(args.block), "--field", "hash"),
            "timestamp": int(v22.rpc(args.rpc, "block", str(args.block), "--field", "timestamp")),
        },
        "mktReceipt": {
            "transactionHash": TX,
            "blockNumber": receipt_block,
            "blockHash": canonical_hash,
            "status": receipt["status"],
            "gasUsed": int(receipt["gasUsed"], 16),
            "logCount": len(receipt["logs"]),
            "outerTo": transaction["to"],
            "outerSelector": transaction["input"][:10],
            "outerValueWei": 0,
            "queuedEventCount": 1,
            "operationId": mkt["operationId"],
            "safeTransactionHash": v22.MKT_SAFE_HASH,
            "target": D1,
            "valueWei": queued_value,
            "eta": eta,
            "innerCalldataMatched": True,
        },
        "c02CanonicalReceipt": c02_proof,
        "state": state,
    }
    args.out.write_text(json.dumps(output, indent=2) + "\n")
    print("V22_POSTFLIGHT=PASS")
    print("BLOCK=" + str(args.block) + " HASH=" + output["snapshot"]["blockHash"])
    print("MKT1_TX=" + TX)
    print("MKT1_RECEIPT_BLOCK=" + str(receipt_block))
    print("MKT1_GAS_USED=" + str(output["mktReceipt"]["gasUsed"]))
    print("MKT1_QUEUED_EVENT=" + mkt["operationId"])
    print("SAFE_NONCE=45")
    print("C02_QUEUED=true MKT1_QUEUED=true MARKETS=0 D4_D6_PAUSED=true")
    print("EVIDENCE_SHA256=" + hashlib.sha256(args.out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
