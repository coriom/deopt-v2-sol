#!/usr/bin/env python3
"""Build a non-executable, local-only replacement deployment package.

No RPC, keystore, signer, or transaction transport is used here. Future
addresses and calldata are deliberately left conditional where the deployment
signer and canonical preceding receipts do not exist yet.
"""

import hashlib
import json
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "artifacts/perps_v2_replacement_deployment"
FROZEN = ROOT / "artifacts/perps_v2_replacement"
SOURCE_COMMIT = "25c36670883604c1ef5229642ee6548aea6796c3"
TIMELOCK = "0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588"
SAFE = "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46"
VAULT = "0x00340C360353a5AB784c5Bc5c44322A6AF0625D3"
INSURANCE = "0x009f38440F058d095b61E0E2ee7fAbDF05BE7500"
CLEARING = "0x54d49c088DD27cFc82685b867c182b4bB4aC435c"
NEW = "0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15"
ORACLE = "0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581"
TOKEN = "0x6eAe407f5640B006faC9965182e238582A3B412E"
EXECUTOR = "0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8"
LIBRARIES = {
    "PerpEngineSeizureLib": "0xf0C5652277CF88B508E05F7aB54949fCDF0360A5",
    "PerpEngineLiquidationLib": "0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D",
}
NAMES = ("PerpMarketRegistry", "FeesManagerV2", "CollateralSeizer", "PerpEngineV2",
         "PerpRiskModule", "PerpMatchingEngineV2")
