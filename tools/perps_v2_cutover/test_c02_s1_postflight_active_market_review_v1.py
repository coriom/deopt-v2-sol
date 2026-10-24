"""Focused consistency checks for C02 scheduling postflight and S2 containment gate."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
POST = json.loads((ART / "c02_s1_public_postflight_v1.json").read_text())
REVIEW = json.loads((ART / "c02_active_market_containment_review_v1.json").read_text())
BUILDER = ART / "c02_market_creation_s1_safe_builder_review_v1.json"


class C02S1PostflightAndActiveMarketReview(unittest.TestCase):
    def test_builder_commitment_and_single_action(self):
        self.assertEqual(
            hashlib.sha256(BUILDER.read_bytes()).hexdigest(),
            "32275799536bc5bdcbea5effe58f3a3fd6dba608af79c2dd39c0999bee7a8b9c",
        )
        actions = json.loads(BUILDER.read_text())["transactions"]
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["data"][:10], "0x8e361cdf")
        self.assertEqual(actions[0]["value"], "0")

    def test_canonical_receipt_and_trace(self):
        x = POST["canonicalEvidence"]
        self.assertEqual(x["chainId"], 84532)
        self.assertEqual(x["receiptStatus"], 1)
        self.assertEqual(x["receiptBlock"]["number"], 49469584)
        self.assertEqual(x["receiptBlock"]["hash"], "0x01cd487cb2cf2a8ec80a3f24d8663b35755543fc41b1efbdfd6a58051d6c5dee")
        self.assertEqual(x["trace"]["status"], "AVAILABLE")
        self.assertEqual(x["trace"]["callCount"], 1)
        self.assertEqual(x["trace"]["safeToTimelockCall"]["inputKeccak256"], x["safe"]["call"]["dataKeccak256"])

    def test_safe_exact_hash_nonce_and_call(self):
        x = POST["canonicalEvidence"]["safe"]
        self.assertEqual(x["localEip712Hash"], x["deployedGetterHash"])
        self.assertEqual(x["safeTxHash"], "0x25599e842b539a2b3aeeb5f6ab7691183127dbd3e578f29e16aa2da65d51ccfe")
        self.assertTrue(x["executionSuccess"])
        self.assertFalse(x["executionFailure"])
        self.assertEqual([x["nonceBefore"], x["nonceAtReceipt"], x["nonceLatest"]], [29, 30, 30])
        self.assertEqual(x["call"]["operation"], 0)
        self.assertEqual(x["call"]["valueWei"], 0)

    def test_timelock_identity_queue_and_delay(self):
        x = POST["canonicalEvidence"]["timelock"]
        self.assertTrue(x["queueEvent"])
        self.assertEqual(x["operationId"], "0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e")
        self.assertEqual(x["eta"], 1792929600)
        self.assertEqual(x["queuedBeforeReceiptLatest"], [False, True, True])
        self.assertGreaterEqual(x["schedulingMarginOverBufferedCutoffSeconds"], 0)
        self.assertEqual(len(x["scopedOperationEventsSinceReceipt"]), 1)
        self.assertEqual(len(POST["recentTimelockQueueInventorySinceC12"]), 1)

    def test_scheduling_did_not_create_market_or_move_economics(self):
        x = POST["canonicalEvidence"]
        a, b, c = (x["stateSnapshots"][p] for p in ("before", "receipt", "latest"))
        for key in x["comparedKeys"]:
            self.assertEqual(a[key], b[key], key)
            self.assertEqual(b[key], c[key], key)
        self.assertEqual(c["d1MarketCount"], 0)
        self.assertFalse(c["d1Market1Exists"])
        self.assertTrue(c["d1SettlementAllowed"])
        self.assertEqual(x["verdict"]["economicNonDrift"], "PASS_BOUNDED")

    def test_maintenance_and_runtime_identity(self):
        x = POST["canonicalEvidence"]["stateSnapshots"]["latest"]
        self.assertEqual(x["d4Flags"], [True] * 4)
        self.assertEqual(x["d4Migration"], 0)
        self.assertEqual(x["d4Pme"], "0x" + "0" * 40)
        self.assertEqual(x["d5Delay"], 600)
        self.assertTrue(x["d6Paused"])
        self.assertFalse(x["vaultD4Acl"] or x["insuranceD4Acl"])
        self.assertEqual(POST["runtimeHashesAtFreshPinnedBlock"]["D1"], "0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5")

    def test_source_active_creation_and_separate_status_setter(self):
        registry = (ROOT / "src/perp/PerpMarketRegistry.sol").read_text()
        timelock = (ROOT / "src/gouvernance/ProtocolTimelock.sol").read_text()
        self.assertIn("isActive: true", registry)
        self.assertIn("function setMarketStatus(uint256 marketId, bool isActive, bool isCloseOnly)", registry)
        self.assertIn("if (!m.exists) revert UnknownMarket();", registry)
        self.assertIn("function queueTransaction(address target, uint256 value, bytes calldata data, uint256 eta)", timelock)
        self.assertEqual(REVIEW["mkt1Inactive"]["minimumActiveIntervalUnderCurrentDAGSeconds"], 86400)

    def test_inactive_diagnostic_identity_and_dag_boundary(self):
        x = REVIEW["mkt1Inactive"]
        data = keccak(text="setMarketStatus(uint256,bool,bool)")[:4] + encode(["uint256", "bool", "bool"], [1, False, False])
        self.assertEqual(x["diagnosticCalldataNotAuthorized"], "0x" + data.hex())
        self.assertEqual(x["diagnosticCalldataKeccak256"], "0x" + keccak(data).hex())
        self.assertIn("C02 canonical execution before", x["approvedDAGDependency"])
        self.assertIn("none is proposed or authorized here", x["saferSourceSupportedButNotApproved"].lower())

    def test_remote_unknown_blocks_s2_package(self):
        rows = REVIEW["reachabilityMatrix"]
        self.assertGreaterEqual(len(rows), 10)
        self.assertTrue(any(r["verdict"] == "UNKNOWN_REMOTE_NOT_VERIFIED" for r in rows))
        self.assertEqual(REVIEW["verdict"]["C02_ACTIVE_MARKET_SAFETY"], "INCONCLUSIVE")
        self.assertEqual(REVIEW["verdict"]["C02_S2_EXECUTION_ELIGIBLE"], "NO")
        self.assertEqual(REVIEW["verdict"]["C02_S2_OFFLINE_PACKAGE"], "BLOCKED")
        self.assertEqual(REVIEW["s2PackageFilesCreated"], [])

    def test_authorization_boundaries(self):
        self.assertFalse(POST["publicTransactionSentByAgent"])
        self.assertFalse(POST["c02ExecutionAuthorized"])
        self.assertFalse(REVIEW["publicActionByAgent"])
        self.assertTrue(all(v == "NO" for v in REVIEW["authorizations"].values()))
        self.assertEqual(POST["verdict"]["C02_S1_POSTFLIGHT"], "PASS")


if __name__ == "__main__":
    unittest.main()
