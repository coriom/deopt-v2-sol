#!/usr/bin/env python3
"""Execute only the operator-approved four-call maintenance package.

One public submission at a time. A failed or ambiguous step halts permanently;
there is no retry, replacement, resume or repair path in this tool.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True
import maintenance_lock_preflight as audit
import migration_reseal_preflight as reseal

ROOT = audit.ROOT
OUT = audit.OUT
APPROVED = '41ea29ebdbcde48dd43733d6f288bd819ad8274738bd008501d03c9d528b6697'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
PW = Path('/run/user')/str(os.getuid())/'deopt-deployer.pw'
KEYSTORE = Path.home()/'.foundry/keystores/deopt-deployer'
EVENT_ADDRESSES = ['PME','NEW','OLD','V1']


def save(name, value):
    tmp = OUT/(name+'.tmp')
    with tmp.open('w') as f:
        json.dump(value,f,indent=2)
        f.write('\n');f.flush();os.fsync(f.fileno())
    tmp.replace(OUT/name)


def compare_state(ctx, preflight, prior, rpc, tag):
    old=ctx['live'];ctx['live']=rpc
    try:
        actual=reseal.reconcile_state(ctx,tag,prior)
    finally:ctx['live']=old
    actual['checks']=[{**row,'args':list(row['args'])} for row in actual['checks']]
    for key in ['checks','seedFlags','positionIndexes','pmeV2Nonces']:
        assert actual[key]==preflight[key], 'Canonical economics/dependencies drift: '+key
    assert len(actual['checks'])==114
    return actual


def control_state(ctx,rpc,tag):
    return {name:([ctx['call'](rpc,ctx[name],'paused()',tag=tag)[0]] if name=='PME'
                  else [ctx['call'](rpc,ctx[name],s,tag=tag)[0] for s in audit.FLAGS])
            for name in EVENT_ADDRESSES}


def invariant(ctx,preflight,prior,rpc,tag,expected_controls,whole=True):
    assert control_state(ctx,rpc,tag)==expected_controls,'Pause-control drift'
    if whole:compare_state(ctx,preflight,prior,rpc,tag)
    assert rpc('eth_call',[{'to':ctx['PME'],'data':ctx['calldata']('domainSeparatorV4()')},tag])==preflight['pmeDomainSeparator']
    for address,value in preflight['executorPermissions'].items():
        ctx['expect'](rpc,ctx['PME'],'isExecutor(address)',value,[address],tag)
    for getter,value in preflight['oldPermissions'].items():
        sig='isFeeConsumer(address)' if getter=='feesManagerV2()' else 'isBackstopCaller(address)'
        ctx['expect'](rpc,ctx['deps'][getter],sig,value,[ctx['OLD']],tag)
    for name in EVENT_ADDRESSES:
        contract=ctx[name];authority=preflight['authorities'][name]
        ctx['expect'](rpc,contract,'owner()',authority['owner'],tag=tag)
        ctx['expect'](rpc,contract,'guardian()',authority['guardian'],tag=tag)
        runtime=bytes.fromhex(rpc('eth_getCode',[contract,tag])[2:])
        assert len(runtime)==authority['runtimeBytes'] and '0x'+ctx['keccak256'](runtime).hex()==authority['runtimeKeccak256']
    ctx['expect'](rpc,ctx['deps']['insuranceFund()'],'owner()',audit.TIMELOCK,tag=tag)
    assert ctx['backend_stopped']()['backend_runtime_state']=='STOPPED'
    assert ctx['call'](rpc,ctx['SAFE'],'nonce()',tag=tag)[0]==preflight['safeNonce']
    assert int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],tag]),16)==preflight['executorNonce']


def scan_unexpected(ctx,rpc,start,end,expected_hashes):
    addresses=json.loads((OUT/'preflight.json').read_text())['eventScan']['emitters']
    actual=[]
    for first in range(start,end+1,2000):
        logs=rpc('eth_getLogs',[{'address':addresses,'fromBlock':hex(first),'toBlock':hex(min(first+1999,end))}])
        actual.extend(logs)
    assert {x['transactionHash'] for x in actual}<=set(expected_hashes),'Unexpected scoped configuration/trade/migration event'
    return actual


def validate_receipt(ctx,receipt,tx,block,hash_,step):
    assert receipt and tx and block
    assert int(receipt['status'],16)==1,'Maintenance transaction reverted'
    assert tx['hash']==receipt['transactionHash']==hash_
    assert tx['blockHash']==receipt['blockHash']==block['hash'] and int(block['hash'],16)!=0
    assert tx['blockNumber']==receipt['blockNumber']==block['number'] and hash_ in block['transactions']
    assert tx['from'].lower()==receipt['from'].lower()==OWNER.lower()
    assert tx['to'].lower()==receipt['to'].lower()==step['target'].lower()
    assert int(tx['chainId'],16)==84532 and int(tx['nonce'],16)==step['nonce']
    assert int(tx['value'],16)==0 and tx['input'].lower()==step['calldata'].lower()
    assert int(tx['gas'],16)==step['gasLimit']
    assert int(tx['maxFeePerGas'],16)==step['maxFeePerGasWei']
    assert int(tx['maxPriorityFeePerGas'],16)==step['maxPriorityFeePerGasWei']
    assert not receipt.get('contractAddress')
    assert len(receipt['logs'])==len(step['expectedEvents']),'Unexpected event count'
    for log,want in zip(receipt['logs'],step['expectedEvents']):
        assert log['address'].lower()==step['target'].lower() and not log.get('removed',False)
        assert [v.lower() for v in log['topics']]==[v.lower() for v in want['topics']]
        assert log['data'].lower()==want['data'].lower()


def maintenance_probes(ctx):
    results=[]
    trader,other=[p['trader'] for p in ctx['manifest']['positions'][:2]]
    for name in ['NEW','OLD','V1']:
        target=ctx[name]
        checks=[('funding1','updateFunding(uint256)',[1],OWNER,'FundingPaused()'),
                ('funding2','updateFunding(uint256)',[2],OWNER,'FundingPaused()'),
                ('applyTrade','applyTrade((address,address,uint256,uint128,uint128,bool))',
                 [f'({trader},{other},1,1,300000000000,true)'],
                 '0x'+ctx['call'](ctx['live'],target,'matchingEngine()')[0].to_bytes(20,'big').hex(),'TradingPaused()'),
                ('liquidate','liquidate(address,uint256,uint128)',[trader,1,1],OWNER,'LiquidationPaused()')]
        if name!='V1':
            keeper='0x'+ctx['call'](ctx['live'],target,'impactMidSource()')[0].to_bytes(20,'big').hex()
            checks.append(('impactMid','updateImpactMid(uint256,uint128)',[1,300000000000],keeper,'FundingPaused()'))
        for label,sig,args,who,error in checks:
            data=ctx['calldata'](sig,tuple(args))
            response=audit.raw(ctx['url'],'eth_call',[{'from':who,'to':target,'data':data,'gasPrice':'0x0','gas':hex(500000)},'latest'])
            expected='0x'+ctx['keccak256'](error.encode())[:4].hex()
            got=audit.error_data(response)
            assert got==expected, 'Exact post-lock pause error not proved: '+name+'.'+label
            results.append({'name':name+'.'+label,'target':target,'caller':who,'selector':data[:10],
                            'error':error,'errorData':got,'method':'eth_call','publicWrite':False})
    trade='(0x'+'00'*32+f',{trader},{other},1,1,300000000000,400000000000,200000000000,true,0,0,0)'
    sig='executeTrade((bytes32,address,address,uint256,uint128,uint128,uint128,uint128,bool,uint256,uint256,uint256),bytes,bytes)'
    data=ctx['calldata'](sig,(trade,'0x','0x'))
    response=audit.raw(ctx['url'],'eth_call',[{'from':OWNER,'to':ctx['PME'],'data':data,'gasPrice':'0x0','gas':hex(500000)},'latest'])
    expected='0x'+ctx['keccak256'](b'PausedError()')[:4].hex()
    assert audit.error_data(response)==expected,'PME pause error not proved'
    results.append({'name':'PME.executeTrade','target':ctx['PME'],'caller':OWNER,'selector':data[:10],
                    'error':'PausedError()','errorData':expected,'method':'eth_call','publicWrite':False})
    assert len(results)==15
    return results


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--execute-reviewed-package',required=True)
    args=parser.parse_args()
    assert not sys.flags.optimize and args.execute_reviewed_package==APPROVED
    journal={'milestone':'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1','approvedPackageSha256':APPROVED,
             'status':'PRECHECK','publicSendInvocations':0,'transactions':[]}
    rpc=None
    try:
        assert not (OUT/'execution_journal.json').exists() and not (OUT/'postflight.json').exists(),'Prior execution evidence exists; no automatic resume'
        path=OUT/'execution_package.json'
        assert hashlib.sha256(path.read_bytes()).hexdigest()==APPROVED
        package=json.loads(path.read_text())
        preflight=json.loads((OUT/'preflight.json').read_text())
        assert package['chainId']==84532 and package['sender']==OWNER and package['startingNonce']==808 and package['expectedFinalNonce']==812
        assert preflight['packageSha256']==APPROVED and preflight['simulationPassed']
        assert len(package['transactions'])==4 and not package['skipped']
        assert [x['name'] for x in package['transactions']]==EVENT_ADDRESSES
        assert [x['nonce'] for x in package['transactions']]==list(range(808,812))
        for n,step in enumerate(package['transactions']):
            assert step['sender']==OWNER and step['value']==0 and step['chainId']==84532
            assert step['target'].lower()==preflight['authorities'][EVENT_ADDRESSES[n]]['address'].lower()
            assert step['pauseFlagsBefore']==preflight['controls'][EVENT_ADDRESSES[n]]
            assert all(v is True for v in step['decodedArguments'])
            assert step['maxFeePerGasWei']==package['fees']['maxFeePerGasWei'] and step['maxPriorityFeePerGasWei']==package['fees']['maxPriorityFeePerGasWei']
            assert step['l1FeeAllowanceWei']==package['fees']['l1AllowancePerTxWei']
        for name,digest in json.loads((OUT/'entry_inventory.json').read_text())['preservedBlockedRebindFiles'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest
        assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()==preflight['solHead']
        assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT.parent/'deopt-v2-backend',text=True).strip()==preflight['backendHead']
        assert not subprocess.check_output(['git','status','--porcelain'],cwd=ROOT.parent/'deopt-v2-backend',text=True).strip()
        assert not subprocess.check_output(['git','diff','--name-only'],cwd=ROOT).strip()
        ctx=reseal.prepare_context();rpc=ctx['live']
        assert int(rpc('eth_chainId',[]),16)==84532
        assert ctx['verify_canonical']()[1]==preflight['canonicalFileSha256']
        ctx['checks']=[(label,address,sig,1 if sig=='migrationState()' else ctx['SNAPSHOT'],sigargs)
            if address.lower()==ctx['NEW'].lower() and sig in ['migrationState()','migrationSnapshotHash()']
            else (label,address,sig,want,sigargs) for label,address,sig,want,sigargs in ctx['checks']]
        previous=json.loads((reseal.OUT/'postflight.json').read_text())
        assert previous['status']=='PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1_COMPLETE'
        preblock=rpc('eth_getBlockByNumber',['latest',False]);tag=preblock['number']
        assert rpc('eth_getBlockByNumber',[hex(ctx['manifest']['snapshotBlockNumber']),False])['hash']==ctx['manifest']['snapshotBlockHash']
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)==int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)==808
        baseline=dict(preflight['controls'])
        invariant(ctx,preflight,previous,rpc,tag,baseline)
        assert not scan_unexpected(ctx,rpc,preflight['freshBlock']+1,int(tag,16),[])
        print('Pre-write economics, owners, controls and scoped activity PASS at block',int(tag,16),flush=True)
        metadata=PW.lstat();directory=PW.parent.stat()
        assert stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode)==0o600
        assert metadata.st_uid==directory.st_uid==os.getuid()==1000
        assert subprocess.check_output(['findmnt','-n','-T',str(PW),'-o','FSTYPE,TARGET'],text=True).split()==['tmpfs',str(PW.parent)]
        env=os.environ.copy()
        for key in ['ETH_PRIVATE_KEY','PRIVATE_KEY','DEPLOYER_PRIVATE_KEY','ETH_PASSWORD']:
            env.pop(key,None)
        env['ETH_RPC_URL']=ctx['url']
        signer=subprocess.run(['cast','wallet','address','--keystore',str(KEYSTORE),'--password-file',str(PW)],cwd='/tmp',env=env,capture_output=True,text=True,timeout=30)
        assert signer.returncode==0 and signer.stdout.strip().lower()==OWNER.lower(),'Signer verification failed; output withheld'
        print('Signer independently verified as OWNER',flush=True)
        fresh=rpc('eth_getBlockByNumber',['latest',False]);ft=fresh['number']
        assert int(ft,16)-int(tag,16)<=180,'Pre-write full checks stale'
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)==int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)==808
        invariant(ctx,preflight,previous,rpc,ft,baseline,whole=False)
        assert not scan_unexpected(ctx,rpc,int(tag,16)+1,int(ft,16),[])
        base=int(fresh['baseFeePerGas'],16);priority=int(rpc('eth_maxPriorityFeePerGas',[]),16)
        price=int(rpc('eth_gasPrice',[]),16)
        assert 2*base+priority<=package['fees']['maxFeePerGasWei'] and price<=package['fees']['maxFeePerGasWei']
        assert priority<=package['fees']['maxPriorityFeePerGasWei']
        l1=2*ctx['call'](rpc,'0x420000000000000000000000000000000000000F','getL1FeeUpperBound(uint256)',[512],ft)[0]
        assert l1<=package['fees']['l1AllowancePerTxWei'],'L1 allowance drift'
        balance=int(rpc('eth_getBalance',[OWNER,ft]),16)
        assert balance>package['fees']['totalBudgetWei'],'Insufficient owner balance; no top-up'
        journal.update(status='APPROVED_GATES_PASS',preBlock=int(ft,16),preBlockHash=fresh['hash'],
                       ownerNoncePre=808,ownerBalancePreWei=balance,verifiedSigner=OWNER,
                       feeEvidence={'baseFeePerGasWei':base,'priorityFeePerGasWei':priority,'gasPriceWei':price,
                                    'l1DoubleUpperBoundWei':l1,'approvedFeeCapWei':package['fees']['maxFeePerGasWei'],
                                    'approvedL1AllowanceWei':package['fees']['l1AllowancePerTxWei']})
        save('prebroadcast.json',{'block':int(ft,16),'blockHash':fresh['hash'],'chainId':84532,'packageSha256':APPROVED,
            'ownerNonce':808,'ownerPendingNonce':808,'ownerBalanceWei':balance,
            'canonicalEconomicChecks':114,'migrationHash':ctx['SNAPSHOT'],'controls':baseline,
            'safeNonce':preflight['safeNonce'],'executorNonce':preflight['executorNonce'],
            'backendRuntimeState':'STOPPED','feeEvidence':journal['feeEvidence'],'signerVerified':True})
        save('execution_journal.json',journal)
        print('Final prebroadcast gate PASS; sending approved nonce 808',flush=True)
        post_controls=dict(baseline)
        for step in package['transactions']:
            ordinal=step['ordinal'];name=step['name'];expected_nonce=step['nonce']
            assert hashlib.sha256(path.read_bytes()).hexdigest()==APPROVED,'Package changed'
            assert int(rpc('eth_chainId',[]),16)==84532
            latest=rpc('eth_getBlockByNumber',['latest',False]);lt=latest['number']
            assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)==int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)==expected_nonce,'Nonce drift; no send'
            invariant(ctx,preflight,previous,rpc,lt,post_controls)
            known_hashes=[x['hash'] for x in journal['transactions']]
            assert set(x['transactionHash'] for x in scan_unexpected(ctx,rpc,journal['preBlock']+1,int(lt,16),known_hashes))<=set(known_hashes)
            remaining=package['transactions'][ordinal-1:]
            remaining_budget=sum(x['gasLimit']*x['maxFeePerGasWei']+x['l1FeeAllowanceWei'] for x in remaining)
            assert int(rpc('eth_getBalance',[OWNER,lt]),16)>remaining_budget
            assert 2*int(latest['baseFeePerGas'],16)+int(rpc('eth_maxPriorityFeePerGas',[]),16)<=step['maxFeePerGasWei']
            assert 2*ctx['call'](rpc,'0x420000000000000000000000000000000000000F','getL1FeeUpperBound(uint256)',[512],lt)[0]<=step['l1FeeAllowanceWei']
            record={'ordinal':ordinal,'name':name,'target':step['target'],'nonce':expected_nonce,'calldata':step['calldata'],
                    'status':'SUBMITTING','submissionAttempts':1,'preBlock':int(lt,16),'receiptObservations':[]}
            journal['transactions'].append(record);journal['publicSendInvocations']+=1;save('execution_journal.json',journal)
            command=['cast','send',step['target'],step['calldata'],'--async','-j','1','--from',OWNER,'--value','0',
                     '--nonce',str(expected_nonce),'--chain','84532','--gas-limit',str(step['gasLimit']),
                     '--gas-price',str(step['maxFeePerGasWei']),'--priority-gas-price',str(step['maxPriorityFeePerGasWei']),
                     '--keystore',str(KEYSTORE),'--password-file',str(PW)]
            try:
                result=subprocess.run(command,cwd='/tmp',env=env,capture_output=True,text=True,timeout=90)
            except subprocess.TimeoutExpired:
                record['status']='SUBMISSION_TIMEOUT_UNKNOWN';record['ownerLatestNonce']=int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)
                record['ownerPendingNonce']=int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)
                save('execution_journal.json',journal)
                raise RuntimeError('Submission timeout; reconcile transaction/nonce externally; no retry') from None
            output=result.stdout.strip().strip('"')
            if re.fullmatch(r'0x[0-9a-fA-F]{64}',output):
                record['hash']=output;record['status']='SUBMITTED';save('execution_journal.json',journal)
            if result.returncode!=0 or 'hash' not in record:
                record['status']='SUBMISSION_AMBIGUOUS'
                record['ownerLatestNonce']=int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)
                record['ownerPendingNonce']=int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)
                save('execution_journal.json',journal)
                raise RuntimeError('Submission ambiguous; output withheld; no retry')
            print('Submitted ordinal',ordinal,'tx',record['hash'],'waiting for canonical receipt',flush=True)
            deadline=time.monotonic()+300;stable_hash=None
            while time.monotonic()<deadline:
                receipt=rpc('eth_getTransactionReceipt',[record['hash']])
                if receipt is None:time.sleep(2);continue
                observation={k:receipt.get(k) for k in ['transactionHash','blockNumber','blockHash','status','gasUsed','effectiveGasPrice','l1Fee']}
                if not record['receiptObservations'] or record['receiptObservations'][-1]!=observation:
                    record['receiptObservations'].append(observation);save('execution_journal.json',journal)
                assert int(receipt['status'],16)==1,'Receipt status 0; STOP'
                if int(receipt['blockHash'],16)==0:time.sleep(2);continue
                if stable_hash is not None:assert stable_hash==receipt['blockHash'],'Receipt block hash drift'
                stable_hash=receipt['blockHash']
                tx=rpc('eth_getTransactionByHash',[record['hash']]);block=rpc('eth_getBlockByNumber',[receipt['blockNumber'],False])
                validate_receipt(ctx,receipt,tx,block,record['hash'],step)
                current=rpc('eth_getBlockByNumber',['latest',False])
                if int(current['number'],16)<int(receipt['blockNumber'],16)+2:time.sleep(2);continue
                post_controls[name]=step['pauseFlagsAfter']
                invariant(ctx,preflight,previous,rpc,receipt['blockNumber'],post_controls)
                assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)==expected_nonce+1
                assert int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)==expected_nonce+1
                record.update(status='VERIFIED',receiptBlock=int(receipt['blockNumber'],16),receiptBlockHash=receipt['blockHash'],
                    gasUsed=int(receipt['gasUsed'],16),effectiveGasPriceWei=int(receipt['effectiveGasPrice'],16),
                    l1FeeWeiProvisional=int(receipt.get('l1Fee','0x0'),16),eventCount=len(receipt['logs']),
                    expectedPauseControls=dict(post_controls),economicChecks=114,eventVerified=True)
                save('execution_journal.json',journal)
                save('receipt_'+str(ordinal)+'.json',receipt)
                print('VERIFIED ordinal',ordinal,'receipt block',record['receiptBlock'],'status 1, events and 114 checks PASS',flush=True)
                break
            else:raise RuntimeError('Canonical receipt timeout; do not retry')
        journal['status']='FOUR_RECEIPTS_VERIFIED_POSTFLIGHT_PENDING';save('execution_journal.json',journal)
        final=rpc('eth_getBlockByNumber',['latest',False]);final_tag=final['number']
        expected={name:[1]*len(flags) for name,flags in baseline.items()}
        invariant(ctx,preflight,previous,rpc,final_tag,expected)
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16)==int(rpc('eth_getTransactionCount',[OWNER,'pending']),16)==812
        hashes=[row['hash'] for row in journal['transactions']]
        logs=scan_unexpected(ctx,rpc,journal['preBlock']+1,int(final_tag,16),hashes)
        assert len(logs)==sum(len(step['expectedEvents']) for step in package['transactions'])==15
        for log in logs:
            assert log['transactionHash'] in hashes
        probes=maintenance_probes(ctx)
        print('Post-lock exact maintenance-error probes PASS',len(probes),'of 15',flush=True)
        settled=[]
        deadline=time.monotonic()+240
        while time.monotonic()<deadline:
            settled=[]
            for row in journal['transactions']:
                rcpt=rpc('eth_getTransactionReceipt',[row['hash']])
                assert rcpt and rcpt['blockHash']==row['receiptBlockHash'] and int(rcpt['status'],16)==1
                settled.append(rcpt)
            post_balance=int(rpc('eth_getBalance',[OWNER,'latest']),16)
            cost=sum(int(x['gasUsed'],16)*int(x['effectiveGasPrice'],16)+int(x.get('l1Fee','0x0'),16) for x in settled)
            if journal['ownerBalancePreWei']-post_balance==cost:break
            time.sleep(3)
        else:raise RuntimeError('Settled fee/balance mismatch; preserve receipts and stop')
        assert hashlib.sha256(path.read_bytes()).hexdigest()==APPROVED
        for name,digest in json.loads((OUT/'entry_inventory.json').read_text())['preservedBlockedRebindFiles'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest
        report={'milestone':journal['milestone'],'status':'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_COMPLETE',
                'chainId':84532,'packageSha256':APPROVED,'comparisonBlock':int(final_tag,16),'comparisonBlockHash':final['hash'],
                'sender':OWNER,'approvedTransactions':package['transactions'],'executionJournal':journal['transactions'],
                'ownerNoncePre':808,'ownerNoncePost':812,'ownerBalancePreWei':journal['ownerBalancePreWei'],
                'ownerBalancePostWei':post_balance,'executionFeesWei':sum(int(x['gasUsed'],16)*int(x['effectiveGasPrice'],16) for x in settled),
                'l1FeesWei':sum(int(x.get('l1Fee','0x0'),16) for x in settled),'ownerExpenditureWei':cost,
                'controlsBefore':baseline,'controlsAfter':expected,'economicCheckCount':114,
                'seedFlagsPositionIndexesPmeNoncesUnchanged':True,'migrationHash':ctx['SNAPSHOT'],
                'market1':[1001002,1001002,0,1789715546],'market2':[0,0,0,0],
                'safeNoncePre':preflight['safeNonce'],'safeNoncePost':ctx['call'](rpc,ctx['SAFE'],'nonce()',tag=final_tag)[0],
                'executorNoncePre':preflight['executorNonce'],'executorNoncePost':int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],final_tag]),16),
                'newVaultAuthorization':False,'newFeeConsumer':False,'newInsuranceBackstop':False,
                'pmeRiskPointersRemainOld':True,'clearingBalanceNative':1000000000,'backendRuntimeState':'STOPPED',
                'exactNegativeProbes':probes,'scopedEvents':len(logs),'expectedScopedEvents':15,
                'insuranceOwner':audit.TIMELOCK,'signedOrderInventory':'UNRESOLVED',
                'safeTimelockWrites':0,'vaultWrites':0,'dependencyRebindWrites':0,'trades':0,'backendDbWrites':0,
                'publicSendInvocations':journal['publicSendInvocations']}
        assert report['safeNoncePre']==report['safeNoncePost'] and report['executorNoncePre']==report['executorNoncePost']
        assert journal['publicSendInvocations']==4
        save('settled_receipts.json',settled)
        save('postflight.json',report)
        journal.update(status='COMPLETE',postflightBlock=report['comparisonBlock'],postflightPassed=True)
        save('execution_journal.json',journal)
        print(json.dumps({key:report[key] for key in ['status','comparisonBlock','ownerNoncePre','ownerNoncePost',
            'ownerExpenditureWei','executionFeesWei','l1FeesWei','publicSendInvocations']},indent=2),flush=True)
    except BaseException as exc:
        journal['haltReason']=str(exc)[:250]
        if (OUT/'execution_journal.json').exists():
            journal['status']='HALTED' if journal['status']!='COMPLETE' else journal['status']
            save('execution_journal.json',journal)
        raise
    finally:
        PW.unlink(missing_ok=True)
        assert not PW.exists(),'Temporary password file remains'


if __name__=='__main__':main()
