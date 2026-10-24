"""Focused, offline cross-checks for C12 postflight and the unsigned C02 package."""
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"


def evidence(name):
    return json.loads((ART / name).read_text())


class C12C02FastTrackEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.c12 = evidence("c12_risk_wiring_s2_public_postflight_v1.json")
        cls.c02 = evidence("c02_market_creation_s1_final_review_v1.json")
        cls.prep = evidence("c02_market_creation_fast_preparation_v1.json")
        cls.builder = evidence("c02_market_creation_s1_safe_builder_review_v1.json")
        cls.dag = evidence("post_maintenance_dependency_dag_v1.json")
        cls.queue = evidence("c02_parallel_governance_queue_v1.json")

    def test_c12_safe_success_and_nonce(self):
        x = self.c12
        self.assertEqual(x["receipt"]["status"], 1)
        self.assertTrue(x["receipt"]["canonicalBlockHashMatch"])
        self.assertEqual(x["safe"]["nonceBefore"], 28)
        self.assertEqual(x["safe"]["nonceAtReceipt"], 29)
        self.assertEqual(x["safe"]["safeTxHashOnchain"], x["decodedEvents"]["safeSuccess"][0]["safeTxHash"])
        self.assertEqual(x["decodedEvents"]["safeFailure"], [])

    def test_c12_exact_nested_trace(self):
        x = self.c12
        safe_to_tl = [n for n in x["tracePath"] if n["from"] == "0xa6b9bb5c7b26b33cfd28c6f5a79b3c527fddcd46" and n["to"] == "0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588"]
        tl_to_d4 = [n for n in x["tracePath"] if n["from"] == "0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588" and n["to"] == "0xd0901de8f6de72aecc716ca1465c4cf58a0b99fb"]
        self.assertEqual(len(safe_to_tl), 1)
        self.assertEqual(len(tl_to_d4), 1)
        self.assertEqual(safe_to_tl[0]["inputKeccak256"], "0x963584c123980e342dc6ee8eb9855243b6c75e05240235f579c64470f2224619")
        self.assertEqual(tl_to_d4[0]["inputKeccak256"], "0x793e647f899a70e7ad9bb5b3fd503eec492225662b0e64a76e46b16f8947fcd5")

    def test_c12_consumed_and_risk_transition(self):
        x = self.c12
        self.assertEqual(len(x["decodedEvents"]["timelockExecuted"]), 1)
        self.assertTrue(x["timelock"]["queuedBefore"])
        self.assertFalse(x["timelock"]["queuedAtReceipt"])
        self.assertFalse(x["timelock"]["queuedLatest"])
        self.assertTrue(x["timelock"]["replay"]["rejected"])
        self.assertEqual(x["readbacks"]["before"]["d4Risk"], "0x" + "0" * 40)
        self.assertEqual(x["readbacks"]["receipt"]["d4Risk"], x["readbacks"]["latest"]["d4Risk"])

    def test_c12_maintenance_and_bounded_economics(self):
        x = self.c12
        for phase in ("before", "receipt", "latest"):
            s = x["readbacks"][phase]
            self.assertTrue(all(s[k] for k in ("d4Trading", "d4Liquidation", "d4Funding", "d4Collateral")))
            self.assertTrue(s["d6Paused"])
            self.assertEqual(s["d1Markets"], 0)
            self.assertFalse(s["vaultD4Acl"] or s["insuranceD4Acl"])
        for key in x["economicNonDrift"]["comparedKeys"]:
            self.assertEqual(x["readbacks"]["before"][key], x["readbacks"]["receipt"][key])
            self.assertEqual(x["readbacks"]["receipt"][key], x["readbacks"]["latest"][key])

    def test_c02_dag_and_active_at_creation_source(self):
        node = next(n for n in self.dag["nodes"] if n["id"] == "C02")
        self.assertEqual(node["dependsOn"], ["C01"])
        self.assertIn("ACTIVE", node["requiredTargetState"])
        source = (ROOT / "src/perp/PerpMarketRegistry.sol").read_text()
        self.assertIn("isActive: true", source)
        self.assertTrue(self.prep["forkRehearsal"]["market1ActiveAfter"])

    def test_c02_manifest_matches_independent_encoding(self):
        operation = self.c02["independentReview"]["operation"]
        a = next(a for a in evidence("timelock_configuration_manifest_c12_c20_v2.json")["actions"] if a["stageId"] == "C02")
        data = bytes.fromhex(operation["innerCalldata"][2:])
        self.assertEqual(operation["innerCalldata"].lower(), a["calldata"].lower())
        self.assertEqual(data[:4], keccak(text=a["signature"])[:4])
        self.assertEqual("0x" + keccak(data).hex(), operation["innerKeccak256"])

    def test_c02_operation_id_and_builder_single_call(self):
        operation = self.c02["independentReview"]["operation"]
        action = self.builder["transactions"]
        self.assertEqual(len(action), 1)
        self.assertEqual(action[0]["to"].lower(), "0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588")
        self.assertEqual(action[0]["value"], "0")
        self.assertEqual(action[0]["data"], operation["queueCalldata"])
        raw = bytes.fromhex(action[0]["data"][2:])
        self.assertEqual(raw[:4], keccak(text="queueTransaction(address,uint256,bytes,uint256)")[:4])
        target, value, inner, eta = decode(["address", "uint256", "bytes", "uint256"], raw[4:])
        self.assertEqual(target, operation["target"].lower())
        self.assertEqual(value, 0)
        self.assertEqual("0x" + inner.hex(), operation["innerCalldata"])
        self.assertEqual(eta, operation["proposedEta"])
        self.assertEqual("0x" + keccak(encode(["address", "uint256", "bytes", "uint256"], [target, value, inner, eta])).hex(), operation["operationId"])

    def test_c02_timelock_and_safe_hash_cross_checks(self):
        r = self.c02["independentReview"]
        self.assertEqual(r["liveState"]["onchainOpHash"], r["operation"]["operationId"])
        self.assertFalse(r["liveState"]["queuedProposedOp"])
        self.assertEqual(r["governance"]["safeTxHashLocal"], r["governance"]["safeTxHashOnchain"])
        self.assertEqual(r["governance"]["nonce"], 29)
        self.assertEqual(r["liveState"]["safeThreshold"], 2)

    def test_c02_eta_and_fork_protection(self):
        r = self.c02["independentReview"]
        o = r["operation"]
        self.assertGreaterEqual(o["proposedEta"], r["chain"]["reviewBlock"]["timestamp"] + r["liveState"]["tlMinDelay"] + 3600)
        self.assertEqual(o["bufferedSchedulingCutoff"], o["proposedEta"] - r["liveState"]["tlMinDelay"] - 3600)
        checks = self.prep["forkRehearsal"]["checksPassed"]
        for item in ("market_active", "funding_blocked", "liquidation_blocked", "non_drift", "replay", "wrong_caller_queue", "premature"):
            self.assertIn(item, checks)
        self.assertEqual(self.prep["forkRehearsal"]["checksFailed"], [])

    def test_no_automatic_next_operation(self):
        q = {x["id"]: x for x in self.queue["operations"]}
        self.assertEqual(q["MKT1_INACTIVE"]["status"], "DEPENDENT_PREPARATION_ONLY")
        self.assertEqual(q["C03"]["status"], "BLOCKED_DEPENDENCY")
        self.assertEqual(q["C04"]["status"], "BLOCKED_DEPENDENCY")
        self.assertTrue(self.queue["noPublicAuthorization"])


if __name__ == "__main__":
    unittest.main()
