# PERPS_V2_CODEX_HANDOFF_RECONCILIATION_V1

Status: **PERPS_V2_CODEX_HANDOFF_RECONCILIATION_V1_COMPLETE — CODEX_HANDOFF_READY**.
No public-chain execution authorized or performed.

Scope: local script, helper, tests and documentation reconciliation, followed by a
normal commit/push. Base Sepolia reads and unsigned Forge simulation only. No
deployment, broadcast, migration, rebind, Vault/Safe/Timelock write, backend start,
service restart, or trade. Production `src/perp` and canonical snapshot artifacts
are unchanged.

Starting Solidity HEAD: `c6f3cb2f259b99ddf6c450b92f52eede7634550d`.
Backend HEAD: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`, unchanged.

## Runtime identity correction

| Runtime | Bytes | Ethereum Keccak-256 |
|---|---:|---|
| PerpEngineV2 | 24,321 | `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a` |
| NEW PerpMarketRegistry | 13,217 | `0x70a03433c8f58ac8e97e6caa5c0e488db1440c05aa1dce46b0fef4930e8194f5` |

Historical Engine value
`0xef5486354584feba953f4eed0d5573b65e9e2bfb6dca0e43a4eedfe7ba46652e`
and PMR value
`0x5d66f23543a0e9ded3da5e85c8f0413af3cbe00794e99e1aa3c9b1b40c63fd8c`
are **NIST SHA3-256**. Earlier documents incorrectly called them Keccak. Their
labels are corrected without changing historical transaction/receipt facts.

The frozen linked Engine bytes must equal live OLD Engine
`0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` byte-for-byte. PMR bytes must equal live
NEW PMR `0xAD8B0855d1fd649539A344AD594bf86929cf0FF7` byte-for-byte.
Engine EIP-170 headroom remains 255 bytes.

`tools/perps_v2_cutover/recovery_preflight.py` verifies these identities and the
unsigned transaction boundary. It reads only allowlisted JSON-RPC methods,
requires chain 84532 before contract reads, and never prints the RPC endpoint.
`snapshot_hash.py` now uses only Ethereum Keccak providers (pysha3, pycryptodome,
or `cast keccak`), and fails closed if none is available. The old NIST fallback
has been removed. Tests hash the existing CBOR without regenerating it.

## Snapshot integrity

- Snapshot block: `47,354,411`.
- Block hash: `0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89`.
- Canonical Ethereum snapshotHash:
  `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.
- `manifest.json`, `manifest.cbor`, and `seed_calldata.json` remain unchanged.
- Existing seed targets refer to OLD Engine; future M3 must deliberately retarget
  the same eight calldata payloads to NEW Engine, without a new snapshot/CBOR.

## Backend intentionally stopped

Operator decision: the backend is intentionally stopped. This is not a blocker.

```text
backend_runtime_state = STOPPED
transaction_emission_capability = NONE
```

The capability statement refers to this stopped local backend, not to the OWNER
EOA or independently operated machines. Read-only checks found no DeOpt backend
process, no port 8080 listener, no tmux session, no screen installation/session,
no relevant Docker backend instance, no system/user service or enabled unit,
and no obvious backend autostart in user cron, timers, systemd/desktop startup
files, shell profiles, or PM2. The PM2 daemon is absent and its current saved
process list is empty. Four live Docker containers are monitoring components
(webhook sink, Grafana, Prometheus, Alertmanager); other containers are stopped
with restart policy `no`.

Source defaults are context only: `PERPS_ACTIVE_ENGINE_VERSION` defaults to V1,
`EXECUTOR_REAL_BROADCAST_ENABLED=false`, `EXECUTION_ENABLED=false`, and
`EXECUTOR_DRY_RUN=true`. These are not described as a running process's effective
environment. No backend code, configuration or service state was changed.

## Recovery script safeguards and signing

`DeployPerpEngineV2Recovery.s.sol` uses `msg.sender`, requires the exact OWNER
`0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`, and uses
`vm.startBroadcast(deployer)` with an address. It neither reads nor handles a
private key. The OWNER check runs even when confirmation is false.

Before CREATE, the script requires:

