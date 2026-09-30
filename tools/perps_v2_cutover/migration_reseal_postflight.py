#!/usr/bin/env python3
"""M4 independent postflight. RPC reads/eth_call only; no signing or send path."""
import concurrent.futures
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

sys.dont_write_bytecode = True
from migration_reseal_execute import OUT, ROOT, APPROVED, OWNER, NEW, SNAPSHOT, PASSWORD, load_context, validate_receipt, save


def migration_closed_probe(ctx, data, tag):
    # Keep exact revert bytes; the older generic read helper intentionally
    # suppresses RPC error data and cannot prove which custom error occurred.
    payload={'jsonrpc':'2.0','id':1,'method':'eth_call',
             'params':[{'from':OWNER,'to':NEW,'value':'0x0','data':data,'gas':hex(500000)},tag]}
    try:
        request=urllib.request.Request(ctx['url'],data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=45) as response: result=json.load(response)
    except Exception:
        raise RuntimeError('Read-only negative probe transport failed; endpoint withheld') from None
    assert 'error' in result and 'result' not in result, 'Seed/seal unexpectedly accepted after seal'
    error=result['error']; reverted=error.get('data')
    if isinstance(reverted,dict): reverted=reverted.get('data')
    assert isinstance(reverted,str) and reverted.lower()=='0x836df086', 'Wrong migration-closed revert'
    return {'from':OWNER,'to':NEW,'value':0,'calldata':data,'rpcMethod':'eth_call',
            'error':'MigrationAlreadySealed()','errorData':reverted.lower(),'rpcErrorCode':error.get('code'),
            'broadcast':False,'passed':True}


