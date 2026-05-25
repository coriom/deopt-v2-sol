# Option Executor Alignment V1J

Date: 2026-05-21

Preflight only. No option execution broadcast, backend `/broadcast` call, option
execution transaction, backend change, frontend change, Solidity change,
deployment, commit, or push was performed.

Target network: Base Sepolia, chain id `84532`.

## Scope

This preflight reconciles the executor address used by backend option execution
simulation and any future backend transaction sender with the on-chain
`OptionMatchingEngine.isExecutor(address)` allowlist.

Current `OptionMatchingEngine`:

```text
0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b
```

## Selector Attribution

Observed selector:

```text
0x1e031850
```

Local Solidity attribution from `src/matching/OptionMatchingEngine.sol`:

| Signature | Selector |
| --- | --- |
| `UnauthorizedExecutor()` | `0x83906042` |
| `InvalidExecutor()` | `0x710c9497` |
| `NotExecutor()` | `0xc32d1d76` |
| `ExecutorNotAllowed()` | `0x5af4d9fe` |
| `NotAuthorized()` | `0xea8e4eb5` |
| `SeriesInactive()` | `0x54535301` |
| `SeriesMetadataMismatch()` | `0x1e031850` |
| `UnknownOptionId()` | `0xc9e72c81` |
| `PausedError()` | `0xeced32bc` |

`OptionMatchingEngine` has no local custom error named
`UnauthorizedExecutor`, `InvalidExecutor`, `NotExecutor`, or
`ExecutorNotAllowed`. Its `onlyExecutor` modifier reverts with
`NotAuthorized()`.

Conclusion: selector `0x1e031850` is `SeriesMetadataMismatch()` in the local
`OptionMatchingEngine` source, not executor gating. If the backend reported that
selector as executor gating, the attribution is stale or came from a different
contract/error table.

## On-Chain State

Read-only Base Sepolia checks were run against the public RPC endpoint.

| Check | Result |
| --- | --- |
| `cast chain-id` | `84532` |
| `OptionMatchingEngine.owner()` | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| `OptionMatchingEngine.marginEngine()` | `0x6C5665De05e7314cB63cD77F82DFa86508A5b5F8` |
| `OptionMatchingEngine.optionRegistry()` | `0x3d52b033Fab00ed6104DD3bc0a715F8648344ecA` |
| `MarginEngine.matchingEngine()` | `0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b` |

The deployed `OptionMatchingEngine` is wired to the Stack A `MarginEngine` and
`OptionProductRegistry`, and Stack A `MarginEngine.matchingEngine()` points back
to this `OptionMatchingEngine`.

## Executor Status

| Address source | Address | `isExecutor` | Notes |
| --- | --- | --- | --- |
| Expected owner/deployer | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` | `true` | Same address as `OptionMatchingEngine.owner()`. |
| `OPTION_EXECUTION_SIMULATION_FROM` from current task context | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` | `true` | Safe simulation sender for executor gating. |
| Backend `.env` `OPTION_EXECUTION_SIMULATION_FROM` | unset | n/a | Backend falls back to `EXECUTOR_FROM_ADDRESS` when unset. |
| Backend `.env` `EXECUTOR_FROM_ADDRESS` | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` | `true` | Effective simulation sender if `OPTION_EXECUTION_SIMULATION_FROM` remains unset. |
| Backend `.env` `EXECUTOR_PRIVATE_KEY` derived address | unavailable | n/a | `EXECUTOR_PRIVATE_KEY` is unset, so no future broadcast sender is currently known from env. |
| Solidity `.env.base-sepolia` `EXECUTOR_PRIVATE_KEY` derived address | unavailable | n/a | `EXECUTOR_PRIVATE_KEY` is unset in this env as well. |
| Zero address fallback | `0x0000000000000000000000000000000000000000` | `false` | Would fail executor gating if used as simulation sender. |

## Intended Backend Executor

For pre-broadcast simulation, the intended backend executor is:

```text
0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
```

This address is currently allowed by `OptionMatchingEngine.isExecutor`.

For any future option execution broadcast, the backend transaction sender is the
public address derived from `EXECUTOR_PRIVATE_KEY`. That key is not set in the
inspected backend env, so the future transaction sender cannot be verified yet.
Before broadcast is enabled, the derived address must either be
`0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` or another address that has been
explicitly allowed by `setExecutor`.

## Mismatch Analysis

No executor allowlist mismatch was found for the current intended simulation
sender:

```text
simulation sender = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
isExecutor       = true
```

The current selector `0x1e031850` therefore should not be treated as executor
gating for this deployed source. It points to `SeriesMetadataMismatch()`, which
means the `OptionTrade` series fields in calldata do not exactly match the
registry series for the supplied `optionId`.

The remaining executor alignment gap is future-broadcast only:
`EXECUTOR_PRIVATE_KEY` is unset, so the eventual transaction sender is unknown.
Do not enable option execution broadcast until the key-derived address is known
and confirmed allowed.

## Manual-Only Authorization

No `setExecutor` action is needed for the current intended backend simulation
address, because it is already allowed.

If an operator later chooses an `EXECUTOR_PRIVATE_KEY` whose derived public
address is different and `isExecutor(<derived address>) == false`, the minimal
manual-only authorization command is:

```bash
set -a
source .env.base-sepolia
set +a