1. Chain ID 84532.
2. Exact OWNER sender.
3. `PERP_MARKET_REGISTRY_V2_ADDRESS` equals
   `0xAD8B0855d1fd649539A344AD594bf86929cf0FF7`, with nonempty code.
4. ABI-decoded deviation getters equal 100 for markets 1 and 2.
5. Both markets exist and are active; malformed/empty return data reverts.
6. Linked Engine runtime length/hash equal the frozen identity above, and OLD
   Engine code has the same length/hash. The verifier additionally compares bytes.
7. `PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=true` to record the nine operations.
   Without confirmation, no operations are recorded. Forge additionally needs
   an explicit `--broadcast` to send transactions.

No shared dependency-side pointer or authorization is modified. NEW Engine's
internal PME/Risk/fee/clearing/insurance/seizer pointers are configured, while
PME_V2 and RISK_V2 still point to OLD Engine. Migration remains OPEN; economic
state is empty; Vault authorization is absent. This is why it remains inert.
Pause flags default false; it is not inert because of an internal pause.

## Exact library configuration and unsigned dry-run

Use both explicit links; do not allow automatic deployment of new libraries:

```bash
# RPC_URL must already contain a Base Sepolia endpoint. Never echo it.
export PERP_MARKET_REGISTRY_V2_ADDRESS=0xAD8B0855d1fd649539A344AD594bf86929cf0FF7
export PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=true

forge script script/DeployPerpEngineV2Recovery.s.sol -j 1 \
  --rpc-url "$RPC_URL" \
  --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
  --libraries src/perp/PerpEngineLiquidationLib.sol:PerpEngineLiquidationLib:0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D \
  --libraries src/perp/PerpEngineSeizureLib.sol:PerpEngineSeizureLib:0xf0C5652277CF88B508E05F7aB54949fCDF0360A5

PYTHONDONTWRITEBYTECODE=1 python3 tools/perps_v2_cutover/recovery_preflight.py \
  --dry-run broadcast/DeployPerpEngineV2Recovery.s.sol/84532/dry-run/run-latest.json
```

This is the unsigned dry-run command: no `--broadcast`, no `--resume`, no
`--skip-simulation`, no keystore or password access. Library binding is also
enforced by the full linked runtime hash before the script's CREATE. The artifact
verifier rejects any additional library transaction or nested deployment.

For a **separately authorized future M2**, the same exact command would additionally
use `--broadcast --keystore <path> --password-file <path>` while retaining
`--sender` and both library links. Those signing/broadcast options were not used
in this milestone. Refresh nonce, code, PMR and runtime checks before that future
milestone; a successful local simulation is not evidence of a public deployment.

## Nine-write boundary

Assuming OWNER nonce 790, NEW_ENGINE is
`0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`.
All values are zero ETH. TX2–TX9 target NEW_ENGINE only.

| # | Nonce | Function | Selector | Decoded argument(s) |
|---|---:|---|---|---|
| 1 | 790 | CREATE PerpEngineV2 | none | OWNER, NEW_PMR, Vault `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3`, Oracle `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` |
| 2 | 791 | setMatchingEngine | `0xcaa57466` | `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` |
| 3 | 792 | setRiskModule | `0x04f6f5b2` | `0x8C3d9F71cA59B908Fa200546A63ea62F9C932998` |
| 4 | 793 | setClearingAccount | `0x41590123` | `0x54d49c088DD27cFc82685b867c182b4bB4aC435c` |
| 5 | 794 | setInsuranceFund | `0xc3c05293` | `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` |
| 6 | 795 | setCollateralSeizer | `0xc34db4d6` | `0x39F928b959cF58369E7C7a3B925e6cBfFA62B669` |
| 7 | 796 | setFeesManagerV2 | `0x81b5323a` | `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f` |
| 8 | 797 | setUseFeesManagerV2 | `0x74304b2a` | true |
| 9 | 798 | setGuardian | `0x8a0dac4a` | OWNER |

The artifact verifier checks full creation code plus constructor arguments, every
setter's exact calldata, sender, nonce, target, chain ID and zero ETH value. It
requires nine transactions and no broadcast receipts or pending transactions.
There are no PME/Risk rebinds, FMV2 consumers, Insurance/Vault ACL changes,
migration calls, library deployments, or backend operations in this sequence.

