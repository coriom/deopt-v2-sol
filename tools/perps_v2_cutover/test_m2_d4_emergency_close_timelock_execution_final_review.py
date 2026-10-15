"""Offline checks for the unsigned M2 S2 review package; no RPC or signing."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak

BASE = Path(__file__).resolve().parents[2] / "artifacts/perps_v2_replacement_deployment"
S1 = json.loads((BASE / "m2_d4_emergency_close_s1_public_postflight_reconciliation_v1.json").read_text())
REVIEW = json.loads((BASE / "m2_d4_emergency_close_timelock_execution_final_review_v1.json").read_text())
INTENT = json.loads((BASE / "m2_d4_emergency_close_unsigned_timelock_execute_v1.json").read_text())
BUILDER = json.loads((BASE / "m2_d4_emergency_close_s2_safe_builder_review_v1.json").read_text())


class M2S2OfflinePackage(unittest.TestCase):
    def test_s1_canonical_receipt_and_commitment(self):
        source = BASE / "m2_d4_emergency_close_s1_public_postflight_reconciliation_v1.json"
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), REVIEW["s1PostflightArtifactSha256"])
        self.assertEqual(S1["verdict"], {"M2_S1_SCHEDULING": "VERIFIED_SCHEDULED", "M2_S1_POSTFLIGHT": "PASS"})
        self.assertEqual(S1["canonicalPublicReceipt"]["status"], "0x1")
        self.assertEqual(S1["reconciledLiveEvidence"]["safe"]["nonceAtReceipt"], 22)
        self.assertEqual(S1["reconciledLiveEvidence"]["timelock"]["operationId"], INTENT["operation"]["operationId"])

    def test_exact_inner_and_outer_calldata(self):
        inner = bytes.fromhex(INTENT["operation"]["innerData"][2:])
        outer = bytes.fromhex(INTENT["timelockCall"]["data"][2:])
        self.assertEqual(inner[:4], keccak(text="setEmergencyModes(bool,bool,bool,bool)")[:4])
        self.assertEqual(decode(["bool"] * 4, inner[4:]), (True,) * 4)
        self.assertEqual("0x" + keccak(inner).hex(), INTENT["operation"]["innerDataKeccak256"])
        self.assertEqual(outer[:4], keccak(text="executeTransaction(address,uint256,bytes,uint256)")[:4])
        target, value, data, eta = decode(["address", "uint256", "bytes", "uint256"], outer[4:])
        self.assertEqual(target.lower(), INTENT["operation"]["target"].lower())
        self.assertEqual((value, data, eta), (0, inner, 1792465200))
        self.assertEqual(len(outer), 324)
        self.assertEqual("0x" + keccak(outer).hex(), INTENT["timelockCall"]["dataKeccak256"])
        self.assertEqual(hashlib.sha256(outer).hexdigest(), INTENT["timelockCall"]["dataSha256"])
        operation_id = "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"], [target, value, data, eta])).hex()
        self.assertEqual(operation_id, INTENT["operation"]["operationId"])

    def test_safe_builder_single_action_matches_intent(self):
        self.assertEqual(BUILDER["chainId"], "84532")
        self.assertEqual(len(BUILDER["transactions"]), 1)
        tx = BUILDER["transactions"][0]
        self.assertEqual(tx["to"].lower(), INTENT["timelockCall"]["to"].lower())
        self.assertEqual(tx["value"], "0")
        self.assertEqual(tx["data"], INTENT["timelockCall"]["data"])
        self.assertEqual(tx["contractMethod"]["name"], "executeTransaction")
        self.assertEqual(tx["contractInputsValues"]["data"], INTENT["operation"]["innerData"])
        self.assertEqual(tx["contractInputsValues"]["eta"], str(INTENT["operation"]["eta"]))
        self.assertEqual(INTENT["safeTransaction"]["operationNumber"], 0)
        self.assertFalse(INTENT["safeTransaction"]["batch"] or INTENT["safeTransaction"]["delegatecall"])
        self.assertIn("OFFLINE_REVIEW_ONLY_NOT_AUTHORIZED", BUILDER["meta"]["name"])

    def test_queued_prestate_and_execution_window(self):
        live = REVIEW["liveSnapshot"]
        self.assertEqual(live["chainId"], 84532)
        self.assertEqual(live["state"]["operationHash"], INTENT["operation"]["operationId"])
        self.assertTrue(live["state"]["operationQueued"])
        self.assertFalse(live["state"]["operationReady"])
        self.assertEqual(live["state"]["safeNonce"], 22)
        self.assertEqual(live["state"]["safeThreshold"], 2)
        self.assertTrue(live["state"]["safeTlExecutor"])
        self.assertTrue(live["state"]["d6Paused"])
        self.assertFalse(any(live["state"][name] for name in ("d4TradingPaused", "d4LiquidationPaused", "d4FundingPaused", "d4CollateralOpsPaused")))
        self.assertEqual(INTENT["executionWindow"]["latestUnixInclusive"], 1792465200 + 14 * 86400)
        self.assertLess(live["block"]["timestamp"], INTENT["executionWindow"]["earliestUnix"])

    def test_fork_result_and_authorization_boundaries(self):
        self.assertEqual(REVIEW["localFork"]["testCounts"], {"passed": 7, "failed": 0, "skipped": 0})
        self.assertEqual(REVIEW["localFork"]["fourFlagsAfter"], [True] * 4)
        self.assertTrue(REVIEW["localFork"]["d6PausedAfter"])
        self.assertTrue(REVIEW["localFork"]["timelockOperationConsumed"])
        self.assertEqual(REVIEW["safeRoute"]["futureSafeTxHash"], "NOT_YET_FINALIZED")
        self.assertFalse(REVIEW["safeRoute"]["realOwnerSignaturesTested"])
        self.assertFalse(any(REVIEW["authorizations"].values()))
        self.assertFalse(REVIEW["publicStateChangedByThisReview"])
        self.assertEqual(INTENT["status"], "OFFLINE_UNSIGNED_NOT_SUBMITTED_NOT_AUTHORIZED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
