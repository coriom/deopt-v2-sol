import datetime
import hashlib
import json
import pathlib
import re
import sys
import urllib.request

step = int(sys.argv[1]) if len(sys.argv) == 2 else 1
if step not in (1, 2, 3):
    raise SystemExit('Usage: options-v23-readonly-preflight.py [1|2|3]')

def safe_excepthook(error_type, _value, _traceback):
    print('PREFLIGHT_VERDICT STOP', error_type.__name__)
sys.excepthook = safe_excepthook

env = {}
for line in pathlib.Path('/home/corio/DEOPT/deopt-v2-sol/.env.base-sepolia').read_text().splitlines():
    match = re.match(r'^(?:export )?([A-Z][A-Z0-9_]*)=(.*)$', line)
    if match:
        env[match.group(1)] = match.group(2).strip().strip('"\'')
url = env['RPC_URL']
deployer = env['DEPLOYER_ADDRESS']
next_id = 0

def rpc(method, params):
    global next_id
    next_id += 1
    payload = json.dumps({'jsonrpc': '2.0', 'id': next_id, 'method': method, 'params': params}).encode()
    request = urllib.request.Request(url, payload, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=20) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError(result['error'].get('message', 'RPC_ERROR'))
    return result['result']

block = rpc('eth_getBlockByNumber', ['latest', False])
height = block['number']
chain_id = int(rpc('eth_chainId', []), 16)
print('CHAIN_ID', chain_id, 'BLOCK', int(height, 16), 'BLOCK_HASH', block['hash'])
print('BLOCK_TIME_UTC', datetime.datetime.fromtimestamp(int(block['timestamp'], 16), datetime.timezone.utc).isoformat())
print('BLOCK_GAS_LIMIT', int(block['gasLimit'], 16), 'BASE_FEE_WEI', int(block.get('baseFeePerGas') or '0x0', 16))
print('GAS_PRICE_WEI', int(rpc('eth_gasPrice', []), 16))
nonce_latest = int(rpc('eth_getTransactionCount', [deployer, 'latest']), 16)
nonce_pending = int(rpc('eth_getTransactionCount', [deployer, 'pending']), 16)
balance_wei = int(rpc('eth_getBalance', [deployer, height]), 16)
print('DEPLOYER', deployer, 'NONCE_LATEST', nonce_latest, 'NONCE_PENDING', nonce_pending,
      'BALANCE_WEI', balance_wei)
addresses = {
    'TIMELOCK': '0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588',
    'SAFE': '0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46',
    'MWETH': '0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02',
    'MUSDC': '0x6eAe407f5640B006faC9965182e238582A3B412E',
    'ORACLE': '0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581',
    'LEGACY_REGISTRY': '0x3d52b033fab00ed6104dd3bc0a715f8648344eca',
    'LEGACY_VAULT': '0x00340c360353a5ab784c5bc5c44322a6af0625d3',
}
codes = {}
for label, address in addresses.items():
    code = bytes.fromhex(rpc('eth_getCode', [address, height])[2:])
    codes[label] = code
    print(label, 'ADDRESS', address, 'CODE_BYTES', len(code), 'SHA256', hashlib.sha256(code).hexdigest())
for label in ('MWETH', 'MUSDC'):
    print(label, 'DECIMALS', int(rpc('eth_call', [{'to': addresses[label], 'data': '0x313ce567'}, height]), 16))
safe_values = {}
for label, method in [('SAFE_NONCE', '0xaffed0e0'), ('SAFE_THRESHOLD', '0xe75235b8')]:
    try:
        safe_values[label] = rpc('eth_call', [{'to': addresses['SAFE'], 'data': method}, height])
        print(label, safe_values[label])
    except Exception:
        print(label, 'CALL_FAILED')
guard_slot = '0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8'
guard = rpc('eth_getStorageAt', [addresses['SAFE'], guard_slot, height])
print('SAFE_GUARD_SLOT', guard)
safe_singleton = rpc('eth_getStorageAt', [addresses['SAFE'], '0x0', height])
print('SAFE_SINGLETON_SLOT', safe_singleton)
module_data = '0xcc2f8452' + format(1,'064x') + format(10,'064x')
module_raw = rpc('eth_call',[{'to':addresses['SAFE'],'data':module_data},height])[2:]
module_words = [module_raw[i:i+64] for i in range(0,len(module_raw),64)]
module_count = int(module_words[2],16)
module_next = '0x'+module_words[1][-40:]
print('SAFE_MODULE_COUNT',module_count,'SAFE_MODULE_NEXT',module_next)
def selector(signature):
    import subprocess
    return subprocess.run(['cast','sig',signature],capture_output=True,text=True,check=True).stdout.strip()
timelock_values = {}
for label, address, signature in [
    ('TIMELOCK_OWNER',addresses['TIMELOCK'],'owner()'),
    ('TIMELOCK_GUARDIAN',addresses['TIMELOCK'],'guardian()'),
    ('TIMELOCK_MIN_DELAY',addresses['TIMELOCK'],'minDelay()'),
    ('TIMELOCK_SAFE_PROPOSER',addresses['TIMELOCK'],'proposers(address)'),
    ('TIMELOCK_SAFE_EXECUTOR',addresses['TIMELOCK'],'executors(address)'),
    ('LEGACY_REGISTRY_OWNER',addresses['LEGACY_REGISTRY'],'owner()')]:
    data = selector(signature)
    if signature.endswith('(address)'):
        data += addresses['SAFE'][2:].lower().rjust(64,'0')
    try:
        timelock_values[label] = rpc('eth_call',[{'to':address,'data':data},height])
        print(label, timelock_values[label])
    except Exception:
        print(label,'CALL_FAILED')
