"""M3 Stage A: allowlisted live reads, then eight seeds ONLY on a private local fork."""
import concurrent.futures
from decimal import Decimal
from functools import lru_cache
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/perps_v2_cutover'))
from migration_replay import NEW,OLD,OWNER,SNAPSHOT,DESTINATION,SOURCE,verify_canonical,validate_steps,sha256,cast
from snapshot_hash import keccak256
from recovery_preflight import linked,ENGINE_HASH
manifest,hashes=verify_canonical()
package=json.loads((DESTINATION/'execution_package.json').read_text())
artifact=json.loads((ROOT/'out/PerpEngineV2.sol/PerpEngineV2.json').read_text())
records=validate_steps(json.loads((SOURCE/'seed_calldata.json').read_text()),package,manifest,artifact)
previous=json.loads((ROOT/'artifacts/perps_v2_engine_recovery_deploy/postflight.json').read_text())
layout=json.loads((DESTINATION/'storage_layout.json').read_text())
slots={x['label']:int(x['slot']) for x in layout['storage']}
(DESTINATION/'storage_layout.json').write_text(json.dumps(layout,indent=2)+'\n')
V1=manifest['engineV1']; PME1=manifest['pmeV1']
deps={**previous['constructorReadback'],**previous['internalWiring']}
PMR=deps['marketRegistry()']; VAULT=deps['collateralVault()']; PME=deps['matchingEngine()']; RISK=deps['riskModule()']
TOKEN='0x6eAe407f5640B006faC9965182e238582A3B412E'
SAFE='0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46'; EXECUTOR='0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8'
url=None
for line in (ROOT/'.env.base-sepolia').read_text().splitlines():
    key,sep,value=line.strip().removeprefix('export ').partition('=')
    if sep and key=='RPC_URL': url=value.strip().strip('\"\'')
READS={'eth_chainId','eth_getBlockByNumber','eth_getTransactionCount','eth_getBalance','eth_getCode','eth_call','eth_getStorageAt','eth_getLogs','eth_gasPrice','eth_maxPriorityFeePerGas','eth_getTransactionReceipt','eth_getTransactionByHash','web3_clientVersion'}
def request(endpoint,method,params):
    try:
        req=urllib.request.Request(endpoint,data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=45) as response: data=json.load(response)
    except Exception: raise RuntimeError('RPC transport failure; endpoint redacted') from None
    if 'error' in data:
        message=str(data['error'].get('message','')).replace(url,'<RPC_REDACTED>')
        message=re.sub(r'https?://[^\s\"\']+','<RPC_REDACTED>',message)
        raise RuntimeError('RPC error for '+method+'; '+message[:500])
    return data['result']
def live(method,params):
    assert method in READS, 'Public RPC write forbidden in Stage A'
    return request(url,method,params)
@lru_cache(maxsize=None)
def calldata(sig,args=()): return cast('calldata',sig,*map(str,args))
def call(rpc,address,sig,args=(),tag='latest'):
    data=rpc('eth_call',[{'to':address,'data':calldata(sig,tuple(args))},tag])
    assert len(data)>=66 and (len(data)-2)%64==0, sig
    return [int(data[i:i+64],16) for i in range(2,len(data),64)]
def expect(rpc,address,sig,want,args=(),tag='latest'):
    want=want if isinstance(want,list) else [want]
    encoded=[int(v,16) if isinstance(v,str) and v.startswith('0x') else v%(1<<256) for v in want]
    actual=call(rpc,address,sig,args,tag)
    assert actual==encoded, sig+' state mismatch at '+address
    return want[0] if len(want)==1 else want
def slot_for(label,*keys):
    value=slots[label]
    for key in keys:
        key=int(key,16) if isinstance(key,str) else key
        value=int.from_bytes(keccak256(key.to_bytes(32,'big')+value.to_bytes(32,'big')),'big')
    return hex(value)
