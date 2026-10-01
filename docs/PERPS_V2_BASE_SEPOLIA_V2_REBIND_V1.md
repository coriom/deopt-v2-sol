# PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1

Status: **BLOCKED in Stage A. No public transaction submitted.**

The requested four-OWNER transaction sequence cannot execute: InsuranceFund is
owned by ProtocolTimelock, not the OWNER EOA. No signing, keystore access, local
fork transaction, governance preparation, rebind or backend action was performed.
There is no approved execution package or READY_TO_BROADCAST preview.

## Checkpoints and evidence

Both worktrees were clean at entry:

- Solidity: `fe5a7e4588504fdaf50db2ea940943c75442a8e7`.
- Backend: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`.
- Chain: Base Sepolia, 84532. No mainnet access.
- Resource check: 7.6 GiB total RAM, approximately 6.5 GiB available; no builds.

Stage-A additions are this report, `tools/perps_v2_cutover/rebind_stage_a_readback.py`
and `artifacts/perps_v2_rebind/`. Production contracts, backend source, historical
reports and canonical artifacts remain unchanged. These additions are uncommitted.

Evidence files:

- `ownership_gate.json`: live owners, failed OWNER-context Insurance eth_call,
  exact custom error, and source-derived setter selectors.
- `stage_a_readback.json`: pinned-block full economic/state comparison, seal
  canonical inclusion, inclusion heads, permissions, domain, nonces, scoped event
  scan and permissionless funding probe. This is a readback, not a send package.
- `operational_record_access.json`: credential-free, read-only database access
  failure and the limits of the signed-order investigation.
- `final_readonly_refresh.json`: final OWNER nonce, Insurance ownership and market
  2 readback confirming the trace did not persist changes.

The report path matches an existing repository ignore rule. It remains a local
file; no ignore rule was changed and no file was staged.

## Confirmed comparison state

Comparison block **47492067**, hash
`0x9788e0728773135f2ff9f2199494fbf7010ab500945335731b48de627dcf6862`.
All **114** economic/dependency gates, seed flags, position indexes and six PME
trader nonces exactly match the committed reseal postflight.

- Canonical CBOR Ethereum Keccak-256:
  `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`;
  existing JSON/CBOR semantic agreement and historical block hash verified.
- NEW runtime: **24321 bytes**, byte-for-byte equal to the frozen linked artifact;
  Ethereum Keccak-256
  `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.
- NEW SEALED with canonical hash; constructor/internal pointers unchanged.
- Market 1 `(1001002,1001002,0,1789715546)`; market 2 `(0,0,0,0)`.
  All six full position tuples, per-trader exposure, indexes and debt agree;
  net size and total residual debt are zero.
- Both funding flags and six position flags set; six debt flags unset.
- NEW PMR deviations 100/100; both markets exist and are active.
- PME and Risk still point to OLD. NEW Vault/FMV2/Insurance permissions all false.
- V1 and OLD Vault permissions true. Clearing ledger **1000000000** native mUSDC.
- V1 freeze/economics and OLD SEALED hash/economics unchanged.
- OLD FMV2 fee consumer **true**; OLD Insurance backstop caller **false**.
- OWNER confirmed/pending nonce **808/808**, balance **0.001706833527156533 ETH**.
  Safe nonce **15**, runtime executor nonce **1**. No fee budget approved.
- Six PME_V2 trader nonces remain zero. OWNER and runtime executor are both
  currently allowlisted executors. PME domain separator:
  `0x26a8b7a2a20b6c06fd610e824899da507ef8e51ad40f76040549a8332376c559`.
- Local backend process and port 8080 checks show STOPPED. This establishes only
  the local check's scope, not global absence of transaction emitters.
- Scoped all-topic scan **47491265–47492067** across the ten recorded contract
  emitters returned **zero events**, including zero trades/configuration events.

Reseal transaction
`0xf4cd9b68d0b21734e2d1ab4710b52b20ca36a7458e8fcc518d01731e07b0cec2`
remains status 1 at block **47491134** with the exact matching canonical transaction,
receipt, block hash and seal event. Observed safe head **47491944** and finalized
head **47491271** both cover it. This is the configured RPC's finalized-tag evidence;
no second-provider agreement is claimed. Earlier provisional observations remain
unchanged in the historical artifacts.

## Decisive ownership blocker

Ownership comparison block **47492053**, hash
`0xc0a7e152b11b44d63ed66673ec299885a4ee789bc93320d884f59917bf156811`.

