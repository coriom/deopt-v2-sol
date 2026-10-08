# PERPS_V2_BASE_SEPOLIA_REPLACEMENT_DEPLOYER_FUNDING_REVIEW

**FUNDING_REVIEW = PASS; no funding authorized.** This is a pinned Base Sepolia read and an offline funding target. The operator separately attested that an interactive address-only check of `/home/corio/.deopt/keystores/perps-v2-replacement-deployer-base-sepolia` derived `0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0`. This review did not open, decrypt or sign with that keystore. The corresponding machine-readable [funding review](../artifacts/perps_v2_replacement_deployment/funding_review.json) has SHA-256 `022e702e342a40e68d706d9a581d8f272aeaa8152cedfad1316c4ac5938c7b46`.

The source remains frozen at `25c36670883604c1ef5229642ee6548aea6796c3`. Original deployment-package SHA-256 remains `4d2940751d06471e3cd6ca3a298db4e68c1a4b1872d9ca51f3371b69a42ea8b9`; signer-bound package SHA-256 remains `672ed9b2d0341041816f496df41f796042673996ff7604253b81651d7aeb8b71`. Neither package nor the D1 constructor was modified.

## Fresh state and D1 address

At Base Sepolia chain ID `84532`, pinned canonical block `47,833,110`, hash `0xed75b946958299c4f71153fc6e2b6468144ad0825ebf0ab646e0816a62d524cd`, the deployment signer had confirmed nonce **0**, pending nonce **0**, native balance **0 wei**, and code `0x`. Its `DIRECT_CREATE` D1 PMR address remains `0x6B3D846536116082dC4E7227861C341Bb85Ee963`; code at that address was `0x`. EIP-1898 block-hash pinning was used for state-dependent reads and the block hash was rechecked. Pending nonce visibility is limited to the configured RPC provider.

The signer remains different from the lost OWNER, ProtocolTimelock, OPS Safe, runtime executor, two intended traders and all three live Safe owners. Read-only mappings show it is not a current PME executor, Timelock proposer/executor, Vault authorized Engine or Insurance backstop caller. The inspected shared owners and guardians are other addresses. These bounded checks establish **no intended protocol authority in the reviewed architecture**, not a claim about every contract on Base Sepolia. Funding the signer would not grant a protocol role.

## Fee observations and planning arithmetic

At the review block, `baseFeePerGas` was **5,000,000 wei**, `eth_maxPriorityFeePerGas` returned **1,000,000 wei** and `eth_gasPrice` returned **6,000,000 wei**. `eth_feeHistory` was rejected by the configured read-only RPC guard (`GuardRejected`); no fee-history value was invented. The deployed Base GasPriceOracle's instantaneous `getL1FeeUpperBound` observations were **10,525 wei** for the 13,794-byte D1 planning size and **59,832 wei** for a 78,566-byte combined planning size. Those local quotes are neither settled fees nor on-chain maximum-fee guarantees.

| Planning scope | Base gas estimate | Gas with 25% margin | At 20,000,000 wei/gas plus separate 0.001 ETH reserve |
|---|---:|---:|---:|
| D1 only | 3,034,081 | 3,792,602 | **0.00107585204 ETH** |
| D1–D6 | 17,053,555 | 21,316,944 | **0.00142633888 ETH** |

The 20,000,000 wei/gas rate is a deliberately higher **planning** rate than the current observations, not an authorized future EIP-1559 field. The separate 0.001 ETH reserve covers L1 fee and network variation and is much larger than the instantaneous oracle quote; it is not a bound on future fees. A **0.005 ETH balance target** remains reasonable for the expected six-stage work, providing roughly 3.5 times the full-sequence planning floor without routinely stocking a disposable signer with large testnet balances. Current balance is insufficient for D1 and the full sequence. Future fee, gas-limit, L1 and balance checks remain mandatory before any separately authorized deployment.

## Funding source and offline intent

A bounded search of current DeOpt Solidity/backend/frontend runbooks found **no named, clean, operator-controlled Base Sepolia gas-funder EOA** for this replacement. Historical materials discuss a one-off funded deployment EOA without designating its address; other funding references concern mUSDC or protocol-role wallets. They do not authorize use of the lost OWNER, runtime executor, traders, Safe owners or protocol contracts.

The preferred operator path is a Base Sepolia ETH faucet. Project onboarding documents already reference Alchemy and QuickNode; the current [QuickNode Base faucet](https://faucet.quicknode.com/base/) describes a Base Sepolia path for a new wallet without a required mainnet balance, with the actual drip shown after address entry. [Alchemy's Base Sepolia faucet](https://www.alchemy.com/faucets/base-sepolia) currently advertises a fixed 0.1 ETH drip and mainnet-activity eligibility; that exceeds this review's 0.005 ETH target. Neither faucet was invoked, and real-time claim eligibility, delivery and exact QuickNode amount remain unverified. An operator can inspect a faucet using only the **public destination address**; there is no reason to connect or unlock the deployment keystore for this review. If the available drip materially exceeds the target, obtain a separate decision rather than silently treating the review as authorization.

The offline desired funding intent is: destination **`0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0`**, value **5,000,000,000,000,000 wei (0.005 ETH)**, calldata **`0x`**. No source account or nonce is assigned. A faucet may dispense a different fixed amount; this is **not an executable transaction package**. If a future operator-controlled transfer is separately authorized, refresh source nonce/balance, destination, exact amount and fee, submit once, obtain a canonical receipt and verify the deployer balance. No blind retry follows an ambiguous submission.

Receiving a simple ETH transfer does **not** consume the destination EOA's nonce. If the deployment signer itself sends nothing, nonce 0 and the D1 `DIRECT_CREATE` prediction remain unchanged. Funding changes the balance and makes this snapshot stale, so the predicted address, nonce, code, balance and package gates must be refreshed after any future funding. The D1 constructor owner remains ProtocolTimelock and expected runtime hash remains `0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5`.

No funding transfer, signature, public send, Safe/Timelock action or deployment occurred. The next milestone is **COMPLETE_OPERATOR_DEPLOYER_FUNDING**, subject to a new, separate authorization and amount review.
