"""Offline checks for the signer-bound, non-executable D1 package."""

import hashlib
import json
import subprocess
import unittest

from eth_abi import encode
from eth_utils import keccak

from bind_replacement_deployer import ADDRESS, ORIGINAL_SHA256, OUT, ROOT, TIMELOCK, create_address


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DeployerBindingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = json.loads((OUT / "d1_pmr_deployment_review.json").read_text())
        cls.bound = json.loads((OUT / "d1_pmr_deployer_bound_review.json").read_text())
        cls.package = json.loads((OUT / "deployment_package_signer_bound.json").read_text())

    def test_original_package_preserved_and_bound_hash(self):
        self.assertEqual(digest(OUT / "deployment_package.json"), ORIGINAL_SHA256)
        self.assertEqual(self.package["originalPackageSha256"], ORIGINAL_SHA256)
        self.assertEqual(self.bound["originalReviewSha256"], digest(OUT / "d1_pmr_deployment_review.json"))
        self.assertEqual(self.package["d1ReviewSha256"], digest(OUT / "d1_pmr_deployer_bound_review.json"))
        for field in self.original:
            if field not in ("expectedPublicAddress", "predictedAddressCodeCheck", "signerRequirements"):
                self.assertEqual(self.bound[field], self.original[field], field)

    def test_create_address_against_independent_cast(self):
        nonce = self.package["confirmedNonce"]
        self.assertEqual(nonce, self.package["pendingNonce"])
        local = create_address(ADDRESS, nonce)
        cast = subprocess.check_output(["cast", "compute-address", "--nonce", str(nonce), ADDRESS], text=True)
        self.assertEqual(local.lower(), cast.split(":", 1)[1].strip().lower())
        self.assertEqual(local, self.package["d1PredictedAddress"])
        self.assertEqual(self.bound["expectedPublicAddress"], local)
        self.assertEqual(self.package["d1PredictedCode"], "0x")

    def test_constructor_runtime_and_initial_authority(self):
        d1 = self.bound
        self.assertEqual(d1["constructorArgs"], [TIMELOCK])
        self.assertEqual(d1["expectedOwner"].lower(), TIMELOCK.lower())
        self.assertEqual(d1["expectedPendingOwner"], "0x" + "00" * 20)
        self.assertEqual(d1["constructorArgsEncoded"], "0x" + encode(["address"], [TIMELOCK]).hex())
        creation = bytes.fromhex(d1["creationTransactionData"][2:])
        self.assertEqual(d1["creationTransactionDataKeccak256"], "0x" + keccak(creation).hex())
        self.assertEqual(d1["linkedCreationBytecodeSha256"],
                         hashlib.sha256(creation[:-32]).hexdigest())
        artifact = json.loads((ROOT / d1["artifactPath"]).read_text())
        runtime = bytes.fromhex(artifact["deployedBytecode"]["object"][2:])
        self.assertEqual(d1["expectedRuntimeHash"], "0x" + keccak(runtime).hex())
        self.assertEqual(d1["expectedRuntimeHash"],
                         "0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5")
        self.assertEqual(d1["initialState"], {"configPaused": False, "creationPaused": False,
                                               "guardian": "0x" + "00" * 20,
                                               "nextMarketId": 1, "paused": False})
        self.assertNotEqual(d1["expectedOwner"].lower(), ADDRESS.lower())
        self.assertTrue(d1["noBroadcastAuthorization"])

    def test_no_privileged_role_or_authorization(self):
        p = self.package
        self.assertEqual(p["deployerAddress"], ADDRESS)
        self.assertEqual(p["deployerCode"], "0x")
        self.assertEqual(p["authorityExclusions"]["checkedRoleResult"],
                         "NO_INTENDED_PROTOCOL_AUTHORITY_IN_STATED_SCOPE")
        a = p["authorityExclusions"]
        for k in ("vaultAuthorizedEngine", "vaultEffectiveEngine", "insuranceBackstopCaller",
                  "pmeExecutor", "timelockProposer", "timelockExecutor"):
            self.assertIs(a[k], False, k)
        self.assertNotIn(ADDRESS.lower(), [x.lower() for x in a["safeOwners"]])
        self.assertFalse(p["publicBroadcastAuthorized"])
        self.assertFalse(p["fundingAuthorized"])
        self.assertEqual(p["d6ExpectedRuntimeHash"], "CONDITIONAL")
        self.assertEqual(p["d2ThroughD6"], "CONDITIONAL_ON_PRECEDING_CANONICAL_RECEIPTS")

    def test_planning_math_and_unfunded_result(self):
        p = self.package["planning"]
        gas = p["gasEstimates"]
        self.assertEqual(p["totalGasEstimate"], sum(gas))
        self.assertEqual(p["d1GasWithMargin"], (gas[0] * 125 + 99) // 100)
        self.assertEqual(p["fullGasWithMargin"], (sum(gas) * 125 + 99) // 100)
        self.assertEqual(p["d1RequirementWei"], p["d1GasWithMargin"] * p["planningMaxFeePerGasWei"] + p["planningL1ReserveWei"])
        self.assertEqual(p["fullSequenceRequirementWei"], p["fullGasWithMargin"] * p["planningMaxFeePerGasWei"] + p["planningL1ReserveWei"])
        self.assertFalse(p["feeEnvelopeAuthorized"])
        self.assertFalse(p["fundedForD1"])
        self.assertFalse(p["fundedForFullSequence"])


if __name__ == "__main__":
    unittest.main()
