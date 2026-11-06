# DEOPT_OPTIONS_VERIFIABLE_SETTLEMENT_V8

Scope: local Solidity prototype, read-only Base Sepolia RPC and local forks. No public transaction, deployment, pointer change, Safe signature, hosted trading activation or GitHub push.

## Evidence and security boundary

The historical `OptionProductRegistry` at `0x3d52b033fab00ed6104dd3bc0a715f8648344eca` has two price-write paths: with zero delay, `setSettlementPrice` finalizes immediately; with nonzero delay, `finalizeSettlementPrice` finalizes a pending arbitrary positive value. Both are callable by `owner` or `settlementOperator`. `MarginEngine.settleAccount(s)` reads `getSettlementInfo` and checks only that the price is nonzero and final. V7's negative control finalized the value `1` locally. A separate wrapper is ineffective while the owner or operator can still call the Registry directly. This is the proven source-to-sink vulnerability.

At the fresh read-only block **55,061,338** (`0xfac758140e9ab23d7a3c18f0a2f322b4fde164ff40ccd0cf7e95d1a9589ccce4`), chain 84532, the ETH Chainlink proxy `0x4adc67696ba383f43dd60a9e78f2c97fbbfc7cb1` and BTC proxy `0x0fb99723aee6f420bead13e6bbb79b7e6f034298` returned adjacent historical rounds through `getRoundData`. Both use eight decimals and phase 1 at this snapshot. ETH round timestamps were 1793932856 and 1793933273; BTC 1793933039 and 1793933280. The deployed Pyth address `0x5f52e4dbea21f5b23523b6e20d50c29ae0a4eb83` returned current feed data and `getUpdateFee([])=0`; this does **not** establish support for a usable historical signed update. The public Hermes historical request returned HTTP 403, so `parsePriceFeedUpdatesUnique` was not tested with an authentic payload. Pyth's [official API](https://api-reference.pyth.network/price-feeds/evm/parsePriceFeedUpdatesUnique) describes signed verification, uniqueness and the payable verification call; [Chainlink's historical round API](https://docs.chain.link/data-feeds/price-feeds/historical-data) describes phase-aware round lookup. Source identities and authenticity of a future expiry price remain distinct gates.

The later pinned collateral read at block **55,062,863** found the Vault accounting and token balance both at **224,066,000,000 six-decimal mUSDC units**, Call short OI **7**, Registry owner ProtocolTimelock, `settlementOperator=0`, `settlementFinalityDelay=0`, and settlement unpaused. A fork-only takeover test paused settlement first, transferred Registry ownership to the prototype and accepted it, then proved the former owner could not call `setSettlementPrice` directly. The prototype has no function that forwards `setSettlementPrice`, `finalizeSettlementPrice`, `setSettlementOperator`, ownership transfer, or delay changes. The live deployment was untouched.

## Prototype and proposed policy (not approved)

`src/settlement/VerifiedOptionSettlementOwner.sol` is an immutable owner contract for the existing Registry, not an optional routing wrapper. Its `acceptRegistryOwnership` requires settlement **and creation** paused, original Timelock owner, zero settlement operator, zero legacy delay, and no pending or finalized series prices. It atomically takes Registry ownership and replaces the historical guardian with itself. The original guardian could otherwise clear `creationPaused` through `setEmergencyModes` and enable creation of a series outside the verifier's feed allowlist. The adapter exposes only pause calls to its immutable external emergency guardian; it does not expose an unpause-creation call. New series creation thus remains frozen under this prototype. The owner-only administrative forwarding is an explicit selector allowlist that excludes all settlement, ownership, creator and pause-creation escape paths. After ownership acceptance, neither Timelock nor another admin can directly finalize a price in the historical Registry. The old owner could still act **before** acceptance; pausing settlement and creation and verifying the transition are mandatory.

Proposed deterministic reference: for each supported underlying/settlement pair, use the last positive Chainlink round at or before expiry and its **immediate next round in the same phase** strictly after expiry. Reject unavailable rounds, phase changes, nonconsecutive IDs, invalid timestamps or answers, and observations older than 1,500 seconds before or more than 1,500 seconds after expiry. Normalize from the feed's actual decimals to 1e8. The prototype allows up to **48 hours** for a challenge; it has a maximum **100 bps** Chainlink/Pyth divergence and **100 bps** Pyth confidence bound. These caps mirror current live-router safety limits where applicable and are **economic proposals, not approved release parameters**. A phase rollover or missing source leaves settlement pending. An L2 sequencer-outage check for the historical interval is not yet implemented or evidenced; this blocks deployment.

Anyone may submit a Pyth update through `parsePriceFeedUpdatesUnique` during the challenge window. Only an authenticated update for the configured feed/expiry window, with bounded confidence and a material divergence, can mark the proposal disputed. A disputed proposal cannot be finalized or cancelled and re-proposed to evade the challenge. A matching update cannot grief settlement. **The current tests use a Pyth stub, not a genuine signed payload**; this path is unqualified for release until a real update is verified against the deployed Pyth contract. The contract never chooses a replacement price after a dispute.

If both historical mechanisms are unavailable or disputed, the prototype leaves the final Registry price unset. Long and short claims remain pending, margin/withdrawal obligations remain tied to existing positions, and no last-known or administrator price is substituted. This preserves the no-arbitrary-price invariant but has no bounded recovery. A future alternate verified source or replacement verifier requires a separately approved design and state/ownership analysis; giving the Safe an arbitrary-price escape would defeat the objective.

Independent review found two further release limits. A valid divergent Pyth update irreversibly disputes a proposal; the prototype offers no bounded, verifiable resolution and can immobilize both counterparties indefinitely. Also, historical `RiskGovernorQueue.queueRegistrySetSeriesActive` and related helpers target the Registry directly; after ownership transfer they would revert. Governance would need a separately reviewed, generic Timelock call to `VerifiedOptionSettlementOwner.executeRegistryAdmin`, and unsupported-series creation remains frozen until a safe on-chain creation policy is approved. Neither is a production-ready migration in this prototype.

## Shared Vault and migration

The V7 withdrawal adapter remains a separate proposed Timelock pointer change. Six tests on the pinned deployed Vault now cover an Options short/long account, stale and future oracle failures, guardian pause, a non-Options InsuranceFund account with 2,100,010 native mUSDC units, and two documented Perps accounts with nonzero positions. After fork-only pointer installation, InsuranceFund successfully withdrew one native unit; Perps positions and Vault balances were unchanged, and the adapter's allowed withdrawal was no greater than the original RiskModule's for both accounts. Aggregate Vault token balance and Call short OI were preserved during the verifier ownership takeover. These representative tests do not enumerate every historical account, liquidation route, fee path or strategy adapter.

The V7 fork test had treated `transferFromInternalAccount` as a guarded live path, but a new fork trace showed that selector reverting immediately on the deployed Vault; it is present in the local source ABI, not evidenced in the deployed runtime. V8 removes that false-positive assertion. Direct `withdraw` and `withdrawFor` remain tested against the live bytecode. Engine-authorized internal transfers and liquidation/seizure hooks bypass the withdrawal adapter by design; their caller restrictions and accounting require separate evidence before a pointer change. No collateral migration is proposed; replacing the non-upgradeable Vault would require an explicit financial state migration and is rejected for this release.

## Reproduction

```bash
cd /home/corio/DEOPT/deopt-v2-sol
python3 -B tools/options_v8_oracle_probe.py
python3 -B tools/options_v8_oracle_probe.py --fork-test
python3 -B tools/options_v7_readonly_preflight.py --fork-test
forge test --match-path test/unit/settlement/VerifiedOptionSettlementOwner.t.sol -vv -j 1
forge test --match-path test/scenario/options/OptionSettlementFlow.t.sol -q -j 1
forge build --skip test -j 1
```

The verifier fork has **2 passing tests**: exclusive Registry ownership with no collateral movement, and actual historical Chainlink rounds accepted for a **synthetic local expired series**. The withdrawal fork has **6 passing tests**. The verifier unit suite has **5 passing tests**, including direct setter/admin bypass rejection, bad round/timestamp, replay, dispute and delay. The existing settlement scenario passed. Pyth stub tests prove only control flow, not authentic signed-update verification. Full V6 browser E2E was not rerun because the prototype is not wired into its launcher; no production flow is claimed.

## Release sequence and stop conditions

1. Approve or reject the price window, reference rule, challenge period, Pyth confidence/divergence policy, sequencer treatment and no-history recovery. Freeze new Options risk until this is resolved.
2. Verify source-to-runtime bytecode for Registry/Vault and all dependency addresses; prove live `settlementOperator=0`, no pending/finalized settlement, no new series/config drift, and inventory of all Vault obligations. Reject if any check fails.
3. After separate transaction approvals, deploy the reviewed owner contract, guardian-pause Registry settlement **and creation**, schedule/execute `transferOwnership`, then schedule/execute `acceptRegistryOwnership`. Re-check old owner and operator cannot write price, the old guardian cannot reopen creation, and `creationPaused` remains true; only then unpause settlement through the allowlisted Timelock route. Never migrate collateral for this ownership step.
4. Only after independent Vault regression and separate approval, guardian-freeze withdrawals as required, deploy the withdrawal adapter, schedule/execute `Vault.setRiskModule(adapter)`, verify all balances/positions/authorized engines, then unpause. A pointer rollback that removes the guard requires withdrawal freeze first.
5. Before any first trade, demonstrate a real signed Pyth historical update on the deployed verifier interface, sequencer-history validation, and full Call settlement with actual proof on a fork or isolated chain. Re-run V6 product E2E if the verifier is integrated into its settlement path.

Rollback: before ownership acceptance, cancel the pending transfer and retain the paused historical Registry. After acceptance, the prototype exposes no arbitrary ownership escape; pause settlement and preserve positions while a separately reviewed verified replacement is designed. No automatic price or collateral restore is permitted. This makes the current prototype **non-deployable** until recovery governance is approved.

## Verdicts

| Field | Verdict | Evidence / limit |
| --- | --- | --- |
| `ARBITRARY_SETTLEMENT_EXPLOIT` | PASS | Direct Registry source path and V7 arbitrary-price negative control confirm it. |
| `SETTLEMENT_VERIFICATION_ARCHITECTURE` | PARTIAL | Exclusive owner and guardian takeover close direct price and creation bypass on fork; bounded recovery and series issuance are missing. |
| `CHAINLINK_HISTORICAL_PROOF` | PARTIAL | Live adjacent rounds and fork proof for synthetic series; actual future expiry and sequencer state unproven. |
| `PYTH_HISTORICAL_PROOF` | BLOCKED | No authentic signed historical payload; Hermes request HTTP 403. |
| `DETERMINISTIC_PRICE_RULE` | PARTIAL | Explicit same-phase adjacent-round rule and bounded windows, subject to economic approval. |
| `CHALLENGE_AND_FINALITY` | PARTIAL | Local dispute/delay tests pass; real Pyth proof and bounded dispute resolution absent. |
| `NO_HISTORY_FALLBACK` | BLOCKED | Fail-closed pending state preserves claims but can immobilize collateral indefinitely. |
| `REGISTRY_BYPASS_PREVENTION` | PARTIAL | After fork-only owner and guardian takeover, direct settlement calls and forbidden admin selectors fail; no live migration or all-path proof. |
| `WITHDRAWAL_ADAPTER_SAFETY` | PARTIAL | Six fork tests pass; authorized internal transfer/liquidation paths and all account classes not covered. |
| `SHARED_VAULT_COMPATIBILITY` | PARTIAL | InsuranceFund and two Perps accounts tested; no complete integration inventory. |
| `EXISTING_POSITION_PRESERVATION` | PARTIAL | Fork owner transition preserves aggregate collateral and short OI; not every holder individually checked. |
| `FORK_SECURITY_TESTS` | PASS | 2 verifier and 6 adapter fork tests at pinned blocks; no public transaction. |
| `BASE_SEPOLIA_RELEASE_READINESS` | BLOCKED | Policy, genuine Pyth proof, sequencer history, bounded dispute recovery, new-series issuance, RiskGovernor compatibility and broad Vault compatibility remain. |
| `OPERATOR_POLICY_DECISIONS` | BLOCKED | Approve reference timing, 48-hour challenge, 100-bps bounds, feed priority and missing-history recovery. |
| `GIT_STATUS` | PASS | Local Solidity commit only; no push, backend or frontend change. |

**Recommendation: NO-GO for economic release and for on-chain ownership or risk-pointer changes.** The next operation is one policy decision on the exact historical reference and bounded recovery path, followed by a real signed-proof test. No administrative procedure alone can close the current arbitrary-price vulnerability.
