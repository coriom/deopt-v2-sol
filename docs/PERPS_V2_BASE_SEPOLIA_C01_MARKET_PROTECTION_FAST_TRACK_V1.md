# C01 market-protection fast track: unsigned scheduling review

**C01_PREPARATION = PASS. C01_SCHEDULING_FINAL_REVIEW = PASS_FOR_SEPARATE_OPERATOR_REVIEW_ONLY.** This milestone produced no Safe proposal, signature, public queue, execution, market, migration replay, or trade. The proposed Safe transaction is conditional on fresh nonce, state, ETA-margin, gas, and wallet review immediately before any separately authorized operator action.

## Source and dependency decision

C01 is exactly `PerpMarketRegistry.setSettlementAssetAllowed(mUSDC, true)` at canonical D1 `0x6B3D846536116082dC4E7227861C341Bb85Ee963`. The frozen source at `src/perp/PerpMarketRegistry.sol:426-430` requires the Timelock owner and open config, writes only `isSettlementAssetAllowed[mUSDC] = true`, and emits `SettlementAssetConfigured(mUSDC,true)`. The corrected canonical configuration manifest independently contains selector `0xdd4d8a46` and the same 68-byte calldata. The DAG gives C01 only `MAINTENANCE_VERIFIED` as a prerequisite and puts C02 after C01; it gives C12 a separate C20 prerequisite. **C01_INDEPENDENT_OF_C12 = YES**, provided all live maintenance and authority checks continue to pass.

C01 is a necessary allowlist prerequisite, **not a market activation control**. `createMarket` checks that allowlist and then creates `isActive=true, isCloseOnly=false` (`src/perp/PerpMarketRegistry.sol:539-569`). C02 therefore remains a separate authorization and postflight; `MKT1_INACTIVE` must follow it. At the pinned review block D1 had zero markets and `nextMarketId=1`. C01 alone creates no market, changes no D4/D6 setting, and grants no Vault or Insurance role. Even if C02 later creates an active market, current D4 migration OPEN, four D4 pauses, zero D4 Risk/PME pointers, absent D4 shared ACLs, and paused D6 block the replacement economic route. `PerpEngineTradingV2.applyTrade` also requires sealed migration, a matching engine, unpaused trading, a configured risk module, and an existing active market (`src/perp/PerpEngineTradingV2.sol:769-786`). **C01_MARKET_PROTECTION = PASS for C01’s bounded prerequisite effect; C01_ECONOMIC_ISOLATION = PASS for the tested current state.** Neither verdict authorizes C02 or assumes its future state will be safe.

## Pinned public readback

One configured Base Sepolia RPC returned block **48,646,982**, hash `0x2d55e8bf2be36939f143ed421d22afe6bffdea45ce8f59d97edb16e1a9d33366`, timestamp **2026-10-22 06:41:05 UTC**. Every named getter and runtime check used that block tag; its hash was rechecked. D1/D4/D5/D6 and Timelock runtime hashes matched the canonical deployment roadmap; the D1 deployment receipt matched its canonical successful receipt. D1 owner was Timelock, config was open, mUSDC was disallowed, and no replacement market existed. C20's D5 delay read **600**. C12's exact operation remained queued; D4 Risk and PME pointers were zero. D4's four restrictions were true, migration OPEN, D6 paused, and D4 lacked Vault Engine and Insurance backstop grants. Shared Clearing and Insurance Vault ledger values and Vault token balance were captured for fork non-drift checks. Safe 1.4.1 had the reviewed three owners, **2-of-3** threshold, nonce **26**, no modules, and a zero guard read through its documented storage getter; Safe was Timelock owner, proposer and executor; queueing was unpaused and `minDelay=86,400` seconds. These are bounded named readbacks from one provider, not an exhaustive state or independent-provider audit.

## Exact unsigned C01 schedule

| Field | Reviewed value |
| --- | --- |
| D1 target / value | `0x6B3D846536116082dC4E7227861C341Bb85Ee963` / `0` |
| Inner function | `setSettlementAssetAllowed(address,bool)` with mUSDC `0x6eAe407f5640B006faC9965182e238582A3B412E`, `true` |
| Inner calldata | `0xdd4d8a460000000000000000000000006eae407f5640b006fac9965182e238582a3b412e0000000000000000000000000000000000000000000000000000000000000001` |
| Safe action | One `CALL (0)` to ProtocolTimelock `queueTransaction(address,uint256,bytes,uint256)`; no MultiSend or second operation |
| Proposed ETA | **2026-10-23 12:00:00 UTC** (`1792756800`) |
| Buffered scheduling cutoff | **2026-10-22 11:00:00 UTC**, leaving the live 24-hour Timelock minimum plus one hour |
| C01 operation ID | `0x589fb819f60769c77ad9090750f2173377eb45dcbb5367fbc0fb978e4e15d396` |
| Conditional SafeTx hash | `0x6f4f68cf38bd215e2ec4cb05c021aeee2286822d9ff1c8b8cd4f286657eabaef` at nonce **26**, zero value, CALL, zero gas/refund fields |

The operation ID was computed locally as `keccak256(abi.encode(D1,0,inner,ETA))`, matched the deployed Timelock's `hashOperation`, and an `eth_call` of the proposed queue from Safe returned that ID. The SafeTx hash was independently computed with deployed Safe 1.4.1 EIP-712 fields and matched its `getTransactionHash` getter. Both are conditional: a changed Safe nonce, envelope field, target, payload, or ETA requires renewed review. Full Safe UI and wallet gas simulation remain an operator gate; this package is not an authorization.

## Validation and evidence

The isolated pinned-block fork suite `forge test -j 1 --match-path test/perp/PerpsV2C01MarketProtectionFastFork.t.sol` passed **3/3** after a test-only correction. Its first run passed 2 and failed 1 because a getter in an argument consumed a `vm.expectRevert`; the corrected run passed without weakening the assertion. It verified C01's exact effect and event, pre-ETA and wrong-caller rejection, operation identity, duplicate and replay rejection, C12 queue independence, no created market, maintenance preservation, and bounded Vault/Insurance/Clearing non-drift. The existing local C20→C12 order test passed **1/1**. Independent package checks passed **6/6**. These are local and fork rehearsals with synthetic authority, not public signatures or receipts.

- [Preparation evidence](../artifacts/perps_v2_replacement_deployment/c01_market_protection_preparation_v1.json)
- [Fork validation, including the first failed test](../artifacts/perps_v2_replacement_deployment/c01_market_protection_fork_validation_v1.json)
- [Final scheduling review](../artifacts/perps_v2_replacement_deployment/c01_market_protection_s1_final_review_v1.json)
- [Unsigned Safe intent](../artifacts/perps_v2_replacement_deployment/c01_market_protection_s1_unsigned_intent_v1.json)
- [One-action Safe Transaction Builder JSON](../artifacts/perps_v2_replacement_deployment/c01_market_protection_s1_safe_builder_v1.json)

**C01_S1_STATUS = AWAITING_OPERATOR_SAFE_ACTION.** This describes the reviewed unsigned package only. Before separate authorization, recheck chain, block, runtime, D1/C12/C20/maintenance state, Timelock permissions and delay, Safe owners/threshold/nonce, unqueued C01 operation, ETA cutoff, and full gas/UI envelope. If the cutoff passes, choose a new ETA and recompute both hashes. After any ambiguous submission, reconcile read-only; never retry blindly. Scheduling will not authorize C01 execution, C12 execution, market creation, migration replay, or public trading.
