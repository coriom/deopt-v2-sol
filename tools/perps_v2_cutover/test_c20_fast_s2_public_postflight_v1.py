"""Offline integrity checks for the canonical, sanitized C20-S2 postflight."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
E = json.loads((ART / "c20_oracle_delay_fast_s2_public_postflight_v1.json").read_text())
I = json.loads((ART / "c20_oracle_delay_fast_s2_unsigned_intent_v1.json").read_text())
P = E["public"]


class C20S2PostflightEvidence(unittest.TestCase):
    def test_reviewed_intent_and_checkpoint_unchanged(self):
        for label, name in (
            ("unsignedIntent", "c20_oracle_delay_fast_s2_unsigned_intent_v1.json"),
            ("operatorCheckpoint", "c20_oracle_delay_fast_s2_operator_checkpoint_v1.json"),
            ("correctedManifest", "timelock_configuration_manifest_c12_c20_v2.json"),
        ):
            self.assertEqual(hashlib.sha256((ART / name).read_bytes()).hexdigest(),
                             E["repository"]["historicalSha256"][label])

    def test_canonical_receipt_and_single_safe_call(self):
        self.assertEqual((P["chainId"], P["receipt"]["status"]), (84532, 1))
        self.assertTrue(P["blocks"]["hashesRechecked"])
        self.assertEqual(P["receipt"]["blockHash"], P["blocks"]["receipt"]["hash"])
        tx = P["transaction"]["decodedSafeFields"]
        self.assertEqual((tx["operation"], tx["value"], tx["to"].lower()),
                         (0, 0, I["timelockAddress"].lower()))
        self.assertEqual(tx["data"], I["timelockCall"]["data"])
        self.assertEqual(tx["signatureSlots65"], 2)
        self.assertTrue(P["transaction"]["signaturesRedacted"])

    def test_safe_and_timelock_inner_success(self):
        self.assertEqual(P["safe"]["successEvents"], [
            {"safeTxHash": I["safeTxHashConditional"], "paymentWei": 0}])
        self.assertEqual(P["safe"]["failureEvents"], [])
        self.assertEqual(P["safe"]["getTransactionHashAtPreReceiptBlock"],
                         I["safeTxHashConditional"])
        self.assertEqual((P["state"]["before"]["safeNonce"],
                          P["state"]["receipt"]["safeNonce"]), (24, 25))
        event = P["timelock"]["executionEvents"]
        self.assertEqual(len(event), 1)
        self.assertEqual((event[0]["operationId"], event[0]["innerCalldata"],
                          event[0]["eta"]),
                         (I["operation"]["id"], I["operation"]["innerCalldata"],
                          I["operation"]["eta"]))

    def test_trace_consumption_and_d5_readback(self):
        trace = P["trace"]
        self.assertTrue(trace["available"] and trace["allCallsSucceeded"])
        calls = [(n["to"].lower(), n["selector"]) for n in trace["nodes"]
                 if n["type"] == "CALL" and n["depth"] >= 2]
        self.assertEqual(calls, [
            (I["timelockAddress"].lower(), "0x06a41d09"),
            (I["operation"]["target"].lower(), "0xcd3b691c")])
        before, after, latest = (P["state"][name] for name in ("before", "receipt", "latest"))
        self.assertEqual((before["queued"], after["queued"], latest["queued"]),
                         (True, False, False))
        self.assertTrue(P["timelock"]["replay"]["rejected"])
        self.assertEqual((before["d5Delay"], after["d5Delay"], latest["d5Delay"]),
                         (0, 600, 600))
        self.assertEqual(P["d5"]["delaySetEventsInReceipt"], [{"old": 0, "new": 600}])

    def test_bounded_non_drift_and_maintenance(self):
        before, after, latest = (P["state"][name] for name in ("before", "receipt", "latest"))
        self.assertEqual({key for key in before if before[key] != after[key]},
                         {"safeNonce", "queued", "d5Delay"})
        self.assertEqual(after, latest)
        for state in (before, after, latest):
            self.assertTrue(all(state[key] for key in
                                ("d4Trading", "d4Liquidation", "d4Funding",
                                 "d4Collateral", "d6Paused")))
            self.assertEqual((state["d4Migration"], state["d4BadDebt"],
                              state["pmrMarketCount"], state["fmRebateBudget"]),
                             (0, 0, 0, 0))
            self.assertFalse(state["d4VaultAuthorized"] or
                             state["d4InsuranceAuthorized"])
        self.assertEqual(before["vaultClearingLedger"], 1_000_000_000)

    def test_c12_is_preparation_only(self):
        self.assertEqual(E["c12Gate"]["status"],
                         "PASS_FOR_SEPARATE_PREPARATION_ONLY")
        self.assertEqual(E["c12Gate"]["supportedWorkflowResult"]["d5MaxOracleDelay"], 600)
        self.assertFalse(E["c12Authorized"] or E["migrationReplayAuthorized"] or
                         E["publicTradingAuthorized"] or E["agentPublicTransactionsSent"])
        self.assertEqual(E["verdict"]["C12_PREPARATION_ELIGIBLE"], "YES")


if __name__ == "__main__":
    unittest.main()
