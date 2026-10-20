"""Offline consistency checks for sanitized C20-S1 public postflight evidence."""

import hashlib
import json
from pathlib import Path
import unittest

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts/perps_v2_replacement_deployment"
POST = json.loads((ARTIFACTS / "c20_oracle_delay_fast_s1_public_postflight_v1.json").read_text())
REVIEW = json.loads((ARTIFACTS / "c20_oracle_delay_fast_scheduling_review_v2.json").read_text())
BUILDER_PATH = ARTIFACTS / "c20_oracle_delay_s1_fast_safe_builder_v2.json"
BUILDER = json.loads(BUILDER_PATH.read_text())
EVIDENCE = POST["evidence"]
ZERO = "0x" + "00" * 20


class C20FastS1Postflight(unittest.TestCase):
    def test_canonical_receipt_and_public_input(self):
        self.assertEqual(EVIDENCE["chainId"], 84532)
        self.assertEqual(EVIDENCE["publicTxHash"],
                         "0x22915a6b6671a46f806a3b08571b5d735e493d2eb10e62816d4ddfe0482f2cfe")
        receipt = EVIDENCE["receipt"]
        self.assertEqual((receipt["status"], receipt["blockNumber"], receipt["timestamp"]),
                         (1, 48355814, 1792479916))
        self.assertTrue(receipt["transactionInCanonicalBlock"])
        self.assertEqual(receipt["logCount"], 3)
        self.assertEqual(EVIDENCE["transaction"]["to"].lower(), REVIEW["safe"]["address"].lower())
        self.assertTrue(EVIDENCE["transaction"]["canonicalAbiEncoding"])

    def test_safe_execution_and_nonce_transition(self):
        safe = EVIDENCE["safe"]
        self.assertEqual(safe["safeTxHash"], REVIEW["safe"]["safeTxHashConditional"])
        self.assertTrue(safe["getTransactionHashMatches"] and safe["executionSuccess"])
        self.assertFalse(safe["executionFailure"])
        self.assertEqual([safe[k] for k in ("nonceBefore", "nonceAtReceipt", "nonceLatest")], [23, 24, 24])
        self.assertEqual((safe["threshold"], len(safe["owners"]), safe["modules"], safe["guard"]),
                         (2, 3, [], ZERO))
        self.assertTrue(safe["signatureBytesNotStored"])
        self.assertEqual(safe["signatureBytesLength"], 130)

    def test_one_exact_safe_call_and_trace(self):
        call = EVIDENCE["safe"]["decodedExecTransaction"]
        intent = REVIEW["safe"]["envelope"]
        for field in ("to", "value", "operation", "data", "safeTxGas", "baseGas", "gasPrice",
                      "gasToken", "refundReceiver"):
            name = "valueWei" if field == "value" else field
            self.assertEqual(call[name].lower() if isinstance(call[name], str) else call[name],
                             intent[field].lower() if isinstance(intent[field], str) else intent[field])
        self.assertEqual(call["operation"], 0)
        self.assertEqual(call["dataKeccak256"], REVIEW["C20"]["queueCalldataKeccak256"])
        trace = EVIDENCE["trace"]
        self.assertEqual(trace["availability"], "AVAILABLE")
        self.assertTrue(trace["singleReviewedSafeToTimelockCall"] and trace["noCallErrors"])
        self.assertTrue(trace["noD5SetterCall"])
        calls = [row for row in trace["callTree"] if row["depth"] == 2 and row["type"] == "CALL"]
        self.assertEqual(len(calls), 1)
        self.assertEqual((calls[0]["to"], calls[0]["selector"]),
                         (intent["to"].lower(), "0x8e361cdf"))

    def test_operation_identity_event_and_delay(self):
        op = EVIDENCE["timelock"]
        intent = REVIEW["C20"]
        inner = bytes.fromhex(op["data"][2:])
        self.assertEqual(inner, keccak(text="setMaxOracleDelay(uint256)")[:4] + encode(["uint256"], [600]))
        self.assertEqual("0x" + keccak(inner).hex(), intent["innerCalldataKeccak256"])
        encoded = encode(["address", "uint256", "bytes", "uint256"],
                         [op["target"], op["valueWei"], inner, op["eta"]])
        self.assertEqual("0x" + keccak(encoded).hex(), intent["operationId"])
        self.assertEqual(op["eta"], 1792584000)
        self.assertTrue(op["queueEvent"] and op["operationHashGetterMatches"])
        self.assertEqual(op["minDelayAtReceipt"], 86400)
        self.assertGreaterEqual(op["delayExcessSeconds"], 3600)

    def test_queued_not_executed_or_duplicated(self):
        op = EVIDENCE["timelock"]
        self.assertEqual([op[k] for k in ("queuedBefore", "queuedAtReceipt", "queuedLatest")],
                         [False, True, True])
        self.assertFalse(op["readyLatest"])
        self.assertEqual((op["operationScopedEventCount"], op["D5ScopedEventCount"]), (1, 1))
        self.assertEqual(op["operationHistory"][0]["publicTxHash"], EVIDENCE["publicTxHash"])
        self.assertEqual(POST["verdict"]["C20_EXECUTION_AUTHORIZED"], "NO")

    def test_pinned_maintenance_and_risk_non_drift(self):
        rows = EVIDENCE["boundedReadbacks"]
        for key in rows["before"]:
            if key in ("safeNonce", "tlQueued"):
                continue
            self.assertEqual(rows["before"][key], rows["receipt"][key], key)
            self.assertEqual(rows["receipt"][key], rows["latest"][key], key)
        now = rows["latest"]
        self.assertEqual(now["d5Delay"], 0)
        self.assertEqual([now[k] for k in ("d4Trading", "d4Liquidation", "d4Funding", "d4CollateralOps")],
                         [True] * 4)
        self.assertTrue(now["d6Paused"])
        self.assertEqual((now["d4Migration"], now["d4Risk"], now["d4Pme"]), (0, ZERO, ZERO))
        self.assertFalse(now["d4VaultAuthorized"] or now["d4InsuranceAuthorized"])
        self.assertEqual(len(set(EVIDENCE["runtimeHashes"]["D5"].values())), 1)

    def test_bounded_economics_and_c12_gate(self):
        now = EVIDENCE["boundedReadbacks"]["latest"]
        self.assertEqual((now["clearingLedger"], now["vaultTokenBalance"], now["insuranceLedger"]),
                         (1000000000, 224066000000, 2100010))
        self.assertEqual((now["d1Markets"], now["d2Budget"], now["d4BadDebt"]), (0, 0, 0))
        self.assertEqual(now["d3Config"], [0, False, False])
        self.assertEqual(POST["verdict"]["C12_AUTHORIZED"], "NO")
        self.assertIn("canonical C20 execution receipt", POST["interpretation"]["C12Gate"])

    def test_builder_and_reviewed_artifact_integrity(self):
        for name, digest in POST["repository"]["reviewedArtifactSha256"].items():
            self.assertEqual(hashlib.sha256((ARTIFACTS / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(BUILDER["chainId"], "84532")
        self.assertEqual(len(BUILDER["transactions"]), 1)
        self.assertEqual(BUILDER["transactions"][0]["data"],
                         EVIDENCE["safe"]["decodedExecTransaction"]["data"])
        self.assertEqual(POST["verdict"]["C20_S1_SCHEDULING"], "VERIFIED_SCHEDULED")
        self.assertEqual(POST["verdict"]["C20_S1_POSTFLIGHT"], "PASS")


if __name__ == "__main__":
    unittest.main()
