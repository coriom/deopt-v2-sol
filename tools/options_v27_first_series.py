#!/usr/bin/env python3
"""Build a CONDITIONAL V27 Safe/Timelock package. Never signs or broadcasts."""

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

CHAIN_ID = 84532
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
MULTISEND_CALL_ONLY = "0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
REGISTRY = "0xcb7bc539ed4A5771F3420f498002e0fc4eE1bD27"
ENGINE = "0x2C4589c88323009db372B4067702e6292ddD294C"
MATCHER = "0x63DE63912BB6743F72ea77847572503Cc93B7d80"
MWETH = "0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02"
MUSDC = "0x6eAe407f5640B006faC9965182e238582A3B412E"
ORACLE = "0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581"


def cast(*args: str) -> str:
    return subprocess.check_output(("cast", *args), text=True).strip()


def item(to: str, data: str) -> bytes:
    body = bytes.fromhex(data[2:])
    return b"\x00" + bytes.fromhex(to[2:]) + (0).to_bytes(32, "big") + len(body).to_bytes(32, "big") + body


def multisend(actions: list[tuple[str, str]]) -> str:
    packed = b"".join(item(to, data) for to, data in actions)
    return cast("calldata", "multiSend(bytes)", "0x" + packed.hex())


def epoch(value: str) -> int:
    return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--strike", type=int, default=2100, help="candidate whole mUSDC per ETH")
    p.add_argument("--expiry", default="2026-11-27T12:00:00Z")
    p.add_argument("--eta", default="2026-11-18T12:00:00Z")
    p.add_argument("--output", default="artifacts/options_v27_first_series/conditional_package.json")
    a = p.parse_args()
    expiry, eta = epoch(a.expiry), epoch(a.eta)
    if not (0 < a.strike < 2**56 and 0 < eta < expiry):
        p.error("invalid candidate strike, ETA or expiry")
    strike1e8 = a.strike * 10**8
    encoded = cast(
        "abi-encode", "f(address,address,uint64,uint64,uint128,bool,bool)",
        MWETH, MUSDC, str(expiry), str(strike1e8), str(10**8), "true", "true",
    )
    option_id = cast("keccak", encoded)
    cfg = f"({ORACLE},0,0,0,0,true)"
    calls = [
        ("REGISTRY_UNPAUSE", cast("calldata", "unpause()")),
        ("ETH_UNDERLYING_ENABLE", cast("calldata", "setUnderlyingConfig(address,(address,uint64,uint64,uint64,uint64,bool))", MWETH, cfg)),
        ("MUSDC_SETTLEMENT_ALLOW", cast("calldata", "setSettlementAssetAllowed(address,bool)", MUSDC, "true")),
        ("CREATE_ETH_CALL", cast("calldata", "createSeries(address,address,uint64,uint64,bool,bool)", MWETH, MUSDC, str(expiry), str(strike1e8), "true", "true")),
        ("DEACTIVATE_ETH_CALL", cast("calldata", "setSeriesActive(uint256,bool)", str(int(option_id, 16)), "false")),
    ]
    operations = []
    for label, inner in calls:
        encoded_op = cast("abi-encode", "f(address,uint256,bytes,uint256)", REGISTRY, "0", inner, str(eta))
        operations.append({
            "label": label, "target": REGISTRY, "value": "0", "innerCalldata": inner,
            "eta": eta, "operationId": cast("keccak", encoded_op),
            "queueCalldata": cast("calldata", "queueTransaction(address,uint256,bytes,uint256)", REGISTRY, "0", inner, str(eta)),
            "executeCalldata": cast("calldata", "executeTransaction(address,uint256,bytes,uint256)", REGISTRY, "0", inner, str(eta)),
        })
    queue = [(TIMELOCK, op["queueCalldata"]) for op in operations]
    execute = [(TIMELOCK, op["executeCalldata"]) for op in operations]
    execute.append((REGISTRY, cast("calldata", "pause()")))  # Safe is guardian only after V24 S2.
    result = {
        "status": "CONDITIONAL_NOT_AUTHORIZED", "chainId": CHAIN_ID, "safe": SAFE,
        "timelock": TIMELOCK, "multisendCallOnly": MULTISEND_CALL_ONLY,
        "registry": REGISTRY, "engine": ENGINE, "matcher": MATCHER,
        "candidate": {"underlying": MWETH, "settlementAsset": MUSDC, "strike1e8": strike1e8,
                      "expiry": expiry, "contractSize1e8": 10**8, "isCall": True,
                      "isEuropean": True, "optionId": option_id},
        "eta": eta, "operations": operations,
        "safeGasParameters": {"safeTxGas": "0", "baseGas": "0", "gasPrice": "0",
                              "gasToken": "0x0000000000000000000000000000000000000000",
                              "refundReceiver": "0x0000000000000000000000000000000000000000"},
        "queueSafeAction": {"to": MULTISEND_CALL_ONLY, "value": "0", "operation": 1,
                            "safeTxGas": "0", "baseGas": "0", "gasPrice": "0", "data": multisend(queue)},
        "executeSafeActionConditional": {"to": MULTISEND_CALL_ONLY, "value": "0", "operation": 1,
                                         "safeTxGas": "0", "baseGas": "0", "gasPrice": "0", "data": multisend(execute)},
        "warnings": [
            "Candidate strike/expiry and ETA require fresh approval and RPC preflight.",
            "V24 S2 must be canonically executed first; Safe guardian final pause depends on it.",
            "Five independent Timelock operations can technically be executed separately by Safe 2/3.",
            "Queue and execute are separate Safe transactions with fresh nonces and distinct authorizations.",
            "No SafeTxHash, gas estimate or signature is valid until final preflight.",
        ],
    }
    out = Path(a.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"PACKAGE={out} OPTION_ID={option_id} OPERATIONS={len(operations)}")


if __name__ == "__main__":
    main()
