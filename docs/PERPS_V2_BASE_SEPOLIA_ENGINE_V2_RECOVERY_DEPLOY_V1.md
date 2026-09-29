# PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1

Status: **PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1_COMPLETE**.

Recovery Engine deployed at **`0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`** on **Base Sepolia, chain ID 84532**.
Exactly nine OWNER transactions succeeded: one CREATE and eight setters on NEW_ENGINE.
NEW_ENGINE is internally wired, migration OPEN, economically empty, and Vault unauthorized.
Shared dependencies still point to OLD_ENGINE; NEW_ENGINE is not an active trading path.

The operator reviewed the unsigned nine-transaction preview and then explicitly replied
`ready`. One invocation of the committed script was broadcast with `--slow --batch-size 1`.
No retry, resume, manual repair, or additional library deployment was performed.

## Repository and validation checkpoint

- Deployed script/source HEAD: `e4762f2f89c7b71c5e07f9fd41f9b73e4f0ca2b2` (clean).
- Backend HEAD: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged, clean).
- Script SHA-256: `21dd1b5442ffea36daeb55894fd627a661586ef0acdf9261729c6376536fa504`.
- Only this deployment record and sanitized evidence are added by the completion commit.
- Production source, deployment script, backend configuration, and canonical migration artifacts remain unchanged.
- `free -h` checked before Forge; `-j 1`, no concurrent Cargo/Forge, no broad test suite.
- Fresh unsigned simulation succeeded; Forge reused the matching artifacts without compilation.
- Independent JSON-RPC reads verified receipts, transaction calldata, bytecode and state.

Evidence: [preflight](../artifacts/perps_v2_engine_recovery_deploy/preflight.json),
[postflight](../artifacts/perps_v2_engine_recovery_deploy/postflight.json).
The JSON files contain only public addresses, hashes, transaction metadata and sanitized
readbacks. They contain no endpoint credentials, wallet contents, password, or signatures.

## Preflight and OWNER account

Pre-broadcast block: **47,457,061**, hash `0xa4027aa51e0de3cd5d266ccccad01f38bbe6ed85f20a6e541d0ea6593f31f488`.
Independent postflight block: **47,457,159**, hash `0x9c403667f5b7647aca3953524db9a8a29b892c6a0c15cf62f96235b568563e93`.

| Item | Before | After |
|---|---|---|
| OWNER confirmed nonce | 790 | 799 |
| OWNER pending nonce | 790 | 799 |
| OWNER ETH | 0.001752856549434849 | 0.001716274205898345 |
| Safe nonce | 15 | 15 |
| Runtime executor nonce | 1 | 1 |

OWNER: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`. Nonce 790 gave predicted CREATE address `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`.
Manual RLP plus Ethereum Keccak and `cast compute-address` agreed. The address had
`eth_getCode == 0x` before broadcast; the deployment receipt returned the same address.

The following gates passed immediately before broadcast and again after execution:

- V1 PME paused and V1 Engine liquidation paused.
- OLD_ENGINE migration SEALED, canonical snapshotHash unchanged.
- Vault authorization for V1 and OLD_ENGINE remains true.
- Clearing Vault ledger remains 1,000,000,000 native mUSDC (1000.000000 mUSDC).
- Approved NEW_PMR has deployed code, two existing active markets, deviations 100/100.
- PME_V2 and RISK_V2 point to OLD_ENGINE.
- Predicted/actual NEW_ENGINE has no Vault, FMV2 consumer or Insurance authorization.
- Backend stopped, no DeOpt backend process and no port 8080 listener.
- Zero V2 TradeExecuted events, with a full preflight scan and continuous extension
  through postflight block 47,457,159.

## Frozen runtime and libraries

NEW_ENGINE, live OLD_ENGINE and the linked local artifact are **byte-for-byte identical**.
Runtime: **24,321 bytes**, EIP-170 headroom **255 bytes**.
Ethereum Keccak-256: `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.
Historical SHA3 labels in older records are not used as Ethereum identities.

| Library | Required and verified link |
|---|---|
| PerpEngineLiquidationLib | `0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D` |
| PerpEngineSeizureLib | `0xf0C5652277CF88B508E05F7aB54949fCDF0360A5` |

NEW_PMR runtime also matched the local artifact before broadcast: 13,217 bytes,
Ethereum Keccak-256 `0x70a03433c8f58ac8e97e6caa5c0e488db1440c05aa1dce46b0fef4930e8194f5`.

## Signing and exact execution configuration

The committed script uses `msg.sender`, rejects any sender other than OWNER,
requires chain ID 84532, hard-binds the approved PMR, and ABI-decodes both markets'
deviation/existence/activity before CREATE. It checks the frozen Engine runtime
and live OLD_ENGINE code before CREATE. There is no DEPLOYER_PRIVATE_KEY dependency.

The actual invocation used this configuration; `$RPC_URL` below is only a placeholder
for the private Base Sepolia endpoint and is never included in evidence:

