"""Synthetic replacement-domain and immutable-raw one-shot tests; no live signer/RPC."""
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import first_trade_execution_adapter as adapter
import first_trade_live_state as state
import restricted_first_trade_guard as guard
from signed_order_resolution import domain
from test_first_trade_execution_adapter import signed_fixture
from test_restricted_first_trade_guard import fixture, package_bytes, synthetic_sign, synthetic_traders


class ReplacementGuardTest(unittest.TestCase):
    def setUp(self):
        self.package, self.candidate, self.live, self.traders = fixture()
        self.policy = {
            'schema':'DEOPT_REPLACEMENT_FIRST_TRADE_DEPLOYMENT_POLICY_V1',
            'chainId':84532,'pme':'0x'+'11'*20,'engine':'0x'+'22'*20,
            'engineRuntimeHash':'0x'+'33'*32,'pmeRuntimeHash':'0x'+'44'*32,
            'engineRuntimeBytes':24519,'pmeRuntimeBytes':10441,
            'pmr':'0x'+'55'*20,'risk':'0x'+'66'*20,'fees':'0x'+'77'*20,
            'vault':'0x'+'88'*20,'insurance':'0x'+'99'*20,'clearing':'0x'+'aa'*20,
            'oracle':'0x'+'bb'*20,'seizer':'0x'+'cc'*20,
            'legacyCollateralRisk':'0x'+'dd'*20,
            'owner':'0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588',
            'guardian':'0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46',
            'executor':guard.EXECUTOR,'buyer':self.traders['buyer'],
            'seller':self.traders['seller'],'snapshotHash':state.SNAPSHOT,
            'deploymentBlock':47789885,
        }
        self.package.update(schema='DEOPT_RESTRICTED_FIRST_TRADE_REPLACEMENT_V1',
                            pme=self.policy['pme'],engine=self.policy['engine'],
                            engineRuntimeHash=self.policy['engineRuntimeHash'])
        self.candidate['to']=self.policy['pme']
        self.live.update(pmeEngine=self.policy['engine'],
                         riskEngine=self.policy['engine'],
                         engineRuntimeHash=self.policy['engineRuntimeHash'],
                         domainSeparator='0x'+domain(84532,self.policy['pme']).hex(),
                         migrationSnapshotHash=state.SNAPSHOT,
                         marketExists=True,marketActive=True,
                         maxExecutionDeviationBps=100,riskMaxOracleDelay=600,
                         backendLocalStopped=True,markPriceStatus='AVAILABLE',
                         markPrice1e8=self.package['trade']['executionPrice1e8'],
                         pmeV1Paused=True,oldEnginePauseFlags=[True]*4,
                         v1EnginePauseFlags=[True]*4,vaultOldAuthorized=True,
                         vaultV1Authorized=True,clearingBalanceNative=1000000000)
        self._resign()

    def _resign(self):
        digest=guard.digest(self.package['trade'],pme=self.policy['pme'])
        _,bs=synthetic_sign(digest,'buyer')
        _,ss=synthetic_sign(digest,'seller')
        data=guard.encode(self.package['trade'],bs,ss)
        self.package.update(digest=digest,
                            buyerSignatureSha256=hashlib.sha256(bs).hexdigest(),
                            sellerSignatureSha256=hashlib.sha256(ss).hexdigest(),
                            calldataSha256=hashlib.sha256(data).hexdigest())
        self.candidate['data']='0x'+data.hex()

    def _bound_bytes(self):
        policy_bytes=package_bytes(self.policy)
        self.package['deploymentPolicySha256']=guard.approved_hash(policy_bytes)
        raw=package_bytes(self.package)
        return raw,policy_bytes

    def test_replacement_domain_exact_trade_and_policy_binding(self):
        raw,policy_bytes=self._bound_bytes()
        with synthetic_traders(self.traders):
            result=guard.validate(raw,guard.approved_hash(raw),self.candidate,self.live,
                                  deployment_policy_bytes=policy_bytes)
            self.assertEqual(result['digest'],self.package['digest'])
            changed=copy.deepcopy(self.policy);changed['pme']='0x'+'12'*20
            with self.assertRaisesRegex(guard.GuardRejected,'replacement package/policy binding'):
                guard.validate(raw,guard.approved_hash(raw),self.candidate,self.live,
                               deployment_policy_bytes=package_bytes(changed))
            self.live['domainSeparator']='0x'+domain(84532,guard.PME).hex()
            with self.assertRaisesRegex(guard.GuardRejected,'wrong live EIP-712 domain'):
                guard.validate(raw,guard.approved_hash(raw),self.candidate,self.live,
                               deployment_policy_bytes=policy_bytes)

    def test_replacement_raw_one_shot_exact_bytes_and_duplicate_block(self):
        raw_tx,signer=signed_fixture(self.candidate)
        self.policy['executor']=signer
        self.package['executor']=signer
        self.candidate['from']=signer
        self.live['activeExecutors']=[signer]
        raw,policy_bytes=self._bound_bytes()
        with synthetic_traders(self.traders), patch.object(guard,'EXECUTOR',signer):
            decision,candidate,tx_hash=adapter.validated_decision(
                raw,guard.approved_hash(raw),raw_tx,self.live,
                deployment_policy_bytes=policy_bytes)
            self.assertEqual(candidate['data'],self.candidate['data'])
            with tempfile.TemporaryDirectory() as temp:
                package_path=Path(temp)/'package.json'; package_path.write_bytes(raw)
                journal=Path(temp)/'journal.json'
                fake=adapter.RecordingFakeTransport()
                with patch.object(state,'collect',lambda rpc,*,raw_size_bytes,policy:self.live):
                    result=adapter.test_only_one_shot(
                        package_path,guard.approved_hash(raw),raw_tx,journal,fake,
                        object(),deployment_policy_bytes=policy_bytes)
                    self.assertEqual(result['transactionHash'].lower(),tx_hash.lower())
                    self.assertEqual(fake.seen,[raw_tx])
                    with self.assertRaises(guard.GuardRejected):
                        adapter.test_only_one_shot(
                            package_path,guard.approved_hash(raw),raw_tx,journal,fake,
                            object(),deployment_policy_bytes=policy_bytes)
                    self.assertEqual(len(fake.seen),1)

    def test_wrong_replacement_destination_or_signed_fee_rejected_before_callback(self):
        raw_tx,signer=signed_fixture(self.candidate)
        self.policy['executor']=signer
        self.package['executor']=signer
        self.candidate['from']=signer
        self.live['activeExecutors']=[signer]
        raw,policy_bytes=self._bound_bytes()
        with synthetic_traders(self.traders), patch.object(guard,'EXECUTOR',signer):
            for changes in ({'to':'0x'+'fe'*20},{'maxFeePerGas':'12000000'}):
                bad,_=signed_fixture(self.candidate,changes=changes)
                with self.assertRaises(guard.GuardRejected):
                    adapter.validated_decision(raw,guard.approved_hash(raw),bad,self.live,
                                               deployment_policy_bytes=policy_bytes)
