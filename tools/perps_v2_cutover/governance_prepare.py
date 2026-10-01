#!/usr/bin/env python3
"""Read-only Base Sepolia governance preparation. Never signs or sends."""
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
import migration_reseal_preflight as migration
import maintenance_lock_preflight as maintenance

ROOT = migration.ROOT
OUT = ROOT / 'artifacts/perps_v2_recovery_governance_prepare'
TIMELOCK = maintenance.TIMELOCK
INSURANCE = '0x009f38440F058d095b61E0E2ee7fAbDF05BE7500'
VAULT = '0x00340C360353a5AB784c5Bc5c44322A6AF0625D3'
CHECKPOINT = '1b8aa78fceb6dae229b4a95e14e7938899ff6280'
BACKEND_CHECKPOINT = 'ad8dd7466aeba6963d28687e825fe4df58ef32ee'
ZERO = '0x' + '00' * 20


def address(raw):
    return '0x' + raw.to_bytes(20, 'big').hex()


def abi_words(data):
    raw = bytes.fromhex(data[2:])
    assert len(raw) % 32 == 0
    return [raw[i:i+32] for i in range(0, len(raw), 32)]


def decoded_address_array(data):
    words = abi_words(data)
    offset = int.from_bytes(words[0], 'big')
    assert offset == 32
    count = int.from_bytes(words[1], 'big')
    assert 0 < count < 20 and len(words) == count + 2
    return ['0x' + word[-20:].hex() for word in words[2:]]


def save(name, item):
    OUT.mkdir(exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(item, indent=2, sort_keys=True) + '\n')
    return path


def utc(seconds):
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat()


