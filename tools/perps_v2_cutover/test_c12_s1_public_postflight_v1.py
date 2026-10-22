"""Focused, offline consistency checks for the C12-S1 public postflight."""

import hashlib
import json
from pathlib import Path
import unittest

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
POST = json.loads((ART / "c12_risk_wiring_s1_public_postflight_v1.json").read_text())
INTENT = json.loads((ART / "c12_risk_wiring_fast_unsigned_safe_schedule_v1.json").read_text())
BUILDER = json.loads((ART / "c12_risk_wiring_fast_s1_safe_builder_v1.json").read_text())
E = POST["evidence"]
OP = "0xd15ec63a22daebd4eb015de23561089547af9b02945fb8ae6dd7028ae7581229"
SAFE_HASH = "0x6cce2c2dcde9635050713acf875793ae2d6767d35f0f755318c9eec72260b9bf"
TX_HASH = "0x27e61939bf39f0db3671ea610d8783ce229bd93a9f154bb04255650c833b3535"
ZERO = "0x" + "00" * 20


class C12S1PublicPostflight(unittest.TestCase):
    def test_canonical_receipt_and_outer_input(self):
        self.assertEqual((E["chainId"], E["publicTxHash"]), (84532, TX_HASH))
        self.assertEqual((E["receipt"]["status"], E["receipt"]["blockNumber"]), (1, 48598531))
        self.assertEqual(E["receipt"]["blockHash"], E["blocks"]["receipt"]["hash"])
        self.assertTrue(E["blocks"]["hashesRechecked"])
        self.assertEqual(E["blocks"]["receipt"]["timestamp"], 1792641575)
        self.assertEqual(E["transaction"]["to"].lower(), "0xdb9b1e94b5b69df7e401ddbede43491141047db3")
        self.assertEqual(E["transaction"]["inputSelector"], "0xcef6d209")

    def test_exact_safe_execution_and_nonce(self):
        safe = E["safe"]
        self.assertEqual(safe["executionSuccess"], [{"paymentWei": 0, "safeTxHash": SAFE_HASH}])
        self.assertEqual(safe["executionFailure"], [])
        self.assertEqual(safe["getTransactionHashAtPreReceiptBlock"], SAFE_HASH)
        self.assertEqual([E["state"][n]["safeNonce"] for n in ("before", "receipt", "latest")], [25, 26, 26])
        self.assertEqual((safe["currentGovernance"]["threshold"], len(safe["currentGovernance"]["owners"])), (2, 3))
        self.assertEqual((safe["currentGovernance"]["modules"], safe["currentGovernance"]["guard"]), ([], ZERO))

    def test_nested_single_call_and_reviewed_envelope(self):
        trace = E["trace"]
        self.assertTrue(trace["available"] and trace["allCallsSucceeded"])
        nodes = trace["nodes"]
        safe = [n for n in nodes if n["to"] == INTENT["safeEnvelope"]["safe"].lower() and n["selector"] == "0x6a761202"]
        tl = [n for n in nodes if n["to"] == INTENT["safeEnvelope"]["to"].lower() and n["selector"] == "0x8e361cdf"]
        self.assertEqual((len(safe), len(tl)), (1, 1))
        self.assertEqual((safe[0]["type"], tl[0]["type"], tl[0]["from"], tl[0]["value"]),
                         ("CALL", "CALL", INTENT["safeEnvelope"]["safe"].lower(), "0x0"))
        self.assertEqual(tl[0]["inputKeccak256"], INTENT["timelockQueueCall"]["queueKeccak256"])
        self.assertFalse([n for n in nodes if n["to"] == INTENT["timelockOperation"]["target"].lower()])
        decoded = E["safe"]["decodedExecTransaction"]
        for key in ("to", "data", "operation", "safeTxGas", "baseGas", "gasPrice", "gasToken", "refundReceiver"):
            self.assertEqual(str(decoded[key]).lower(), str(INTENT["safeEnvelope"][key]).lower(), key)
        self.assertEqual((decoded["valueWei"], decoded["signatureBytesLength"], decoded["signatureSlots65"]), (0, 130, 2))

    def test_timelock_event_and_operation_identity(self):
        op = E["timelock"]
        self.assertEqual(len(op["queueEvents"]), 1)
        event = op["queueEvents"][0]
        self.assertEqual(event["operationId"], OP)
        self.assertEqual((event["target"], event["valueWei"], event["data"], event["eta"]),
                         (INTENT["timelockOperation"]["target"].lower(), 0,
                          INTENT["timelockOperation"]["innerCalldata"], 1792756800))
        inner = bytes.fromhex(event["data"][2:])
        self.assertEqual(inner, keccak(text="setRiskModule(address)")[:4] +
                         encode(["address"], [INTENT["timelockOperation"]["riskModuleArg"]]))
        self.assertEqual("0x" + keccak(encode(["address", "uint256", "bytes", "uint256"],
                                               [event["target"], 0, inner, event["eta"]])).hex(), OP)
        self.assertEqual(op["hashOperationOnchain"], OP)

    def test_delay_queue_consumption_and_duplicate_scope(self):
        op = E["timelock"]
        self.assertEqual(op["minDelayAtReceipt"], 86400)
        self.assertGreaterEqual(op["eta"] - E["blocks"]["receipt"]["timestamp"] - 86400, 3600)
        self.assertEqual([E["state"][n]["tlQueued"] for n in ("before", "receipt", "latest")],
                         [False, True, True])
        self.assertEqual(op["postReceiptOperationEvents"], [])
        self.assertEqual(len(op["recentExactC12QueueEvents"]), 1)
        self.assertEqual(op["recentExactC12QueueEvents"][0]["publicTxHash"], TX_HASH)
        self.assertEqual(op["recentD4QueueEvents"], 1)

    def test_maintenance_and_risk_non_drift(self):
        before, receipt, latest = [E["state"][n] for n in ("before", "receipt", "latest")]
        for key in before:
            if key not in ("safeNonce", "tlQueued"):
                self.assertEqual(before[key], receipt[key], key)
                self.assertEqual(receipt[key], latest[key], key)
        self.assertEqual((latest["d4Risk"], latest["d4Pme"], latest["d4Migration"]), (ZERO, ZERO, 0))
        self.assertEqual(latest["d4Flags"], [True] * 4)
        self.assertEqual((latest["d5Delay"], latest["d5Engine"], latest["d6Paused"]),
                         (600, INTENT["timelockOperation"]["target"].lower(), True))
        self.assertFalse(latest["d4VaultAuthorized"] or latest["d4InsuranceAuthorized"])

    def test_bounded_shared_economics_and_runtime(self):
        latest = E["state"]["latest"]
        self.assertEqual((latest["vaultClearingLedger"], latest["pmrMarketCount"],
                          latest["fmRebateBudget"], latest["d4BadDebt"]), (1000000000, 0, 0, 0))
        self.assertEqual(latest["d3SeizeConfig"], [0, False, False])
        self.assertEqual((latest["d6TraderNonce"], latest["d6ZeroFill"]), (0, 0))
        self.assertEqual(E["runtimeHashesLatest"]["D4"],
                         "0x1ee5dc2756bea85a4ab327ff69f8652ef6aa0acf2883f00ad1a23c7f51f95785")
        self.assertEqual(E["runtimeHashesLatest"]["D5"],
                         "0x8c782209845865d35ecff80c00525ef3f0f335bea4e7b9846f01199c60fb5a2c")

    def test_reviewed_artifacts_and_stopping_state(self):
        for name, digest in POST["repository"]["reviewedArtifactSha256"].items():
            self.assertEqual(hashlib.sha256((ART / name).read_bytes()).hexdigest(), digest, name)
        self.assertEqual(BUILDER["chainId"], "84532")
        self.assertEqual(len(BUILDER["transactions"]), 1)
        self.assertEqual(BUILDER["transactions"][0]["data"], E["safe"]["decodedExecTransaction"]["data"])
        self.assertEqual(POST["verdict"]["C12_S1_SCHEDULING"], "VERIFIED_SCHEDULED")
        self.assertEqual(POST["verdict"]["C12_EXECUTION_AUTHORIZED"], "NO")
        self.assertEqual(POST["publicTransactionsSentByAgent"], 0)


if __name__ == "__main__":
    unittest.main()
