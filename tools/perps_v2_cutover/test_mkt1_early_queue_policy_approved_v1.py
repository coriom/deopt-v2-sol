"""Focused checks for approved MKT1 scheduling policy and unsigned S1 review."""

import hashlib
import json
import unittest
from pathlib import Path

from eth_abi import decode, encode
from eth_utils import keccak

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / 'artifacts/perps_v2_replacement_deployment'


def read(name):
    return json.loads((ART / name).read_text())


class ApprovedEarlyQueue(unittest.TestCase):
    def test_only_mkt1_phase_dependency_changes(self):
        old = read('post_maintenance_dependency_dag_v2.json')
        new = read('post_maintenance_dependency_dag_v3.json')
        self.assertEqual(new['supersedes']['sha256'], hashlib.sha256(
            (ART / 'post_maintenance_dependency_dag_v2.json').read_bytes()).hexdigest())
        self.assertEqual(old['chainId'], new['chainId'])
        self.assertEqual(old['topologicalOrder'], new['topologicalOrder'])
        self.assertEqual(len(old['edges']), len(new['edges']))
        self.assertEqual(len(old['nodes']), len(new['nodes']))
        old_edges = {(e['from'], e['to']): e for e in old['edges']}
        new_edges = {(e['from'], e['to']): e for e in new['edges']}
        self.assertEqual(old_edges.keys(), new_edges.keys())
        for key, before in old_edges.items():
            if key == ('C02', 'MKT1_INACTIVE'):
                after = dict(new_edges[key]); self.assertEqual(after.pop('appliesTo'), 'MKT1_INACTIVE_S2_EXECUTION')
                self.assertEqual(before, after)
            else:
                self.assertEqual(before, new_edges[key], key)
        old_nodes = {n['id']: n for n in old['nodes']}
        new_nodes = {n['id']: n for n in new['nodes']}
        for key in old_nodes:
            if key == 'MKT1_INACTIVE':
                after = dict(new_nodes[key])
                for extra in ('dependencyScope', 'schedulingPrerequisites', 'executionPrerequisites',
                              'earlySchedulingAuthorizedByPolicy', 'publicSchedulingAuthorized',
                              'publicExecutionAuthorized'):
                    after.pop(extra)
                self.assertEqual(old_nodes[key], after)
            else:
                self.assertEqual(old_nodes[key], new_nodes[key], key)
        mkt = new_nodes['MKT1_INACTIVE']
        self.assertEqual(mkt['schedulingPrerequisites'], ['C02_S1_CANONICAL_QUEUE_POSTFLIGHT_PASS'])
        self.assertEqual(mkt['executionPrerequisites'],
                         ['C02_S2_CANONICAL_POSTFLIGHT_PASS', 'MKT1_INACTIVE_S1_CANONICAL_QUEUE_POSTFLIGHT_PASS'])
        self.assertFalse(mkt['publicSchedulingAuthorized'] or mkt['publicExecutionAuthorized'])

    def test_policy_approval_has_no_transaction_authorization(self):
        policy = read('mkt1_early_queue_policy_approval_v1.json')
        new = read('post_maintenance_dependency_dag_v3.json')
        self.assertEqual(policy['approvedDagSha256'], hashlib.sha256(
            (ART / 'post_maintenance_dependency_dag_v3.json').read_bytes()).hexdigest())
        self.assertEqual(policy['chainId'], 84532)
        self.assertEqual(policy['newSchedulingEdge']['from'], 'C02_S1_CANONICAL_QUEUE_POSTFLIGHT_PASS')
        self.assertTrue(any(e['from'] == 'C02_S2_CANONICAL_POSTFLIGHT_PASS'
                            for e in policy['preservedExecutionEdges']))
        self.assertFalse(any(policy['authorization'].values()))
        self.assertFalse(new['mkt1EarlyQueuePolicyApproval']['executionAuthorized'])

    def test_reviewed_builder_and_operation_identity(self):
        review = read('mkt1_inactive_early_s1_final_review_v1.json')
        builder = read('mkt1_inactive_early_s1_safe_builder_final_review_v1.json')
        self.assertEqual(review['reviewVerdict'], 'PASS_OFFLINE')
        self.assertTrue(review['authorization']['policyApproved'])
        self.assertFalse(review['authorization']['schedulingApproved'])
        self.assertFalse(review['authorization']['executionApproved'])
        self.assertEqual(review['builderSha256'], hashlib.sha256(
            (ROOT / review['builderPath']).read_bytes()).hexdigest())
        self.assertEqual(builder['chainId'], '84532')
        self.assertEqual(len(builder['transactions']), 1)
        tx = builder['transactions'][0]
        self.assertEqual((tx['to'].lower(), tx['value'], tx['data']),
                         (review['timelock'].lower(), '0', review['outerCalldata']))
        inner = bytes.fromhex(review['innerCalldata'][2:])
        self.assertEqual(decode(['uint256', 'bool', 'bool'], inner[4:]), (1, False, False))
        self.assertEqual(decode(['address', 'uint256', 'bytes', 'uint256'],
                                bytes.fromhex(review['outerCalldata'][10:])),
                         (review['target'].lower(), 0, inner, review['eta']))
        self.assertEqual(review['operationId'], '0x' + keccak(encode(
            ['address', 'uint256', 'bytes', 'uint256'],
            [review['target'], 0, inner, review['eta']])).hex())
        self.assertEqual(review['expiryInclusive'], review['eta'] + review['snapshot']['reads']['timelock_grace'])
        self.assertGreaterEqual(review['eta'], review['snapshot']['block']['timestamp'] +
                                review['snapshot']['reads']['timelock_min_delay'] + 48 * 3600)
        self.assertEqual(review['safeEnvelope']['nonceObserved'], review['snapshot']['reads']['safe_nonce'])

    def test_fork_scope_and_live_blockers_are_explicit(self):
        review = read('mkt1_inactive_early_s1_final_review_v1.json')
        baseline = read('d2_d3_six_operation_s2_final_configuration_v1.json')
        state = review['snapshot']['reads']
        self.assertEqual(state['safe_owners'], baseline['safe']['owners'])
        self.assertEqual(state['safe_threshold'], 2)
        self.assertEqual(state['safe_modules'][0], [])
        self.assertEqual(state['timelock_owner'], review['operatorCheckpoint']['safe'].lower())
        self.assertTrue(state['c02_queued'])
        self.assertEqual(state['d1_total_markets'], 0)
        self.assertFalse(state['d1_market1_exists'])
        self.assertTrue(all(state[k] for k in ('d4_trading_paused', 'd4_liquidation_paused',
                                              'd4_funding_paused', 'd4_collateral_paused',
                                              'd6_paused')))
        self.assertFalse(state['vault_d4_authorized'] or state['insurance_d4_backstop'])
        self.assertEqual(state['d3_musdc_config'], [5, True, True])
        self.assertTrue(all(state[f'd2_perp_tier_{i}'] == [0, 200] for i in range(5)))
        self.assertTrue(all(review['readOnlyChecks'].values()))
        fork = review['forkRehearsal']
        self.assertEqual(fork['scope'], 'ISOLATED_ANVIL_FORK_ONLY')
        self.assertEqual(fork['forkBlock'], review['snapshot']['block']['number'])
        for key in ('prematureExecutionRejected', 'executionWithoutMarketRejectedAtEta',
                    'cancelledC02ExecutionRejected', 'marketActiveAfterC02',
                    'marketInactiveAfterMkt1', 'wrongMarketIdRejected', 'mkt1ReplayRejected',
                    'forkRevertedAfterTest'):
            self.assertTrue(fork[key], key)
        self.assertTrue(all(fork['d4FourFlags'].values()) and fork['d6Paused'])
        self.assertEqual(review['remoteIsolationStatus'], 'NOT_VERIFIED_BLOCKS_C02_S2_ONLY')
        self.assertFalse(review['authorization']['publicTxByAgent'])


if __name__ == '__main__':
    unittest.main()
