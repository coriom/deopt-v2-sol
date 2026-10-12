"""Offline checks for the M1-only, unsigned governance preparation artifact."""

import hashlib
import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = ROOT / "artifacts/perps_v2_replacement_deployment/m1_d6_initial_pause_preparation_v1.json"


def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()


def encode_operation(target, value, data, eta):
    raw = bytes.fromhex(data[2:])
    head = b"".join([
        int(target, 16).to_bytes(32, "big"), value.to_bytes(32, "big"),
        (128).to_bytes(32, "big"), eta.to_bytes(32, "big"),
    ])
    tail = len(raw).to_bytes(32, "big") + raw.ljust((len(raw) + 31) // 32 * 32, b"\x00")
    return head + tail


class M1PreparationArtifactTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan = json.loads(ARTIFACT.read_text())

    def test_canonical_identity_and_pause_only(self):
        p = self.plan
        self.assertEqual(p["verdict"], "PASS")
        self.assertEqual(p["chainId"], 84532)
        self.assertEqual(p["scope"], "M1_D6_PAUSE_ONLY")
        self.assertEqual(p["m1"]["functionSignature"], "pause()")
        self.assertEqual(p["m1"]["calldata"], cast("sig", "pause()"))
        self.assertEqual(p["m1"]["valueWei"], 0)
        self.assertFalse(p["d6"]["paused"])
        self.assertFalse(p["m2Prepared"])
        self.assertFalse(p["m2Authorized"])
        self.assertFalse(p["publicStateChanged"])

    def test_operation_id_and_custom_timelock_fields(self):
        p = self.plan
        op = p["timelockOperation"]
        self.assertEqual(op["implementation"], "CUSTOM_PROTOCOL_TIMELOCK_NOT_OZ_TIMELOCK_CONTROLLER")
        self.assertEqual(op["salt"], "NOT_APPLICABLE")
        self.assertEqual(op["predecessor"], "NOT_APPLICABLE")
        self.assertEqual(op["proposedEta"], p["reviewBlockTimestamp"] + 72 * 3600)
        self.assertEqual(op["queueDeadline"], op["proposedEta"] - op["minDelaySeconds"])
        payload = encode_operation(p["m1"]["target"], 0, p["m1"]["calldata"], op["proposedEta"])
        expected_id = cast("keccak", "0x" + payload.hex())
        self.assertEqual(op["proposedOperationId"], expected_id)
        self.assertEqual(op["onchainHashOperationReadback"], expected_id)
        self.assertFalse(op["conflictAtReview"])

    def test_separate_unsigned_safe_templates(self):
        p = self.plan
        op = p["timelockOperation"]
        for kind, signature in (
            ("schedule", "queueTransaction(address,uint256,bytes,uint256)"),
            ("execute", "executeTransaction(address,uint256,bytes,uint256)"),
        ):
            t = p["offlineTemplates"][kind]
            data = bytes.fromhex(t["calldata"][2:])
            self.assertEqual("0x" + data[:4].hex(), cast("sig", signature))
            self.assertEqual(data[4:], encode_operation(p["m1"]["target"], 0, p["m1"]["calldata"], op["proposedEta"]))
            self.assertEqual(t["target"].lower(), p["d6"]["owner"].lower())
            self.assertEqual(t["safeAddress"].lower(), p["timelock"]["owner"].lower())
            self.assertIsNone(t["safeNonce"])
            self.assertIsNone(t["safeTxHash"])
            self.assertEqual(t["status"], "OFFLINE_TEMPLATE_NOT_PROPOSED_OR_SIGNED")

    def test_prior_artifact_integrity_and_test_evidence(self):
        p = self.plan
        for prefix in ("preflight", "operationPlan"):
            path = ROOT / p["priorEvidence"][prefix + "Path"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), p["priorEvidence"][prefix + "Sha256"])
        self.assertEqual((p["localForkRehearsal"]["testsPassed"], p["localForkRehearsal"]["testsFailed"], p["localForkRehearsal"]["testsSkipped"]), (6, 0, 0))
        self.assertFalse(p["localForkRehearsal"]["realSafeSignaturesSimulated"])
        self.assertFalse(p["safeTransactionAuthorized"])
        self.assertFalse(p["timelockOperationAuthorized"])


if __name__ == "__main__":
    unittest.main()
