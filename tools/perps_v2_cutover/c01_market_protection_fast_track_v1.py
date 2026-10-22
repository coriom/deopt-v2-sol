#!/usr/bin/env python3
"""Read-only, pinned C01 review and unsigned Safe package generator."""

import hashlib
import json
from pathlib import Path
import sys
import time
import urllib.request

from eth_abi import decode, encode
from eth_utils import keccak

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from first_trade_live_state import configured_rpc_url  # noqa: E402

ART = ROOT / "artifacts/perps_v2_replacement_deployment"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
TL = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
D1 = "0x6B3D846536116082dC4E7227861C341Bb85Ee963"
D4 = "0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB"
D5 = "0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110"
D6 = "0xeeA4e5d891B90D3d99E9C4e2c61069911477110E"
VAULT = "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3"
INSURANCE = "0x009f38440F058d095b61E0E2ee7fAbDF05BE7500"
CLEARING = "0x54d49c088DD27cFc82685b867c182b4bB4aC435c"
TOKEN = "0x6eAe407f5640B006faC9965182e238582A3B412E"
C12_ID = "0xd15ec63a22daebd4eb015de23561089547af9b02945fb8ae6dd7028ae7581229"
ETA = 1792756800  # 2026-10-23 12:00:00 UTC; independent of C12's operation ID.
ZERO = "0x" + "00" * 20
ALLOWED = {"eth_chainId", "eth_getBlockByNumber", "eth_getCode", "eth_call",
           "eth_getTransactionReceipt"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rpc(method, params):
    require(method in ALLOWED, "non-read-only RPC method")
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(configured_rpc_url(), payload,
                                     {"Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
            break
        except Exception as exc:
            if attempt == 2:
                raise RuntimeError("RPC transport failed for " + method + " (" +
                                   type(exc).__name__ + "); endpoint redacted") from None
            time.sleep(attempt + 1)
    require(isinstance(result, dict) and "result" in result and "error" not in result,
            "RPC rejected " + method + "; endpoint redacted")
    return result["result"]


def calldata(signature, types=(), args=()):
    return "0x" + (keccak(text=signature)[:4] + encode(list(types), list(args))).hex()


def call(address, signature, output_types, tag, types=(), args=(), sender=None):
    tx = {"to": address, "data": calldata(signature, types, args)}
    if sender:
        tx["from"] = sender
    try:
        raw = rpc("eth_call", [tx, tag])
    except RuntimeError as exc:
        raise RuntimeError(signature + ": " + str(exc)) from None
    require(isinstance(raw, str) and raw.startswith("0x"), "malformed " + signature)
    return decode(list(output_types), bytes.fromhex(raw[2:]))


def value(address, signature, output_type, tag, types=(), args=()):
    return call(address, signature, [output_type], tag, types, args)[0]


def code_hash(address, tag):
    code = rpc("eth_getCode", [address, tag])
    require(isinstance(code, str) and len(code) > 2, "missing runtime " + address)
    return "0x" + keccak(bytes.fromhex(code[2:])).hex()


def write(name, obj):
    path = ART / name
    data = (json.dumps(obj, indent=2, sort_keys=True) + "\n").encode()
    path.write_bytes(data)
    return {"path": str(path.relative_to(ROOT)), "sha256": hashlib.sha256(data).hexdigest()}


def main():
    dag_path = ART / "post_maintenance_dependency_dag_v1.json"
    manifest_path = ART / "timelock_configuration_manifest_c12_c20_v2.json"
    roadmap_path = ART / "post_maintenance_configuration_roadmap_v1.json"
    dag = json.loads(dag_path.read_text())
    manifest = json.loads(manifest_path.read_text())
    roadmap = json.loads(roadmap_path.read_text())
    node = next(n for n in dag["nodes"] if n["id"] == "C01")
    action = next(a for a in manifest["actions"] if a["stageId"] == "C01")
    require(node["dependsOn"] == ["MAINTENANCE_VERIFIED"], "C01 dependency drift")
    require("C12" not in node["dependsOn"], "C01 depends on C12")
    require(action["signature"] == "setSettlementAssetAllowed(address,bool)", "C01 ABI drift")
    require(action["decodedArgs"] == [TOKEN.lower(), True], "C01 args drift")
    require(roadmap["contracts"]["D1"]["address"].lower() == D1.lower(), "D1 manifest drift")
    inner = calldata(action["signature"], ["address", "bool"], [TOKEN, True])
    require(inner == action["calldata"], "C01 calldata differs from trusted manifest")

    require(int(rpc("eth_chainId", []), 16) == 84532, "wrong chain")
    block = rpc("eth_getBlockByNumber", ["latest", False])
    tag = block["number"]
    number, timestamp = int(tag, 16), int(block["timestamp"], 16)
    pinned = {"number": number, "hash": block["hash"], "timestamp": timestamp}
    runtime = {name: code_hash(address, tag) for name, address in
               (("D1", D1), ("D4", D4), ("D5", D5), ("D6", D6), ("Timelock", TL))}
    for name in ("D1", "D4", "D5", "D6"):
        require(runtime[name] == roadmap["contracts"][name]["runtimeKeccak256"],
                name + " runtime mismatch")
    require(runtime["Timelock"] == "0xb20f9fa764b46a832c7665f07c1b9c3cd6506a58f6885c0e12e88e9bbc55233c",
            "Timelock runtime mismatch")

    state = {
        "D1": {
            "owner": value(D1, "owner()", "address", tag),
            "paused": value(D1, "paused()", "bool", tag),
            "creationPaused": value(D1, "creationPaused()", "bool", tag),
            "configPaused": value(D1, "configPaused()", "bool", tag),
            "totalMarkets": value(D1, "totalMarkets()", "uint256", tag),
            "nextMarketId": value(D1, "nextMarketId()", "uint256", tag),
            "settlementAllowed": value(D1, "isSettlementAssetAllowed(address)", "bool", tag,
                                       ["address"], [TOKEN]),
            "timelockMarketCreator": value(D1, "isMarketCreator(address)", "bool", tag,
                                           ["address"], [TL]),
        },
        "D4": {
            "owner": value(D4, "owner()", "address", tag),
            "tradingPaused": value(D4, "tradingPaused()", "bool", tag),
            "liquidationPaused": value(D4, "liquidationPaused()", "bool", tag),
            "fundingPaused": value(D4, "fundingPaused()", "bool", tag),
            "collateralOpsPaused": value(D4, "collateralOpsPaused()", "bool", tag),
            "migrationState": value(D4, "migrationState()", "uint8", tag),
            "riskModule": value(D4, "riskModule()", "address", tag),
            "matchingEngine": value(D4, "matchingEngine()", "address", tag),
        },
        "D5": {"delay": value(D5, "maxOracleDelay()", "uint256", tag)},
        "D6": {"paused": value(D6, "paused()", "bool", tag)},
        "custody": {
            "vaultD4Authorized": value(VAULT, "isAuthorizedEngine(address)", "bool", tag,
                                       ["address"], [D4]),
            "insuranceD4Backstop": value(INSURANCE, "isBackstopCaller(address)", "bool", tag,
                                         ["address"], [D4]),
            "clearingVaultLedger": value(VAULT, "balances(address,address)", "uint256", tag,
                                         ["address", "address"], [CLEARING, TOKEN]),
            "insuranceVaultLedger": value(VAULT, "balances(address,address)", "uint256", tag,
                                          ["address", "address"], [INSURANCE, TOKEN]),
            "vaultTokenBalance": value(TOKEN, "balanceOf(address)", "uint256", tag,
                                       ["address"], [VAULT]),
        },
    }
    require(state["D1"]["owner"].lower() == TL.lower(), "D1 owner drift")
    require(state["D1"]["totalMarkets"] == 0 and state["D1"]["nextMarketId"] == 1,
            "market already created")
    require(not state["D1"]["settlementAllowed"] and
            not state["D1"]["paused"] and
            not state["D1"]["creationPaused"] and
            not state["D1"]["configPaused"],
            "C01 pre-state drift")
    require(state["D1"]["timelockMarketCreator"], "Timelock market creator absent")
    require(state["D4"]["owner"].lower() == TL.lower(), "D4 owner drift")
    require(all(state["D4"][k] for k in
                ("tradingPaused", "liquidationPaused", "fundingPaused", "collateralOpsPaused")),
            "D4 maintenance open")
    require(state["D4"]["migrationState"] == 0 and
            state["D4"]["riskModule"].lower() == ZERO.lower() and
            state["D4"]["matchingEngine"].lower() == ZERO.lower(), "D4 migration/wiring drift")
    require(state["D5"]["delay"] == 600 and state["D6"]["paused"], "C20/D6 drift")
    require(not state["custody"]["vaultD4Authorized"] and
            not state["custody"]["insuranceD4Backstop"], "shared ACL drift")

    require(value(SAFE, "VERSION()", "string", tag) == "1.4.1", "Safe version drift")
    owners = [a.lower() for a in value(SAFE, "getOwners()", "address[]", tag)]
    expected_owners = [x.lower() for x in roadmap["governance"]["owners"]]
    threshold = value(SAFE, "getThreshold()", "uint256", tag)
    nonce = value(SAFE, "nonce()", "uint256", tag)
    # Safe 1.4.1 GuardManager has an internal getter; StorageAccessible is public.
    guard_slot = int("4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8", 16)
    guard_bytes = value(SAFE, "getStorageAt(uint256,uint256)", "bytes", tag,
                        ["uint256", "uint256"], [guard_slot, 1])
    require(len(guard_bytes) == 32, "Safe guard slot read malformed")
    guard = "0x" + guard_bytes[-20:].hex()
    modules, _ = call(SAFE, "getModulesPaginated(address,uint256)",
                      ["address[]", "address"], tag, ["address", "uint256"],
                      ["0x0000000000000000000000000000000000000001", 10])
    require(threshold == 2 and sorted(owners) == sorted(expected_owners), "Safe authority drift")
    require(guard.lower() == ZERO.lower() and len(modules) == 0, "Safe guard/modules drift")
    delay = value(TL, "minDelay()", "uint256", tag)
    require(delay == 86400 and not value(TL, "queuePaused()", "bool", tag), "Timelock delay/pause drift")
    require(value(TL, "owner()", "address", tag).lower() == SAFE.lower(), "Timelock owner drift")
    require(value(TL, "proposers(address)", "bool", tag, ["address"], [SAFE]) and
            value(TL, "executors(address)", "bool", tag, ["address"], [SAFE]),
            "Safe Timelock roles drift")
    require(value(TL, "queuedTransactions(bytes32)", "bool", tag,
                  ["bytes32"], [bytes.fromhex(C12_ID[2:])]), "C12 not queued")
    require(ETA >= timestamp + delay + 3600, "ETA lacks one-hour scheduling margin")

    op_args = [D1, 0, bytes.fromhex(inner[2:]), ETA]
    op = "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"], op_args)).hex()
    onchain_op = value(TL, "hashOperation(address,uint256,bytes,uint256)", "bytes32", tag,
                       ["address", "uint256", "bytes", "uint256"], op_args)
    require(op == "0x" + onchain_op.hex(), "operation hash mismatch")
    require(not value(TL, "queuedTransactions(bytes32)", "bool", tag,
                      ["bytes32"], [onchain_op]), "C01 already queued")
    outer = calldata("queueTransaction(address,uint256,bytes,uint256)",
                     ["address", "uint256", "bytes", "uint256"], op_args)
    queue_return = rpc("eth_call", [{"from": SAFE, "to": TL, "data": outer}, tag])
    require(queue_return.lower() == op.lower(), "queue eth_call operation mismatch")

    safe_types = ["address", "uint256", "bytes", "uint8", "uint256", "uint256",
                  "uint256", "address", "address", "uint256"]
    tx_type = keccak(text="SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)")
    domain_type = keccak(text="EIP712Domain(uint256 chainId,address verifyingContract)")
    domain = keccak(encode(["bytes32", "uint256", "address"], [domain_type, 84532, SAFE]))
    struct = keccak(encode(["bytes32", "address", "uint256", "bytes32", "uint8",
                           "uint256", "uint256", "uint256", "address", "address", "uint256"],
                          [tx_type, TL, 0, keccak(bytes.fromhex(outer[2:])), 0, 0, 0, 0,
                           ZERO, ZERO, nonce]))
    safe_hash = "0x" + keccak(b"\x19\x01" + domain + struct).hex()
    getter_args = [TL, 0, bytes.fromhex(outer[2:]), 0, 0, 0, 0, ZERO, ZERO, nonce]
    onchain_hash = value(SAFE, "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)",
                         "bytes32", tag, safe_types, getter_args)
    require(safe_hash == "0x" + onchain_hash.hex(), "Safe hash mismatch")

    deploy = json.loads((ART / "d1_pmr_execution_retry_v2_journal.json").read_text())["canonicalReceipt"]
    receipt = rpc("eth_getTransactionReceipt", [deploy["transactionHash"]])
    require(int(receipt["status"], 16) == 1 and
            receipt["contractAddress"].lower() == D1.lower() and
            receipt["blockHash"].lower() == deploy["blockHash"].lower(), "D1 receipt drift")
    require(rpc("eth_getBlockByNumber", [tag, False])["hash"].lower() == block["hash"].lower(),
            "pinned block reorg")

    sources = {"dagSha256": hashlib.sha256(dag_path.read_bytes()).hexdigest(),
               "manifestSha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
               "roadmapSha256": hashlib.sha256(roadmap_path.read_bytes()).hexdigest(),
               "d1DeploymentTx": deploy["transactionHash"]}
    preparation = {"schema": "deopt.c01_market_protection.preparation.v1", "status": "PASS",
                   "chainId": 84532, "reviewBlock": pinned, "source": sources, "runtimeHashes": runtime,
                   "liveState": state, "dependency": {"dependsOn": node["dependsOn"],
                   "c12Queued": True, "c12CompletionRequired": False, "c02Separate": True},
                   "safeAuthority": {"owners": owners, "threshold": threshold, "nonce": nonce,
                                     "guard": guard, "modules": list(modules)},
                   "effect": "D1 settlement allowlist mUSDC false to true; no market creation",
                   "safeStop": "D4 four flags true, D6 paused, D4 migration OPEN, no market created",
                   "publicTransactionSent": False}
    builder = {"version": "1.0", "chainId": "84532", "createdAt": timestamp * 1000,
               "meta": {"name": "OFFLINE_REVIEW_ONLY_NOT_AUTHORIZED_C01_S1",
                        "description": "One unsigned Safe CALL to ProtocolTimelock.queueTransaction for D1 mUSDC settlement allowlist; separate Safe 2/3 authorization required.",
                        "txBuilderVersion": "1.18.0", "createdFromSafeAddress": SAFE,
                        "createdFromOwnerAddress": ""},
               "transactions": [{"to": TL, "value": "0", "data": outer,
                                 "contractMethod": {"name": "queueTransaction", "payable": False,
                                                    "inputs": [{"name": n, "type": t, "internalType": t}
                                                               for n, t in (("target", "address"),
                                                                            ("value", "uint256"),
                                                                            ("data", "bytes"),
                                                                            ("eta", "uint256"))]},
                                 "contractInputsValues": {"target": D1, "value": "0",
                                                          "data": inner, "eta": str(ETA)}}]}
    builder_ref = write("c01_market_protection_s1_safe_builder_v1.json", builder)
    unsigned = {"schema": "deopt.c01_market_protection.unsigned_schedule.v1",
                "status": "OFFLINE_UNSIGNED_UNSUBMITTED_NOT_AUTHORIZED",
                "chainId": 84532, "safe": SAFE, "timelock": TL,
                "innerCall": {"target": D1, "valueWei": 0, "signature": action["signature"],
                              "args": [TOKEN, True], "calldata": inner},
                "queueCall": {"calldata": outer, "eta": ETA, "operationId": op,
                              "bufferedSchedulingCutoff": ETA - delay - 3600},
                "safeEnvelope": {"to": TL, "valueWei": 0, "data": outer, "operation": 0,
                                 "safeTxGas": 0, "baseGas": 0, "gasPrice": 0,
                                 "gasToken": ZERO, "refundReceiver": ZERO, "nonce": nonce,
                                 "safeTxHashConditional": safe_hash},
                "builder": builder_ref, "signatureCount": 0, "proposalCount": 0,
                "publicTransactionSent": False}
    unsigned_ref = write("c01_market_protection_s1_unsigned_intent_v1.json", unsigned)
    prep_ref = write("c01_market_protection_preparation_v1.json", preparation)
    fork_path = ART / "c01_market_protection_fork_validation_v1.json"
    fork = json.loads(fork_path.read_text())
    require(fork["forkBlockNumber"] == 48642380 and
            all(fork["correctedRun"].get(k) == v for k, v in
                {"passed": 3, "failed": 0, "skipped": 0, "exitCode": 0}.items()) and
            fork["additionalLocalGovernanceOrderTest"]["passed"] == 1 and
            fork["additionalLocalGovernanceOrderTest"]["failed"] == 0,
            "focused fork validation absent or failed")
    fork_ref = {"path": str(fork_path.relative_to(ROOT)),
                "sha256": hashlib.sha256(fork_path.read_bytes()).hexdigest()}
    review = {"schema": "deopt.c01_market_protection.scheduling_final_review.v1",
              "status": "PASS_FOR_SEPARATE_OPERATOR_REVIEW_ONLY", "reviewBlock": pinned,
              "preparation": prep_ref, "unsignedIntent": unsigned_ref,
              "builder": builder_ref, "forkValidation": fork_ref,
              "operationId": op, "safeTxHashConditional": safe_hash,
              "crossChecks": {"manifestInnerCalldata": True, "onchainOperationId": True,
                              "queueEthCall": True, "safeHashGetter": True,
                              "pinnedBlockHashRechecked": True, "D1CanonicalReceipt": True},
              "minDelaySeconds": delay, "eta": ETA,
              "bufferedSchedulingCutoff": ETA - delay - 3600,
              "secondsToCutoffAtReview": ETA - delay - 3600 - timestamp,
              "c12Independence": True, "marketProtection": True,
              "economicIsolation": "PASS_BOUNDED_FORK_AND_PINNED_STATE",
              "sourceReview": {
                  "C01": "setSettlementAssetAllowed(mUSDC,true) is onlyOwner and whenConfigNotPaused; it updates one allowlist mapping and emits SettlementAssetConfigured",
                  "C02": "createMarket checks the allowlist and creates a market active immediately; C02 and MKT1_INACTIVE remain separately governed",
                  "economicRoute": "C01 creates no market; D4 migration OPEN, four pauses true, Risk/PME pointers zero, D6 paused and shared ACLs absent"
              },
              "limitations": ["Safe hash is conditional on nonce and every envelope field",
                              "Full Safe UI gas simulation and wallet review remain operator gates",
                              "One RPC provider; named getter and receipt scope is bounded",
                              "Future C02 creates an active market and requires separate authorization"],
              "publicSigning": False, "safeProposal": False,
              "publicScheduling": False, "publicExecution": False}
    review_ref = write("c01_market_protection_s1_final_review_v1.json", review)
    print(json.dumps({"block": pinned, "eta": ETA, "operationId": op,
                      "safeTxHashConditional": safe_hash, "nonce": nonce,
                      "secondsToCutoff": review["secondsToCutoffAtReview"],
                      "files": [prep_ref, unsigned_ref, builder_ref, review_ref]}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("C01 fast track blocked: " + str(exc), file=sys.stderr)
        raise SystemExit(1) from None