def flag(rpc,label,keys,want,tag='latest',engine=NEW):
    location=slot_for(label,*keys)
    actual=int(rpc('eth_getStorageAt',[engine,location,tag]),16)
    assert actual==want, 'Unexpected seed flag '+label+' '+str(keys)
    return {'label':label,'keys':list(keys),'slot':location,'value':actual}
def backend_stopped():
    for p in Path('/proc').iterdir():
        if not p.name.isdigit(): continue
        try: exe,comm=str((p/'exe').resolve()).lower(),(p/'comm').read_text().lower()
        except OSError: continue
        assert 'deopt' not in exe and 'deopt' not in comm,'Backend process exists'
    assert not subprocess.check_output(['ss','-H','-ltn','sport = :8080'],text=True).strip()
    return {'backend_runtime_state':'STOPPED','transaction_emission_capability':'NONE','backendProcesses':0,'port8080Listeners':0}

assert int(live('eth_chainId',[]),16)==84532
block=live('eth_getBlockByNumber',['latest',False]); tag=block['number']
nonce=int(live('eth_getTransactionCount',[OWNER,tag]),16)
pending=int(live('eth_getTransactionCount',[OWNER,'pending']),16)
assert nonce==pending==799,'OWNER nonce drift; separate review required'
assert live('eth_getBlockByNumber',[hex(manifest['snapshotBlockNumber']),False])['hash']==manifest['snapshotBlockHash']
code=bytes.fromhex(live('eth_getCode',[NEW,tag])[2:])
assert code==linked(artifact,'deployedBytecode') and len(code)==24321 and '0x'+keccak256(code).hex()==ENGINE_HASH
report={'stage':'A','publicWrites':0,'keystoreUnlocked':False,'chainId':84532,'block':int(tag,16),'blockHash':block['hash'],
        'ownerNonce':nonce,'pendingNonce':pending,'ownerBalanceWei':int(live('eth_getBalance',[OWNER,tag]),16),
        'snapshotHash':SNAPSHOT,'canonicalFileSha256':hashes,'packageSha256':sha256((DESTINATION/'execution_package.json').read_bytes()),
        'runtime':{'bytes':len(code),'ethereumKeccak256':ENGINE_HASH,'byteEqualFrozenArtifact':True},'checks':[]}
checks=[]
def add(label,address,sig,want,args=()): checks.append((label,address,sig,want,args))
for getter,want in deps.items(): add('NEW.'+getter,NEW,getter,want)
for getter in ['migrationState()','migrationSnapshotHash()','totalResidualBadDebtBase()']: add('NEW.'+getter,NEW,getter,0)
add('V1.PME.paused',PME1,'paused()',1); add('V1.liquidationPaused',V1,'liquidationPaused()',1)
add('OLD.migrationState',OLD,'migrationState()',1); add('OLD.snapshot',OLD,'migrationSnapshotHash()',SNAPSHOT)
add('OLD.registry',OLD,'marketRegistry()','0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC')
for engine,want in [(V1,1),(OLD,1),(NEW,0)]: add('Vault.'+engine,VAULT,'isAuthorizedEngine(address)',want,[engine])
for contract in [PME,RISK]: add('Shared.perpEngine.'+contract,contract,'perpEngine()',OLD)
add('NEW.feeConsumer',deps['feesManagerV2()'],'isFeeConsumer(address)',0,[NEW])
add('NEW.backstopCaller',deps['insuranceFund()'],'isBackstopCaller(address)',0,[NEW])
add('Clearing.balance',VAULT,'balances(address,address)',1000000000,[deps['clearingAccount()'],TOKEN])
for m in manifest['markets']:
    mid=m['marketId']; values=[m[k] for k in ['longOI1e8','shortOI1e8','cumulativeFundingRate1e18','lastFundingTimestamp']]
    add('NEW.market.'+str(mid),NEW,'marketState(uint256)',[0,0,0,0],[mid])
    for engine in [V1,OLD]: add('canonical.market.'+engine+'.'+str(mid),engine,'marketState(uint256)',values,[mid])
    for sig,want in [('getMaxExecutionDeviationBps(uint256)',100),('marketExists(uint256)',1),('isMarketActive(uint256)',1)]: add('PMR.'+sig+'.'+str(mid),PMR,sig,want,[mid])
