#!/usr/bin/env python3
"""Maintenance Stage A: public reads, four maximum writes ONLY to local Anvil.

Never signs, unlocks a keystore, or sends to the public endpoint. Existing
canonical and BLOCKED-rebind evidence is preserved byte-for-byte.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
import migration_reseal_preflight as m

ROOT = m.ROOT
OUT = ROOT/'artifacts/perps_v2_recovery_maintenance_lock'
FLAGS = ['tradingPaused()', 'liquidationPaused()', 'fundingPaused()', 'collateralOpsPaused()']
FLAG_EVENTS = ['TradingPauseSet(bool)', 'LiquidationPauseSet(bool)', 'FundingPauseSet(bool)', 'CollateralOpsPauseSet(bool)']
TIMELOCK = '0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588'


def save(name, data):
    (OUT/name).write_text(json.dumps(data, indent=2)+'\n')


def raw(endpoint, method, params):
    try:
        req = urllib.request.Request(endpoint, data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(), headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(req, timeout=45) as response:
            return json.load(response)
    except Exception:
        raise RuntimeError('RPC transport failed; endpoint withheld') from None


def error_data(result):
    e = result.get('error', {}).get('data')
    return e.get('data') if isinstance(e, dict) else e


def main():
    assert not sys.flags.optimize
    OUT.mkdir(exist_ok=True)
    inventory = json.loads((OUT/'entry_inventory.json').read_text())
    def preserved():
        for name, digest in inventory['preservedBlockedRebindFiles'].items():
            assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest, 'Prior evidence changed'
        assert not subprocess.check_output(['git','diff','--name-only'], cwd=ROOT).strip()
        assert not subprocess.check_output(['git','status','--porcelain'], cwd=ROOT.parent/'deopt-v2-backend').strip()
    preserved()
    c = m.prepare_context()
    r, call, expect = c['live'], c['call'], c['expect']
    c['READS'].update(['debug_traceCall', 'eth_estimateGas'])
    k = lambda data: '0x'+c['keccak256'](data).hex()
    cd = c['calldata']
    assert int(r('eth_chainId', []),16) == 84532
    cached = json.loads((OUT/'baseline.json').read_text()) if '--reuse-comparison-block' in sys.argv else None
    b = r('eth_getBlockByNumber',[hex(cached['block']) if cached else 'latest',False]); tag = b['number']
    if cached: assert b['hash'] == cached['blockHash']
    assert int(b['hash'],16)
    owner = c['OWNER']
    nonce = int(r('eth_getTransactionCount',[owner,'latest']),16)
    assert nonce == int(r('eth_getTransactionCount',[owner,'pending']),16) == 808, 'Nonce drift; separate review'
    c['checks'] = [(label,a,sig,1 if sig=='migrationState()' else c['SNAPSHOT'],args)
        if a.lower()==c['NEW'].lower() and sig in ['migrationState()','migrationSnapshotHash()']
        else (label,a,sig,want,args) for label,a,sig,want,args in c['checks']]
    prior = json.loads((m.OUT/'postflight.json').read_text())
    def reconcile(rpc, blocktag):
        old = c['live']; c['live'] = rpc
        try:
            state = m.reconcile_state(c, blocktag, prior)
            state['checks'] = [{**x,'args':list(x['args'])} for x in state['checks']]
            return state
        finally: c['live'] = old
    state = {key:cached[key] for key in ['checks','seedFlags','positionIndexes','pmeV2Nonces']} if cached else reconcile(r,tag)
    for key in ['checks','seedFlags','positionIndexes','pmeV2Nonces']:
        assert state[key] == prior[key], 'Canonical state drift: '+key
    report = {'milestone':'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1','stage':'A','publicWrites':0,'keystoreUnlocked':False,
        'chainId':84532,'block':int(tag,16),'blockHash':b['hash'],'blockTimestamp':int(b['timestamp'],16),'ownerNonce':nonce,
        'ownerBalanceWei':int(r('eth_getBalance',[owner,tag]),16),'snapshotHash':c['SNAPSHOT'],'canonicalFileSha256':c['hashes'],
        'solHead':inventory['solHead'],'backendHead':inventory['backendHead'],**state}
    print('Pinned economic reconciliation PASS: 114 checks plus bookkeeping',flush=True)
    save('baseline.json',report)
    abi_names = {'PME':'PerpMatchingEngineV2','NEW':'PerpEngineV2','OLD':'PerpEngineV2','V1':'PerpEngine'}
    codes, abis, controls, authority, steps = {}, {}, {}, {}, []
    topic = lambda sig: k(sig.encode())
    one = '0x'+(1).to_bytes(32,'big').hex()
    for name in ['PME','NEW','OLD','V1']:
        a = c[name]
        code = bytes.fromhex(r('eth_getCode',[a,tag])[2:]); codes[name] = code
        artifact = json.loads((ROOT/'out'/f'{abi_names[name]}.sol'/f'{abi_names[name]}.json').read_text())
        abis[name] = artifact['abi']
        localcode = c['linked'](artifact,'deployedBytecode')
        same = code == localcode
        immutable_mask_equal = None
        if name=='PME':
            live_mask,local_mask = bytearray(code),bytearray(localcode)
            for refs in artifact['deployedBytecode']['immutableReferences'].values():
                for ref in refs:
                    i,n = ref['start'],ref['length']; live_mask[i:i+n] = local_mask[i:i+n] = bytes(n)
            immutable_mask_equal = live_mask == local_mask
            assert immutable_mask_equal
        if name in ['NEW','OLD']:
            assert same and len(code)==24321 and k(code)==c['ENGINE_HASH']
        saved = cached.get('authorities',{}).get(name) if cached else None
        own = saved['owner'] if saved else '0x'+call(r,a,'owner()',tag=tag)[0].to_bytes(20,'big').hex()
        guardian = saved['guardian'] if saved else '0x'+call(r,a,'guardian()',tag=tag)[0].to_bytes(20,'big').hex()
        assert owner.lower() in [own.lower(),guardian.lower()]
        flags = cached['controls'][name] if saved else ([call(r,a,'paused()',tag=tag)[0]] if name=='PME' else [call(r,a,s,tag=tag)[0] for s in FLAGS])
        controls[name] = flags
        sig = 'pause()' if name=='PME' else 'setEmergencyModes(bool,bool,bool,bool)'
        args = () if name=='PME' else ('true',)*4
        data = cd(sig,args)
        assert r('eth_call',[{'from':owner,'to':a,'data':data,'value':'0x0'},tag]) == '0x'
        authority[name] = {'address':a,'owner':own,'guardian':guardian,'ownerContextCallPassed':True,'selector':data[:10],
            'runtimeBytes':len(code),'runtimeKeccak256':k(code),'equalsCurrentArtifact':same,
            'artifactMatchExcludingImmutables':immutable_mask_equal,
            'abiScope':'Current artifact exact' if same else 'Deployed maintenance surface checked by live call, fork controls/events and storage-diff trace; no whole-V1-source identity assumed'}
        if all(flags): continue
        if name=='PME': events = [{'topics':[topic('Paused(address)'), '0x'+owner[2:].lower().rjust(64,'0')],'data':'0x'}]
        else:
            events = [{'topics':[topic(event)],'data':one} for event,value in zip(FLAG_EVENTS,flags) if not value]
            events.append({'topics':[topic('EmergencyModeUpdated(bool,bool,bool,bool)')],'data':'0x'+one[2:]*4})
        steps.append({'ordinal':len(steps)+1,'name':name,'chainId':84532,'sender':owner,'target':a,'nonce':nonce+len(steps),'value':0,
            'function':sig,'selector':data[:10],'decodedArguments':[] if name=='PME' else [True]*4,'calldata':data,
            'pauseFlagsBefore':flags,'pauseFlagsAfter':[1]*len(flags),'expectedEvents':events})
    report.update(authorities=authority,controls=controls,skipped=[name for name,v in controls.items() if all(v)])
    report['insuranceOwner'] = expect(r,c['deps']['insuranceFund()'],'owner()',TIMELOCK,tag=tag)
    report['safeNonce'] = call(r,c['SAFE'],'nonce()',tag=tag)[0]
    report['executorNonce'] = int(r('eth_getTransactionCount',[c['EXECUTOR'],tag]),16)
    report['pmeDomainSeparator'] = r('eth_call',[{'to':c['PME'],'data':cd('domainSeparatorV4()')},tag])
    report['executorPermissions'] = {a:call(r,c['PME'],'isExecutor(address)',[a],tag)[0] for a in [owner,c['EXECUTOR']]}
    report['oldPermissions'] = {getter:call(r,c['deps'][getter],sig,[c['OLD']],tag)[0] for getter,sig in [('feesManagerV2()','isFeeConsumer(address)'),('insuranceFund()','isBackstopCaller(address)')]}
    report['localBackend'] = {**c['backend_stopped'](),'scope':'local process executable/comm and port 8080; not global absence of activity'}
    report['fundingExposure'] = []
    for name in ['NEW','OLD','V1']:
        tx = {'from':'0x0000000000000000000000000000000000000001','to':c[name],'value':'0x0','data':cd('updateFunding(uint256)',(2,))}
        res = raw(c['url'],'eth_call',[tx,tag])
        row = {'name':name,'transaction':tx,'result':res.get('result'),'errorData':error_data(res),'publicWrite':False}
        if 'result' in res:
            diff = r('debug_traceCall',[tx,tag,{'tracer':'prestateTracer','tracerConfig':{'diffMode':True}}])
            post = diff['post'].get(c[name].lower(),{}).get('storage',{})
            assert len(post)==1 and int(next(iter(post.values())),16)==int(b['timestamp'],16)
            slot = next(iter(post))
            assert int(r('eth_getStorageAt',[c[name],slot,tag]),16)==0
            row.update(storageDiff=post,previousStorageValue=0,effect='market 2 timestamp initialization only; no funding/PnL accrual')
        report['fundingExposure'].append(row)
    save('baseline.json',report)
    print('Authorities and actual deployed pause calls PASS; exposures:',[(x['name'],x['result'] is not None) for x in report['fundingExposure']],flush=True)

    # Separate planning-only reads. No concrete ETA/operation ID or queue payload.
    gov = {'timelock':TIMELOCK,'minDelay':call(r,TIMELOCK,'minDelay()',tag=tag)[0],
        'queuePaused':call(r,TIMELOCK,'queuePaused()',tag=tag)[0],
        'owner':'0x'+call(r,TIMELOCK,'owner()',tag=tag)[0].to_bytes(20,'big').hex(),
        'vaultOwner':'0x'+call(r,c['VAULT'],'owner()',tag=tag)[0].to_bytes(20,'big').hex(),
        'roles':{a:{s:call(r,TIMELOCK,s,[a],tag)[0] for s in ['proposers(address)','executors(address)']} for a in [owner,c['SAFE']]},
        'safeThreshold':call(r,c['SAFE'],'getThreshold()',tag=tag)[0],
        'safeOwnersAbi':r('eth_call',[{'to':c['SAFE'],'data':cd('getOwners()')},tag]),
        'operationIdFormula':'Ethereum keccak256(abi.encode(target,value,data,eta)); two distinct operations; ETA not selected',
        'insuranceTarget':c['deps']['insuranceFund()'],'vaultTarget':c['VAULT'],
        'noQueueOrExecutionPrepared':True}
    tl_art=json.loads((ROOT/'out/ProtocolTimelock.sol/ProtocolTimelock.json').read_text())
    tl_code=bytes.fromhex(r('eth_getCode',[TIMELOCK,tag])[2:])
    gov['runtimeEqualsLocalArtifact']=tl_code==c['linked'](tl_art,'deployedBytecode')
    gov['runtimeKeccak256']=k(tl_code)
    gov['sourceOperationMethods']=[x['name'] for x in tl_art['abi'] if x['type']=='function' and any(v in x['name'].lower() for v in ['queue','execute','batch'])]
    save('governance_planning.json',gov)

    base=int(b['baseFeePerGas'],16); priority=int(r('eth_maxPriorityFeePerGas',[]),16)
    fee=max(2*base+priority,int(r('eth_gasPrice',[]),16))
    l1=2*call(r,'0x420000000000000000000000000000000000000F','getL1FeeUpperBound(uint256)',[512],tag)[0]
    fees={'baseFeePerGasWei':base,'maxPriorityFeePerGasWei':priority,'maxFeePerGasWei':fee,'l1AllowancePerTxWei':l1,
          'l1Method':'2x deployed OP GasPriceOracle.getL1FeeUpperBound(512); exceeds 132-byte calldata plus signed-envelope overhead','gasMarginPercent':30}
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    endpoint='http://127.0.0.1:'+str(port)
    proc=subprocess.Popen(['anvil','--fork-url',c['url'],'--fork-block-number',str(report['block']),'--chain-id','84532','--host','127.0.0.1','--port',str(port),'--accounts','0','--quiet','--threads','1','--no-storage-caching','--disable-default-create2-deployer'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    def local(method,params):
        assert proc.poll() is None and endpoint.startswith('http://127.0.0.1:')
        assert method in c['READS']|{'anvil_impersonateAccount','anvil_stopImpersonatingAccount','eth_sendTransaction','debug_traceTransaction'}
        return c['request'](endpoint,method,params)
    simulation={'localRpc':endpoint,'scope':'isolated Anvil fork, not public Base Sepolia; chainId also 84532','forkBlock':report['block'],
        'storageOverrides':False,'codeReplacement':False,'balanceFabrication':False,'keystoreUnlocked':False,'steps':[],
        'executionMode':'Standard EVM over actual Base Sepolia fork state; OP-mode four-admin-call proof preserved in fork_attempt_3.json',
        'feeScope':'Local standard-EVM receipts exclude OP L1 charges; public OP GasPriceOracle supplies separate fee allowance',
        'reason':'Anvil OP eth_call charges L1 cost to unfunded contract callers before reaching EVM. Standard EVM permits fee-free authorized-caller pause probes; no contract code, storage or balances changed to bypass checks.'}
    def negative(name,address,sig,args,sender,error):
        data=cd(sig,tuple(args));res=raw(endpoint,'eth_call',[{'from':sender,'to':address,'data':data,'gasPrice':'0x0','gas':hex(500000)},'latest'])
        want=k(error.encode())[:10]
        if error_data(res)!=want:save('negative_probe_failure.json',{'name':name,'response':res,'expectedError':error})
        assert error_data(res)==want, 'Wrong maintenance revert for '+name+': '+str(error_data(res))
        return {'name':name,'from':sender,'target':address,'function':sig,'calldata':data,'expectedError':error,'errorData':want,'passed':True,'method':'eth_call'}
    try:
        for _ in range(60):
            if proc.poll() is not None: raise RuntimeError('Local fork startup failed')
            try:
                if 'anvil' in local('web3_clientVersion',[]).lower():break
            except RuntimeError:pass
            time.sleep(.5)
        else:raise RuntimeError('Local startup timeout')
        assert local('eth_getBlockByNumber',[tag,False])['hash']==b['hash']
        assert int(local('eth_chainId',[]),16)==84532
        assert int(local('eth_getTransactionCount',[owner,'latest']),16)==nonce
        assert int(local('eth_getBalance',[owner,'latest']),16)==report['ownerBalanceWei']
        for name,code in codes.items():assert local('eth_getCode',[c[name],'latest'])=='0x'+code.hex()
        local('anvil_impersonateAccount',[owner])
        expected_controls=dict(controls)
        for step in steps:
            tx={'from':owner,'to':step['target'],'data':step['calldata'],'value':'0x0','nonce':hex(step['nonce']),'gas':hex(500000),
                'maxFeePerGas':hex(fee),'maxPriorityFeePerGas':hex(priority)}
            estimate=int(local('eth_estimateGas',[tx]),16);limit=(estimate*130+99)//100;tx['gas']=hex(limit)
            h=local('eth_sendTransaction',[tx])
            simulation['pendingLocalTransaction']={'hash':h,'ordinal':step['ordinal'],'nonce':step['nonce'],'target':step['target']}
            save('fork_simulation.json',simulation)
            receipt=None
            for _ in range(120):
                receipt=local('eth_getTransactionReceipt',[h])
                if receipt is not None:break
                time.sleep(.25)
            simulation['pendingLocalTransaction']['receipt']=receipt
            save('fork_simulation.json',simulation)
            assert receipt and int(receipt['status'],16)==1, 'Local receipt failed or unavailable; no next step'
            actual=local('eth_getTransactionByHash',[h]);assert actual['to'].lower()==step['target'].lower() and actual['input']==step['calldata'] and int(actual['nonce'],16)==step['nonce']
            assert len(receipt['logs'])==len(step['expectedEvents'])
            for event,want in zip(receipt['logs'],step['expectedEvents']):
                assert event['address'].lower()==step['target'].lower() and event['topics']==want['topics'] and event['data']==want['data']
            trace=local('debug_traceTransaction',[h,{'tracer':'callTracer'}]);assert not trace.get('calls'), 'Unexpected external call'
            diff=local('debug_traceTransaction',[h,{'tracer':'prestateTracer','tracerConfig':{'diffMode':True}}])
            storage_changes={a:x['storage'] for a,x in diff['post'].items() if x.get('storage')}
            assert set(storage_changes)=={step['target'].lower()} and len(storage_changes[step['target'].lower()])==1
            slot,value=next(iter(storage_changes[step['target'].lower()].items()))
            before=diff['pre'][step['target'].lower()].get('storage',{}).get(slot,'0x0')
            before_bytes=int(before,16).to_bytes(32,'big');after_bytes=int(value,16).to_bytes(32,'big')
            changed=[(a,b) for a,b in zip(before_bytes,after_bytes) if a!=b]
            assert changed==[(0,1)]*sum(1 for v in step['pauseFlagsBefore'] if not v), 'Unexpected control/storage mutation'
            expected_controls[step['name']]=step['pauseFlagsAfter']
            for name,flags in expected_controls.items():
                got=[call(local,c[name],'paused()')[0]] if name=='PME' else [call(local,c[name],s)[0] for s in FLAGS]
                assert got==flags
            after=reconcile(local,'latest');assert after==state, 'Economic/shared/migration state changed'
            assert local('eth_call',[{'to':c['PME'],'data':cd('domainSeparatorV4()')},'latest'])==report['pmeDomainSeparator']
            for a,v in report['executorPermissions'].items():expect(local,c['PME'],'isExecutor(address)',v,[a])
            for getter,v in report['oldPermissions'].items():expect(local,c['deps'][getter],'isFeeConsumer(address)' if getter=='feesManagerV2()' else 'isBackstopCaller(address)',v,[c['OLD']])
            step.update(gasEstimate=estimate,gasLimit=limit,maxFeePerGasWei=fee,maxPriorityFeePerGasWei=priority,l1FeeAllowanceWei=l1)
            simulation['steps'].append({'ordinal':step['ordinal'],'name':step['name'],'localTransactionHash':h,'receipt':receipt,
                'exactEvents':True,'noExternalCalls':True,'storageChanges':storage_changes,'economicChecks':114,'economicsFlagsIndexesNoncesUnchanged':True,
                'localGasUsed':int(receipt['gasUsed'],16)})
            del simulation['pendingLocalTransaction']
            save('fork_simulation.json',simulation)
            print('LOCAL maintenance step',step['ordinal'],step['name'],'PASS, gas estimate',estimate,flush=True)
        probes=[]
        trader=c['manifest']['positions'][0]['trader'];other=c['manifest']['positions'][1]['trader']
        for name in ['NEW','OLD','V1']:
            a=c[name]
            for mid in [1,2]:probes.append(negative(name+'.funding'+str(mid),a,'updateFunding(uint256)',[mid],owner,'FundingPaused()'))
            me='0x'+call(local,a,'matchingEngine()')[0].to_bytes(20,'big').hex()
            trade=f'({trader},{other},1,1,300000000000,true)'
            probes.append(negative(name+'.applyTrade',a,'applyTrade((address,address,uint256,uint128,uint128,bool))',[trade],me,'TradingPaused()'))
            probes.append(negative(name+'.liquidate',a,'liquidate(address,uint256,uint128)',[trader,1,1],owner,'LiquidationPaused()'))
            impact_sig='updateImpactMid(uint256,uint128)'
            selector=bytes.fromhex(cd(impact_sig,(1,300000000000))[2:10])
            if b'\x63'+selector in codes[name]:
                keeper='0x'+call(local,a,'impactMidSource()')[0].to_bytes(20,'big').hex()
                probes.append(negative(name+'.impactMid',a,impact_sig,[1,300000000000],keeper,'FundingPaused()'))
            else:
                probes.append({'name':name+'.impactMid','present':False,'evidence':'selector absent from actual deployed PUSH4 dispatch; no current-V1 ABI assumption'})
        # Empty signatures are never validated: authorized executor reaches pause first.
        trade='(0x'+'00'*32+f',{trader},{other},1,1,300000000000,400000000000,200000000000,true,0,0,0)'
        probes.append(negative('PME.executeTrade',c['PME'],'executeTrade((bytes32,address,address,uint256,uint128,uint128,uint128,uint128,bool,uint256,uint256,uint256),bytes,bytes)',[trade,'0x','0x'],owner,'PausedError()'))
        simulation['negativeProbes']=probes
        simulation['essentialReads']='Full 114 state gates, market/position/index/debt reads and domain/nonces succeed after every step'
        simulation['collateralOperations']='No PerpEngine external collateral entrypoint in inspected surface uses whenCollateralOpsNotPaused. Flag set/read verified; shared Vault not paused.'
        simulation['finalOwnerNonce']=int(local('eth_getTransactionCount',[owner,'latest']),16)
        assert simulation['finalOwnerNonce']==nonce+len(steps)
        expect(local,c['SAFE'],'nonce()',report['safeNonce'])
        assert int(local('eth_getTransactionCount',[c['EXECUTOR'],'latest']),16)==report['executorNonce']
        local('anvil_stopImpersonatingAccount',[owner])
        simulation['passed']=True
    finally:
        proc.terminate()
        try:proc.wait(timeout=10)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
        simulation['localForkStopped']=True
        save('fork_simulation.json',simulation)
    # Refresh the public state; local fork writes have no public side effects.
    fresh=r('eth_getBlockByNumber',['latest',False]);ft=fresh['number']
    assert reconcile(r,ft)==state, 'Public economic drift during rehearsal'
    assert int(r('eth_getTransactionCount',[owner,'latest']),16)==int(r('eth_getTransactionCount',[owner,'pending']),16)==nonce
    for name,flags in controls.items():
        got=[call(r,c[name],'paused()',tag=ft)[0]] if name=='PME' else [call(r,c[name],s,tag=ft)[0] for s in FLAGS]
        assert got==flags, 'Public control drift during rehearsal'
        expect(r,c[name],'owner()',authority[name]['owner'],tag=ft)
        expect(r,c[name],'guardian()',authority[name]['guardian'],tag=ft)
        assert r('eth_getCode',[c[name],ft])=='0x'+codes[name].hex()
    emitters=prior['eventAudit']['emitters'];logs=[]
    for first in range(prior['block']+1,int(ft,16)+1,2000):
        logs.extend(r('eth_getLogs',[{'address':emitters,'fromBlock':hex(first),'toBlock':hex(min(first+1999,int(ft,16)))}]))
    assert not logs, 'Unexpected scoped event since reseal'
    # Refresh fee bounds at the final public comparison; retaining a higher
    # simulation cap is conservative and does not change the approved calldata.
    final_base=int(fresh['baseFeePerGas'],16)
    final_priority=int(r('eth_maxPriorityFeePerGas',[]),16)
    priority=max(priority,final_priority)
    fee=max(fee,2*final_base+priority,int(r('eth_gasPrice',[]),16))
    l1=max(l1,2*call(r,'0x420000000000000000000000000000000000000F','getL1FeeUpperBound(uint256)',[512],ft)[0])
    fees.update(finalFeeBlock=int(ft,16),finalBaseFeePerGasWei=final_base,maxFeePerGasWei=fee,maxPriorityFeePerGasWei=priority,l1AllowancePerTxWei=l1)
    for step in steps:step.update(maxFeePerGasWei=fee,maxPriorityFeePerGasWei=priority,l1FeeAllowanceWei=l1)
    fees['totalGasEstimate']=sum(x['gasEstimate'] for x in steps)
    fees['totalGasLimit']=sum(x['gasLimit'] for x in steps)
    fees['totalBudgetWei']=fees['totalGasLimit']*fee+len(steps)*l1
    fresh_balance=int(r('eth_getBalance',[owner,ft]),16);assert fresh_balance>fees['totalBudgetWei']
    package={'milestone':report['milestone'],'stage':'A_REQUIRES_NEW_OPERATOR_READY','chainId':84532,'sender':owner,'comparisonBlock':report['block'],
        'comparisonBlockHash':report['blockHash'],'snapshotHash':c['SNAPSHOT'],'startingNonce':nonce,'expectedFinalNonce':nonce+len(steps),
        'transactions':steps,'fees':fees,'ownerBalanceWei':fresh_balance,'skipped':report['skipped'],'publicWrites':0,
        'prohibitions':'No rebind, Insurance/FMV2/Risk/Vault/Timelock writes, unpause, trade, backend/DB action',
        'remainingIssues':['Insurance authorization requires actual ProtocolTimelock owner','Signed-order inventory unresolved; pauses do not invalidate signatures']}
    save('execution_package.json',package)
    ph=hashlib.sha256((OUT/'execution_package.json').read_bytes()).hexdigest()
    report.update(freshBlock=int(ft,16),freshBlockHash=fresh['hash'],eventScan={'fromBlock':prior['block']+1,'toBlock':int(ft,16),'emitters':emitters,'events':0},
        packageSha256=ph,fees=fees,ownerBalanceWei=fresh_balance,simulationPassed=True)
    report['localBackend']={**c['backend_stopped'](),'scope':'local process and port 8080 only'}
    preserved();c['verify_canonical']()
    save('preflight.json',report)
    print(json.dumps({'result':'READY_TO_BROADCAST','packageSha256':ph,'transactions':len(steps),'freshBlock':report['freshBlock'],'nonce':nonce,'fees':fees,'ownerBalanceWei':fresh_balance},indent=2),flush=True)


if __name__=='__main__':main()
