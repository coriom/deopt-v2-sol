#!/usr/bin/env python3
"""Reproduce the non-secret D4 creation package from frozen local artifacts."""

import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "artifacts/perps_v2_replacement_deployment/d4_engine_preparation.json"
BUILD = ROOT / "artifacts/perps_v2_replacement_deployment/build_manifest.json"
TEMPLATE = ROOT / "artifacts/perps_v2_replacement_deployment/d4_engine_deployment_template.json"
ARTIFACT = ROOT / "out/PerpEngineV2.sol/PerpEngineV2.json"


def cast(*args: str) -> str:
    return subprocess.check_output(["cast", *args], text=True).strip()


def keccak(data: bytes) -> str:
    return cast("keccak", "0x" + data.hex()).lower()


def linked(obj: dict, libraries: dict) -> bytes:
    text = obj["object"][2:]
    for entries in obj["linkReferences"].values():
        for name, refs in entries.items():
            address = libraries[name][2:].lower()
            for ref in refs:
                assert ref["length"] == 20
                start = ref["start"] * 2
                end = start + 40
                assert text[start:end].startswith("__$")
                text = text[:start] + address + text[end:]
    assert "__" not in text
    return bytes.fromhex(text)


def main() -> None:
    package = json.loads(PACKAGE.read_text())
    build = json.loads(BUILD.read_text())
    template = json.loads(TEMPLATE.read_text())
    artifact = json.loads(ARTIFACT.read_text())
    frozen = build["contracts"][3]
    assert package["sourceCommit"] == build["sourceCommit"]
    assert package["startingRepositoryCommit"] == "804ca6a539f527e4dec59b7204737db88e4b57c5"
    assert frozen["contract"] == "PerpEngineV2"
    assert package["build"]["compilerVersion"] == frozen["compilerVersion"]
    assert package["build"]["optimizer"] == frozen["optimizer"]
    assert package["build"]["viaIR"] == frozen["viaIR"]
    assert package["build"]["evmVersion"] == frozen["evmVersion"]
    assert package["build"]["metadataSettings"] == frozen["metadataSettings"]
    assert package["build"]["sourceDependencies"] == frozen["sourceDependencies"]
    for source in frozen["sourceDependencies"]:
        actual = hashlib.sha256((ROOT / source["path"]).read_bytes()).hexdigest()
        assert actual == source["sha256"][2:], source["path"]

    assert artifact["metadata"]["compiler"]["version"] == frozen["compilerVersion"]
    assert artifact["bytecode"]["linkReferences"] == frozen["creationLinkReferences"]
    assert artifact["deployedBytecode"]["linkReferences"] == frozen["runtimeLinkReferences"]
    assert artifact["deployedBytecode"].get("immutableReferences") in (None, {})
    assert package["build"]["runtimeImmutableReferences"] == {}

    creation = linked(artifact["bytecode"], build["libraries"])
    runtime = linked(artifact["deployedBytecode"], build["libraries"])
    assert keccak(creation) == frozen["linkedCreationBytecodeKeccak256"]
    assert hashlib.sha256(creation).hexdigest() == frozen["linkedCreationBytecodeSha256"]
    assert keccak(runtime) == frozen["linkedRuntimeTemplateKeccak256"]
    assert package["expectedPublicRuntimeHash"] == template["localFixtureRuntimeHash"]
    assert package["expectedPublicRuntimeHash"] == keccak(runtime)

    args = package["constructorArgs"]
    assert args == [
        "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588",
        "0x6B3D846536116082dC4E7227861C341Bb85Ee963",
        "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3",
        "0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581",
    ]
    assert [item["type"] for item in frozen["constructorAbi"]["inputs"]] == ["address"] * 4
    encoded = b"".join(bytes.fromhex(addr[2:]).rjust(32, b"\0") for addr in args)
    assert package["constructorArgsEncoded"] == "0x" + encoded.hex()
    initcode = creation + encoded
    assert package["creationTransactionData"] == "0x" + initcode.hex()
    assert package["creationData"] == {
        "length": len(initcode),
        "keccak256": keccak(initcode),
        "sha256": hashlib.sha256(initcode).hexdigest(),
    }
    computed = cast("compute-address", "--nonce", "3", package["deployer"]).split()[-1]
    assert computed.lower() == package["predictedAddress"].lower()
    assert package["deployerConfirmedNonce"] == package["deployerPendingNonce"] == 3
    assert package["publicBroadcastAuthorized"] is False
    assert package["d5PreparationAuthorized"] is False
    print("D4 preparation package: local source, links, constructor, initcode, runtime template, and CREATE address PASS")


if __name__ == "__main__":
    main()
