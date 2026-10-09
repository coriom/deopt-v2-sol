#!/usr/bin/env python3
"""Validate the offline unsigned D5 review and its governance-order blocker."""

import hashlib
import json

from verify_d5_preparation import ROOT, cast, main as verify_preparation


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    verify_preparation()
    directory = ROOT / "artifacts/perps_v2_replacement_deployment"
    prep_path = directory / "d5_risk_preparation.json"
    review_path = directory / "d5_risk_final_review.json"
    intent_path = directory / "d5_risk_unsigned_intent.json"
    manifest_path = directory / "timelock_configuration_manifest.json"
    prep = json.loads(prep_path.read_text())
    review = json.loads(review_path.read_text())
    intent = json.loads(intent_path.read_text())
    manifest = json.loads(manifest_path.read_text())

    assert review["status"] == "BLOCKED_GOVERNANCE_SEQUENCE"
    assert review["preparationSha256"] == digest(prep_path.read_bytes())
    assert review["governanceManifestSha256"] == digest(manifest_path.read_bytes())
    assert review["startingRepositoryCommit"] == "0c23944053e4994e25cf979883c7d9ec311e35b9"
    assert review["unsignedIntent"]["sha256"] == digest(intent_path.read_bytes())
    assert review["chainId"] == intent["chainId"] == 84532
    assert review["predictedAddress"].lower() == intent["expectedContractAddress"].lower()
    assert review["predictedAddressEmpty"] and review["deployer"]["codeEmpty"]
    assert review["deployer"]["confirmedNonce"] == review["deployer"]["pendingNonce"] == intent["nonce"] == 4
    assert intent["transactionType"] == 2 and intent["to"] is None
    assert intent["valueWei"] == "0" and intent["accessList"] == []
    assert intent["authorization"] == "NONE_BLOCKED_FINAL_READ_ONLY_REVIEW"
    assert intent["from"].lower() == review["deployer"]["address"].lower()
    assert intent["data"] == prep["creationData"]["hex"]
    creation = bytes.fromhex(intent["data"][2:])
    assert len(creation) == review["creationData"]["lengthBytes"] == 10_697
    assert digest(creation) == review["creationData"]["sha256"]
    assert cast("keccak", intent["data"]).lower() == review["creationData"]["keccak256"]
    assert review["creationBytecodeKeccak256"] == prep["build"]["creationBytecodeKeccak256"]
    assert review["initcodeKeccak256"] == prep["initcodeKeccak256"]
    assert review["expectedPublicRuntimeHash"] == prep["expectedPublicRuntimeKeccak256"]
    assert review["localRuntimeHash"] == review["expectedPublicRuntimeHash"]
    assert review["constructorArguments"] == prep["constructorArguments"]
    assert review["constructorAbiEncoding"] == prep["constructorAbiEncoding"]
    assert review["initialAuthority"]["owner"].lower() == prep["constructorArguments"]["owner"].lower()
    assert review["initialAuthority"]["guardian"] == "0x" + "0" * 40
    assert review["initialAuthority"]["guardianPolicy"] == "PAUSE_ONLY"
    assert review["oracleFreshness"]["initialMaxDelaySeconds"] == 0
    assert review["oracleFreshness"]["operationalMaxDelaySeconds"] == 600
    assert review["oracleFreshness"]["future600RequiredBeforeD4Wiring"] is True
    assert review["oracleFreshness"]["policyCheck"] == "FAIL_GOVERNANCE_SEQUENCE_NOT_ENFORCED"
    assert review["asymmetricWiring"]["d4ToD5"] == "0x" + "0" * 40
    assert review["asymmetricWiring"]["d5ToD4"].lower() == prep["constructorArguments"]["engine"].lower()
    assert all(stage["freshStateCheck"] == "PASS" for stage in review["canonicalStages"].values())
    oracle_manifest = json.loads((ROOT / "artifacts/perps_v2_replacement/pmr_config_manifest.json").read_text())
    assert review["oracleFeedReadback"]["globalMaxDelaySeconds"] == 1500
    assert review["oracleFeedReadback"]["pinnedBlockVerification"] == "PASS"
    for market in (1, 2):
        assert review["oracleFeedReadback"][f"market{market}"] == oracle_manifest["sharedOracleDependencyReadback"][f"market{market}Feed"]

    actions = manifest["actions"]
    indices = {action["stageId"]: i for i, action in enumerate(actions)}
    c12 = actions[indices["C12"]]
    c20 = actions[indices["C20"]]
    assert indices["C12"] < indices["C20"]
    assert c12["signature"] == "setRiskModule(address)"
    assert c20["signature"] == "setMaxOracleDelay(uint256)" and c20["decodedArgs"] == [600]
    assert "C20" not in c12["prerequisite"] and c12["canShareQueueDelayWindow"]
    assert review["governanceSequenceReview"]["committedManifestEnforcesRequiredOrder"] is False

    fee = review["feeReview"]
    assert fee["freshGasEstimate"] <= intent["gasLimit"] == fee["proposedGasLimit"]
    assert intent["maxFeePerGasWei"] == fee["proposedMaxFeePerGasWei"]
    assert intent["maxPriorityFeePerGasWei"] == fee["proposedMaxPriorityFeePerGasWei"]
    assert int(fee["maxExecutionGasCostWei"]) == intent["gasLimit"] * intent["maxFeePerGasWei"]
    assert int(fee["maxTotalPlanningCostWei"]) == int(fee["maxExecutionGasCostWei"]) + int(fee["l1FeePlanningAllowanceWei"])
    assert int(fee["projectedBalanceAfterMaxPlanningCostWei"]) == int(fee["deployerBalanceWei"]) - int(fee["maxTotalPlanningCostWei"])
    assert fee["balanceSufficient"] and not fee["gasAndFeeEnvelopeAuthorized"]
    assert review["focusedTests"]["passed"] == 22
    assert review["focusedTests"]["failed"] == review["focusedTests"]["skipped"] == 0
    assert review["publicTransactionsSigned"] == review["publicTransactionsBroadcast"] == 0
    assert not any(review[key] for key in (
        "d5ExecutionAuthorized", "d6PreparationAuthorized", "timelockOperationAuthorized",
        "safeTransactionAuthorized", "migrationReplayAuthorized", "publicTradingAuthorized",
        "readyForSeparateD5ExecutionAuthorization",
    ))
    print("D5 final review: unsigned intent, costs, postflight, and governance-order blocker PASS")


if __name__ == "__main__":
    main()
