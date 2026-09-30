#!/usr/bin/env python3
"""Operator-approved one-shot M4 seal. No retries, replacements or resume.

Only the reviewed preview hash enables one cast send. Receipt observations are
preserved until nonzero canonical inclusion is established. Cleanup always runs.
Independent postflight is a separate read-only tool.
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
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/perps_v2_migration_reseal'
APPROVED = '993727c3d27fe697d28f04d2adbda4c91573e77f035a44b5ba4865e6f8a13134'
HELPER_HASH = 'f756745fe1d0be54a97fb2c7c03a00b545e108fc9e100ab60f08bcf6b41fd43a'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
NEW = '0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15'
SNAPSHOT = '0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d'
PASSWORD = Path('/run/user') / str(os.getuid()) / 'deopt-deployer.pw'
KEYSTORE = str(Path.home() / '.foundry/keystores/deopt-deployer')


def save(name, value):
    temp = OUT / (name+'.tmp')
    with temp.open('w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    temp.replace(OUT/name)


def load_context():
    helper = ROOT/'tools/perps_v2_cutover/migration_reseal_preflight.py'
    assert hashlib.sha256(helper.read_bytes()).hexdigest() == HELPER_HASH
    import migration_reseal_preflight as preflight
    assert hashlib.sha256((OUT/'transaction_preview.json').read_bytes()).hexdigest() == APPROVED
    preview = json.loads((OUT/'transaction_preview.json').read_text())
    assert preview == {'chainId': 84532, 'from': OWNER, 'to': NEW, 'nonce': 807, 'value': 0,
        'function': 'sealMigration(bytes32)', 'selector': '0x05d5af5b', 'args': [SNAPSHOT],
        'calldata': '0x05d5af5b'+SNAPSHOT[2:], 'gasLimit': 75000,
        'maxFeePerGasWei': 11000000, 'maxPriorityFeePerGasWei': 1000000}
    return preflight, preflight.prepare_context(), preview


def validate_receipt(receipt, tx, block, tx_hash, preview, expected_event):
    assert int(receipt['status'], 16) == 1, 'Seal receipt failed'
    assert receipt['transactionHash'] == tx['hash'] == tx_hash
    assert tx['from'].lower() == receipt['from'].lower() == OWNER.lower()
    assert tx['to'].lower() == receipt['to'].lower() == NEW.lower()
    assert int(tx['nonce'], 16) == 807 and int(tx['chainId'], 16) == 84532
    assert int(tx['value'], 16) == 0 and tx['input'].lower() == preview['calldata'].lower()
    assert int(tx['gas'], 16) == preview['gasLimit']
    assert int(tx['maxFeePerGas'], 16) == preview['maxFeePerGasWei']
    assert int(tx['maxPriorityFeePerGas'], 16) == preview['maxPriorityFeePerGasWei']
    assert not receipt.get('contractAddress')
    assert int(receipt['blockHash'], 16) != 0
    assert receipt['blockHash'] == tx['blockHash'] == block['hash']
    assert receipt['blockNumber'] == tx['blockNumber'] == block['number']
    assert tx_hash in block['transactions']
    assert len(receipt['logs']) == 1, 'Unexpected external/event mutation'
    event = receipt['logs'][0]
    assert not event.get('removed', False)
    assert event['address'].lower() == NEW.lower()
    assert [t.lower() for t in event['topics']] == expected_event['topics']
    assert event['data'].lower() == SNAPSHOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute-reviewed-preview', required=True)
    args = parser.parse_args()
    assert args.execute_reviewed_preview == APPROVED
    assert not sys.flags.optimize
    journal = {'milestone': 'PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1', 'chainId': 84532,
               'previewSha256': APPROVED, 'status': 'PRECHECK', 'publicSendInvocations': 0,
               'receiptObservations': []}
    owns_journal = False
    ctx = None
    try:
        assert not (OUT/'execution_journal.json').exists(), 'Existing journal; no automatic resume'
        assert not (OUT/'execution_started.json').exists(), 'Existing execution marker; no send'
        preflight, ctx, preview = load_context()
        rpc, expect, call = ctx['live'], ctx['expect'], ctx['call']
        before = json.loads((OUT/'preflight.json').read_text())
        previous = json.loads((ctx['DESTINATION']/'postflight.json').read_text())
        assert before['previewSha256'] == APPROVED and before['simulation']['passed']
        assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip() == preflight.CHECKPOINT
        assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT.parent/'deopt-v2-backend',text=True).strip() == preflight.BACKEND_HEAD
        assert not subprocess.check_output(['git','status','--porcelain'],cwd=ROOT.parent/'deopt-v2-backend',text=True).strip()
        assert subprocess.run(['git','diff','--quiet','HEAD','--','src','script','artifacts/perps_v2_final_snapshot','artifacts/perps_v2_migration_replay'],cwd=ROOT).returncode == 0
        for path, digest in before['preservedArtifactSha256'].items():
            assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest() == digest
        assert int(rpc('eth_chainId', []), 16) == 84532
        block = rpc('eth_getBlockByNumber', ['latest', False]); tag = block['number']
        state = call(rpc, NEW, 'migrationState()', tag=tag)[0]
        snapshot = call(rpc, NEW, 'migrationSnapshotHash()', tag=tag)[0]
        if state == 1:
            save('already_sealed_readback.json', {'block': int(tag,16), 'blockHash':block['hash'],
                 'migrationState':state, 'snapshotHash':'0x'+snapshot.to_bytes(32,'big').hex(),
                 'expectedHash':snapshot==int(SNAPSHOT,16), 'publicWrites':0})
            raise AssertionError('Already SEALED; identify existing seal transaction without sending')
        assert state == 0 and snapshot == 0
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16) == 807
        assert int(rpc('eth_getTransactionCount',[OWNER,'pending']),16) == 807
        runtime = bytes.fromhex(rpc('eth_getCode',[NEW,tag])[2:])
        assert len(runtime) == 24321 and '0x'+ctx['keccak256'](runtime).hex() == ctx['ENGINE_HASH']
        assert runtime == ctx['linked'](ctx['artifact'],'deployedBytecode')
        assert rpc('eth_getBlockByNumber',[hex(ctx['manifest']['snapshotBlockNumber']),False])['hash'] == ctx['manifest']['snapshotBlockHash']

        # Independent signer verification: never log wallet output on failure.
        metadata = PASSWORD.lstat(); directory = PASSWORD.parent.stat()
        assert stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o600
        assert metadata.st_uid == directory.st_uid == os.getuid() == 1000
        mount = subprocess.check_output(['findmnt','-n','-T',str(PASSWORD),'-o','FSTYPE,TARGET'],text=True).split()
        assert mount == ['tmpfs', str(PASSWORD.parent)]
        env = os.environ.copy()
        for key in ['ETH_PRIVATE_KEY','PRIVATE_KEY','DEPLOYER_PRIVATE_KEY','ETH_PASSWORD']:
            env.pop(key, None)
        signer = subprocess.run(['cast','wallet','address','--keystore',KEYSTORE,'--password-file',str(PASSWORD)],
                                cwd='/tmp',env=env,capture_output=True,text=True,timeout=30)
        assert signer.returncode == 0 and signer.stdout.strip().lower() == OWNER.lower(), 'Signer verification failed; output withheld'
        print('Decrypted keystore address independently verified as OWNER',flush=True)
        evidence = {'stage':'B_PREBROADCAST','previewSha256':APPROVED,'verifiedSigner':OWNER,
                    'passwordFileMode':'0600','passwordFileOwnerUid':1000,'runtimeFilesystem':'tmpfs',
                    'block':int(tag,16),'blockHash':block['hash'],'chainId':84532,
                    'replayReceipts':preflight.verify_receipts(ctx,previous),
                    **preflight.reconcile_state(ctx,tag,previous)}
        evidence['eventScan'] = preflight.scan_changes(ctx,before['freshness']['block']+1,int(tag,16))
        evidence.update(ctx['backend_stopped']())
        print('Full seeded-state and isolation gates passed; preparing final single-call boundary',flush=True)
        fresh = rpc('eth_getBlockByNumber',['latest',False]); fresh_tag=fresh['number']
        assert int(fresh_tag,16)-int(tag,16) <= 180, 'Prebroadcast state checks stale'
        critical = [(ctx['NEW'],'owner()',OWNER,[]), (NEW,'migrationState()',0,[]),
                    (NEW,'migrationSnapshotHash()',0,[]), (NEW,'marketRegistry()',ctx['PMR'],[]),
                    (ctx['PME'],'perpEngine()',ctx['OLD'],[]), (ctx['RISK'],'perpEngine()',ctx['OLD'],[]),
                    (ctx['VAULT'],'isAuthorizedEngine(address)',0,[NEW]),
                    (ctx['deps']['feesManagerV2()'],'isFeeConsumer(address)',0,[NEW]),
                    (ctx['deps']['insuranceFund()'],'isBackstopCaller(address)',0,[NEW])]
        for address,sig,want,params in critical: expect(rpc,address,sig,want,params,fresh_tag)
        evidence['freshEventScan'] = preflight.scan_changes(ctx,int(tag,16)+1,int(fresh_tag,16))
        evidence['safeNonce'] = expect(rpc,ctx['SAFE'],'nonce()',before['safeNonce'],tag=fresh_tag)
        evidence['executorNonce'] = int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],fresh_tag]),16)
        assert evidence['executorNonce'] == before['executorNonce']
        assert int(rpc('eth_getTransactionCount',[ctx['EXECUTOR'],'pending']),16) == evidence['executorNonce']
        balance = int(rpc('eth_getBalance',[OWNER,fresh_tag]),16)
        assert balance == before['ownerBalanceWei'], 'Balance drift; reconcile before send'
        l1 = call(rpc,'0x420000000000000000000000000000000000000F','getL1FeeUpperBound(uint256)',[512],fresh_tag)[0]
        budget = preview['gasLimit']*preview['maxFeePerGasWei']+2*l1
        assert balance > budget
        assert int(fresh['baseFeePerGas'],16)+preview['maxPriorityFeePerGasWei'] <= preview['maxFeePerGasWei']
        tx_call = {'from':OWNER,'to':NEW,'value':'0x0','data':preview['calldata'],'gas':hex(preview['gasLimit'])}
        assert rpc('eth_call',[tx_call,fresh_tag]) == '0x'
        estimate = int(rpc('eth_estimateGas',[tx_call,fresh_tag]),16)
        assert estimate <= preview['gasLimit']
        evidence.update(freshBlock=int(fresh_tag,16),freshBlockHash=fresh['hash'],ownerBalanceWei=balance,
                        gasEstimate=estimate,l1FeeUpperBound512BytesWei=l1,maxBudgetWei=budget,simulationPassed=True)
        save('prebroadcast.json',evidence)
        assert int(rpc('eth_chainId',[]),16) == 84532
        assert int(rpc('eth_getTransactionCount',[OWNER,'latest']),16) == 807
        assert int(rpc('eth_getTransactionCount',[OWNER,'pending']),16) == 807
        assert hashlib.sha256((OUT/'transaction_preview.json').read_bytes()).hexdigest() == APPROVED
        with (OUT/'execution_started.json').open('x') as stream:
            json.dump({'previewSha256':APPROVED,'nonce':807,'target':NEW},stream);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        owns_journal=True
        journal.update(status='SUBMITTING',preblock=int(fresh_tag,16),preblockHash=fresh['hash'],
                       ownerNoncePre=807,ownerBalancePreWei=balance,independentlyVerifiedSigner=OWNER,publicSendInvocations=1)
        save('execution_journal.json',journal)
        command = ['cast','send',NEW,preview['calldata'],'--async','-j','1','--from',OWNER,'--value','0',
                   '--nonce','807','--chain','84532','--gas-limit',str(preview['gasLimit']),
                   '--gas-price',str(preview['maxFeePerGasWei']),'--priority-gas-price',str(preview['maxPriorityFeePerGasWei']),
                   '--rpc-url',ctx['url'],'--keystore',KEYSTORE,'--password-file',str(PASSWORD)]
        try:
            result = subprocess.run(command,cwd='/tmp',env=env,capture_output=True,text=True,timeout=90)
        except subprocess.TimeoutExpired:
            raise RuntimeError('Submission timeout; reconcile nonce/journal without resending; command withheld') from None
        output = result.stdout.strip().strip('"')
        if re.fullmatch(r'0x[0-9a-fA-F]{64}',output):
            journal.update(transactionHash=output,status='SUBMITTED');save('execution_journal.json',journal)
        assert result.returncode == 0 and 'transactionHash' in journal, 'Submission ambiguous; no resend; output withheld'
        print('Submitted exactly one seal transaction:',journal['transactionHash'],flush=True)
        deadline=time.monotonic()+240
        stable_hash=None
        while time.monotonic()<deadline:
            receipt=rpc('eth_getTransactionReceipt',[journal['transactionHash']])
            if receipt is None:
                time.sleep(2);continue
            observation={k:receipt.get(k) for k in ['transactionHash','blockNumber','blockHash','status','gasUsed','effectiveGasPrice','l1Fee']}
            if not journal['receiptObservations'] or journal['receiptObservations'][-1]!=observation:
                journal['receiptObservations'].append(observation);save('execution_journal.json',journal)
            assert int(receipt['status'],16)==1, 'Seal reverted; STOP'
            if int(receipt['blockHash'],16)==0:
                time.sleep(2);continue  # Reconcile this hash only; no new submission.
            if stable_hash is not None: assert stable_hash==receipt['blockHash'], 'Canonical hash drift; STOP'
            stable_hash=receipt['blockHash']
            tx=rpc('eth_getTransactionByHash',[journal['transactionHash']])
            canonical=rpc('eth_getBlockByNumber',[receipt['blockNumber'],False])
            validate_receipt(receipt,tx,canonical,journal['transactionHash'],preview,before['expectedEvent'])
            latest=rpc('eth_getBlockByNumber',['latest',False])
            if int(latest['number'],16)<int(receipt['blockNumber'],16)+2:
                time.sleep(2);continue
            expect(rpc,NEW,'migrationState()',1,tag=receipt['blockNumber'])
            expect(rpc,NEW,'migrationSnapshotHash()',SNAPSHOT,tag=receipt['blockNumber'])
            save('canonical_receipt.json',receipt)
            journal.update(status='CANONICAL_SEAL_VERIFIED_POSTFLIGHT_PENDING',receiptBlock=int(receipt['blockNumber'],16),
                           receiptBlockHash=receipt['blockHash'],receiptStatus=1,eventVerified=True,
                           migrationState='SEALED',migrationSnapshotHash=SNAPSHOT)
            save('execution_journal.json',journal)
            print('Canonical receipt, exact MigrationSealed event and SEALED/hash readback PASS',flush=True)
            break
        else:
            raise AssertionError('Canonical receipt timeout; reconcile known hash without resending')
    except BaseException as error:
        if owns_journal:
            journal.update(status='HALTED',errorType=type(error).__name__)
            if ctx is not None:
                try:
                    journal['haltNonces']={tag:int(ctx['live']('eth_getTransactionCount',[OWNER,tag]),16) for tag in ['latest','pending']}
                except Exception: journal['haltNonceReadFailed']=True
            save('execution_journal.json',journal)
        raise
    finally:
        PASSWORD.unlink(missing_ok=True)
        absent=not PASSWORD.exists()
        if owns_journal:
            journal['passwordFileAbsent']=absent;save('execution_journal.json',journal)
        else:
            save('precheck_cleanup.json',{'passwordFileAbsent':absent,'publicSendInvocations':0})
        assert absent, 'Password cleanup failed'
        print('Temporary password file removed; absence verified',flush=True)


if __name__=='__main__':
    main()
