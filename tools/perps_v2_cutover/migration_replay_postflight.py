#!/usr/bin/env python3
"""Independent read-only M3 postflight; cannot sign, send, seed or seal."""
import concurrent.futures
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/perps_v2_cutover'))
from migration_replay_execute import check_receipt, save, APPROVED, PREFLIGHT_HELPER
helper=ROOT/'tools/perps_v2_cutover/migration_replay_preflight.py'
source=helper.read_text()
assert hashlib.sha256(helper.read_bytes()).hexdigest()==PREFLIGHT_HELPER
ctx={'__file__':str(helper)}
exec(compile(source.split("assert int(live('eth_chainId',[]),16)==84532")[0],str(helper),'exec'),ctx)
live,expect,call,flag=(ctx[k] for k in ['live','expect','call','flag'])
NEW,OLD,V1,OWNER,PME,PME1,RISK,VAULT,TOKEN,SAFE,EXECUTOR=(ctx[k] for k in ['NEW','OLD','V1','OWNER','PME','PME1','RISK','VAULT','TOKEN','SAFE','EXECUTOR'])
out=ctx['DESTINATION']; manifest=ctx['manifest']; package=ctx['package']
assert hashlib.sha256((out/'execution_package.json').read_bytes()).hexdigest()==APPROVED
journal=json.loads((out/'execution_journal.json').read_text())
pre=json.loads((out/'prebroadcast.json').read_text())
reconciliation=json.loads((out/'receipt_block_reconciliation.json').read_text())
assert journal['successfulPrefix']==8 and journal['publicSendInvocations']==8
assert journal['status'] in {'EIGHT_SEEDS_VERIFIED_FINAL_RECONCILIATION_PENDING', 'COMPLETE'}
assert journal['passwordFileAbsent'] and not Path('/run/user/1000/deopt-deployer.pw').exists()
assert int(live('eth_chainId',[]),16)==84532
block=live('eth_getBlockByNumber',['latest',False]); tag=block['number']; ctx['tag']=tag
safe_block=live('eth_getBlockByNumber',['safe',False])
assert int(safe_block['number'],16)>=journal['transactions'][-1]['block'], 'Await safe inclusion; no sends'
report={'stage':'B_POSTFLIGHT','chainId':84532,'block':int(tag,16),'blockHash':block['hash'],
        'packageSha256':APPROVED,'canonicalSnapshotHash':ctx['SNAPSHOT'],'transactions':[],
        'receiptReconciliation':{'initialZeroBlockHashOrdinals':[],'initialL1FeeChangedOrdinals':[],
            'verification':'fresh receipt + transaction + canonical block inclusion; repeated against earlier reconciliation',
            'safeHeadBlock':int(safe_block['number'],16),'safeHeadHash':safe_block['hash'],
            'additionalPublicRpcChecks':'Unavailable: both public endpoints returned HTTP 403',
            'originalJournalPreserved':True}}

for i,(row,step) in enumerate(zip(journal['transactions'],package['orderedSteps']),1):
    assert row['state']=='VERIFIED' and row['ordinal']==i
    receipt=live('eth_getTransactionReceipt',[row['hash']]); tx=live('eth_getTransactionByHash',[row['hash']])
    name='MigrationMarketFundingSeeded' if i<=2 else 'MigrationPositionSeeded'
    event=next(a for a in ctx['artifact']['abi'] if a['type']=='event' and a['name']==name)
    signature=name+'('+','.join(p['type'] for p in event['inputs'])+')'
    topics=['0x'+ctx['keccak256'](signature.encode()).hex()]; data=[]
    for param in event['inputs']:
        value=step['args'][param['name']]
        word=(int(value,16) if isinstance(value,str) else value%(1<<256)).to_bytes(32,'big').hex()
        if param['indexed']: topics.append('0x'+word)
        else: data.append(word)
    expected_event={'topics':topics,'data':'0x'+''.join(data)}
    check_receipt(receipt,tx,step,i,expected_event)
    canonical_block=live('eth_getBlockByNumber',[receipt['blockNumber'],False])
    assert int(receipt['blockHash'],16)!=0
    assert canonical_block['hash']==receipt['blockHash']==tx['blockHash']
    assert row['hash'] in canonical_block['transactions']
    assert int(receipt['blockNumber'],16)==row['block']
    observed=reconciliation['observations'][i-1]
    assert observed['hash']==row['hash'] and observed['currentBlockHash']==receipt['blockHash'] and observed['included']
    if receipt['blockHash']!=row['blockHash']:
        # Explicitly reconcile only an observed all-zero placeholder, never a
        # changed nonzero block hash. Keep the original journal observation.
        assert int(row['blockHash'],16)==0, 'Nonzero historical block hash changed; STOP'
        assert observed['hash']==row['hash'] and observed['journalBlockHash']==row['blockHash']
        assert observed['currentBlockHash']==receipt['blockHash'] and observed['included']
        report['receiptReconciliation']['initialZeroBlockHashOrdinals'].append(i)
    if int(receipt.get('l1Fee','0x0'),16)!=row['l1FeeWei']:
        report['receiptReconciliation']['initialL1FeeChangedOrdinals'].append(i)
    assert int(tx['nonce'],16)==798+i
    report['transactions'].append({'ordinal':i,'hash':row['hash'],'block':row['block'],'blockHash':receipt['blockHash'],
        'nonce':798+i,'target':NEW,'signature':step['signature'],'args':step['args'],'status':1,
        'gasUsed':int(receipt['gasUsed'],16),'effectiveGasPriceWei':int(receipt['effectiveGasPrice'],16),
        'l1FeeWei':int(receipt.get('l1Fee','0x0'),16),'eventVerified':True,'stepStorageReadbackVerified':True})
