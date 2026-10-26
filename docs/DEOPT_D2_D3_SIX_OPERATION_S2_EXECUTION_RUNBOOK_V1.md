# DeOpt D2/D3 S2 execution runbook

S1 scheduling is complete: six distinct queued operations, all with ETA **2026-10-27 12:00 UTC** and inclusive expiry **2026-11-10 12:00 UTC**. Tier 4 canonical receipt: `0x02850ab3fdd04516529b140a316c52ab73fff780e0b2f1bcaa05d203d5095d54` in block 50328234; Safe nonce advanced 35→36. Fee and D3 policy remain unchanged until each separate S2 execution.

## Conditional sequence

| Step | Operation | Timelock ID | Conditional Safe nonce | Conditional SafeTx hash | Builder SHA-256 |
|---|---|---|---:|---|---|
| 1 | [D3_TOKEN](../artifacts/perps_v2_replacement_deployment/d3_token_s2_safe_builder_v1.json) | `0x6678a5eefb1b1a1b7a9ff4aa5795e1ba7d09fba63ee59917d454e07fe2208c0d` | 36 | `0x263f797d378aba0478288588b548efff7efc3d1546fe885c232de7d1bff4e73c` | `09dc4b3045b72ae5709c5db4a04478e08c882bcbd9cfb36078035af8fabf5f92` |
| 2 | [D2_PERP_TIER_0](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_0_s2_safe_builder_v1.json) | `0x1976519a08a3a7e65cbe1a2f77fcf0f5fa0f783ccb6c7ef0e6c87b7481caf45b` | 37 | `0x361020aba95982f0187725e31716183edfe3b24b428737721d0fa5caafbbdcc7` | `141d289485027139b6288a9e824531256f71fa64c180057337c68abca80601f1` |
| 3 | [D2_PERP_TIER_1](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_1_s2_safe_builder_v1.json) | `0xb79986810ad3e08b5495a8edeaed0654da513ef6acfa15e8ff1d496ff2ef4a11` | 38 | `0x736f2f64d358f40e72d243024c5a5b65843eaae35cdb7a5a2a64db87ee265e49` | `5693c9d0d9af890fc28988784822188699b261fc9d7bf590d3e4b40e9d783e6a` |
| 4 | [D2_PERP_TIER_2](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_2_s2_safe_builder_v1.json) | `0x48b66ca38c21064a6605af4038a657a191a56f327784dc1e0d0bffdc21075a62` | 39 | `0xdfbcbbf2c808b55e3e5ba7a42ebf7e110ee4e79235e0c2b1c686570d5318949d` | `7ca10a7eee28811c82e6ee0a9f035717e96e79ebb20f67604f9ac259c571185c` |
| 5 | [D2_PERP_TIER_3](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_3_s2_safe_builder_v1.json) | `0xaaf8ae230522b4a6b08a365be6e87f2544392e729b559db44968912b3a177f76` | 40 | `0x0cfa836f6f396bdd049908af487f40cd5da07648cee3b660e01a9303260bc7f1` | `26fae2aea98a7039d2572e4ff8c7bd208ecadc16f09dfbc7d8d749aa882ad897` |
| 6 | [D2_PERP_TIER_4](../artifacts/perps_v2_replacement_deployment/d2_perp_tier_4_s2_safe_builder_v1.json) | `0x9ec2e37332d4dbb27791ae7f4de7e852147b344f58210e61adb7b2f95a8d5b49` | 41 | `0x4f365bce909032d8b0e0d31a85c1b5af3b55b3753082bf274e8a09cd8955b81a` | `31c0638be0e56d227a69e604b13e24d83982464bc44d548006c0e00ab21075a4` |

Each Builder file contains **one unsigned, zero-value CALL** to custom ProtocolTimelock `executeTransaction(address,uint256,bytes,uint256)` with exact reviewed target, inner calldata and ETA. No MultiSend, delegatecall, scheduling or public submission is included. All Safe gas/refund values used for conditional hashes are zero; the Builder files do not enforce them. The nonce and hash for each later step are conditional, not a reusable authorization.

## Before each manual S2 operation

1. Wait until a fresh Base Sepolia block timestamp is at least the ETA and no later than the inclusive expiry. Confirm chain ID 84532, Timelock queued/ready status, exact operation ID, target, calldata, Safe nonce, 2-of-3 threshold, owners, modules and guard.
2. Confirm the previous step has a **canonical public postflight PASS**. Refresh D4 four emergency flags, D6 pause, D3 compatible collateral RiskModule pointer, D4→D5, C02 queued/market absent, shared ACLs, fee recipient and rebate budgets.
3. Recompute SafeTx hash against deployed `getTransactionHash` using the live nonce and full envelope. If nonce or any field changed, stop for independent new review.
4. In Safe UI, import only the selected Builder JSON. Require a successful full Safe simulation, acceptable wallet gas estimate and enough Base Sepolia ETH. Verify exact one CALL, zero value and two genuine owner confirmations. Only the human operator may approve and submit once.
5. Supply the public transaction hash. Independently verify canonical receipt, Safe success and nonce, exact Timelock `TransactionExecuted`, consumed operation and replay rejection, target readback, D4/D6 maintenance and bounded shared economic non-drift. Stop on FAIL or INCONCLUSIVE; do not retry blindly or advance.

## Target-specific acceptance

- **D3_TOKEN:** mUSDC `seizeConfigs` becomes `(5,true,true)`; compatible collateral RiskModule pointer remains unchanged.
- **D2_PERP_TIER_0..4:** the corresponding `getFeeProfile(tier, PERP)` becomes `(0,200)` ppm, equivalent to maker 0 bps and taker 2 bps. Other tiers and option profiles remain unchanged.
- **Every step:** D2 rebate budget remains zero, legacy rebate budget remains 999977 in recorded units, fee recipient stays ProtocolTimelock, D4/D6 maintenance persists, market count stays zero, and C02 remains queued/unexecuted.

The isolated fork tests used owner-address impersonation to exercise Safe mechanics; they did **not** test genuine signatures. No S2 execution, C02 execution, migration or trading is authorized by these artifacts.
