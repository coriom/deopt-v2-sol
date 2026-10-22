# C20 S2 operator execution checkpoint

**C20_S2_EXACT_TRANSACTION_REVIEW = PASS**
**C20_S2_STATUS = AWAITING_OPERATOR_SAFE_ACTION**
**FINAL_EXECUTION_APPROVAL = PENDING**

No Safe proposal, signature, public transaction, or Timelock state change was made by this review. This checkpoint is a pinned snapshot, not authority to reuse stale state. C12, migration and public trading remain unauthorized.

Base Sepolia chainId 84532; review block `48557954` / `0x823fb2b007b7a912e63011b901bdbdd9a09c5b88b1683b02d4ffa7b8fb3e031b` at timestamp `1792633459`. The block hash was rechecked. The C20 operation remains queued and ready in the source-verified inclusive window `1792584000..1793793600`. The scoped operation event scan found the original S1 queue event and no execution or cancellation event.

OPS Safe `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` is version 1.4.1, nonce **24**, threshold **2/3**, with the reviewed owners, no modules or guard, and unchanged fallback handler. It remains a Timelock executor. D5 delay is **0**, D4's four restrictions remain **true,true,true,true**, migration is OPEN with zero Risk/PME pointers and no D4 Vault/Insurance authorization, and D6 remains paused. D4/D5/D6 and Timelock runtime hashes match the prior review. Shared checks are bounded: Vault token balance `224066000000` and Clearing ledger `1000000000` match the prior snapshot.

The one Safe action is **CALL (0)** to `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, value **0**, with exact reviewed 228-byte `executeTransaction(address,uint256,bytes,uint256)` calldata. Its Keccak-256 is `0x442affee20ddf4bd8dadfd054ff300d095e7b85ff3f7aa197a3a75ccbadac757`. It executes D5 `0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110` with `setMaxOracleDelay(600)`, inner calldata `0xcd3b691c0000000000000000000000000000000000000000000000000000000000000258`, original ETA `1792584000`, and operation ID `0xad2000557d6dfd7a9adec3d2ba7e66c27386191195c78bd1090f40f8bd7ebc0a`. Local decoding, operation hash, on-chain Timelock hash, and Safe `getTransactionHash` agree.

The reviewed Safe envelope is nonce **24**, `safeTxGas=0`, `baseGas=0`, `gasPrice=0`, `gasToken=0x0000000000000000000000000000000000000000`, `refundReceiver=0x0000000000000000000000000000000000000000`. The **conditional SafeTx hash** is `0x911ceff10ce4de39bf3e17b9779a533c28baf8efae8d25a455d59dd4f63bc909`. The imported Builder file does not bind nonce, gas/refund fields, or the outer network gas limit; the Safe UI must show the same values and hash.

Import file: `/home/corio/DEOPT/deopt-v2-sol/artifacts/perps_v2_replacement_deployment/c20_oracle_delay_fast_s2_safe_builder_v1.json`
Verified SHA-256: `c17bb2c96e8550ed8ab27e9682b5bd49dde7856175713db087096ae4504ad73a`

Read-only Timelock execution `eth_call` succeeded. Direct Timelock gas estimate from the Safe address was **64600**; this excludes Safe and wallet overhead. Observed base fee `5000000` wei, priority fee `1000000` wei, gas price `6000000` wei at review. **Safe UI simulation, full wallet gas estimate, and the executing wallet ETH balance remain pending.** No public gas limit or fee envelope is approved here.

The operator must manually import the file into the Base Sepolia OPS Safe, verify the one CALL, destination, zero value, exact data, nonce, five gas/refund fields and SafeTx hash; require successful UI simulation and sufficient executing-wallet ETH; explicitly approve and obtain two real owner confirmations. Immediately before manual execution, recheck chain window, queue, nonce, authorities, D5=0, D4 restrictions and D6 pause. If any material field differs, stop for a new review. Execute at most once and never retry an ambiguous submission. Provide the public transaction hash for an independent read-only postflight; an outer receipt alone is insufficient.

Focused offline package tests: **8 passed, 0 failed, 0 skipped**. Fresh checkpoint validation: **21 predicates passed, 0 failed**. Evidence: `/home/corio/DEOPT/deopt-v2-sol/artifacts/perps_v2_replacement_deployment/c20_oracle_delay_fast_s2_operator_checkpoint_v1.json` (SHA-256 `3d8db2b25820a59d0c3471df8ad6ad5e727f76a058f10c6bb9cef284937b20cd`). RPC endpoint and credentials are not stored.
