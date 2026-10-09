#!/usr/bin/env python3
"""Offline integrity of the versioned governance fix and preserved D5 evidence."""
import hashlib
import json
from pathlib import Path
import subprocess

from build_governance_c12_c20_v2 import ROOT, OLD, NEW, OLD_SHA, build
from c12_c20_preflight import C12_DATA, C20_DATA, D4, D5, validate_manifest
from verify_d5_final_review import main as verify_blocked_review

DIR = ROOT / "artifacts/perps_v2_replacement_deployment"
ARTIFACT = DIR / "governance_c12_c20_order_fix_v1.json"
FROZEN = "25c36670883604c1ef5229642ee6548aea6796c3"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    assert sha(OLD) == OLD_SHA
    assert json.loads(NEW.read_text()) == build()
    new_sha = validate_manifest()
    report = json.loads(ARTIFACT.read_text())
    assert report["historicalManifest"]["sha256"] == OLD_SHA
    assert report["correctedManifest"]["sha256"] == new_sha
    assert report["C12"]["target"].lower() == D4.lower()
    assert report["C12"]["calldata"].lower() == C12_DATA
    assert report["C12"]["dependsOn"] == ["C20_EXECUTED_AND_READ_BACK"]
    assert report["C20"]["target"].lower() == D5.lower()
    assert report["C20"]["calldata"].lower() == C20_DATA
    assert report["C20"]["requiredValueSeconds"] == 600
    assert report["d5FrozenDeployment"]["deploymentStatus"] == "NOT_DEPLOYED"
    assert report["liveReadOnlyObservation"]["d5CodeEmpty"]
    assert report["frozenSourceCommit"] == FROZEN
    changed = subprocess.check_output(["git", "diff", "--name-only", FROZEN, "HEAD", "--", "src"],
                                      cwd=ROOT, text=True)
    assert changed.strip() == "", "frozen Solidity source changed"
    assert not subprocess.check_output(["git", "diff", "--name-only", "--", "src"],
                                       cwd=ROOT, text=True).strip()
    for name, digest in report["preservedHistoricalEvidence"].items():
        assert sha(DIR / name) == digest, name
    assert report["preservedHistoricalEvidence"]["d5_risk_final_review.json"] == \
        "6e2851fb3890478eef32a29d4bafbcb225d5d46f3302970a7a327453d2cbf156"
    assert report["preservedHistoricalEvidence"]["d5_risk_unsigned_intent.json"] == \
        "3da6a70882b7472c0c999f1c7715630813a5e663d8fb2ef74294904dc42e856a"
    assert report["preservedHistoricalEvidence"]["d5_risk_preparation.json"] == \
        "69df1563e3ca6c0a2d10cd34aefd7b9a96d1bfa96511b0f17120f944a8948351"
    assert all(not enabled for enabled in report["authorization"].values())
    verify_blocked_review()
    print("governance correction: manifest, preserved D5 hashes, source freeze and blocked history PASS")
    print("correction artifact sha256", sha(ARTIFACT))


if __name__ == "__main__":
    main()
