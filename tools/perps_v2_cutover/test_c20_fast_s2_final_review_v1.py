"""Offline cross-checks for the unsigned, queued C20-S2 execution package."""

import hashlib
import json
from pathlib import Path
import unittest

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts/perps_v2_replacement_deployment"
REVIEW = json.loads((ARTIFACTS / "c20_oracle_delay_fast_s2_final_review_v1.json").read_text())
INTENT = json.loads((ARTIFACTS / "c20_oracle_delay_fast_s2_unsigned_intent_v1.json").read_text())
BUILDER = json.loads((ARTIFACTS / "c20_oracle_delay_fast_s2_safe_builder_v1.json").read_text())
POST = json.loads((ARTIFACTS / "c20_oracle_delay_fast_s1_public_postflight_v1.json").read_text())
ZERO = "0x" + "00" * 20


class C20FastS2FinalReview(unittest.TestCase):
    def test_preserves_s1_evidence_and_manifest(self):
        for name, digest in (("c20_oracle_delay_fast_s1_public_postflight_v1.json",
                              REVIEW["repository"]["S1PostflightSha256"]),
                             ("timelock_configuration_manifest_c12_c20_v2.json",
                              REVIEW["repository"]["C12C20ManifestSha256"])):
            self.assertEqual(hashlib.sha256((ARTIFACTS / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(REVIEW["s1CanonicalReceipt"]["txHash"], POST["evidence"]["publicTxHash"])
        self.assertEqual(REVIEW["s1CanonicalReceipt"]["blockHash"], POST["evidence"]["receipt"]["blockHash"])
        self.assertTrue(REVIEW["s1CanonicalReceipt"]["safeSuccess"])
        self.assertTrue(REVIEW["s1CanonicalReceipt"]["queueEvent"])

    def test_existing_queued_operation_and_window(self):
        op = REVIEW["timelock"]["operation"]
        self.assertEqual(op["id"], POST["evidence"]["timelock"]["operationId"])
        self.assertEqual((op["eta"], op["expiryInclusive"]), (1792584000, 1793793600))
        self.assertTrue(op["queued"])
        self.assertFalse(op["readyNow"])
        self.assertEqual(op["executionOrCancelEventsSinceS1"], 0)
        self.assertLess(REVIEW["chain"]["reviewBlock"]["timestamp"], op["eta"])
        self.assertEqual(REVIEW["publicExecutionReadyNow"], "NO_WAITING_FOR_ETA")

    def test_exact_inner_setter_and_operation_hash(self):
        op = INTENT["operation"]
        inner = keccak(text="setMaxOracleDelay(uint256)")[:4] + encode(["uint256"], [600])
        self.assertEqual("0x" + inner.hex(), op["innerCalldata"])
        self.assertEqual("0x" + keccak(inner).hex(), op["innerCalldataKeccak256"])
        operation_id = "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"],
                                             [op["target"], 0, inner, op["eta"]])).hex()
        self.assertEqual(operation_id, op["id"])
        self.assertTrue(REVIEW["timelock"]["operation"]["onChainHashMatch"])

    def test_exact_custom_execute_calldata(self):
        call = INTENT["timelockCall"]
        args = [INTENT["operation"]["target"], 0,
                bytes.fromhex(INTENT["operation"]["innerCalldata"][2:]), 1792584000]
        types = ["address", "uint256", "bytes", "uint256"]
        expected = keccak(text=call["function"])[:4] + encode(types, args)
        self.assertEqual(expected[:4], bytes.fromhex("06a41d09"))
        self.assertEqual(call["data"], "0x" + expected.hex())
        self.assertEqual(decode(types, expected[4:]), (args[0].lower(), 0, args[2], args[3]))
        self.assertEqual(len(expected), 228)
        self.assertEqual(call["dataKeccak256"], "0x" + keccak(expected).hex())
        self.assertEqual(call["dataSha256"], hashlib.sha256(expected).hexdigest())

    def test_safe_envelope_and_independent_eip712_hash(self):
        envelope = INTENT["safeEnvelope"]
        self.assertEqual((envelope["to"], envelope["value"], envelope["operation"], envelope["nonce"]),
                         (INTENT["timelockAddress"], 0, 0, 24))
        self.assertEqual((envelope["safeTxGas"], envelope["baseGas"], envelope["gasPrice"],
                          envelope["gasToken"], envelope["refundReceiver"]), (0, 0, 0, ZERO, ZERO))
        domain = keccak(encode(["bytes32", "uint256", "address"],
                               [keccak(text="EIP712Domain(uint256 chainId,address verifyingContract)"),
                                84532, INTENT["safeAddress"]]))
        self.assertEqual("0x" + domain.hex(),
                         "0x2c0d582d9c9e132109be0c6b670d4740fd7774bb12703c7888886a9b7748656a")
        self.assertTrue(REVIEW["safe"]["safeTxHashMatchesDeployedGetter"])
        struct = keccak(encode(["bytes32", "address", "uint256", "bytes32", "uint8", "uint256",
                                "uint256", "uint256", "address", "address", "uint256"],
                               [keccak(text="SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"),
                                envelope["to"], 0, keccak(bytes.fromhex(envelope["data"][2:])),
                                0, 0, 0, 0, ZERO, ZERO, 24]))
        self.assertEqual("0x" + keccak(b"\x19\x01" + domain + struct).hex(),
                         INTENT["safeTxHashConditional"])
        self.assertNotEqual(INTENT["safeTxHashConditional"], POST["evidence"]["safe"]["safeTxHash"])

    def test_one_action_safe_builder_matches_intent(self):
        self.assertEqual(BUILDER["chainId"], "84532")
        self.assertEqual(len(BUILDER["transactions"]), 1)
        tx = BUILDER["transactions"][0]
        self.assertEqual((tx["to"], tx["value"], tx["data"]),
                         (INTENT["timelockAddress"], "0", INTENT["timelockCall"]["data"]))
        self.assertEqual(tx["contractMethod"]["name"], "executeTransaction")
        self.assertEqual(tx["contractInputsValues"]["eta"], "1792584000")
        self.assertEqual(tx["contractInputsValues"]["data"], INTENT["operation"]["innerCalldata"])
        self.assertEqual(hashlib.sha256((ARTIFACTS / "c20_oracle_delay_fast_s2_safe_builder_v1.json")
                                        .read_bytes()).hexdigest(),
                         INTENT["safeTransactionBuilder"]["sha256"])

    def test_fork_result_and_maintenance_limits(self):
        rehearsal = REVIEW["forkRehearsal"]
        self.assertEqual(rehearsal["forgeTests"], {"passed": 7, "failed": 0, "skipped": 0})
        self.assertTrue(rehearsal["prematureExecutionReverted"] and rehearsal["operationConsumed"])
        self.assertTrue(rehearsal["replayRejected"] and rehearsal["D4D6MaintenancePreserved"])
        self.assertEqual(rehearsal["D5MaxOracleDelayAfter"], 600)
        self.assertFalse(rehearsal["realSafeSignaturesVerified"])
        self.assertEqual(REVIEW["prestate"]["D5MaxOracleDelay"], 0)
        self.assertEqual(REVIEW["prestate"]["D4FourFlags"], [True] * 4)
        self.assertTrue(REVIEW["prestate"]["D6Paused"])

    def test_c12_and_public_execution_remain_unauthorized(self):
        self.assertEqual(REVIEW["c12Gate"]["status"], "BLOCKED_WAITING_FOR_C20")
        self.assertTrue(REVIEW["c12Gate"]["queuedC20Insufficient"])
        self.assertFalse(REVIEW["publicExecutionAuthorized"])
        self.assertFalse(INTENT["authorityAndLimits"]["publicExecutionAuthorized"])
        self.assertEqual(REVIEW["gasPlanning"]["safeFullGasReview"], "PENDING_SAFE_UI_AFTER_ETA")
        self.assertTrue(INTENT["safeTransactionBuilder"]["builderDoesNotBindNonceGasOrRefund"])


if __name__ == "__main__":
    unittest.main()
