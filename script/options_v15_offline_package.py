#!/usr/bin/env python3
"""Offline, unsigned V15 deployment manifest and inert Timelock calldata.

Consumes a previously simulated Foundry dry-run. --nonce must come from a
fresh *pending* RPC read at the operator preflight; no RPC or signer is used.
The output is a proposal, never an instruction to broadcast automatically.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRY_RUN = ROOT / "broadcast/DeployOptionsIsolatedV14.s.sol/84532/dry-run/run-latest.json"
NAMES = (
    "OracleRouter", "CollateralVault", "OptionProductRegistry", "MarginEngine",
    "RiskModule", "OptionMatchingEngine", "FeesManagerV2", "InsuranceFund",
    "VerifiedOptionSettlementOwner",
)
TX_LIMIT = 16_777_216
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
MUSDC = "0x6eAe407f5640B006faC9965182e238582A3B412E"
MWETH = "0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02"
ETH_CHAINLINK_SOURCE = "0x09bcd126feb91e13007b2c69644c12ab56260473"
ETH_PYTH_SOURCE = "0x1a6302edc9e9dc5efae8dd5e931089ac6dc5322b"
LINKED_LIBRARIES = {
    "MarginEngineLiquidationLib": {
        "address": "0xb72a7bc82747ce2a0e11df1307b8cb7ef085cc18",
        "runtime_sha256": "ac277d02575e7d450f9ac38113cdedb5c00c8d2c9b4bde32b2ecf929ad42712e",
    },
    "MarginEngineSeizureLib": {
        "address": "0xeb7530cf6f51930681545f90a18817cf8ff55b2c",
        "runtime_sha256": "fc7bf1916c20aae5bd1a67407310a7ee073aaeaf3762851730575db33a7dc2a5",
    },
}


def cast(*args: str) -> str:
    return subprocess.run(["cast", *args], check=True, capture_output=True, text=True).stdout.strip()


def checked_address(value: str) -> str:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
        raise ValueError("invalid address")
    return value


def linked_creation(template: str, references: dict, initcode: bytes) -> dict:
    """Match compiled CREATE bytecode while allowing only declared link slots."""
    raw = template.removeprefix("0x")
    if len(initcode) * 2 < len(raw):
        raise ValueError("CREATE initcode shorter than compiled artifact")
    observed = initcode.hex()[:len(raw)]
    linked = {}
    for source, libraries in references.items():
        for library, slots in libraries.items():
            addresses = set()
            for slot in slots:
                start, length = slot["start"] * 2, slot["length"] * 2
                addresses.add(checked_address("0x" + observed[start:start + length]).lower())
                width = length * 2
                raw = raw[:start] + "?" * width + raw[start + width:]
                observed = observed[:start] + "?" * width + observed[start + width:]
            if len(addresses) != 1:
                raise ValueError(f"inconsistent linked addresses for {source}:{library}")
            linked[f"{source}:{library}"] = addresses.pop()
    if raw.lower() != observed.lower():
        raise ValueError("dry-run bytecode differs from current compiled artifact")
    return linked


def package(deployer: str, nonce: int, eta: int, reference_timestamp: int, dry_run: Path) -> dict:
    deployer = checked_address(deployer)
    if nonce < 0 or eta <= 0:
        raise ValueError("nonce and eta must be positive")
    if eta < reference_timestamp + 86_400:
        raise ValueError("eta violates the observed 24-hour Timelock minimum")
    if eta > reference_timestamp + 7 * 86_400:
        raise ValueError("eta exceeds the seven-day review horizon; refresh the preflight")
    source = json.loads(dry_run.read_text())
    if source.get("chain") != 84532:
        raise ValueError("dry-run is not Base Sepolia")
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, check=True,
                          capture_output=True, text=True).stdout.strip()
    simulated_commit = str(source.get("commit", ""))
    if not re.fullmatch(r"[0-9a-f]{7,40}", simulated_commit):
        raise ValueError("dry-run source commit is missing")
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", simulated_commit, head], cwd=ROOT
    )
    if ancestor.returncode != 0:
        raise ValueError("dry-run source is not an ancestor of current HEAD; re-simulate")
    original_script = subprocess.run(
        ["git", "show", f"{simulated_commit}:script/DeployOptionsIsolatedV14.s.sol"],
        cwd=ROOT, check=True, capture_output=True,
    ).stdout
    current_script = (ROOT / "script/DeployOptionsIsolatedV14.s.sol").read_bytes()
    if original_script != current_script:
        raise ValueError("deployment script changed since dry-run; re-simulate")
    creates = source["transactions"]
    if len(creates) != len(NAMES) or tuple(t.get("contractName") for t in creates) != NAMES:
        raise ValueError("expected nine ordered CREATE transactions")
    first = creates[0]["transaction"]
    dry_nonce = int(first["nonce"], 16)
    dry_deployer = first["from"]
    if dry_deployer.lower() != deployer.lower():
        raise ValueError("deployer differs from dry-run; re-simulate with the actual deployer")
    if int(first["chainId"], 16) != 84532:
        raise ValueError("wrong transaction chain")
    manifest = []
    addresses = {}
    for index, (name, record) in enumerate(zip(NAMES, creates, strict=True)):
        tx = record["transaction"]
        gas = int(tx["gas"], 16)
        if tx.get("from", "").lower() != deployer.lower() or tx.get("transactionType") not in (None, "CREATE"):
            raise ValueError("unexpected creator or transaction type")
        if record["transactionType"] != "CREATE" or int(tx["nonce"], 16) != dry_nonce + index:
            raise ValueError("dry-run nonce sequence is not consecutive")
        if gas > TX_LIMIT:
            raise ValueError(f"{name} exceeds per-transaction gas limit")
        predicted = cast("compute-address", "--nonce", str(nonce + index), deployer).split()[-1]
        checked_address(predicted)
        if nonce == dry_nonce and predicted.lower() != record["contractAddress"].lower():
            raise ValueError("CREATE prediction differs from dry-run")
        initcode = bytes.fromhex(tx["input"].removeprefix("0x"))
        artifact_path = ROOT / "out" / f"{name}.sol" / f"{name}.json"
        artifact = json.loads(artifact_path.read_text())
        template = artifact["bytecode"]["object"]
        linked = linked_creation(template, artifact["bytecode"].get("linkReferences", {}), initcode)
        if name == "MarginEngine":
            direct = [address for key, address in linked.items()
                      if key.endswith(":MarginEngineLiquidationLib")]
            if direct != [LINKED_LIBRARIES["MarginEngineLiquidationLib"]["address"]]:
                raise ValueError("MarginEngine liquidation library differs from verified Base Sepolia address")
            # SeizureLib is linked by the pre-deployed LiquidationLib, not
            # directly by MarginEngine; its runtime hash needs an RPC check.
        runtime_template = artifact["deployedBytecode"]["object"]
        runtime_size = len(runtime_template.removeprefix("0x")) // 2
        if runtime_size > 24_576:
            raise ValueError(f"{name} runtime exceeds EIP-170 limit")
        addresses[name] = predicted
        manifest.append({
            "step": index + 1, "contract": name, "nonce": nonce + index,
            "predicted_address": predicted, "gas_limit_from_fork": gas,
            "initcode_sha256": hashlib.sha256(initcode).hexdigest(),
            "compiled_template_sha256": hashlib.sha256(template.encode()).hexdigest(),
            "linked_libraries_require_onchain_code_verification": linked,
            "runtime_bytecode_size": runtime_size,
        })
    if len({a.lower() for a in addresses.values()}) != 9:
        raise ValueError("CREATE address collision")

    # These operations keep the new stack inert. The economic configuration,
    # funding, series creation and activation require separate approval.
    actions = [
        ("inert", "pause_new_registry_creation", "OptionProductRegistry", "pauseCreation()", []),
        ("inert", "pause_new_registry_settlement", "OptionProductRegistry", "pauseSettlement()", []),
        ("inert", "pause_new_matching", "OptionMatchingEngine", "pause()", []),
        ("inert", "pause_new_vault", "CollateralVault", "setEmergencyModes(bool,bool,bool,bool)", ["true"] * 4),
        ("inert", "set_router_max_age", "OracleRouter", "setMaxOracleDelay(uint32)", ["1500"]),
        ("inert", "register_eth_feed_inactive", "OracleRouter",
         "setFeed(address,address,address,address,uint32,uint16,bool)",
         [MWETH, MUSDC, ETH_CHAINLINK_SOURCE, ETH_PYTH_SOURCE, "1500", "100", "false"]),
    ]
    safe = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
    for target_name in (
        "OptionProductRegistry", "CollateralVault", "OptionMatchingEngine",
        "OracleRouter", "MarginEngine", "RiskModule", "InsuranceFund",
    ):
        actions.append(("guardian", f"guardian_{target_name}", target_name,
                        "setGuardian(address)", [safe]))
    actions.extend([
        ("candidate_risk_unapproved", "allow_test_usdc", "CollateralVault",
         "setCollateralToken(address,bool,uint8,uint16)", [MUSDC, "true", "6", "10000"]),
        ("candidate_risk_unapproved", "vault_deposit_cap_2000_musdc", "CollateralVault",
         "setTokenDepositCap(address,uint256)", [MUSDC, "2000000000"]),
        ("candidate_risk_unapproved", "vault_margin_engine", "CollateralVault",
         "setMarginEngine(address)", [addresses["MarginEngine"]]),
        ("candidate_risk_unapproved", "vault_risk_module", "CollateralVault",
         "setRiskModule(address)", [addresses["RiskModule"]]),
        ("candidate_risk_unapproved", "vault_insurance", "CollateralVault",
         "setAuthorizedEngine(address,bool)", [addresses["InsuranceFund"], "true"]),
        ("candidate_risk_unapproved", "insurance_token", "InsuranceFund",
         "setTokenAllowed(address,bool)", [MUSDC, "true"]),
        ("candidate_risk_unapproved", "insurance_backstop", "InsuranceFund",
         "setBackstopCaller(address,bool)", [addresses["MarginEngine"], "true"]),
        ("candidate_risk_unapproved", "registry_settlement_asset", "OptionProductRegistry",
         "setSettlementAssetAllowed(address,bool)", [MUSDC, "true"]),
        ("candidate_risk_unapproved", "registry_eth_risk", "OptionProductRegistry",
         "setUnderlyingConfig(address,(address,uint64,uint64,uint64,uint64,bool))",
         [MWETH, f'({addresses["OracleRouter"]},3000,3000,0,2000,true)']),
        ("candidate_risk_unapproved", "registry_option_margin", "OptionProductRegistry",
         "setOptionRiskConfig(address,(uint128,uint32,uint32,bool))",
         [MWETH, "(10000000,12000,20000,true)"]),
        ("candidate_risk_unapproved", "risk_base_params", "RiskModule",
         "setRiskParams(address,uint256,uint256)", [MUSDC, "10000000", "12000"]),
        ("candidate_risk_unapproved", "risk_sync_tokens", "RiskModule",
         "syncCollateralTokensFromVault()", []),
        ("candidate_risk_unapproved", "margin_risk_module", "MarginEngine",
         "setRiskModule(address)", [addresses["RiskModule"]]),
        ("candidate_risk_unapproved", "margin_sync_risk", "MarginEngine",
         "syncRiskParamsFromRiskModule()", []),
        ("candidate_risk_unapproved", "margin_matching", "MarginEngine",
         "setMatchingEngine(address)", [addresses["OptionMatchingEngine"]]),
        ("candidate_risk_unapproved", "margin_insurance", "MarginEngine",
         "setInsuranceFund(address)", [addresses["InsuranceFund"]]),
        ("candidate_risk_unapproved", "fees_consumer", "FeesManagerV2",
         "setFeeConsumer(address,bool)", [addresses["MarginEngine"], "true"]),
        ("candidate_risk_unapproved", "margin_fees_v2", "MarginEngine",
         "setFeesManagerV2(address)", [addresses["FeesManagerV2"]]),
        ("candidate_risk_unapproved", "margin_use_fees_v2", "MarginEngine",
         "setUseFeesManagerV2(bool)", ["true"]),
        ("ownership_unapproved", "registry_transfer_to_verifier", "OptionProductRegistry",
         "transferOwnership(address)", [addresses["VerifiedOptionSettlementOwner"]]),
        ("ownership_unapproved", "verifier_accept_registry", "VerifiedOptionSettlementOwner",
         "acceptRegistryOwnership()", []),
    ])
    expiry = 1_795_780_800  # 2026-11-27 12:00 UTC; proposal only
    strike_1e8 = 225_000_000_000  # $2250; proposal only
    option_tuple = cast("abi-encode", "f(address,address,uint64,uint64,uint128,bool,bool)",
                        MWETH, MUSDC, str(expiry), str(strike_1e8), "100000000", "true", "true")
    proposed_option_id = int(cast("keccak", option_tuple), 16)
    actions.extend([
        ("series_unapproved", "create_inactive_eth_call", "VerifiedOptionSettlementOwner",
         "createInactiveCallSeries(address,uint64,uint64)",
         [MWETH, str(expiry), str(strike_1e8)]),
        ("series_unapproved", "cap_short_oi_one_contract", "MarginEngine",
         "setSeriesShortOpenInterestCap(uint256,uint256)", [str(proposed_option_id), "1"]),
    ])
    operations = []
    for phase, label, target_name, signature, arguments in actions:
        target = addresses[target_name]
        data = cast("calldata", signature, *arguments)
        artifact = json.loads((ROOT / "out" / f"{target_name}.sol" / f"{target_name}.json").read_text())
        selectors = {"0x" + value.lower() for value in artifact.get("methodIdentifiers", {}).values()}
        if data[:10].lower() not in selectors:
            raise ValueError(f"{label}: target ABI has no matching function selector")
        encoded = cast("abi-encode", "f(address,uint256,bytes,uint256)", target, "0", data, str(eta))
        operation_id = cast("keccak", encoded)
        queue_data = cast("calldata", "queueTransaction(address,uint256,bytes,uint256)", target, "0", data, str(eta))
        execute_data = cast("calldata", "executeTransaction(address,uint256,bytes,uint256)", target, "0", data, str(eta))
        operations.append({
            "phase": phase, "approval_required": True,
            "label": label, "target": target, "value_wei": 0,
            "data": data, "eta": eta, "timelock_operation_id": operation_id,
            "queue_to": TIMELOCK, "queue_calldata": queue_data,
            "execute_to": TIMELOCK, "execute_calldata": execute_data,
        })
    return {
        "status": "UNSIGNED_OFFLINE_PROPOSAL", "chain_id": 84532,
        "deployer": deployer, "pending_nonce_supplied": nonce,
        "reference_block_timestamp_supplied": reference_timestamp,
        "timelock_eta": eta, "timelock_expiry": eta + 14 * 86_400,
        "dry_run_nonce": dry_nonce, "dry_run_commit": source.get("commit"),
        "gas_per_transaction_ceiling": TX_LIMIT,
        "deployment_gas_limit_sum": sum(m["gas_limit_from_fork"] for m in manifest),
        "inert_configuration_direct_call_gas_fork": 369_966,
        "remaining_configuration_gas": "NOT_MEASURED_ON_FRESH_FORK",
        "proposed_eth_call": {"expiry_unix": expiry, "strike_1e8": strike_1e8,
                              "raw_option_id": str(proposed_option_id),
                              "status": "OPERATOR_APPROVAL_REQUIRED"},
        "contracts": manifest, "timelock_operations_by_dependency_order": operations,
        "linked_libraries_must_be_rechecked_onchain": LINKED_LIBRARIES,
        "halt_before": ["series_creation", "funding", "matching_executor_enable", "economic_activation"],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployer", required=True)
    parser.add_argument("--pending-nonce", type=int, required=True)
    parser.add_argument("--eta", type=int, required=True)
    parser.add_argument("--reference-timestamp", type=int, required=True)
    parser.add_argument("--dry-run", type=Path, default=DRY_RUN)
    args = parser.parse_args()
    print(json.dumps(package(args.deployer, args.pending_nonce, args.eta,
                             args.reference_timestamp, args.dry_run), indent=2))


if __name__ == "__main__":
    main()
