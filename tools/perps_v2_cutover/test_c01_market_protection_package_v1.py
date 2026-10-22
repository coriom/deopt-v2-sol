"""Independent offline checks of the reviewed, unsigned C01 package."""

import hashlib
import json
from pathlib import Path
import unittest

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "artifacts/perps_v2_replacement_deployment"
ZERO = "0x" + "00" * 20


def get(name):
    return json.loads((ART / name).read_text())


class C01PackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.prep = get("c01_market_protection_preparation_v1.json")
        cls.intent = get("c01_market_protection_s1_unsigned_intent_v1.json")
        cls.builder = get("c01_market_protection_s1_safe_builder_v1.json")
        cls.review = get("c01_market_protection_s1_final_review_v1.json")
        cls.fork = get("c01_market_protection_fork_validation_v1.json")
        cls.dag = get("post_maintenance_dependency_dag_v1.json")
        cls.manifest = get("timelock_configuration_manifest_c12_c20_v2.json")

    def test_c01_is_not_c12_dependent(self):
        n = next(n for n in self.dag["nodes"] if n["id"] == "C01")
        self.assertEqual(n["dependsOn"], ["MAINTENANCE_VERIFIED"])
        self.assertIn({"from": "C01", "hard": True, "to": "C02"}, self.dag["edges"])
        self.assertTrue(self.prep["dependency"]["c12Queued"])
        self.assertFalse(self.prep["dependency"]["c12CompletionRequired"])

    def test_inner_matches_manifest_and_fixed_abi(self):
        a = next(a for a in self.manifest["actions"] if a["stageId"] == "C01")
        c = self.intent["innerCall"]
        self.assertEqual(c["signature"], "setSettlementAssetAllowed(address,bool)")
        self.assertEqual(c["target"].lower(), "0x6b3d846536116082dc4e7227861c341bb85ee963")
        self.assertEqual(c["calldata"], a["calldata"])
        self.assertEqual(c["calldata"][:10], "0x" + keccak(text=c["signature"])[:4].hex())
        self.assertEqual(decode(["address", "bool"], bytes.fromhex(c["calldata"][10:])),
                         (c["args"][0].lower(), True))

    def test_outer_is_one_canonical_timelock_call(self):
        tx = self.builder["transactions"]
        self.assertEqual(len(tx), 1)
        self.assertEqual(tx[0]["to"].lower(), self.intent["timelock"].lower())
        self.assertEqual(tx[0]["value"], "0")
        outer = tx[0]["data"]
        self.assertEqual(outer, self.intent["queueCall"]["calldata"])
        self.assertEqual(outer[:10], "0x" +
                         keccak(text="queueTransaction(address,uint256,bytes,uint256)")[:4].hex())
        target, value, data, eta = decode(["address", "uint256", "bytes", "uint256"],
                                          bytes.fromhex(outer[10:]))
        self.assertEqual((target, value, "0x" + data.hex(), eta),
                         (self.intent["innerCall"]["target"].lower(), 0,
                          self.intent["innerCall"]["calldata"], self.intent["queueCall"]["eta"]))
        self.assertEqual(tx[0]["contractInputsValues"]["eta"], str(eta))
        self.assertEqual(self.builder["meta"]["name"], "OFFLINE_REVIEW_ONLY_NOT_AUTHORIZED_C01_S1")

    def test_operation_identity_and_delay_margin(self):
        c = self.intent["innerCall"]
        q = self.intent["queueCall"]
        calculated = "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"],
                                          [c["target"], 0, bytes.fromhex(c["calldata"][2:]), q["eta"]])).hex()
        self.assertEqual(calculated, q["operationId"])
        self.assertEqual(calculated, self.review["operationId"])
        self.assertGreaterEqual(q["eta"] - self.prep["reviewBlock"]["timestamp"],
                                self.review["minDelaySeconds"] + 3600)

    def test_safe_eip712_hash_is_conditional_and_exact(self):
        s = self.intent["safeEnvelope"]
        domain = keccak(encode(["bytes32", "uint256", "address"],
                               [keccak(text="EIP712Domain(uint256 chainId,address verifyingContract)"),
                                84532, self.intent["safe"]]))
        tx_type = keccak(text="SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
        struct = keccak(encode(["bytes32", "address", "uint256", "bytes32", "uint8",
                                "uint256", "uint256", "uint256", "address", "address", "uint256"],
                               [tx_type, s["to"], 0, keccak(bytes.fromhex(s["data"][2:])),
                                s["operation"], s["safeTxGas"], s["baseGas"], s["gasPrice"],
                                s["gasToken"], s["refundReceiver"], s["nonce"]]))
        self.assertEqual(s["gasToken"], ZERO)
        self.assertEqual(s["refundReceiver"], ZERO)
        self.assertEqual(s["operation"], 0)
        self.assertEqual("0x" + keccak(b"\x19\x01" + domain + struct).hex(),
                         self.review["safeTxHashConditional"])

    def test_evidence_refs_and_no_authorization(self):
        for key in ("preparation", "unsignedIntent", "builder", "forkValidation"):
            ref = self.review[key]
            self.assertEqual(hashlib.sha256((ROOT / ref["path"]).read_bytes()).hexdigest(),
                             ref["sha256"])
        self.assertEqual(self.fork["correctedRun"]["passed"], 3)
        self.assertEqual(self.fork["correctedRun"]["failed"], 0)
        self.assertFalse(self.review["publicSigning"])
        self.assertFalse(self.review["safeProposal"])
        self.assertFalse(self.review["publicScheduling"])
        self.assertFalse(self.review["publicExecution"])
        self.assertEqual(self.review["economicIsolation"], "PASS_BOUNDED_FORK_AND_PINNED_STATE")


if __name__ == "__main__":
    unittest.main()
