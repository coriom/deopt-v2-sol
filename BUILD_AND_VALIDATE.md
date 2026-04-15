# BUILD_AND_VALIDATE.md

## Purpose

This document defines the canonical build and validation workflow for DeOpt v2.

It is the operational reference for:

- local build discipline
- patch validation
- warning triage
- test execution order
- safe stopping conditions
- agent execution rules

This file exists to prevent chaotic iteration, partial validation, and unsafe multi-file patching.

---

# 1. CORE PRINCIPLE

Every change must follow this rule:

1. identify the exact issue
2. patch the narrowest safe scope
3. run the smallest relevant validation command
4. only expand scope if the validation output requires it

No speculative refactor.
No batch patching without explicit reason.
No feature work during stabilization unless explicitly requested.

---

# 2. CANONICAL BUILD ENVIRONMENT

## 2.1 Foundry configuration

The canonical build configuration is the repository `foundry.toml`.

Expected baseline:
- fixed `solc_version`
- optimizer enabled
- `via_ir = true` when required by stack-depth constraints

## 2.2 Canonical build command

```bash
forge build

This is the default command for validating any Solidity code change.

2.3 Build success condition

A build is considered acceptable when:

there are no compiler errors
there are no new warnings indicating semantic breakage
there are no new warnings indicating dangerous casts or hidden type issues in touched logic
3. PATCH VALIDATION TIERS

Validation depends on the scope of the change.

3.1 Tier A — Local compile fix

Use when:

fixing imports
fixing identifier mismatch
fixing type mismatch
fixing mutability
fixing syntax
fixing local helper references

Required validation:

forge build

Stop condition:

build passes
no new warnings directly tied to the patch
3.2 Tier B — Local logic fix

Use when:

changing arithmetic
changing conversions
changing sign handling
changing liquidation preview
changing fee quote inputs
changing storage-adjacent helper behavior

Required validation:

forge build

Then run the narrowest relevant test file if available.

Examples:

forge test --match-path test/perp/PerpEngine.t.sol
forge test --match-path test/margin/MarginEngine.t.sol
forge test --match-path test/risk/RiskModule.t.sol

Stop condition:

build passes
relevant test file passes
no invariant contradiction introduced
3.3 Tier C — Cross-module economic fix

Use when:

changing liquidation flow
changing bad debt routing
changing insurance usage
changing funding application
changing risk accounting
changing collateral valuation
changing settlement behavior

Required validation:

forge build

Then run all relevant narrow tests, not just one.

Typical examples:

forge test --match-path test/perp/*.t.sol
forge test --match-path test/margin/*.t.sol
forge test --match-path test/risk/*.t.sol
forge test --match-path test/liquidation/*.t.sol

If invariant tests exist:

forge test --match-path test/invariants/*.t.sol

Stop condition:

build passes
all related test scopes pass
economic reasoning remains consistent with INVARIANTS.md
4. FIRST-ERROR RULE

When forge build fails:

fix only the first blocking compiler error
rebuild immediately
do not attempt to “clean up everything nearby”
do not refactor surrounding code unless the root cause requires it

This rule is mandatory during stabilization.

5. WARNING TRIAGE RULES

Not all warnings are equal.

5.1 High-priority warnings

These must be treated seriously if they touch modified logic:

unsafe type cast
silent truncation risk
unreachable code caused by wrong assumptions
mutability mismatch revealing hidden state assumptions
shadowing that obscures economic variables
warning implying interface/implementation divergence

Action:

fix now or explicitly justify deferral
5.2 Medium-priority warnings

Usually fix after build stabilization:

unused imports
style/lint naming issues
aliasing issues
minor readability notes

Action:

defer unless they hide a real semantic problem
5.3 Low-priority warnings

Can wait until cleanup pass:

formatting-only lint
comment quality
stylistic inconsistency with no semantic effect
6. VALIDATION BY MODULE
6.1 risk/

When modifying:

collateral valuation
risk views
oracle conversion
maintenance / initial margin
oracle-down behavior

Required checks:

build
risk tests
unit consistency review:
base-native
1e8 normalized
token-native

Mandatory reasoning:

no raw/effective balance confusion
no unsafe unit mixing
6.2 margin/

When modifying:

option position mutation
settlement
liquidation
open-series indexing
fee application

Required checks:

build
margin tests
settlement and liquidation scenario checks if affected

Mandatory reasoning:

settlement idempotency
short contracts tracking coherence
position index coherence
6.3 perp/

When modifying:

position transition
funding
liquidation
residual bad debt
open interest
liquidation preview

Required checks:

build
perp tests
liquidation path review if affected

Mandatory reasoning:

sign correctness
position conservation
funding checkpoint coherence
residual debt policy coherence
6.4 oracle/

When modifying:

normalization
fallback logic
staleness checks
deviation checks
feed activation

Required checks:

build
oracle tests
downstream risk review if price shape changed

Mandatory reasoning:

price always 1e8
stale price never silently accepted where forbidden
6.5 collateral/

When modifying:

deposit/withdraw
internal transfer
token config
yield sync
balance views

Required checks:

build
vault tests
downstream risk review if effective balances changed

Mandatory reasoning:

no phantom balances
no accounting mismatch between raw and effective value
6.6 liquidation/

When modifying:

seizure plan
haircut/spread valuation
token ordering
effective base coverage

Required checks:

build
liquidation tests
risk/liquidation interaction review

Mandatory reasoning:

conservative valuation
no over-crediting seized collateral
deterministic coverage semantics
6.7 fees/

When modifying:

fee caps
quote logic
override precedence
tier claims
premium vs notional fee path

Required checks:

build
fees tests
engine integration review if quote semantics changed

Mandatory reasoning:

override > tier > default
fee quote inputs remain economically correct
6.8 gouvernance/

When modifying:

queue wrappers
encoded calldata
timelock execution
target validation

Required checks:

build
governance tests if available
signature alignment review

Mandatory reasoning:

wrapper signature matches target contract exactly
queue/cancel/execute remain symmetric
7. DOCUMENT UPDATE RULES

After any meaningful modification, update PROGRESS.md.

A meaningful modification includes:

build blocker fix
logic change
parameter change
interface alignment
architectural clarification
test addition

Each entry must include:

date
scope
files modified
summary
invariants impacted
validation result
status
8. SAFE STOP CONDITIONS

It is acceptable to stop after a turn when:

the first compiler blocker is fixed and build is green
the local target test scope passes
the patch does not obviously require cross-module propagation
the remaining work is a separate issue

It is not acceptable to stop when:

build still fails
a touched invariant is left ambiguous
a type migration was started but not completed
an interface and implementation are left inconsistent
9. PATCH SIZE POLICY
9.1 Preferred patch style
smallest safe patch
minimal file count
no opportunistic cleanup
9.2 When multi-file change is allowed

Only when one of these is true:

canonical type moved
interface must match implementation
root cause is cross-module
compile propagation is unavoidable
9.3 When full-file rewrite is acceptable

Only when:

user explicitly asks for full file
local patch is more dangerous than replacement
file is already structurally inconsistent enough that partial edit is error-prone
10. AGENT OPERATING RULES

Any coding agent working in this repository must:

read AGENTS.md
use SPEC.md for system intent
use INVARIANTS.md for safety constraints
use PARAMETERS.md for current baseline values
use ARCHITECTURE_MAP.md for dependency reasoning
update PROGRESS.md after meaningful work

The agent must never:

invent units
silently change scaling
change storage layout casually
broaden patch scope without need
treat baseline parameters as if they were hard invariants
11. RECOMMENDED COMMAND SEQUENCE
11.1 During stabilization
forge build

If error:

fix first blocker only
rerun forge build
11.2 After local logic fix
forge build
forge test --match-path <narrowest_relevant_test_file>
11.3 After critical economic flow fix
forge build
forge test --match-path test/risk/*.t.sol
forge test --match-path test/margin/*.t.sol
forge test --match-path test/perp/*.t.sol
forge test --match-path test/liquidation/*.t.sol

Adapt scope to touched modules.

12. CURRENT PROJECT PHASE

Current phase:

protocol stabilization before comprehensive test matrix

Implication:

prioritize compile correctness
prioritize invariant coherence
postpone non-essential feature work
postpone broad refactors
prepare for structured test buildout
13. DEFINITION OF VALID CHANGE

A change is considered valid only if all of the following hold:

it resolves the intended issue
it preserves relevant invariants
it passes the required validation tier
it does not introduce unexplained new warnings in touched logic
it is documented in PROGRESS.md when meaningful

If one of these is false, the change is incomplete.