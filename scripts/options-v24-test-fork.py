#!/usr/bin/env python3
"""One-command read-only package build and targeted Safe fork simulation."""
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
values = {}
for line in (root / '.env.base-sepolia').read_text().splitlines():
    match = re.match(r'^(?:export )?([A-Z][A-Z0-9_]*)=(.*)$', line)
    if match:
        values[match[1]] = match[2].strip().strip('"\'')
rpc_url = values['RPC_URL']
package = subprocess.run([sys.executable, str(root / 'scripts/options-v24-build-governed-package.py')],
                         cwd=root, capture_output=True, text=True)
print((package.stdout + package.stderr).replace(rpc_url, '[RPC_URL]'), end='')
if package.returncode:
    raise SystemExit(package.returncode)
env = os.environ.copy()
env['OPTIONS_V24_FORK_RPC'] = rpc_url
test = subprocess.run(['forge','test','--match-path','test/options/OptionsV24GovernedConfigFork.t.sol',
                       '-vv','--jobs','1'],cwd=root,env=env,capture_output=True,text=True)
print((test.stdout + test.stderr).replace(rpc_url,'[RPC_URL]'), end='')
raise SystemExit(test.returncode)
