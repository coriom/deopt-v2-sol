"""Offline integrity tests for the unsigned M1 S1 scheduling review."""

import hashlib
import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "artifacts/perps_v2_replacement_deployment"
REVIEW = BASE / "m1_d6_pause_scheduling_final_review_v1.json"
INTENT = BASE / "m1_d6_pause_unsigned_safe_schedule_v1.json"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def w(value):
    return int(value).to_bytes(32, "big")


def a(value):
    return w(int(value, 16))


def k(raw):
    return bytes.fromhex(cast("keccak", "0x" + raw.hex())[2:])


class M1SchedulingFinalReviewTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.review = json.loads(REVIEW.read_text())
        cls.intent = json.loads(INTENT.read_text())

    def test_preparation_integrity_and_no_authorization(self):
        r = self.review
        prior = ROOT / r["preparation"]["path"]
        self.assertEqual(hashlib.sha256(prior.read_bytes()).hexdigest(), r["preparation"]["sha256"])
        self.assertEqual(r["verdict"], "PASS")
        self.assertFalse(r["publicStateChanged"])
        self.assertFalse(r["safeProposalCreated"])
        self.assertFalse(r["safeSignaturesCollected"])
        self.assertFalse(r["m1Scheduled"])
        self.assertFalse(r["m1Executed"])
        self.assertFalse(r["m2Prepared"])
        self.assertEqual(hashlib.sha256(INTENT.read_bytes()).hexdigest(), r["unsignedIntent"]["sha256"])

    def test_exact_custom_timelock_operation_and_eta(self):
        r = self.review
        m = r["m1Scheduling"]
        inner = bytes.fromhex(r["m1Inner"]["data"][2:])
        target = r["m1Inner"]["target"]
        eta = m["eta"]
        encoded = a(target) + w(0) + w(128) + w(eta) + w(len(inner)) + inner.ljust(32, b"\0")
        self.assertEqual("0x" + k(encoded).hex(), m["operationId"])
        self.assertEqual(m["operationId"], m["operationIdFromOnchainHashFunction"])
        self.assertEqual(m["predecessor"], "NOT_APPLICABLE")
        self.assertEqual(m["salt"], "NOT_APPLICABLE")
        self.assertEqual(m["queueDeadline"], eta - r["timelockState"]["TL.minDelay"])
        self.assertGreater(m["queueDeadline"], r["chain"]["blockTimestamp"])
        self.assertFalse(m["queued"])
        self.assertFalse(m["ready"])
        self.assertFalse(m["conflict"])

    def test_outer_call_and_safe_fields(self):
        r = self.review
        intent = self.intent
        fields = intent["transaction"]
        expected = cast(
            "calldata", "queueTransaction(address,uint256,bytes,uint256)",
            r["m1Inner"]["target"], "0", r["m1Inner"]["data"], str(r["m1Scheduling"]["eta"]),
        )
        self.assertEqual(fields["data"], expected)
        self.assertEqual(fields["data"], r["m1Scheduling"]["outerCalldata"])
        self.assertEqual("0x" + k(bytes.fromhex(expected[2:])).hex(), r["m1Scheduling"]["outerCalldataKeccak256"])
        self.assertEqual(fields["operation"], 0)
        self.assertEqual(fields["valueWei"], 0)
        self.assertEqual(fields["to"].lower(), r["d6State"]["D6.owner"].lower())
        self.assertEqual(fields["nonceObserved"], r["safeState"]["Safe.nonce"])
        self.assertFalse(intent["safeNonceIsExecutionCommitment"])

    def test_safe_eip712_hash_matches_deployed_getter(self):
        i = self.intent
        f = i["transaction"]
        safe = i["safe"]
        domain_type = k(b"EIP712Domain(uint256 chainId,address verifyingContract)")
        domain = k(domain_type + w(i["chainId"]) + a(safe))
        typehash = k(b"SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
        data_hash = k(bytes.fromhex(f["data"][2:]))
        struct = k(typehash + a(f["to"]) + w(f["valueWei"]) + data_hash + w(f["operation"]) + w(f["safeTxGas"]) + w(f["baseGas"]) + w(f["gasPrice"]) + a(f["gasToken"]) + a(f["refundReceiver"]) + w(f["nonceObserved"]))
        digest = "0x" + k(b"\x19\x01" + domain + struct).hex()
        self.assertEqual(digest, i["safeTransactionHashReadOnlyConditional"])
        self.assertEqual(digest, self.review["unsignedIntent"]["safeTxHashConditional"])
        self.assertFalse(i["safeTransactionHashIsPublicTransactionHash"])

    def test_scheduling_does_not_imply_execution(self):
        r = self.review
        self.assertFalse(r["d6State"]["D6.paused"])
        self.assertFalse(r["simulations"]["postScheduleD6Paused"])
        self.assertFalse(r["simulations"]["safeSignaturesVerified"])
        self.assertTrue(r["simulations"]["prematureExecutionBlocked"])
        self.assertTrue(r["simulations"]["noM2Scheduling"])
        self.assertEqual(r["gasPlanning"]["safeMediatedEstimate"], "NOT_RELIABLY_AVAILABLE_WITHOUT_EXACT_SIGNED_SAFE_TRANSACTION")


if __name__ == "__main__":
    unittest.main()
