#!/usr/bin/env python3
"""Bind the frozen D1 review to a public deployer address using read-only RPC.

The keystore is inspected with lstat only. This tool cannot sign or send.
The original deployment package and D1 review remain immutable evidence.
"""

import hashlib
import json
import os
import stat
import sys
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak, to_checksum_address

from first_trade_live_state import PublicRpc, configured_rpc_url, pin_mode

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "artifacts/perps_v2_replacement_deployment"
KEYSTORE = Path("/home/corio/.deopt/keystores/perps-v2-replacement-deployer-base-sepolia")
ORIGINAL_SHA256 = "4d2940751d06471e3cd6ca3a298db4e68c1a4b1872d9ca51f3371b69a42ea8b9"
ADDRESS = "0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0"  # operator-provided public address
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
VAULT = "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3"
INSURANCE = "0x009f38440F058d095b61E0E2ee7fAbDF05BE7500"
PME = "0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2"
PMR = "0xAD8B0855d1fd649539A344AD594bf86929cf0FF7"
ORACLE = "0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581"
EXCLUSIONS = {
    "timelock": TIMELOCK,
    "opsSafe": SAFE,
    "lostOwner": "0xc35F7A8A103A9A4464adfaa76B9B514093D23C27",
    "runtimeExecutor": "0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8",
    "traderA": "0xff287410852b9328437eac353720e5476bc5f837",
    "traderB": "0x66858286feea78a05ea093673ea1535e0a52002d",
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def rlp_item(raw):
    if not raw:
        return b"\x80"
    if len(raw) == 1 and raw[0] < 128:
        return raw
    if len(raw) >= 56:
        raise ValueError("RLP item too long for CREATE address input")
    return bytes([0x80 + len(raw)]) + raw


def create_address(sender, nonce):
    nonce_bytes = b"" if nonce == 0 else nonce.to_bytes((nonce.bit_length() + 7) // 8, "big")
    payload = rlp_item(bytes.fromhex(sender[2:])) + rlp_item(nonce_bytes)
    if len(payload) >= 56:
        raise ValueError("RLP list too long for CREATE address input")
    return to_checksum_address(keccak(bytes([0xC0 + len(payload)]) + payload)[-20:])


def metadata_only():
    directory = KEYSTORE.parent
    parent = directory.lstat()
    item = KEYSTORE.lstat()
    if not stat.S_ISDIR(parent.st_mode) or stat.S_IMODE(parent.st_mode) != 0o700:
        raise ValueError("keystore directory metadata differs")
    if not stat.S_ISREG(item.st_mode) or stat.S_ISLNK(item.st_mode):
        raise ValueError("keystore is not a regular non-symlink file")
    if stat.S_IMODE(item.st_mode) != 0o600:
        raise ValueError("keystore mode differs")
    if parent.st_uid != os.getuid() or item.st_uid != os.getuid() or parent.st_gid != os.getgid() or item.st_gid != os.getgid():
        raise ValueError("keystore ownership differs")
    return {"path": str(KEYSTORE), "fileType": "REGULAR_NON_SYMLINK", "mode": "0600",
            "ownerUid": item.st_uid, "ownerGid": item.st_gid,
            "parentMode": "0700", "parentOwnerUid": parent.st_uid, "parentOwnerGid": parent.st_gid,
            "contentsRead": False, "decrypted": False}


def main():
    if len(sys.argv) != 1:
        raise SystemExit("this read-only binder takes no secret or transaction arguments")
    original = OUT / "deployment_package.json"
    if sha256(original) != ORIGINAL_SHA256:
        raise ValueError("original deployment package changed")
    package = json.loads(original.read_text())
    if package["sourceCommit"] != "25c36670883604c1ef5229642ee6548aea6796c3":
        raise ValueError("frozen source mismatch")
    key_meta = metadata_only()
    rpc = PublicRpc(configured_rpc_url())
    chain = int(rpc("eth_chainId", []), 16)
    if chain != 84532:
        raise ValueError("wrong chain")
    block = rpc("eth_getBlockByNumber", ["latest", False])
    tag, pin = pin_mode(rpc, block)

    def call(target, signature, arg_types=(), args=(), out_type="address"):
        data = "0x" + (keccak(text=signature)[:4] + encode(list(arg_types), list(args))).hex()
        raw = rpc("eth_call", [{"to": target, "data": data}, tag])
        return decode([out_type], bytes.fromhex(raw[2:]))[0]

    confirmed = int(rpc("eth_getTransactionCount", [ADDRESS, "latest"]), 16)
    pending = int(rpc("eth_getTransactionCount", [ADDRESS, "pending"]), 16)
    if confirmed != pending:
        raise ValueError("deployer confirmed/pending nonce conflict")
    balance = int(rpc("eth_getBalance", [ADDRESS, tag]), 16)
    if rpc("eth_getCode", [ADDRESS, tag]) != "0x":
        raise ValueError("operator address has code")
    predicted = create_address(ADDRESS, confirmed)
    if rpc("eth_getCode", [predicted, tag]) != "0x":
        raise ValueError("predicted D1 address is occupied")

    owners = [to_checksum_address(x) for x in call(SAFE, "getOwners()", out_type="address[]")]
    authority = {
        "safeOwners": owners,
        "safeThreshold": call(SAFE, "getThreshold()", out_type="uint256"),
        "safeNonce": call(SAFE, "nonce()", out_type="uint256"),
        "vaultOwner": call(VAULT, "owner()"),
        "vaultGuardian": call(VAULT, "guardian()"),
        "vaultAuthorizedEngine": call(VAULT, "isAuthorizedEngine(address)", ["address"], [ADDRESS], "bool"),
        "vaultEffectiveEngine": call(VAULT, "isEngineAuthorized(address)", ["address"], [ADDRESS], "bool"),
        "insuranceOwner": call(INSURANCE, "owner()"),
        "insuranceGuardian": call(INSURANCE, "guardian()"),
        "insuranceBackstopCaller": call(INSURANCE, "isBackstopCaller(address)", ["address"], [ADDRESS], "bool"),
        "pmeOwner": call(PME, "owner()"),
        "pmeGuardian": call(PME, "guardian()"),
        "pmeExecutor": call(PME, "isExecutor(address)", ["address"], [ADDRESS], "bool"),
        "timelockOwner": call(TIMELOCK, "owner()"),
        "timelockGuardian": call(TIMELOCK, "guardian()"),
        "timelockProposer": call(TIMELOCK, "proposers(address)", ["address"], [ADDRESS], "bool"),
        "timelockExecutor": call(TIMELOCK, "executors(address)", ["address"], [ADDRESS], "bool"),
        "pmrOwner": call(PMR, "owner()"),
        "pmrGuardian": call(PMR, "guardian()"),
        "oracleOwner": call(ORACLE, "owner()"),
        "oracleGuardian": call(ORACLE, "guardian()"),
    }
    privileged = [*owners, *(v for k, v in authority.items() if k.endswith(("Owner", "Guardian")))]
    if any(ADDRESS.lower() == v.lower() for v in [*EXCLUSIONS.values(), *privileged]):
        raise ValueError("deployer collides with known privileged address")
    if any(authority[k] for k in ("vaultAuthorizedEngine", "vaultEffectiveEngine", "insuranceBackstopCaller",
                                  "pmeExecutor", "timelockProposer", "timelockExecutor")):
        raise ValueError("deployer has a checked protocol role")
    authority["checkedRoleResult"] = "NO_INTENDED_PROTOCOL_AUTHORITY_IN_STATED_SCOPE"

    fee = {"baseFeePerGasWei": int(block["baseFeePerGas"], 16)}
    for method in ("eth_maxPriorityFeePerGas", "eth_gasPrice"):
        try:
            fee[method + "Wei"] = int(rpc(method, []), 16)
        except Exception as exc:
            fee[method + "Status"] = type(exc).__name__
    try:
        history = rpc("eth_feeHistory", [hex(5), "latest", [50]])
        fee["feeHistoryRewardMedianWei"] = [int(x[0], 16) for x in history["reward"]]
    except Exception as exc:
        fee["feeHistoryStatus"] = type(exc).__name__
    d1_size_bound = 13794  # committed D1 initcode length plus signed-envelope planning bytes
    data = "0x" + (keccak(text="getL1FeeUpperBound(uint256)")[:4] + encode(["uint256"], [d1_size_bound])).hex()
    raw = rpc("eth_call", [{"to": "0x420000000000000000000000000000000000000F", "data": data}, tag])
    fee["d1L1FeeUpperBoundQuoteWei"] = decode(["uint256"], bytes.fromhex(raw[2:]))[0]
    fee["d1SizeBoundBytes"] = d1_size_bound
    final_block = rpc("eth_getBlockByNumber", [block["number"], False])
    if final_block["hash"].lower() != block["hash"].lower():
        raise ValueError("review block identity changed")

    d1_original_path = OUT / "d1_pmr_deployment_review.json"
    if sha256(d1_original_path) != package["artifactSha256"][d1_original_path.name]:
        raise ValueError("original D1 review changed")
    d1 = json.loads(d1_original_path.read_text())
    build = json.loads((OUT / "build_manifest.json").read_text())["contracts"][0]
    artifact = json.loads((ROOT / d1["artifactPath"]).read_text())
    creation = bytes.fromhex(d1["creationTransactionData"][2:])
    encoded = encode(d1["constructorTypes"], d1["constructorArgs"])
    if (d1["contract"] != "PerpMarketRegistry" or
            d1["constructorArgs"] != [TIMELOCK] or
            d1["expectedOwner"].lower() != TIMELOCK.lower() or
            d1["expectedRuntimeHash"] != "0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5" or
            d1["creationTransactionData"] != build["creationTransactionData"] or
            d1["linkedCreationBytecodeSha256"] != hashlib.sha256(creation[:-len(encoded)]).hexdigest() or
            d1["creationTransactionDataKeccak256"] != "0x" + keccak(creation).hex() or
            d1["constructorArgsEncoded"] != "0x" + encoded.hex() or
            artifact["deployedBytecode"]["object"] == "0x"):
        raise ValueError("frozen D1 constructor/runtime evidence mismatch")
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"][2:])
    if "0x" + keccak(runtime).hex() != d1["expectedRuntimeHash"]:
        raise ValueError("frozen D1 runtime hash mismatch")

    d1["expectedPublicAddress"] = predicted
    d1["predictedAddressCodeCheck"] = {"blockNumber": int(block["number"], 16),
                                        "blockHash": block["hash"], "code": "0x", "empty": True}
    d1["signerRequirements"]["address"] = ADDRESS
    d1["signerRequirements"]["addressProvenance"] = "OPERATOR_PROVIDED_NOT_DECRYPTED_BY_BINDER"
    d1["deployerNonceObservation"] = {"confirmed": confirmed, "pending": pending}
    d1["originalReviewSha256"] = sha256(d1_original_path)
    d1["noBroadcastAuthorization"] = True
    d1_path = OUT / "d1_pmr_deployer_bound_review.json"
    save(d1_path, d1)

    gas_estimates = [3034081, 1984130, 1564663, 5679125, 2344674, 2446882]
    gas_cap_planning = 20_000_000  # wei/gas; planning only, not an approved fee field
    d1_with_margin = (gas_estimates[0] * 125 + 99) // 100
    full_with_margin = (sum(gas_estimates) * 125 + 99) // 100
    l1_reserve = 10**15  # 0.001 ETH, deliberately larger than instantaneous oracle quote
    planning = {"gasEstimates": gas_estimates, "totalGasEstimate": sum(gas_estimates),
                "gasMarginPercent": 25, "planningMaxFeePerGasWei": gas_cap_planning,
                "planningL1ReserveWei": l1_reserve,
                "d1GasWithMargin": d1_with_margin, "fullGasWithMargin": full_with_margin,
                "d1RequirementWei": d1_with_margin * gas_cap_planning + l1_reserve,
                "fullSequenceRequirementWei": full_with_margin * gas_cap_planning + l1_reserve,
                "recommendedMinimumBalanceWei": 5 * 10**15,
                "fundedForD1": balance >= d1_with_margin * gas_cap_planning + l1_reserve,
                "fundedForFullSequence": balance >= 5 * 10**15,
                "feeQuote": fee, "feeEnvelopeAuthorized": False,
                "notes": "Planning only. Base L1 quote is an instantaneous observation, not an on-chain maximum or future guarantee."}
    bound = {"schema": "deopt.perps_v2_replacement_deployment.signer_binding.v1",
             "originalPackageSha256": ORIGINAL_SHA256,
             "originalPackagePath": "artifacts/perps_v2_replacement_deployment/deployment_package.json",
             "sourceCommit": package["sourceCommit"], "chainId": chain,
             "reviewBlockNumber": int(block["number"], 16), "reviewBlockHash": block["hash"], "pinMode": pin,
             "deployerAddress": ADDRESS, "deployerAddressProvenance": "OPERATOR_PROVIDED_NOT_LOCALLY_DECRYPTED",
             "keystoreMetadata": key_meta,
             "confirmedNonce": confirmed, "pendingNonce": pending, "balanceWei": balance, "deployerCode": "0x",
             "d1PredictedAddress": predicted, "d1PredictedCode": "0x",
             "d1ReviewPath": d1_path.relative_to(ROOT).as_posix(), "d1ReviewSha256": sha256(d1_path),
             "authorityExclusions": authority, "knownAddressExclusions": EXCLUSIONS,
             "planning": planning, "d2ThroughD6": "CONDITIONAL_ON_PRECEDING_CANONICAL_RECEIPTS",
             "d6ExpectedRuntimeHash": "CONDITIONAL",
             "signerBindingResult": "PASS_UNFUNDED", "publicBroadcastAuthorized": False,
             "fundingAuthorized": False, "timelockOperationAuthorized": False}
    bound_path = OUT / "deployment_package_signer_bound.json"
    save(bound_path, bound)
    print(json.dumps({"chainId": chain, "blockNumber": bound["reviewBlockNumber"],
                      "blockHash": block["hash"], "signer": ADDRESS, "nonce": confirmed,
                      "balanceWei": balance, "d1PredictedAddress": predicted,
                      "d1ReviewSha256": sha256(d1_path), "packageSha256": sha256(bound_path),
                      "fundedForD1": planning["fundedForD1"]}, sort_keys=True))


if __name__ == "__main__":
    main()