```bash
PERP_MARKET_REGISTRY_V2_ADDRESS=0xAD8B0855d1fd649539A344AD594bf86929cf0FF7 \
PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=true \
forge script script/DeployPerpEngineV2Recovery.s.sol -j 1 \
  --rpc-url "$RPC_URL" \
  --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
  --libraries src/perp/PerpEngineLiquidationLib.sol:PerpEngineLiquidationLib:0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D \
  --libraries src/perp/PerpEngineSeizureLib.sol:PerpEngineSeizureLib:0xf0C5652277CF88B508E05F7aB54949fCDF0360A5 \
  --slow --batch-size 1 --broadcast \
  --keystore /home/corio/.foundry/keystores/deopt-deployer \
  --password-file /run/user/1000/deopt-deployer.pw
```

This records the completed invocation; it is **not an instruction to run it again**.
The unsigned simulation omitted `--broadcast`, `--keystore` and `--password-file`.
Forge `--slow` waits for each transaction to confirm successfully before sending the next.
All nine independently checked receipt block numbers increase strictly.

## Exact constructor and nine-transaction preview

Constructor ABI: `constructor(address,address,address,address)`; no function selector.

```text
owner    = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
registry = 0xAD8B0855d1fd649539A344AD594bf86929cf0FF7
vault    = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3
oracle   = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
```

All transaction values are zero. All setters target `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15` only.
Creation data and every setter calldata were compared byte-for-byte with the approved
unsigned plan. No forbidden target or additional contract creation appears.

| TX | Nonce | Target | Function | Selector | Decoded argument | Estimated gas |
|---|---:|---|---|---|---|---:|
| 1 | 790 | CREATE | `constructor(address,address,address,address)` | `none` | `OWNER, NEW_PMR, VAULT, OracleRouter (above)` | 7,255,341 |
| 2 | 791 | NEW_ENGINE | `setMatchingEngine(address)` | `0xcaa57466` | `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` | 70,786 |
| 3 | 792 | NEW_ENGINE | `setRiskModule(address)` | `0x04f6f5b2` | `0x8C3d9F71cA59B908Fa200546A63ea62F9C932998` | 65,081 |
| 4 | 793 | NEW_ENGINE | `setClearingAccount(address)` | `0x41590123` | `0x54d49c088DD27cFc82685b867c182b4bB4aC435c` | 75,944 |
| 5 | 794 | NEW_ENGINE | `setInsuranceFund(address)` | `0xc3c05293` | `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` | 67,310 |
| 6 | 795 | NEW_ENGINE | `setCollateralSeizer(address)` | `0xc34db4d6` | `0x39F928b959cF58369E7C7a3B925e6cBfFA62B669` | 71,315 |
| 7 | 796 | NEW_ENGINE | `setFeesManagerV2(address)` | `0x81b5323a` | `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f` | 70,189 |
| 8 | 797 | NEW_ENGINE | `setUseFeesManagerV2(bool)` | `0x74304b2a` | `true` | 44,733 |
| 9 | 798 | NEW_ENGINE | `setGuardian(address)` | `0x8a0dac4a` | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` | 41,783 |

Each setter writes only its corresponding NEW_ENGINE pointer or fee-mode flag;
the final guardian setter retains OWNER, which was also established by the constructor.
Total estimated gas: **7,762,482**.
Forge estimate at 0.011 gwei: **0.000085387302 ETH**.

## Public transactions and independently verified receipts

| TX | Transaction hash | Block | Status | Execution gas used |
|---|---|---:|---:|---:|
| 1 | `0xe9af35ea3c17a97d039669fe2cf9d9a28609783744e526d700c193328195a4cc` | 47,457,089 | 1 | 5,581,032 |
| 2 | `0x511e3efd4dadf44a34880ca3aa77f749dc3baaf2e34250232df7e96660c4cd03` | 47,457,090 | 1 | 48,401 |
| 3 | `0xec1c4438d4bdb3bf79d27bd524a74928f9d2797f56a193417068b1d71575581b` | 47,457,091 | 1 | 47,119 |
| 4 | `0xb82cafd52ce5801b380a33a9770a6a662e4fb9f6e4ccba448f15aa12107a2a99` | 47,457,092 | 1 | 54,983 |
| 5 | `0x70cb762979d34ce085e2362097166426a68506b94e787ccae4a355cd6993c81d` | 47,457,094 | 1 | 48,732 |
| 6 | `0x6817bc4bff1fca662b47f239a0e0d25a9aaca1a12470be5ca8a25801437ca377` | 47,457,096 | 1 | 48,763 |
| 7 | `0xd579248db6923a38363efe2d040927100a14963c2b90fb2f31ad01ff1b8d0320` | 47,457,097 | 1 | 47,993 |
| 8 | `0x163e7d1865858cf6b8255684900efed7910883574be12536da6b0638440fc021` | 47,457,098 | 1 | 30,587 |
| 9 | `0x24c2979b0d6245d5c8b38c3d14df6b486f349eec509bd784a72e1c499b1bc5ec` | 47,457,099 | 1 | 28,570 |

Total execution gas used: **5,936,180**.
OWNER balance decrease: **36,582,343,536,504 wei**
(0.000036582343536504 ETH), exactly reconciled to
the sum of receipt execution fees plus L1 fees. No unexplained OWNER balance movement.

## Independent constructor and internal wiring readback

Historical reads at CREATE block **47,457,089** confirmed
the four constructor fields, OWNER guardian, OPEN migration, zero snapshot hash,
zero residual debt and zero matching/risk/clearing pointers before setters.
Both market states were zero at that block. Runtime at CREATE already matched the
final frozen runtime. Final state was independently read at block 47,457,159:

| Getter | Value |
|---|---|
| `owner()` | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| `marketRegistry()` | `0xAD8B0855d1fd649539A344AD594bf86929cf0FF7` |
| `collateralVault()` | `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` |
| `oracle()` | `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` |
| `matchingEngine()` | `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` |
| `riskModule()` | `0x8C3d9F71cA59B908Fa200546A63ea62F9C932998` |
| `clearingAccount()` | `0x54d49c088DD27cFc82685b867c182b4bB4aC435c` |
| `insuranceFund()` | `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` |
| `collateralSeizer()` | `0x39F928b959cF58369E7C7a3B925e6cBfFA62B669` |
| `feesManagerV2()` | `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f` |
| `useFeesManagerV2()` | `true` |
| `guardian()` | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |

## Fresh migration and economic state

- `migrationState == OPEN (0)`.
- `migrationSnapshotHash == bytes32(0)`.
- `totalResidualBadDebtBase == 0`.
- Markets 1 and 2: `(longOI, shortOI, cumFR, lastFundingTimestamp) = (0,0,0,0)`.
- All six canonical traders: position `(size, openNotional, lastCumFR) = (0,0,0)`
  on both markets, residual bad debt 0, active market count 0.

The six addresses and all readbacks are in `postflight.json`. OLD_ENGINE's two
market states and six seeded positions still match the canonical manifest.
Canonical CBOR Ethereum hash was rechecked as `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.
No manifest/CBOR regeneration, seed or seal occurred.