OWNER: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`.
NEW_ENGINE: `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`.

| Requested order | Contract / setter | Selector | Live owner |
|---|---|---|---|
| 1 | FMV2 `setFeeConsumer(NEW_ENGINE,true)` | `0x677682c4` | OWNER EOA |
| 2 | Insurance `setBackstopCaller(NEW_ENGINE,true)` | `0x0f62e507` | ProtocolTimelock |
| 3 | Risk `setPerpEngine(NEW_ENGINE)` | `0xb619daf7` | OWNER EOA |
| 4 | PME `setEngine(NEW_ENGINE)` | `0x0e830e49` | OWNER EOA |

InsuranceFund `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` owner is
**`0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`**, ProtocolTimelock.
The exact proposed Insurance call from OWNER reverts under read-only `eth_call`
with **`NotAuthorized()` (`0xea8e4eb5`)**. Its `onlyOwner` modifier compares
`msg.sender` directly with `owner`; operator or guardian status does not suffice.

Source references: `src/core/InsuranceFund.sol:138` and `:346`;
`src/fees/FeesManagerV2.sol:141`; `src/perp/PerpRiskModule.sol:286`;
`src/matching/PerpMatchingEngineV2.sol:404`.
Each setter changes only its permission/pointer and emits its corresponding
`FeeConsumerSet`, `BackstopCallerSet`, `PerpEngineSet` or `EngineSet` event.
They make no external calls and do not gate on Engine migration state.

The older recovery preflight explicitly inferred Insurance ownership "from
source" (`PERPS_V2_BASE_SEPOLIA_V2_REDEPLOY_RECOVERY_PREFLIGHT_V1.md:64`).
That is not evidence of current deployed ownership. The freeze document's
"4 OWNER tx. No governance flow" conclusion is incompatible with the live read.
This report supersedes that authority assumption; historical files are preserved.

The older freeze document also orders PME before Risk/permissions. The operator's
current explicit order places PME last. Source inspection supports changing the
order without extra calls, but cannot cure the Insurance authority mismatch.
No Timelock operation was queued, prepared or substituted.

## Maintenance and surviving-signature gates

NEW and OLD Engines have trading/funding/liquidation pause flags all false.
PME_V2 is unpaused. V1 matching and liquidation remain paused as required.

`PerpEngineTradingV2.updateFunding(uint256)` is public and only requires SEALED,
unpaused funding and an existing market. At lines 552–555, market 2's zero funding
timestamp is initialized to the current block timestamp before the disabled
funding-configuration branch. It has no signer, executor, Risk or Vault ACL gate.
An `eth_call` from unrelated address `0x0000000000000000000000000000000000000001`
to NEW_ENGINE `updateFunding(2)` succeeds. The call discards its changes; no funding
transaction was sent. This proves that a stopped local backend and absent Vault
authorization do not enforce preservation of the canonical economic state.
The read-only `debug_traceCall` additionally returned the actual storage diff,
without overrides: `_marketStates[2].lastFundingTimestamp` changes from zero to
the comparison block timestamp. The slot is independently derived from the frozen
storage layout; the chain value remains zero. No balances were fabricated.

The source also exposes public `liquidate`, which checks SEALED and liquidation
pause, reads the shared RiskModule and then invokes funding. No liquidation was
executed or claimed successful. `applyTrade` requires the matching engine and
unpaused trading; PME entrypoints additionally require an authorized executor,
valid signatures and order conditions. Later Vault interactions can revert, but
Vault authorization is not a universal gate on Engine storage mutation.

PME `setEngine` does not reset its EIP-712 domain, `nonces`, `intentFilled`,
`intentNonceUsed` or executor mapping. Its domain remains
`DeOptV2-PerpMatchingEngine`, version `2`, chain 84532, verifying contract
`0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2`.
Legacy trade deadline zero is unbounded; order-intent deadlines have their own
checks. No signature is classified as harmless based on age, prefix or chain ID.

The current backend `.env` is absent. Available
`.env.perps_closed_test_prepare_only.local` references a loopback database that
returns a database-does-not-exist error. SELECT-only access used transaction
read-only settings and a short timeout. No database/service was started or changed.
This configuration is not established as an exhaustive historical store inventory.
No claim is made that potentially executable V2 signatures or prepared broadcasts
are absent; this gate remains unresolved. No signatures or credentials were printed.

Any maintenance pause requires a separately reviewed authorization. None was added
to this milestone. The existing funding exposure predates the proposed rebind.

## OLD_ENGINE residual authority and non-interference

OLD_ENGINE keeps its own PME/Risk pointers and its existing fee/Insurance/Vault
permissions. The exact permission booleans are recorded in the readback evidence;
no revocation was attempted. If Risk step 3 were applied, OLD_ENGINE's calls to
that shared RiskModule would read NEW_ENGINE economics. OLD_ENGINE must not be
described as fully isolated or retired after rebind.

No four-call fork rehearsal was run after the authority gate failed. Rebound Risk
reads and oracle freshness were therefore not tested; maxOracleDelay remains 600.
No oracle success, mocked state, gas budget, fee sufficiency or four-call execution
success is claimed. Proposed nonces 808–811 are not an approved executable sequence.

## Stop decision

**PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1_BLOCKED**.

Required before a revised preview: separately review the actual Insurance authority
path, resolve maintenance controls, and obtain a trustworthy read-only inventory of
potentially executable same-domain orders/prepared broadcasts. The current four
OWNER writes cannot be approved as specified. No alternate governance transaction,
pause, rebind, Vault operation or next milestone is automatically authorized.

Public writes 0; keystore unlocks 0; token/migration/Vault/governance/backend/DB
mutations 0. No password file was read or created in Stage A. No commit or push.
