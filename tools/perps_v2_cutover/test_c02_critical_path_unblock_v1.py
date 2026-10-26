"""Focused consistency checks for read-only C02/MKT1 critical-path evidence."""
import hashlib
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"


def load(name):
    return json.loads((ART / name).read_text())


class C02CriticalPathEvidence(unittest.TestCase):
    def setUp(self):
        self.report = load("c02_critical_path_unblock_parallel_governance_v1.json")
        self.proposal = load("mkt1_early_queue_policy_amendment_proposal_v1.json")

    def test_live_c02_and_maintenance_snapshot(self):
        r = self.report
        c = r["chain"]
        self.assertEqual(c["chainId"], 84532)
        self.assertTrue(c["c02Queued"] and c["c02Ready"])
        self.assertEqual(c["marketCount"], 0)
        self.assertFalse(c["market1Exists"])
        self.assertTrue(all(c["d4Flags"].values()) and c["d6Paused"])
        self.assertFalse(c["d4VaultAuthorized"] or c["d4InsuranceAuthorized"])
        self.assertTrue(all(c["d2d3Queues"].values()))
        self.assertEqual(c["safeNonce"], 36)
        self.assertEqual(r["c02ExecutionEligibility"], "NO_REMOTE_ISOLATION_UNVERIFIED")
        self.assertFalse(r["authorization"]["c02Execution"])

    def test_proposed_policy_is_unapproved_and_preserves_execution_gate(self):
        r = self.report
        p = self.proposal
        self.assertEqual(p["technicalReview"], "PASS")
        self.assertEqual(p["operatorPolicyApproval"], "REQUIRED")
        self.assertEqual(r["mkt1PolicyCheckpoint"]["oldSchedulingEdge"], p["oldHardEdge"])
        self.assertEqual(r["mkt1PolicyCheckpoint"]["proposedSchedulingEdge"], p["proposedSchedulingHardEdge"])
        self.assertEqual(r["mkt1PolicyCheckpoint"]["preservedExecutionEdges"], p["preservedExecutionHardEdges"])
        self.assertTrue(r["mkt1PolicyCheckpoint"]["approvedDagUnchanged"])
        self.assertEqual(hashlib.sha256((ROOT / p["approvedDagPath"]).read_bytes()).hexdigest(), p["approvedDagSha256"])
        self.assertFalse(r["authorization"]["mkt1Scheduling"] or r["authorization"]["mkt1Execution"])
        self.assertEqual(r["mkt1PolicyCheckpoint"]["s1PackageReadiness"], "NOT_OPERATOR_READY_POLICY_AND_REMOTE_EVIDENCE_PENDING")

    def test_remote_unknown_and_nonce_interleaving(self):
        r = self.report
        components = {x["component"]: x for x in r["concreteInfrastructure"]}
        self.assertEqual(components["Rust backend and external relayer/keeper runtime"]["classification"], "UNKNOWN")
        self.assertEqual(components["historical Railway project"]["classification"], "HISTORICAL_UNVERIFIED")
        self.assertEqual(components["Rust trading backend GitHub deployment records"]["latestStatusCounts"], {"failure": 46})
        self.assertEqual([x["id"] for x in r["operationalEvidenceRequired"]], ["CANONICAL_VERCEL_FUNCTIONS_CRONS", "RUST_BACKEND_HOST_ATTESTATION"])
        s2 = load("d2_d3_six_operation_s2_unsigned_intents_v1.json")
        self.assertEqual(r["d2d3Interaction"]["conditionalSafeNonces"], [x["safeNonceConditional"] for x in s2["operations"]])
        self.assertEqual(r["d2d3Interaction"]["conditionalSafeNonces"], list(range(36, 42)))
        self.assertFalse(any(r["authorization"].values()))


if __name__ == "__main__":
    unittest.main()
