#!/usr/bin/env python3
"""Pinned, read-only Base Sepolia shared-state check for a replacement package.

Uses the configured project RPC without recording or printing its URL. No
transaction, signer, database, or keystore operation is present in this tool.
"""

import json
from pathlib import Path
import sys

from eth_abi import decode, encode
from eth_utils import keccak

from first_trade_live_state import PublicRpc, configured_rpc_url, pin_mode

ROOT = Path(__file__).resolve().parents[2]
FROZEN = ROOT / "artifacts/perps_v2_replacement/pmr_config_manifest.json"
OUT = ROOT / "artifacts/perps_v2_replacement_deployment/live_shared_state.json"
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
VAULT = "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3"
INSURANCE = "0x009f38440F058d095b61E0E2ee7fAbDF05BE7500"
CLEARING = "0x54d49c088DD27cFc82685b867c182b4bB4aC435c"
SEIZER = "0x39F928b959cF58369E7C7a3B925e6cBfFA62B669"
LEGACY_FMV2 = "0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f"
NEW = "0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15"
OLD = "0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9"
V1 = "0xc6C592100723Fe0C66343A16e95eC34cC0c2141c"
TOKEN = "0x6eAe407f5640B006faC9965182e238582A3B412E"


def abi_type(item):
    if item["type"].startswith("tuple"):
        return "(" + ",".join(abi_type(x) for x in item["components"]) + ")" + item["type"][5:]
    return item["type"]


def canonical(value):
    if isinstance(value, bytes):
        return "0x" + value.hex()
    if isinstance(value, str) and value.startswith("0x"):
        return value.lower()
    if isinstance(value, (tuple, list)):
        return [canonical(x) for x in value]
    return value


def named(item, value):
    if item["type"] == "tuple":
        return {part["name"]: named(part, field) for part, field in zip(item["components"], value)}
    return canonical(value)


def artifact_call(rpc, tag, contract, artifact, method, args=()):
    abi = json.loads((ROOT / f"out/{artifact}.sol/{artifact}.json").read_text())["abi"]
    matches = [x for x in abi if x["type"] == "function" and x["name"] == method and len(x["inputs"]) == len(args)]
    if len(matches) != 1:
        raise ValueError("ambiguous ABI method " + method)
    entry = matches[0]
    sig = method + "(" + ",".join(abi_type(x) for x in entry["inputs"]) + ")"
    payload = keccak(text=sig)[:4] + encode([abi_type(x) for x in entry["inputs"]], args)
    result = rpc("eth_call", [{"to": contract, "data": "0x" + payload.hex()}, tag])
    values = decode([abi_type(x) for x in entry["outputs"]], bytes.fromhex(result[2:]))
    return named(entry["outputs"][0], values[0]) if len(values) == 1 else [named(x, y) for x, y in zip(entry["outputs"], values)]


def simple_call(rpc, tag, address, signature, arg_types=(), args=(), out_types=("address",)):
    payload = keccak(text=signature)[:4] + encode(list(arg_types), list(args))
    raw = rpc("eth_call", [{"to": address, "data": "0x" + payload.hex()}, tag])
    values = decode(list(out_types), bytes.fromhex(raw[2:]))
    return canonical(values[0]) if len(values) == 1 else canonical(values)


def compare(expected, actual, path, differences):
    if isinstance(expected, dict):
        for key, val in expected.items():
            if key not in actual:
                differences.append({"field": path + "." + key, "status": "UNREADABLE"})
            else:
                compare(val, actual[key], path + "." + key, differences)
    elif isinstance(expected, list):
        if len(expected) != len(actual):
            differences.append({"field": path, "status": "UNEXPECTED_DRIFT", "expected": expected, "actual": actual})
        else:
            for index, val in enumerate(expected):
                compare(val, actual[index], f"{path}[{index}]", differences)
    elif canonical(expected) != canonical(actual):
        differences.append({"field": path, "status": "UNEXPECTED_DRIFT", "expected": expected, "actual": actual})


