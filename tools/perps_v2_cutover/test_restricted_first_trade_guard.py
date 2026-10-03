"""Synthetic-only tests. No RPC, operational key, signer service or send."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import contextmanager

import restricted_first_trade_guard as g
import signed_order_resolution as s


def synthetic_sign(digest, seed):
    """Deterministic synthetic fixture; unrelated to any DeOpt account."""
    private = int.from_bytes(s.k256(('fixture account '+seed).encode()), 'big') % (s.N-1)+1
    point = s.mul(private, s.G)
    address = '0x'+s.k256(point[0].to_bytes(32,'big')+point[1].to_bytes(32,'big'))[-20:].hex()
    z = int.from_bytes(bytes.fromhex(digest[2:]), 'big')
    k = int.from_bytes(s.k256(('fixture nonce '+seed+digest).encode()), 'big') % (s.N-1)+1
    rpoint = s.mul(k, s.G)
    rv = rpoint[0] % s.N
    sv = (pow(k,-1,s.N)*(z+rv*private)) % s.N
    v = 27+(rpoint[1]&1)
    if sv > s.N//2:
        sv = s.N-sv
        v = 27+((v-27)^1)
    sig = rv.to_bytes(32,'big')+sv.to_bytes(32,'big')+bytes([v])
    assert s.recover(bytes.fromhex(digest[2:]),'0x'+sig.hex()) == address
    return address, sig


def fixture():
    timestamp = 1790000000
    buyer_seed, seller_seed = 'buyer', 'seller'
    buyer_address, _ = synthetic_sign('0x'+'01'*32, buyer_seed)
    seller_address, _ = synthetic_sign('0x'+'01'*32, seller_seed)
    policy = {'buyer':buyer_address,'seller':seller_address,'executor':g.EXECUTOR}
    trade = {'intentId':'0x'+s.k256(b'isolated synthetic intent').hex(),
             'buyer':buyer_address,'seller':seller_address,'marketId':1,
             'sizeDelta1e8':1000,'executionPrice1e8':2468310000,
             'maxExecutionPrice1e8':2500000000,'minExecutionPrice1e8':2400000000,
             'buyerIsMaker':True,'buyerNonce':0,'sellerNonce':0,'deadline':timestamp+300}
    digest = g.digest(trade)
    _, buyer_sig = synthetic_sign(digest, buyer_seed)
    _, seller_sig = synthetic_sign(digest, seller_seed)
    data = g.encode(trade,buyer_sig,seller_sig)
    tx_fields = {'nonce':1,'gasLimit':200000,'maxFeePerGas':11000000,
                 'maxPriorityFeePerGas':1000000}
    package = {'schema':'DEOPT_RESTRICTED_FIRST_TRADE_V1','chainId':84532,
               'pme':g.PME,'engine':g.ENGINE,'engineRuntimeHash':g.ENGINE_HASH,
               'executor':g.EXECUTOR,'valueWei':0,'trade':trade,'digest':digest,
               'buyerSignatureSha256':hashlib.sha256(buyer_sig).hexdigest(),
               'sellerSignatureSha256':hashlib.sha256(seller_sig).hexdigest(),
               'calldataSha256':hashlib.sha256(data).hexdigest(),
               'transaction':tx_fields,'l1AllowanceWei':1000000000,
               'maxTotalCostWei':2201000000000}
    candidate = {'chainId':84532,'from':g.EXECUTOR,'to':g.PME,'valueWei':0,
                 'data':'0x'+data.hex(),**tx_fields}
    live = {'chainId':84532,'pmeEngine':g.ENGINE,'engineRuntimeHash':g.ENGINE_HASH,
            'domainSeparator':'0x'+s.domain().hex(),'activeExecutors':[g.EXECUTOR],
            'executorNonceConfirmed':1,'executorNoncePending':1,'pmePaused':False,
            'engineTradingPaused':False,'engineFundingPaused':False,
            'vaultAuthorized':True,'insuranceAuthorized':True,
            'feeConsumerAuthorized':True,'migrationSealed':True,'marketId':1,
            'buyerSize1e8':-10000,'sellerSize1e8':10000,
            'buyerNonce':0,'sellerNonce':0,'blockTimestamp':timestamp,
            'blockHash':'0x'+'ab'*32,'knownHistoricalIntentIds':[],
            'l1FeeQuoteWei':500000000,'executorBalanceWei':1000000000000000}
    return package,candidate,live,policy


def package_bytes(package):
    return json.dumps(package,sort_keys=True,separators=(',',':')).encode()


@contextmanager
def synthetic_traders(policy):
    # Production validate() has no trader-policy override.
    with patch.object(g, 'BUYER', policy['buyer']), patch.object(g, 'SELLER', policy['seller']):
        yield


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.package,self.candidate,self.live,self.policy = fixture()

    def check(self):
        raw=package_bytes(self.package)
        with synthetic_traders(self.policy):
            return g.validate(raw,g.approved_hash(raw),self.candidate,self.live)

    def reject(self, message):
        with self.assertRaisesRegex(g.GuardRejected,message):
            self.check()

    def resign(self, buyer_seed='buyer', seller_seed='seller'):
        trade=self.package['trade']
        d=g.digest(trade)
        _,buyer_sig=synthetic_sign(d,buyer_seed)
        _,seller_sig=synthetic_sign(d,seller_seed)
        data=g.encode(trade,buyer_sig,seller_sig)
        self.package['digest']=d
        self.package['buyerSignatureSha256']=hashlib.sha256(buyer_sig).hexdigest()
        self.package['sellerSignatureSha256']=hashlib.sha256(seller_sig).hexdigest()
        self.package['calldataSha256']=hashlib.sha256(data).hexdigest()
        self.candidate['data']='0x'+data.hex()

    def test_exact_synthetic_payload_is_accepted(self):
        decision=self.check()
        self.assertEqual(decision['digest'],self.package['digest'])
        self.assertEqual(g.decode(bytes.fromhex(self.candidate['data'][2:]))[0],
                         {**self.package['trade'],'buyer':self.policy['buyer'],
                          'seller':self.policy['seller']})

    def test_chain_verifier_and_executor_set(self):
        self.live['chainId']=1
        self.reject('wrong chain')
        self.live['chainId']=84532
        self.live['domainSeparator']='0x'+'11'*32
        self.reject('wrong live EIP-712 domain')
        self.live['domainSeparator']='0x'+s.domain().hex()
        self.live['activeExecutors'].append('0x'+'33'*20)
        self.reject('other executor')

    def test_wrong_roles_market_and_exposure(self):
        self.live['buyerSize1e8']=10000
        self.reject('oversized or exposure-increasing')
        self.live['buyerSize1e8']=-10000
        self.live['sellerSize1e8']=-10000
        self.reject('oversized or exposure-increasing')
        self.live['sellerSize1e8']=10000
        self.live['marketId']=2
        self.reject('migration/market')
        self.live['marketId']=1
        self.policy['buyer'],self.policy['seller']=self.policy['seller'],self.policy['buyer']
        self.reject('wrong close traders')

    def test_oversize_wrong_nonce_deadline(self):
        self.live['sellerSize1e8']=500
        self.reject('oversized')
        self.live['sellerSize1e8']=10000
        self.live['buyerNonce']=1
        self.reject('trader nonce')
        self.live['buyerNonce']=0
        self.live['blockTimestamp']=self.package['trade']['deadline']
        self.reject('expired')

    def test_altered_price_bounds_maker_zero_deadline(self):
        # A changed approval file cannot inherit the original approval hash.
        original=package_bytes(self.package)
        for key,value in (('executionPrice1e8',1),('maxExecutionPrice1e8',1),
                          ('buyerIsMaker',False),('deadline',0)):
            changed=copy.deepcopy(self.package)
            changed['trade'][key]=value
            with self.assertRaisesRegex(g.GuardRejected,'approved package hash changed'):
                g.validate(package_bytes(changed),g.approved_hash(original),
                           self.candidate,self.live)

    def test_wrong_market_trader_price_and_signature_bytes(self):
        changed=bytearray.fromhex(self.candidate['data'][2:])
        for word_index in (1,3,5,6,8):
            trial=changed.copy()
            trial[4+word_index*32+31] ^= 1
            self.candidate['data']='0x'+trial.hex()
            self.reject('calldata changed')
        self.candidate['data']='0x'+bytes(changed).hex()
        wrong=changed.copy()
        wrong[-1] ^= 1
        self.candidate['data']='0x'+wrong.hex()
        self.package['calldataSha256']=hashlib.sha256(wrong).hexdigest()
        self.reject('noncanonical signature padding')

    def test_alternate_entrypoints_and_trailing_bytes(self):
        for selector in (s.k256(b'executeBatch()')[:4],
                         s.k256(b'executeTradeFromIntents()')[:4]):
            wrong=selector+bytes.fromhex(self.candidate['data'][10:])
            self.candidate['data']='0x'+wrong.hex()
            self.package['calldataSha256']=hashlib.sha256(wrong).hexdigest()
            self.reject('alternate entrypoint')
        wrong=bytes.fromhex(self.candidate['data'][2:])+bytes(32)
        self.candidate['data']='0x'+wrong.hex()
        self.package['calldataSha256']=hashlib.sha256(wrong).hexdigest()
        self.reject('noncanonical calldata length')

    def test_fee_envelope_and_maintenance(self):
        self.candidate['gasLimit']+=1
        self.reject('gasLimit drift')
        self.candidate['gasLimit']-=1
        self.live['l1FeeQuoteWei']=1000000001
        self.reject('L1 allowance exceeded')
        self.live['l1FeeQuoteWei']=500000000
        self.live['executorBalanceWei']=1
        self.reject('fee budget or balance insufficient')
        self.live['executorBalanceWei']=1000000000000000
        self.live['pmePaused']=True
        self.reject('maintenance release')

    def test_zero_future_and_expired_signed_deadline(self):
        self.package['trade']['deadline']=0
        self.resign()
        self.reject('expired, zero')
        self.package['trade']['deadline']=self.live['blockTimestamp']+901
        self.resign()
        self.reject('overlong deadline')
        self.package['trade']['deadline']=self.live['blockTimestamp']-1
        self.resign()
        self.reject('expired')

    def test_valid_approval_but_wrong_signer_or_domain(self):
        self.resign(buyer_seed='unrelated local fixture')
        self.reject('signature does not match')
        self.resign()
        self.live['domainSeparator']='0x'+'11'*32
        self.reject('wrong live EIP-712 domain')

    def test_valid_approval_but_bad_economic_bounds_or_market(self):
        self.package['trade']['maxExecutionPrice1e8']=1
        self.resign()
        self.reject('buyer bound')
        self.package['trade']['maxExecutionPrice1e8']=2500000000
        self.package['trade']['marketId']=2
        self.resign()
        self.reject('invalid close economics')

    def test_intent_and_trader_nonce_are_bound(self):
        self.live['knownHistoricalIntentIds']=[self.package['trade']['intentId']]
        self.reject('intent ID not fresh')
        self.live['knownHistoricalIntentIds']=[]
        self.package['trade']['buyerNonce']=1
        self.resign()
        self.reject('trader nonce drift')

    def test_callback_not_reached_on_guard_failure(self):
        raw=package_bytes(self.package)
        self.candidate['to']='0x'+'12'*20
        calls=[]
        with tempfile.TemporaryDirectory() as td:
            with synthetic_traders(self.policy), self.assertRaises(g.GuardRejected):
                decision=g.validate(raw,g.approved_hash(raw),self.candidate,self.live)
                g.one_shot(decision,Path(td)/'journal.json',b'\x02synthetic',
                           lambda b:calls.append(b),locked_preflight=lambda:decision)
            self.assertEqual(calls,[])

    def test_persist_failure_prevents_send(self):
        raw=package_bytes(self.package)
        calls=[]
        def fail(*_):
            raise OSError('synthetic persistence failure')
        with tempfile.TemporaryDirectory() as td:
            with synthetic_traders(self.policy):
                decision=g.validate(raw,g.approved_hash(raw),self.candidate,self.live)
            with self.assertRaises(OSError):
                g.one_shot(decision,Path(td)/'journal.json',b'\x02synthetic',
                           lambda b:calls.append(b),locked_preflight=lambda:decision,persist=fail)
            self.assertEqual(calls,[])

    def test_one_shot_and_ambiguous_prior_submission(self):
        decision=self.check()
        tx=b'\x02synthetic'
        with tempfile.TemporaryDirectory() as td:
            journal=Path(td)/'journal.json'
            calls=[]
            g.one_shot(decision,journal,tx,
                       lambda b:calls.append(b) or '0x'+g.k256(b).hex(),
                       locked_preflight=lambda:decision)
            self.assertEqual(calls,[tx])
            self.assertEqual(json.loads(journal.read_text())['status'],'SUBMITTED')
            with self.assertRaisesRegex(g.GuardRejected,'prior or ambiguous'):
                g.one_shot(decision,journal,tx,
                           lambda b:calls.append(b) or '0x'+g.k256(b).hex(),
                           locked_preflight=lambda:decision)
            self.assertEqual(calls,[tx])
        with tempfile.TemporaryDirectory() as td:
            journal=Path(td)/'journal.json'
            def ambiguous(_):
                raise TimeoutError('synthetic ambiguous submission')
            with self.assertRaises(TimeoutError):
                g.one_shot(decision,journal,tx,ambiguous,locked_preflight=lambda:decision)
            self.assertEqual(json.loads(journal.read_text())['status'],'SUBMISSION_UNKNOWN')
            with self.assertRaisesRegex(g.GuardRejected,'prior or ambiguous'):
                g.one_shot(decision,journal,tx,ambiguous,locked_preflight=lambda:decision)


if __name__=='__main__':
    unittest.main()
