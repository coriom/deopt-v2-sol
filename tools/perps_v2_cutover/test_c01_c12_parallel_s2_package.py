"""Offline consistency checks for the two independent S2 Safe actions."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
REVIEW = json.loads((ART / "c01_c12_parallel_s2_execution_review_v1.json").read_text())
NONCES = json.loads((ART / "c01_c12_s2_nonce_sequence_v1.json").read_text())
EXPECTED = {
    "C01": ("0x3734e380d87e14827ace06325fa6bc352d1756e71212acb89133b6c33a03c4a6", 27),
    "C12": ("0x963584c123980e342dc6ee8eb9855243b6c75e05240235f579c64470f2224619", 28),
}


class ParallelS2PackageTest(unittest.TestCase):
    def test_snapshot_and_queued_identity(self):
        self.assertEqual(REVIEW["chain"]["chainId"], 84532)
        self.assertTrue(REVIEW["chain"]["blockHashRechecked"])
        self.assertEqual(REVIEW["timelock"]["eta"], 1792756800)
        self.assertEqual(REVIEW["timelock"]["expiryInclusiveUnix"], 1793966400)
        for name in EXPECTED:
            self.assertTrue(REVIEW["operations"][name]["queued"])
            self.assertFalse(REVIEW["operations"][name]["readyAtReview"])
            self.assertEqual(REVIEW["operations"][name]["postSchedulingExecutionOrCancellationEvents"], [])
            self.assertEqual(len(REVIEW["targetScopedQueueScan"][name]), 1)
            self.assertEqual(REVIEW["targetScopedQueueScan"][name][0]["operationId"],
                             REVIEW["operations"][name]["id"])

    def test_c01_builder_exact_single_action(self):
        self._check_operation("C01", "c01_s2_safe_builder_v1.json", "first", "safeTransaction")

    def test_c12_builder_exact_single_action(self):
        self._check_operation("C12", "c12_s2_safe_builder_v1.json", "second", "safeTransactionConditional")

    def _check_operation(self, name, filename, position, envelope_name):
        path = ART / filename
        builder = json.loads(path.read_text())
        self.assertEqual(builder["version"], "1.0")
        self.assertEqual(builder["chainId"], "84532")
        self.assertEqual(len(builder["transactions"]), 1)
        action = builder["transactions"][0]
        op = REVIEW["operations"][name]
        self.assertEqual(action["to"].lower(), REVIEW["timelock"]["address"].lower())
        self.assertEqual(action["value"], "0")
        self.assertEqual(action["contractMethod"]["name"], "executeTransaction")
        self.assertEqual([x["type"] for x in action["contractMethod"]["inputs"]],
                         ["address", "uint256", "bytes", "uint256"])
        self.assertEqual(action["data"], op["executeCalldata"])
        self.assertEqual(action["contractInputsValues"], {
            "target": op["target"], "value": "0", "data": op["innerCalldata"], "eta": "1792756800"
        })
        tx = bytes.fromhex(action["data"][2:])
        self.assertEqual(tx[:4], keccak(text="executeTransaction(address,uint256,bytes,uint256)")[:4])
        args = decode(["address", "uint256", "bytes", "uint256"], tx[4:])
        self.assertEqual(args, (op["target"].lower(), 0, bytes.fromhex(op["innerCalldata"][2:]), 1792756800))
        self.assertEqual(tx[4:], encode(["address", "uint256", "bytes", "uint256"], args))
        self.assertEqual("0x" + keccak(tx).hex(), EXPECTED[name][0])
        self.assertEqual("0x" + keccak(encode(["address", "uint256", "bytes", "uint256"], args)).hex(), op["id"])
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), op["builderJsonSha256"])
        record = NONCES[position]
        env = record[envelope_name]
        self.assertEqual(env["nonce"], EXPECTED[name][1])
        self.assertEqual(env["data"], action["data"])
        self.assertEqual(env["to"].lower(), action["to"].lower())
        self.assertEqual(env["operationCode"], 0)
        self.assertEqual([env[k] for k in ("safeTxGas", "baseGas", "gasPrice")], [0, 0, 0])
        self.assertEqual(record["builderJsonSha256"], op["builderJsonSha256"])
        self.assertEqual(record["safeTxHash" if name == "C01" else "safeTxHashConditional"], op["s2SafeTxHash"])

    def test_nonce_separation_and_conditional_second(self):
        self.assertEqual(NONCES["recommendedOrder"], ["C01", "C12"])
        self.assertEqual(NONCES["first"]["nonce"], 27)
        self.assertEqual(NONCES["second"]["nonce"], 28)
        self.assertIn("ONLY after C01", NONCES["second"]["condition"])
        self.assertNotEqual(NONCES["first"]["safeTxHash"], NONCES["second"]["safeTxHashConditional"])

    def test_maintenance_and_economic_prestate(self):
        state = REVIEW["publicPrestate"]
        self.assertEqual(state["d4FourEmergencyFlags"], [True] * 4)
        self.assertTrue(state["d6Paused"])
        self.assertEqual(state["d1MarketCount"], 0)
        self.assertFalse(state["d1MusdcAllowed"])
        self.assertEqual(state["d5Delay"], 600)
        self.assertFalse(state["vaultD4Authorized"])
        self.assertFalse(state["insuranceD4Authorized"])
        self.assertEqual(state["clearingLedger"], 1_000_000_000)

    def test_historical_s1_evidence_integrity(self):
        for name, filename, key in [
            ("C01", "c01_market_protection_s1_public_postflight_v1.json", "c01S1EvidenceSha256"),
            ("C12", "c12_risk_wiring_s1_public_postflight_v1.json", "c12S1EvidenceSha256"),
        ]:
            self.assertEqual(hashlib.sha256((ART / filename).read_bytes()).hexdigest(), REVIEW["repository"][key])
            receipt = REVIEW["s1CanonicalProof"][name]
            self.assertEqual(receipt["status"], 1)
            self.assertEqual(len(receipt["queueEvents"]), 1)
            self.assertEqual(receipt["queueEvents"][0]["operationId"], REVIEW["operations"][name]["id"])

    def test_no_public_authorization_or_batch(self):
        self.assertFalse(REVIEW["publicTransactionsSentByAgent"])
        self.assertEqual(REVIEW["authorization"], {
            "C01_EXECUTION_AUTHORIZED": "NO", "C12_EXECUTION_AUTHORIZED": "NO",
            "MARKET_CREATION_AUTHORIZED": "NO", "MIGRATION_REPLAY_AUTHORIZED": "NO",
            "PUBLIC_TRADING_AUTHORIZED": "NO",
        })
        self.assertEqual(REVIEW["forkRehearsal"]["passed"], 4)
        self.assertEqual(REVIEW["forkRehearsal"]["failed"], 0)


if __name__ == "__main__":
    unittest.main()