print('Independent receipts and events verified: 8/8',flush=True)

# Same 114 gates as Stage A, with only the now-seeded NEW economic expectations changed.
exec(compile(source[source.index('checks=[]'):source.index('def runcheck(item):')],str(helper),'exec'),ctx)
positions={(p['trader'].lower(),p['marketId']):p for p in manifest['positions']}
markets={m['marketId']:m for m in manifest['markets']}
checks=[]
for label,address,sig,want,args in ctx['checks']:
    if address.lower()==NEW.lower():
        if sig=='marketState(uint256)':
            m=markets[args[0]]; want=[m[k] for k in ['longOI1e8','shortOI1e8','cumulativeFundingRate1e18','lastFundingTimestamp']]
        elif sig=='positions(address,uint256)':
            p=positions.get((args[0].lower(),args[1]))
            want=[p[k] for k in ['size1e8','openNotional1e8','lastCumulativeFundingRate1e18']] if p else [0,0,0]
        elif sig=='getTraderMarketsLength(address)': want=1
        elif sig=='totalAbsLongSize1e8(address)': want=max(positions[(args[0].lower(),1)]['size1e8'],0)
        elif sig=='totalAbsShortSize1e8(address)': want=max(-positions[(args[0].lower(),1)]['size1e8'],0)
    checks.append((label,address,sig,want,args))
def runcheck(item):
    label,address,sig,want,args=item
    return {'label':label,'value':expect(live,address,sig,want,args,tag),'passed':True}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool: report['checks']=list(pool.map(runcheck,checks))
report['marketReconciliation']=[]
for mid,m in markets.items():
    values=[m[k] for k in ['longOI1e8','shortOI1e8','cumulativeFundingRate1e18','lastFundingTimestamp']]
    report['marketReconciliation'].append({'marketId':mid,'manifest':values,'v1':values,'oldEngine':values,'newEngine':values})
report['positionReconciliation']=[]; report['seedFlags']=[]
for mid in [1,2]: report['seedFlags'].append(flag(live,'_marketFundingSeeded',(mid,),1,tag))
for p in manifest['positions']:
    trader=p['trader']; mid=p['marketId']; values=[p[k] for k in ['size1e8','openNotional1e8','lastCumulativeFundingRate1e18']]
    report['seedFlags'].append(flag(live,'_positionSeeded',(trader,mid),1,tag))
    report['seedFlags'].append(flag(live,'_residualBadDebtSeeded',(trader,),0,tag))
    index=flag(live,'traderMarketIndexPlus1',(trader,mid),1,tag)
    expect(live,NEW,'getTraderMarketsSlice(address,uint256,uint256)',[32,1,mid],[trader,0,1],tag)
    report['positionReconciliation'].append({'trader':trader,'marketId':mid,'manifest':values,'v1':values,'oldEngine':values,
                                           'newEngine':values,'indexPlusOne':index['value'],'traderMarkets':[mid],'residualBadDebtBase':0})
report['positionTotals']={'netSize':sum(p['size1e8'] for p in manifest['positions']),
                         'longOI':sum(max(p['size1e8'],0) for p in manifest['positions']),
                         'shortOI':sum(max(-p['size1e8'],0) for p in manifest['positions'])}
assert report['positionTotals']=={'netSize':0,'longOI':1001002,'shortOI':1001002}
report['migrationState']='OPEN'; report['migrationSnapshotHash']='0x'+'00'*32
report['totalResidualBadDebtBase']=0
report['pmeV2Nonces']={}
for trader,value in pre['pmeV2Nonces'].items():
    report['pmeV2Nonces'][trader]=expect(live,PME,'nonces(address)',value,[trader],tag)