## Fresh targeted validation

Memory checked with `free -h` before Forge. All Forge runs use `-j 1`, sequentially;
no Cargo or broad suite was run.

| Suite | Fresh result |
|---|---:|
| PerpEngineExecutionPriceGuard | 22 passed |
| PerpEngineV2Migration | 33 passed |
| PerpEngineV2ProductionWiring | 1 passed |
| PerpEngineV2RecoveryRehearsal | 3 passed |
| Requested four-suite total | **59 passed, 0 failed** |
| DeployPerpEngineV2Recovery guard regressions | 12 passed |
| Python Ethereum hash / transaction boundary regressions | 11 passed |

The additional Solidity checks cover wrong chain/sender/PMR, missing code,
either market's wrong deviation/missing/inactive state, empty/malformed ABI data,
and wrong runtime size/hash. Python checks include Ethereum golden vectors,
provider fallback/fail-closed behavior, existing canonical CBOR, and rejection
of extra deployments, shared-target calls, wrong arguments/nonces/creation code,
and broadcast receipts. Synthetic unit-test artifacts are not chain evidence.

Targeted build:
`forge build -j 1 script/DeployPerpEngineV2Recovery.s.sol` with the same two
`--libraries` flags above succeeded with Solc 0.8.30. Only script/helpers/tests/docs
changed; production Engine source and its runtime identity are preserved.

## Final live reconciliation and verdict

The real Forge dry-run completed successfully with **exactly nine** unsigned
transactions, nonces **790–798**, **zero receipts**, and **zero pending entries**.
The verifier accepted the full CREATE input and all eight exact setter calls.
No new library deployments or shared dependency-side writes were present.
Forge's estimated total gas was 7,762,482; this is a simulation estimate only.

Evidence committed with this milestone:

- [Runtime and nine-transaction verification](../artifacts/perps_v2_handoff_reconciliation/runtime_and_dry_run.json),
  including SHA-256 fingerprints of the script and underlying Forge dry-run artifact.
- [Final live readback](../artifacts/perps_v2_handoff_reconciliation/final_live_readback.json).

Runtime verification block: **47,455,858**, hash
`0x55fa4c521b35fbea6badadfb67c196b11d2d100ab1970967c9d0e1df23c3f621`.

Final state block: **47,455,898**, **2026-09-29 11:08:04 UTC**, hash
`0xb8d9f5826c8385659ee681f23fa8639c8b0d269578c4d87b0ea6c86bb365ddb2`.
All 23 readback assertions passed:

- V1 matching paused and V1 liquidation paused.
- OLD V2 SEALED with the unchanged canonical snapshotHash; residual bad debt zero.
- Vault V1 and OLD V2 authorization true; predicted NEW Engine authorization false.
- Clearing's Vault balance remains 1,000,000,000 native mUSDC.
- OLD Engine still uses OLD PMR; PME_V2 and RISK_V2 still use OLD Engine.
- Approved NEW PMR has the expected OWNER, two markets and mUSDC allowlisting;
  both markets exist, are active, and return 100 bps.
- Predicted NEW Engine's FMV2 and Insurance authorizations remain false.

Zero V2 TradeExecuted events were found from **47,147,740 through 47,455,898**
inclusive across OLD ENGINE_V2 and PME_V2, using both event signatures.
No DeOpt backend was started; its intentionally stopped status is resolved.

OWNER confirmed and pending nonce were both **790**, including the end-of-readback
check. Cast CREATE derivation and independent RLP/Keccak derivation agree on
`0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`; `eth_getCode` is `0x`.

The first script invocation supplied RPC only through the environment and was
rejected by the chain guard on Forge's default local chain 31337. The successful
run used explicit `--rpc-url` as documented above. Neither invocation included
`--broadcast`, signing material or wallet access.

Blockers: **none**. Verdict: **CODEX_HANDOFF_READY**.

Commit/push policy: normal commit `fix(perps): reconcile recovery deployment handoff for Codex`
on `main`, then normal push to `origin/main`; no amend, force push or skipped hooks.
The containing commit identifies the completed reconciliation; final remote HEAD
is independently checked and reported to the operator after push.

Next milestone, only after a READY verdict and separate execution authorization:
`PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1`.
