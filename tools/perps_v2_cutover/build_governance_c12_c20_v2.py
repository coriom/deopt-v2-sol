#!/usr/bin/env python3
"""Derive the future governance source of truth; preserve the historic package."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DIR = ROOT / "artifacts/perps_v2_replacement_deployment"
OLD = DIR / "timelock_configuration_manifest.json"
NEW = DIR / "timelock_configuration_manifest_c12_c20_v2.json"
OLD_SHA = "9e3e10daad602bfd3831cab3ee469d74a0aa88cf321fcb49381381cb44fd2b6a"
D4 = "0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB"
D5 = "0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110"


def build():
    assert hashlib.sha256(OLD.read_bytes()).hexdigest() == OLD_SHA
    manifest = json.loads(OLD.read_text())
    actions = manifest["actions"]
    assert len(actions) == 26 and len({x["stageId"] for x in actions}) == 26
    c12 = next(x for x in actions if x["stageId"] == "C12")
    c20 = next(x for x in actions if x["stageId"] == "C20")
    assert c12["signature"] == "setRiskModule(address)" and c12["decodedArgs"] == ["D5_CANONICAL_ADDRESS"]
    assert c20["signature"] == "setMaxOracleDelay(uint256)" and c20["decodedArgs"] == [600]
    assert c20["calldata"].startswith("0xcd3b691c") and len(c20["calldata"]) == 74
    assert int(c20["calldata"][10:], 16) == 600
    c12["prerequisite"] += (
        "; canonical successful D4/D5 deployment receipts; C20 separately executed on Base Sepolia "
        "with canonical successful receipt and Timelock "
        "TransactionExecuted proof; fresh D5.maxOracleDelay()==600 readback; D5 owner Timelock and "
        "perpEngine()==canonical D4; D4 riskModule()==zero and migrationState()==OPEN; "
        "four Engine maintenance flags true, D4 Vault/Insurance ACL false, PME route unavailable, backend stopped"
    )
    c12["dependsOn"] = ["C20_EXECUTED_AND_READ_BACK"]
    c12["authorizationValidator"] = "tools/perps_v2_cutover/c12_c20_preflight.py"
    c12["authorizationPhases"] = ["authorization", "execution"]
    c12["liveGate"] = {"chainId": 84532, "d5Owner": manifest["governance"],
                       "d5EnginePointer": D4, "d5MaxOracleDelaySeconds": 600,
                       "d4RiskPointerZero": True, "d4MigrationOpen": True,
                       "d4EmergencyFlagsAllTrue": True, "d4VaultInsuranceAclFalse": True,
                       "pmeAbsentOrPaused": True, "backendStopped": True,
                       "canonicalC20QueueAndExecutionReceipts": True,
                       "c20ExecutedEventAndClearedQueue": True,
                       "freshReadbackAtAuthorizationAndExecution": True,
                       "independentReadbackBeforeC12Queue": True}
    c12["canShareQueueDelayWindow"] = False
    c12["forbiddenSameTransactionOrBatchWith"] = ["C20"]
    c12["targetAddress"] = D4
    c12["decodedArgsResolved"] = [D5]
    c12["calldata"] = "0x04f6f5b2" + D5[2:].lower().rjust(64, "0")
    c12["calldataStatus"] = "EXACT_CONDITIONAL_ON_CANONICAL_D5_DEPLOYMENT"
    c20["prerequisite"] += "; canonical D5 deployment and independent Timelock review/approval"
    c20["targetAddress"] = D5
    c20["canShareQueueDelayWindow"] = False
    c20["readback"] = {"signature": "maxOracleDelay()", "value": 600, "unit": "seconds",
                       "requiredAfterExecution": True, "freshBeforeC12AuthorizationAndExecution": True}
    c20["executionProof"] = {"chainId": 84532, "receiptStatus": 1,
                             "timelockEvent": "TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)",
                             "operationId": "keccak256(abi.encode(target,value,data,eta))",
                             "queuedTransactionsAfterExecution": False, "sameBatchAsC12": False}
    c20["requiredLifecycle"] = ["D5_CANONICALLY_DEPLOYED", "PREPARED", "INDEPENDENTLY_REVIEWED",
                                 "SCHEDULED_BY_APPROVED_GOVERNANCE", "TIMELOCK_DELAY_ELAPSED",
                                 "PUBLICLY_EXECUTED", "ONCHAIN_DELAY_600_READ_BACK"]
    actions.remove(c12)
    actions.insert(actions.index(c20) + 1, c12)
    manifest["schema"] = "deopt.perps_v2_replacement_deployment.timelock_config.c12_c20.v2"
    manifest["supersedesManifestSha256"] = OLD_SHA
    manifest["sourceOfTruthForFutureC12C20"] = True
    manifest["historicalPackageManifestIsNotAuthorization"] = True
    manifest["authorized"] = False
    manifest["status"] = "FUTURE_CONDITIONAL_OPERATIONS_NOT_AUTHORIZED"
    return manifest


if __name__ == "__main__":
    NEW.write_text(json.dumps(build(), indent=2, sort_keys=True) + "\n")
    print("versioned governance manifest sha256", hashlib.sha256(NEW.read_bytes()).hexdigest())