## NEW PMR compatibility and operational inactivity

NEW_ENGINE.marketRegistry is `0xAD8B0855d1fd649539A344AD594bf86929cf0FF7`.
Direct ABI-decoded calls to that address return
`getMaxExecutionDeviationBps(1) == 100` and `(2) == 100`; both markets exist and
are active. The original missing selector `0x4d73d67f` failure condition is absent
for this Engine-to-PMR relationship. This is read-only compatibility proof, not
a trade test or activation.

| Shared dependency | Postflight value |
|---|---|
| PME_V2.perpEngine | `0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` (OLD) |
| RISK_V2.perpEngine | `0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` (OLD) |
| FMV2.isFeeConsumer(NEW_ENGINE) | false |
| InsuranceFund.isBackstopCaller(NEW_ENGINE) | false |
| Vault.isAuthorizedEngine(NEW_ENGINE) | false |
| Vault.isAuthorizedEngine(V1) | true |
| Vault.isAuthorizedEngine(OLD_ENGINE) | true |
| Vault.balances(CLEARING_V2,mUSDC) | 1,000,000,000 |

OLD_ENGINE remains SEALED with canonical snapshotHash `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d` and OLD PMR
`0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC`. V1 remains frozen.
NEW_ENGINE is internally wired while the shared execution path remains OLD_ENGINE.

Backend remains `STOPPED`, with `transaction_emission_capability = NONE` for the
backend process. This does not describe OWNER's separate deployment capability.
No backend source/configuration, service, DB or process was changed or started.

## Write boundary, cleanup and next milestone

An independent full-block transaction scan over blocks 47,457,061–47,457,159
found exactly the nine recorded OWNER transactions, with nonce delta **+9**.
Safe nonce delta **0**; executor confirmed/pending nonce delta **0**.
All receipt logs originate from NEW_ENGINE. The eight setter implementations
write Engine storage only; their exact on-chain calldata match the approved plan.

- 1 CREATE; 8 NEW_ENGINE setters; 0 library deployments.
- 0 Safe/Timelock writes; 0 Vault ACL writes; 0 PME/Risk rebinds.
- 0 FMV2 consumer / Insurance authorization writes.
- 0 migration seeds or seals; 0 backend/DB writes; 0 trades.
- No mainnet interaction, automatic retry or repair transaction.

After all nine successful receipts, `/run/user/1000/deopt-deployer.pw` was removed
and its absence verified. No claim of physical secure shredding is made.
No private key, password, endpoint credential or signature was printed or committed.

Blockers: **none**.

Exact next milestone: **PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1**.
It is **not executed or automatically authorized by this completion**.
