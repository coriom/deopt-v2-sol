"""Focused consistency checks for the six unsigned Base Sepolia D2/D3 S2 packages."""
import hashlib
import json
import subprocess
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
ART=ROOT/'artifacts/perps_v2_replacement_deployment'
ZERO='0x'+'00'*20
TL='0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588'

def load(name):return json.loads((ART/name).read_text())
def word(x):return f'{int(x):064x}'
def digest(x):return subprocess.check_output(['cast','keccak',x],text=True).strip().lower()

class S2UnsignedPackage(unittest.TestCase):
    def setUp(self):
        self.s1=load('d2_d3_s1_unsigned_intents_v1.json')['operations']
        self.s2=load('d2_d3_six_operation_s2_unsigned_intents_v1.json')
        self.review=load('d2_d3_six_operation_s2_execution_review_v1.json')

    def test_s1_postflight_and_distinct_s2_identity(self):
        ledger=load('d2_d3_six_operation_s1_run_progress_v8.json')
        self.assertEqual(ledger['completedOperations'],6)
        self.assertTrue(all(x['postflightVerdict']=='PASS' and x['queueStatus']=='QUEUED' for x in ledger['operations']))
        self.assertEqual(len(self.s2['operations']),6)
        self.assertEqual(len({x['operationId'] for x in self.s2['operations']}),6)
        self.assertFalse(self.s2['s2ExecutionAuthorized'])
        self.assertEqual([x['safeNonceConditional'] for x in self.s2['operations']],list(range(36,42)))

    def test_exact_call_and_builder(self):
        for prior,current in zip(self.s1,self.s2['operations'],strict=True):
            self.assertEqual(current['name'],prior['name'])
            self.assertEqual(current['operationId'],prior['timelockOperationId'])
            self.assertEqual(current['innerCalldata'],prior['innerCalldata'])
            self.assertEqual(current['target'].lower(),prior['target'].lower())
            target=int(current['target'],16);inner=current['innerCalldata'][2:];eta=current['eta']
            dynamic=word(len(inner)//2)+inner.ljust(((len(inner)+63)//64)*64,'0')
            encoded=word(target)+word(0)+word(128)+word(eta)+dynamic
            self.assertEqual(digest('0x'+encoded),current['operationId'].lower())
            outer='0x06a41d09'+encoded
            self.assertEqual(current['executionCalldata'].lower(),outer.lower())
            self.assertEqual(current['executionCalldataKeccak256'].lower(),digest(outer))
            path=ROOT/current['builderPath'];builder=json.loads(path.read_text())
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),current['builderSha256'])
            self.assertEqual(builder['chainId'],'84532')
            self.assertEqual(len(builder['transactions']),1)
            tx=builder['transactions'][0]
            self.assertEqual((tx['to'].lower(),tx['value'],tx['data'].lower()),(TL.lower(),'0',outer.lower()))
            self.assertEqual(tx['contractMethod']['name'],'executeTransaction')
            self.assertEqual((tx['contractInputsValues']['target'].lower(),tx['contractInputsValues']['value'],tx['contractInputsValues']['data'].lower(),tx['contractInputsValues']['eta']),
                             (current['target'].lower(),'0',prior['innerCalldata'].lower(),str(eta)))
            fields=current['safeTxFields']
            self.assertEqual((fields['operation'],fields['value'],fields['safeTxGas'],fields['baseGas'],fields['gasPrice'],fields['gasToken'],fields['refundReceiver']),
                             (0,'0','0','0','0',ZERO,ZERO))

    def test_review_and_hash_commitments(self):
        self.assertEqual(self.review['unsignedIntentsSha256'],hashlib.sha256((ART/'d2_d3_six_operation_s2_unsigned_intents_v1.json').read_bytes()).hexdigest())
        self.assertEqual(self.review['s1ProgressSha256'],hashlib.sha256((ART/'d2_d3_six_operation_s1_run_progress_v8.json').read_bytes()).hexdigest())
        self.assertEqual(self.review['tier4PublicPostflightSha256'],hashlib.sha256((ART/'d2_perp_tier_4_s1_public_postflight_v1.json').read_bytes()).hexdigest())
        for reviewed,op in zip(self.review['operations'],self.s2['operations'],strict=True):
            self.assertEqual(reviewed['safeTxHashConditional'],op['safeTxHashConditional'])
            self.assertEqual(reviewed['executionCalldataKeccak256'],op['executionCalldataKeccak256'])
            self.assertEqual(reviewed['builderSha256'],op['builderSha256'])
        self.assertEqual(self.review['forkRehearsal']['testCount'],3)
        self.assertFalse(self.review['forkRehearsal']['actualSafeSignaturesTested'])

if __name__=='__main__':unittest.main()