export OPTION_MATCHING_ENGINE_ADDR=0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b
export EXECUTOR_ADDRESS=<address-derived-from-EXECUTOR_PRIVATE_KEY>

cast send "$OPTION_MATCHING_ENGINE_ADDR" \
  "setExecutor(address,bool)" \
  "$EXECUTOR_ADDRESS" true \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY"
```

Do not run this command as part of preflight. It mutates Base Sepolia.

Post-authorization read-only verification:

```bash
cast call "$OPTION_MATCHING_ENGINE_ADDR" \
  "isExecutor(address)(bool)" \
  "$EXECUTOR_ADDRESS" \
  --rpc-url "$RPC_URL"
```

Expected result:

```text
true
```

## Backend Env Values After Alignment

Use the same verified address across backend option execution, simulation, and
EIP-712 configuration:

```bash
OPTION_MATCHING_ENGINE_ADDRESS=0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b
OPTION_EXECUTION_CHAIN_ID=84532
OPTION_EXECUTION_EIP712_NAME=DeOptV2-OptionMatchingEngine
OPTION_EXECUTION_EIP712_VERSION=1

# Either set this explicitly:
OPTION_EXECUTION_SIMULATION_FROM=0xc35F7A8A103A9A4464adfaa76B9B514093D23C27

# Or leave OPTION_EXECUTION_SIMULATION_FROM unset only if this remains identical:
EXECUTOR_FROM_ADDRESS=0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
```

Before any future broadcast:

```bash
EXECUTOR_PRIVATE_KEY=<operator-supplied-key>
```

The public address derived from `EXECUTOR_PRIVATE_KEY` must be confirmed with:

```bash
cast wallet address --private-key "$EXECUTOR_PRIVATE_KEY"
cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b \
  "isExecutor(address)(bool)" \
  "<derived-address>" \
  --rpc-url "$RPC_URL"
```

Do not enable `OPTION_EXECUTION_BROADCAST_ENABLED`,
`EXECUTOR_REAL_BROADCAST_ENABLED`, or call option broadcast until that check is
true and a human explicitly approves the broadcast phase.

## Next Backend Rerun Steps

1. Restart or reload the backend with the aligned non-secret option execution
   env values above.
2. Keep option execution broadcast disabled.
3. Rerun the option nonce read path against
   `OptionMatchingEngine.nonces(address)`.
4. Recreate or refresh the option execution intent so calldata is rebuilt from
   the active registry series tuple.
5. Rerun buyer and seller signing against the same EIP-712 verifying contract:
   `0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b`.
6. Rerun only the live option execution `eth_call` simulation.
7. If selector `0x1e031850` persists, compare the calldata fields
   `underlying`, `settlementAsset`, `expiry`, `strike1e8`, `isCall`, and
   `contractSize1e8` against `OptionProductRegistry.getSeriesIfExists(optionId)`.

## Read-Only Evidence Commands

Equivalent read-only commands:

```bash
cast sig "UnauthorizedExecutor()"
cast sig "InvalidExecutor()"
cast sig "NotExecutor()"
cast sig "ExecutorNotAllowed()"
cast sig "NotAuthorized()"
cast sig "SeriesInactive()"
cast sig "SeriesMetadataMismatch()"

cast chain-id --rpc-url https://sepolia.base.org

cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b \
  "owner()(address)" \
  --rpc-url https://sepolia.base.org

cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b \
  "isExecutor(address)(bool)" \
  0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
  --rpc-url https://sepolia.base.org

cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b \
  "marginEngine()(address)" \
  --rpc-url https://sepolia.base.org

cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b \
  "optionRegistry()(address)" \
  --rpc-url https://sepolia.base.org

cast call 0x6C5665De05e7314cB63cD77F82DFa86508A5b5F8 \
  "matchingEngine()(address)" \
  --rpc-url https://sepolia.base.org
```

## Validation

Local validation:

| Command | Result |
| --- | --- |
| `forge fmt --check` | Passed |
| `forge build` | Passed; compilation skipped, existing Foundry lint notes/warnings emitted |
| `forge test` | Passed; 179 tests passed, 0 failed, 0 skipped |

## Remaining Blocker

The remaining blocker is not executor allowlisting for
`0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`; it is the calldata/registry series
metadata mismatch indicated by `SeriesMetadataMismatch()`.

Future broadcast readiness still requires an operator-supplied
`EXECUTOR_PRIVATE_KEY`, public-address derivation, and `isExecutor` verification
for that derived address.
