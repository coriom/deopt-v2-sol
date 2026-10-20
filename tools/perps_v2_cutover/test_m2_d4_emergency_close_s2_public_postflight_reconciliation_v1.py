"""Offline cross-checks for the canonical, sanitized M2 execution evidence."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak


BASE = Path(__file__).resolve().parents[2] / "artifacts/perps_v2_replacement_deployment"
POST = json.loads((BASE / "m2_d4_emergency_close_s2_public_postflight_reconciliation_v1.json").read_text())
INTENT = json.loads((BASE / "m2_d4_emergency_close_unsigned_timelock_execute_v1.json").read_text())
CHECKPOINT = json.loads((BASE / "m2_d4_emergency_close_s2_operator_checkpoint_v2.json").read_text())
LIVE = POST["liveEvidence"]
ZERO = "0x" + "00" * 20


class M2PublicPostflight(unittest.TestCase):
    def test_canonical_receipt_and_safe_call(self):
        self.assertEqual(POST["chainId"] if "chainId" in POST else LIVE["chainId"], 84532)
        self.assertEqual(LIVE["receipt"]["transactionHash"], LIVE["publicTransactionHash"])
        self.assertEqual(LIVE["receipt"]["status"], "0x1")
        self.assertEqual(LIVE["receipt"]["blockHash"], LIVE["receiptBlock"]["hash"])
        self.assertEqual(LIVE["safe"]["safeTxHash"], CHECKPOINT["safe"]["safeTxHashProposed"])
        self.assertTrue(LIVE["safe"]["executionSuccess"])
        self.assertFalse(LIVE["safe"]["executionFailure"])
        self.assertEqual([LIVE["safe"][k] for k in ("nonceBefore", "nonceAtReceipt", "nonceLatest")], [22, 23, 23])
        call = LIVE["safe"]["decodedExecTransaction"]
        self.assertEqual((call["to"].lower(), call["value"], call["operation"]),
                         (INTENT["timelockCall"]["to"].lower(), 0, 0))
        self.assertEqual(call["dataKeccak256"], INTENT["timelockCall"]["dataKeccak256"])
        self.assertEqual((call["safeTxGas"], call["baseGas"], call["gasPrice"]), (0, 0, 0))
        self.assertEqual((call["gasToken"], call["refundReceiver"]), (ZERO, ZERO))
        self.assertEqual(call["signatureBytes"], 130)
        self.assertEqual(LIVE["trace"]["safeExecCallCount"], 1)
        self.assertTrue(LIVE["trace"]["noCallErrors"])

    def test_timelock_identity_events_and_consumption(self):
        inner = bytes.fromhex(INTENT["operation"]["innerData"][2:])
        outer = bytes.fromhex(INTENT["timelockCall"]["data"][2:])
        self.assertEqual(inner, keccak(text="setEmergencyModes(bool,bool,bool,bool)")[:4]
                         + encode(["bool"] * 4, [True] * 4))
        self.assertEqual(outer, keccak(text="executeTransaction(address,uint256,bytes,uint256)")[:4]
                         + encode(["address", "uint256", "bytes", "uint256"],
                                  [INTENT["operation"]["target"], 0, inner, 1792465200]))
        self.assertEqual("0x" + keccak(inner).hex(), INTENT["operation"]["innerDataKeccak256"])
        self.assertEqual("0x" + keccak(outer).hex(), INTENT["timelockCall"]["dataKeccak256"])
        operation_id = "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"],
                                             [INTENT["operation"]["target"], 0, inner, 1792465200])).hex()
        self.assertEqual(operation_id, LIVE["timelock"]["operationId"])
        self.assertEqual([e["block"] for e in LIVE["timelock"]["operationHistory"]], [48134264, 48349216])
        self.assertEqual([LIVE["timelock"][k] for k in ("queuedBefore", "queuedAtReceipt", "queuedLatest")],
                         [True, False, False])
        self.assertEqual(LIVE["timelock"]["replayReadOnlyCall"], "REJECTED")
        self.assertEqual((LIVE["trace"]["timelockExecuteCallCount"], LIVE["trace"]["d4SetterCallCount"]), (1, 1))
        self.assertEqual(LIVE["postReceiptScopedEventCount"], 0)

    def test_four_flag_transition_and_bounded_non_drift(self):
        before, receipt, latest = (LIVE["state"][key] for key in ("before", "atReceipt", "latest"))
        flags = ("d4Trading", "d4Liquidation", "d4Funding", "d4CollateralOps")
        self.assertEqual([before[key] for key in flags], [False] * 4)
        self.assertEqual([receipt[key] for key in flags], [True] * 4)
        self.assertEqual([latest[key] for key in flags], [True] * 4)
        for key in before:
            if key in (*flags, "safeNonce", "tlQueued"):
                continue
            self.assertEqual(before[key], receipt[key], key)
            self.assertEqual(receipt[key], latest[key], key)
        self.assertTrue(receipt["d6Paused"])
        self.assertEqual(receipt["d4Migration"], 0)
        self.assertEqual((receipt["d4Risk"], receipt["d4Pme"]), (ZERO, ZERO))
        self.assertEqual(receipt["vaultClearingLedger"], 1_000_000_000)
        self.assertEqual(receipt["d5OracleDelay"], 0)
        self.assertEqual(POST["additionalBoundedReadbacks"]["before"],
                         POST["additionalBoundedReadbacks"]["receipt"])
        self.assertEqual(POST["additionalBoundedReadbacks"]["receipt"],
                         POST["additionalBoundedReadbacks"]["latest"])
        self.assertEqual(len(LIVE["d4EmergencyEvents"]), 5)
        self.assertEqual(POST["verdict"]["M2_POSTFLIGHT"], "PASS")
        for name, digest in POST["reviewedArtifactSha256"].items():
            self.assertEqual(hashlib.sha256((BASE / name).read_bytes()).hexdigest(), digest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
