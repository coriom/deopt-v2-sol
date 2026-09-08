# DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_DEFERRAL_V1

Architectural decision record.

## Decision

Base Sepolia WETH closed-test activation is **DEFERRED**. WETH remains
disabled on Base Sepolia. Closed-test coverage continues on local Anvil.

This is an intentional architectural decision, not a failed
implementation.

## Verdict

`DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_BLOCKED_BY_IMMUTABLE_VAULT_GATING`

## Trigger

Milestone `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_RELEASE_CLOSURE_V1`
Part B audit determined that executing the previously-frozen
`DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_ACTIVATION_MANIFEST_FINAL`
(sol commit `906ef8f`) would open WETH collateral deposit + margin usage
to every EOA on Base Sepolia, not just the intended closed-test cohort.

## Root cause

The deployed CollateralVault at
`0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` is a plain constructor-
initialised contract with **no proxy / no upgrade hook**. Its
`deposit(address token, uint256 amount)` function has three gates —
`whenDepositsNotPaused`, `cfg.isSupported`, `_requireLaunchActiveCollateral(token)`
— all of which are **global per-token**. No per-caller allowlist exists.

Adding per-caller gating requires modifying the vault, which requires
redeploying it at a new address. That in turn cascades to `MarginEngineV2`
(immutable constructor arg pointing at the vault), the backend RPC config,
the frontend contract addresses, and the monitoring stack. Bounded to
Base Sepolia, that redeploy is still a large migration for a **temporary**
closed-test requirement.

## Rationale for deferring

- CollateralVault is a core custody primitive. Replacing it solely to
  introduce a temporary per-user WETH launch allowlist creates
  unnecessary migration + dependency blast radius.
- The closed-test correctness claim is already GREEN on local Anvil
  (see `DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1_COMPLETE`) — 51
  backend tests + 8 frontend contract tests + a live-Anvil orchestrator
  proving the multi-collateral runtime path end-to-end including
  restart durability.
- The signals Base Sepolia would add (real block times, real oracle
  latency, real gas, real UI on public RPC, multi-user coordination)
  are useful but not urgent. They can be deferred until proper
  production-readiness work with a real gating design.

## Immediate consequences

- **`DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_ACTIVATION_MANIFEST_FINAL`**
  (frozen at sol commit `906ef8f`) is **NOT AUTHORIZED** for broadcast.
  No transaction from WETH-TX-01..18 may be sent from any signer under
  any circumstance under the terms of this deferral.
- The authorization sentence template at the bottom of that manifest
  is **REVOKED**. Issuing that sentence verbatim in a future directive
  is not sufficient to authorize broadcast; it is superseded by this
  deferral.
- `DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_MANIFEST_V1` (the
  design predecessor at the same sol tree) remains valid as
  **design documentation** but its 18-tx sequence is likewise
  unauthorized to broadcast under this deferral.
- No Solidity, backend, or frontend delta is applied by this record.
  All three repos remain at:
  - Solidity: `906ef8f` (adding this file only)
  - Backend: `126a857`
  - Frontend: `9cd8dce`

## Preserved posture

- USDC collateral on Base Sepolia: **UNCHANGED**.
- WETH on Base Sepolia: **REMAINS DISABLED** (`crate::config::collateral::WETH`
  stays `deposit_enabled=false`; production `assert_v1_single_collateral_invariant`
  keeps passing).
- WETH closed-test on local Anvil: **UNCHANGED** — the
  `WETH_CLOSED_TEST` overlay + `MULTICOLLATERAL_CLOSED_TEST_ENABLED`
  env var flow continues to work on chain id 31337.
- `refuse_closed_test_on_forbidden_chain(84532)` **remains intact** —
  the coarse gate that refuses closed-test on Base Sepolia is now the
  correct posture, not a temporary posture-to-be-loosened.
- cbBTC: **DISABLED** (unchanged).
- Public Perps: **OFF** (unchanged).
- Funding: **OFF** (unchanged).
- Frozen Perps Base Sepolia broadcast manifest: **UNTOUCHED**.
- No mainnet activity of any kind.

## Future design option — Vault / Risk launch-control V1.1

If DeOpt later decides that staged per-account collateral launches are
a permanent protocol capability (not just a one-off closed-test tool),
design a dedicated migration milestone. Not now. Not in this milestone.
Not without a separate GO directive.

**Desired properties for a future Vault / Risk launch-control V1.1**:

- **Per-collateral activation** — each collateral token has an
  independent launch-control state, not a single protocol-wide flag.
- **Optional per-account / per-subaccount launch access** — the vault
  natively knows which callers are allowed to first-deposit a given
  collateral during a launch window; opting IN is per-token.
- **Deposits + use gated** — the gate applies to both the deposit
  action (`deposit` / `depositFor`) AND the risk module's decision to
  count the balance toward margin (`_tryComputeTokenCollateralValue`
  consults the same allowlist).
- **Withdrawals + unwind always preserved** — a user removed from the
  allowlist retains the ability to withdraw their existing balance and
  close their existing positions. Removal never traps funds. This is
  the invariant that makes staged launches safe: a mistake in allow-
  list management cannot trap deposits.
- **Emergency disable** — a guardian role can flip a per-token launch
  gate off globally without racing the timelock (matches existing
  `pauseDeposits(token)` style; independent from ownership rotation).
- **No trapping of existing collateral** — every allowlist / gate
  toggle preserves the invariant that a holder can always withdraw
  what they hold. Explicit fuzz tests should assert this.
- **Migration-safe** — if implemented on a fresh vault, the migration
  path from the current single-global-flag vault to V1.1 should be
  designed with a clear state-migration story (either fresh deployment
  + user opt-in migration, or a proxy pattern that preserves the
  existing storage layout). Do not implement without that story.

**Explicitly NOT part of this deferral record**:

- Any Solidity code for the above.
- Any deployment plan.
- Any timeline commitment.
- Any authorization to design or ship it.

The above is guidance for the operator writing the eventual "GO —
execute VAULT_LAUNCH_CONTROL_V1_1_DESIGN" directive, not an approved
work item.

## Explicit non-goals

This deferral does NOT:

- Ship any Solidity change.
- Redeploy the CollateralVault or MarginEngineV2.
- Modify the backend closed-test allowlist behavior (remains: refuses
  84532, allows 31337).
- Modify the frontend closed-test env-var behavior.
- Weaken any existing security posture.
- Authorize any WETH-TX-XX broadcast.

## Rollback

This deferral is itself a code-only, doc-only change (adds this file
plus a NOT-AUTHORIZED banner atop the existing manifest). To rescind
the deferral: delete this file and remove the banner via a new
milestone directive. That is not a routine action — rescinding
requires the same architectural review that produced this record.

## Final state at close

- Solidity: `<pending commit>` (this file + banner amendment)
- Backend: `126a857` (unchanged)
- Frontend: `9cd8dce` (unchanged)
- Base Sepolia on-chain state: **unchanged**.
- Base mainnet on-chain state: **unchanged**.
- Closed-test proof: `DEOPT_WETH_COLLATERAL_LIVE_ANVIL_CLOSURE_V1`
  (local Anvil, GREEN, unchanged).

Milestone: `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_RELEASE_CLOSURE_V1_DEFERRED`.
