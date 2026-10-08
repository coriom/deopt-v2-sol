# PERPS_V2_BASE_SEPOLIA_REPLACEMENT_DEPLOYER_FUNDING_TOPUP_POSTFLIGHT_V1

**FUNDING_POSTFLIGHT = PASS, read-only.** The operator reports an additional manual Base Sepolia top-up. No funding transaction hash was supplied, so this postflight verifies the resulting live balance, not a canonical receipt or funding source. No additional funding, signing, broadcast, Safe/Timelock action or D1 deployment occurred. The [postflight artifact](../artifacts/perps_v2_replacement_deployment/funding_topup_postflight.json) has SHA-256 `7b9a340569b885980e78b9df7cc0f31c89b812acc3f71b9151b31c03f68f55fe`.

At EIP-1898 hash-pinned Base Sepolia block **47,838,510**, hash `0x096333f129d91f0a150687aadbe1d3be64bab4beed06a8231b685f37b94f147d` (2026-10-08 07:41:48 UTC), chain ID was **84532**. The block hash was checked again after collection. Deployment signer `0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0` had confirmed and pending nonces **0/0**, native balance **2,000,000,000,000,000 wei (0.002 ETH)** and code `0x`. Pending nonce visibility is limited to the configured RPC provider. The operator's earlier interactive address-only keystore identity attestation remains distinct from this chain read; this postflight did not access the keystore.

| Planning comparison | Threshold | Current result |
|---|---:|---|
| D1 minimum | 0.00107585204 ETH | **YES** |
| D1–D6 planning floor | 0.00142633888 ETH | **YES** |
| Optional recommended balance | 0.005 ETH | **NO** |

The optional 0.005 ETH balance target is not a PASS requirement. Funding sufficiency is based on the previously reviewed planning floors; it does **not** authorize a future fee envelope or guarantee sufficient gas at deployment time. Fresh planning-only observations were `baseFeePerGas` **5,000,000 wei**, priority recommendation **1,000,000 wei** and `eth_gasPrice` **6,000,000 wei**.

`DIRECT_CREATE` from the signer at nonce 0 still predicts D1 PMR `0x6B3D846536116082dC4E7227861C341Bb85Ee963`. Independent installed `cast compute-address --nonce 0` agreed; `eth_getCode` at the target was `0x`. The D1 constructor still assigns owner directly to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`. The constructor-independent expected runtime Keccak remains `0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5`. Incoming ETH did not consume the signer nonce. Signer, nonce, constructor, predicted address and runtime identity remain bound as reviewed; the old balance observation in the signer-bound package is stale and must not be reused as current.

The same three Safe owners and 2-of-3 threshold were read live. ProtocolTimelock owner/guardian remained OPS Safe, with Safe proposer/executor permissions true. The deployer was not a Safe owner, Timelock proposer/executor, Vault authorized Engine, Insurance backstop caller, current PME executor, or an inspected shared owner/guardian. These bounded checks support **no intended protocol authority** for the deployment-only signer.

Frozen source commit `25c36670883604c1ef5229642ee6548aea6796c3` has no `src/` diff. Original package SHA-256 `4d2940751d06471e3cd6ca3a298db4e68c1a4b1872d9ca51f3371b69a42ea8b9`, signer-bound package SHA-256 `672ed9b2d0341041816f496df41f796042673996ff7604253b81651d7aeb8b71`, bound D1 review SHA-256 `78bc03524a25990ed1b1beebd26f9b62a4b514b9b1b01b38f29dba2d2c005920` and frozen PMR configuration SHA-256 `accf5770fed96c52cb869c868822697e98a3acc2b6b9f35ab6922e2fc945d20c` still match. Ten focused package tests passed.

The next milestone is **PERPS_V2_BASE_SEPOLIA_REPLACEMENT_D1_PMR_FINAL_REVIEW**. It must independently refresh nonce, code, balance, fees, D1 constructor data, runtime expectations and all required state gates. This postflight does not authorize D1 signing or broadcast.