for p in manifest['positions']:
    trader=p['trader']; mid=p['marketId']; values=[p[k] for k in ['size1e8','openNotional1e8','lastCumulativeFundingRate1e18']]
    for engine in [V1,OLD]: add('canonical.position.'+engine+'.'+trader,engine,'positions(address,uint256)',values,[trader,mid])
    for market in [1,2]: add('NEW.position.'+trader+'.'+str(market),NEW,'positions(address,uint256)',[0,0,0],[trader,market])
    for sig in ['getTraderMarketsLength(address)','totalAbsLongSize1e8(address)','totalAbsShortSize1e8(address)']: add('NEW.'+sig+'.'+trader,NEW,sig,0,[trader])
    for engine in [V1,OLD,NEW]: add('debt.'+engine+'.'+trader,engine,'getResidualBadDebt(address)',0,[trader])
for engine in [V1,OLD]: add('totalDebt.'+engine,engine,'totalResidualBadDebtBase()',0)
for p in manifest['pmeNonces']: add('V1.nonce.'+p['trader'],PME1,'nonces(address)',p['nonce'],[p['trader']])
for item in manifest['vaultBalances']: add('canonical.vault.'+item['user'],VAULT,'balances(address,address)',item['balance'],[item['user'],item['token']])
def runcheck(item):
    label,address,sig,want,args=item
    return {'label':label,'value':expect(live,address,sig,want,args,tag),'passed':True}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool: report['checks']=list(pool.map(runcheck,checks))
report['seedFlags']=[]
for mid in [1,2]: report['seedFlags'].append(flag(live,'_marketFundingSeeded',(mid,),0,tag))
for p in manifest['positions']:
    report['seedFlags'].append(flag(live,'_positionSeeded',(p['trader'],p['marketId']),0,tag))
    report['seedFlags'].append(flag(live,'_residualBadDebtSeeded',(p['trader'],),0,tag))
report['pmeV2Nonces']={p['trader']:call(live,PME,'nonces(address)',[p['trader']],tag)[0] for p in manifest['positions']}
report['safeNonce']=call(live,SAFE,'nonce()',tag=tag)[0]
report['executorNonce']=int(live('eth_getTransactionCount',[EXECUTOR,tag]),16)
assert int(live('eth_getTransactionCount',[EXECUTOR,'pending']),16)==report['executorNonce']
event_abis=[a for a in artifact['abi'] if a['type']=='event' and (a['name'].startswith('Migration') or a['name']=='TradeExecuted')]
def topic(a): return '0x'+keccak256((a['name']+'('+','.join(x['type'] for x in a['inputs'])+')').encode()).hex()
topics=[topic(a) for a in event_abis]
topics.append('0x5018a0a73d56c00e01815636cf5e029fd7ed9440d42b3eea0e75404dfedb3f80')
start=previous['block']
events=live('eth_getLogs',[{'address':[NEW,OLD,V1,PME,PME1],'fromBlock':hex(start),'toBlock':tag,'topics':[topics]}])
assert not events,'Unexpected migration/trade since postflight'
new_events=live('eth_getLogs',[{'address':NEW,'fromBlock':hex(previous['transactions'][0]['block']),'toBlock':tag,'topics':[topics]}])
assert not new_events,'NEW_ENGINE already seeded or traded'
report['eventScan']={'fromBlock':start,'toBlock':int(tag,16),'emitters':[NEW,OLD,V1,PME,PME1],'topics':topics,'events':0,'newEngineSinceCreateEvents':0}
report.update(backend_stopped())
base_fee=int(block['baseFeePerGas'],16); priority=int(live('eth_maxPriorityFeePerGas',[]),16)
gas_price=int(live('eth_gasPrice',[]),16)
max_fee=max(2*base_fee+priority,gas_price)
report['fees']={'baseFeePerGasWei':base_fee,'priorityFeePerGasWei':priority,'gasPriceWei':gas_price,'maxFeePerGasWei':max_fee,
                'gasMarginPercent':30,'l1AllowanceMultiplier':2,'l1UnsignedSizeUpperBoundBytes':512}
