"""Focused offline checks for the canonical C01-S2 public postflight evidence."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak


ART = Path(__file__).resolve().parents[2] / "artifacts/perps_v2_replacement_deployment"
E = json.loads((ART / "c01_market_protection_s2_public_postflight_v1.json").read_text())
N = json.loads((ART / "c01_c12_s2_nonce_sequence_v1.json").read_text())
C01 = json.loads((ART / "c01_s2_safe_builder_v1.json").read_text())
C12 = json.loads((ART / "c12_s2_safe_builder_v1.json").read_text())


class C01S2PostflightEvidenceTest(unittest.TestCase):
    def test_supplied_hash_correction_is_explicit_and_unique(self):
        x = E["hashReconciliation"]
        self.assertEqual(len(x["operatorSuppliedHash"]), 65)
        self.assertFalse(x["operatorSuppliedHashValid"])
        self.assertEqual(len(x["canonicalPublicTxHash"]), 66)
        self.assertNotEqual(x["operatorSuppliedHash"], x["canonicalPublicTxHash"])
        self.assertEqual(E["canonicalPublicTransaction"]["to"].lower(), N["safe"].lower())

    def test_canonical_receipt_and_pinned_blocks(self):
        r = E["canonicalReceipt"]
        self.assertEqual(E["chain"]["chainId"], 84532)
        self.assertTrue(E["chain"]["blockHashesRechecked"])
        self.assertEqual(r["status"], 1)
        self.assertEqual(r["blockNumber"], 49433335)
        self.assertEqual(r["blockHash"], E["chain"]["blocks"]["receipt"]["hash"])
        self.assertGreaterEqual(E["chain"]["blocks"]["receipt"]["timestamp"], 1792756800)

    def test_safe_call_and_actual_fields_hash(self):
        tx = E["canonicalPublicTransaction"]["safeExecTransaction"]
        reviewed = N["first"]["safeTransaction"]
        self.assertEqual(tx["data"], reviewed["data"])
        self.assertEqual(tx["to"].lower(), reviewed["to"].lower())
        self.assertEqual(tx["valueWei"], 0)
        self.assertEqual(tx["operation"], 0)
        self.assertEqual([tx[x] for x in ("safeTxGas", "baseGas", "gasPrice")], [0, 0, 0])
        self.assertEqual(tx["gasToken"], tx["refundReceiver"])
        dtype = keccak(text="EIP712Domain(uint256 chainId,address verifyingContract)")
        stype = keccak(text="SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
        domain = keccak(encode(["bytes32", "uint256", "address"], [dtype, 84532, N["safe"]]))
        struct = keccak(encode(
            ["bytes32", "address", "uint256", "bytes32", "uint8", "uint256", "uint256", "uint256", "address", "address", "uint256"],
            [stype, tx["to"], 0, keccak(bytes.fromhex(tx["data"][2:])), 0, 0, 0, 0, tx["gasToken"], tx["refundReceiver"], 27],
        ))
        digest = "0x" + keccak(b"\x19\x01" + domain + struct).hex()
        self.assertEqual(digest, E["safe"]["actualFieldsEip712Hash"])
        self.assertEqual(digest, N["first"]["safeTxHash"])
        self.assertEqual(E["safe"]["executionSuccessEvent"]["safeTxHash"], digest)
        self.assertEqual(E["safe"]["executionFailureEvents"], [])

    def test_trace_has_one_call_to_timelock_and_d1(self):
        trace = E["executionTrace"]
        self.assertEqual(trace["status"], "AVAILABLE")
        root = trace["tree"]
        self.assertEqual(root["to"].lower(), N["safe"].lower())
        singleton = root["calls"][0]
        self.assertEqual(singleton["type"], "DELEGATECALL")
        calls = [x for x in singleton["calls"] if x["type"] == "CALL"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["to"].lower(), N["timelock"].lower())
        self.assertEqual(calls[0]["inputKeccak256"], N["first"]["calldataKeccak256"])
        self.assertEqual(len(calls[0]["calls"]), 1)
        self.assertEqual(calls[0]["calls"][0]["to"].lower(), C01["transactions"][0]["contractInputsValues"]["target"].lower())

    def test_timelock_exact_event_consumption_and_replay(self):
        tl = E["timelock"]
        ev = tl["executionEvent"]
        self.assertEqual(ev["operationId"], tl["operationId"])
        self.assertEqual(ev["valueWei"], 0)
        self.assertEqual(ev["eta"], 1792756800)
        self.assertEqual(ev["data"], C01["transactions"][0]["contractInputsValues"]["data"])
        self.assertEqual("0x" + keccak(bytes.fromhex(ev["data"][2:])).hex(), ev["dataKeccak256"])
        self.assertTrue(tl["queuedBefore"])
        self.assertFalse(tl["queuedAtReceipt"])
        self.assertFalse(tl["queuedLatest"])
        self.assertTrue(tl["replayEthCall"]["rejected"])

    def test_d1_primary_poststate_and_no_market(self):
        d = E["d1"]
        self.assertEqual(d["allowanceBeforeReceiptLatest"], [False, True, True])
        self.assertEqual(d["marketCountBeforeReceiptLatest"], [0, 0, 0])
        self.assertEqual(d["marketIdsBeforeReceiptLatest"], [[], [], []])
        self.assertEqual(len(d["settlementEventsReceiptToLatest"]), 1)
        self.assertEqual(d["settlementEventsReceiptToLatest"][0]["transactionHash"], E["hashReconciliation"]["canonicalPublicTxHash"])
        self.assertEqual(d["runtimeHashAtReceipt"], d["runtimeHashLatest"])

    def test_safe_nonce_and_threshold_transition(self):
        safe = E["safe"]
        self.assertEqual([safe["nonceBefore"], safe["nonceAtReceipt"], safe["nonceLatest"]], [27, 28, 28])
        self.assertEqual(safe["thresholdBeforeReceiptLatest"], [2, 2, 2])
        self.assertEqual(safe["modulesLatest"], [])
        self.assertEqual(safe["signatureEvidence"].startswith("Safe transaction contained 130"), True)

    def test_maintenance_and_bounded_shared_non_drift(self):
        x = E["maintenanceAndEconomicState"]
        before, at, latest = (x[y] for y in ("before", "receipt", "latest"))
        self.assertEqual(x["sharedEconomicNonDrift"], "PASS_BOUNDED")
        for k in x["sharedComparedKeys"]:
            self.assertEqual(before[k], at[k], k)
            self.assertEqual(at[k], latest[k], k)
        for stage in (before, at, latest):
            self.assertTrue(all(stage[k] for k in ("d4Trading", "d4Liquidation", "d4Funding", "d4Collateral")))
            self.assertTrue(stage["d6Paused"])
            self.assertEqual(stage["d4Risk"], stage["d4Pme"])
            self.assertEqual(stage["d5Delay"], 600)
        samples = x["sampledPosition"]
        self.assertEqual(samples["before"]["sampledD4PositionReturnKeccak256"], samples["receipt"]["sampledD4PositionReturnKeccak256"])
        self.assertEqual(samples["receipt"]["sampledD4PositionReturnKeccak256"], samples["latest"]["sampledD4PositionReturnKeccak256"])

    def test_c12_readiness_is_conditional_and_hash_rederived(self):
        c = E["c12Readiness"]
        self.assertTrue(c["queuedLatest"])
        self.assertTrue(c["readyLatest"])
        self.assertEqual(c["safeNonceLatest"], 28)
        self.assertEqual(c["safeTxHashLocal"], c["safeTxHashDeployedGetter"])
        self.assertEqual(c["safeTxHashLocal"], N["second"]["safeTxHashConditional"])
        self.assertEqual(C12["transactions"][0]["data"], N["second"]["safeTransactionConditional"]["data"])
        self.assertEqual(hashlib.sha256((ART / "c12_s2_safe_builder_v1.json").read_bytes()).hexdigest(), c["builderJsonSha256"])
        self.assertIn("NOT_AUTHORIZED", c["status"])

    def test_no_agent_public_action_or_further_authorization(self):
        self.assertFalse(E["publicTransactionsSentByAgent"])
        self.assertEqual(E["verdict"]["C01_S2_EXECUTION"], "VERIFIED_SUCCESS")
        self.assertEqual(E["verdict"]["C01_S2_POSTFLIGHT"], "PASS")
        for k in ("C12_PUBLIC_EXECUTION_AUTHORIZED", "MARKET_CREATION_AUTHORIZED", "MIGRATION_REPLAY_AUTHORIZED", "PUBLIC_TRADING_AUTHORIZED"):
            self.assertEqual(E["verdict"][k], "NO")


if __name__ == "__main__":
    unittest.main()
