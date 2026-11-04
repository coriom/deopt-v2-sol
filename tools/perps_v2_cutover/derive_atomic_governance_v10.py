#!/usr/bin/env python3
"""Derive conditional V10 Safe actions from reviewed C02/MKT1 calldata.

Offline only: no RPC, signature, Safe proposal, or public transaction.
"""
import argparse
import hashlib
import json
from pathlib import Path

import derive_atomic_replacement_v9 as v9

ART = v9.ART
ETA = 1794484800  # 2026-11-12 12:00 UTC, subject to fresh approval.
SNAPSHOT = {
    "blockNumber": 54397286,
    "blockHash": "0xd6ae2a2e4a78364cfd47903e8702e7130d30715027e0f6cb8a454dbffaa67fe0",
    "timestamp": 1793801326,
    "safeNonce": 43,
}


def derive(eta: int) -> dict:
    c02 = v9.read_inner("c02_market_creation_s1_safe_builder_review_v1.json")
    mkt = v9.read_inner("mkt1_inactive_early_s1_safe_builder_final_review_v1.json")
    if v9.operation_id(c02, v9.OLD_C02_ETA).lower() != v9.OLD_C02:
        raise ValueError("old C02 identity drift")
    if v9.operation_id(mkt, v9.OLD_MKT_ETA).lower() != v9.OLD_MKT:
        raise ValueError("old MKT1 identity drift")
    if not c02.startswith("0xbdb9df9a") or not mkt.startswith("0x85477fb3"):
        raise ValueError("unexpected D1 selector")
    if eta <= v9.OLD_C02_ETA + 14 * 86400 + 86400:
        raise ValueError("ETA lacks delay after old C02 expiry")

    first = v9.action("QUEUE_NEW_C02", "queueTransaction", c02, eta)
    second = v9.action("QUEUE_NEW_MKT1", "queueTransaction", mkt, eta)
    exec_c02 = v9.calldata("executeTransaction", c02, eta)
    exec_mkt = v9.calldata("executeTransaction", mkt, eta)
    packed = "0x" + (v9.packed_call(exec_c02) + v9.packed_call(exec_mkt)).hex()
    outer = v9.cast("calldata", "multiSend(bytes)", packed)
    return {
        "schema": "deopt.c02.atomic_governance.conditional.v10",
        "status": "UNAPPROVED_POLICY_NOT_OPERATOR_READY_NO_PUBLIC_ACTION",
        "chainId": 84532,
        "snapshot": SNAPSHOT,
        "addresses": {"safe": v9.SAFE, "timelock": v9.TL, "marketRegistry": v9.D1,
                      "multiSendCallOnly": v9.MULTISEND},
        "legacy": {
            "c02OperationId": v9.OLD_C02,
            "c02ExpiryInclusive": v9.OLD_C02_ETA + 14 * 86400,
            "mkt1OperationId": v9.OLD_MKT,
            "mkt1ExpiryInclusive": v9.OLD_MKT_ETA + 14 * 86400,
            "policy": "Do not execute either old operation. Queue replacement only after old C02 is stale and market 1 remains absent. Old MKT1 may remain queued; it cannot activate a market.",
        },
        "timelockModel": {
            "method": "queueTransaction/executeTransaction",
            "operationIdentity": "keccak256(abi.encode(target,value,data,eta))",
            "predecessor": None,
            "salt": None,
            "minDelaySecondsAtSnapshot": 86400,
            "gracePeriodSeconds": 14 * 86400,
            "nativeBatchSupported": False,
        },
        "proposedEta": eta,
        "earliestQueueAfterOldC02Expiry": v9.OLD_C02_ETA + 14 * 86400 + 1,
        "latestQueueAtMinimumDelay": eta - 86400,
        "suggestedLatestQueueWithMargin": eta - 86400 - 12 * 3600,
        "newExpiryInclusive": eta + 14 * 86400,
        "newOperations": {"c02": first["operationId"], "mkt1": second["operationId"]},
        "separatelyAuthorizedSafeActions": [first, second, {
            "label": "EXECUTE_ATOMIC_PAIR",
            "to": v9.MULTISEND,
            "value": "0",
            "operation": 1,
            "method": "multiSend(bytes)",
            "innerCallOperation": 0,
            "innerCallTargets": [v9.TL, v9.TL],
            "innerTransactions": packed,
            "innerC02ExecuteCalldata": exec_c02,
            "innerMkt1ExecuteCalldata": exec_mkt,
            "calldata": outer,
            "calldataKeccak256": v9.keccak(outer),
        }],
        "safePolicy": "Three separate Safe 2/3 authorizations; queue postflight for each; one exact MultiSendCallOnly execution after both ready. Never authorize either executeTransaction alone. Any nonce/state drift requires new review.",
        "residualRisk": "The deployed Timelock permits the Safe 2/3 to execute new C02 alone; this DAG cannot enforce atomicity on chain. Off-chain policy approval must explicitly accept this trust boundary.",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--eta", type=int, default=ETA)
    parser.add_argument("--out", type=Path, default=ART / "c02_atomic_governance_v10_conditional.json")
    args = parser.parse_args()
    package = derive(args.eta)
    args.out.write_text(json.dumps(package, indent=2) + "\n")
    print("NEW_C02_OPERATION=" + package["newOperations"]["c02"])
    print("NEW_MKT1_OPERATION=" + package["newOperations"]["mkt1"])
    print("PACKAGE_SHA256=" + hashlib.sha256(args.out.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