def main():
    rpc = PublicRpc(configured_rpc_url())
    chain = int(rpc("eth_chainId", []), 16)
    if chain != 84532:
        raise ValueError("wrong chain")
    block_tag = hex(int(sys.argv[1])) if len(sys.argv) == 2 else "latest"
    block = rpc("eth_getBlockByNumber", [block_tag, False])
    tag, pin = pin_mode(rpc, block)
    frozen = json.loads(FROZEN.read_text())
    registry = frozen["reference"]["registry"]
    router = frozen["sharedOracleDependencyReadback"]["router"]
    read = lambda addr, art, method, args=(): artifact_call(rpc, tag, addr, art, method, args)
    live = {
        "chainId": chain,
        "blockNumber": int(block["number"], 16),
        "blockHash": block["hash"],
        "blockTimestamp": int(block["timestamp"], 16),
        "pinMode": pin,
        "timelock": {
            "owner": read(TIMELOCK, "ProtocolTimelock", "owner"),
            "guardian": read(TIMELOCK, "ProtocolTimelock", "guardian"),
            "minDelay": read(TIMELOCK, "ProtocolTimelock", "minDelay"),
            "safeProposer": read(TIMELOCK, "ProtocolTimelock", "proposers", (SAFE,)),
            "safeExecutor": read(TIMELOCK, "ProtocolTimelock", "executors", (SAFE,)),
        },
        "safe": {
            "owners": simple_call(rpc, tag, SAFE, "getOwners()", out_types=("address[]",)),
            "threshold": simple_call(rpc, tag, SAFE, "getThreshold()", out_types=("uint256",)),
            "nonce": simple_call(rpc, tag, SAFE, "nonce()", out_types=("uint256",)),
            "modules": simple_call(rpc, tag, SAFE, "getModulesPaginated(address,uint256)",
                                   ("address", "uint256"), ("0x0000000000000000000000000000000000000001", 32),
                                   ("address[]", "address")),
        },
        "vault": {
            "owner": read(VAULT, "CollateralVault", "owner"),
            "guardian": read(VAULT, "CollateralVault", "guardian"),
            "marginEngine": read(VAULT, "CollateralVault", "marginEngine"),
            "insuranceMapped": read(VAULT, "CollateralVault", "isAuthorizedEngine", (INSURANCE,)),
            "insuranceEffective": read(VAULT, "CollateralVault", "isEngineAuthorized", (INSURANCE,)),
            "strandedNew": read(VAULT, "CollateralVault", "isAuthorizedEngine", (NEW,)),
            "oldEngine": read(VAULT, "CollateralVault", "isAuthorizedEngine", (OLD,)),
            "v1Engine": read(VAULT, "CollateralVault", "isAuthorizedEngine", (V1,)),
            "clearingLedger": read(VAULT, "CollateralVault", "balances", (CLEARING, TOKEN)),
            "insuranceLedger": read(VAULT, "CollateralVault", "balances", (INSURANCE, TOKEN)),
            "tokenConfig": read(VAULT, "CollateralVault", "getCollateralConfig", (TOKEN,)),
        },
        "insurance": {
            "owner": read(INSURANCE, "InsuranceFund", "owner"),
            "guardian": read(INSURANCE, "InsuranceFund", "guardian"),
            "vault": read(INSURANCE, "InsuranceFund", "collateralVault"),
            "strandedNewBackstop": read(INSURANCE, "InsuranceFund", "isBackstopCaller", (NEW,)),
        },
        "clearing": {"vault": read(CLEARING, "PerpClearingAccountV2", "collateralVault")},
        "seizer": {
            "owner": read(SEIZER, "CollateralSeizer", "owner"),
            "vault": read(SEIZER, "CollateralSeizer", "collateralVault"),
            "oracle": read(SEIZER, "CollateralSeizer", "oracle"),
            "riskModule": read(SEIZER, "CollateralSeizer", "riskModule"),
            "oracleMaxDelay": read(SEIZER, "CollateralSeizer", "oracleMaxDelay"),
        },
        "legacyCollateralRisk": {},
        "legacyFmv2": {
            "owner": read(LEGACY_FMV2, "FeesManagerV2", "owner"),
            "feeRecipient": read(LEGACY_FMV2, "FeesManagerV2", "feeRecipient"),
        },
        "pmr": {
            "registry": registry,
            "owner": read(registry, "PerpMarketRegistry", "owner"),
            "guardian": read(registry, "PerpMarketRegistry", "guardian"),
            "timelockIsMarketCreator": read(registry, "PerpMarketRegistry", "isMarketCreator", (TIMELOCK,)),
            "nextMarketId": read(registry, "PerpMarketRegistry", "nextMarketId"),
            "marketIds": read(registry, "PerpMarketRegistry", "getAllMarketIds"),
            "settlementAllowed": read(registry, "PerpMarketRegistry", "isSettlementAssetAllowed", (TOKEN,)),
            "paused": read(registry, "PerpMarketRegistry", "paused"),
            "creationPaused": read(registry, "PerpMarketRegistry", "creationPaused"),
            "configPaused": read(registry, "PerpMarketRegistry", "configPaused"),
            "markets": [],
        },
        "oracle": {
            "owner": read(router, "OracleRouter", "owner"),
            "guardian": read(router, "OracleRouter", "guardian"),
            "maxOracleDelay": read(router, "OracleRouter", "maxOracleDelay"),
        },
    }
    legacy_risk = live["seizer"]["riskModule"]
    live["legacyCollateralRisk"] = {
        "address": legacy_risk,
        "owner": read(legacy_risk, "RiskModule", "owner"),
        "vault": read(legacy_risk, "RiskModule", "collateralVault"),
        "oracle": read(legacy_risk, "RiskModule", "oracle"),
    }
    live["runtimeIdentity"] = {}
    for name, address_value in (("timelock", TIMELOCK), ("safe", SAFE), ("vault", VAULT),
                                ("insurance", INSURANCE), ("clearing", CLEARING),
                                ("oracle", router), ("seizer", SEIZER),
                                ("legacyCollateralRisk", legacy_risk)):
        code = bytes.fromhex(rpc("eth_getCode", [address_value, tag])[2:])
        if not code:
            raise ValueError("missing code at " + name)
        live["runtimeIdentity"][name] = {
            "address": address_value, "bytes": len(code), "keccak256": "0x" + keccak(code).hex(),
        }
    for record in frozen["markets"]:
        market_id = record["marketId"]
        market, risk, liquidation, funding = read(registry, "PerpMarketRegistry", "getMarketConfigs", (market_id,))
        market["symbolBytes32"] = market.pop("symbol")
        live["pmr"]["markets"].append({
            "marketId": market_id,
            "market": market,
            "risk": risk, "liquidation": liquidation, "funding": funding,
            "maxExecutionDeviationBps": read(registry, "PerpMarketRegistry", "getMaxExecutionDeviationBps", (market_id,)),
            "metadata": read(registry, "PerpMarketRegistry", "marketMetadata", (market_id,)),
        })
        base = record["market"]["underlying"]
        feed = read(router, "OracleRouter", "getFeed", (base, TOKEN))
        live["oracle"][f"market{market_id}Feed"] = feed
    hash_before = rpc("eth_getBlockByNumber", [block["number"], False])["hash"]
    if hash_before.lower() != block["hash"].lower():
        raise ValueError("canonical block changed")
    differences = []
    compare(frozen["marketCreationOrder"], live["pmr"]["marketIds"], "marketIds", differences)
    compare(frozen["nextMarketIdAfterCreation"], live["pmr"]["nextMarketId"], "nextMarketId", differences)
    compare(frozen["markets"], live["pmr"]["markets"], "markets", differences)
    for key, actual in (("maxOracleDelaySeconds", live["oracle"]["maxOracleDelay"]),):
        compare(frozen["sharedOracleDependencyReadback"]["globalMaxOracleDelaySeconds"], actual, "oracle." + key, differences)
    for market_id in (1, 2):
        expected_feed = frozen["sharedOracleDependencyReadback"][f"market{market_id}Feed"]
        actual_feed = live["oracle"][f"market{market_id}Feed"]
        translated = {"primary": actual_feed["primarySource"], "secondary": actual_feed["secondarySource"],
                      "maxDelaySeconds": actual_feed["maxDelay"],
                      "maxDeviationBps": actual_feed["maxDeviationBps"], "isActive": actual_feed["isActive"]}
        compare(expected_feed, translated, f"oracle.market{market_id}Feed", differences)
    live["pmr"]["differences"] = differences
    live["pmr"]["refresh"] = "PASS" if not differences else "BLOCKED"
    def leaves(value, path):
        if isinstance(value, dict):
            for key, item in value.items():
                yield from leaves(item, path + "." + key)
        elif isinstance(value, list):
            for index, item in enumerate(value):
                yield from leaves(item, f"{path}[{index}]")
        else:
            yield {"field": path, "status": "MATCH"}
    live["pmr"]["fieldClassifications"] = (
        list(leaves(frozen["markets"], "markets")) +
        list(leaves(frozen["sharedOracleDependencyReadback"], "sharedOracleDependencyReadback")) +
        [{"field": "marketCreationOrder", "status": "MATCH"},
         {"field": "nextMarketIdAfterCreation", "status": "MATCH"},
         {"field": "allowedSettlementAssetsForReplacement", "status": "MATCH" if live["pmr"]["settlementAllowed"] else "UNEXPECTED_DRIFT"},
         {"field": "reference.blockNumber/blockHash/timestamp", "status": "EXPECTED_DIFFERENCE", "reason": "fresh canonical comparison block"},
         {"field": "marketCreatorForReplacement", "status": "EXPECTED_DIFFERENCE", "reason": "new Timelock-owned PMR not yet deployed"},
         {"field": "guardianForReplacement", "status": "EXPECTED_DIFFERENCE", "reason": "new PMR guardian requires future Timelock configuration"}]
    )
    for key, desired in frozen["postConfigurationMaintenance"].items():
        live["pmr"]["fieldClassifications"].append({
            "field": "postConfigurationMaintenance." + key,
            "status": "MATCH" if live["pmr"][key] == desired else "EXPECTED_DIFFERENCE",
            "reason": "intended replacement maintenance control; live source PMR remains separate" if live["pmr"][key] != desired else "",
        })
    for item in live["pmr"]["fieldClassifications"]:
        if any(d["field"] == item["field"] for d in differences):
            item["status"] = "UNEXPECTED_DRIFT"
    live["vaultInsuranceAcl"] = {
        "sourcePredicate": "CollateralVaultStorage._isAuthorizedEngine(msg.sender) in onlyMarginEngine for transferBetweenAccounts",
        "caller": INSURANCE,
        "required": True,
        "present": live["vault"]["insuranceEffective"],
        "status": "PASS" if live["vault"]["insuranceEffective"] else "BLOCKED",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(live, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"chainId": chain, "blockNumber": live["blockNumber"], "blockHash": block["hash"],
                      "pmr": live["pmr"]["refresh"], "pmrDifferences": len(differences),
                      "insuranceVaultAcl": live["vaultInsuranceAcl"]["status"],
                      "clearingLedger": live["vault"]["clearingLedger"]}))


if __name__ == "__main__":
    main()
