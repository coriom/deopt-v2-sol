#!/usr/bin/env python3
"""Synthetic read-only RPC adversarial cases for the future C12 gate."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from eth_abi import encode
from eth_utils import keccak

sys.path.insert(0, str(Path(__file__).resolve().parent))
import c12_c20_preflight as gate


def h(n):
    return "0x" + f"{n:064x}"


def timelock_call(method, target, data, eta):
    return "0x" + (keccak(text=method)[:4] + encode(
        ["address", "uint256", "bytes", "uint256"],
        [target, 0, bytes.fromhex(data[2:]), eta])).hex()


def safe_call(inner, *, operation=0, target=gate.TIMELOCK):
    return "0x" + (keccak(text=gate.SAFE_EXEC)[:4] + encode(gate.SAFE_EXEC_TYPES,
        [target, 0, bytes.fromhex(inner[2:]), operation, 0, 0, 0,
         "0x" + "0" * 40, "0x" + "0" * 40, b""])).hex()


def event(topic, operation, target, data, eta, tx, executed=False):
    values = encode(["uint256", "bytes", "uint256", "bytes"] if executed else
                    ["uint256", "bytes", "uint256"],
                    [0, bytes.fromhex(data[2:]), eta, b""] if executed else
                    [0, bytes.fromhex(data[2:]), eta])
    return {"address": gate.TIMELOCK, "topics": [topic, operation, h(int(target, 16))],
            "data": "0x" + values.hex(), "transactionHash": tx}


class Fixture:
    def __init__(self):
        self.latest = 150
        self.delay = 600
        self.chain = gate.CHAIN
        self.d5 = gate.D5
        self.d4_risk = 0
        self.c20_queued = 0
        self.c12_queued = 1
        self.c20_queue_status = 1
        self.c20_execute_status = 1
        self.events_stale = False
        self.c12_exists = False
        self.bad_batch = False
        self.bad_d5_owner = False
        self.flags = {x: 1 for x in ("tradingPaused()", "liquidationPaused()",
                                      "fundingPaused()", "collateralOpsPaused()")}
        self.eta = 100000
        self.c12_eta = 200000
        self.c20_op = gate.operation_id(self.d5, gate.C20_DATA, self.eta)
        self.c12_op = gate.operation_id(gate.D4, gate.C12_DATA, self.c12_eta)
        self.tx_d5, self.tx_q, self.tx_x, self.tx_c12 = h(51), h(52), h(53), h(54)
        self.blocks = {n: {"number": hex(n), "hash": h(1000+n),
                           "timestamp": hex(t)} for n, t in
                       ((100, 100), (110, 110), (120, 1000), (130, 100000),
                        (135, 101000), (140, 104000), (150, 200001))}
        self.receipts = {}
        self.txs = {}
        self._add(gate.D4_DEPLOY_TX, 100, gate.D4, gate.DEPLOYER, 3, "0x", [])
        d5_input = json.loads((gate.ROOT / "artifacts/perps_v2_replacement_deployment/d5_risk_preparation.json").read_text())["creationData"]["hex"]
        self._add(self.tx_d5, 110, self.d5, gate.DEPLOYER, 4, d5_input, [], creation=True)
        self._add(self.tx_q, 120, None, gate.TIMELOCK, 0,
                  timelock_call("queueTransaction(address,uint256,bytes,uint256)", self.d5, gate.C20_DATA, self.eta),
                  [event(gate.QUEUED_TOPIC, self.c20_op, self.d5, gate.C20_DATA, self.eta, self.tx_q)])
        self._add(self.tx_x, 130, None, gate.TIMELOCK, 1,
                  timelock_call("executeTransaction(address,uint256,bytes,uint256)", self.d5, gate.C20_DATA, self.eta),
                  [event(gate.EXECUTED_TOPIC, self.c20_op, self.d5, gate.C20_DATA, self.eta, self.tx_x, True)])
        self._add(self.tx_c12, 140, None, gate.TIMELOCK, 2,
                  timelock_call("queueTransaction(address,uint256,bytes,uint256)", gate.D4, gate.C12_DATA, self.c12_eta),
                  [event(gate.QUEUED_TOPIC, self.c12_op, gate.D4, gate.C12_DATA, self.c12_eta, self.tx_c12)])
        self.evidence = {"schema": "deopt.c12_c20.public_evidence.v1", "phase": "authorization",
                         "chainId": gate.CHAIN, "stageId": "C20", "batch": False,
                         "target": self.d5, "timelock": gate.TIMELOCK,
                         "calldata": gate.C20_DATA, "eta": self.eta, "operationId": self.c20_op,
                         "manifestSha256": gate.validate_manifest(),
                         "d5DeploymentTxHash": self.tx_d5, "c20QueueTxHash": self.tx_q,
                         "c20ExecutionTxHash": self.tx_x}

    def _add(self, txid, n, created, to, nonce, data, logs, creation=False):
        self.receipts[txid] = {"transactionHash": txid, "status": "0x1", "blockNumber": hex(n),
                                "blockHash": self.blocks[n]["hash"], "contractAddress": created,
                                "logs": logs}
        self.txs[txid] = {"blockHash": self.blocks[n]["hash"], "from": gate.DEPLOYER if created else
                          "0x1111111111111111111111111111111111111111", "nonce": hex(nonce),
                          "to": None if created else to, "input": data,
                          "value": "0x0", "type": "0x2"}

    def __call__(self, method, params):
        if method == "eth_chainId": return hex(self.chain)
        if method == "eth_getBlockByNumber": return self.blocks[self.latest if params[0] == "latest" else int(params[0], 16)]
        if method == "eth_getTransactionReceipt": return self.receipts.get(params[0])
        if method == "eth_getTransactionByHash": return self.txs.get(params[0])
        if method == "eth_getCode": return "0x6000" if params[0].lower() in (gate.D4.lower(), self.d5.lower()) else "0x"
        if method == "eth_getLogs":
            if params[0]["address"].lower() == gate.TIMELOCK.lower():
                return self.receipts[self.tx_c12]["logs"] if self.c12_exists else []
            return [{"transactionHash": self.tx_x}] + ([{"transactionHash": h(99)}] if self.events_stale else [])
        if method == "eth_call":
            tx = params[0]; address = tx["to"].lower(); data = tx["data"].lower()
            sig = data[:10]
            sel = lambda x: "0x" + keccak(text=x)[:4].hex()
            val = 0
            if address == gate.TIMELOCK.lower():
                if sig == sel("hashOperation(address,uint256,bytes,uint256)"): val = int(self.c20_op, 16)
                elif sig == sel("queuedTransactions(bytes32)"):
                    val = self.c20_queued if data[10:] == self.c20_op[2:] else self.c12_queued
                elif sig == sel("minDelay()"): val = 86400
            elif address == self.d5.lower():
                if sig == sel("owner()"): val = 0 if self.bad_d5_owner else int(gate.TIMELOCK, 16)
                elif sig == sel("perpEngine()"): val = int(gate.D4, 16)
                elif sig == sel("maxOracleDelay()"): val = self.delay
            elif address == gate.D4.lower():
                if sig == sel("riskModule()"): val = self.d4_risk
                elif sig == sel("owner()"): val = int(gate.TIMELOCK, 16)
                elif sig in [sel(k) for k in self.flags]:
                    val = next(v for k,v in self.flags.items() if sig == sel(k))
            return h(val)
        raise AssertionError("unexpected RPC " + method)


class TestC12C20Preflight(unittest.TestCase):
    def setUp(self):
        self.f = Fixture()
        self.patch = patch.object(gate, "code_hash", lambda *args: None)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def good(self, phase="authorization"):
        evidence = copy.deepcopy(self.f.evidence)
        evidence["phase"] = phase
        if phase == "execution":
            self.f.c12_exists = False
            self.f.latest = 135
            try:
                evidence["c12AuthorizationReadback"] = gate.validate(
                    self.f, self.f.evidence, "authorization", backend_ok=True)
            finally:
                self.f.latest = 150
            self.f.c12_exists = True
            evidence["c12Queue"] = {"eta": self.f.c12_eta, "operationId": self.f.c12_op,
                                    "queueTxHash": self.f.tx_c12}
        else:
            self.f.c12_exists = False
        return gate.validate(self.f, evidence, phase, backend_ok=True)

    def reject(self):
        with self.assertRaises(gate.GateError):
            self.good()

    def test_c20_executed_live_600_passes_both_phases(self):
        self.assertEqual(self.good()["C12_AUTHORIZATION_READY"], "YES")
        self.assertEqual(self.good("execution")["C12_AUTHORIZATION_READY"], "YES")

    def test_missing_c20(self):
        self.f.evidence["c20ExecutionTxHash"] = h(999)
        self.reject()

    def test_queued_only_and_prepared_only(self):
        self.f.c20_queued = 1
        self.reject()
        self.f.c20_queued = 0
        self.f.receipts.pop(self.f.tx_x)
        self.reject()

    def test_simulation_and_failed_receipt(self):
        self.f.evidence["c20ExecutionTxHash"] = "0x" + "0"*64
        self.reject()
        self.f.evidence["c20ExecutionTxHash"] = self.f.tx_x
        self.f.receipts[self.f.tx_x]["status"] = "0x0"
        self.reject()

    def test_wrong_delays_and_stale_event(self):
        for delay in (0, 599, 601):
            self.f.delay = delay
            self.reject()
        self.f.delay = 600
        self.f.events_stale = True
        self.reject()

    def test_wrong_chain_target_and_deployment(self):
        self.f.chain = 1; self.reject(); self.f.chain = gate.CHAIN
        self.f.evidence["target"] = gate.D4; self.reject(); self.f.evidence["target"] = gate.D5
        self.f.receipts[self.f.tx_d5]["contractAddress"] = gate.D4; self.reject()

    def test_d4_pointer_owner_and_maintenance_drift(self):
        self.f.d4_risk = int(gate.D5, 16); self.reject(); self.f.d4_risk = 0
        self.f.bad_d5_owner = True; self.reject(); self.f.bad_d5_owner = False
        self.f.flags["tradingPaused()"] = 0; self.reject()

    def test_batch_and_receipt_inconsistency(self):
        self.f.evidence["batch"] = True; self.reject(); self.f.evidence["batch"] = False
        self.f.txs[self.f.tx_x]["input"] = "0xabcdef00"; self.reject()
        self.f.txs[self.f.tx_x]["input"] = timelock_call("executeTransaction(address,uint256,bytes,uint256)", gate.D5, gate.C20_DATA, self.f.eta)
        self.f.receipts[self.f.tx_x]["blockHash"] = h(999); self.reject()

    def test_exact_safe_call_route_passes_but_delegate_batch_fails(self):
        q = self.f.txs[self.f.tx_q]
        x = self.f.txs[self.f.tx_x]
        q["to"] = gate.SAFE; x["to"] = gate.SAFE
        q_inner, x_inner = q["input"], x["input"]
        q["input"] = safe_call(q_inner)
        x["input"] = safe_call(x_inner)
        self.assertEqual(self.good()["C12_AUTHORIZATION_READY"], "YES")
        x["input"] = safe_call(x_inner, operation=1)
        self.reject()
        x["input"] = safe_call(x_inner, target=gate.D4)
        self.reject()

    def test_extra_timelock_event_in_one_transaction_fails(self):
        self.f.receipts[self.f.tx_x]["logs"].append(event(
            gate.QUEUED_TOPIC, self.f.c12_op, gate.D4, gate.C12_DATA, self.f.c12_eta, self.f.tx_x))
        self.reject()

    def test_c12_scheduled_too_early_or_batch(self):
        self.f.receipts[self.f.tx_c12]["blockNumber"] = self.f.receipts[self.f.tx_x]["blockNumber"]
        with self.assertRaises(gate.GateError): self.good("execution")
        self.f.receipts[self.f.tx_c12]["blockNumber"] = hex(140)
        self.f.txs[self.f.tx_c12]["input"] = "0xdeadbeef"
        with self.assertRaises(gate.GateError): self.good("execution")

    def test_already_queued_c12_blocks_authorization(self):
        self.f.c12_exists = True
        with self.assertRaises(gate.GateError):
            gate.validate(self.f, self.f.evidence, "authorization", backend_ok=True)

    def test_c20_timelock_delay_and_queue_event_required(self):
        self.f.blocks[120]["timestamp"] = hex(self.f.eta - 86399)
        self.reject()
        self.f.blocks[120]["timestamp"] = hex(1000)
        self.f.receipts[self.f.tx_q]["logs"] = []
        self.reject()

    def test_c20_wrong_operation_or_deployer_input(self):
        self.f.evidence["operationId"] = h(0)
        self.reject()
        self.f.evidence["operationId"] = self.f.c20_op
        self.f.txs[self.f.tx_d5]["input"] = "0x6000"
        self.reject()

    def test_backend_and_wrong_manifest_fail_closed(self):
        with self.assertRaises(gate.GateError):
            gate.validate(self.f, self.f.evidence, "authorization", backend_ok=False)
        self.f.evidence["manifestSha256"] = h(1)
        self.reject()

    def test_execution_requires_separate_c12_queue_and_elapsed_delay(self):
        evidence = copy.deepcopy(self.f.evidence)
        evidence["phase"] = "execution"
        with self.assertRaises(gate.GateError):
            gate.validate(self.f, evidence, "execution", backend_ok=True)
        self.f.blocks[150]["timestamp"] = hex(self.f.c12_eta - 1)
        with self.assertRaises(gate.GateError): self.good("execution")

    def test_c12_queue_requires_earlier_independent_readback(self):
        late = self.good()  # review block 150, after C12's block 140
        evidence = copy.deepcopy(self.f.evidence)
        evidence["phase"] = "execution"
        evidence["c12AuthorizationReadback"] = late
        evidence["c12Queue"] = {"eta": self.f.c12_eta, "operationId": self.f.c12_op,
                                "queueTxHash": self.f.tx_c12}
        self.f.c12_exists = True
        with self.assertRaises(gate.GateError):
            gate.validate(self.f, evidence, "execution", backend_ok=True)
        evidence["c12AuthorizationReadback"]["reviewBlock"] = 135
        evidence["c12AuthorizationReadback"]["reviewBlockHash"] = h(999)
        with self.assertRaises(gate.GateError):
            gate.validate(self.f, evidence, "execution", backend_ok=True)

    def test_manifest_dependency_cannot_be_removed(self):
        m = gate.expected_manifest()
        c12 = next(x for x in m["actions"] if x["stageId"] == "C12")
        self.assertEqual(c12["dependsOn"], ["C20_EXECUTED_AND_READ_BACK"])
        self.assertFalse(c12["canShareQueueDelayWindow"])
        self.assertLess(next(i for i,x in enumerate(m["actions"]) if x["stageId"] == "C20"),
                        next(i for i,x in enumerate(m["actions"]) if x["stageId"] == "C12"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "unsafe.json"
            c12["dependsOn"] = []
            path.write_text(json.dumps(m))
            with patch.object(gate, "MANIFEST", path), self.assertRaises(gate.GateError):
                gate.validate_manifest()

    def test_historical_builder_cannot_overwrite_preserved_manifest(self):
        from build_replacement_deployment_package import main as historical_builder
        with self.assertRaisesRegex(RuntimeError, "historical V1 package is frozen"):
            historical_builder()


if __name__ == "__main__":
    unittest.main()
