#!/usr/bin/env python3
"""Pinned-block, read-only Options collateral and settlement inventory.

Only RPC_URL is loaded from .env.base-sepolia. No signer, key, or transaction API
is used. Output contains public chain state and a SHA-256 of runtime bytecode.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "deployments/base-sepolia.manifest.draft.json"
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"

SELECTOR = {
    "owner": "8da5cb5b", "guardian": "452a9320", "marginEngine": "004006e0",
    "riskModule": "9ed1a985", "collateralVault": "0bece79c",
    "optionRegistry": "3b4567b0", "oracle": "7dc0d1d0",
    "matchingEngine": "1c0edff2", "settlementOperator": "1b6984e8",
    "settlementFinalityDelay": "4b27b5a4", "getAllOptionIds": "04c51d97",
    "getSeries": "1160da15", "seriesShortOpenInterest": "1bcae3a9",
    "getCollateralTokens": "b58eb63f", "totalDepositedByToken": "e62bac56",
    "balanceOf": "70a08231", "balances": "c23f001f", "decimals": "313ce567",
    "withdrawalsPaused": "e9f2838e", "settlementPaused": "4168632d",
    "getTraderSeries": "e981da29", "getPositionQuantity": "ffdfaead",
}


def rpc_url():
    supplied = os.environ.get("OPTIONS_V7_RPC_URL")
    if supplied:
        return supplied
    with (ROOT / ".env.base-sepolia").open() as env_file:
        for line in env_file:
            if line.startswith("RPC_URL="):
                return line.split("=", 1)[1].strip().strip("\"'")
    raise RuntimeError("RPC_URL unavailable")


class Rpc:
    def __init__(self, url):
        if not url.startswith("https://"):
            raise RuntimeError("RPC must use HTTPS")
        self.url = url
        self.block = "latest"

    def call(self, method, params):
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, data=payload, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                result = json.load(response)
        except Exception as exc:
            raise RuntimeError(f"RPC {method} failed: {type(exc).__name__}") from None
        if "error" in result or "result" not in result:
            raise RuntimeError(f"RPC {method} returned error")
        return result["result"]

    def view(self, address, method, *words):
        data = "0x" + SELECTOR[method] + "".join(f"{word:064x}" for word in words)
        return self.call("eth_call", [{"to": address, "data": data}, self.block])


def words(data):
    if not isinstance(data, str) or not data.startswith("0x") or (len(data) - 2) % 64:
        raise RuntimeError("Malformed ABI response")
    return [int(data[i:i + 64], 16) for i in range(2, len(data), 64)]


def scalar(rpc, address, method, *args):
    value = words(rpc.view(address, method, *args))
    if len(value) != 1:
        raise RuntimeError(f"Unexpected ABI response for {method}")
    return value[0]


def addr(value):
    return "0x" + f"{value:040x}"[-40:]


def dynamic_array(data, limit=256):
    value = words(data)
    if len(value) < 2 or value[0] != 32 or value[1] > limit or len(value) != value[1] + 2:
        raise RuntimeError("Unexpected or oversized ABI array")
    return value[2:]


def contract(rpc, address):
    code = rpc.call("eth_getCode", [address, rpc.block])
    raw = bytes.fromhex(code[2:])
    if not raw:
        raise RuntimeError(f"No deployed code at {address}")
    slots = {}
    for name, slot in (("implementation", IMPLEMENTATION_SLOT), ("admin", ADMIN_SLOT), ("beacon", BEACON_SLOT)):
        value = int(rpc.call("eth_getStorageAt", [address, slot, rpc.block]), 16)
        slots[name] = addr(value & ((1 << 160) - 1)) if value else None
    return {"address": address, "runtime_bytes": len(raw), "runtime_sha256": hashlib.sha256(raw).hexdigest(),
            "erc1967_slots": slots, "eip1167_minimal_proxy": raw.startswith(bytes.fromhex("363d3d373d3d3d363d73"))}


def main():
    manifest = json.loads(MANIFEST.read_text())
    rpc = Rpc(rpc_url())
    if int(rpc.call("eth_chainId", []), 16) != 84532:
        raise RuntimeError("Wrong chain ID")
    block = rpc.call("eth_getBlockByNumber", ["latest", False])
    rpc.block = block["number"]
    contracts = manifest["contracts"]
    vault = contracts["CollateralVault"]
    registry = contracts["OptionProductRegistry"]
    engine = addr(scalar(rpc, vault, "marginEngine"))
    risk = addr(scalar(rpc, vault, "riskModule"))
    result = {"chain_id": 84532, "block": int(rpc.block, 16), "block_hash": block["hash"],
              "block_timestamp": int(block["timestamp"], 16), "contracts": {},
              "wiring": {"vault_margin_engine": engine, "vault_risk_module": risk},
              "collateral": [], "series": [], "accounts": []}
    for name, address in (("vault", vault), ("registry", registry), ("margin_engine", engine), ("risk_module", risk)):
        result["contracts"][name] = contract(rpc, address)
    result["wiring"].update({
        "engine_vault": addr(scalar(rpc, engine, "collateralVault")),
        "engine_registry": addr(scalar(rpc, engine, "optionRegistry")),
        "engine_risk": addr(scalar(rpc, engine, "riskModule")),
        "engine_oracle": addr(scalar(rpc, engine, "oracle")),
        "engine_matching": addr(scalar(rpc, engine, "matchingEngine")),
    })
    result["contracts"]["option_matching"] = contract(rpc, result["wiring"]["engine_matching"])
    result["registry_admin"] = {"owner": addr(scalar(rpc, registry, "owner")),
                                "settlement_operator": addr(scalar(rpc, registry, "settlementOperator")),
                                "settlement_finality_delay_seconds": scalar(rpc, registry, "settlementFinalityDelay"),
                                "settlement_paused": bool(scalar(rpc, registry, "settlementPaused"))}
    result["vault_admin"] = {"owner": addr(scalar(rpc, vault, "owner")),
                             "guardian": addr(scalar(rpc, vault, "guardian")),
                             "withdrawals_paused": bool(scalar(rpc, vault, "withdrawalsPaused"))}
    for token_word in dynamic_array(rpc.view(vault, "getCollateralTokens"), 32):
        token = addr(token_word)
        result["collateral"].append({"token": token, "decimals": scalar(rpc, token, "decimals"),
                                     "vault_accounting_total": scalar(rpc, vault, "totalDepositedByToken", token_word),
                                     "vault_token_balance": scalar(rpc, token, "balanceOf", int(vault, 16))})
    for option_id in dynamic_array(rpc.view(registry, "getAllOptionIds")):
        value = words(rpc.view(registry, "getSeries", option_id))
        if len(value) != 9:
            raise RuntimeError("Unexpected OptionSeries ABI")
        result["series"].append({"id": str(option_id), "underlying": addr(value[0]),
                                  "settlement_asset": addr(value[1]), "expiry": value[2],
                                  "strike_1e8": value[3], "contract_size_1e8": value[4],
                                  "call": bool(value[5]), "european": bool(value[6]),
                                  "exists": bool(value[7]), "active": bool(value[8]),
                                  "short_open_interest": scalar(rpc, engine, "seriesShortOpenInterest", option_id)})
    for account in sys.argv[1:]:
        if not account.startswith("0x") or len(account) != 42:
            raise RuntimeError("Invalid public account address")
        account = account.lower()
        series = dynamic_array(rpc.view(engine, "getTraderSeries", int(account, 16)), 256)
        balances = {item["token"]: scalar(rpc, vault, "balances", int(account, 16), int(item["token"], 16))
                    for item in result["collateral"]}
        positions = {str(option_id): scalar(rpc, engine, "getPositionQuantity", int(account, 16), option_id)
                     for option_id in series}
        positions = {key: value - (1 << 256) if value >= (1 << 255) else value for key, value in positions.items()}
        result["accounts"].append({"address": account, "vault_balances": balances, "positions": positions})
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--fork-test"]:
            environment = os.environ.copy()
            environment["RPC_URL"] = rpc_url()
            sys.exit(subprocess.call(
                ["forge", "test", "--match-path", "test/fork/OptionWithdrawalRiskGateFork.t.sol", "-vv"],
                cwd=ROOT, env=environment,
            ))
        main()
    except Exception as exc:
        print(f"PREFLIGHT_BLOCKED={exc}", file=sys.stderr)
        sys.exit(1)
