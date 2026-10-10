#!/usr/bin/env python3
"""Canonical C12 validation workflow. Read-only RPC; no signing or submission.

Each invocation is a new live check. A successful report is evidence for a
separate human review, never an authorization, queue, execution, or postflight.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import c12_c20_preflight as gate

EXPECTED_MANIFEST_SHA256 = "745e7a2fad6a77fef6e35f10a1a431b75615524f51fe13c881c191351ad591fe"
STAGES = ("prepare", "review", "authorize", "schedule", "execute", "postflight")


def require_c12_governance_readiness(rpc, evidence, stage, *, backend_ok=False):
    """Validate the exact C12 boundary afresh; never build a public transaction."""
    gate.require(stage in STAGES, "unknown C12 stage")
    gate.require(gate.MANIFEST.is_file(), "canonical C12 manifest missing")
    manifest_sha = hashlib.sha256(gate.MANIFEST.read_bytes()).hexdigest()
    gate.require(manifest_sha == EXPECTED_MANIFEST_SHA256, "historical or unexpected C12 manifest")
    phase = "execution" if stage in ("execute", "postflight") else "authorization"
    # validate() verifies the manifest semantics, canonical public receipts,
    # live D4/D5/C20 state, C12 queue/delay in execution phase, and reorg.
    checked = gate.validate(rpc, evidence, phase, backend_ok=backend_ok)
    gate.require(checked["C12_AUTHORIZATION_READY"] == "YES" and
                 checked["manifestSha256"] == manifest_sha and
                 checked["chainId"] == gate.CHAIN and
                 checked["d5MaxOracleDelay"] == 600,
                 "C12 preflight incomplete")
    if stage == "schedule":
        earlier = evidence.get("c12AuthorizationReadback")
        gate.require(isinstance(earlier, dict) and
                     earlier.get("C12_AUTHORIZATION_READY") == "YES" and
                     earlier.get("phase") == "authorization" and
                     earlier.get("chainId") == gate.CHAIN and
                     earlier.get("manifestSha256") == manifest_sha and
                     earlier.get("c20OperationId") == checked["c20OperationId"] and
                     earlier.get("c20ExecutionTxHash") == checked["c20ExecutionTxHash"] and
                     earlier.get("d5MaxOracleDelay") == 600,
                     "missing prior C12 authorization readback")
        review_n = earlier.get("reviewBlock")
        gate.require(isinstance(review_n, int) and 0 < review_n < checked["reviewBlock"],
                     "C12 authorization readback not earlier than scheduling check")
        previous = rpc("eth_getBlockByNumber", [hex(review_n), False])
        gate.require(previous and gate.lower(previous["hash"]) ==
                     gate.lower(earlier.get("reviewBlockHash")),
                     "prior C12 authorization block noncanonical")
        gate.require(gate.call(rpc, gate.D5, "maxOracleDelay()", tag=hex(review_n)) == 600 and
                     gate.call(rpc, gate.D4, "riskModule()", tag=hex(review_n)) == 0 and
                     gate.call(rpc, gate.D4, "migrationState()", tag=hex(review_n)) == 0,
                     "prior C12 authorization state invalid")
    # Public C12 submission is deliberately absent. A postflight cannot be
    # asserted until a separately reviewed execution adapter exists.
    gate.require(stage != "postflight", "public C12 postflight is not implemented")
    result = {
        "schema": "deopt.c12.governance_workflow_validation.v1",
        "stageRequested": stage.upper(),
        "validationState": "PASS_FOR_SEPARATE_REVIEW_ONLY",
        "actualGovernanceState": "UNALTERED",
        "chainId": gate.CHAIN,
        "reviewBlock": checked["reviewBlock"],
        "reviewBlockHash": checked["reviewBlockHash"],
        "manifestPath": str(gate.MANIFEST.relative_to(gate.ROOT)),
        "manifestSha256": manifest_sha,
        "D4": gate.D4,
        "D5": gate.D5,
        "C12Target": gate.D4,
        "C12CalldataKeccak256": "0x" + gate.keccak(bytes.fromhex(gate.C12_DATA[2:])).hex(),
        "C20OperationId": checked["c20OperationId"],
        "C20ExecutionTxHash": checked["c20ExecutionTxHash"],
        "D5LiveMaxOracleDelaySeconds": checked["d5MaxOracleDelay"],
        "preflightPhase": phase,
        "preflightResult": "PASS",
        "safeProposalPrepared": False,
        "c12Authorized": False,
        "c12Scheduled": False,
        "c12Executed": False,
        "publicSubmissionImplemented": False,
        "publicSubmissionEnabled": False,
        "publicWriteCount": 0,
    }
    if stage == "authorize":
        # The execution preflight checks this record against the earlier
        # canonical block and requires C12's later, separate queue receipt.
        result["c12AuthorizationReadback"] = checked
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=STAGES, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True,
                        help="new local sanitized validation record; existing files are never overwritten")
    args = parser.parse_args(argv)
    try:
        gate.require(args.evidence.is_file(), "C20/C12 evidence missing")
        evidence = json.loads(args.evidence.read_text())
        # The only RPC implementation reachable from the CLI has an explicit
        # read-only method allowlist. No raw/signed transaction API is imported.
        result = require_c12_governance_readiness(
            gate.PublicRpc(gate.configured_rpc_url()), evidence, args.stage,
            backend_ok=gate.backend_stopped())
        with args.output.open("x") as out:
            json.dump(result, out, indent=2, sort_keys=True)
            out.write("\n")
    except Exception as exc:
        print("C12_WORKFLOW_READY = NO; reason =", str(exc).splitlines()[0][:180])
        return 1
    print("C12_WORKFLOW_VALIDATION = PASS_FOR_SEPARATE_REVIEW_ONLY")
    print("C12_PUBLIC_SUBMISSION_ENABLED = NO")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
