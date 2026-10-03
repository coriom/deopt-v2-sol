"""Synthetic-only RPC, EIP-1559 and one-shot tests. No public sender."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import first_trade_execution_adapter as adapter
import first_trade_live_state as state
import restricted_first_trade_guard as guard
from test_restricted_first_trade_guard import fixture, package_bytes, synthetic_traders
from signed_order_resolution import k256


def signed_fixture(candidate, *, changes=None, seed='synthetic adapter fixture only'):
    tx = {'chainId':candidate['chainId'],'to':candidate['to'],'value':str(candidate['valueWei']),
          'nonce':candidate['nonce'],'gas':str(candidate['gasLimit']),
          'maxFeePerGas':str(candidate['maxFeePerGas']),
          'maxPriorityFeePerGas':str(candidate['maxPriorityFeePerGas']),
          'data':candidate['data'],'accessList':[]}
    tx.update(changes or {})
    js = """const fs=require('fs'),v=require('viem');
      const {privateKeyToAccount}=require('viem/accounts');
      (async()=>{const i=JSON.parse(fs.readFileSync(0,'utf8'));
      const a=privateKeyToAccount(v.keccak256(v.toHex(i.seed)));
      const t=i.tx; for(const k of ['value','gas','maxFeePerGas','maxPriorityFeePerGas'])t[k]=BigInt(t[k]);
      const raw=await a.signTransaction(t);
      process.stdout.write(JSON.stringify({raw,address:a.address}));})().catch(()=>process.exit(1))"""
    p=subprocess.run(['node','-e',js],input=json.dumps({'tx':tx,'seed':seed}),text=True,
                     capture_output=True,check=True,timeout=15,
                     cwd=state.ROOT.parent/'deopt-v2-frontend')
    value=json.loads(p.stdout)
    return bytes.fromhex(value['raw'][2:]), value['address']


def w(x):
    return int(x).to_bytes(32,'big').hex()


class FakeRpc:
    def __init__(self, *, hash_pin=True):
        self.now=int(time.time())
        self.height=47619182
        self.hash='0x'+'ab'*32
        self.hash_pin=hash_pin
        self.change_hash=False
        self.chain=84532
        self.fail_signature=None
        self.extra_executor=False
        self.calls=[]
        self.deployment=json.loads(state.DEPLOYMENT.read_text())
        self.baseline=json.loads(state.BASELINE.read_text())
        self.pme_code=b'\x11'*10441
        self.engine_code=b'\x22'*24321
        self.wiring=self.deployment['internalWiring']
        self.constructor=self.deployment['constructorReadback']

    def __call__(self, method, params):
        self.calls.append(method)
        if method=='eth_chainId':return hex(self.chain)
        if method=='eth_getBlockByNumber':
            if params[0]==hex(self.baseline['comparisonBlock']):
                return {'hash':self.baseline['comparisonBlockHash']}
            return {'number':hex(self.height),'hash':('0x'+'cd'*32 if self.change_hash and
                    params[0] != 'latest' else self.hash),'timestamp':hex(self.now),'baseFeePerGas':'0x1'}
        if method in ('eth_call','eth_getCode','eth_getBalance'):
            tag=params[1]
            if isinstance(tag,dict) and not self.hash_pin:
                raise state.RpcFault(method,-32602,'invalid params: blockHash object not supported')
            target=params[0]['to'].lower() if method=='eth_call' else params[0].lower()
            if method=='eth_getCode':
                return '0x'+(self.pme_code if target==guard.PME.lower() else self.engine_code).hex()
            if method=='eth_getBalance':return hex(10**18)
            data=params[0]['data']; selector=data[:10]
            sig=next((s for s in self.signatures if '0x'+k256(s.encode())[:4].hex()==selector),None)
            if self.fail_signature==sig:return '0x'
            return self.response(target,sig,data)
        if method=='eth_getLogs':
            if not self.extra_executor:return []
            topic='0x'+k256(b'ExecutorSet(address,bool)').hex()
            return [{'address':guard.PME,'topics':[topic,'0x'+bytes(12).hex()+'33'*20],
                     'data':'0x'+w(1),'blockNumber':hex(self.height),
                     'blockHash':self.hash,'transactionHash':'0x'+'99'*32}]
        if method=='eth_getTransactionReceipt':
            return {'status':'0x1','blockHash':self.hash}
        if method=='eth_getTransactionCount':return '0x1'
        if method=='eth_gasPrice':return '0x100'
        if method=='eth_maxPriorityFeePerGas':return '0x10'
        raise AssertionError('unexpected RPC method '+method)

    signatures = ('owner()','marketRegistry()','collateralVault()','oracle()',
      'matchingEngine()','riskModule()','clearingAccount()','insuranceFund()','feesManagerV2()',
      'perpEngine()','domainSeparatorV4()','migrationState()',
      'migrationSnapshotHash()','isExecutor(address)','positions(address,uint256)',
      'marketState(uint256)','getMaxExecutionDeviationBps(uint256)',
      'marketExists(uint256)','isMarketActive(uint256)','getMarkPrice(uint256)',
      'maxOracleDelay()','nonces(address)','paused()','tradingPaused()',
      'fundingPaused()','liquidationPaused()','collateralOpsPaused()',
      'isAuthorizedEngine(address)','isBackstopCaller(address)',
      'isFeeConsumer(address)','getL1FeeUpperBound(uint256)')
    signatures += ('balances(address,address)',)
    signatures += ('queuedTransactions(bytes32)',)

    def response(self,target,sig,data):
        require=sig is not None
        if not require:raise AssertionError('unknown selector')
        def addr(x):return int(x,16)
        if sig=='owner()':return '0x'+w(addr(state.OWNER))
        if sig in self.constructor:return '0x'+w(addr(self.constructor[sig]))
        if sig in self.wiring:return '0x'+w(addr(self.wiring[sig]))
        if sig=='perpEngine()':return '0x'+w(addr(state.OLD))
        if sig=='domainSeparatorV4()':return '0x'+w(int.from_bytes(state.domain(),'big'))
        if sig=='migrationState()':return '0x'+w(1)
        if sig=='migrationSnapshotHash()':return '0x'+state.SNAPSHOT[2:]
        if sig=='isExecutor(address)':
            a='0x'+data[-40:].lower()
            return '0x'+w(int(a in (state.OWNER.lower(),state.EXECUTOR.lower()) or
                             (self.extra_executor and a=='0x'+'33'*20)))
        if sig=='positions(address,uint256)':
            a='0x'+data[10+24:10+64].lower()
            sign=-1 if a==guard.BUYER.lower() else 1
            return '0x'+w(sign*1000000%(1<<256))+w(sign*2468310000%(1<<256))+w(0)
        if sig=='marketState(uint256)':return '0x'+w(1001002)+w(1001002)+w(0)+w(1789715546)
        if sig=='getMaxExecutionDeviationBps(uint256)':return '0x'+w(100)
        if sig in ('marketExists(uint256)','isMarketActive(uint256)'):return '0x'+w(1)
        if sig=='getMarkPrice(uint256)':return '0x'+w(2468310000)
        if sig=='maxOracleDelay()':return '0x'+w(600)
        if sig=='nonces(address)':return '0x'+w(0)
        if sig in ('paused()','tradingPaused()','fundingPaused()',
                   'liquidationPaused()','collateralOpsPaused()'):return '0x'+w(1)
        if sig=='isAuthorizedEngine(address)':
            a='0x'+data[-40:].lower()
            return '0x'+w(int(a in (state.OLD.lower(),state.V1.lower())))
        if sig in ('isBackstopCaller(address)','isFeeConsumer(address)'):return '0x'+w(0)
        if sig=='balances(address,address)':return '0x'+w(1000000000)
        if sig=='queuedTransactions(bytes32)':return '0x'+w(1)
        if sig=='getL1FeeUpperBound(uint256)':return '0x'+w(500000000)
        raise AssertionError(sig)


class CollectorTest(unittest.TestCase):
    def setUp(self):
        self.rpc=FakeRpc()
        self.patches=[patch.object(state,'PME_RUNTIME','0x'+k256(self.rpc.pme_code).hex()),
                      patch.object(state,'ENGINE_HASH','0x'+k256(self.rpc.engine_code).hex()),
                      patch.object(state,'local_backend_stopped',lambda:True)]
        for item in self.patches:item.start()
        self.addCleanup(lambda:[item.stop() for item in reversed(self.patches)])

    def test_coherent_pinned_collection_reports_not_armed(self):
        result=state.collect(self.rpc,now=self.rpc.now)
        self.assertEqual(result['pinningMode'],'EIP1898_BLOCK_HASH_REQUIRE_CANONICAL')
        self.assertEqual(result['buyerSize1e8'],-1000000)
        self.assertEqual(result['sellerSize1e8'],1000000)
        self.assertEqual(state.readiness(result)['status'],'NOT_ARMED')
        self.assertEqual(result['l1FeeQuoteWei'],None)

    def test_block_number_fallback_and_hash_change(self):
        self.rpc.hash_pin=False
        self.assertEqual(state.collect(self.rpc,now=self.rpc.now)['pinningMode'],
                         'BLOCK_NUMBER_WITH_BEFORE_AFTER_HASH_CHECK')
        self.rpc.change_hash=True
        with self.assertRaisesRegex(guard.GuardRejected,'pinned block hash changed'):
            state.collect(self.rpc,now=self.rpc.now)

    def test_wrong_chain_stale_malformed_runtime_and_extra_executor(self):
        self.rpc.chain=1
        with self.assertRaisesRegex(guard.GuardRejected,'wrong network'):
            state.collect(self.rpc,now=self.rpc.now)
        self.rpc.chain=84532
        with self.assertRaisesRegex(guard.GuardRejected,'stale or future'):
            state.collect(self.rpc,now=self.rpc.now+301)
        self.rpc.pme_code=b'\x00'
        with self.assertRaisesRegex(guard.GuardRejected,'unexpected PME runtime'):
            state.collect(self.rpc,now=self.rpc.now)
        self.rpc.pme_code=b'\x11'*10441
        self.rpc.fail_signature='owner()'
        with self.assertRaisesRegex(guard.GuardRejected,'malformed owner'):
            state.collect(self.rpc,now=self.rpc.now)
        self.rpc.fail_signature=None
        self.rpc.extra_executor=True
        result=state.collect(self.rpc,now=self.rpc.now)
        self.assertEqual(len(result['activeExecutors']),3)
        self.assertIn('executor set not restricted',state.readiness(result)['reasons'])

    def test_separate_pending_nonce_and_fee_inputs(self):
        original=self.rpc.__call__
        def divergent(method,params):
            if method=='eth_getTransactionCount' and params[1]=='pending':return '0x2'
            return original(method,params)
        result=state.collect(divergent,raw_size_bytes=800,now=self.rpc.now)
        self.assertEqual(result['l1QuoteInputSerializedBytes'],800)
        self.assertEqual(result['l1FeeQuoteWei'],500000000)
        self.assertIn('executor pending nonce conflict',state.readiness(result)['reasons'])


class SignedAdapterTest(unittest.TestCase):
    def setUp(self):
        self.package,self.candidate,self.live,self.policy=fixture()
        self.raw,self.synthetic_executor=signed_fixture(self.candidate)
        self.package['executor']=self.synthetic_executor
        self.candidate['from']=self.synthetic_executor
        self.live['activeExecutors']=[self.synthetic_executor]
        self.live.update({'riskEngine':guard.ENGINE,'migrationSnapshotHash':state.SNAPSHOT,
            'marketExists':True,'marketActive':True,'maxExecutionDeviationBps':100,
            'riskMaxOracleDelay':600,'backendLocalStopped':True,
            'markPriceStatus':'AVAILABLE','markPrice1e8':2468310000,
            'l1FeeQuoteWei':500000000,'pmeV1Paused':True,
            'oldEnginePauseFlags':[True]*4,'v1EnginePauseFlags':[True]*4,
            'vaultOldAuthorized':True,'vaultV1Authorized':True,
            'clearingBalanceNative':1000000000})
        self.patches=[patch.object(guard,'EXECUTOR',self.synthetic_executor),
                      patch.object(state,'EXECUTOR',self.synthetic_executor),
                      patch.object(guard,'BUYER',self.policy['buyer']),
                      patch.object(guard,'SELLER',self.policy['seller'])]
        for item in self.patches:item.start()
        self.addCleanup(lambda:[item.stop() for item in reversed(self.patches)])

    def decide(self,raw=None):
        return adapter.validated_decision(package_bytes(self.package),
            guard.approved_hash(package_bytes(self.package)),raw or self.raw,self.live)

    def test_type2_positive_and_independent_cast_crosscheck(self):
        candidate,hash_value=adapter.decode_signed_raw(self.raw)
        self.assertEqual({**candidate,'to':candidate['to'].lower(),
                          'from':candidate['from'].lower()},
                         {**self.candidate,'to':self.candidate['to'].lower(),
                          'from':self.candidate['from'].lower()})
        self.assertEqual(hash_value,'0x'+k256(self.raw).hex())
        # Foundry is independent of viem; compare a synthetic signed vector.
        out=subprocess.run(['cast','decode-transaction','--json'],
            input='0x'+self.raw.hex(),text=True,capture_output=True,check=True,timeout=10)
        other=json.loads(out.stdout)
        self.assertEqual(int(other['chainId'],16) if isinstance(other['chainId'],str) else other['chainId'],84532)
        self.assertEqual(other['to'].lower(),guard.PME.lower())
        self.assertEqual(self.decide()[2],hash_value)

    def test_wrong_signer_destination_nonce_data_and_fee(self):
        wrong_signer,_=signed_fixture(self.candidate,seed='unrelated synthetic executor')
        with self.assertRaisesRegex(guard.GuardRejected,'sender/target'):
            adapter.decode_signed_raw(wrong_signer)
        for change in ({'to':'0x'+'33'*20},{'nonce':2},
                       {'data':'0x7101c201'},{'maxFeePerGas':'12000000'}):
            raw,_=signed_fixture(self.candidate,changes=change)
            with self.assertRaises(guard.GuardRejected):
                adapter.validated_decision(package_bytes(self.package),
                    guard.approved_hash(package_bytes(self.package)),raw,self.live)
        # Unpatched production policy rejects synthetic executor identity.
        with patch.object(guard,'EXECUTOR','0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8'):
            with self.assertRaisesRegex(guard.GuardRejected,'sender/target'):
                adapter.decode_signed_raw(self.raw)

    def test_type_access_list_and_changed_raw_bytes(self):
        raw,_=signed_fixture(self.candidate,changes={'accessList':[{'address':guard.PME,'storageKeys':[]}]})
        with self.assertRaisesRegex(guard.GuardRejected,'decode/recovery failed'):
            adapter.decode_signed_raw(raw)
        with self.assertRaisesRegex(guard.GuardRejected,'unsupported signed transaction form'):
            adapter.decode_signed_raw(b'\x01'+self.raw[1:])
        changed=self.raw[:-1]+bytes([self.raw[-1]^1])
        with self.assertRaises(guard.GuardRejected):
            adapter.validated_decision(package_bytes(self.package),
                guard.approved_hash(package_bytes(self.package)),changed,self.live)

    def test_fake_transport_exact_bytes_and_one_shot(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'approved.json';path.write_bytes(package_bytes(self.package))
            journal=Path(tmp)/'journal.json';fake=adapter.RecordingFakeTransport()
            with patch.object(state,'collect',lambda rpc,raw_size_bytes:copy.deepcopy(self.live)):
                result=adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                    self.raw,journal,fake,object())
                self.assertEqual(fake.seen,[self.raw])
                self.assertEqual(result['journalStatus'],'SUBMITTED_NOT_CONFIRMED')
                with self.assertRaisesRegex(guard.GuardRejected,'prior or ambiguous'):
                    adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                        self.raw,journal,fake,object())
                self.assertEqual(fake.seen,[self.raw])

    def test_changed_package_or_final_nonce_never_reaches_transport(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'approved.json';path.write_bytes(package_bytes(self.package))
            approved=guard.approved_hash(path.read_bytes())
            journal=Path(tmp)/'journal.json';fake=adapter.RecordingFakeTransport();reads=[0]
            def change_package(rpc,raw_size_bytes):
                reads[0]+=1
                if reads[0]==2:path.write_bytes(path.read_bytes()+b' ')
                return copy.deepcopy(self.live)
            with patch.object(state,'collect',change_package):
                with self.assertRaisesRegex(guard.GuardRejected,'package file changed'):
                    adapter.test_only_one_shot(path,approved,self.raw,journal,
                        fake,object())
            self.assertEqual(fake.seen,[])
            self.assertFalse(journal.exists())
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'approved.json';path.write_bytes(package_bytes(self.package))
            journal=Path(tmp)/'journal.json';reads=[0];fake=adapter.RecordingFakeTransport()
            def change_nonce(rpc,raw_size_bytes):
                reads[0]+=1
                live=copy.deepcopy(self.live)
                if reads[0]==2:live['executorNoncePending']=2
                return live
            with patch.object(state,'collect',change_nonce):
                with self.assertRaisesRegex(guard.GuardRejected,'LIVE_EXECUTION_NOT_ARMED'):
                    adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                        self.raw,journal,fake,object())
            self.assertEqual(fake.seen,[])
            self.assertFalse(journal.exists())

    def test_changed_raw_bytes_cannot_reach_transport(self):
        changed=self.raw[:-1]+bytes([self.raw[-1]^1]);fake=adapter.RecordingFakeTransport()
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'approved.json';path.write_bytes(package_bytes(self.package))
            with patch.object(state,'collect',lambda rpc,raw_size_bytes:copy.deepcopy(self.live)):
                with self.assertRaises(guard.GuardRejected):
                    adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                        changed,Path(tmp)/'journal.json',fake,object())
        self.assertEqual(fake.seen,[])

    def test_rejection_persistence_and_ambiguity_never_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'approved.json';path.write_bytes(package_bytes(self.package))
            journal=Path(tmp)/'journal.json';fake=adapter.RecordingFakeTransport()
            with patch.object(state,'collect',lambda rpc,raw_size_bytes:copy.deepcopy(self.live)):
                with self.assertRaisesRegex(guard.GuardRejected,'approved package hash'):
                    adapter.test_only_one_shot(path,'00'*32,self.raw,journal,fake,object())
                self.assertFalse(fake.seen)
                def fail(*_):raise OSError('synthetic disk failure')
                with self.assertRaises(OSError):
                    adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                        self.raw,journal,fake,object(),persist=fail)
                self.assertFalse(fake.seen)
            with tempfile.TemporaryDirectory() as tmp2:
                journal2=Path(tmp2)/'journal.json'
                timeout=adapter.RecordingFakeTransport(timeout=True)
                with patch.object(state,'collect',lambda rpc,raw_size_bytes:copy.deepcopy(self.live)):
                    with self.assertRaises(TimeoutError):
                        adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                            self.raw,journal2,timeout,object())
                    with self.assertRaisesRegex(guard.GuardRejected,'prior or ambiguous'):
                        adapter.test_only_one_shot(path,guard.approved_hash(path.read_bytes()),
                            self.raw,journal2,timeout,object())
                self.assertEqual(timeout.seen,[self.raw])


if __name__=='__main__':unittest.main()