def main():
    assert not sys.flags.optimize
    assert subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip() == CHECKPOINT
    assert subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT.parent/'deopt-v2-backend', text=True).strip() == BACKEND_CHECKPOINT
    assert not subprocess.check_output(['git','status','--porcelain'], cwd=ROOT.parent/'deopt-v2-backend', text=True).strip()
    ctx = migration.prepare_context()
    rpc, call, cd = ctx['live'], ctx['call'], ctx['calldata']
    assert int(rpc('eth_chainId', []),16) == 84532
    b = rpc('eth_getBlockByNumber',['latest',False]); tag=b['number']
    assert int(b['hash'],16)
    prior = json.loads((migration.OUT/'postflight.json').read_text())
    ctx['checks'] = [(label,a,sig,1 if sig=='migrationState()' else ctx['SNAPSHOT'],args)
        if a.lower()==ctx['NEW'].lower() and sig in ('migrationState()','migrationSnapshotHash()')
        else (label,a,sig,want,args) for label,a,sig,want,args in ctx['checks']]
    state = migration.reconcile_state(ctx,tag,prior)
    state['checks'] = [{**row,'args':list(row['args'])} for row in state['checks']]
    for key in ('checks','seedFlags','positionIndexes','pmeV2Nonces'):
        assert state[key] == prior[key], 'Economic/dependency drift: '+key
    assert len(state['checks']) == 114
    for name in ('PME','PME1'):
        assert call(rpc,ctx[name],'paused()',tag=tag)==[1]
    for name in ('NEW','OLD','V1'):
        assert [call(rpc,ctx[name],sig,tag=tag)[0] for sig in maintenance.FLAGS] == [1]*4
    assert ctx['backend_stopped']()['backend_runtime_state']=='STOPPED'
    runtime = bytes.fromhex(rpc('eth_getCode',[ctx['NEW'],tag])[2:])
    assert len(runtime)==24321 and runtime==ctx['linked'](ctx['artifact'],'deployedBytecode')
    assert '0x'+ctx['keccak256'](runtime).hex()==ctx['ENGINE_HASH']
    owners = {}
    addresses={'INSURANCE':INSURANCE,'VAULT':VAULT,'FMV2':ctx['deps']['feesManagerV2()'],
               'RISK_V2':ctx['RISK'],'PME_V2':ctx['PME']}
    assert addresses['FMV2'].lower()=='0x00da0b9876bcbf0c79cb5bcacfebafb8c7ad774f'
    for name, contract in addresses.items():
        owners[name]=address(call(rpc,contract,'owner()',tag=tag)[0])
    assert owners['INSURANCE'].lower()==owners['VAULT'].lower()==TIMELOCK.lower()
    assert all(owners[x].lower()==ctx['OWNER'].lower() for x in ('FMV2','RISK_V2','PME_V2'))
    tl={'owner':address(call(rpc,TIMELOCK,'owner()',tag=tag)[0]),
        'guardian':address(call(rpc,TIMELOCK,'guardian()',tag=tag)[0]),
        'minDelay':call(rpc,TIMELOCK,'minDelay()',tag=tag)[0],
        'gracePeriod':call(rpc,TIMELOCK,'GRACE_PERIOD()',tag=tag)[0],
        'queuePaused':bool(call(rpc,TIMELOCK,'queuePaused()',tag=tag)[0]),
        'safeProposer':bool(call(rpc,TIMELOCK,'proposers(address)',[ctx['SAFE']],tag)[0]),
        'safeExecutor':bool(call(rpc,TIMELOCK,'executors(address)',[ctx['SAFE']],tag)[0]),
        'ownerEoaProposer':bool(call(rpc,TIMELOCK,'proposers(address)',[ctx['OWNER']],tag)[0]),
        'ownerEoaExecutor':bool(call(rpc,TIMELOCK,'executors(address)',[ctx['OWNER']],tag)[0])}
    assert tl['owner'].lower()==ctx['SAFE'].lower() and not tl['queuePaused']
    assert tl['safeProposer'] and tl['safeExecutor']
    safe={'address':ctx['SAFE'],'nonce':call(rpc,ctx['SAFE'],'nonce()',tag=tag)[0],
          'threshold':call(rpc,ctx['SAFE'],'getThreshold()',tag=tag)[0],
          'owners':decoded_address_array(rpc('eth_call',[{'to':ctx['SAFE'],'data':cd('getOwners()')},tag]))}
    assert safe['threshold']==2 and len(safe['owners'])==3
    # Safe linked-list sentinel is address(1). Decode only ABI words returned by getModulesPaginated.
    mods=abi_words(rpc('eth_call',[{'to':ctx['SAFE'],'data':cd('getModulesPaginated(address,uint256)',('0x0000000000000000000000000000000000000001',10))},tag]))
    offset=int.from_bytes(mods[0],'big'); assert offset==64
    module_count=int.from_bytes(mods[2],'big'); assert module_count < 10
    safe['modules']=['0x'+word[-20:].hex() for word in mods[3:3+module_count]]
    safe['nextModule']='0x'+mods[1][-20:].hex()
    assert len(mods)==3+module_count
    nonces={k:int(rpc('eth_getTransactionCount',[a,'latest']),16) for k,a in
        (('owner',ctx['OWNER']),('executor',ctx['EXECUTOR']))}
    pending={k:int(rpc('eth_getTransactionCount',[a,'pending']),16) for k,a in
        (('owner',ctx['OWNER']),('executor',ctx['EXECUTOR']))}
    assert nonces==pending and nonces=={'owner':812,'executor':1} and safe['nonce']==15
    scan_start=47529108
    emitters=[ctx[x] for x in ('NEW','OLD','V1','PME','PME1','RISK','VAULT','PMR')]
    emitters += [addresses['FMV2'],INSURANCE,TIMELOCK,ctx['SAFE']]
    events=[]
    for start in range(scan_start,int(tag,16)+1,2000):
        logs=rpc('eth_getLogs',[{'address':emitters,'fromBlock':hex(start),'toBlock':hex(min(start+1999,int(tag,16)))}])
        events.extend({'address':x['address'],'transactionHash':x['transactionHash'],
                       'blockNumber':int(x['blockNumber'],16),'topic0':x['topics'][0] if x['topics'] else None} for x in logs)
    assert not events, 'Unexpected relevant event after maintenance; inspect before queue preparation'
    assert call(rpc,ctx['PME'],'perpEngine()',tag=tag)[0]==int(ctx['OLD'],16)
    assert call(rpc,ctx['RISK'],'perpEngine()',tag=tag)[0]==int(ctx['OLD'],16)
    assert call(rpc,VAULT,'isAuthorizedEngine(address)',[ctx['NEW']],tag)[0]==0
    assert call(rpc,INSURANCE,'isBackstopCaller(address)',[ctx['NEW']],tag)[0]==0
    assert call(rpc,addresses['FMV2'],'isFeeConsumer(address)',[ctx['NEW']],tag)[0]==0
    # Exact deployed Timelock runtime is known from the earlier governance planning evidence.
    tl_art=json.loads((ROOT/'out/ProtocolTimelock.sol/ProtocolTimelock.json').read_text())
    assert bytes.fromhex(rpc('eth_getCode',[TIMELOCK,tag])[2:])==ctx['linked'](tl_art,'deployedBytecode')
    t=int(b['timestamp'],16)
    eta=t+max(72*3600,tl['minDelay']+48*3600)
    assert eta-t>=tl['minDelay'] and eta>t
    queue_abi={'inputs':[{'internalType':'address','name':'target','type':'address'},
                         {'internalType':'uint256','name':'value','type':'uint256'},
                         {'internalType':'bytes','name':'data','type':'bytes'},
                         {'internalType':'uint256','name':'eta','type':'uint256'}],
               'name':'queueTransaction','outputs':[{'internalType':'bytes32','name':'txHash','type':'bytes32'}],
               'stateMutability':'nonpayable','type':'function'}
    save('queue_transaction_abi.json',[queue_abi])
    operations=[]
    for idx,(name,target,sig) in enumerate((('G1_INSURANCE',INSURANCE,'setBackstopCaller(address,bool)'),
                                           ('G2_VAULT',VAULT,'setAuthorizedEngine(address,bool)'))):
        inner=cd(sig,(ctx['NEW'],'true'))
        selector=subprocess.check_output(['cast','sig',sig],text=True).strip()
        assert inner[:10]==selector
        assert len(inner)==138 and int(inner[10:74],16)==int(ctx['NEW'],16) and int(inner[74:],16)==1
        decoded_inner=subprocess.check_output(['cast','calldata-decode',sig,inner],text=True).splitlines()
        assert decoded_inner==[ctx['NEW'],'true']
        outer=cd('queueTransaction(address,uint256,bytes,uint256)',(target,0,inner,eta))
        assert outer[:10]==subprocess.check_output(['cast','sig','queueTransaction(address,uint256,bytes,uint256)'],text=True).strip()
        decoded_outer=subprocess.check_output(['cast','calldata-decode',
            'queueTransaction(address,uint256,bytes,uint256)',outer],text=True).splitlines()
        assert decoded_outer[0].lower()==target.lower() and decoded_outer[1]=='0'
        assert decoded_outer[2].lower()==inner.lower() and decoded_outer[3].split(' ')[0]==str(eta)
        encoded=subprocess.check_output(['cast','abi-encode','f(address,uint256,bytes,uint256)',target,'0',inner,str(eta)],text=True).strip()
        local_id='0x'+ctx['keccak256'](bytes.fromhex(encoded[2:])).hex()
        chain_id=rpc('eth_call',[{'to':TIMELOCK,'data':cd('hashOperation(address,uint256,bytes,uint256)',(target,0,inner,eta))},tag])
        assert chain_id.lower()==local_id.lower()
        assert call(rpc,TIMELOCK,'queuedTransactions(bytes32)',[local_id],tag)[0]==0
        assert rpc('eth_call',[{'from':ctx['SAFE'],'to':TIMELOCK,'data':outer,'value':'0x0'},tag]).lower()==local_id.lower()
        assert rpc('eth_call',[{'from':TIMELOCK,'to':target,'data':inner,'value':'0x0'},tag])=='0x'
        # These direct eth_calls discard effects; current permission remains false.
        getter='isBackstopCaller(address)' if idx==0 else 'isAuthorizedEngine(address)'
        assert call(rpc,target,getter,[ctx['NEW']],tag)[0]==0
        operation={'name':name,'safeNonceForReview':safe['nonce']+idx,'safe':ctx['SAFE'],
                   'safeTarget':TIMELOCK,'safeOperation':'CALL','safeOperationCode':0,'valueWei':0,
                   'target':target,'innerFunction':sig,'innerCalldata':inner,'outerFunction':'queueTransaction(address,uint256,bytes,uint256)',
                   'outerCalldata':outer,'eta':eta,'etaUTC':utc(eta),'queueDeadline':eta-tl['minDelay'],
                   'queueDeadlineUTC':utc(eta-tl['minDelay']),'executionWindowEnd':eta+tl['gracePeriod'],
                   'executionWindowEndUTC':utc(eta+tl['gracePeriod']),
                   'operationId':local_id,'onchainOperationId':chain_id,'currentlyQueued':False,
                   'setterCallFromTimelockPassed':True,'queueCallFromSafePassed':True,
                   'expectedImmediateEffect':'Timelock pending flag only; target permission stays false',
                   'expectedFutureEffect':('Authorize NEW_ENGINE as Insurance backstop caller' if idx==0 else
                                           'Authorize NEW_ENGINE in Vault mapping and append to authorizedEngines if not listed')}
        operations.append(operation)
        builder_method={'inputs':queue_abi['inputs'],'name':'queueTransaction','payable':False}
        builder={'version':'1.0','chainId':'84532','createdAt':t*1000,
                 'meta':{'name':name,'description':'Review only: one Safe CALL to queue one independent Timelock operation',
                         'txBuilderVersion':'1.18.0','createdFromSafeAddress':ctx['SAFE'],'createdFromOwnerAddress':''},
                 'transactions':[{'to':TIMELOCK,'value':'0','data':outer,'contractMethod':builder_method,
                                  'contractInputsValues':{'target':target,'value':'0','data':inner,'eta':str(eta)}}]}
        save(name.lower()+'_safe_builder.json',builder)
        save(name.lower()+'_safe_review_manifest.json',{
            **operation,'reviewedSafeTxFields':{'to':TIMELOCK,'value':'0','data':outer,'operation':0,
              'safeTxGas':'0','baseGas':'0','gasPrice':'0','gasToken':ZERO,'refundReceiver':ZERO,
              'nonce':safe['nonce']+idx},
            'warning':'Builder import does not bind Safe nonce/gas/refund fields. Compare the actual constructed Safe transaction before any future signature; no SafeTx hash asserted.'})
    assert operations[0]['operationId']!=operations[1]['operationId']
    report={'milestone':'PERPS_V2_BASE_SEPOLIA_RECOVERY_GOVERNANCE_PREPARE_V1',
            'solHead':CHECKPOINT,'backendHead':BACKEND_CHECKPOINT,'chainId':84532,
            'comparisonBlock':int(tag,16),'comparisonBlockHash':b['hash'],'comparisonTimestamp':t,
            'comparisonUTC':utc(t),'stateChecks':114,'seedFlags':len(state['seedFlags']),
            'positionIndexes':len(state['positionIndexes']),'pmeTraderNonces':state['pmeV2Nonces'],
            'runtimeKeccak256':ctx['ENGINE_HASH'],'snapshotHash':ctx['SNAPSHOT'],
            'backendRuntimeState':'STOPPED','backendScope':'local /proc executable/comm and port 8080 only',
            'scopedEvents':events,'scannedFromBlock':scan_start,'owners':owners,'timelock':tl,
            'safe':safe,'eoaNonces':nonces,'eoaPendingNonces':pending,'operations':operations,
            'publicWrites':0,'keystoreUnlocked':False,'signaturesGenerated':False}
    save('readback_and_operations.json',report)
    print(json.dumps({'comparisonBlock':report['comparisonBlock'],'comparisonBlockHash':b['hash'],
        'comparisonUTC':report['comparisonUTC'],'ownerNonce':nonces['owner'],'safeNonce':safe['nonce'],
        'executorNonce':nonces['executor'],'timelock':tl,'owners':owners,
        'operationIds':[x['operationId'] for x in operations],'eta':eta,'etaUTC':utc(eta),
        'queueDeadlineUTC':utc(eta-tl['minDelay']),'executionWindowEndUTC':utc(eta+tl['gracePeriod']),
        'scopedEvents':len(events),'economicChecks':114},indent=2))


if __name__=='__main__':
    main()
