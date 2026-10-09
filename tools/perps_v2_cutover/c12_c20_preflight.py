#!/usr/bin/env python3
"""Fail-closed, read-only C12 authorization/execution preflight. Never signs or sends.

This is an off-chain operational gate, not a Solidity invariant. Invoke it twice:
before separate C12 authorization and immediately before public C12 execution.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

from eth_abi import decode, encode
from eth_utils import keccak

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_governance_c12_c20_v2 import NEW as MANIFEST, build as expected_manifest, D4, D5  # noqa: E402
from first_trade_live_state import configured_rpc_url  # noqa: E402

CHAIN = 84532
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
DEPLOYER = "0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0"
VAULT = "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3"
INSURANCE = "0x009f38440F058d095b61E0E2ee7fAbDF05BE7500"
D4_DEPLOY_TX = "0xd77b5b6c74a6709fc8a5040318ced23f7033c69f7720b4fb4c74e200e306fae0"
D4_HASH = "0x1ee5dc2756bea85a4ab327ff69f8652ef6aa0acf2883f00ad1a23c7f51f95785"
D5_HASH = "0x8c782209845865d35ecff80c00525ef3f0f335bea4e7b9846f01199c60fb5a2c"
ZERO = "0x" + "0" * 40
C20_DATA = "0x" + (keccak(text="setMaxOracleDelay(uint256)")[:4] + encode(["uint256"], [600])).hex()
C12_DATA = "0x" + (keccak(text="setRiskModule(address)")[:4] + encode(["address"], [D5])).hex()
QUEUED_TOPIC = "0x" + keccak(text="TransactionQueued(bytes32,address,uint256,bytes,uint256)").hex()
EXECUTED_TOPIC = "0x" + keccak(text="TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)").hex()
SAFE_EXEC = "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)"
SAFE_EXEC_TYPES = ["address", "uint256", "bytes", "uint8", "uint256", "uint256", "uint256",
                   "address", "address", "bytes"]
DELAY_SET_TOPIC = "0x" + keccak(text="MaxOracleDelaySet(uint256,uint256)").hex()
READ_ONLY_RPC = frozenset(("eth_chainId", "eth_getBlockByNumber", "eth_getCode", "eth_call",
                           "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getLogs"))


class PublicRpc:
    def __init__(self, endpoint):
        self.endpoint = endpoint

    def __call__(self, method, params):
        require(method in READ_ONLY_RPC, "public RPC method not read-only")
        request = urllib.request.Request(self.endpoint,
            data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.load(response)
        except Exception:
            raise GateError("public RPC transport failed; endpoint redacted") from None
        require(isinstance(body, dict) and "error" not in body and "result" in body,
                "public RPC rejected " + method + "; endpoint redacted")
        return body["result"]


class GateError(RuntimeError):
    pass


def require(ok, reason):
    if not ok:
        raise GateError(reason)


def lower(value):
    require(isinstance(value, str), "missing address/hash")
    return value.lower()


def quantity(value):
    require(isinstance(value, str) and value.startswith("0x"), "malformed quantity")
    return int(value, 16)


def call(rpc, address, signature, types=(), args=(), tag="latest"):
    data = "0x" + (keccak(text=signature)[:4] + encode(list(types), list(args))).hex()
    raw = rpc("eth_call", [{"to": address, "data": data}, tag])
    require(isinstance(raw, str) and raw.startswith("0x") and len(raw) == 66, "invalid " + signature + " readback")
    return int(raw, 16)


def code_hash(rpc, address, tag, expected):
    code = rpc("eth_getCode", [address, tag])
    require(isinstance(code, str) and code.startswith("0x") and len(code) > 2, "missing code at " + address)
    require("0x" + keccak(bytes.fromhex(code[2:])).hex() == expected, "runtime mismatch at " + address)


def canonical_receipt(rpc, tx_hash, latest_number, tag):
    require(isinstance(tx_hash, str) and len(tx_hash) == 66 and tx_hash.startswith("0x"), "missing transaction hash")
    receipt = rpc("eth_getTransactionReceipt", [tx_hash])
    require(isinstance(receipt, dict) and quantity(receipt["status"]) == 1, "missing/failed public receipt")
    require(lower(receipt.get("transactionHash")) == lower(tx_hash), "receipt transaction hash mismatch")
    n = quantity(receipt["blockNumber"])
    require(n < latest_number, "receipt not independently confirmed")
    block = rpc("eth_getBlockByNumber", [hex(n), False])
    require(block and lower(block["hash"]) == lower(receipt["blockHash"]), "receipt block noncanonical")
    tx = rpc("eth_getTransactionByHash", [tx_hash])
    require(isinstance(tx, dict) and lower(tx["blockHash"]) == lower(block["hash"]), "transaction not canonical")
    return receipt, tx, block


def operation_id(target, data, eta):
    return "0x" + keccak(encode(["address", "uint256", "bytes", "uint256"],
                               [target, 0, bytes.fromhex(data[2:]), eta])).hex()


def log_matches(receipt, topic, operation, target, data, eta, executed):
    matches = []
    for log in receipt.get("logs", []):
        topics = log.get("topics", [])
        if lower(log["address"]) != lower(TIMELOCK) or len(topics) != 3 or lower(topics[0]) != topic:
            continue
        if lower(topics[1]) != lower(operation) or int(topics[2], 16) != int(target, 16):
            continue
        try:
            values = decode(["uint256", "bytes", "uint256", "bytes"] if executed else
                            ["uint256", "bytes", "uint256"], bytes.fromhex(log["data"][2:]))
        except Exception:
            continue
        if values[0] == 0 and values[1] == bytes.fromhex(data[2:]) and values[2] == eta:
            require(lower(log.get("transactionHash")) == lower(receipt["transactionHash"]),
                    "Timelock log transaction mismatch")
            matches.append(log)
    require(len(matches) == 1, "missing/ambiguous exact Timelock event")


def governance_envelope(tx, receipt, method, target, data, eta):
    """An exact direct Timelock call or one Safe CALL; never a MultiSend batch."""
    expected = "0x" + (keccak(text=method)[:4] + encode(
        ["address", "uint256", "bytes", "uint256"],
        [target, 0, bytes.fromhex(data[2:]), eta])).hex()
    to = lower(tx.get("to"))
    supplied = lower(tx.get("input"))
    if to == lower(TIMELOCK):
        require(supplied == expected, "wrong direct Timelock call")
    elif to == lower(SAFE):
        require(supplied[:10] == "0x" + keccak(text=SAFE_EXEC)[:4].hex(), "wrong Safe method/batch")
        try:
            values = decode(SAFE_EXEC_TYPES, bytes.fromhex(supplied[10:]))
        except Exception:
            raise GateError("invalid Safe transaction calldata") from None
        require(values[0] == TIMELOCK.lower() and values[1] == 0 and
                values[2] == bytes.fromhex(expected[2:]) and values[3] == 0,
                "Safe transaction must be one exact Timelock CALL")
        require(supplied[10:] == encode(SAFE_EXEC_TYPES, values).hex(), "trailing Safe calldata")
    else:
        raise GateError("wrong Timelock/Safe transaction destination")
    timelock_logs = [log for log in receipt.get("logs", []) if lower(log.get("address")) == lower(TIMELOCK)]
    require(len(timelock_logs) == 1, "batched or missing Timelock operation")


def c12_queue_events(rpc, first_block, tag):
    """Catch any C12 queued by a bypass path, including earlier/other ETAs."""
    logs = scan_logs(rpc, int(first_block, 16), int(tag, 16), {"address": TIMELOCK,
        "topics": [QUEUED_TOPIC, None, "0x" + int(D4, 16).to_bytes(32, "big").hex()]})
    matched = []
    for log in logs:
        require(lower(log.get("address")) == lower(TIMELOCK), "wrong queue log address")
        topics = log.get("topics", [])
        require(len(topics) == 3 and lower(topics[0]) == QUEUED_TOPIC and
                int(topics[2], 16) == int(D4, 16), "malformed queue log")
        try:
            value, data, eta = decode(["uint256", "bytes", "uint256"], bytes.fromhex(log["data"][2:]))
        except Exception:
            raise GateError("invalid queue log") from None
        if value == 0 and data == bytes.fromhex(C12_DATA[2:]):
            matched.append((log, eta))
    return matched


def scan_logs(rpc, start, end, query):
    logs = []
    for first in range(start, end + 1, 2000):
        batch = rpc("eth_getLogs", [{**query, "fromBlock": hex(first),
                                     "toBlock": hex(min(first + 1999, end))}])
        require(isinstance(batch, list), "log scan unavailable")
        logs.extend(batch)
    return logs


def validate_manifest():
    require(MANIFEST.exists(), "versioned manifest missing")
    actual = json.loads(MANIFEST.read_text())
    require(actual == expected_manifest(), "versioned manifest changed or stale")
    require(actual["governance"].lower() == TIMELOCK.lower() and actual["safe"].lower() == SAFE.lower(),
            "wrong governance actor")
    actions = actual["actions"]
    index = {x["stageId"]: i for i, x in enumerate(actions)}
    require(len(index) == len(actions) and index["C20"] < index["C12"], "C20 must precede C12")
    c12, c20 = actions[index["C12"]], actions[index["C20"]]
    require("C20_EXECUTED_AND_READ_BACK" in c12["dependsOn"] and
            not c12["canShareQueueDelayWindow"] and "C20" in c12["forbiddenSameTransactionOrBatchWith"],
            "C12 dependency missing")
    require(c12["calldata"].lower() == C12_DATA and c12["targetAddress"].lower() == D4.lower(),
            "C12 intent mismatch")
    require(c12["liveGate"]["d5MaxOracleDelaySeconds"] == 600 and
            c12["liveGate"]["freshReadbackAtAuthorizationAndExecution"] and
            c12["liveGate"]["canonicalC20QueueAndExecutionReceipts"] and
            c12["liveGate"]["independentReadbackBeforeC12Queue"], "C12 live gate missing")
    require(c20["calldata"].lower() == C20_DATA and c20["targetAddress"].lower() == D5.lower() and
            c20["readback"]["signature"] == "maxOracleDelay()" and c20["readback"]["value"] == 600 and
            not c20["canShareQueueDelayWindow"],
            "C20 intent mismatch")
    return hashlib.sha256(MANIFEST.read_bytes()).hexdigest()


def backend_stopped():
    # Local operator guard; cannot prove all remote/public clients are stopped.
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            executable = str((proc / "exe").resolve()).lower()
            name = (proc / "comm").read_text().lower()
        except OSError:
            continue
        require("deopt" not in executable and "deopt" not in name, "backend process active")
    for proc_net in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            rows = Path(proc_net).read_text().splitlines()[1:]
        except OSError:
            raise GateError("backend listener check unavailable") from None
        for row in rows:
            fields = row.split()
            require(len(fields) > 3, "malformed network listener state")
            require(not (fields[1].split(":")[-1].upper() == "1F90" and fields[3] == "0A"),
                    "backend port 8080 active")
    return True


def validate(rpc, evidence, phase, *, backend_ok=False):
    """Return sanitized observations or raise; all RPC calls are read-only."""
    require(phase in ("authorization", "execution"), "invalid phase")
    manifest_sha = validate_manifest()
    require(quantity(rpc("eth_chainId", [])) == CHAIN, "wrong chain")
    latest = rpc("eth_getBlockByNumber", ["latest", False])
    require(latest and latest.get("hash"), "missing latest block")
    latest_n = quantity(latest["number"])
    tag = latest["number"]
    require(backend_ok, "local backend stop not established")
    require(isinstance(evidence, dict) and evidence.get("schema") == "deopt.c12_c20.public_evidence.v1", "invalid evidence schema")
    require(evidence.get("phase") == phase and evidence.get("chainId") == CHAIN and
            evidence.get("stageId") == "C20" and evidence.get("batch") is False,
            "wrong phase, chain, operation or batch evidence")
    require(lower(evidence.get("target")) == lower(D5) and lower(evidence.get("timelock")) == lower(TIMELOCK),
            "wrong C20 target or Timelock")
    require(evidence.get("calldata") == C20_DATA and isinstance(evidence.get("eta"), int), "wrong C20 calldata/eta")
    eta = evidence["eta"]
    op = operation_id(D5, C20_DATA, eta)
    require(lower(evidence.get("operationId")) == op, "wrong C20 operation ID")
    require(call(rpc, TIMELOCK, "hashOperation(address,uint256,bytes,uint256)",
                 ("address", "uint256", "bytes", "uint256"), (D5, 0, bytes.fromhex(C20_DATA[2:]), eta), tag)
            == int(op, 16), "Timelock operation hash mismatch")
    require(call(rpc, TIMELOCK, "queuedTransactions(bytes32)", ("bytes32",),
                 (bytes.fromhex(op[2:]),), tag) == 0, "C20 only queued or requeued")
    require(lower(evidence.get("manifestSha256")) == manifest_sha, "wrong governance manifest")

    d4_receipt, d4_tx, _ = canonical_receipt(rpc, D4_DEPLOY_TX, latest_n, tag)
    require(lower(d4_receipt.get("contractAddress")) == lower(D4) and lower(d4_tx.get("from")) == lower(DEPLOYER)
            and quantity(d4_tx["nonce"]) == 3, "D4 deployment mismatch")
    d5_receipt, d5_tx, _ = canonical_receipt(rpc, evidence.get("d5DeploymentTxHash"), latest_n, tag)
    require(lower(d5_receipt.get("contractAddress")) == lower(D5) and lower(d5_tx.get("from")) == lower(DEPLOYER)
            and quantity(d5_tx["nonce"]) == 4 and lower(d5_tx.get("to") or ZERO) == ZERO,
            "D5 deployment mismatch")
    d5_input = d5_tx.get("input", "")
    require(quantity(d5_tx.get("value", "0x0")) == 0 and quantity(d5_tx.get("type", "0x0")) == 2 and
            isinstance(d5_input, str) and d5_input.startswith("0x") and
            hashlib.sha256(bytes.fromhex(d5_input[2:])).hexdigest() ==
            "bbca0c9949993ffbaaf352f4d9fd9c6bb6af0514a6e05ffecb09b986fe7a3b99" and
            "0x" + keccak(bytes.fromhex(d5_input[2:])).hex() ==
            "0xf13dc356f5a7a61cc5528392334339694a67907c05230f5955cedf0feaddfb49",
            "D5 creation input mismatch")
    code_hash(rpc, D4, tag, D4_HASH)
    code_hash(rpc, D5, tag, D5_HASH)

    qreceipt, qtx, qblock = canonical_receipt(rpc, evidence.get("c20QueueTxHash"), latest_n, tag)
    xreceipt, xtx, xblock = canonical_receipt(rpc, evidence.get("c20ExecutionTxHash"), latest_n, tag)
    governance_envelope(qtx, qreceipt, "queueTransaction(address,uint256,bytes,uint256)", D5, C20_DATA, eta)
    governance_envelope(xtx, xreceipt, "executeTransaction(address,uint256,bytes,uint256)", D5, C20_DATA, eta)
    require(qreceipt["transactionHash"] != xreceipt["transactionHash"] and
            quantity(qreceipt["blockNumber"]) < quantity(xreceipt["blockNumber"]), "C20 queued/executed in same batch")
    require(quantity(qreceipt["blockNumber"]) > quantity(d5_receipt["blockNumber"]),
            "C20 queued before canonical D5 deployment")
    log_matches(qreceipt, QUEUED_TOPIC, op, D5, C20_DATA, eta, False)
    log_matches(xreceipt, EXECUTED_TOPIC, op, D5, C20_DATA, eta, True)
    min_delay = call(rpc, TIMELOCK, "minDelay()", tag=qreceipt["blockNumber"])
    require(eta >= quantity(qblock["timestamp"]) + min_delay and
            quantity(xblock["timestamp"]) >= eta, "Timelock delay not proven")
    require(quantity(xreceipt["blockNumber"]) > quantity(d5_receipt["blockNumber"]), "C20 before D5 deployment")
    require(latest_n > quantity(xreceipt["blockNumber"]), "C20 not independently confirmed")
    delay_events = scan_logs(rpc, quantity(xreceipt["blockNumber"]), latest_n,
                             {"address": D5, "topics": [DELAY_SET_TOPIC]})
    require(isinstance(delay_events, list) and len(delay_events) == 1 and
            lower(delay_events[0].get("transactionHash")) == lower(xreceipt["transactionHash"]),
            "stale C20 proof: missing or later Risk oracle-delay change")
    require(call(rpc, D5, "owner()", tag=tag) == int(TIMELOCK, 16), "D5 owner drift")
    require(call(rpc, D5, "perpEngine()", tag=tag) == int(D4, 16), "D5 Engine drift")
    require(call(rpc, D5, "maxOracleDelay()", tag=tag) == 600, "fresh D5 oracle delay is not 600")
    require(call(rpc, D4, "riskModule()", tag=tag) == 0, "D4 Risk pointer already set")
    require(call(rpc, D4, "migrationState()", tag=tag) == 0, "D4 migration no longer OPEN")
    require(call(rpc, D4, "owner()", tag=tag) == int(TIMELOCK, 16), "D4 owner drift")
    for flag in ("tradingPaused()", "liquidationPaused()", "fundingPaused()", "collateralOpsPaused()"):
        require(call(rpc, D4, flag, tag=tag) == 1, "D4 maintenance flag off: " + flag)
    pme = call(rpc, D4, "matchingEngine()", tag=tag)
    if pme:
        require(call(rpc, "0x" + pme.to_bytes(20, "big").hex(), "paused()", tag=tag) == 1,
                "PME execution route available")
    require(call(rpc, VAULT, "isAuthorizedEngine(address)", ("address",), (D4,), tag) == 0,
            "D4 already Vault-authorized")
    require(call(rpc, INSURANCE, "isBackstopCaller(address)", ("address",), (D4,), tag) == 0,
            "D4 already Insurance-authorized")
    queued_c12 = c12_queue_events(rpc, d4_receipt["blockNumber"], tag)
    if phase == "authorization":
        require(not queued_c12, "C12 already queued before separate authorization")
    if phase == "execution":
        c12 = evidence.get("c12Queue")
        require(isinstance(c12, dict) and isinstance(c12.get("eta"), int), "missing separately queued C12")
        c12_op = operation_id(D4, C12_DATA, c12["eta"])
        require(lower(c12.get("operationId")) == c12_op, "C12 operation ID mismatch")
        qr, qt, qblock_c12 = canonical_receipt(rpc, c12.get("queueTxHash"), latest_n, tag)
        require(quantity(qr["blockNumber"]) > quantity(xreceipt["blockNumber"]),
                "C12 queued before C20 verified")
        earlier = evidence.get("c12AuthorizationReadback")
        require(isinstance(earlier, dict) and earlier.get("C12_AUTHORIZATION_READY") == "YES" and
                earlier.get("phase") == "authorization" and earlier.get("manifestSha256") == manifest_sha and
                lower(earlier.get("c20ExecutionTxHash")) == lower(xreceipt["transactionHash"]) and
                earlier.get("d5MaxOracleDelay") == 600,
                "missing independent C12 authorization readback")
        review_n = earlier.get("reviewBlock")
        require(isinstance(review_n, int) and
                quantity(xreceipt["blockNumber"]) < review_n < quantity(qr["blockNumber"]),
                "C12 queued before independently verified C20 state")
        review_block = rpc("eth_getBlockByNumber", [hex(review_n), False])
        require(review_block and lower(review_block["hash"]) == lower(earlier.get("reviewBlockHash")),
                "C12 authorization readback block noncanonical")
        require(call(rpc, D5, "maxOracleDelay()", tag=hex(review_n)) == 600 and
                call(rpc, D4, "riskModule()", tag=hex(review_n)) == 0 and
                call(rpc, D4, "migrationState()", tag=hex(review_n)) == 0,
                "C12 earlier on-chain readback invalid")
        governance_envelope(qt, qr, "queueTransaction(address,uint256,bytes,uint256)", D4, C12_DATA, c12["eta"])
        log_matches(qr, QUEUED_TOPIC, c12_op, D4, C12_DATA, c12["eta"], False)
        require(len(queued_c12) == 1 and
                lower(queued_c12[0][0].get("transactionHash")) == lower(qr["transactionHash"]) and
                queued_c12[0][1] == c12["eta"], "earlier/other C12 queue exists")
        c12_min_delay = call(rpc, TIMELOCK, "minDelay()", tag=qr["blockNumber"])
        require(c12["eta"] >= quantity(qblock_c12["timestamp"]) + c12_min_delay,
                "C12 Timelock scheduling delay not proven")
        require(call(rpc, TIMELOCK, "queuedTransactions(bytes32)", ("bytes32",),
                     (bytes.fromhex(c12_op[2:]),), tag) == 1, "C12 not queued")
        require(quantity(latest["timestamp"]) >= c12["eta"], "C12 Timelock delay not elapsed")
    require(lower(rpc("eth_getBlockByNumber", [tag, False])["hash"]) == lower(latest["hash"]),
            "read block reorg during preflight")
    return {"C12_AUTHORIZATION_READY": "YES", "phase": phase, "chainId": CHAIN,
            "reviewBlock": latest_n, "reviewBlockHash": latest["hash"], "manifestSha256": manifest_sha,
            "c20OperationId": op, "c20ExecutionTxHash": evidence["c20ExecutionTxHash"],
            "d5MaxOracleDelay": 600, "publicWriteCount": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("authorization", "execution"), required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    try:
        evidence = json.loads(args.evidence.read_text())
        report = validate(PublicRpc(configured_rpc_url()), evidence, args.phase, backend_ok=backend_stopped())
    except Exception as exc:
        print("C12_AUTHORIZATION_READY = NO; reason =", str(exc).splitlines()[0][:180])
        raise SystemExit(1) from None
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
