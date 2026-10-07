#!/usr/bin/env python3
"""Bind the reviewed local fixture to canonical migration evidence; no RPC or wallet."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "artifacts/perps_v2_replacement"

# Verified by the local PerpsV2ReplacementTopology deterministic-address test.
# These are TEST-FIXTURE addresses, never public deployment targets.
FIXTURE = {
    "PerpMarketRegistry": ("0x0b107A4a63194CC053F8773a139E9CcC5fc193F5", "0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5"),
    "FeesManagerV2": ("0xb875Dbccf7C849Fc687AFb35801047D51B806473", "0x732101d67fb112f6d3159f32852071bbf995f8bd1995335cf9a2b0f167d08726"),
    "CollateralSeizer": ("0x51fc2DB3130D4899c9bf2942A83b463fC5d23ef5", "0x6d199e027af598ee903513a1ab41e27e2937115c79b8ec85e386d739615befcb"),
    "PerpEngineV2": ("0x28E241e780f147c1cE5D3C5dAC4b05940Ca03245", "0x80b3316f0e0f2c058017320985d72eb6d63d9715220487f5679d1a2bb48c601c"),
    "PerpRiskModule": ("0xb0B10b88d9BB55Ea87e0251ad0d2B607Ec451a7E", "0x8c782209845865d35ecff80c00525ef3f0f335bea4e7b9846f01199c60fb5a2c"),
    "PerpMatchingEngineV2": ("0x0E2F3490a6880139E033D242B2878953Ed695Ce6", "0xd5d1474e3ab29c371cbeeffd0522a3c58f483a648b33edb9730d500b6f5e6c06"),
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    migration = json.loads((BASE / "migration_manifest.json").read_text())
    assert migration["chainId"] == 84532
    context = {
        "schema": "deopt.perps_v2_replacement.local_recovery_context.v1",
        "scope": "deterministic local Foundry fixture only; never public deployment identity",
        "chainId": 84532,
        "canonicalSnapshotHash": migration["engineSealSnapshotHash"],
        "fixtureTest": "test/perp/PerpsV2ReplacementTopology.t.sol:testDeterministicFixtureReplacementAddresses",
        "replacementFixture": {name: {"address": address, "runtimeKeccak256": code_hash}
                               for name, (address, code_hash) in FIXTURE.items()},
        "manifestSha256": {name: digest(BASE / f"{name}_manifest.json") for name in
                           ("source", "pmr_config", "authority", "migration")},
    }
    out = BASE / "recovery_context_manifest.json"
    out.write_text(json.dumps(context, indent=2, sort_keys=True) + "\n")
    print(out.relative_to(ROOT))
    print(digest(out))


if __name__ == "__main__":
    main()