# A 512-byte signed-envelope bound exceeds each actual 100/164-byte calldata tx.
# Query the deployed OP GasPriceOracle's upper bound at the same pinned block.
gpo='0x420000000000000000000000000000000000000F'
l1_bound=call(live,gpo,'getL1FeeUpperBound(uint256)',[512],tag)[0]
report['fees']['l1FeeUpperBoundPerTxWei']=l1_bound
(DESTINATION/'preflight.json').write_text(json.dumps(report,indent=2)+'\n')
print('LIVE PREFLIGHT PASS',report['block'],'nonce',nonce,'checks',len(checks),'all seed flags zero; scoped events zero',flush=True)

# The public endpoint is never passed to the write-capable function below.
subprocess.run(['free','-h'],check=True)
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
local_url='http://127.0.0.1:'+str(port)
args=['anvil','--fork-url',url,'--fork-block-number',str(report['block']),'--chain-id','84532',
      '--host','127.0.0.1','--port',str(port),'--accounts','0','--quiet','--threads','1',
      '--no-storage-caching','--disable-default-create2-deployer','--optimism']
process=subprocess.Popen(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def local(method,params):
    parsed=urllib.parse.urlparse(local_url)
    assert parsed.hostname=='127.0.0.1' and parsed.port==port and process.poll() is None
    assert method in READS|{'anvil_impersonateAccount','eth_estimateGas','eth_sendTransaction','anvil_stopImpersonatingAccount','debug_traceTransaction'}
    return request(local_url,method,params)
simulation={'kind':'isolated local Anvil fork; NOT public Base Sepolia','localRpc':local_url,'forkBlock':report['block'],'chainId':84532,
            'codeReplaced':False,'storageEdited':False,'mockedCalls':False,'keystoreUnlocked':False,'transactions':[]}
try:
    for _ in range(60):
        if process.poll() is not None: raise RuntimeError('Local Anvil failed to start; no public writes')
        try:
            client=local('web3_clientVersion',[])
            if 'anvil' in client.lower(): break
        except RuntimeError: pass
        time.sleep(0.5)
    else: raise RuntimeError('Local Anvil startup timeout')
    assert int(local('eth_chainId',[]),16)==84532
    assert local('eth_getCode',[NEW,'latest'])=='0x'+code.hex()
    assert local('eth_getBlockByNumber',[tag,False])['hash']==block['hash']
    fork_balance=int(local('eth_getBalance',[OWNER,'latest']),16)
    fork_nonce=int(local('eth_getTransactionCount',[OWNER,'latest']),16)
    assert fork_balance==report['ownerBalanceWei'] and fork_nonce==799, 'Fork account state mismatch'
    print('LOCAL FORK account matches pinned public state; balance wei',fork_balance,'nonce',fork_nonce,flush=True)
    local('anvil_impersonateAccount',[OWNER])
    oi=[0,0]
    for step in package['orderedSteps']:
        i=step['ordinal']; values=step['args']
        expect(local,NEW,'migrationState()',0)
        expect(local,NEW,'migrationSnapshotHash()',0)
        if i<=2: flag(local,'_marketFundingSeeded',(values['marketId'],),0)
        else:
            flag(local,'_positionSeeded',(values['trader'],values['marketId']),0)
            expect(local,NEW,'positions(address,uint256)',[0,0,0],[values['trader'],values['marketId']])
        tx={'from':OWNER,'to':NEW,'data':step['calldata'],'value':'0x0','nonce':hex(798+i),
            'maxFeePerGas':hex(max_fee),'maxPriorityFeePerGas':hex(priority),'gas':hex(1000000)}
        estimate=int(local('eth_estimateGas',[tx]),16); limit=(estimate*130+99)//100
        tx['gas']=hex(limit)
        txhash=local('eth_sendTransaction',[tx])
        for _ in range(120):
            receipt=local('eth_getTransactionReceipt',[txhash])
            if receipt is not None: break
            time.sleep(0.25)
        assert receipt is not None, 'Local receipt timeout; no next step'
        assert int(receipt['status'],16)==1, 'Local transaction reverted; no next step'
        sent=local('eth_getTransactionByHash',[txhash])
        assert sent['from'].lower()==OWNER.lower() and sent['to'].lower()==NEW.lower()
        assert sent['input']==step['calldata'] and int(sent['nonce'],16)==798+i
        event_name='MigrationMarketFundingSeeded' if i<=2 else 'MigrationPositionSeeded'
        abi_event=next(a for a in event_abis if a['name']==event_name)
        matching=[l for l in receipt['logs'] if l['address'].lower()==NEW.lower() and l['topics'][0]==topic(abi_event)]
        assert len(matching)==1 and len(receipt['logs'])==1
        event=matching[0]; indexed=[]; data=[]
        for param in abi_event['inputs']:
            value=values[param['name']]
            word=(int(value,16) if isinstance(value,str) else value%(1<<256)).to_bytes(32,'big').hex()
            (indexed if param['indexed'] else data).append(word)
        assert event['topics'][1:]==['0x'+v for v in indexed] and event['data']=='0x'+''.join(data)
        if i<=2:
            flag(local,'_marketFundingSeeded',(values['marketId'],),1)
            state=[0,0,values['cumulativeFundingRate1e18'],values['lastFundingTimestamp']]
            expect(local,NEW,'marketState(uint256)',state,[values['marketId']])
        else:
            trader=values['trader']; mid=values['marketId']; size=values['size1e8']
            state=[values[k] for k in ['size1e8','openNotional1e8','lastCumulativeFundingRate1e18']]
            expect(local,NEW,'positions(address,uint256)',state,[trader,mid]); flag(local,'_positionSeeded',(trader,mid),1)
            expect(local,NEW,'getTraderMarketsLength(address)',1,[trader])
            expect(local,NEW,'getTraderMarketsSlice(address,uint256,uint256)',[32,1,mid],[trader,0,1])
            # Internal indexPlus1 and public aggregate exposure must agree.
            flag(local,'traderMarketIndexPlus1',(trader,mid),1)
            expect(local,NEW,'totalAbsLongSize1e8(address)',max(size,0),[trader])
            expect(local,NEW,'totalAbsShortSize1e8(address)',max(-size,0),[trader])
            oi[0]+=max(size,0); oi[1]+=max(-size,0)
            expect(local,NEW,'marketState(uint256)',oi+[0,1789715546],[1])
        trace=local('debug_traceTransaction',[txhash,{'tracer':'callTracer'}])
        def validate_calls(node,root=False):
            if root: assert node['to'].lower()==NEW.lower()
            else: assert node['type']=='STATICCALL' and node['to'].lower()==PMR.lower(), 'Unexpected external write/call'
            for child in node.get('calls',[]): validate_calls(child)
        validate_calls(trace,True)
        row=dict(records[i-1]); row.update(gasEstimate=estimate,gasLimitWithMargin=limit,localGasUsed=int(receipt['gasUsed'],16),
            localReceiptStatus=1,expectedEvent=event_name,eventVerified=True,postStateVerified=True,market1OI=list(oi),
            externalCalls='Only STATICCALL to approved PMR',l1FeeAllowanceWei=2*l1_bound)
        simulation['transactions'].append(row)
        print('LOCAL FORK STEP',i,'PASS; gas estimate',estimate,'OI',oi,flush=True)
    for market in manifest['markets']:
        expect(local,NEW,'marketState(uint256)',[market[k] for k in ['longOI1e8','shortOI1e8','cumulativeFundingRate1e18','lastFundingTimestamp']],[market['marketId']])
    for p in manifest['positions']:
        expect(local,NEW,'getResidualBadDebt(address)',0,[p['trader']]); flag(local,'_residualBadDebtSeeded',(p['trader'],),0)
    for sig in ['migrationState()','migrationSnapshotHash()','totalResidualBadDebtBase()']: expect(local,NEW,sig,0)
    for contract in [PME,RISK]: expect(local,contract,'perpEngine()',OLD)
    expect(local,VAULT,'isAuthorizedEngine(address)',0,[NEW])
    expect(local,deps['feesManagerV2()'],'isFeeConsumer(address)',0,[NEW])
    expect(local,deps['insuranceFund()'],'isBackstopCaller(address)',0,[NEW])
    expect(local,VAULT,'balances(address,address)',1000000000,[deps['clearingAccount()'],TOKEN])
    for trader,value in report['pmeV2Nonces'].items(): expect(local,PME,'nonces(address)',value,[trader])
    assert int(local('eth_getTransactionCount',[OWNER,'latest']),16)==807
    expect(local,SAFE,'nonce()',report['safeNonce'])
    assert int(local('eth_getTransactionCount',[EXECUTOR,'latest']),16)==report['executorNonce']
    local('anvil_stopImpersonatingAccount',[OWNER])
    simulation.update(passed=True,finalOwnerNonce=807,finalMigrationState='OPEN',finalSnapshotHash='0x'+'00'*32,
        finalMarket1=[1001002,1001002,0,1789715546],finalMarket2=[0,0,0,0],sharedDependenciesUnchanged=True,
        sumPositionSize=sum(p['size1e8'] for p in manifest['positions']),totalResidualBadDebtBase=0)
finally:
    process.terminate()
    try: process.wait(timeout=10)
    except subprocess.TimeoutExpired: process.kill(); process.wait()
simulation['localForkStopped']=True
report['fees']['totalGasEstimate']=sum(r['gasEstimate'] for r in simulation['transactions'])
report['fees']['totalGasLimitWithMargin']=sum(r['gasLimitWithMargin'] for r in simulation['transactions'])
report['fees']['totalL1FeeAllowanceWei']=16*l1_bound
report['fees']['totalBudgetWei']=report['fees']['totalGasLimitWithMargin']*max_fee+16*l1_bound
assert report['ownerBalanceWei']>report['fees']['totalBudgetWei'],'Insufficient ETH; no top-up authorized'
latest=live('eth_getBlockByNumber',['latest',False])
assert int(live('eth_getTransactionCount',[OWNER,'latest']),16)==int(live('eth_getTransactionCount',[OWNER,'pending']),16)==799
assert not live('eth_getLogs',[{'address':[NEW,OLD,V1,PME,PME1],'fromBlock':tag,'toBlock':latest['number'],'topics':[topics]}])
report['finalFreshness']={'block':int(latest['number'],16),'blockHash':latest['hash'],'confirmedNonce':799,'pendingNonce':799,'unexpectedEvents':0}
report.update(backend_stopped())
verify_canonical()
(DESTINATION/'preflight.json').write_text(json.dumps(report,indent=2)+'\n')
(DESTINATION/'simulation.json').write_text(json.dumps(simulation,indent=2)+'\n')
print('STAGE A PASS; public nonce remains 799; local fork stopped; NO PUBLIC WRITES',flush=True)
print(json.dumps({'block':report['block'],'freshness':report['finalFreshness'],'fees':report['fees'],'ownerBalanceETH':str(Decimal(report['ownerBalanceWei'])/Decimal(10**18))},indent=2))
