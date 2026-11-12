#!/usr/bin/env python3
"""Build an unsigned, fail-closed Safe/Timelock Options V24 package from live RPC."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/options_v24_governed_configuration/unsigned_package.json'
REGISTRY = '0xcb7bc539ed4A5771F3420f498002e0fc4eE1bD27'
ENGINE = '0x2C4589c88323009db372B4067702e6292ddD294C'
MATCHER = '0x63DE63912BB6743F72ea77847572503Cc93B7d80'
TIMELOCK = '0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588'
SAFE = '0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46'
MULTISEND = '0x9641d764fc13c8B624c04430C7356C1C7C8102e2'
MUSDC = '0x6eAe407f5640B006faC9965182e238582A3B412E'
MWETH = '0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02'
ORACLE = '0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581'
OLD_REGISTRY = '0x3d52b033fab00ed6104dd3bc0a715f8648344eca'
OLD_VAULT = '0x00340c360353a5ab784c5bc5c44322a6af0625d3'
ZERO = '0x'+'0'*40
ETA = 1794830400  # 2026-11-16 12:00 UTC; conditional on operator scheduling in time.
EXPECTED_CODE = {
    REGISTRY: 'c8b39d8ef62b8c20ec256fb93e7c665925062c7c12af3b377b0c46b5575642a5',
    ENGINE: '2238890203633769f341bba2fc116a6cfea2c6f5937a1fec315db066497d6b8a',
    MATCHER: 'e3bd131f88dd547eb896f256b2fbaac1ce6efc817b151ddb96540758920cfa81',
    TIMELOCK: '904b58d49c54e85b95cefb6d1e1e2d1bda7a5eb256215c6bcb7e64fe6bcc78dc',
    SAFE: 'a8a0fbd3cdf49e751346664e01b529a58322a814cf8df8d85deb20e63bd6415e',
    OLD_REGISTRY: 'c8b39d8ef62b8c20ec256fb93e7c665925062c7c12af3b377b0c46b5575642a5',
    OLD_VAULT: 'ad5e47f340d0ce48046ac90a854587cd2d2d4e2c63efc87c0fb2c8dcd57fbe6c',
    MUSDC: '48d431fc1e55659d63cf765706c8650b274b6b1d96ff7521577272615f17c1d4',
    MWETH: 'b8721bb823209123e162b0fbf3ac5ab6779ea36b7adaf030b0632dbfc9e64f3a',
    ORACLE: '5ca1133e7e241be7d5b104d0b15ef34bb7f29c21f757a24b0cc84dd8aed77821',
}

def stop(reason):
    raise SystemExit('STOP: '+reason)

env = {}
for line in (ROOT / '.env.base-sepolia').read_text().splitlines():
    match = re.match(r'^(?:export )?([A-Z][A-Z0-9_]*)=(.*)$', line)
    if match:
        env[match[1]] = match[2].strip().strip('"\'')
RPC_URL = env['RPC_URL']
request_number = 0

def rpc(method, params):
    global request_number
    request_number += 1
    request = urllib.request.Request(RPC_URL,
        json.dumps({'jsonrpc':'2.0','id':request_number,'method':method,'params':params}).encode(),
        headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        result = json.load(response)
    if 'error' in result:
        stop('RPC '+method+' failed')
    return result['result']

def cast(*args):
    return subprocess.check_output(['cast',*map(str,args)],text=True,stderr=subprocess.DEVNULL).strip()

def calldata(signature,*args):
    return cast('calldata',signature,*args)

def read(address,signature,*args):
    raw = rpc('eth_call',[{'to':address,'data':calldata(signature,*args)},BLOCK_TAG])
    return int(raw,16)

def code_hash(address):
    return hashlib.sha256(bytes.fromhex(rpc('eth_getCode',[address,BLOCK_TAG])[2:])).hexdigest()

def assert_eq(actual, expected, what):
    if actual != expected:
        stop(what+' drift')

assert_eq(int(rpc('eth_chainId',[]),16),84532,'chainId')
block = rpc('eth_getBlockByNumber',['latest',False])
BLOCK_TAG = block['number']
block_number = int(BLOCK_TAG,16)
timestamp = int(block['timestamp'],16)
for address,want in EXPECTED_CODE.items():
    assert_eq(code_hash(address),want,'code '+address)
multisend_code = rpc('eth_getCode',[MULTISEND,BLOCK_TAG])
assert_eq(cast('keccak',multisend_code),
          '0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939',
          'MultiSend code')
assert_eq(read(TIMELOCK,'owner()'),int(SAFE,16),'Timelock owner')
assert_eq(read(TIMELOCK,'guardian()'),int(SAFE,16),'Timelock guardian')
assert_eq(read(TIMELOCK,'proposers(address)',SAFE),1,'Safe proposer')
assert_eq(read(TIMELOCK,'executors(address)',SAFE),1,'Safe executor')
assert_eq(read(TIMELOCK,'executors(address)',ZERO),0,'open executor')
assert_eq(read(TIMELOCK,'queuePaused()'),0,'queue pause')
delay = read(TIMELOCK,'minDelay()')
assert_eq(delay,86400,'Timelock delay')
if timestamp + delay + 12*3600 > ETA:
    stop('candidate ETA lacks 12-hour queue margin; regenerate with a newly approved ETA')
assert_eq(read(SAFE,'getThreshold()'),2,'Safe threshold')
safe_nonce = read(SAFE,'nonce()')
assert_eq(safe_nonce,45,'Safe nonce; Perps action may have consumed it')
assert_eq(int(rpc('eth_getStorageAt',[SAFE,'0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8',BLOCK_TAG]),16),0,'Safe guard')
raw_owners = rpc('eth_call',[{'to':SAFE,'data':calldata('getOwners()')},BLOCK_TAG])[2:]
owner_words = [raw_owners[i:i+64] for i in range(0,len(raw_owners),64)]
owners = {'0x'+v[-40:] for v in owner_words[2:2+int(owner_words[1],16)]}
assert_eq({o.lower() for o in owners},{
    '0xb9f8de807ff98d5730035a8bfed4bda33e886d06',
    '0x0e7dcb5b9fd969e4fdc6f3a7b7993819ddc5a35d',
    '0xa774c46c41064524df895bd7be9f294409798dfc'},'Safe owners')
module_data = calldata('getModulesPaginated(address,uint256)','0x0000000000000000000000000000000000000001',10)
raw_modules = rpc('eth_call',[{'to':SAFE,'data':module_data},BLOCK_TAG])[2:]
module_words = [raw_modules[i:i+64] for i in range(0,len(raw_modules),64)]
assert_eq(int(module_words[2],16),0,'Safe modules count')
assert_eq(int(module_words[1],16),1,'Safe modules next')
assert_eq(read(REGISTRY,'owner()'),int(TIMELOCK,16),'Registry owner')
assert_eq(read(REGISTRY,'guardian()'),0,'Registry guardian')
assert_eq(read(REGISTRY,'totalSeries()'),0,'Registry series')
assert_eq(read(REGISTRY,'creationPaused()'),0,'Registry creation pause')
assert_eq(read(REGISTRY,'isSeriesCreator(address)',TIMELOCK),1,'Timelock series creator')
assert_eq(read(REGISTRY,'isSettlementAssetAllowed(address)',MUSDC),0,'mUSDC asset gate')
underlying_raw = rpc('eth_call',[{'to':REGISTRY,'data':calldata('underlyingConfigs(address)',MWETH)},BLOCK_TAG])[2:]
assert_eq(int(underlying_raw[-64:],16),0,'mWETH underlying gate')
assert_eq(read(ENGINE,'owner()'),int(TIMELOCK,16),'Engine owner')
assert_eq(read(ENGINE,'registry()'),int(REGISTRY,16),'Engine Registry pointer')
assert_eq(read(ENGINE,'oracle()'),int(ORACLE,16),'Engine oracle pointer')
assert_eq(read(ENGINE,'liquidationOracleMaxDelay()'),1500,'Engine oracle max delay')
assert_eq(read(ENGINE,'exerciseWindow()'),172800,'Engine exercise window')
assert_eq(read(ENGINE,'paused()'),1,'Engine pause')
for getter in ('optionId()','seriesBound()','matchingEngine()','maxOpenContracts()',
               'maxWalletOpenContracts()','totalOpenContracts()','totalLockedUnderlying()',
               'makerFeePpm()','takerFeePpm()','feeRecipient()','underlying()','quote()'):
    assert_eq(read(ENGINE,getter),0,'Engine '+getter)
assert_eq(read(MATCHER,'owner()'),int(TIMELOCK,16),'Matcher owner')
assert_eq(read(MATCHER,'marginEngine()'),int(ENGINE,16),'Matcher engine pointer')
assert_eq(read(MATCHER,'optionRegistry()'),int(REGISTRY,16),'Matcher Registry pointer')
assert_eq(read(MATCHER,'guardian()'),0,'Matcher guardian')
assert_eq(read(MATCHER,'paused()'),0,'Matcher pause')
assert_eq(read(MATCHER,'configurationFrozen()'),0,'Matcher freeze')
assert_eq(read(MATCHER,'isExecutor(address)',TIMELOCK),1,'Matcher Timelock executor')
assert_eq(read(MATCHER,'isExecutor(address)',SAFE),0,'Matcher Safe executor')
assert_eq(read(MATCHER,'isExecutor(address)',ZERO),0,'Matcher open executor')
assert_eq(read(MWETH,'decimals()'),18,'mWETH decimals')
assert_eq(read(MUSDC,'decimals()'),6,'mUSDC decimals')
assert_eq(read(OLD_REGISTRY,'totalSeries()'),2,'legacy series')
assert_eq(read(MWETH,'balanceOf(address)',OLD_VAULT),0,'legacy mWETH')
assert_eq(read(MUSDC,'balanceOf(address)',OLD_VAULT),224_066_000_000,'legacy mUSDC')
assert_eq(int(rpc('eth_getBalance',[OLD_VAULT,BLOCK_TAG]),16),0,'legacy Vault ETH')

actions = [
    ('MATCHER_PAUSE',MATCHER,calldata('pause()')),
    ('MATCHER_GUARDIAN',MATCHER,calldata('setGuardian(address)',SAFE)),
    ('REGISTRY_GUARDIAN',REGISTRY,calldata('setGuardian(address)',SAFE)),
    ('REGISTRY_GLOBAL_PAUSE',REGISTRY,calldata('pause()')),
]
operations = []
for label,target,inner in actions:
    encoded = cast('abi-encode','f(address,uint256,bytes,uint256)',target,0,inner,ETA)
    op_id = cast('keccak',encoded)
    assert_eq(rpc('eth_call',[{'to':TIMELOCK,
        'data':calldata('hashOperationBytes(address,uint256,bytes,uint256)',target,0,inner,ETA)},BLOCK_TAG]),
        op_id,'Timelock operation ID '+label)
    assert_eq(read(TIMELOCK,'queuedTransactions(bytes32)',op_id),0,'already queued '+label)
    operations.append({'label':label,'target':target,'valueWei':'0','innerCalldata':inner,
                       'eta':ETA,'operationId':op_id,
                       'queueCalldata':calldata('queueTransaction(address,uint256,bytes,uint256)',target,0,inner,ETA),
                       'executeCalldata':calldata('executeTransaction(address,uint256,bytes,uint256)',target,0,inner,ETA)})

def multisend(inner_key):
    packed = b''
    for op in operations:
        data = bytes.fromhex(op[inner_key][2:])
        packed += bytes([0])+bytes.fromhex(TIMELOCK[2:])+bytes(32)+len(data).to_bytes(32,'big')+data
    return calldata('multiSend(bytes)','0x'+packed.hex())

queue_data = multisend('queueCalldata')
execute_data = multisend('executeCalldata')
def safe_action(data,nonce):
    hash_data = calldata('getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
                         MULTISEND,0,data,1,0,0,0,ZERO,ZERO,nonce)
    tx_hash = rpc('eth_call',[{'to':SAFE,'data':hash_data},BLOCK_TAG])
    return {'to':MULTISEND,'valueWei':'0','operation':1,'data':data,'safeNonceIfUnchanged':nonce,
            'safeTxHashIfUnchanged':tx_hash,'safeTxGas':0,'baseGas':0,'gasPrice':0,
            'gasToken':ZERO,'refundReceiver':ZERO,'status':'UNSIGNED_CONDITIONAL'}

package = {'schema':'deopt.options.physical.governed_configuration.v24',
           'status':'UNSIGNED_NO_AUTHORIZATION_NO_BROADCAST',
           'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
           'snapshot':{'chainId':84532,'block':block_number,'blockHash':block['hash'],'timestamp':timestamp,
                       'safeNonce':safe_nonce,'timelockMinDelaySeconds':delay},
           'etaCandidateUtc':'2026-11-16T12:00:00Z',
           'operations':operations,
           'queueSafeAction':safe_action(queue_data,safe_nonce),
           'executeSafeActionConditional':safe_action(execute_data,safe_nonce+1),
           'warning':'Only queue action is candidate for first separate approval. Recompute ETA, nonce, hash and gas immediately before any signature. Fork impersonation does not authorize a Safe transaction.',
           'deferred':['setUnderlyingConfig','setSettlementAssetAllowed','configureFees',
                       'configureExposureCaps','bindSeries','bindMatchingEngine',
                       'setExecutor','freezeConfiguration','createSeries','unpause']}
OUT.parent.mkdir(parents=True,exist_ok=True)
OUT.write_text(json.dumps(package,indent=2)+'\n')
pathlib.Path('/tmp/deopt-options-v24-package.json').write_text(OUT.read_text())
for phase,field,method in [('queue','queueCalldata','queueTransaction'),
                           ('execute','executeCalldata','executeTransaction')]:
    builder = {
        'version':'1.0','chainId':'84532','createdAt':int(time.time()*1000),
        'meta':{'name':'DeOpt Options V24 '+phase+' safety-only',
                'description':'Four Timelock calls; Safe MultiSendCallOnly, zero ETH, no series or trading activation. Unsigned conditional package.',
                'txBuilderVersion':'1.18.0','createdFromSafeAddress':SAFE,'createdFromOwnerAddress':''},
        'transactions':[]}
    for op in operations:
        builder['transactions'].append({
            'to':TIMELOCK,'value':'0','data':op[field],
            'contractMethod':{'name':method,'payable':phase=='execute','inputs':[
                {'name':'target','type':'address','internalType':'address'},
                {'name':'value','type':'uint256','internalType':'uint256'},
                {'name':'data','type':'bytes','internalType':'bytes'},
                {'name':'eta','type':'uint256','internalType':'uint256'}]},
            'contractInputsValues':{'target':op['target'],'value':'0',
                                    'data':op['innerCalldata'],'eta':str(ETA)}})
    (OUT.parent / (phase+'_safe_builder_unsigned.json')).write_text(json.dumps(builder,indent=2)+'\n')
print('PACKAGE',OUT,'BLOCK',block_number,'SAFE_NONCE',safe_nonce,'ETA',ETA)
for op in operations:
    print('OPERATION',op['label'],op['operationId'])
print('QUEUE_SAFE_TX_HASH_CONDITIONAL',package['queueSafeAction']['safeTxHashIfUnchanged'])
print('EXECUTE_SAFE_TX_HASH_CONDITIONAL',package['executeSafeActionConditional']['safeTxHashIfUnchanged'])
print('READONLY_PACKAGE_PASS')
