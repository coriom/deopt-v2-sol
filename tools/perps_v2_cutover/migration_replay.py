#!/usr/bin/env python3
"""M3 artifact verification and recovery package preparation. No RPC or signing.

Requires cbor2 for decoding EXISTING bytes only. Never re-encodes canonical CBOR.
All file digests named sha256 use SHA-256; snapshotHash uses Ethereum Keccak-256.
"""
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess

from snapshot_hash import canonical, keccak256

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'artifacts/perps_v2_final_snapshot'
DESTINATION = ROOT / 'artifacts/perps_v2_migration_replay'
NEW = '0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15'
OLD = '0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9'
OWNER = '0xc35F7A8A103A9A4464adfaa76B9B514093D23C27'
SNAPSHOT = '0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d'
FUNDING = 'adminSeedMarketFunding(uint256,int256,uint64)'
POSITION = 'adminSeedPosition(address,uint256,int256,int256,int256)'


def require(value, message):
    if not value:
        raise ValueError(message)


def sha256(blob):
    return hashlib.sha256(blob).hexdigest()


def cast(*args):
    return subprocess.check_output(['cast', *args], text=True).strip()


def verify_canonical():
    import cbor2
    manifest = json.loads((SOURCE / 'manifest.json').read_text())
    expected = canonical(manifest)
    require(set(manifest) == set(expected), 'Unknown manifest field; review destination/scope binding')
    require(manifest['schemaVersion'] == 1 and manifest['chainId'] == 84532, 'Wrong snapshot schema/chain')
    blob = (SOURCE / 'manifest.cbor').read_bytes()
    stream = io.BytesIO(blob)
    decoded = cbor2.CBORDecoder(stream).decode()
    require(not stream.read(), 'Trailing CBOR bytes')
    require(decoded == expected, 'Existing CBOR and canonical JSON disagree')
    require('0x' + keccak256(blob).hex() == SNAPSHOT, 'Snapshot Ethereum Keccak mismatch')
    require(manifest['snapshotBlockNumber'] == 47354411, 'Wrong source block')
    require(manifest['snapshotBlockHash'] == '0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89', 'Wrong source block hash')
    require(not manifest['residualBadDebt'], 'Unexpected residual debt')
    hashes = {name: sha256((SOURCE / name).read_bytes()) for name in ['manifest.json', 'manifest.cbor', 'seed_calldata.json']}
    # Canonical source bytes must also match the authoritative repository checkpoint.
    for name, digest in hashes.items():
        committed = subprocess.check_output(['git', 'show', 'def2631191c0029e8d45b6e93a976bf2570dedef:artifacts/perps_v2_final_snapshot/' + name], cwd=ROOT)
        require(sha256(committed) == digest, 'Canonical artifact differs from committed checkpoint: ' + name)
    return manifest, hashes


