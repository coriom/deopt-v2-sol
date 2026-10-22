"""Focused offline consistency checks for C01-S1 public postflight evidence."""

import hashlib
import json
from pathlib import Path
import unittest

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
POST = json.loads((ART / "c01_market_protection_s1_public_postflight_v1.json").read_text())
INTENT = json.loads((ART / "c01_market_protection_s1_unsigned_intent_v1.json").read_text())
BUILDER = json.loads((ART / "c01_market_protection_s1_safe_builder_v1.json").read_text())
E = POST["evidence"]
TX = "0xe2493d18a752ab078d2916793c0aa00b28c473bca916ad60ff9ec727356bb46e"
OP = "0x589fb819f60769c77ad9090750f2173377eb45dcbb5367fbc0fb978e4e15d396"
SAFE_HASH = "0x6f4f68cf38bd215e2ec4cb05c021aeee2286822d9ff1c8b8cd4f286657eabaef"
ZERO = "0x" + "00" * 20


class C01S1PublicPostflight(unittest.TestCase):
    def test_receipt_and_canonical_blocks(self):
        self.assertEqual((E["chainId"], E["publicTxHash"]), (84532, TX))
        self.assertEqual((E["receipt"]["status"], E["receipt"]["blockNumber"]), (1, 48664062))
        self.assertEqual(E["receipt"]["blockHash"], E["blocks"]["receipt"]["hash"])
        self.assertTrue(all(E["blockHashesRechecked"].values()))
        self.assertEqual(E["blocks"]["receipt"]["timestamp"], 1792654681)
        self.assertEqual(E["transaction"]["to"], "0xdb9b1e94b5b69df7e401ddbede43491141047db3")
        self.assertEqual(E["transaction"]["inputSelector"], "0xcef6d209")

    def test_safe_success_nonce_and_governance(self):
        self.assertEqual(E["safe"]["executionSuccess"], [{"paymentWei": 0, "safeTxHash": SAFE_HASH}])
        self.assertEqual(E["safe"]["executionFailure"], [])
        self.assertEqual(E["safe"]["getTransactionHashAtPreReceiptBlock"], SAFE_HASH)
        self.assertEqual([E["state"][w]["safeNonce"] for w in ("before", "receipt", "latest")], [26, 27, 27])
        gov = E["safe"]["currentGovernance"]
        self.assertEqual((gov["threshold"], len(gov["owners"]), gov["modules"], gov["guard"]),
                         (2, 3, [], ZERO))

    def test_exact_single_call_and_no_direct_d1_call(self):
        nodes = E["trace"]["nodes"]
        self.assertTrue(E["trace"]["available"] and E["trace"]["allCallsSucceeded"])
        safe = [n for n in nodes if n["to"] == INTENT["safe"].lower() and n["selector"] == "0x6a761202"]
        tl = [n for n in nodes if n["to"] == INTENT["timelock"].lower() and n["selector"] == "0x8e361cdf"]
        self.assertEqual((len(safe), len(tl)), (1, 1))
        self.assertEqual((safe[0]["type"], tl[0]["type"], tl[0]["from"], tl[0]["value"]),
                         ("CALL", "CALL", INTENT["safe"].lower(), "0x0"))
        self.assertTrue(tl[0]["path"].startswith(safe[0]["path"] + "/"))
        self.assertEqual(tl[0]["inputKeccak256"], "0x" + keccak(bytes.fromhex(INTENT["queueCall"]["calldata"][2:])).hex())
        self.assertEqual([n for n in nodes if n["to"] == INTENT["innerCall"]["target"].lower()], [])
        decoded = E["safe"]["decodedExecTransactions"]
        self.assertEqual(len(decoded), 1)
        for key in ("to", "data", "operation", "safeTxGas", "baseGas", "gasPrice", "gasToken", "refundReceiver"):
            self.assertEqual(str(decoded[0][key]).lower(), str(INTENT["safeEnvelope"][key]).lower(), key)
        self.assertEqual((decoded[0]["valueWei"], decoded[0]["signatureBytesLength"], decoded[0]["signatureSlots65"]),
                         (0, 130, 2))

    def test_queue_event_abi_and_operation_identity(self):
        events = E["timelock"]["queueEvents"]
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual((event["operationId"], event["target"], event["valueWei"], event["eta"]),
                         (OP, INTENT["innerCall"]["target"].lower(), 0, 1792756800))
        inner = bytes.fromhex(event["data"][2:])
        self.assertEqual(inner, keccak(text="setSettlementAssetAllowed(address,bool)")[:4] +
                         encode(["address", "bool"], [INTENT["innerCall"]["args"][0], True]))
        self.assertEqual(decode(["address", "bool"], inner[4:]), (INTENT["innerCall"]["args"][0].lower(), True))
        self.assertEqual("0x" + keccak(encode(["address", "uint256", "bytes", "uint256"],
                                               [event["target"], 0, inner, event["eta"]])).hex(), OP)
        self.assertEqual(E["timelock"]["hashOperationOnchain"], OP)

    def test_delay_queue_and_duplicate_scope(self):
        tl = E["timelock"]
        self.assertGreaterEqual(tl["eta"] - E["blocks"]["receipt"]["timestamp"] - tl["minDelayAtReceipt"], 3600)
        self.assertEqual([E["state"][w]["c01Queued"] for w in ("before", "receipt", "latest")],
                         [False, True, True])
        self.assertEqual([E["state"][w]["c12Queued"] for w in ("before", "receipt", "latest")],
                         [True, True, True])
        self.assertEqual(tl["postReceiptOperationEvents"], [])
        self.assertEqual(len(tl["recentD1QueueEvents"]), 1)
        self.assertEqual((tl["recentD1QueueEvents"][0]["publicTxHash"],
                          tl["recentD1QueueEvents"][0]["operationId"]), (TX, OP))
        history = POST["historicalD1QueueScan"]
        self.assertEqual((history["fromBlock"], history["toBlock"], history["chunks"]),
                         (47830000, E["blocks"]["latest"]["number"], 42))
        self.assertEqual(history["queueEvents"], history["equivalentC01Events"])
        self.assertEqual(len(history["queueEvents"]), 1)
        self.assertEqual((history["queueEvents"][0]["operationId"], history["queueEvents"][0]["publicTxHash"]),
                         (OP, TX))

    def test_d1_allowance_and_empty_market_non_drift(self):
        for w in ("before", "receipt", "latest"):
            s = E["state"][w]
            self.assertEqual((s["d1Allowed"], s["d1MarketCount"], s["d1MarketIds"], s["d1NextMarketId"]),
                             (False, 0, [], 1))
            self.assertEqual(s["d1Owner"], INTENT["timelock"].lower())
        self.assertEqual(E["runtimeHashesLatest"]["D1"],
                         "0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5")

    def test_maintenance_and_bounded_economics(self):
        before, receipt, latest = [E["state"][w] for w in ("before", "receipt", "latest")]
        for key in before:
            if key not in ("safeNonce", "c01Queued"):
                self.assertEqual(before[key], receipt[key], key)
                self.assertEqual(receipt[key], latest[key], key)
        self.assertEqual([latest[k] for k in ("tradingPaused", "liquidationPaused", "fundingPaused", "collateralOpsPaused")], [True] * 4)
        self.assertEqual((latest["d4Migration"], latest["d4Risk"], latest["d4Pme"], latest["d5Delay"], latest["d6Paused"]),
                         (0, ZERO, ZERO, 600, True))
        self.assertEqual((latest["vaultD4Authorized"], latest["insuranceD4Authorized"], latest["vaultClearingLedger"]),
                         (False, False, 1000000000))
        self.assertEqual((latest["fmRebateBudget"], latest["d4Debt"], latest["d4PositionSize"], latest["d4TraderMarkets"]),
                         (0, 0, 0, 0))

    def test_artifact_integrity_and_stopping_state(self):
        for name, digest in POST["repository"]["reviewedArtifactSha256"].items():
            self.assertEqual(hashlib.sha256((ART / name).read_bytes()).hexdigest(), digest, name)
        self.assertEqual((BUILDER["chainId"], len(BUILDER["transactions"])), ("84532", 1))
        self.assertEqual(BUILDER["transactions"][0]["data"], E["safe"]["decodedExecTransactions"][0]["data"])
        self.assertEqual(POST["verdict"]["C01_S1_SCHEDULING"], "VERIFIED_SCHEDULED")
        self.assertEqual(POST["verdict"]["C01_EXECUTION_AUTHORIZED"], "NO")
        self.assertEqual(POST["publicTransactionsSentByAgent"], 0)
        self.assertTrue(POST["tomorrowExecutionPlanning"]["C12_S2_SAFE_NONCE_REVIEW_REQUIRED"])


if __name__ == "__main__":
    unittest.main()