FILES = ("source", "authority", "pmr_config", "fee_liability", "executor", "migration")
EXPECTED = (
    "2526f2fcfa8386b34d6b44638929e8b68d90875754d4dce636f0924ccdcdfc1b",
    "47c483b8ca5c8aec7e2107870124a9bcd2ddf4750ca13ba6c445a334f7c3e713",
    "accf5770fed96c52cb869c868822697e98a3acc2b6b9f35ab6922e2fc945d20c",
    "5bf7cb0159054f4127e49501009c793fed9a240fa2d9a6fab8558c02fa9953fe",
    "960a12192a8aca4520a647b54d83e1f4e5087b2bd52a121c520b9ed80e97b361",
    "4bfcf23520716532acf5aef967042f3fe7b19ca2182b19dc7e698c332d59337e",
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write(name, value):
    path = OUT / name
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    return sha(path.read_bytes())


def render_bytecode(section):
    template = section["object"][2:]
    for libraries in section["linkReferences"].values():
        for name, references in libraries.items():
            address = LIBRARIES[name][2:].lower()
            for ref in references:
                if ref["length"] != 20:
                    raise ValueError("non-address link")
                start = ref["start"] * 2
                template = template[:start] + address + template[start + 40:]
    return bytes.fromhex(template)


def abi_type(item):
    if item["type"].startswith("tuple"):
        return "(" + ",".join(abi_type(x) for x in item["components"]) + ")" + item["type"][5:]
    return item["type"]


def encode_call(contract, method, args):
    abi = json.loads((ROOT / f"out/{contract}.sol/{contract}.json").read_text())["abi"]
    matches = [x for x in abi if x["type"] == "function" and x["name"] == method and len(x["inputs"]) == len(args)]
    if len(matches) != 1:
        raise ValueError("ambiguous function " + contract + "." + method)
    inputs = matches[0]["inputs"]
    types = [abi_type(x) for x in inputs]
    signature = method + "(" + ",".join(types) + ")"
    if any(isinstance(value, str) and value.startswith("D") and value.endswith("_CANONICAL_ADDRESS") for value in args):
        return signature, None
    encoded = encode(types, args)
    if jsonable(decode(types, encoded)) != jsonable(args):
        raise ValueError("ABI round-trip mismatch for " + signature)
    return signature, "0x" + (keccak(text=signature)[:4] + encoded).hex()


def jsonable(value):
    if isinstance(value, bytes):
        return "0x" + value.hex()
    if isinstance(value, str) and value.startswith("0x"):
        return value.lower()
    if isinstance(value, (tuple, list)):
        return [jsonable(x) for x in value]
    return value


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, expected in zip(FILES, EXPECTED):
        actual = sha((FROZEN / f"{name}_manifest.json").read_bytes())
        if actual != expected:
            raise ValueError(f"frozen manifest changed: {name}")
    source = json.loads((FROZEN / "source_manifest.json").read_text())
    live = json.loads((OUT / "live_shared_state.json").read_text())
    if live["chainId"] != 84532 or live["pmr"]["refresh"] != "PASS":
        raise ValueError("live PMR/chain check failed")
    if live["vaultInsuranceAcl"]["status"] != "PASS":
        raise ValueError("live Insurance Vault ACL check failed")
    risk = "0xc0f019005a25524a34f2ee8839dcdcc50715dd7b"
    constructors = (
        [TIMELOCK],
        [TIMELOCK, TIMELOCK],
        [TIMELOCK, VAULT, ORACLE, risk],
        [TIMELOCK, "D1_CANONICAL_ADDRESS", VAULT, ORACLE],
        [TIMELOCK, VAULT, "D4_CANONICAL_ADDRESS", ORACLE, TOKEN],
        [TIMELOCK, "D4_CANONICAL_ADDRESS"],
    )
    initial = (
        {"guardian": "0x0000000000000000000000000000000000000000", "paused": False,
         "creationPaused": False, "configPaused": False, "nextMarketId": 1},
        {"feeRecipient": TIMELOCK, "protocolFeeVault": "0x0000000000000000000000000000000000000000",
         "rebateBudget": 0, "merkleRoot": "0x" + "00" * 32},
        {"guardian": "NOT_SUPPORTED", "oracleMaxDelay": 600, "vault": VAULT,
         "oracle": ORACLE, "riskModule": risk},
        {"guardian": TIMELOCK, "tradingPaused": False, "liquidationPaused": False,
         "fundingPaused": False, "collateralOpsPaused": False,
         "migrationState": 0, "migrationSnapshotHash": "0x" + "00" * 32,
         "marketRegistry": "D1_CANONICAL_ADDRESS", "vault": VAULT, "oracle": ORACLE},
        {"guardian": "0x0000000000000000000000000000000000000000",
         "maxOracleDelay": 0, "perpEngine": "D4_CANONICAL_ADDRESS"},
        {"guardian": "0x0000000000000000000000000000000000000000",
         "paused": False, "perpEngine": "D4_CANONICAL_ADDRESS",
         "ownerIsExecutor": True},
    )
    required = (
        live["timelock"]["owner"].lower() == SAFE.lower(),
        live["timelock"]["minDelay"] == 86400,
        live["timelock"]["safeProposer"], live["timelock"]["safeExecutor"],
        live["safe"]["threshold"] == 2 and len(live["safe"]["owners"]) == 3,
        live["safe"]["modules"] == [[], "0x0000000000000000000000000000000000000001"],
        live["vault"]["owner"].lower() == TIMELOCK.lower(),
        live["insurance"]["owner"].lower() == TIMELOCK.lower(),
        live["oracle"]["owner"].lower() == TIMELOCK.lower(),
        live["clearing"]["vault"].lower() == VAULT.lower(),
        live["vault"]["clearingLedger"] == 1_000_000_000,
        live["vault"]["strandedNew"], live["insurance"]["strandedNewBackstop"],
        live["legacyCollateralRisk"]["address"].lower() == risk.lower(),
        live["legacyCollateralRisk"]["owner"].lower() == TIMELOCK.lower(),
        live["legacyCollateralRisk"]["vault"].lower() == VAULT.lower(),
        live["legacyCollateralRisk"]["oracle"].lower() == ORACLE.lower(),
        live["legacyFmv2"]["feeRecipient"].lower() == TIMELOCK.lower(),
    )
    if not all(required):
        raise ValueError("shared governance or dependency drift")
    rehearsal = json.loads((OUT / "local_rehearsal.json").read_text())
    if rehearsal["result"] != {"passed": 1, "failed": 0, "skipped": 0}:
        raise ValueError("local rehearsal failed")
    shared_runtime = json.loads((OUT / "shared_runtime_comparison.json").read_text())
    for name in ("vault", "insurance"):
        record = shared_runtime[name]
        if record["liveRuntimeKeccak256"] != live["runtimeIdentity"][name]["keccak256"] or \
                record["liveRuntimeBytes"] != live["runtimeIdentity"][name]["bytes"]:
            raise ValueError("shared runtime evidence mismatch: " + name)
    current_vault = json.loads((ROOT / "out/CollateralVault.sol/CollateralVault.json").read_text())
    if "0x" + keccak(bytes.fromhex(current_vault["deployedBytecode"]["object"][2:])).hex() != \
            shared_runtime["vault"]["currentArtifactRuntimeKeccak256"]:
        raise ValueError("current Vault artifact hash drift")
    build = {"schema": "deopt.perps_v2_replacement_deployment.build.v1",
             "sourceCommit": SOURCE_COMMIT, "frozenManifestSha256": dict(zip(FILES, EXPECTED)),
             "libraryAddressPolicy": "reuse previously deployed Base Sepolia libraries only after exact pinned-code verification",
             "libraries": LIBRARIES, "contracts": []}
    stages = []
    for i, (name, args, state) in enumerate(zip(NAMES, constructors, initial), 1):
        artifact = json.loads((ROOT / f"out/{name}.sol/{name}.json").read_text())
        frozen = source["contracts"][i - 1]
        if frozen["name"] != name:
            raise ValueError("frozen source order changed")
        metadata = artifact["metadata"]
        if metadata["compiler"]["version"] != frozen["compilerVersion"]:
            raise ValueError("compiler drift")
        for dep in frozen["sourceDependencies"]:
            if sha((ROOT / dep["path"]).read_bytes()) != dep["sha256"][2:]:
                raise ValueError("source dependency drift")
        if sha(artifact["bytecode"]["object"].encode()) != frozen["creationBytecodeTemplateSha256"][2:]:
            raise ValueError("creation artifact drift")
        creation = render_bytecode(artifact["bytecode"])
        runtime_template = render_bytecode(artifact["deployedBytecode"])
        immutable_refs = artifact["deployedBytecode"].get("immutableReferences", {})
        runtime_hash = None if immutable_refs else "0x" + keccak(runtime_template).hex()
        observed = rehearsal["stages"][i - 1]
        if observed["stage"] != f"D{i}" or (runtime_hash is not None and observed["runtimeKeccak256"] != runtime_hash):
            raise ValueError("local runtime hash mismatch")
        inputs = next(x["inputs"] for x in artifact["abi"] if x["type"] == "constructor")
        types = [abi_type(x) for x in inputs]
        exact = all(isinstance(x, str) and x.startswith("0x") for x in args)
        encoded = encode(types, args) if exact else None
        tx_data = creation + encoded if encoded is not None else None
        record = {
            "stage": f"D{i}", "contract": name,
            "artifactPath": f"out/{name}.sol/{name}.json",
            "sourceFile": frozen["source"], "compilerVersion": frozen["compilerVersion"],
            "optimizer": frozen["optimizer"], "viaIR": frozen["viaIR"],
            "evmVersion": metadata["settings"]["evmVersion"],
            "metadataSettings": metadata["settings"].get("metadata"),
            "sourceDependencies": frozen["sourceDependencies"],
            "constructorAbi": frozen["constructorAbi"],
            "creationLinkReferences": artifact["bytecode"]["linkReferences"],
            "runtimeLinkReferences": artifact["deployedBytecode"]["linkReferences"],
            "runtimeImmutableReferences": immutable_refs,
            "linkedCreationBytecode": "0x" + creation.hex(),
            "linkedCreationBytecodeSha256": sha(creation),
            "linkedCreationBytecodeKeccak256": "0x" + keccak(creation).hex(),
            "linkedRuntimeTemplateSha256": sha(runtime_template),
            "linkedRuntimeTemplateKeccak256": None if immutable_refs else runtime_hash,
            "runtimeHashKind": "CONSTRUCTOR_DEPENDENT" if immutable_refs else "CONSTRUCTOR_INDEPENDENT",
            "constructorArgs": args, "constructorTypes": types,
            "constructorArgsEncoded": None if encoded is None else "0x" + encoded.hex(),
            "creationTransactionData": None if tx_data is None else "0x" + tx_data.hex(),
            "creationTransactionDataKeccak256": None if tx_data is None else "0x" + keccak(tx_data).hex(),
            "expectedOwner": TIMELOCK, "expectedPendingOwner": "0x0000000000000000000000000000000000000000"
            if name != "FeesManagerV2" else "NOT_APPLICABLE_ONE_STEP_OWNER",
            "initialState": state, "expectedPublicAddress": "UNRESOLVED_NO_DEPLOYMENT_SIGNER",
            "expectedRuntimeHash": runtime_hash,
            "localFixtureRuntimeHash": observed["runtimeKeccak256"],
            "localFixtureAddress": observed["localAddress"],
            "localGasObservedExcludingIntrinsic": observed["localGasObserved"],
            "readOnlyRpcGasEstimate": observed["rpcGasEstimate"],
            "gasEstimateAddressScope": observed["estimateInput"],
        }
        build["contracts"].append(record)
        stages.append({k: v for k, v in record.items() if k not in ("linkedCreationBytecode", "sourceDependencies")})
        file_name = ("d1_pmr_deployment_review.json" if i == 1 else
                     ["", "", "d2_fmv2_deployment_template.json", "d3_seizer_deployment_template.json",
                      "d4_engine_deployment_template.json", "d5_risk_deployment_template.json",
                      "d6_pme_deployment_template.json"][i])
        stages[-1]["postflight"] = ["canonical receipt status 1", "exact constructor data and creator nonce",
                                     "code/runtime hash", "Timelock owner and zero pending owner where supported",
                                     "initial guardian, pause state and constructor pointers"]
        stages[-1]["signerRequirements"] = {
            "role": "contract creation and gas payment only", "address": "UNDESIGNATED",
            "mustNotBe": ["owner", "guardian", "executor", "migration authority", "admin"],
            "beforePublicReview": ["operator designates existing suitable signer", "fresh chain and signer address verification",
                                   "confirmed/pending nonce equality", "balance and EIP-1559/L1 fee review",
                                   "CREATE predicted address and live code nonexistence check"],
        }
        stages[-1]["addressDerivation"] = "last 20 bytes of keccak256(rlp([verified signer, fresh nonce])) for DIRECT_CREATE; do not force a stale nonce"
        stages[-1]["precedingReceiptRequired"] = None if i == 1 else f"D{i-1} canonical receipt and postflight"
        stages[-1]["predictedAddressCodeCheck"] = "UNAVAILABLE_NO_SIGNER_OR_NONCE"
        stages[-1]["noBroadcastAuthorization"] = True
        write(file_name, stages[-1])
    write("build_manifest.json", build)
    # Kept separate from the six logical contracts: these two existing library
    # addresses were read-only verified against the frozen artifact, ignoring
    # only Solidity's per-library embedded self-address immutable.
    write("library_link_evidence.json", {
        "comparisonBlockNumber": 47829878,
        "comparisonBlockHash": live["blockHash"],
        "libraries": [
            {"name": "PerpEngineSeizureLib", "address": LIBRARIES["PerpEngineSeizureLib"],
             "runtimeBytes": 3628, "runtimeKeccak256": "0xf55a4667bd9b69f73fd6bd0f3e24ea48de8295293893673b2af9c9f0cdcb5f1d",
             "unmaskedTemplateDifferences": 0},
            {"name": "PerpEngineLiquidationLib", "address": LIBRARIES["PerpEngineLiquidationLib"],
             "runtimeBytes": 6148, "runtimeKeccak256": "0xd7e6ef4cfd0904c0736c7d0bc08d602a0b6218e14f6c4468841a46b849d4ed2c",
             "unmaskedTemplateDifferences": 0},
        ],
        "immutableMask": "library_deploy_address only; all other bytes match linked frozen artifact",
    })
    migration = json.loads((FROZEN / "migration_manifest.json").read_text())
    seed = json.loads((ROOT / "artifacts/perps_v2_final_snapshot/seed_calldata.json").read_text())
    write("migration_replay_package.json", {
        "sourceManifestSha256": EXPECTED[-1], "canonicalSnapshotBlock": migration["canonicalSnapshotBlock"],
        "canonicalSnapshotBlockHash": migration["canonicalSnapshotBlockHash"],
        "sealSnapshotHash": migration["engineSealSnapshotHash"],
        "futureTarget": "D4_CANONICAL_ADDRESS", "orderedSeeds": [
            {k: v for k, v in item.items() if k != "target"} for item in seed["orderedSteps"]],
        "preSeal": "prove all six tuples, market state, OI, indexes, zero debt and unchanged shared custody/ledger",
        "sealCall": "0x" + (keccak(text="sealMigration(bytes32)")[:4]
                              + encode(["bytes32"], [bytes.fromhex(migration["engineSealSnapshotHash"][2:])])).hex(),
        "forbiddenSideEffects": ["Vault/Clearing funding", "mint", "collateral copy", "rebate budget copy", "realized PnL replay"],
        "authorized": False,
    })
    write("shared_acl_transition_manifest.json", {
        "schema": "deopt.perps_v2_replacement_deployment.shared_acl_transition.v1",
        "timelock": TIMELOCK, "vault": VAULT, "insurance": INSURANCE,
        "strandedEngine": NEW, "replacementEngine": "D4_CANONICAL_ADDRESS",
        "currentStrandedVault": live["vault"]["strandedNew"],
        "currentStrandedInsurance": live["insurance"]["strandedNewBackstop"],
        "insuranceVaultCallerAuthorization": live["vault"]["insuranceEffective"],
        "grantBeforeDualWindow": ["replacement Engine deployed/configured/SEALED", "both Engines fully maintenance-closed",
                                  "backend stopped", "no duplicate Vault/Clearing funding"],
        "futureGrants": ["Vault.setAuthorizedEngine(D4_CANONICAL_ADDRESS,true)",
                         "InsuranceFund.setBackstopCaller(D4_CANONICAL_ADDRESS,true)"],
        "futureIndependentRevocations": [
            "Vault.setAuthorizedEngine(" + NEW + ",false)",
            "InsuranceFund.setBackstopCaller(" + NEW + ",false)"],
        "revocationCalldata": {
            "vault": encode_call("CollateralVault", "setAuthorizedEngine", [NEW, False])[1],
            "insurance": encode_call("InsuranceFund", "setBackstopCaller", [NEW, False])[1],
        },
        "replacementGrantCalldata": "UNRESOLVED_D4_CANONICAL_ADDRESS",
        "revocationPrerequisite": "replacement ACL/replay verified and no stranded Engine operational dependency",
        "authorized": False,
    })
    write("first_trade_guard_binding.json", {
        "schema": "deopt.perps_v2_replacement_deployment.first_trade_guard_binding.v1",
        "engine": "D4_CANONICAL_ADDRESS", "engineRuntimeKeccak256": build["contracts"][3]["expectedRuntimeHash"],
        "pme": "D6_CANONICAL_ADDRESS", "pmeRuntimeKeccak256": "UNRESOLVED_CONSTRUCTOR_IMMUTABLES",
        "eip712": {"name": "DeOptV2-PerpMatchingEngine", "version": "2", "chainId": 84532,
                    "verifyingContract": "D6_CANONICAL_ADDRESS", "domainSeparator": "UNRESOLVED_ADDRESS"},
        "localFixtureOnly": {
            "pme": rehearsal["stages"][5]["localAddress"],
            "pmeRuntimeKeccak256": rehearsal["stages"][5]["runtimeKeccak256"],
            "domainSeparator": rehearsal["stages"][5]["localDomainSeparator"],
        },
        "executor": EXECUTOR, "marketId": 1,
        "buyer": "0x66858286feea78a05ea093673ea1535e0a52002d",
        "seller": "0xff287410852b9328437eac353720e5476bc5f837",
        "closeOnly": True, "maximumDeadlineHorizonSeconds": 900,
        "policy": "exact selector, bytes, nonce, signatures, fees, package SHA-256, one-shot journal; no live sender",
        "status": "CONDITIONAL_UNTIL_CANONICAL_D4_D6_RECEIPTS", "armed": False,
    })
    action_specs = []
    def add_action(stage, target, contract, method, args, prerequisite, poststate):
        signature, calldata = encode_call(contract, method, args)
        action_specs.append({
            "stageId": stage, "target": target, "valueWei": 0,
            "signature": signature, "decodedArgs": jsonable(args), "calldata": calldata,
            "calldataStatus": "EXACT" if calldata else "CONDITIONAL_ON_CANONICAL_ADDRESS",
            "prerequisite": prerequisite, "expectedPreState": "confirm at future queue review",
            "expectedPostState": poststate, "separatePostflightRequired": True,
            "canShareQueueDelayWindow": True, "timelockEta": None, "operationId": None,
        })
    pmr = json.loads((FROZEN / "pmr_config_manifest.json").read_text())
    add_action("C01", "D1_CANONICAL_ADDRESS", "PerpMarketRegistry", "setSettlementAssetAllowed",
               [TOKEN, True], "D1 canonical receipt; config open", "mUSDC allowed")
    for idx, market in enumerate(pmr["markets"], 1):
        fields = lambda section: tuple(market[section].values())
        args = [market["market"]["underlying"], TOKEN, ORACLE,
                bytes.fromhex(market["market"]["symbolBytes32"][2:]),
                fields("risk"), fields("liquidation"), fields("funding")]
        add_action(f"C0{idx+1}", "D1_CANONICAL_ADDRESS", "PerpMarketRegistry", "createMarket",
                   args, "previous market ID and config verified", f"new marketId exactly {idx}")
        add_action(f"C0{idx+3}", "D1_CANONICAL_ADDRESS", "PerpMarketRegistry", "setMaxExecutionDeviationBps",
                   [idx, market["maxExecutionDeviationBps"]], f"market {idx} exists", "deviation matches PMR manifest")
    add_action("C06", "D1_CANONICAL_ADDRESS", "PerpMarketRegistry", "setGuardian",
               [SAFE], "D1 deployed", "guardian Safe, tighten only")
    for stage, target, contract, method, args, prerequisite, poststate in (
        ("C07", "D1_CANONICAL_ADDRESS", "PerpMarketRegistry", "setEmergencyModes", [True, True], "markets configured", "creation/config paused"),
        ("C08", "D1_CANONICAL_ADDRESS", "PerpMarketRegistry", "pause", [], "markets configured", "PMR paused"),
        ("C09", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setEmergencyModes", [True]*4, "D4 deployed", "all Engine controls true"),
        ("C10", "D6_CANONICAL_ADDRESS", "PerpMatchingEngineV2", "pause", [], "D6 deployed", "PME paused"),
        ("C11", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setMatchingEngine", ["D6_CANONICAL_ADDRESS"], "D4 and D6 deployed", "Engine PME pointer"),
        ("C12", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setRiskModule", ["D5_CANONICAL_ADDRESS"], "D4 and D5 deployed", "Engine Risk pointer"),
        ("C13", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setCollateralSeizer", ["D3_CANONICAL_ADDRESS"], "D4 and D3 deployed", "Engine Seizer pointer"),
        ("C14", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setFeesManagerV2", ["D2_CANONICAL_ADDRESS"], "D4 and D2 deployed", "Engine FMV2 pointer"),
        ("C15", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setUseFeesManagerV2", [True], "D2 pointer verified", "FMV2 enabled"),
        ("C16", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setClearingAccount", [CLEARING], "shared Clearing readback", "Clearing pointer"),
        ("C17", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setInsuranceFund", [INSURANCE], "shared Insurance readback", "Insurance pointer"),
        ("C18", "D4_CANONICAL_ADDRESS", "PerpEngineV2", "setGuardian", [SAFE], "D4 deployed", "Safe pause-only guardian"),
        ("C19", "D5_CANONICAL_ADDRESS", "PerpRiskModule", "setGuardian", [SAFE], "D5 deployed", "Safe risk guardian"),
        ("C20", "D5_CANONICAL_ADDRESS", "PerpRiskModule", "setMaxOracleDelay", [600], "D5 deployed", "Risk oracle delay 600") ,
        ("C21", "D6_CANONICAL_ADDRESS", "PerpMatchingEngineV2", "setGuardian", [SAFE], "D6 deployed", "Safe pause guardian"),
        ("C22", "D6_CANONICAL_ADDRESS", "PerpMatchingEngineV2", "setExecutor", [TIMELOCK, False], "D6 paused", "Timelock routine executor removed"),
        ("C23", "D6_CANONICAL_ADDRESS", "PerpMatchingEngineV2", "setExecutor", [EXECUTOR, True], "closed first-test policy reviewed", "runtime sole routine executor"),
        ("C24", "D2_CANONICAL_ADDRESS", "FeesManagerV2", "setFeeConsumer", ["D4_CANONICAL_ADDRESS", True], "D2/D4 deployed", "replacement Engine fee consumer"),
        ("C25", VAULT, "CollateralVault", "setAuthorizedEngine", ["D4_CANONICAL_ADDRESS", True], "replacement sealed and both Engines closed", "replacement Vault ACL true"),
        ("C26", INSURANCE, "InsuranceFund", "setBackstopCaller", ["D4_CANONICAL_ADDRESS", True], "replacement sealed and both Engines closed", "replacement backstop ACL true"),
    ):
        add_action(stage, target, contract, method, args, prerequisite, poststate)
    action_specs.sort(key=lambda item: int(item["stageId"][1:]))
    write("timelock_configuration_manifest.json", {
        "schema": "deopt.perps_v2_replacement_deployment.timelock_config.v1",
        "governance": TIMELOCK, "safe": SAFE, "minimumDelayObserved": live["timelock"]["minDelay"],
        "operationIds": "UNRESOLVED_NO_APPROVED_ETA; deployed Timelock hashes abi.encode(target,value,data,eta), no salt",
        "actions": action_specs, "status": "CONDITIONAL_ADDRESSES_AND_ETA", "authorized": False,
    })
    package = {"schema": "deopt.perps_v2_replacement_deployment.package.v1",
               "sourceCommit": SOURCE_COMMIT, "chainId": 84532,
               "reviewBlockNumber": live["blockNumber"], "reviewBlockHash": live["blockHash"],
               "deploymentSignerStatus": "NO_SIGNER_DESIGNATED",
               "deploymentAddressMode": "DIRECT_CREATE",
               "futureAddressRule": "refresh signer nonce and verify every preceding canonical receipt; no nonce allocation now",
               "exactLibraryLinksResolved": True,
               "constructorRuntimeHashesResolved": False,
               "pmrLiveRefresh": live["pmr"]["refresh"],
               "vaultInsuranceLiveAcl": live["vaultInsuranceAcl"]["status"],
               "stages": [{"id": f"D{i}", "contract": name,
                           "reviewFile": "d1_pmr_deployment_review.json" if i == 1 else
                           ["", "", "d2_fmv2_deployment_template.json", "d3_seizer_deployment_template.json",
                            "d4_engine_deployment_template.json", "d5_risk_deployment_template.json",
                            "d6_pme_deployment_template.json"][i],
                           "requiresPreviousCanonicalReceipt": i > 1}
                          for i, name in enumerate(NAMES, 1)],
               "readiness": "BLOCKED_DEPLOYMENT_SIGNER_UNDESIGNATED",
               "publicBroadcastAuthorized": False}
    files = sorted(p.name for p in OUT.glob("*.json") if p.name != "deployment_package.json")
    package["artifactSha256"] = {name: sha((OUT / name).read_bytes()) for name in files}
    write("deployment_package.json", package)
    print(json.dumps({"package": str(OUT.relative_to(ROOT)),
                      "artifactCount": len(files) + 1,
                      "D1Hash": build["contracts"][0]["expectedRuntimeHash"],
                      "D4Hash": build["contracts"][3]["expectedRuntimeHash"]}))


if __name__ == "__main__":
    main()