def validate_steps(original, recovery, manifest, artifact):
    require(original['engineV2'].lower() == OLD.lower(), 'Historical package target drift')
    for key in ['snapshotBlockNumber', 'snapshotBlockHash']:
        require(original[key] == recovery[key] == manifest[key], 'Source block binding mismatch')
    require(recovery['chainId'] == 84532 and recovery['snapshotHash'] == SNAPSHOT, 'Package binding mismatch')
    require(recovery['engineV2'].lower() == NEW.lower(), 'Recovery engine mismatch')
    require(recovery['owner'].lower() == OWNER.lower(), 'Recovery OWNER mismatch')
    require(recovery['startingNonce'] == 799, 'Starting nonce requires separate drift review')
    require(recovery['originalPackageSha256'] == sha256((SOURCE / 'seed_calldata.json').read_bytes()),
            'Historical package file hash mismatch')
    require(recovery['seedIteratorSummary'] == original['seedIteratorSummary'], 'Seed summary changed')
    steps = recovery['orderedSteps']
    require(len(steps) == len(original['orderedSteps']) == 8, 'Exactly eight seed entries required')
    functions = {a['name']: a for a in artifact['abi'] if a['type'] == 'function'}
    records = []
    for i, (old, new) in enumerate(zip(original['orderedSteps'], steps), 1):
        require(old['ordinal'] == new['ordinal'] == i, 'Ordinal mismatch')
        require(old['target'].lower() == OLD.lower() and new['target'].lower() == NEW.lower(), 'Forbidden target')
        require(type(new['value']) is int and new['value'] == 0, 'Nonzero or noninteger ETH value')
        normalized = copy.deepcopy(new)
        normalized['target'] = old['target']
        normalized.pop('value')
        require(normalized == old, 'Historical seed fields changed beyond target/value')
        signature = FUNDING if i <= 2 else POSITION
        require(new['signature'] == signature, 'Forbidden seed function or order')
        function = functions[signature.split('(')[0]]
        abi_signature = function['name'] + '(' + ','.join(x['type'] for x in function['inputs']) + ')'
        require(signature == abi_signature, 'Frozen ABI mismatch')
        selector = '0x' + artifact['methodIdentifiers'][signature]
        require(new['selector'] == new['calldata'][:10] == selector, 'Selector mismatch')
        args = new['args']
        require(set(args) == {x['name'] for x in function['inputs']}, 'Argument keys mismatch')
        decoded = json.loads(cast('decode-calldata', '--json', signature, new['calldata']))
        require(len(decoded) == len(function['inputs']), 'Decoded argument count mismatch')
        values = []
        for param, value in zip(function['inputs'], decoded):
            expected_value = args[param['name']]
            if param['type'] == 'address':
                require(value.lower() == expected_value.lower(), 'Decoded address mismatch')
            else:
                require(type(expected_value) is int and int(value) == expected_value, 'Decoded integer mismatch')
            values.append(str(expected_value))
        require(cast('calldata', signature, *values).lower() == new['calldata'].lower(), 'Trailing/noncanonical calldata')
        if i <= 2:
            entity = manifest['markets'][i - 1]
            require(args == {k: entity[k] for k in args}, 'Funding values differ from manifest')
        else:
            entity = manifest['positions'][i - 3]
            require(args == entity, 'Position values differ from manifest')
        records.append({'ordinal': i, 'nonce': 798 + i, 'target': NEW, 'value': 0,
                        'signature': signature, 'selector': selector, 'decodedArgs': args,
                        'calldataIdentical': new['calldata'] == old['calldata']})
    return records


def build():
    manifest, hashes = verify_canonical()
    original = json.loads((SOURCE / 'seed_calldata.json').read_text())
    package = copy.deepcopy(original)
    package.update(engineV2=NEW, chainId=84532, snapshotHash=SNAPSHOT, owner=OWNER,
                   startingNonce=799, originalPackageSha256=hashes['seed_calldata.json'])
    for step in package['orderedSteps']:
        step['target'] = NEW
        step['value'] = 0
    artifact = json.loads((ROOT / 'out/PerpEngineV2.sol/PerpEngineV2.json').read_text())
    records = validate_steps(original, package, manifest, artifact)
    encoded = (json.dumps(package, indent=2) + '\n').encode()
    DESTINATION.mkdir(exist_ok=True)
    path = DESTINATION / 'execution_package.json'
    if path.exists():
        require(path.read_bytes() == encoded, 'Existing recovery package differs; refusing overwrite')
    else:
        path.write_bytes(encoded)
    evidence = {'snapshotHash': SNAPSHOT, 'jsonCborSemanticAgreement': True,
                'canonicalFileSha256': hashes, 'recoveryPackageSha256': sha256(encoded),
                'scope': 'Source-bound manifest; no exclusive destination. Recovery freeze section L permits replacement Engine replay.',
                'changes': 'Top-level execution bindings added; each target changed OLD to NEW, value explicitly zero. All other step fields preserved.',
                'transactions': records}
    (DESTINATION / 'artifact_verification.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    build()
