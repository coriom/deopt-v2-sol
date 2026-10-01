#!/usr/bin/env python3
"""Read-only durable evidence of the completed maintenance-error probes."""

import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
import maintenance_lock_execute as prior
import migration_reseal_preflight as reseal

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/perps_v2_recovery_maintenance_lock_finish'
EXPECTED = 'cd4509be30e9fc9baf39a7606a523018ea667f6c93a685a46d870334adc29adb'


def main():
    assert hashlib.sha256((OUT/'execution_package.json').read_bytes()).hexdigest() == EXPECTED
    post = json.loads((OUT/'postflight.json').read_text())
    assert post['status'] == 'PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_COMPLETE'
    ctx = reseal.prepare_context()
    rpc = ctx['live']
    assert int(rpc('eth_chainId', []),16) == 84532
    block = rpc('eth_getBlockByNumber',['latest',False])
    tag = block['number']
    assert int(block['hash'],16) != 0
    assert int(rpc('eth_getTransactionCount',[prior.OWNER,'latest']),16) == 812
    assert int(rpc('eth_getTransactionCount',[prior.OWNER,'pending']),16) == 812
    assert prior.control_state(ctx,rpc,tag) == {'PME':[1],'NEW':[1,1,1,1],
                                                'OLD':[1,1,1,1],'V1':[1,1,1,1]}
    assert ctx['call'](rpc,ctx['PME1'],'paused()',tag=tag)[0] == 1
    assert ctx['backend_stopped']()['backend_runtime_state'] == 'STOPPED'
    probes = prior.maintenance_probes(ctx)
    assert len(probes) == 15 and all(x['method'] == 'eth_call' and not x['publicWrite'] for x in probes)
    output = {'chainId':84532,'comparisonBlock':int(tag,16),'comparisonBlockHash':block['hash'],
              'ownerNonce':812,'controlsAllPaused':True,'backendRuntimeState':'STOPPED',
              'exactPauseErrorsVerified':15,'publicWrites':0,'probes':probes}
    (OUT/'postflight_negative_probes.json').write_text(json.dumps(output,indent=2)+'\n')
    print('15/15 exact eth_call-only maintenance errors at block',int(tag,16),flush=True)


if __name__ == '__main__':
    main()
