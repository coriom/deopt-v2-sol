"""Focused structural safety checks for the read-only post-maintenance plan."""

import hashlib
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
DAG = json.loads((ART / "post_maintenance_dependency_dag_v1.json").read_text())
ROAD = json.loads((ART / "post_maintenance_configuration_roadmap_v1.json").read_text())
NODES = {n["id"]: n for n in DAG["nodes"]}
ORDER = {name: i for i, name in enumerate(DAG["topologicalOrder"])}


class RoadmapSafety(unittest.TestCase):
    def test_chain_and_readonly_boundary(self):
        self.assertEqual(DAG["chainId"], ROAD["chainId"])
        self.assertEqual(DAG["chainId"], 84532)
        self.assertEqual(DAG["status"], "PLANNING_ONLY_NO_PUBLIC_OPERATION_AUTHORIZED")
        self.assertEqual(DAG["reviewBlock"], ROAD["reviewBlock"])

    def test_unique_complete_acyclic_graph(self):
        self.assertEqual(len(NODES), len(DAG["nodes"]))
        self.assertEqual(set(ORDER), set(NODES))
        for edge in DAG["edges"]:
            self.assertIn(edge["from"], NODES)
            self.assertIn(edge["to"], NODES)
            self.assertTrue(edge["hard"])
            self.assertLess(ORDER[edge["from"]], ORDER[edge["to"]])

    def test_governance_lifecycle_not_batched(self):
        for node in DAG["nodes"]:
            self.assertIn("source", node)
            self.assertIn("authority", node)
            self.assertIn("requiredReadback", node)
            self.assertIn("safeStoppingState", node)
            self.assertIn("failureOrAmbiguity", node)
            if node["publicTimelockScheduleRequired"]:
                self.assertTrue(node["publicTimelockExecuteRequired"])
                self.assertTrue(node["canonicalReceiptRequired"])
                self.assertEqual(node["mandatoryDelaySeconds"], 86400)

    def test_maintenance_gate_for_first_operations(self):
        self.assertEqual(ROAD["maintenance"]["d4FourFlags"], [True] * 4)
        self.assertTrue(ROAD["maintenance"]["d6Paused"])
        self.assertFalse(ROAD["maintenance"]["m1Queued"])
        self.assertFalse(ROAD["maintenance"]["m2Queued"])
        for name in ("C20", "C01", "D3_TOKEN", "D2_FEE_POLICY", "GUARDIAN_POLICY"):
            self.assertIn("MAINTENANCE_VERIFIED", NODES[name]["dependsOn"])

    def test_c20_before_c12_and_manifest_binding(self):
        self.assertIn("C20", NODES["C12"]["dependsOn"])
        self.assertLess(ORDER["C20"], ORDER["C12"])
        self.assertEqual(ROAD["C12"]["status"], "BLOCKED_WAITING_FOR_C20")
        self.assertFalse(ROAD["C20"]["executed"])
        path = ART / "timelock_configuration_manifest_c12_c20_v2.json"
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), ROAD["artifactIntegrity"]["correctedGovernanceManifestSha256"])
        manifest = json.loads(path.read_text())
        c20 = next(a for a in manifest["actions"] if a["stageId"] == "C20")
        self.assertEqual(c20["calldata"].lower(), ROAD["C20"]["calldata"])

    def test_market_active_creation_is_contained(self):
        for a, b, c in (("C02", "MKT1_INACTIVE", "C03"), ("C03", "MKT2_INACTIVE", "C07")):
            self.assertLess(ORDER[a], ORDER[b])
            self.assertLess(ORDER[b], ORDER[c])
        self.assertLess(ORDER["C04"], ORDER["C07"])
        self.assertLess(ORDER["C05"], ORDER["C07"])
        self.assertLess(ORDER["C07"], ORDER["C08"])

    def test_d1_reactivation_requires_pause_release(self):
        for a, b in (("D1_RELEASE_GLOBAL", "D1_RELEASE_CONFIG"), ("D1_RELEASE_CONFIG", "MKT1_RESTRICTED_ACTIVATE"), ("MKT1_RESTRICTED_ACTIVATE", "D1_REPAUSE_CONFIG"), ("D1_REPAUSE_CONFIG", "D4_SELECTIVE_RELEASE")):
            self.assertLess(ORDER[a], ORDER[b])

    def test_collateral_and_fee_dependencies(self):
        self.assertIn("D3_TOKEN", NODES["C13"]["dependsOn"])
        self.assertIn("D3_RISK", NODES["C13"]["dependsOn"])
        self.assertIn("D2_FEE_POLICY", NODES["C14"]["dependsOn"])
        self.assertIn("C24", NODES["C15"]["dependsOn"])
        self.assertEqual(ROAD["currentConfiguration"]["D3"]["mUSDCSeizeConfig"], [0, False, False])
        self.assertEqual(ROAD["currentConfiguration"]["D2"]["rebateBudgetMusdc"], 0)

    def test_runtime_executor_before_bootstrap_removal(self):
        self.assertIn("EXECUTOR_IDENTITY_REVIEW", NODES["C23"]["dependsOn"])
        self.assertIn("C23", NODES["C22"]["dependsOn"])
        self.assertTrue(ROAD["currentConfiguration"]["D6"]["timelockExecutor"])
        self.assertFalse(ROAD["currentConfiguration"]["D6"]["runtimeExecutor"])

    def test_each_migration_seed_and_equality_before_seal(self):
        for i in range(1, 9):
            name = f"MIGRATION_SEED_{i:02d}"
            self.assertIn(name, NODES)
            expected = "MIGRATION_PREFLIGHT" if i == 1 else f"MIGRATION_SEED_{i-1:02d}"
            self.assertIn(expected, NODES[name]["dependsOn"])
        self.assertIn("MIGRATION_SEED_08", NODES["ECONOMIC_EQUALITY"]["dependsOn"])
        self.assertIn("ECONOMIC_EQUALITY", NODES["MIGRATION_SEAL"]["dependsOn"])
        self.assertEqual(ROAD["economic"]["canonicalPositions"], 6)
        self.assertEqual(ROAD["economic"]["clearingLedgerRawMusdc"], 1000000000)
        self.assertTrue(ROAD["economic"]["duplicateFundingForbidden"])
        self.assertEqual(ROAD["economic"]["correctedPnlRegression"]["longRawMusdc"], 244274)
        self.assertEqual(ROAD["economic"]["correctedPnlRegression"]["shortRawMusdc"], -244274)

    def test_shared_grants_follow_seal_and_review(self):
        for name in ("C25", "C26"):
            self.assertIn("MIGRATION_SEAL", NODES[name]["dependsOn"])
            self.assertIn("ACL_POLICY_REVIEW", NODES[name]["dependsOn"])
        self.assertFalse(ROAD["maintenance"]["d4VaultAuthorized"])
        self.assertFalse(ROAD["maintenance"]["d4InsuranceAuthorized"])

    def test_guard_and_restricted_trade_remain_late(self):
        self.assertIn("C22", NODES["FIRST_TRADE_GUARD"]["dependsOn"])
        self.assertIn("MIGRATION_SEAL", NODES["FIRST_TRADE_GUARD"]["dependsOn"])
        self.assertLess(ORDER["D6_SELECTIVE_RELEASE"], ORDER["RESTRICTED_FIRST_TRADE"])
        self.assertLess(ORDER["RESTRICTED_FIRST_TRADE"], ORDER["BROADER_ACTIVATION"])

    def test_first_operation_is_preparation_only(self):
        self.assertEqual(ROAD["firstRecommendedOperation"], "C20")
        self.assertEqual(ROAD["firstMilestone"], "PERPS_V2_BASE_SEPOLIA_C20_ORACLE_DELAY_PREPARATION_V1")
        self.assertIs(ROAD["C20"]["eligibleForPreparation"], True)
        self.assertEqual(ROAD["governance"]["futureEta"], "UNASSIGNED")
        self.assertEqual(ROAD["governance"]["futureSafeNonce"], "UNASSIGNED")


if __name__ == "__main__":
    unittest.main()
