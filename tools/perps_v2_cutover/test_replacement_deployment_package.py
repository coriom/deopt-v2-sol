"""Offline integrity checks for the conditional replacement deployment package."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import encode
from eth_utils import keccak

from build_replacement_deployment_package import EXPECTED, FILES, FROZEN, OUT, ROOT, render_bytecode


class PackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.package = json.loads((OUT / "deployment_package.json").read_text())
        cls.build = json.loads((OUT / "build_manifest.json").read_text())

    def test_frozen_source_and_manifest_hashes(self):
        for name, expected in zip(FILES, EXPECTED):
            self.assertEqual(hashlib.sha256((FROZEN / f"{name}_manifest.json").read_bytes()).hexdigest(), expected)
        self.assertEqual(len(self.build["contracts"]), 6)
        for entry in self.build["contracts"]:
            for dependency in entry["sourceDependencies"]:
                self.assertEqual("0x" + hashlib.sha256((ROOT / dependency["path"]).read_bytes()).hexdigest(),
                                 dependency["sha256"])

    def test_creation_bytes_and_constructor_encoding(self):
        for entry in self.build["contracts"]:
            artifact = json.loads((ROOT / entry["artifactPath"]).read_text())
            creation = render_bytecode(artifact["bytecode"])
            self.assertEqual(entry["linkedCreationBytecode"], "0x" + creation.hex())
            self.assertEqual(entry["linkedCreationBytecodeSha256"], hashlib.sha256(creation).hexdigest())
            self.assertEqual(entry["linkedCreationBytecodeKeccak256"], "0x" + keccak(creation).hex())
            if entry["creationTransactionData"]:
                args = encode(entry["constructorTypes"], entry["constructorArgs"])
                self.assertEqual(entry["constructorArgsEncoded"], "0x" + args.hex())
                self.assertEqual(entry["creationTransactionData"], "0x" + (creation + args).hex())
                self.assertEqual(entry["creationTransactionDataKeccak256"], "0x" + keccak(creation + args).hex())
            else:
                self.assertIn(entry["stage"], ("D4", "D5", "D6"))
                self.assertIsNone(entry["creationTransactionDataKeccak256"])

    def test_local_rehearsal_runtime_identity(self):
        rehearsal = json.loads((OUT / "local_rehearsal.json").read_text())
        for entry, observed in zip(self.build["contracts"], rehearsal["stages"]):
            self.assertEqual(entry["stage"], observed["stage"])
            self.assertEqual(entry["localFixtureRuntimeHash"], observed["runtimeKeccak256"])
            if entry["runtimeHashKind"] == "CONSTRUCTOR_INDEPENDENT":
                self.assertEqual(entry["expectedRuntimeHash"], observed["runtimeKeccak256"])
            else:
                self.assertIsNone(entry["expectedRuntimeHash"])

    def test_timelock_calldata_and_conditional_fields(self):
        actions = json.loads((OUT / "timelock_configuration_manifest.json").read_text())["actions"]
        self.assertEqual(len(actions), 26)
        self.assertEqual([int(x["stageId"][1:]) for x in actions], list(range(1, 27)))
        for action in actions:
            self.assertEqual(action["valueWei"], 0)
            self.assertIsNone(action["operationId"])
            self.assertIsNone(action["timelockEta"])
            if action["calldata"]:
                self.assertEqual(bytes.fromhex(action["calldata"][2:10]), keccak(text=action["signature"])[:4])
            else:
                self.assertEqual(action["calldataStatus"], "CONDITIONAL_ON_CANONICAL_ADDRESS")

    def test_package_sha_binding_and_no_authorization(self):
        for name, expected in self.package["artifactSha256"].items():
            self.assertEqual(hashlib.sha256((OUT / name).read_bytes()).hexdigest(), expected, name)
        self.assertEqual(self.package["deploymentSignerStatus"], "NO_SIGNER_DESIGNATED")
        self.assertEqual(self.package["deploymentAddressMode"], "DIRECT_CREATE")
        self.assertFalse(self.package["publicBroadcastAuthorized"])
        self.assertFalse(json.loads((OUT / "first_trade_guard_binding.json").read_text())["armed"])


if __name__ == "__main__":
    unittest.main()
