#!/usr/bin/env python3
"""Read-only Base Sepolia fee envelope for the unsigned V23 CREATE package."""

import json
import pathlib
import re
import sys
import urllib.request

step = int(sys.argv[1]) if len(sys.argv) == 2 else 1
if step not in (1, 2, 3):
    raise SystemExit('Usage: options-v23-fee-preflight.py [1|2|3]')


def hide_errors(kind, _value, _traceback):
    print("FEE_PREFLIGHT=STOP", kind.__name__)


sys.excepthook = hide_errors
root = pathlib.Path(__file__).resolve().parents[1]
values = {}
for line in (root / ".env.base-sepolia").read_text().splitlines():
    match = re.match(r"^(?:export )?([A-Z][A-Z0-9_]*)=(.*)$", line)
    if match:
        values[match.group(1)] = match.group(2).strip().strip('"\'')
url = values["RPC_URL"]
package = json.loads((root / "artifacts/options_v23_inactive_deployment/unsigned_transactions.json").read_text())
count = 0


def rpc(method, params):
    global count
    count += 1
    payload = json.dumps({"jsonrpc": "2.0", "id": count, "method": method, "params": params}).encode()
    request = urllib.request.Request(url, payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=25) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError("RPC_ERROR")
    return result["result"]


oracle = "0x420000000000000000000000000000000000000F"
block = rpc("eth_getBlockByNumber", ["latest", False])
number = block["number"]
chain = int(rpc("eth_chainId", []), 16)
gas_price = int(rpc("eth_gasPrice", []), 16)
base_fee = int(block.get("baseFeePerGas") or "0x0", 16)
balance = int(rpc("eth_getBalance", [package["transactions"][0]["from"], number]), 16)
spent = package['deployerInitialBalanceWei'] - balance
code = rpc("eth_getCode", [oracle, number])
print("CHAIN_ID", chain, "BLOCK", int(number, 16), "BASE_FEE_WEI", base_fee, "GAS_PRICE_WEI", gas_price)
print("GPO_CODE_BYTES", (len(code) - 2) // 2)


def call_uint(selector, value):
    data = selector + format(value, "064x")
    return int(rpc("eth_call", [{"to": oracle, "data": data}, number]), 16)


l1_total = 0
operator_total = 0
l2_total = 0
price_ok = True
for transaction in package["transactions"][step-1:]:
    # +300 bytes covers typed-envelope, address, signature and RLP overhead.
    unsigned_size_bound = (len(transaction["data"]) - 2) // 2 + 300
    l1_upper = call_uint("0xf1c7a58b", unsigned_size_bound)
    operator_upper = call_uint("0x275aedd2", transaction["gasLimit"])
    l2_upper = transaction["gasLimit"] * int(transaction["maxFeePerGasWei"])
    l1_total += l1_upper
    operator_total += operator_upper
    l2_total += l2_upper
    price_ok &= base_fee + int(transaction["maxPriorityFeePerGasWei"]) <= int(transaction["maxFeePerGasWei"])
    price_ok &= gas_price <= int(transaction["maxFeePerGasWei"])
    print("FEE", transaction["contract"], "L2_MAX_WEI", l2_upper, "L1_UPPER_WEI", l1_upper,
          "OPERATOR_UPPER_WEI", operator_upper)

reserve = package["l1AndOperatorFeeReserveWei"]
ceiling = package["authorizedAllInclusiveCeilingWei"]
envelope = spent + l2_total + reserve
checks = {
    "chain": chain == 84532,
    "gpo_code": code != "0x",
    "network_executable": price_ok,
    "l2_manifest": l2_total == sum(t['gasLimit']*int(t['maxFeePerGasWei']) for t in package['transactions'][step-1:]),
    "prior_spend_nonnegative": spent >= 0,
    "l1_operator_within_reserve": l1_total + operator_total <= reserve,
    "all_in_within_ceiling": envelope <= ceiling,
    "deployer_funded": balance >= l2_total + reserve,
}
print("SPENT_SO_FAR_WEI", spent, "TOTAL_L2_MAX_WEI", l2_total, "TOTAL_L1_UPPER_WEI", l1_total,
      "TOTAL_OPERATOR_UPPER_WEI", operator_total, "L1_RESERVE_WEI", reserve,
      "ALL_IN_ENVELOPE_WEI", envelope, "AUTHORIZED_CEILING_WEI", ceiling)
for name, passed in checks.items():
    print("CHECK", name, "PASS" if passed else "STOP")
print("FEE_PREFLIGHT", "PASS" if all(checks.values()) else "STOP")
if not all(checks.values()):
    sys.exit(2)
