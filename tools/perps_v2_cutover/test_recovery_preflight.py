"""Offline synthetic-artifact tests for rejecting expanded M2 write boundaries."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from recovery_preflight import OWNER, PMR, VAULT, ORACLE, SETTERS, cast, verify_transactions


class WriteBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.predicted = "0xa2bdc0efe80806ffda20189294dd8a5a1b426f15"
        self.artifact = {"bytecode": {"object": "0x6000", "linkReferences": {}}}
        creation = "0x6000" + "".join(a[2:].lower().rjust(64, "0") for a in [OWNER, PMR, VAULT, ORACLE])
        self.run = {"chain": 84532, "receipts": [], "pending": [], "transactions": []}
        for i in range(9):
            tx = {"from": OWNER, "nonce": hex(790 + i), "chainId": hex(84532), "value": "0x0",
                  "input": creation if i == 0 else cast("calldata", *SETTERS[i - 1])}
            if i:
                tx["to"] = self.predicted
            self.run["transactions"].append({"transactionType": "CREATE" if i == 0 else "CALL",
                                              "contractAddress": self.predicted, "transaction": tx,
                                              "additionalContracts": []})

    def check(self, run):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic-dry-run.json"
            path.write_text(json.dumps(run))
            return verify_transactions(path, self.artifact, 790, self.predicted)

    def test_exact_sequence_accepted(self):
        self.assertEqual(len(self.check(self.run)), 9)

    def test_extra_library_deployment_rejected(self):
        self.run["transactions"].append(copy.deepcopy(self.run["transactions"][0]))
        with self.assertRaisesRegex(ValueError, "exactly nine"):
            self.check(self.run)

    def test_shared_dependency_target_rejected(self):
        self.run["transactions"][1]["transaction"]["to"] = SETTERS[0][1]
        with self.assertRaisesRegex(ValueError, "unexpected target"):
            self.check(self.run)

    def test_wrong_setter_argument_rejected(self):
        self.run["transactions"][8]["transaction"]["input"] = cast("calldata", "setGuardian(address)", PMR)
        with self.assertRaisesRegex(ValueError, "unexpected setter"):
            self.check(self.run)

    def test_wrong_nonce_rejected(self):
        self.run["transactions"][1]["transaction"]["nonce"] = hex(792)
        with self.assertRaisesRegex(ValueError, "nonce"):
            self.check(self.run)

    def test_wrong_creation_code_rejected(self):
        self.run["transactions"][0]["transaction"]["input"] += "00"
        with self.assertRaisesRegex(ValueError, "creation code"):
            self.check(self.run)

    def test_broadcast_receipt_rejected(self):
        self.run["receipts"] = [{"status": "0x1"}]
        with self.assertRaisesRegex(ValueError, "unbroadcast"):
            self.check(self.run)


if __name__ == "__main__":
    unittest.main()
