import http.server
import json
import pathlib
import re
import subprocess
import threading
import time
import urllib.request

ROOT = pathlib.Path('/home/corio/DEOPT/deopt-v2-sol')
env_file = {}
for line in (ROOT / '.env.base-sepolia').read_text().splitlines():
    m = re.match(r'^(?:export )?([A-Z][A-Z0-9_]*)=(.*)$', line)
    if m:
        env_file[m.group(1)] = m.group(2).strip().strip('"\'')
remote = env_file['RPC_URL']
deployer = env_file['DEPLOYER_ADDRESS']
proxy_port, anvil_port = 18666, 18665
local = f'http://127.0.0.1:{anvil_port}'

class Forward(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        req = urllib.request.Request(remote, body, headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=35) as response:
                content = response.read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except BrokenPipeError:
            return
        except Exception as exc:
            content = json.dumps({'jsonrpc': '2.0', 'id': None, 'error': {'code': -32000, 'message': type(exc).__name__}}).encode()
            self.send_response(502)
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)

server = http.server.ThreadingHTTPServer(('127.0.0.1', proxy_port), Forward)
threading.Thread(target=server.serve_forever, daemon=True).start()
anvil_log = open('/tmp/deopt-v23-anvil.log', 'w')
anvil = subprocess.Popen(['anvil', '--silent', '--auto-impersonate', '--fork-url', f'http://127.0.0.1:{proxy_port}',
                          '--fork-block-number', '57438610', '--chain-id', '84532', '--port', str(anvil_port)],
                         stdout=anvil_log, stderr=subprocess.STDOUT)
counter = 0
def rpc(method, params):
    global counter
    counter += 1
    req = urllib.request.Request(local, json.dumps({'jsonrpc':'2.0','id':counter,'method':method,'params':params}).encode(),
                                 headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=40) as response:
        result = json.load(response)
    if 'error' in result:
        raise RuntimeError(result['error'].get('message', 'RPC_ERROR'))
    return result['result']

def predict(nonce):
    result = subprocess.run(['cast', 'compute-address', '--nonce', str(nonce), deployer], capture_output=True,
                            text=True, check=True).stdout
    return re.search(r'0x[0-9a-fA-F]{40}', result).group()

def run(name, extra, expected_nonce=None, expect_fail=False):
    import os
    e = os.environ.copy()
    signed_fork = os.environ.get('DEOPT_V23_SIGNED_FORK') == '1'
    if expected_nonce is None:
        expected_nonce = int(rpc('eth_getTransactionCount', [deployer, 'latest']), 16)
    e.update({'OPTIONS_V21_DEPLOY_ALLOWED': 'true', 'OPTIONS_V23_LOCAL_ANVIL': 'false' if signed_fork else 'true',
              'OPTIONS_V23_PUBLIC_BROADCAST_ALLOWED': 'true' if signed_fork else 'false',
              'OPTIONS_V21_OPTION_ID': '0',
              'OPTIONS_V23_DEPLOYER': deployer, 'OPTIONS_V23_EXPECTED_NONCE': str(expected_nonce),
              'OPTIONS_V21_ORACLE': '0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581', **extra})
    if signed_fork:
        e['DEPLOYER_PRIVATE_KEY'] = env_file['DEPLOYER_PRIVATE_KEY']
    cmd = ['forge', 'script', f'script/DeployOptionsPhysicalV21.s.sol:{name}', '--rpc-url', local,
           '--broadcast', '--sender', deployer, '--slow', '--silent']
    if not signed_fork:
        cmd.append('--unlocked')
    result = subprocess.run(cmd, cwd=ROOT, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=240)
    if expect_fail:
        if result.returncode == 0 or 'deployer nonce drift' not in result.stdout:
            print('EXPECTED_FAILURE_NOT_OBSERVED', result.returncode,
                  '[redacted in signed mode]' if signed_fork else result.stdout[-900:])
            raise SystemExit(2)
        print(name, 'NONCE_REPLAY_REJECTED')
        return
    if result.returncode:
        print(name, 'FAILED', result.returncode,
              '[redacted in signed mode]' if signed_fork else result.stdout[-1200:])
        raise SystemExit(2)
    print(name, 'PASS')