def main():
    assert not sys.flags.optimize
    preflight,ctx,preview=load_context()
    rpc,expect=ctx['live'],ctx['expect']
    baseline=json.loads((OUT/'prebroadcast.json').read_text())
    stage_a=json.loads((OUT/'preflight.json').read_text())
    journal=json.loads((OUT/'execution_journal.json').read_text())
    previous=json.loads((ctx['DESTINATION']/'postflight.json').read_text())
    assert journal['publicSendInvocations']==1 and 'transactionHash' in journal
    assert journal['status'] in {'CANONICAL_SEAL_VERIFIED_POSTFLIGHT_PENDING','COMPLETE'}
    assert journal['passwordFileAbsent'] and not PASSWORD.exists()
    assert int(rpc('eth_chainId',[]),16)==84532
    block=rpc('eth_getBlockByNumber',['latest',False]); tag=block['number']
    assert int(block['hash'],16)!=0
    receipt=rpc('eth_getTransactionReceipt',[journal['transactionHash']])
    tx=rpc('eth_getTransactionByHash',[journal['transactionHash']])
    canonical=rpc('eth_getBlockByNumber',[receipt['blockNumber'],False])
    validate_receipt(receipt,tx,canonical,journal['transactionHash'],preview,stage_a['expectedEvent'])
    assert receipt['blockHash']==journal['receiptBlockHash']
    report={'milestone':'PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1','stage':'B_POSTFLIGHT','chainId':84532,
            'block':int(tag,16),'blockHash':block['hash'],'previewSha256':APPROVED,
            'transactionHash':journal['transactionHash'],'receiptBlock':int(receipt['blockNumber'],16),
            'receiptBlockHash':receipt['blockHash'],'receiptStatus':1,'transaction':preview,
            'exactTransactionAndEventVerified':True,'event':receipt['logs'][0]}
    report['heads']={}
    for name in ['safe','finalized']:
        try:
            head=rpc('eth_getBlockByNumber',[name,False])
            report['heads'][name]={'block':int(head['number'],16),'hash':head['hash'],
                                 'coversSeal':int(head['number'],16)>=report['receiptBlock']}
        except (RuntimeError,TypeError): report['heads'][name]={'supported':False}
    ctx['checks']=[(label,address,sig,1 if sig=='migrationState()' else SNAPSHOT,args)
                   if address.lower()==NEW.lower() and sig in ['migrationState()','migrationSnapshotHash()']
                   else (label,address,sig,want,args) for label,address,sig,want,args in ctx['checks']]
    reconciled=preflight.reconcile_state(ctx,tag,previous)
    # Prebroadcast is JSON: zero-argument tuples were serialized as arrays.
    # Normalize argument metadata only; actual getter values remain untouched.
    reconciled['checks']=[{**entry,'args':list(entry['args'])} for entry in reconciled['checks']]
    for old,new in zip(baseline['checks'],reconciled['checks']):
        if new['address'].lower()==NEW.lower() and new['function'] in ['migrationState()','migrationSnapshotHash()']:
            assert new['value']==(1 if new['function']=='migrationState()' else SNAPSHOT)
        else: assert new==old, 'Unexpected state change beyond seal metadata'
    assert len(baseline['checks'])==len(reconciled['checks'])==114
    for key in ['seedFlags','positionIndexes','pmeV2Nonces']:
        assert baseline[key]==reconciled[key], 'Migration bookkeeping/nonce changed: '+key
    report.update(reconciled)
    report.update(migrationState='SEALED',migrationSnapshotHash=SNAPSHOT,
                  markets=ctx['manifest']['markets'],positions=ctx['manifest']['positions'],
                  positionTotals=previous['positionTotals'],totalResidualBadDebtBase=0,
                  onlyExpectedMetadataChanged=True)
    print('Full post-seal economics, bookkeeping and isolation checks PASS',flush=True)
    residual_data=ctx['calldata']('adminSeedResidualBadDebt(address,uint256)',(ctx['manifest']['positions'][0]['trader'],0))
    probes=[('adminSeedMarketFunding',ctx['package']['orderedSteps'][0]['calldata']),
            ('adminSeedPosition',ctx['package']['orderedSteps'][2]['calldata']),
            ('adminSeedResidualBadDebt',residual_data),('sealMigration',preview['calldata'])]
    expected_error='0x'+ctx['keccak256'](b'MigrationAlreadySealed()')[:4].hex()
    assert expected_error=='0x836df086'
    report['negativeProbes']=[{'function':name,**migration_closed_probe(ctx,data,tag)} for name,data in probes]
    print('OWNER-context negative probes: 4/4 exact MigrationAlreadySealed() reverts',flush=True)
    report['ownerNoncePre']=807
    report['ownerNoncePost']=int(rpc('eth_getTransactionCount',[OWNER,tag]),16)
    report['ownerPendingNoncePost']=int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)
    assert report['ownerNoncePost']==report['ownerPendingNoncePost']==808
    report['safeNoncePre']=baseline['safeNonce']
    report['safeNoncePost']=expect(rpc,ctx['SAFE'],'nonce()',baseline['safeNonce'],tag=tag)
    report['executorNoncePre']=baseline['executorNonce']
    report['executorNoncePost']=int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],tag]),16)
    assert report['executorNoncePost']==baseline['executorNonce']==int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],'pending']),16)
    report['ownerBalancePreWei']=journal['ownerBalancePreWei']
    report['ownerBalancePostWei']=int(rpc('eth_getBalance',[OWNER,tag]),16)
    report['gasUsed']=int(receipt['gasUsed'],16)
    report['effectiveGasPriceWei']=int(receipt['effectiveGasPrice'],16)
    report['executionFeesWei']=report['gasUsed']*report['effectiveGasPriceWei']
    report['l1FeesWei']=int(receipt.get('l1Fee','0x0'),16)
    report['ownerExpenditureWei']=report['ownerBalancePreWei']-report['ownerBalancePostWei']
    assert report['ownerExpenditureWei']==report['executionFeesWei']+report['l1FeesWei'], 'Unexplained OWNER expenditure'
    for key in ['ownerBalancePre','ownerBalancePost','ownerExpenditure']:
        report[key+'ETH']=format(Decimal(report[key+'Wei'])/Decimal(10**18),'f')
    initial=journal['receiptObservations'][0]
    report['receiptObservationReconciliation']={'initialBlockHash':initial['blockHash'],
        'settledBlockHash':receipt['blockHash'],'initialL1FeeWei':int(initial.get('l1Fee') or '0x0',16),
        'settledL1FeeWei':report['l1FeesWei'],'originalObservationsPreserved':True}
    emitters=baseline['eventScan']['emitters']
    logs=[]
    for start in range(baseline['block']+1,int(tag,16)+1,2000):
        logs.extend(rpc('eth_getLogs',[{'address':emitters,'fromBlock':hex(start),'toBlock':hex(min(start+1999,int(tag,16)))}]))
    assert len(logs)==1 and logs[0]['transactionHash']==journal['transactionHash']
    assert logs[0]['address'].lower()==NEW.lower() and logs[0]['topics']==stage_a['expectedEvent']['topics']
    assert logs[0]['data'].lower()==SNAPSHOT
    report['eventAudit']={'fromBlock':baseline['block']+1,'toBlock':int(tag,16),'emitters':emitters,
                          'sealEvents':1,'seedEvents':0,'tradeEvents':0,'configurationEvents':0}
    def owner_transactions(height):
        b=rpc('eth_getBlockByNumber',[hex(height),True])
        return [t['hash'] for t in b['transactions'] if t['from'].lower()==OWNER.lower()]
    hashes=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for found in pool.map(owner_transactions,range(journal['preblock'],int(tag,16)+1)): hashes.extend(found)
    assert hashes==[journal['transactionHash']], 'Unexpected OWNER transaction'
    report['writeAudit']={'fromBlock':journal['preblock'],'toBlock':int(tag,16),'ownerTransactionHashes':hashes,
                         'publicSendInvocations':1,'ownerNonceDelta':1,'safeNonceDelta':0,'executorNonceDelta':0,
                         'seals':1,'seeds':0,'deployments':0,'tokenMovements':0,'sharedDependencyWrites':0,
                         'vaultAuthorizationWrites':0,'safeTimelockWrites':0,'backendDbWrites':0,'trades':0}
    code=bytes.fromhex(rpc('eth_getCode',[NEW,tag])[2:])
    assert code==ctx['linked'](ctx['artifact'],'deployedBytecode') and len(code)==24321
    assert '0x'+ctx['keccak256'](code).hex()==ctx['ENGINE_HASH']
    report['runtime']={'bytes':len(code),'ethereumKeccak256':ctx['ENGINE_HASH'],'byteEqualFrozenArtifact':True}
    report.update(ctx['backend_stopped']())
    for path,digest in stage_a['preservedArtifactSha256'].items():
        assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest
    report['preservedArtifactSha256']=stage_a['preservedArtifactSha256']
    assert hashlib.sha256((OUT/'transaction_preview.json').read_bytes()).hexdigest()==APPROVED
    assert rpc('eth_getBlockByNumber',[tag,False])['hash']==block['hash']
    assert rpc('eth_getBlockByNumber',[receipt['blockNumber'],False])['hash']==receipt['blockHash']
    assert not PASSWORD.exists()
    report['passwordFileAbsent']=True
    report['status']='PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1_COMPLETE'
    save('settled_receipt.json',receipt)
    save('postflight.json',report)
    journal.update(status='COMPLETE',postflightBlock=report['block'],postflightPassed=True)
    save('execution_journal.json',journal)
    print(json.dumps({k:report[k] for k in ['status','transactionHash','receiptBlock','block','blockHash',
         'ownerNoncePost','migrationState','migrationSnapshotHash','gasUsed','executionFeesWei','l1FeesWei',
         'ownerBalancePreETH','ownerBalancePostETH','ownerExpenditureETH','passwordFileAbsent']},indent=2))


if __name__=='__main__':
    main()
