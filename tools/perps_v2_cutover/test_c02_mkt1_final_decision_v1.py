"""Focused integrity gate for the unapproved MKT1 early-queue candidate."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / 'artifacts/perps_v2_replacement_deployment'


def load(name):
    return json.loads((ART / name).read_text())


class ConditionalMkt1Candidate(unittest.TestCase):
    def setUp(self):
        self.c = load('mkt1_inactive_early_s1_conditional_candidate_v1.json')
        self.r = load('c02_mkt1_critical_path_final_decision_v1.json')
        self.b = load('mkt1_inactive_early_s1_unapproved_policy_safe_builder_v1.json')

    def test_one_call_and_exact_identity(self):
        c = self.c
        self.assertEqual(self.b['chainId'], '84532')
        self.assertEqual(len(self.b['transactions']), 1)
        self.assertIn('UNAPPROVED_POLICY_NOT_OPERATOR_READY', self.b['meta']['name'])
        tx = self.b['transactions'][0]
        self.assertEqual((tx['to'].lower(), tx['value'], tx['data']),
                         (c['timelock'].lower(), '0', c['outerCalldata']))
        self.assertEqual(hashlib.sha256((ROOT / c['builderPath']).read_bytes()).hexdigest(), c['builderSha256'])
        inner = bytes.fromhex(c['innerCalldata'][2:])
        self.assertEqual(c['innerCalldata'][:10], '0x' + keccak(text=c['innerFunction'])[:4].hex())
        self.assertEqual(decode(['uint256', 'bool', 'bool'], inner[4:]), (1, False, False))
        self.assertEqual(decode(['address', 'uint256', 'bytes', 'uint256'], bytes.fromhex(c['outerCalldata'][10:])),
                         (c['target'].lower(), 0, inner, c['eta']))
        self.assertEqual('0x' + keccak(encode(['address', 'uint256', 'bytes', 'uint256'],
                                             [c['target'], 0, inner, c['eta']])).hex(), c['operationId'])
        self.assertGreaterEqual(c['eta'], c['snapshot']['block']['timestamp'] +
                                c['snapshot']['reads']['timelock_min_delay'] + 48 * 3600)
        self.assertEqual(c['expiryInclusive'], c['eta'] + c['snapshot']['reads']['timelock_grace'])

    def test_policy_remains_unapproved(self):
        p = load('mkt1_early_queue_policy_amendment_proposal_v1.json')
        self.assertEqual(self.r['policy']['oldSchedulingEdge']['from'], p['oldHardEdge']['from'])
        self.assertEqual(self.r['policy']['proposedSchedulingEdge'], p['proposedSchedulingHardEdge'])
        self.assertFalse(self.r['policy']['approvedDagChanged'])
        self.assertFalse(self.c['authorization']['policyApproved'])
        self.assertFalse(self.c['authorization']['schedulingApproved'])
        self.assertFalse(self.r['authorization']['c02Execution'])
        self.assertEqual(self.r['infrastructure']['remoteIsolationVerdict'], 'NOT_VERIFIED')

    def test_fork_and_live_gate_are_separate(self):
        r = self.r
        self.assertEqual(r['chain']['pinnedBlock']['hash'], self.c['snapshot']['block']['hash'])
        self.assertTrue(r['chain']['reads']['c02_queued'])
        self.assertEqual(r['chain']['reads']['d1_total_markets'], 0)
        self.assertTrue(r['fork']['noPublicTransactions'])
        self.assertTrue(r['fork']['prematureExecutionRejected'])
        self.assertTrue(r['fork']['executionWithoutMarketRejectedAtEta'])
        self.assertTrue(r['fork']['marketInactiveAfterMkt1'])
        self.assertFalse(r['authorization']['publicTxByAgent'])


if __name__ == '__main__':
    unittest.main()