report['ownerNoncePre']=799; report['ownerNoncePost']=int(live('eth_getTransactionCount',[OWNER,tag]),16)
report['ownerPendingNoncePost']=int(live('eth_getTransactionCount',[OWNER,'pending']),16)
assert report['ownerNoncePost']==report['ownerPendingNoncePost']==807
report['safeNoncePre']=pre['safeNonce']; report['safeNoncePost']=expect(live,SAFE,'nonce()',pre['safeNonce'],tag=tag)
report['executorNoncePre']=pre['executorNonce']; report['executorNoncePost']=int(live('eth_getTransactionCount',[EXECUTOR,tag]),16)
assert report['executorNoncePost']==pre['executorNonce']==int(live('eth_getTransactionCount',[EXECUTOR,'pending']),16)
report['ownerBalancePreWei']=journal['ownerBalancePreWei']; report['ownerBalancePostWei']=int(live('eth_getBalance',[OWNER,tag]),16)
report['ownerBalancePreETH']=str(Decimal(report['ownerBalancePreWei'])/Decimal(10**18))
report['ownerBalancePostETH']=str(Decimal(report['ownerBalancePostWei'])/Decimal(10**18))
report['ownerExpenditureWei']=report['ownerBalancePreWei']-report['ownerBalancePostWei']
report['totalGasUsed']=sum(r['gasUsed'] for r in report['transactions'])
report['executionFeesWei']=sum(r['gasUsed']*r['effectiveGasPriceWei'] for r in report['transactions'])
report['l1FeesWei']=sum(r['l1FeeWei'] for r in report['transactions'])
assert report['ownerExpenditureWei']==report['executionFeesWei']+report['l1FeesWei'],'Unexplained OWNER balance change'
runtime=bytes.fromhex(live('eth_getCode',[NEW,tag])[2:])
assert runtime==ctx['linked'](ctx['artifact'],'deployedBytecode')
assert len(runtime)==24321 and '0x'+ctx['keccak256'](runtime).hex()==ctx['ENGINE_HASH']
report['runtime']={'bytes':len(runtime),'ethereumKeccak256':ctx['ENGINE_HASH'],'byteEqualFrozenArtifact':True}
assert live('eth_getBlockByNumber',[hex(manifest['snapshotBlockNumber']),False])['hash']==manifest['snapshotBlockHash']

expected_hashes={r['hash'].lower() for r in report['transactions']}
logs=live('eth_getLogs',[{'address':pre['eventScan']['emitters'],'fromBlock':hex(pre['prebroadcastBlock']),
                        'toBlock':tag,'topics':[pre['eventScan']['topics']]}])
assert len(logs)==8 and {l['transactionHash'].lower() for l in logs}==expected_hashes
assert all(l['address'].lower()==NEW.lower() for l in logs)
report['eventAudit']={'fromBlock':pre['prebroadcastBlock'],'toBlock':int(tag,16),'fundingSeedEvents':2,'positionSeedEvents':6,
                      'residualDebtSeedEvents':0,'sealEvents':0,'tradeEvents':0,'oldOrV1MigrationTradeEvents':0}
owner_hashes=[]
def scan_block(height):
    data=live('eth_getBlockByNumber',[hex(height),True])
    return [t['hash'].lower() for t in data['transactions'] if t['from'].lower()==OWNER.lower()]
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    for batch in pool.map(scan_block,range(journal['preblock'],int(tag,16)+1)): owner_hashes.extend(batch)
assert len(owner_hashes)==8 and set(owner_hashes)==expected_hashes
report['writeAudit']={'fromBlock':journal['preblock'],'toBlock':int(tag,16),'ownerTransactionCount':8,
    'ownerTransactionHashes':owner_hashes,'ownerNonceDelta':8,'safeNonceDelta':0,'executorNonceDelta':0,
    'tokenEventsInAuthorizedReceipts':0,'deployments':0,'sharedDependencyWrites':0,'vaultAclWrites':0,
    'safeTimelockWrites':0,'sealWrites':0,'backendDbWrites':0,'trades':0}
report.update(ctx['backend_stopped']())
_,hashes=ctx['verify_canonical'](); report['canonicalFileSha256']=hashes
assert hashes==pre['canonicalFileSha256']
report['passwordFileAbsent']=not Path('/run/user/1000/deopt-deployer.pw').exists()
assert report['passwordFileAbsent']
assert hashlib.sha256((out/'execution_package.json').read_bytes()).hexdigest()==APPROVED
report['status']='PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1_COMPLETE'
(out/'postflight.json').write_text(json.dumps(report,indent=2)+'\n')
journal.update(status='COMPLETE', finalReconciliationFile='postflight.json', finalReconciliationPassed=True,
               finalReconciliationBlock=report['block'])
save(journal)
print(json.dumps({k:report[k] for k in ['status','block','blockHash','ownerNoncePost','ownerBalancePreETH','ownerBalancePostETH',
       'totalGasUsed','executionFeesWei','l1FeesWei','ownerExpenditureWei','positionTotals','migrationState','migrationSnapshotHash','passwordFileAbsent']},indent=2))
