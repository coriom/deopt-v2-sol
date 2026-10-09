#!/usr/bin/env python3
"""Validate the offline, unsigned D4 final-review package without RPC access."""

import hashlib
import json
from pathlib import Path

from verify_d4_preparation import ROOT, cast, main as verify_preparation


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    verify_preparation()
    directory = ROOT / "artifacts/perps_v2_replacement_deployment"
    preparation_path = directory / "d4_engine_preparation.json"
    review_path = directory / "d4_engine_final_review.json"
    intent_path = directory / "d4_engine_unsigned_intent.json"
    preparation = json.loads(preparation_path.read_text())
    review = json.loads(review_path.read_text())
    intent = json.loads(intent_path.read_text())

    assert review["status"] == "PASS_READ_ONLY"
    assert review["preparationSha256"] == digest(preparation_path.read_bytes())
    assert review["frozenSourceCommit"] == preparation["sourceCommit"]
    assert review["startingRepositoryCommit"] == "d2d6284797468ea201de9ad500525340bc9a1327"
    assert review["unsignedIntent"]["sha256"] == digest(intent_path.read_bytes())
    assert review["chainId"] == intent["chainId"] == 84532
    assert review["predictedAddress"].lower() == intent["expectedContractAddress"].lower()
    assert review["predictedAddressEmpty"] and review["deployer"]["codeEmpty"]
    assert review["deployer"]["confirmedNonce"] == review["deployer"]["pendingNonce"] == intent["nonce"] == 3
    assert intent["transactionType"] == 2 and intent["to"] is None
    assert intent["valueWei"] == "0" and intent["accessList"] == []
    assert intent["authorization"] == "NONE_FINAL_READ_ONLY_REVIEW"
    assert intent["from"].lower() == review["deployer"]["address"].lower()
    assert intent["data"] == preparation["creationTransactionData"]
    creation = bytes.fromhex(intent["data"][2:])
    assert len(creation) == review["creationData"]["length"] == 25_431
    assert digest(creation) == review["creationData"]["sha256"]
    assert cast("keccak", intent["data"]).lower() == review["creationData"]["keccak256"]
    assert review["creationBytecode"]["keccak256"] == preparation["build"]["linkedCreationBytecode"]["keccak256"]
    assert review["expectedPublicRuntimeHash"] == preparation["expectedPublicRuntimeHash"]
    assert review["localCreationCallRuntimeHash"] == review["expectedPublicRuntimeHash"]
    assert review["build"]["libraryLinks"] == preparation["build"]["libraryLinks"]
    assert review["constructorArgs"] == preparation["constructorArgs"]
    assert review["constructorArgsEncoded"] == preparation["constructorArgsEncoded"]
    assert review["initialAuthority"]["owner"].lower() == review["constructorArgs"][0].lower()
    assert review["initialGuardianHandoff"]["initialGuardian"].lower() == review["constructorArgs"][0].lower()
    assert review["initialGuardianHandoff"]["guardianPolicy"] == "PAUSE_ONLY"
    assert review["initialMigration"]["state"] == "OPEN"
    assert review["initialMigration"]["snapshotHash"] == "0x" + "0" * 64
    assert not any(review["initialEmergency"].values())
    assert all(not value["publicReachable"] for value in review["operationalReachability"].values())
    assert review["operationalReachability"]["migration"]["governanceSeedReachable"]
    for stage in ("d1", "d2", "d3"):
        assert review["canonicalStages"][stage]["receiptCanonicalVerified"]
        assert review["canonicalStages"][stage]["stateCheck"] == "PASS"
    fee = review["feeReview"]
    assert fee["gasEstimate"] <= intent["gasLimit"] == fee["proposedGasLimit"]
    assert intent["maxFeePerGasWei"] == fee["proposedMaxFeePerGasWei"]
    assert intent["maxPriorityFeePerGasWei"] == fee["proposedMaxPriorityFeePerGasWei"]
    assert int(fee["maxExecutionGasCostWei"]) == intent["gasLimit"] * intent["maxFeePerGasWei"]
    assert int(fee["maxTotalPlanningCostWei"]) == int(fee["maxExecutionGasCostWei"]) + int(fee["l1FeePlanningAllowanceWei"])
    assert int(fee["projectedBalanceAfterMaxPlanningCostWei"]) == int(review["deployer"]["balanceWei"]) - int(fee["maxTotalPlanningCostWei"])
    assert fee["balanceSufficient"] and int(fee["projectedBalanceAfterMaxPlanningCostWei"]) > 0
    assert not fee["feeEnvelopeAuthorized"]
    assert review["focusedTests"]["failed"] == review["focusedTests"]["skipped"] == 0
    assert review["focusedTests"]["passed"] == 56
    assert review["publicTransactionsSigned"] == review["publicTransactionsBroadcast"] == 0
    assert not any(review[key] for key in (
        "d5PreparationAuthorized", "timelockOperationAuthorized", "safeTransactionAuthorized",
        "migrationReplayAuthorized", "publicTradingAuthorized"
    ))
    print("D4 final review: offline intent, costs, postflight bindings, and no-authorization flags PASS")


if __name__ == "__main__":
    main()
