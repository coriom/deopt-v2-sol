#!/usr/bin/env python3
"""Freeze local replacement artifacts after `forge build -j 1`.

No network, keys, signing or deployment. Linked Engine bytecode remains an
unlinked template; its deployable hash must be resolved in a later package.
"""

import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "artifacts/perps_v2_replacement/source_manifest.json"
NAMES = (
    "PerpMarketRegistry",
    "FeesManagerV2",
    "CollateralSeizer",
    "PerpEngineV2",
    "PerpRiskModule",
    "PerpMatchingEngineV2",
)


def sha(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def evm_hash(code: str) -> str:
    return subprocess.check_output(["cast", "keccak", code], text=True).strip()


def main() -> None:
    records = []
    for name in NAMES:
        artifact = ROOT / f"out/{name}.sol/{name}.json"
        data = json.loads(artifact.read_text())
        metadata = data["metadata"]
        settings = metadata["settings"]
        target = settings["compilationTarget"]
        if len(target) != 1 or list(target.values()) != [name]:
            raise ValueError(f"unexpected target: {name}")
        source = next(iter(target))
        dependencies = []
        for path in sorted(metadata["sources"]):
            file = ROOT / path
            if not file.is_file():
                raise FileNotFoundError(file)
            dependencies.append({"path": path, "sha256": sha(file.read_bytes())})
        constructor = next((x for x in data["abi"] if x["type"] == "constructor"), None)
        linked = bool(data["bytecode"]["linkReferences"] or data["deployedBytecode"]["linkReferences"])
        immutables = data["deployedBytecode"].get("immutableReferences", {})
        creation = data["bytecode"]["object"]
        runtime = data["deployedBytecode"]["object"]
        if not creation.startswith("0x") or not runtime.startswith("0x"):
            raise ValueError(f"missing bytecode: {name}")
        records.append({
            "name": name,
            "source": source,
            "sourceSha256": sha((ROOT / source).read_bytes()),
            "compilerVersion": metadata["compiler"]["version"],
            "optimizer": settings["optimizer"],
            "viaIR": settings.get("viaIR", False),
            "effectiveEvmVersionFromArtifact": settings.get("evmVersion"),
            "evmVersionExplicitInFoundryToml": False,
            "constructorAbi": constructor,
            "sourceDependencies": dependencies,
            "creationBytecodeTemplateSha256": sha(creation.encode()),
            "runtimeBytecodeTemplateSha256": sha(runtime.encode()),
            "creationBytecodeKeccak256": None if linked else evm_hash(creation),
            "runtimeBytecodeKeccak256": None if linked or immutables else evm_hash(runtime),
            "linkReferences": data["bytecode"]["linkReferences"],
            "runtimeLinkReferences": data["deployedBytecode"]["linkReferences"],
            "runtimeImmutableReferences": immutables,
            "creationHashStatus": "REQUIRES_LIBRARY_ADDRESSES" if linked else "DETERMINISTIC",
            "runtimeHashStatus": ("REQUIRES_LIBRARY_ADDRESSES" if linked else
                                  "REQUIRES_CONSTRUCTOR_IMMUTABLE_VALUES" if immutables else
                                  "DETERMINISTIC"),
        })
    result = {
        "schema": "deopt.perps_v2_replacement.source_manifest.v1",
        "chainIdForFutureDeployment": 84532,
        "ownerForFutureDeployment": "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588",
        "sourcePolicy": "current repository source; no historical runtime substitution",
        "bytecodeHashMethod": "Ethereum Keccak-256 only for fully resolved artifact bytecode; linked or immutable runtime templates use SHA-256 until constructor/library addresses are reviewed",
        "contracts": records,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print(OUT.relative_to(ROOT))
    print(hashlib.sha256(OUT.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()
