#!/usr/bin/env python3
"""Integration tests through the supported C12 workflow API and CLI."""

import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from eth_utils import keccak

sys.path.insert(0, str(Path(__file__).resolve().parent))
import c12_c20_preflight as gate
import c12_governance_workflow as workflow
from test_c12_c20_preflight import Fixture, h


class TestC12WorkflowIntegration(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(patch.stopall)
        # The synthetic RPC supplies toy bytecode; still require code to exist.
        def synthetic_code_hash(rpc, address, tag, expected):
            if rpc("eth_getCode", [address, tag]) == "0x":
                raise gate.GateError("missing contract code")
        patch.object(gate, "code_hash", synthetic_code_hash).start()

    def run_stage(self, stage="authorize", evidence=None):
        self.f.c12_exists = stage == "execute"
        supplied = copy.deepcopy(evidence if evidence is not None else self.f.evidence)
        supplied["phase"] = "execution" if stage == "execute" else "authorization"
        return workflow.require_c12_governance_readiness(self.f, supplied, stage, backend_ok=True)

    def prior_authorization(self):
        self.f.latest = 135
        self.f.c12_exists = False
        earlier = self.run_stage("authorize")["c12AuthorizationReadback"]
        self.f.latest = 150
        return earlier

    def execution_evidence(self):
        earlier = self.prior_authorization()
        self.f.c12_exists = True
        evidence = copy.deepcopy(self.f.evidence)
        evidence["phase"] = "execution"
        evidence["c12AuthorizationReadback"] = earlier
        evidence["c12Queue"] = {"eta": self.f.c12_eta, "operationId": self.f.c12_op,
                                "queueTxHash": self.f.tx_c12}
        return evidence

    def test_every_pre_execution_stage_calls_fresh_gate_and_emits_no_transaction(self):
        for stage in ("prepare", "review", "authorize"):
            with self.subTest(stage=stage):
                result = self.run_stage(stage)
                self.assertEqual(result["preflightResult"], "PASS")
                self.assertFalse(result["publicSubmissionImplemented"])
                self.assertFalse(result["c12Authorized"])
                self.assertFalse(result["c12Scheduled"])
                self.assertNotIn("calldata", result)
        self.f.delay = 599
        for stage in ("prepare", "review", "authorize", "schedule"):
            with self.subTest(stage=stage), self.assertRaises(gate.GateError):
                self.run_stage(stage)

    def test_schedule_requires_prior_authorization_and_fresh_recheck(self):
        with self.assertRaises(gate.GateError): self.run_stage("schedule")
        prior = self.prior_authorization()
        evidence = copy.deepcopy(self.f.evidence)
        evidence["c12AuthorizationReadback"] = prior
        result = self.run_stage("schedule", evidence)
        self.assertEqual(result["preflightResult"], "PASS")
        self.assertFalse(result["c12Scheduled"])
        self.f.delay = 599
        with self.assertRaises(gate.GateError): self.run_stage("schedule", evidence)
        self.f.delay = 600
        evidence["c12AuthorizationReadback"]["reviewBlockHash"] = h(999)
        with self.assertRaises(gate.GateError): self.run_stage("schedule", evidence)

    def test_execute_gate_rechecks_live_state_and_separate_queue(self):
        evidence = self.execution_evidence()
        result = self.run_stage("execute", evidence)
        self.assertEqual(result["preflightPhase"], "execution")
        self.assertFalse(result["c12Executed"])
        self.f.delay = 601
        with self.assertRaises(gate.GateError):
            self.run_stage("execute", evidence)
        self.f.delay = 600
        evidence.pop("c12Queue")
        with self.assertRaises(gate.GateError):
            self.run_stage("execute", evidence)

    def test_postflight_cannot_claim_unimplemented_public_execution(self):
        evidence = self.execution_evidence()
        evidence["phase"] = "execution"
        with self.assertRaisesRegex(gate.GateError, "not implemented"):
            workflow.require_c12_governance_readiness(self.f, evidence, "postflight", backend_ok=True)

    def test_absent_deployment_c20_receipt_and_queued_only_block(self):
        self.f.receipts.pop(self.f.tx_d5)
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f = Fixture()
        self.f.receipts.pop(self.f.tx_x)
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f = Fixture()
        self.f.c20_queued = 1
        with self.assertRaises(gate.GateError): self.run_stage()

    def test_failed_simulated_or_wrong_c20_and_batch_block(self):
        self.f.receipts[self.f.tx_x]["status"] = "0x0"
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f = Fixture()
        self.f.evidence["c20ExecutionTxHash"] = h(999)
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f = Fixture()
        self.f.evidence["target"] = gate.D4
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f = Fixture()
        self.f.evidence["batch"] = True
        with self.assertRaises(gate.GateError): self.run_stage()

    def test_wrong_delay_stale_readback_chain_and_d4_drift_block(self):
        for delay in (0, 599, 601):
            self.f.delay = delay
            with self.subTest(delay=delay), self.assertRaises(gate.GateError): self.run_stage()
        self.f.delay = 600
        self.assertEqual(self.run_stage()["D5LiveMaxOracleDelaySeconds"], 600)
        self.f.events_stale = True
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f.events_stale = False
        self.f.chain = 1
        with self.assertRaises(gate.GateError): self.run_stage()
        self.f.chain = gate.CHAIN
        self.f.d4_risk = int(gate.D5, 16)
        with self.assertRaises(gate.GateError): self.run_stage()

    def test_sealed_d4_or_available_pme_route_blocks(self):
        fixture = self.f
        class DriftedRpc:
            def __init__(self, signature, value):
                self.signature, self.value = signature, value
            def __call__(self, method, params):
                if method == "eth_call" and params[0]["to"].lower() == gate.D4.lower() and \
                        params[0]["data"][:10] == "0x" + keccak(text=self.signature)[:4].hex():
                    return h(self.value)
                return fixture(method, params)
        for signature, value in (("migrationState()", 1), ("matchingEngine()", 0x1234)):
            with self.subTest(signature=signature), self.assertRaises(gate.GateError):
                workflow.require_c12_governance_readiness(
                    DriftedRpc(signature, value), self.f.evidence, "authorize", backend_ok=True)

    def test_historical_missing_or_tampered_manifest_block(self):
        old = gate.ROOT / "artifacts/perps_v2_replacement_deployment/timelock_configuration_manifest.json"
        with patch.object(gate, "MANIFEST", old), self.assertRaises(gate.GateError): self.run_stage()
        missing = Path(self.tmp.name) / "missing.json"
        with patch.object(gate, "MANIFEST", missing), self.assertRaises(gate.GateError): self.run_stage()
        tampered = Path(self.tmp.name) / "tampered.json"
        manifest = gate.expected_manifest()
        next(x for x in manifest["actions"] if x["stageId"] == "C12")["dependsOn"] = []
        tampered.write_text(json.dumps(manifest))
        with patch.object(gate, "MANIFEST", tampered), self.assertRaises(gate.GateError): self.run_stage()

    def test_cli_entrypoint_persists_only_pass_and_requires_preflight(self):
        evidence = Path(self.tmp.name) / "evidence.json"
        output = Path(self.tmp.name) / "result.json"
        evidence.write_text(json.dumps(self.f.evidence))
        with patch.object(gate, "PublicRpc", return_value=self.f), \
             patch.object(gate, "configured_rpc_url", return_value="synthetic"), \
             patch.object(gate, "backend_stopped", return_value=True):
            self.assertEqual(workflow.main(["--stage", "authorize", "--evidence", str(evidence),
                                            "--output", str(output)]), 0)
            self.assertEqual(json.loads(output.read_text())["preflightResult"], "PASS")
            self.assertEqual(workflow.main(["--stage", "authorize", "--evidence", str(evidence),
                                            "--output", str(output)]), 1)  # no overwrite
            with patch.object(gate, "validate", side_effect=gate.GateError("preflight missing")):
                missing = Path(self.tmp.name) / "must-not-exist.json"
                self.assertEqual(workflow.main(["--stage", "schedule", "--evidence", str(evidence),
                                                "--output", str(missing)]), 1)
                self.assertFalse(missing.exists())
            self.f.delay = 0
            blocked = Path(self.tmp.name) / "blocked.json"
            self.assertEqual(workflow.main(["--stage", "authorize", "--evidence", str(evidence),
                                            "--output", str(blocked)]), 1)
            self.assertFalse(blocked.exists())

    def test_cli_schedule_and_execute_consume_prior_authorization_output(self):
        evidence = Path(self.tmp.name) / "evidence.json"
        prior_path = Path(self.tmp.name) / "prior.json"
        schedule_path = Path(self.tmp.name) / "schedule.json"
        execution_path = Path(self.tmp.name) / "execution.json"
        with patch.object(gate, "PublicRpc", return_value=self.f), \
             patch.object(gate, "configured_rpc_url", return_value="synthetic"), \
             patch.object(gate, "backend_stopped", return_value=True):
            self.f.latest = 135
            evidence.write_text(json.dumps(self.f.evidence))
            self.assertEqual(workflow.main(["--stage", "authorize", "--evidence", str(evidence),
                                            "--output", str(prior_path)]), 0)
            prior = json.loads(prior_path.read_text())["c12AuthorizationReadback"]
            self.f.latest = 150
            prepared = copy.deepcopy(self.f.evidence)
            prepared["c12AuthorizationReadback"] = prior
            evidence.write_text(json.dumps(prepared))
            self.assertEqual(workflow.main(["--stage", "schedule", "--evidence", str(evidence),
                                            "--output", str(schedule_path)]), 0)
            self.assertFalse(json.loads(schedule_path.read_text())["c12Scheduled"])
            self.f.c12_exists = True
            prepared["phase"] = "execution"
            prepared["c12Queue"] = {"eta": self.f.c12_eta, "operationId": self.f.c12_op,
                                     "queueTxHash": self.f.tx_c12}
            evidence.write_text(json.dumps(prepared))
            self.assertEqual(workflow.main(["--stage", "execute", "--evidence", str(evidence),
                                            "--output", str(execution_path)]), 0)
            self.assertFalse(json.loads(execution_path.read_text())["c12Executed"])

    def test_cli_rejects_bypass_flags_and_missing_evidence(self):
        evidence = Path(self.tmp.name) / "none.json"
        output = Path(self.tmp.name) / "none-output.json"
        self.assertEqual(workflow.main(["--stage", "authorize", "--evidence", str(evidence),
                                        "--output", str(output)]), 1)
        self.assertFalse(output.exists())
        with self.assertRaises(SystemExit):
            workflow.main(["--stage", "authorize", "--evidence", str(evidence),
                           "--output", str(output), "--skip-preflight"])


if __name__ == "__main__":
    unittest.main()