try:
    raw = rpc('eth_call',[{'to':addresses['SAFE'],'data':selector('getOwners()')},height])[2:]
    words = [raw[i:i+64] for i in range(0,len(raw),64)]
    count = int(words[1],16)
    owners = ['0x'+x[-40:] for x in words[2:2+count]]
    print('SAFE_OWNER_COUNT',count,'SAFE_OWNERS',*owners)
except Exception:
    print('SAFE_OWNERS_CALL_FAILED')

package_path = pathlib.Path('/home/corio/DEOPT/deopt-v2-sol/artifacts/options_v23_inactive_deployment/unsigned_transactions.json')
package = json.loads(package_path.read_text())
root = pathlib.Path('/home/corio/DEOPT/deopt-v2-sol')
baseline = package['legacyBaseline']
vault = addresses['LEGACY_VAULT']
vault_word = vault[2:].lower().rjust(64, '0')
legacy_series = int(rpc('eth_call', [{'to':addresses['LEGACY_REGISTRY'], 'data':'0x0c6a595a'}, height]),16)
vault_weth = int(rpc('eth_call', [{'to':addresses['MWETH'], 'data':'0x70a08231'+vault_word},height]),16)
vault_usdc = int(rpc('eth_call', [{'to':addresses['MUSDC'], 'data':'0x70a08231'+vault_word},height]),16)
vault_eth = int(rpc('eth_getBalance',[vault,height]),16)
remaining_l2 = sum(t['gasLimit']*int(t['maxFeePerGasWei']) for t in package['transactions'][step-1:])
checks = {
    'chain': chain_id == 84532,
    'nonce': nonce_latest == nonce_pending == package['transactions'][step-1]['nonce'],
    'deployer': deployer.lower() == package['transactions'][0]['from'].lower(),
    'balance': balance_wei >= remaining_l2 + package['l1AndOperatorFeeReserveWei'],
    'guard': int(guard, 16) == 0,
    'safe_singleton': int(safe_singleton,16) != 0,
    'safe_modules': module_count == 0 and int(module_next,16) == 1,
    'safe_nonce': int(safe_values['SAFE_NONCE'], 16) == 45,
    'safe_threshold': int(safe_values['SAFE_THRESHOLD'], 16) == 2,
    'safe_owners': set(x.lower() for x in owners) == {
        '0xb9f8de807ff98d5730035a8bfed4bda33e886d06',
        '0x0e7dcb5b9fd969e4fdc6f3a7b7993819ddc5a35d',
        '0xa774c46c41064524df895bd7be9f294409798dfc',
    },
    'timelock_owner': int(timelock_values['TIMELOCK_OWNER'],16) == int(addresses['SAFE'],16),
    'timelock_delay': int(timelock_values['TIMELOCK_MIN_DELAY'],16) == 86400,
    'timelock_proposer': int(timelock_values['TIMELOCK_SAFE_PROPOSER'],16) == 1,
    'timelock_executor': int(timelock_values['TIMELOCK_SAFE_EXECUTOR'],16) == 1,
    'dependencies_code': all(hashlib.sha256(codes[x]).hexdigest() == digest
                             for x,digest in package['dependencyCodeSha256'].items()),
    'legacy_series': legacy_series == baseline['registryTotalSeries'],
    'legacy_weth': vault_weth == baseline['vaultMWEthBaseUnits'],
    'legacy_usdc': vault_usdc == baseline['vaultMUSDCBaseUnits'],
    'legacy_eth': vault_eth == baseline['vaultEthWei'],
    'source_files': all(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                        for name,digest in package['sourceFileSha256'].items()),
}
import subprocess
for index,tx in enumerate(package['transactions']):
    predicted = subprocess.run(['cast','compute-address','--nonce',str(tx['nonce']),deployer],
                               capture_output=True,text=True,check=True).stdout
    match = re.search(r'0x[0-9a-fA-F]{40}',predicted)
    checks['address_'+tx['contract']] = bool(match) and match.group().lower() == tx['predictedAddress'].lower()
    actual_code = rpc('eth_getCode',[tx['predictedAddress'],height])
    if index < step - 1:
        checks['deployed_'+tx['contract']] = hashlib.sha256(bytes.fromhex(actual_code[2:])).hexdigest() == tx['expectedRuntimeSha256']
    else:
        checks['empty_'+tx['contract']] = actual_code == '0x'
if step >= 2:
    registry = package['transactions'][0]['predictedAddress']
    checks['new_registry_owner'] = int(rpc('eth_call',[{'to':registry,'data':selector('owner()')},height]),16) == int(addresses['TIMELOCK'],16)
    checks['new_registry_empty'] = int(rpc('eth_call',[{'to':registry,'data':'0x0c6a595a'},height]),16) == 0
if step >= 3:
    engine = package['transactions'][1]['predictedAddress']
    expected_zero = ('matchingEngine()','maxOpenContracts()','totalOpenContracts()','totalLockedUnderlying()','seriesBound()')
    checks['engine_paused'] = int(rpc('eth_call',[{'to':engine,'data':selector('paused()')},height]),16) == 1
    checks['engine_unbound_empty'] = all(int(rpc('eth_call',[{'to':engine,'data':selector(sig)},height]),16) == 0 for sig in expected_zero)
    checks['engine_owner'] = int(rpc('eth_call',[{'to':engine,'data':selector('owner()')},height]),16) == int(addresses['TIMELOCK'],16)
for name,ok in checks.items():
    print('CHECK',name,'PASS' if ok else 'STOP')
print('PREFLIGHT_VERDICT', 'PASS' if all(checks.values()) else 'STOP')
if not all(checks.values()):
    sys.exit(2)
