#!/usr/bin/env python3
"""Reproduce the non-secret D5 package from frozen local source and build."""

import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "artifacts/perps_v2_replacement_deployment/d5_risk_preparation.json"
BUILD = ROOT / "artifacts/perps_v2_replacement_deployment/build_manifest.json"
TEMPLATE = ROOT / "artifacts/perps_v2_replacement_deployment/d5_risk_deployment_template.json"
COMPILED = ROOT / "out/PerpRiskModule.sol/PerpRiskModule.json"


def cast(*args: str) -> str:
    return subprocess.check_output(["cast", *args], text=True).strip()


def keccak(data: bytes) -> str:
    return cast("keccak", "0x" + data.hex()).lower()


def main() -> None:
    package = json.loads(PACKAGE.read_text())
    build = json.loads(BUILD.read_text())
    template = json.loads(TEMPLATE.read_text())
    compiled = json.loads(COMPILED.read_text())
    frozen = next(item for item in build["contracts"] if item["contract"] == "PerpRiskModule")

    assert package["frozenSourceCommit"] == build["sourceCommit"]
    assert package["startingRepositoryCommit"] == "df6c41f02280ec7eb621487da218f9de727b199a"
    assert not subprocess.check_output(
        ["git", "-C", str(ROOT), "diff", "--name-only", build["sourceCommit"], "HEAD", "--", "src"],
        text=True,
    ).strip()
    for key in ("compilerVersion", "optimizer", "viaIR", "evmVersion", "metadataSettings"):
        assert package["build"][key] == frozen[key] == template[key]
    assert compiled["metadata"]["compiler"]["version"] == frozen["compilerVersion"]
    assert frozen["constructorAbi"] == package["constructorAbi"] == template["constructorAbi"]
    for source in frozen["sourceDependencies"]:
        actual = hashlib.sha256((ROOT / source["path"]).read_bytes()).hexdigest()
        assert actual == source["sha256"][2:]
        assert package["build"]["sourceDependencySha256"][source["path"]] == source["sha256"]

    assert compiled["bytecode"]["linkReferences"] == {}
    assert compiled["deployedBytecode"]["linkReferences"] == {}
    assert compiled["deployedBytecode"].get("immutableReferences") in (None, {})
    creation = bytes.fromhex(compiled["bytecode"]["object"][2:])
    runtime = bytes.fromhex(compiled["deployedBytecode"]["object"][2:])
    assert keccak(creation) == package["build"]["creationBytecodeKeccak256"] == template["linkedCreationBytecodeKeccak256"]
    assert hashlib.sha256(creation).hexdigest() == package["build"]["creationBytecodeSha256"]
    assert keccak(runtime) == package["expectedPublicRuntimeKeccak256"] == template["expectedRuntimeHash"]
    assert package["runtimeMatchesHistoricalFixture"] is True

    args = package["constructorArguments"]
    assert package["constructorArgumentOrder"] == ["owner", "vault", "engine", "oracle", "baseToken"]
    assert [args[key].lower() for key in package["constructorArgumentOrder"]] == [
        "0xa67f8e8e673ce4bb2fb563b0e6e9fa8f70e3b588",
        "0x00340c360353a5ab784c5bc5c44322a6af0625d3",
        "0xd0901de8f6de72aecc716ca1465c4cf58a0b99fb",
        "0xb416406f200b2ef3d7a86a5d5877ed41d9b1a581",
        "0x6eae407f5640b006fac9965182e238582a3b412e",
    ]
    encoded = b"".join(bytes.fromhex(args[key][2:]).rjust(32, b"\0") for key in package["constructorArgumentOrder"])
    assert package["constructorAbiEncoding"] == "0x" + encoded.hex()
    initcode = creation + encoded
    assert package["creationData"]["hex"] == "0x" + initcode.hex()
    assert package["creationData"]["lengthBytes"] == len(initcode)
    assert package["creationData"]["keccak256"].lower() == keccak(initcode)
    assert package["creationData"]["sha256"] == hashlib.sha256(initcode).hexdigest()
    assert package["initcodeKeccak256"].lower() == keccak(initcode)
    computed = cast("compute-address", "--nonce", "4", package["deployer"]["address"]).split()[-1]
    assert computed.lower() == package["predictedAddress"].lower()

    assert package["deployer"]["confirmedNonce"] == package["deployer"]["pendingNonce"] == 4
    assert package["initialRiskConfiguration"]["maxOracleDelaySeconds"] == 0
    assert package["oracleFreshness"]["configurationRequiredBeforeRiskWiringOrOperationalUse"] is True
    assert package["reciprocalWiring"]["completeAtDeployment"] is False
    assert package["publicBroadcastAuthorized"] is False
    assert package["timelockOperationAuthorized"] is False
    assert package["d6PreparationAuthorized"] is False
    print("D5 preparation package: frozen source, constructor, initcode, runtime, CREATE address, and safety gates PASS")


if __name__ == "__main__":
    main()
