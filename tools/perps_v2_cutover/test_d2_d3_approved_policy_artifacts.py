"""Offline consistency checks for the Base Sepolia D2/D3 policy approval."""

import hashlib
import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
ZERO = "0x" + "00" * 20
D3 = "0x43Ac3782e75018981a8F8d210049f2A185b07331"
D2 = "0x9947F42cC29A32992bbf2030ee49E35C839EDEd5"
MUSDC = "0x6eAe407f5640B006faC9965182e238582A3B412E"
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"


def load(name):
    return json.loads((ART / name).read_text())


def keccak(data):
    return subprocess.check_output(["cast", "keccak", data], text=True).strip().lower()


def word(value):
    return f"{value:064x}"


class ApprovedPolicyArtifacts(unittest.TestCase):
    def test_dag_correction_is_bounded(self):
        old = load("post_maintenance_dependency_dag_v1.json")
        new = load("post_maintenance_dependency_dag_v2.json")
        approval = load("d2_d3_testnet_policy_approval_v1.json")
        assert hashlib.sha256((ART / "post_maintenance_dependency_dag_v1.json").read_bytes()).hexdigest() == approval["previousDagV1Sha256"]
        assert hashlib.sha256((ART / "post_maintenance_dependency_dag_v2.json").read_bytes()).hexdigest() == approval["approvedDagV2Sha256"]
        old_ids = {n["id"] for n in old["nodes"]}
        new_ids = {n["id"] for n in new["nodes"]}
        self.assertEqual(new_ids, (old_ids - {"D3_RISK"}) | {"D3_RISK_COMPAT_VERIFIED"})
        self.assertEqual(len(old["edges"]), len(new["edges"]))
        rename = lambda value: "D3_RISK_COMPAT_VERIFIED" if value == "D3_RISK" else value
        expected_edges = {(rename(e["from"]), rename(e["to"]), e["hard"]) for e in old["edges"]}
        actual_edges = {(e["from"], e["to"], e["hard"]) for e in new["edges"]}
        self.assertEqual(actual_edges, expected_edges)
        self.assertEqual(new["topologicalOrder"], [rename(value) for value in old["topologicalOrder"]])
        old_nodes = {n["id"]: n for n in old["nodes"]}
        new_nodes = {n["id"]: n for n in new["nodes"]}
        for node_id in old_ids - {"D3_RISK", "D3_TOKEN", "D2_FEE_POLICY", "C13"}:
            self.assertEqual(new_nodes[node_id], old_nodes[node_id], node_id)
        gate = next(n for n in new["nodes"] if n["id"] == "D3_RISK_COMPAT_VERIFIED")
        self.assertFalse(gate["publicTimelockScheduleRequired"] or gate["publicTimelockExecuteRequired"])
        self.assertIn("D3_RISK_COMPAT_VERIFIED", next(n for n in new["nodes"] if n["id"] == "C13")["dependsOn"])
        self.assertFalse(new["testnetPolicyApproval"]["publicSchedulingOrExecutionAuthorized"])

    def test_six_distinct_one_action_intents(self):
        bundle = load("d2_d3_s1_unsigned_intents_v1.json")
        ops = bundle["operations"]
        self.assertEqual([o["name"] for o in ops], ["D3_TOKEN"] + [f"D2_PERP_TIER_{i}" for i in range(5)])
        self.assertEqual(len({o["timelockOperationId"] for o in ops}), 6)
        for i, op in enumerate(ops):
            self.assertEqual(op["safeTxFields"]["nonce"], 30 + i)
            self.assertEqual(op["eta"], 1793102400)
            self.assertEqual(op["bufferedSchedulingCutoff"], op["eta"] - 86400 - 3600)
            self.assertFalse(op["operatorReadyNow"] or op["queuedAtReview"])
            self.assertEqual(op["safeTxHashLocal"], op["safeTxHashOnchain"])
            self.assertEqual(op["timelockOperationId"], op["timelockHashOnchain"])
            fields = op["safeTxFields"]
            self.assertEqual((fields["operation"], fields["value"], fields["safeTxGas"], fields["baseGas"], fields["gasPrice"]), (0, "0", "0", "0", "0"))
            self.assertEqual((fields["gasToken"], fields["refundReceiver"]), (ZERO, ZERO))
            self.assertEqual(fields["to"].lower(), TIMELOCK.lower())

    def test_calldata_and_operation_id_rederived(self):
        for i, op in enumerate(load("d2_d3_s1_unsigned_intents_v1.json")["operations"]):
            target = D3 if i == 0 else D2
            if i == 0:
                inner = "0x20366617" + word(int(MUSDC, 16)) + word(5) + word(1)
            else:
                inner = "0xf6524d58" + word(i - 1) + word(1) + word(0) + word(200)
            self.assertEqual(op["target"].lower(), target.lower())
            self.assertEqual(op["innerCalldata"].lower(), inner.lower())
            self.assertEqual(op["innerKeccak256"].lower(), keccak(inner))
            self.assertEqual(op["innerSha256"], hashlib.sha256(bytes.fromhex(inner[2:])).hexdigest())
            padded = inner[2:].ljust(((len(inner) - 2 + 63) // 64) * 64, "0")
            outer = "0x8e361cdf" + word(int(target, 16)) + word(0) + word(128) + word(op["eta"]) + word((len(inner) - 2) // 2) + padded
            self.assertEqual(op["outerCalldata"].lower(), outer.lower())
            self.assertEqual(op["outerKeccak256"].lower(), keccak(outer))
            self.assertEqual(op["outerSha256"], hashlib.sha256(bytes.fromhex(outer[2:])).hexdigest())
            identity = "0x" + word(int(target, 16)) + word(0) + word(128) + word(op["eta"]) + word((len(inner) - 2) // 2) + padded
            self.assertEqual(op["timelockOperationId"].lower(), keccak(identity))

    def test_builder_exactly_matches_unsigned_intent(self):
        for op in load("d2_d3_s1_unsigned_intents_v1.json")["operations"]:
            path = ROOT / op["safeBuilderJsonPath"]
            builder = json.loads(path.read_text())
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), op["safeBuilderJsonSha256"])
            self.assertEqual(builder["chainId"], "84532")
            self.assertEqual(len(builder["transactions"]), 1)
            action = builder["transactions"][0]
            self.assertEqual(action["contractMethod"]["name"], "queueTransaction")
            self.assertEqual(action["to"].lower(), TIMELOCK.lower())
            self.assertEqual(action["value"], "0")
            self.assertEqual(action["data"], op["outerCalldata"])
            args = action["contractInputsValues"]
            self.assertEqual((args["target"].lower(), args["value"], args["data"].lower(), int(args["eta"])), (op["target"].lower(), "0", op["innerCalldata"].lower(), op["eta"]))

    def test_consolidated_readiness_matches_committed_intents(self):
        review = load("d2_d3_six_operation_s1_consolidated_operator_readiness_v1.json")
        bundle = load("d2_d3_s1_unsigned_intents_v1.json")
        snapshot = load("d2_d3_six_operation_s1_live_snapshot_v1.json")
        self.assertEqual(review["chainId"], 84532)
        self.assertEqual(review["reviewBlock"], snapshot["block"])
        self.assertEqual(review["safe"]["nonce"], 30)
        self.assertEqual(review["safe"]["threshold"], 2)
        self.assertEqual(review["latestBufferedSchedulingTime"], bundle["eta"] - 86400 - 3600)
        self.assertEqual(review["liveSnapshotSha256"], hashlib.sha256((ROOT / review["liveSnapshotPath"]).read_bytes()).hexdigest())
        self.assertEqual(review["reviewedIntentsSha256"], hashlib.sha256((ROOT / review["reviewedIntentsPath"]).read_bytes()).hexdigest())
        self.assertEqual(review["operationCount"], len(bundle["operations"]))
        for i, (op, intent) in enumerate(zip(review["operations"], bundle["operations"], strict=True)):
            self.assertEqual(op["name"], intent["name"])
            self.assertEqual(op["operationId"], intent["timelockOperationId"])
            self.assertEqual(op["outerTimelockCalldata"], intent["outerCalldata"])
            self.assertEqual(op["safeTxHashConditional"], intent["safeTxHashOnchain"])
            self.assertEqual(op["safeNonceConditional"], 30 + i)
            self.assertFalse(op["operationQueuedAtReview"])
            self.assertEqual(op["builderSha256"], hashlib.sha256((ROOT / op["builderPath"]).read_bytes()).hexdigest())
        self.assertFalse(review["publicTransactionsSentByAgent"])


if __name__ == "__main__":
    unittest.main()
