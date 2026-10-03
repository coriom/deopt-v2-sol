#!/usr/bin/env python3
"""Read-only, pinned Base Sepolia state for one proposed recovery close.

No eth_sendRawTransaction, keystore, database, or live signed payload path.
The RPC endpoint is read locally and never included in output or exceptions.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.request

from eth_abi import encode as abi_encode
from restricted_first_trade_guard import (BUYER, CHAIN, ENGINE, ENGINE_HASH, EXECUTOR,
                                          PME, SELLER, GuardRejected, require)
from signed_order_resolution import domain, k256

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT/'artifacts/perps_v2_restricted_first_trade_guard/preflight.json'
DEPLOYMENT = ROOT/'artifacts/perps_v2_engine_recovery_deploy/postflight.json'
HISTORICAL = ROOT/'artifacts/perps_v2_signed_order_resolution/evidence.json'
OLD = '0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9'
V1 = '0xc6C592100723Fe0C66343A16e95eC34cC0c2141c'
PME_V1 = '0x774d96E5739bffadEE91508b4D3D74F5BE29F165'
TOKEN = '0x6eAe407f5640B006faC9965182e238582A3B412E'
TIMELOCK = '0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588'
G1 = '0x824bc77bb68ff4878d2e477478ed4d120abab89ce27b181a7c8ecc5ba7cfa3f6'
G2 = '0x02705011c0ee36d4928843bfb5641ff90aebf658162735668774768a7bc3e846'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
SNAPSHOT = '0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d'
PME_RUNTIME = '0x815d473801fd4353051a3a7c1b4e9cae493786b0c3cc643a789e496e5f2813bc'
GPO = '0x420000000000000000000000000000000000000F'
ALLOWED_RPC = frozenset(('eth_chainId', 'eth_getBlockByNumber', 'eth_getCode',
                         'eth_getBalance', 'eth_getTransactionCount', 'eth_call',
                         'eth_getLogs', 'eth_getTransactionReceipt', 'eth_gasPrice',
                         'eth_maxPriorityFeePerGas'))


class RpcFault(RuntimeError):
    def __init__(self, method, code=None, message=''):
        super().__init__('RPC failure for '+method+' (endpoint redacted)')
        self.code, self.message = code, message


def configured_rpc_url():
    # Read only the named field. Never log the line, URL or process environment.
    path = ROOT/'.env.base-sepolia'
    for line in path.read_text().splitlines():
        key, sep, value = line.strip().removeprefix('export ').partition('=')
        if sep and key == 'RPC_URL':
            value = value.strip().strip('"\'')
            require(value.startswith(('https://', 'http://')), 'RPC URL missing')
            return value
    raise GuardRejected('RPC URL missing')


class PublicRpc:
    def __init__(self, endpoint):
        self.endpoint = endpoint

    def __call__(self, method, params):
        require(method in ALLOWED_RPC, 'public RPC method not read-only/allowlisted')
        req = urllib.request.Request(self.endpoint,
            data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),
            headers={'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                body = json.load(response)
        except Exception:
            raise RpcFault(method) from None
        if not isinstance(body, dict) or 'error' in body or 'result' not in body:
            error = body.get('error', {}) if isinstance(body, dict) else {}
            raise RpcFault(method, error.get('code'), str(error.get('message', '')))
        return body['result']


def number(value, label):
    require(isinstance(value, str) and re.fullmatch(r'0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)', value),
            'malformed '+label)
    return int(value, 16)


def bytes_hex(value, label, *, size=None):
    require(isinstance(value, str) and value.startswith('0x') and
            len(value[2:]) % 2 == 0 and re.fullmatch(r'[0-9a-fA-F]*', value[2:]) is not None,
            'malformed '+label)
    raw = bytes.fromhex(value[2:])
    require(size is None or len(raw) == size, 'malformed '+label)
    return raw


def signed(word):
    return word if word < 2**255 else word-2**256


def call(rpc, address, signature, types=(), args=(), tag='latest', words=1):
    require(len(types) == len(args), 'internal ABI argument mismatch')
    data = '0x'+(k256(signature.encode())[:4]+abi_encode(types, args)).hex()
    raw = bytes_hex(rpc('eth_call', [{'to':address,'data':data}, tag]), signature)
    require(len(raw) == words*32, 'malformed '+signature+' output')
    return [int.from_bytes(raw[i:i+32], 'big') for i in range(0,len(raw),32)]


def unsupported_hash_pin(error):
    return isinstance(error, RpcFault) and error.code in (-32602, -32000) and any(
        token in error.message.lower() for token in ('invalid params','unmarshal','blockhash',
        'block hash','object','not supported','unsupported'))


def pin_mode(rpc, block):
    hash_tag = {'blockHash':block['hash'], 'requireCanonical':True}
    probes = [('eth_call',[{'to':PME,'data':'0x'+k256(b'owner()')[:4].hex()},hash_tag]),
              ('eth_getCode',[ENGINE,hash_tag]), ('eth_getBalance',[EXECUTOR,hash_tag])]
    try:
        for method, params in probes:
            rpc(method, params)
        return hash_tag, 'EIP1898_BLOCK_HASH_REQUIRE_CANONICAL'
    except RpcFault as error:
        if not unsupported_hash_pin(error):
            raise
        return block['number'], 'BLOCK_NUMBER_WITH_BEFORE_AFTER_HASH_CHECK'


def address(words, label):
    require(len(words) == 1 and words[0] >> 160 == 0, 'malformed '+label)
    return '0x'+words[0].to_bytes(20,'big').hex()


def local_backend_stopped():
    # Process names only; no command lines, environments or signer material.
    matches = []
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            exe = str((process/'exe').resolve()).lower()
            name = (process/'comm').read_text().strip().lower()
        except OSError:
            continue
        if 'deopt-v2-backend' in exe or 'deopt-v2-backend' in name:
            matches.append(int(process.name))
    listeners = subprocess.check_output(['ss','-H','-ltn','sport = :8080'],text=True).strip()
    return not matches and not listeners


def active_executors(rpc, pinned, block_number):
    baseline = json.loads(BASELINE.read_text())
    require(baseline['chainId'] == CHAIN and baseline['executorEventCount'] ==
            len(baseline['executorTimeline']) and baseline['executorEventScanFromBlock'] == 47147788 and
            baseline['executorEventScanToBlock'] == baseline['comparisonBlock'], 'executor baseline invalid')
    require(block_number >= baseline['comparisonBlock'] and
            block_number-baseline['comparisonBlock'] <= 20000, 'executor baseline stale')
    old = rpc('eth_getBlockByNumber',[hex(baseline['comparisonBlock']),False])
    require(old and old['hash'].lower() == baseline['comparisonBlockHash'].lower(),
            'executor baseline block changed')
    states = {}
    for item in baseline['executorTimeline']:
        states[item['executor'].lower()] = bool(item['allowed'])
    topic = '0x'+k256(b'ExecutorSet(address,bool)').hex()
    count = 0
    for lo in range(baseline['comparisonBlock']+1, block_number+1, 2000):
        logs = rpc('eth_getLogs',[{'address':PME,'topics':[topic],
                                  'fromBlock':hex(lo),'toBlock':hex(min(lo+1999,block_number))}])
        require(isinstance(logs,list), 'malformed executor logs')
        for event in logs:
            require(event['address'].lower() == PME.lower() and len(event['topics']) == 2 and
                    event['topics'][0].lower() == topic and
                    bytes_hex(event['topics'][1], 'executor topic', size=32)[:12] == bytes(12),
                    'malformed executor event')
            state = int.from_bytes(bytes_hex(event['data'],'executor allowed',size=32),'big')
            require(state in (0,1), 'malformed executor event state')
            receipt = rpc('eth_getTransactionReceipt',[event['transactionHash']])
            event_block = rpc('eth_getBlockByNumber',[event['blockNumber'],False])
            require(receipt and number(receipt['status'],'executor receipt status') == 1 and
                    event_block and event_block['hash'].lower() == event['blockHash'].lower() and
                    receipt['blockHash'].lower() == event['blockHash'].lower(),
                    'executor event receipt mismatch')
            states['0x'+event['topics'][1][-40:].lower()] = bool(state)
            count += 1
    for executor, allowed in states.items():
        observed = call(rpc,PME,'isExecutor(address)',('address',),(executor,),pinned)[0]
        require(observed == int(allowed), 'executor inventory/mapping mismatch')
    return sorted(a for a,v in states.items() if v), count, baseline['comparisonBlock']+1


def collect(rpc, *, raw_size_bytes=None, now=None):
    """Return actual state even while paused/unbound; no readiness shortcuts."""
    require(number(rpc('eth_chainId',[]),'chainId') == CHAIN, 'wrong network')
    head = rpc('eth_getBlockByNumber',['latest',False])
    require(isinstance(head,dict) and bytes_hex(head['hash'],'block hash',size=32) != bytes(32),
            'missing block identity')
    height = number(head['number'],'block number')
    timestamp = number(head['timestamp'],'block timestamp')
    live_clock = now is None
    now = int(time.time()) if live_clock else now
    require(0 <= now-timestamp <= 300, 'stale or future block')
    tag, mode = pin_mode(rpc,head)
    deployment = json.loads(DEPLOYMENT.read_text())
    wiring = deployment['internalWiring']; constructor = deployment['constructorReadback']
    require(deployment['chainId'] == CHAIN and deployment['newEngine'].lower() == ENGINE.lower() and
            wiring['matchingEngine()'].lower() == PME.lower(), 'deployment evidence drift')
    registry = constructor['marketRegistry()']; vault = constructor['collateralVault()']
    risk = wiring['riskModule()']; insurance = wiring['insuranceFund()']
    fees = wiring['feesManagerV2()']; clearing = wiring['clearingAccount()']
    pme_code = bytes_hex(rpc('eth_getCode',[PME,tag]),'PME runtime')
    engine_code = bytes_hex(rpc('eth_getCode',[ENGINE,tag]),'Engine runtime')
    require(len(pme_code) == 10441 and '0x'+k256(pme_code).hex() == PME_RUNTIME,
            'unexpected PME runtime')
    require(len(engine_code) == 24321 and '0x'+k256(engine_code).hex() == ENGINE_HASH,
            'unexpected Engine runtime')
    get = lambda target,sig,types=(),args=(),words=1: call(rpc,target,sig,types,args,tag,words)
    addr = lambda target,sig: address(get(target,sig),sig)
    require(addr(PME,'owner()').lower() == OWNER.lower(), 'PME owner drift')
    require(addr(ENGINE,'owner()').lower() == OWNER.lower(), 'Engine owner drift')
    require(addr(ENGINE,'marketRegistry()').lower() == registry.lower() and
            addr(ENGINE,'collateralVault()').lower() == vault.lower() and
            addr(ENGINE,'oracle()').lower() == constructor['oracle()'].lower(),
            'Engine constructor drift')
    require(addr(ENGINE,'matchingEngine()').lower() == PME.lower() and
            addr(ENGINE,'riskModule()').lower() == risk.lower() and
            addr(ENGINE,'clearingAccount()').lower() == clearing.lower() and
            addr(ENGINE,'insuranceFund()').lower() == insurance.lower() and
            addr(ENGINE,'feesManagerV2()').lower() == fees.lower(), 'Engine wiring drift')
    pme_engine = addr(PME,'perpEngine()')
    risk_engine = addr(risk,'perpEngine()')
    domain_value = get(PME,'domainSeparatorV4()')[0]
    require(domain_value == int.from_bytes(domain(),'big'), 'PME domain drift')
    migration = get(ENGINE,'migrationState()')[0]
    snapshot = '0x'+get(ENGINE,'migrationSnapshotHash()')[0].to_bytes(32,'big').hex()
    require(migration == 1 and snapshot.lower() == SNAPSHOT.lower(), 'migration state drift')
    active, new_events, event_from = active_executors(rpc,tag,height)
    buyer = get(ENGINE,'positions(address,uint256)',('address','uint256'),(BUYER,1),3)
    seller = get(ENGINE,'positions(address,uint256)',('address','uint256'),(SELLER,1),3)
    market = get(ENGINE,'marketState(uint256)',('uint256',),(1,),4)
    deviation = get(registry,'getMaxExecutionDeviationBps(uint256)',('uint256',),(1,))[0]
    exists = get(registry,'marketExists(uint256)',('uint256',),(1,))[0]
    market_active = get(registry,'isMarketActive(uint256)',('uint256',),(1,))[0]
    require(deviation == 100 and exists == market_active == 1, 'market registry drift')
    mark_price, mark_status = None, 'UNAVAILABLE'
    try:
        mark_price = get(ENGINE,'getMarkPrice(uint256)',('uint256',),(1,))[0]
        require(mark_price > 0, 'zero mark price')
        mark_status = 'AVAILABLE'
    except RpcFault as error:
        # A contract revert is an explicit availability result. Transport or
        # malformed RPC failure remains fatal, never a synthetic quote.
        if 'revert' not in error.message.lower():
            raise
    historical = json.loads(HISTORICAL.read_text())
    require(historical['chainId'] == CHAIN and len(historical['intents']) == 14,
            'known-ID evidence malformed')
    known_ids = [item['reconstructedPayload']['intentIdBytes32'] for item in historical['intents']]
    l1_quote = None
    if raw_size_bytes is not None:
        require(type(raw_size_bytes) is int and 0 < raw_size_bytes <= 10000,
                'invalid signed transaction size')
        l1_quote = get(GPO,'getL1FeeUpperBound(uint256)',('uint256',),(raw_size_bytes,))[0]
    result = {
        'chainId':CHAIN, 'blockNumber':height, 'blockHash':head['hash'],
        'blockTimestamp':timestamp, 'pinningMode':mode,
        'pmeAddress':PME, 'pmeRuntimeHash':PME_RUNTIME,
        'pmeEngine':pme_engine, 'riskEngine':risk_engine,
        'engineRuntimeHash':ENGINE_HASH, 'engineRuntimeBytes':len(engine_code),
        'domainSeparator':'0x'+domain_value.to_bytes(32,'big').hex(),
        'migrationSealed':True, 'migrationSnapshotHash':snapshot,
        'marketId':1, 'marketState':[market[0],market[1],signed(market[2]),market[3]],
        'marketExists':True, 'marketActive':True,
        'maxExecutionDeviationBps':deviation,'markPrice1e8':mark_price,'markPriceStatus':mark_status,
        'riskMaxOracleDelay':get(risk,'maxOracleDelay()')[0],
        'buyerPosition':[signed(x) for x in buyer],
        'sellerPosition':[signed(x) for x in seller],
        'buyerSize1e8':signed(buyer[0]), 'sellerSize1e8':signed(seller[0]),
        'buyerNonce':get(PME,'nonces(address)',('address',),(BUYER,))[0],
        'sellerNonce':get(PME,'nonces(address)',('address',),(SELLER,))[0],
        'pmePaused':bool(get(PME,'paused()')[0]),
        'engineTradingPaused':bool(get(ENGINE,'tradingPaused()')[0]),
        'engineFundingPaused':bool(get(ENGINE,'fundingPaused()')[0]),
        'engineLiquidationPaused':bool(get(ENGINE,'liquidationPaused()')[0]),
        'engineCollateralOpsPaused':bool(get(ENGINE,'collateralOpsPaused()')[0]),
        'pmeV1Paused':bool(get(PME_V1,'paused()')[0]),
        'oldEnginePauseFlags':[bool(get(OLD,sig)[0]) for sig in
            ('tradingPaused()','liquidationPaused()','fundingPaused()','collateralOpsPaused()')],
        'v1EnginePauseFlags':[bool(get(V1,sig)[0]) for sig in
            ('tradingPaused()','liquidationPaused()','fundingPaused()','collateralOpsPaused()')],
        'vaultAuthorized':bool(get(vault,'isAuthorizedEngine(address)',('address',),(ENGINE,))[0]),
        'vaultOldAuthorized':bool(get(vault,'isAuthorizedEngine(address)',('address',),(OLD,))[0]),
        'vaultV1Authorized':bool(get(vault,'isAuthorizedEngine(address)',('address',),(V1,))[0]),
        'insuranceAuthorized':bool(get(insurance,'isBackstopCaller(address)',('address',),(ENGINE,))[0]),
        'feeConsumerAuthorized':bool(get(fees,'isFeeConsumer(address)',('address',),(ENGINE,))[0]),
        'clearingBalanceNative':get(vault,'balances(address,address)',('address','address'),
                                    (clearing,TOKEN))[0],
        'g1Queued':bool(get(TIMELOCK,'queuedTransactions(bytes32)',('bytes32',),(bytes.fromhex(G1[2:]),))[0]),
        'g2Queued':bool(get(TIMELOCK,'queuedTransactions(bytes32)',('bytes32',),(bytes.fromhex(G2[2:]),))[0]),
        'activeExecutors':active, 'executorEventsSinceBaseline':new_events,
        'executorEventScanFromBlock':event_from,
        'executorBalanceWei':number(rpc('eth_getBalance',[EXECUTOR,tag]),'executor balance'),
        'executorNonceConfirmed':number(rpc('eth_getTransactionCount',[EXECUTOR,'latest']),'confirmed nonce'),
        'executorNoncePending':number(rpc('eth_getTransactionCount',[EXECUTOR,'pending']),'pending nonce'),
        'gasPriceWei':number(rpc('eth_gasPrice',[]),'gas price'),
        'maxPriorityFeeQuoteWei':number(rpc('eth_maxPriorityFeePerGas',[]),'priority fee'),
        'l1FeeQuoteWei':l1_quote,
        'l1QuoteMethod':'GasPriceOracle.getL1FeeUpperBound(uint256)' if l1_quote is not None else None,
        'l1QuoteInputSerializedBytes':raw_size_bytes,
        'knownHistoricalIntentIds':known_ids,
        'backendLocalStopped':local_backend_stopped(),
    }
    after = rpc('eth_getBlockByNumber',[hex(height),False])
    require(after and after['hash'].lower() == head['hash'].lower(), 'pinned block hash changed')
    require(0 <= (int(time.time()) if live_clock else now)-timestamp <= 300,
            'observation expired during collection')
    return result


def readiness(live):
    """Actual maintenance state is a valid collection with NOT_ARMED verdict."""
    reasons=[]
    for key,want in (('pmeEngine',ENGINE),('riskEngine',ENGINE)):
        if live[key].lower() != want.lower(): reasons.append(key+' not rebound')
    for key in ('pmePaused','engineTradingPaused','engineFundingPaused'):
        if live[key]: reasons.append(key+' active')
    for key in ('vaultAuthorized','insuranceAuthorized','feeConsumerAuthorized','backendLocalStopped'):
        if not live[key]: reasons.append(key+' not satisfied')
    if not live['pmeV1Paused'] or not all(live['oldEnginePauseFlags']) or not all(live['v1EnginePauseFlags']):
        reasons.append('old/V1 maintenance drift')
    if not live['vaultOldAuthorized'] or not live['vaultV1Authorized'] or live['clearingBalanceNative'] != 1000000000:
        reasons.append('shared custody/ledger drift')
    if {x.lower() for x in live['activeExecutors']} != {EXECUTOR.lower()}:
        reasons.append('executor set not restricted')
    if live['executorNonceConfirmed'] != live['executorNoncePending']:
        reasons.append('executor pending nonce conflict')
    if live['markPriceStatus'] != 'AVAILABLE' or not live['markPrice1e8']:
        reasons.append('oracle mark unavailable')
    if live['l1FeeQuoteWei'] is None:
        reasons.append('exact signed transaction size/fee quote absent')
    return {'status':'ARMED_FOR_LOCAL_VALIDATION' if not reasons else 'NOT_ARMED',
            'reasons':reasons}


def main():
    observation = collect(PublicRpc(configured_rpc_url()))
    verdict = readiness(observation)
    evidence = {key: observation[key] for key in (
        'chainId','blockNumber','blockHash','blockTimestamp','pinningMode',
        'pmeRuntimeHash','pmeEngine','riskEngine','engineRuntimeHash',
        'migrationSnapshotHash','marketState','maxExecutionDeviationBps',
        'markPrice1e8','markPriceStatus','buyerPosition','sellerPosition',
        'buyerNonce','sellerNonce','pmePaused','engineTradingPaused',
        'engineFundingPaused','engineLiquidationPaused','engineCollateralOpsPaused',
        'pmeV1Paused','oldEnginePauseFlags','v1EnginePauseFlags',
        'vaultAuthorized','vaultOldAuthorized','vaultV1Authorized',
        'insuranceAuthorized','feeConsumerAuthorized','clearingBalanceNative',
        'g1Queued','g2Queued','activeExecutors','executorEventsSinceBaseline',
        'executorEventScanFromBlock','executorBalanceWei',
        'executorNonceConfirmed','executorNoncePending','gasPriceWei',
        'maxPriorityFeeQuoteWei','l1FeeQuoteWei','l1QuoteMethod',
        'l1QuoteInputSerializedBytes','backendLocalStopped')}
    evidence['readiness'] = verdict
    evidence['publicWrites'] = 0
    evidence['signedRawTransactionProvided'] = False
    output = ROOT/'artifacts/perps_v2_first_trade_execution_adapter/live_readback.json'
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(evidence,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'block':observation['blockNumber'],'blockHash':observation['blockHash'],
                      'pinningMode':observation['pinningMode'],'readiness':verdict,
                      'evidence':str(output.relative_to(ROOT))}))


if __name__=='__main__':
    main()
