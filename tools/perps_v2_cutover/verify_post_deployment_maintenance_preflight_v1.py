#!/usr/bin/env python3
"""Offline integrity check for the read-only M1/M2 maintenance preflight."""

import hashlib
import json
import subprocess
from pathlib import Path

from eth_abi import encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "artifacts/perps_v2_replacement_deployment"
PREFLIGHT = BASE / "post_deployment_maintenance_preflight_v1.json"
PLAN = BASE / "maintenance_operation_plan_v1.json"
DOC = ROOT / "docs/PERPS_V2_BASE_SEPOLIA_POST_DEPLOYMENT_MAINTENANCE_AND_GOVERNANCE_PREFLIGHT_V1.md"
FROZEN = "25c36670883604c1ef5229642ee6548aea6796c3"
MANIFEST_SHA = "745e7a2fad6a77fef6e35f10a1a431b75615524f51fe13c881c191351ad591fe"
WORKFLOW_SHA = "8f69c2e6c3c66cb337a58478b45c4923078b1ef3fc028de5f2a29174fbbe66c8"
VALIDATOR_SHA = "371ac6a893078571f0702f324fbb245f7ab03f3a372b017b6e386f4d6b42b1a5"
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
D4 = "0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB"
D6 = "0xeeA4e5d891B90D3d99E9C4e2c61069911477110E"
ZERO = "0x" + "0" * 40


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = json.loads(PREFLIGHT.read_text())
    plan = json.loads(PLAN.read_text())
    assert DOC.is_file()
    assert p["verdict"] == "PASS" and not p["publicActionsExecuted"]
    assert plan["verdict"] == "PASS_OFFLINE_PLAN_ONLY" and not plan["publicActionAuthorized"]
    assert p["frozenSoliditySourceCommit"] == FROZEN
    assert not subprocess.check_output(["git", "diff", "--name-only", FROZEN, "HEAD", "--", "src"], cwd=ROOT, text=True).strip()
    assert p["chainId"] == plan["chainId"] == 84532
    assert p["reviewBlockNumber"] == plan["reviewBlockNumber"]
    assert p["reviewBlockHash"] == plan["reviewBlockHash"]
    assert p["operationPlanSha256"] == sha(PLAN)
    assert p["governanceIntegrity"]["correctedManifestSha256"] == MANIFEST_SHA
    assert sha(BASE / "timelock_configuration_manifest_c12_c20_v2.json") == MANIFEST_SHA
    assert p["governanceIntegrity"]["workflowSha256"] == WORKFLOW_SHA
    assert sha(ROOT / p["governanceIntegrity"]["workflow"]) == WORKFLOW_SHA
    assert p["governanceIntegrity"]["validatorSha256"] == VALIDATOR_SHA
    assert sha(ROOT / p["governanceIntegrity"]["validator"]) == VALIDATOR_SHA
    assert p["d5MaxOracleDelay"] == 0
    assert p["d4"]["migrationState"] == 0
    assert p["d4"]["riskModule"] == p["d4"]["matchingEngine"] == ZERO
    assert not p["d6"]["paused"]
    assert p["d6"]["executor.timelock"] and not p["d6"]["executor.runtime"]
    assert p["safe"]["threshold"] == 2 and len(p["safe"]["owners"]) == 3
    assert p["timelock"]["minDelay"] == 86400
    assert p["timelock"]["proposers.safe"] and p["timelock"]["executors.safe"]
    assert len(p["deployments"]) == 6
    assert all(d["owner"].lower() == TIMELOCK.lower() for d in p["deployments"])
    assert p["deployments"][3]["address"].lower() == D4.lower()
    assert p["deployments"][5]["address"].lower() == D6.lower()
    assert p["d6CanonicalReceipt"]["status"] == "0x1"
    assert p["sharedCustody"]["clearingLedgerRawMUSDC"] == 1_000_000_000
    assert not p["sharedCustody"]["vault"]["isAuthorizedEngine.D4"]
    assert not p["sharedCustody"]["insurance"]["backstopD4"]
    assert not p["currentPublicEconomicPathExists"] and not p["postSimulatedMaintenanceEconomicPathExists"]
    assert plan["firstOperation"] == "M1_D6_PAUSE" and plan["secondOperation"] == "M2_D4_FOUR_FLAG_CLOSE"
    expected = [
        ("M1_D6_PAUSE", D6, "pause()", keccak(text="pause()")[:4]),
        ("M2_D4_FOUR_FLAG_CLOSE", D4, "setEmergencyModes(bool,bool,bool,bool)",
         keccak(text="setEmergencyModes(bool,bool,bool,bool)")[:4] + encode(["bool"] * 4, [True] * 4)),
    ]
    for op, (name, target, sig, data) in zip(plan["operations"], expected):
        assert op["id"] == name and op["target"].lower() == target.lower()
        assert op["functionSignature"] == sig and op["calldata"] == "0x" + data.hex()
        assert op["calldataKeccak256"] == "0x" + keccak(data).hex()
        assert op["valueWei"] == 0 and op["chainId"] == 84532
        assert op["eta"] is None and op["operationHash"] is None
        assert op["safeProposal"] is None and op["signedPayload"] is None
    assert "M2_D4_FOUR_FLAG_CLOSE" in plan["governanceDependencyDag"]["M1_D6_PAUSE"]
    assert "C12_D4_RISK_WIRING" in plan["governanceDependencyDag"]["C20_CANONICAL_RECEIPT_AND_LIVE_600_READBACK"]
    assert p["focusedTests"]["forkFoundry"] == {"passed": 6, "failed": 0, "skipped": 0}
    assert p["focusedTests"]["governancePython"] == {"passed": 31, "failed": 0, "skipped": 0}
    print("maintenance offline evidence PASS", "preflightSha256", sha(PREFLIGHT), "planSha256", sha(PLAN))


if __name__ == "__main__":
    main()
