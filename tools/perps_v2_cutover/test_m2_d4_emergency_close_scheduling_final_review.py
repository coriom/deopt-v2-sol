"""Offline integrity checks for the unsigned S1-M2 scheduling review."""

import hashlib
import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "artifacts/perps_v2_replacement_deployment"
REVIEW = BASE / "m2_d4_emergency_close_scheduling_final_review_v1.json"
INTENT = BASE / "m2_d4_emergency_close_unsigned_safe_schedule_v1.json"
BUILDER = BASE / "m2_d4_emergency_close_s1_safe_builder_review_v1.json"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def word(value):
    return int(value).to_bytes(32, "big")


def address(value):
    return word(int(value, 16))


def keccak(raw):
    return bytes.fromhex(cast("keccak", "0x" + raw.hex())[2:])


class M2SchedulingFinalReviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.review = json.loads(REVIEW.read_text())
        cls.intent = json.loads(INTENT.read_text())
        cls.builder = json.loads(BUILDER.read_text())

    def test_preparation_hashes_and_authorization_boundary(self):
        r = self.review
        names = {
            "preparationSha256": "m2_d4_emergency_close_preparation_v1.json",
            "operationPlanSha256": "m2_d4_emergency_operation_plan_v1.json",
        }
        for key, name in names.items():
            self.assertEqual(hashlib.sha256((BASE / name).read_bytes()).hexdigest(), r["preparationArtifacts"][key])
        self.assertEqual(
            hashlib.sha256((ROOT / "docs/PERPS_V2_BASE_SEPOLIA_D4_INITIAL_EMERGENCY_CLOSE_PREPARATION_V1.md").read_bytes()).hexdigest(),
            r["preparationArtifacts"]["preparationReportSha256"],
        )
        self.assertEqual(r["verdict"], "PASS")
        self.assertFalse(r["publicStateChanged"])
        self.assertFalse(r["safeProposalCreated"])
        self.assertFalse(r["safeSignaturesCollected"])
        self.assertFalse(r["m2Scheduled"])
        self.assertFalse(r["m2Executed"])
        self.assertTrue(all(value is False for value in r["authorization"].values()))

    def test_exact_inner_abi_eta_and_operation_id(self):
        r = self.review
        m = r["m2"]
        inner = cast("calldata", "setEmergencyModes(bool,bool,bool,bool)", "true", "true", "true", "true")
        self.assertEqual(inner, m["innerCalldata"])
        self.assertEqual(len(bytes.fromhex(inner[2:])), 132)
        self.assertEqual("0x" + keccak(bytes.fromhex(inner[2:])).hex(), m["innerCalldataKeccak256"])
        raw = address(m["target"]) + word(0) + word(128) + word(m["eta"])
        data = bytes.fromhex(inner[2:])
        raw += word(len(data)) + data.ljust(160, b"\0")
        self.assertEqual("0x" + keccak(raw).hex(), m["operationId"])
        self.assertEqual(m["onchainHashOperationResult"], m["operationId"])
        self.assertEqual(m["operationStateAtReview"], "ABSENT")
        self.assertFalse(m["queuedTransactions"])
        self.assertEqual(m["matchingD4TimelockEventCountGenesisToReview"], 0)
        self.assertFalse(m["conflict"])
        self.assertEqual(m["latestTheoreticalScheduleTimestamp"], m["eta"] - r["timelock"]["minDelaySeconds"])
        self.assertEqual(m["finalGateCutoffWithOneHourBuffer"], m["latestTheoreticalScheduleTimestamp"] - 3600)
        self.assertGreater(m["finalGateCutoffWithOneHourBuffer"], r["reviewBlock"]["timestamp"])

    def test_outer_safe_call_and_conditional_hash(self):
        r, i = self.review, self.intent
        m, tx = r["m2"], i["safeTransaction"]
        outer = cast("calldata", "queueTransaction(address,uint256,bytes,uint256)", m["target"], "0", m["innerCalldata"], str(m["eta"]))
        self.assertEqual(outer, tx["data"])
        self.assertEqual(outer, m["outerCalldata"])
        self.assertEqual("0x" + keccak(bytes.fromhex(outer[2:])).hex(), m["outerCalldataKeccak256"])
        self.assertEqual(tx["operation"], 0)
        self.assertEqual(tx["valueWei"], 0)
        self.assertEqual(tx["to"].lower(), r["timelock"]["address"].lower())
        self.assertFalse(i["safeNonceReserved"])
        self.assertEqual(i["safeNonceObservedOnly"], r["safeGovernance"]["nonceObservedOnly"])
        self.assertEqual(hashlib.sha256(INTENT.read_bytes()).hexdigest(), r["unsignedIntentSha256"])
        self.assertEqual(hashlib.sha256(BUILDER.read_bytes()).hexdigest(), i["safeBuilderSha256"])
        domain_type = keccak(b"EIP712Domain(uint256 chainId,address verifyingContract)")
        domain = keccak(domain_type + word(i["chainId"]) + address(i["safe"]))
        tx_type = keccak(b"SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
        struct = keccak(tx_type + address(tx["to"]) + word(0) + keccak(bytes.fromhex(tx["data"][2:]))
                        + word(0) + word(tx["safeTxGas"]) + word(tx["baseGas"]) + word(tx["gasPrice"])
                        + address(tx["gasToken"]) + address(tx["refundReceiver"]) + word(tx["nonceObservedOnly"]))
        self.assertEqual("0x" + keccak(b"\x19\x01" + domain + struct).hex(), i["safeTxHashConditional"])
        self.assertTrue(i["safeTxHashOnchainGetterMatch"])

    def test_builder_schema_and_single_transaction_consistency(self):
        b, i, r = self.builder, self.intent, self.review
        self.assertEqual(b["version"], "1.0")
        self.assertEqual(b["chainId"], "84532")
        self.assertEqual(b["meta"]["txBuilderVersion"], "1.18.0")
        self.assertEqual(b["meta"]["createdFromSafeAddress"], i["safe"])
        self.assertIn("OFFLINE_REVIEW_ONLY_NOT_AUTHORIZED", b["meta"]["name"])
        self.assertEqual(len(b["transactions"]), 1)
        tx = b["transactions"][0]
        self.assertEqual(set(tx), {"to", "value", "data", "contractMethod", "contractInputsValues"})
        self.assertEqual(tx["to"], i["safeTransaction"]["to"])
        self.assertEqual(tx["value"], "0")
        self.assertEqual(tx["data"], i["safeTransaction"]["data"])
        self.assertEqual(tx["contractMethod"]["name"], "queueTransaction")
        self.assertFalse(tx["contractMethod"]["payable"])
        self.assertEqual([item["type"] for item in tx["contractMethod"]["inputs"]], ["address", "uint256", "bytes", "uint256"])
        self.assertEqual(tx["contractInputsValues"], {"target": r["m2"]["target"], "value": "0", "data": r["m2"]["innerCalldata"], "eta": str(r["m2"]["eta"])})
        self.assertEqual(hashlib.sha256(BUILDER.read_bytes()).hexdigest(), r["safeBuilderSha256"])

    def test_scheduling_simulation_preserves_execution_boundary(self):
        r = self.review
        self.assertTrue(r["m1Completion"]["d6PausedNow"])
        self.assertFalse(r["m1Completion"]["queuedNow"])
        self.assertEqual(r["readOnlySimulation"]["safeToTimelockEthCallResult"], r["m2"]["operationId"])
        self.assertTrue(r["readOnlySimulation"]["unauthorizedCallReverted"])
        self.assertTrue(r["readOnlySimulation"]["collisionRejected"])
        self.assertTrue(r["readOnlySimulation"]["prematureExecutionRejected"])
        self.assertEqual(r["readOnlySimulation"]["d4FlagsAfterScheduling"], [False] * 4)
        self.assertTrue(r["readOnlySimulation"]["d6PausedAfterScheduling"])
        self.assertEqual(r["readOnlySimulation"]["sharedEconomicNonDrift"], "PASS_BOUNDED")
        self.assertFalse(r["readOnlySimulation"]["realSafeSignaturesVerified"])
        self.assertEqual(r["gasPlanning"]["fullSafeSchedulingEstimate"], "NOT_RELIABLY_AVAILABLE")


if __name__ == "__main__":
    unittest.main()
