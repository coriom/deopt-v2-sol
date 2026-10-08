# PERPS_V2_BASE_SEPOLIA_REPLACEMENT_DEPLOYER_FUNDING_POSTFLIGHT_V1

**FUNDING_POSTFLIGHT = BLOCKED — balance below the reviewed D1 planning floor.** This was a read-only Base Sepolia postflight. The operator reports manual funding but supplied no public funding transaction hash, so this review verifies the resulting balance, not the funding transaction's receipt or source. No additional funding, signing, deployment, Safe or Timelock operation was performed. Machine-readable [postflight evidence](../artifacts/perps_v2_replacement_deployment/funding_postflight.json) has SHA-256 `6483076d3406f78212149437179f172302dce9d3bb109a3d100f5c5290976f92`.

At pinned canonical block **47,834,697**, hash `0x58b9aa8e10b3a66d4c28ea35332b68f181d4a315d0190d4ce3fec7add4f275d6` (2026-10-08 05:34:42 UTC), chain ID was **84532**. The block hash was rechecked after EIP-1898 block-hash-pinned reads. Deployment signer `0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0` had confirmed nonce **0**, pending nonce **0**, balance **1,000,000,000,000,000 wei (0.001 ETH)** and code `0x`. The operator previously attested that the designated keystore derives this address; this review did not inspect or decrypt it. Pending nonce visibility is limited to the configured RPC provider.

| Funding comparison | Reviewed amount | Current result |
|---|---:|---|
| Conservative D1 planning floor | 0.00107585204 ETH | **NO**, short by 0.00007585204 ETH |
| Full D1–D6 planning floor | 0.00142633888 ETH | **NO** |
| Recommended planning balance | 0.005 ETH | **NO** |

The funding floors are planning controls, not claims that an actual D1 deployment would necessarily fail at the current fee quote. At this block, `baseFeePerGas` was **5,000,000 wei**, the priority recommendation **1,000,000 wei** and `eth_gasPrice` **6,000,000 wei**. No D1 execution fee envelope was prepared. A larger faucet drip is not inherently a failure; the actual amount simply does not meet the reviewed D1 floor.

`DIRECT_CREATE` from the signer at nonce 0 still predicts D1 PMR at `0x6B3D846536116082dC4E7227861C341Bb85Ee963`. Independent `cast compute-address --nonce 0` agreed; `eth_getCode` at the predicted address was `0x`. Funding did not consume the recipient nonce. The D1 constructor still assigns owner to ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`; expected constructor-independent runtime Keccak remains `0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5`. The D1 package identity is stable across this incoming ETH receipt, while the old **balance observation** in the signer-bound package is stale and must not be treated as current.

The Timelock owner/guardian remained OPS Safe, its minDelay was **86,400 seconds**, queuePaused **false**, and Safe proposer/executor permissions **true**. The Safe had the same three owners, threshold **2**, no modules, and nonce **19**. The deployment signer was none of these owners; Timelock proposer/executor, Vault Engine authorization, Insurance backstop authorization and current PME executor mapping were all **false** for it. Inspected shared owner/guardian readbacks were other addresses. These bounded reads support **no intended protocol authority** for the deployment signer; funding it grants none.

Frozen source commit `25c36670883604c1ef5229642ee6548aea6796c3` has no `src/` diff. The original package SHA-256 remains `4d2940751d06471e3cd6ca3a298db4e68c1a4b1872d9ca51f3371b69a42ea8b9`, signer-bound package SHA-256 `672ed9b2d0341041816f496df41f796042673996ff7604253b81651d7aeb8b71`, and PMR configuration manifest SHA-256 `accf5770fed96c52cb869c868822697e98a3acc2b6b9f35ab6922e2fc945d20c`. Ten focused package tests passed. No package or source was rewritten to hide the funding shortfall.

**Stop:** D1 final review is not cleared under the reviewed funding floor. Any further funding requires separate operator action; this postflight authorizes none. After an externally authorized balance change, refresh balance, both signer nonces, predicted address/code, current fees and D1 gates. No D1 deployment is authorized by this report.
