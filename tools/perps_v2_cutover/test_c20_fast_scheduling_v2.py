"""Offline consistency checks for the unsigned accelerated C20 S1 package."""
import hashlib
import json
from pathlib import Path
import unittest

from eth_abi import decode, encode
from eth_utils import keccak


ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts/perps_v2_replacement_deployment"
REVIEW = ARTIFACTS / "c20_oracle_delay_fast_scheduling_review_v2.json"
BUILDER = ARTIFACTS / "c20_oracle_delay_s1_fast_safe_builder_v2.json"
PREPARATION = ARTIFACTS / "c20_oracle_delay_preparation_v1.json"
PLAN = ARTIFACTS / "c20_oracle_delay_operation_plan_v1.json"
ZERO = "0x" + "00" * 20


class FastC20SchedulingPackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.review = json.loads(REVIEW.read_text())
        cls.builder = json.loads(BUILDER.read_text())
        cls.c20 = cls.review["C20"]

    def test_preserves_preparation_and_old_operation_identity(self):
        refs = self.review["repository"]
        self.assertEqual(hashlib.sha256(PREPARATION.read_bytes()).hexdigest(), refs["previousPreparationSha256"])
        self.assertEqual(hashlib.sha256(PLAN.read_bytes()).hexdigest(), refs["previousOperationPlanSha256"])
        self.assertNotEqual(self.c20["operationId"], refs["previousProposedOperationId"])
        self.assertEqual(refs["previousProposedEta"], 1792810800)

    def test_inner_calldata_is_exact_uint256_600(self):
        c = self.c20
        inner = "0x" + (keccak(text="setMaxOracleDelay(uint256)")[:4] + encode(["uint256"], [600])).hex()
        self.assertEqual(c["innerCalldata"], inner)
        self.assertEqual(c["innerCalldataBytes"], 36)
        self.assertEqual(c["innerCalldataKeccak256"], "0x" + keccak(bytes.fromhex(inner[2:])).hex())
        self.assertEqual(decode(["uint256"], bytes.fromhex(inner[10:])), (600,))

    def test_outer_calldata_has_one_canonical_timelock_operation(self):
        c = self.c20
        types = ["address", "uint256", "bytes", "uint256"]
        args = [c["target"], 0, bytes.fromhex(c["innerCalldata"][2:]), 1792584000]
        outer = "0x" + (keccak(text="queueTransaction(address,uint256,bytes,uint256)")[:4] + encode(types, args)).hex()
        self.assertEqual(c["queueCalldata"], outer)
        self.assertEqual(c["queueCalldataBytes"], 228)
        self.assertEqual(c["queueCalldataKeccak256"], "0x" + keccak(bytes.fromhex(outer[2:])).hex())
        self.assertEqual(encode(types, decode(types, bytes.fromhex(outer[10:]))), bytes.fromhex(outer[10:]))

    def test_operation_id_and_absent_queue(self):
        c = self.c20
        args = [c["target"], 0, bytes.fromhex(c["innerCalldata"][2:]), c["eta"]]
        op = "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"], args)).hex()
        self.assertEqual(op, c["operationId"])
        self.assertEqual(op, self.review["timelock"]["operationId"])
        self.assertEqual(self.review["timelock"]["operationState"], "ABSENT")
        self.assertTrue(self.review["timelock"]["operationIdLocalEqualsOnChain"])

    def test_safe_eip712_hash_binds_zero_envelope_and_nonce(self):
        r = self.review
        f = r["safe"]["envelope"]
        self.assertEqual(f["nonce"], 23)
        self.assertEqual([f[x] for x in ("safeTxGas", "baseGas", "gasPrice")], [0, 0, 0])
        self.assertEqual([f[x] for x in ("gasToken", "refundReceiver")], [ZERO, ZERO])
        domain = keccak(encode(["bytes32", "uint256", "address"], [
            keccak(text="EIP712Domain(uint256 chainId,address verifyingContract)"), 84532, r["safe"]["address"]]))
        self.assertEqual("0x" + domain.hex(), r["safe"]["safeDomainSeparator"])
        struct = keccak(encode(
            ["bytes32", "address", "uint256", "bytes32", "uint8", "uint256", "uint256", "uint256", "address", "address", "uint256"],
            [keccak(text="SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"),
             f["to"], f["value"], keccak(bytes.fromhex(f["data"][2:])), f["operation"], f["safeTxGas"],
             f["baseGas"], f["gasPrice"], f["gasToken"], f["refundReceiver"], f["nonce"]]))
        self.assertEqual("0x" + keccak(b"\x19\x01" + domain + struct).hex(), r["safe"]["safeTxHashConditional"])
        self.assertTrue(r["safe"]["safeTxHashLocalEqualsOnChainGetter"])

    def test_builder_is_one_exact_unsigned_action(self):
        r, b = self.review, self.builder
        self.assertEqual(b["version"], "1.0")
        self.assertEqual(b["chainId"], "84532")
        self.assertEqual(len(b["transactions"]), 1)
        tx = b["transactions"][0]
        self.assertEqual(tx["to"].lower(), r["timelock"]["address"].lower())
        self.assertEqual(tx["value"], "0")
        self.assertEqual(tx["data"], r["C20"]["queueCalldata"])
        self.assertEqual(tx["contractMethod"]["name"], "queueTransaction")
        self.assertEqual(tx["contractInputsValues"]["eta"], str(r["C20"]["eta"]))
        self.assertEqual(tx["contractInputsValues"]["data"], r["C20"]["innerCalldata"])
        self.assertEqual(hashlib.sha256(BUILDER.read_bytes()).hexdigest(), r["builder"]["sha256"])

    def test_accelerated_deadline_and_hard_c12_gate(self):
        r, c = self.review, self.c20
        self.assertEqual(c["eta"] - r["timelock"]["minDelaySeconds"] - 3600, 1792494000)
        self.assertEqual(c["bufferedSchedulingCutoff"], 1792494000)
        self.assertGreater(c["secondsToBufferedCutoffAtOperationSnapshot"], 0)
        self.assertEqual(r["c12Gate"]["status"], "BLOCKED_UNTIL_CANONICAL_C20_S2_AND_FRESH_D5_600_READBACK")
        self.assertTrue(r["c12Gate"]["queueOnlyInsufficient"])

    def test_maintenance_preserved_and_no_public_authorization(self):
        r = self.review
        self.assertEqual(r["maintenanceAndBoundedEconomy"]["D4Flags"], [True] * 4)
        self.assertTrue(r["maintenanceAndBoundedEconomy"]["D6Paused"])
        self.assertEqual(r["maintenanceAndBoundedEconomy"]["D5Delay"], 0)
        for key in ("agentPublicSigning", "agentPublicBroadcast", "agentSafeProposal", "C20SchedulingPubliclyCompleted", "C20Executed", "C12Authorized", "migrationReplayAuthorized", "publicTradingAuthorized"):
            self.assertFalse(r[key], key)


if __name__ == "__main__":
    unittest.main()