try:
    for _ in range(100):
        if anvil.poll() is not None:
            raise RuntimeError('Anvil terminated')
        try:
            if int(rpc('eth_chainId', []), 16) == 84532:
                break
        except Exception:
            time.sleep(1)
    else:
        raise RuntimeError('Anvil did not start')
    print('LOCAL_FORK_CHAIN_ID', int(rpc('eth_chainId', []), 16))
    print('LOCAL_FORK_BLOCK', int(rpc('eth_blockNumber', []), 16))
    print('ANVIL_NODE', bool(rpc('anvil_nodeInfo', [])))
    nonce = int(rpc('eth_getTransactionCount', [deployer, 'latest']), 16)
    print('DEPLOYER_START_NONCE', nonce)
    predicted = [predict(nonce + i) for i in range(3)]
    print('PREDICTED_REGISTRY_ENGINE_MATCHER', *predicted)
    legacy = '0x00340c360353a5ab784c5bc5c44322a6af0625d3'
    before_code = rpc('eth_getCode', [legacy, 'latest'])
    before_balance = rpc('eth_getBalance', [legacy, 'latest'])
    legacy_registry = '0x3d52b033fab00ed6104dd3bc0a715f8648344eca'
    before_series = rpc('eth_call', [{'to':legacy_registry,'data':'0x0c6a595a'},'latest'])
    def token_balance(token, account):
        return rpc('eth_call',[{'to':token,'data':'0x70a08231'+account[2:].lower().rjust(64,'0')},'latest'])
    weth = '0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02'
    usdc = '0x6eAe407f5640B006faC9965182e238582A3B412E'
    legacy_weth = token_balance(weth, legacy)
    legacy_usdc = token_balance(usdc, legacy)
    rpc('anvil_setBalance', [deployer, '0x8ac7230489e80000'])
    print('SIMULATION_FUNDED_DEPLOYER_ONLY', True)
    run('DeployOptionsPhysicalRegistryV21', {})
    registry = predicted[0]
    print('INTERRUPTION_AFTER_REGISTRY_NONCE', int(rpc('eth_getTransactionCount', [deployer, 'latest']),16))
    print('INTERRUPTION_REGISTRY_CODE_PRESENT', rpc('eth_getCode', [registry, 'latest']) != '0x')
    print('INTERRUPTION_ENGINE_CODE_ABSENT', rpc('eth_getCode', [predicted[1], 'latest']) == '0x')
    run('DeployOptionsPhysicalRegistryV21', {}, expected_nonce=nonce, expect_fail=True)
    run('DeployOptionsPhysicalEngineV21', {'OPTIONS_V21_REGISTRY': registry})
    print('INTERRUPTION_AFTER_ENGINE_NONCE', int(rpc('eth_getTransactionCount', [deployer, 'latest']),16))
    print('INTERRUPTION_ENGINE_CODE_PRESENT', rpc('eth_getCode', [predicted[1], 'latest']) != '0x')
    print('INTERRUPTION_MATCHER_CODE_ABSENT', rpc('eth_getCode', [predicted[2], 'latest']) == '0x')
    run('DeployOptionsPhysicalEngineV21', {'OPTIONS_V21_REGISTRY': registry}, expected_nonce=nonce+1, expect_fail=True)
    run('DeployOptionsPhysicalMatcherV23', {'OPTIONS_V21_REGISTRY':registry,'OPTIONS_V23_ENGINE':predicted[1]})
    for label, address in zip(('REGISTRY','ENGINE','MATCHER'), predicted):
        code = rpc('eth_getCode', [address, 'latest'])
        import hashlib
        print(label, 'ADDRESS', address, 'CODE_BYTES', (len(code)-2)//2,
              'RUNTIME_SHA256', hashlib.sha256(bytes.fromhex(code[2:])).hexdigest())
    latest = int(rpc('eth_blockNumber', []), 16)
    for height in range(57438611, latest + 1):
        b = rpc('eth_getBlockByNumber', [hex(height), False])
        for tx in b['transactions']:
            receipt = rpc('eth_getTransactionReceipt', [tx])
            if receipt['from'].lower() == deployer.lower():
                print('RECEIPT', tx, 'STATUS', int(receipt['status'], 16), 'NONCE_BLOCK', height,
                      'GAS', int(receipt['gasUsed'], 16), 'CONTRACT', receipt['contractAddress'])
    print('FINAL_NONCE', int(rpc('eth_getTransactionCount', [deployer, 'latest']),16))
    print('LEGACY_CODE_UNCHANGED', before_code == rpc('eth_getCode', [legacy, 'latest']))
    print('LEGACY_ETH_BALANCE_UNCHANGED', before_balance == rpc('eth_getBalance', [legacy, 'latest']))
    print('LEGACY_SERIES_COUNT_UNCHANGED', before_series == rpc('eth_call', [{'to':legacy_registry,'data':'0x0c6a595a'},'latest']))
    print('LEGACY_MWETH_BALANCE_UNCHANGED',legacy_weth == token_balance(weth,legacy))
    print('LEGACY_MUSDC_BALANCE_UNCHANGED',legacy_usdc == token_balance(usdc,legacy))
    for name, address, selector in [('REGISTRY_OWNER', registry, '0x8da5cb5b'),
                                     ('REGISTRY_SERIES_COUNT', registry, '0x0c6a595a'),
                                     ('ENGINE_PAUSED', predicted[1], '0x5c975abb')]:
        try:
            print(name, rpc('eth_call', [{'to': address, 'data': selector}, 'latest']))
        except Exception:
            print(name, 'CALL_FAILED')
finally:
    anvil.terminate()
    try:
        anvil.wait(timeout=10)
    except subprocess.TimeoutExpired:
        anvil.kill()
    anvil_log.close()
    server.shutdown()
