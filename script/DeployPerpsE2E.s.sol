// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MockPriceSource} from "../src/oracle/MockPriceSource.sol";
import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {MockImpactMidSink} from "../src/testnet/MockImpactMidSink.sol";

// PERPS_V2_BACKEND_ANVIL_LIVE_E2E_V1 — V2 deployment imports.
import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {PerpEngineV2} from "../src/perp/PerpEngineV2.sol";
import {PerpMatchingEngineV2} from "../src/matching/PerpMatchingEngineV2.sol";
import {PerpClearingAccountV2} from "../src/perp/PerpClearingAccountV2.sol";
import {IPerpRiskModule} from "../src/perp/PerpEngineStorage.sol";

/// @title _PerpsE2EMockERC20
/// @notice Script-local ERC-20 mock. Kept inside this file so the E2E
///         harness has zero dependencies on `test/` fixtures which
///         `forge script` normally excludes.
contract _PerpsE2EMockERC20 is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title DeployPerpsE2E
/// @notice Minimum-topology deployment for the closed-test PERPS E2E
///         harness (`~/DEOPT/deopt-v2-backend/tests/perps_closed_test_e2e_harness.rs`).
///
/// @dev
///  # Scope
///  This script exists ONLY to stand up the smallest set of contracts
///  the backend's closed-test signed-intent path actually queries against
///  a local anvil node:
///    - mock USDC + mock WETH (address plumbing for `PerpsReadMarket`)
///    - two `MockPriceSource` feeds (primary + secondary - the router
///      hardens against solo-primary active feeds, `SecondarySourceRequired`)
///    - `OracleRouter` (single `setFeed` for the ETH/USDC pair)
///    - `PerpMarketRegistry` (address only - the closed-test path reads
///      market metadata from the backend's `PerpsReadConfig`, not from
///      the chain, but the address is surfaced for symmetry with the
///      production deployment manifest)
///    - `PerpMatchingEngine` (address only - used solely as the EIP-712
///      `verifying_contract` for `PerpTradeDomain`; `executeTrade` is
///      never called by the harness)
///
///  We deliberately do NOT deploy `PerpEngine`, `PerpRiskModule`,
///  `CollateralVault`, `InsuranceFund`, or `FeesManager` because the
///  closed-test signed-intent path routes through the backend's
///  `submit_perp_order_via_repository` (PG-backed) service which never
///  broadcasts a transaction. The task spec explicitly permits this
///  minimal topology.
///
///  # Refuses
///  - `PERPS_E2E_DEPLOY_ENABLED != true`.
///  - `block.chainid == 1 || block.chainid == 8453` (mainnet chain ids).
///  - `PERPS_E2E_MANIFEST_PATH` unset (harness needs the manifest).
///  - `DEPLOYER_PRIVATE_KEY` unset.
///
///  # Never
///  Never touches production perps flags. Never enables `useFeesManagerV2`.
///  Never wires a production oracle. Never submits an execute-trade
///  transaction.
contract DeployPerpsE2E is Script {
    /// Default oracle price used when `PERPS_E2E_INITIAL_PRICE_1E8` is
    /// unset. $3000 in 1e8 scale.
    uint256 internal constant DEFAULT_ETH_PRICE_1E8 = 300_000_000_000;
    /// Governance-recommended per-market execution-price guard, matches
    /// `MAX_EXECUTION_DEVIATION_BPS` recommended default (5%).
    uint16 internal constant EXECUTION_DEVIATION_BPS = 500;
    /// Oracle-router dual-source deviation gate (5%).
    uint16 internal constant ORACLE_MAX_DEVIATION_BPS = 500;
    /// Per-feed staleness ceiling (seconds). Matches the closed-test
    /// PerpsReadConfig default (`DEFAULT_STALE_AFTER_SEC`).
    uint32 internal constant FEED_MAX_DELAY = 60;

    error DeployNotEnabled();
    error MainnetRefused(uint256 chainId);
    error ManifestPathUnset();
    error DeployerPrivateKeyUnset();

    struct Deployed {
        address deployer;
        address usdc;
        address weth;
        address primarySource;
        address secondarySource;
        address oracleRouter;
        address perpMarketRegistry;
        address perpMatchingEngine;
        address perpEnginePlaceholder;
        address mockImpactMidSink;
        uint256 initialPrice1e8;
        uint256 marketId;
        bytes32 marketSymbol;
    }

    function run() external returns (Deployed memory out) {
        _requireDeployEnabled();
        _refuseMainnet();

        uint256 deployerPk = _requireDeployerPk();
        out.deployer = vm.addr(deployerPk);
        out.initialPrice1e8 = vm.envOr("PERPS_E2E_INITIAL_PRICE_1E8", DEFAULT_ETH_PRICE_1E8);
        out.marketId = vm.envOr("PERPS_E2E_MARKET_ID", uint256(1));
        out.marketSymbol = bytes32("ETH-PERP");

        vm.startBroadcast(deployerPk);

        // 1. Mock ERC-20 quote + base assets. Address plumbing only.
        out.usdc = address(new _PerpsE2EMockERC20("Mock USDC", "mUSDC", 6));
        out.weth = address(new _PerpsE2EMockERC20("Mock WETH", "mWETH", 18));

        // 2. Dual-source mock oracle feeds. The router rejects a
        //    solo-primary active feed (see `SecondarySourceRequired`),
        //    so both are required. Same initial price on both to keep
        //    the deviation gate deterministic.
        out.primarySource = address(new MockPriceSource(out.initialPrice1e8, block.timestamp));
        out.secondarySource = address(new MockPriceSource(out.initialPrice1e8, block.timestamp));

        // 3. OracleRouter owned by the deployer so `setFeed` succeeds.
        OracleRouter router = new OracleRouter(out.deployer);
        out.oracleRouter = address(router);
        router.setFeed(
            out.weth,
            out.usdc,
            IPriceSource(out.primarySource),
            IPriceSource(out.secondarySource),
            FEED_MAX_DELAY,
            ORACLE_MAX_DEVIATION_BPS,
            true
        );

        // 4. PerpMarketRegistry (empty; the backend closed-test path
        //    reads its own PerpsReadConfig for market metadata). Owner
        //    is the deployer.
        out.perpMarketRegistry = address(new PerpMarketRegistry(out.deployer));

        // 5. PerpMatchingEngine - address used as EIP-712
        //    verifying_contract on the backend. Constructor rejects
        //    zero-address engine, so we pass the deployer as a
        //    non-zero placeholder. `executeTrade` is NEVER called by
        //    the harness. If a future scenario needs to call it, the
        //    scenario must deploy a real PerpEngine + wire it here.
        out.perpEnginePlaceholder = out.deployer;
        out.perpMatchingEngine =
            address(new PerpMatchingEngine(out.deployer, out.perpEnginePlaceholder));

        // 6. PERPS-CLOSED-TEST-HARDENING-V1 Part E — mock impact-mid sink.
        //    Byte-compatible surface with `PerpEngine.setImpactMidSource` +
        //    `PerpEngine.updateImpactMid` so the backend's
        //    `LocalAnvilPublisher` can broadcast against a real anvil-side
        //    contract without deploying a full `PerpEngine` topology.
        //    Local-anvil-only; never touched on Base Sepolia or mainnet.
        out.mockImpactMidSink = address(new MockImpactMidSink());

        vm.stopBroadcast();

        _writeManifest(out);
        _logSanitized(out);
    }

    function _requireDeployEnabled() internal view {
        if (!vm.envOr("PERPS_E2E_DEPLOY_ENABLED", false)) revert DeployNotEnabled();
    }

    function _refuseMainnet() internal view {
        uint256 id = block.chainid;
        if (id == 1 || id == 8453) revert MainnetRefused(id);
    }

    function _requireDeployerPk() internal view returns (uint256) {
        if (!vm.envExists("DEPLOYER_PRIVATE_KEY")) revert DeployerPrivateKeyUnset();
        return vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    function _writeManifest(Deployed memory d) internal {
        if (!vm.envExists("PERPS_E2E_MANIFEST_PATH")) revert ManifestPathUnset();
        string memory path = vm.envString("PERPS_E2E_MANIFEST_PATH");

        // Build a flat JSON object keyed by field names the harness
        // reads directly. All addresses lowercase (checksumming happens
        // on the Rust side if needed).
        string memory root = "perps_e2e_manifest";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "marketId", d.marketId);
        vm.serializeUint(root, "initialPrice1e8", d.initialPrice1e8);
        vm.serializeAddress(root, "deployer", d.deployer);
        vm.serializeAddress(root, "usdc", d.usdc);
        vm.serializeAddress(root, "weth", d.weth);
        vm.serializeAddress(root, "primarySource", d.primarySource);
        vm.serializeAddress(root, "secondarySource", d.secondarySource);
        vm.serializeAddress(root, "oracleRouter", d.oracleRouter);
        vm.serializeAddress(root, "perpMarketRegistry", d.perpMarketRegistry);
        vm.serializeAddress(root, "perpMatchingEngine", d.perpMatchingEngine);
        string memory json =
            vm.serializeAddress(root, "mockImpactMidSink", d.mockImpactMidSink);
        vm.writeJson(json, path);
    }

    function _logSanitized(Deployed memory d) internal view {
        console2.log("DeployPerpsE2E - closed-test minimum-topology");
        console2.log("chainId", block.chainid);
        console2.log("deployer", d.deployer);
        console2.log("usdc", d.usdc);
        console2.log("weth", d.weth);
        console2.log("primarySource", d.primarySource);
        console2.log("secondarySource", d.secondarySource);
        console2.log("oracleRouter", d.oracleRouter);
        console2.log("perpMarketRegistry", d.perpMarketRegistry);
        console2.log("perpMatchingEngine", d.perpMatchingEngine);
        console2.log("mockImpactMidSink", d.mockImpactMidSink);
        console2.log("initialPrice1e8", d.initialPrice1e8);
    }
}

// ────────────────────────────────────────────────────────────────
// PERPS_V2_BACKEND_ANVIL_LIVE_E2E_V1 (§§1-4)
// ────────────────────────────────────────────────────────────────

/// @title _PerpsV2E2EMockRisk
/// @notice Script-local `IPerpRiskModule` — kept in this file so
///         `forge script` (which excludes `test/`) can deploy it.
///         Fully ABI-compatible with the production risk-module
///         interface consumed by `PerpEngineV2.applyTrade`; it does
///         not itself compute margin — the E2E test seeds account
///         risk explicitly and every account is set to "healthy" so
///         `applyTrade` accepts the trade at simulation time. The
///         real per-trade solvency check is enforced by
///         `PerpMatchingEngineV2._executeSingle` via the actual V2
///         Engine calls; this mock only supplies the risk-view
///         primitives the engine reads.
contract _PerpsV2E2EMockRisk is IPerpRiskModule {
    address public immutable baseCollateralToken;
    uint8 public immutable baseDecimals;

    mapping(address => AccountRisk) internal risks;

    constructor(address baseToken, uint8 decimals_) {
        baseCollateralToken = baseToken;
        baseDecimals = decimals_;
    }

    function setAccountRisk(address t, int256 equity, uint256 mm, uint256 im) external {
        risks[t] = AccountRisk(equity, mm, im);
    }

    /// @notice Convenience: mark an account as "trivially healthy" for
    ///         the E2E harness. `equity` is set to `type(int256).max /
    ///         2` — well above any margin requirement any test can
    ///         produce — and both maintenance/initial margin are zero.
    function setHealthy(address t) external {
        risks[t] = AccountRisk(type(int256).max / 2, 0, 0);
    }

    function computeAccountRisk(address t) external view returns (AccountRisk memory r) {
        r = risks[t];
    }

    function computeFreeCollateral(address t) external view returns (int256) {
        AccountRisk memory r = risks[t];
        return r.equityBase - int256(r.initialMarginBase);
    }

    function previewWithdrawImpact(address, address, uint256 amount)
        external
        pure
        returns (WithdrawPreview memory p)
    {
        p.requestedAmount = amount;
        p.maxWithdrawable = amount;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @title DeployPerpsV2E2E
/// @notice Full V2 topology for the backend live E2E integration test
///         (`tests/perps_v2_backend_anvil_live_e2e_pg_integration.rs`).
///         Deploys the production
///         `CollateralVault` / `PerpEngineV2` /
///         `PerpMatchingEngineV2` / `PerpClearingAccountV2` at Sol
///         HEAD `2e9ad6f`, configures them, seeds representative
///         A/B migration state (mirroring current Base Sepolia
///         positions), seals migration with a deterministic
///         snapshot hash, funds the clearing account, and writes a
///         manifest the Rust harness reads verbatim.
///
///         The RISK module is a script-local ABI-compatible mock —
///         no production PerpRiskModuleV2 exists at this Sol HEAD,
///         and the E2E's happy path exercises the trade codec /
///         accounting primitives, NOT liquidation logic.
///
/// @dev
///  # Refuses
///  - `PERPS_V2_E2E_DEPLOY_ENABLED != true`.
///  - `block.chainid == 1 || block.chainid == 8453`.
///  - `PERPS_V2_E2E_MANIFEST_PATH` unset.
///  - `DEPLOYER_PRIVATE_KEY` unset.
///
///  # Never
///  Never signs a trade. Never calls `executeTrade`. Never sends
///  ETH. The backend E2E integration invokes eth_call ONLY.
///
///  # Env inputs
///    DEPLOYER_PRIVATE_KEY       — Anvil dev key (harness supplies)
///    PERPS_V2_E2E_TRADER_A      — trader A address (Anvil #1)
///    PERPS_V2_E2E_TRADER_B      — trader B address (Anvil #2)
///    PERPS_V2_E2E_EXECUTOR      — backend executor address (Anvil #3)
///    PERPS_V2_E2E_INITIAL_PRICE_1E8   (default 246_831_000_000 —
///                                     current Base Sepolia mark)
///    PERPS_V2_E2E_CLEARING_FUND_RAW   (default 1_000_000_000_000 —
///                                     1M mUSDC at 6-dec scale)
///    PERPS_V2_E2E_SEAL_MIGRATION      (default true; set "false"
///                                     to leave migration OPEN for
///                                     the §15 negative test)
contract DeployPerpsV2E2E is Script {
    uint256 internal constant DEFAULT_PRICE_1E8 = 246_831_000_000;
    uint256 internal constant DEFAULT_CLEARING_FUND_RAW = 1_000_000_000_000;
    // Base Sepolia deterministic A/B seed (mirrors §M of the
    // PERPS_V2_MIGRATION_SEED_HOOK_V1 milestone).
    int256 internal constant A_SIZE_1E8 = 1_000_000;
    int256 internal constant A_OPEN_NOTIONAL_1E8 = 2_468_310_000;
    int256 internal constant B_SIZE_1E8 = -1_000_000;
    int256 internal constant B_OPEN_NOTIONAL_1E8 = -2_468_310_000;
    // Non-zero deterministic seal hash. `keccak256("PERPS_V2_E2E_SEAL")` slice.
    bytes32 internal constant SEAL_HASH =
        bytes32(uint256(0xB45E5EA1_C01D5EA1_11111111_22222222));
    uint16 internal constant EXECUTION_DEVIATION_BPS = 10_000;
    uint16 internal constant ORACLE_MAX_DEVIATION_BPS = 500;
    uint32 internal constant FEED_MAX_DELAY = 60;

    error DeployNotEnabled();
    error MainnetRefused(uint256 chainId);
    error ManifestPathUnset();
    error DeployerPrivateKeyUnset();
    error TraderAddressUnset(string which);

    struct V2Deployed {
        address deployer;
        address usdc;
        address weth;
        address primarySource;
        address secondarySource;
        address oracleRouter;
        address vault;
        address perpMarketRegistry;
        address perpEngineV2;
        address perpMatchingEngineV2;
        address perpClearingAccountV2;
        address risk;
        address traderA;
        address traderB;
        address executor;
        uint256 initialPrice1e8;
        uint256 marketId;
        uint256 clearingFundRaw;
        bytes32 sealHash;
        bool sealed_;
    }

    function run() external returns (V2Deployed memory out) {
        _requireDeployEnabled();
        _refuseMainnet();

        uint256 deployerPk = _requireDeployerPk();
        out.deployer = vm.addr(deployerPk);
        out.initialPrice1e8 = vm.envOr("PERPS_V2_E2E_INITIAL_PRICE_1E8", DEFAULT_PRICE_1E8);
        out.clearingFundRaw =
            vm.envOr("PERPS_V2_E2E_CLEARING_FUND_RAW", DEFAULT_CLEARING_FUND_RAW);
        out.marketId = 1;
        out.sealHash = SEAL_HASH;
        out.sealed_ = vm.envOr("PERPS_V2_E2E_SEAL_MIGRATION", true);

        if (!vm.envExists("PERPS_V2_E2E_TRADER_A")) revert TraderAddressUnset("A");
        if (!vm.envExists("PERPS_V2_E2E_TRADER_B")) revert TraderAddressUnset("B");
        if (!vm.envExists("PERPS_V2_E2E_EXECUTOR")) revert TraderAddressUnset("executor");
        out.traderA = vm.envAddress("PERPS_V2_E2E_TRADER_A");
        out.traderB = vm.envAddress("PERPS_V2_E2E_TRADER_B");
        out.executor = vm.envAddress("PERPS_V2_E2E_EXECUTOR");

        vm.startBroadcast(deployerPk);

        // 1. Assets — deployer will hold total supply, mint fund to
        //    both traders + fund the vault for clearing seed.
        _PerpsE2EMockERC20 usdcContract =
            new _PerpsE2EMockERC20("Mock USDC", "mUSDC", 6);
        out.usdc = address(usdcContract);
        out.weth = address(new _PerpsE2EMockERC20("Mock WETH", "mWETH", 18));

        // 2. Oracle: dual-source router (rejects solo-primary).
        out.primarySource =
            address(new MockPriceSource(out.initialPrice1e8, block.timestamp));
        out.secondarySource =
            address(new MockPriceSource(out.initialPrice1e8, block.timestamp));

        OracleRouter router = new OracleRouter(out.deployer);
        out.oracleRouter = address(router);
        router.setFeed(
            out.weth,
            out.usdc,
            IPriceSource(out.primarySource),
            IPriceSource(out.secondarySource),
            FEED_MAX_DELAY,
            ORACLE_MAX_DEVIATION_BPS,
            true
        );

        // 3. Vault + Registry.
        CollateralVault vault = new CollateralVault(out.deployer);
        out.vault = address(vault);
        PerpMarketRegistry registry = new PerpMarketRegistry(out.deployer);
        out.perpMarketRegistry = address(registry);

        // 4. PerpEngineV2 (owner, registry, vault, oracle).
        PerpEngineV2 engine =
            new PerpEngineV2(out.deployer, address(registry), address(vault), address(router));
        out.perpEngineV2 = address(engine);

        // 5. Risk module (script-local ABI-compatible mock).
        _PerpsV2E2EMockRisk risk = new _PerpsV2E2EMockRisk(out.usdc, 6);
        out.risk = address(risk);

        // 6. PerpMatchingEngineV2 (owner, engine).
        PerpMatchingEngineV2 pme = new PerpMatchingEngineV2(out.deployer, address(engine));
        out.perpMatchingEngineV2 = address(pme);
        pme.setExecutor(out.executor, true);

        // 7. Vault: allow-list USDC as collateral + authorise the engine.
        vault.setCollateralToken(out.usdc, true, 6, 10_000);
        vault.setAuthorizedEngine(address(engine), true);

        // 8. Registry: allow settlement asset + create the market.
        registry.setSettlementAssetAllowed(out.usdc, true);
        registry.createMarket(
            out.weth,
            out.usdc,
            address(0),
            bytes32("ETH-PERP-V2-E2E"),
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000,
                maintenanceMarginBps: 500,
                liquidationPenaltyBps: 500,
                maxPositionSize1e8: uint128(10_000 * 1e8),
                maxOpenInterest1e8: uint128(100_000 * 1e8),
                reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({
                closeFactorBps: 5_000,
                priceSpreadBps: 100,
                minImprovementBps: 50,
                oracleMaxDelay: 60
            }),
            PerpMarketRegistry.FundingConfig({
                isEnabled: false,
                fundingInterval: 0,
                maxFundingRateBps: 0,
                maxSkewFundingBps: 0,
                oracleClampBps: 0,
                impactMidMaxDelay: 0
            })
        );
        registry.setMaxExecutionDeviationBps(out.marketId, EXECUTION_DEVIATION_BPS);

        // 9. Engine: matching + risk + clearing.
        engine.setMatchingEngine(address(pme));
        engine.setRiskModule(address(risk));

        PerpClearingAccountV2 clearing = new PerpClearingAccountV2(address(vault));
        out.perpClearingAccountV2 = address(clearing);
        engine.setClearingAccount(address(clearing));

        // 10. Mark accounts trivially healthy so applyTrade accepts
        //     any candidate at simulation time.
        risk.setHealthy(out.traderA);
        risk.setHealthy(out.traderB);
        risk.setHealthy(address(clearing));

        // 11. Fund the vault: mint USDC to the deployer, approve the
        //     vault, deposit into the clearing account's Vault
        //     balance via `PerpClearingAccountV2.fundClearing` (the
        //     canonical funding path — never touched with a direct
        //     `vault.deposit` for the clearing account).
        //
        //     Also fund trader A/B minimal amounts so `_setHealthyRisk`
        //     mapping alone is enough — no Vault trader balance is
        //     asserted by the happy-path E2E, but the funds are
        //     staged in case a future test uses them.
        usdcContract.mint(out.deployer, out.clearingFundRaw);
        usdcContract.approve(address(clearing), out.clearingFundRaw);
        // PerpClearingAccountV2.fundClearing pulls the funds via
        // ERC20 transferFrom(deployer, address(this), amount) and
        // then vault-deposits into itself.
        clearing.fundClearing(out.usdc, out.clearingFundRaw);

        // 12. Seed Base-Sepolia-parity A/B state. Market funding first.
        engine.adminSeedMarketFunding(out.marketId, 0, uint64(block.timestamp));
        engine.adminSeedPosition(
            out.traderA, out.marketId, A_SIZE_1E8, A_OPEN_NOTIONAL_1E8, 0
        );
        engine.adminSeedPosition(
            out.traderB, out.marketId, B_SIZE_1E8, B_OPEN_NOTIONAL_1E8, 0
        );

        // 13. Seal migration (unless the operator flagged this run
        //     as the §15 migration-open negative fixture).
        if (out.sealed_) {
            engine.sealMigration(out.sealHash);
        }

        vm.stopBroadcast();

        _writeManifest(out);
        _logSanitized(out);
    }

    function _requireDeployEnabled() internal view {
        if (!vm.envOr("PERPS_V2_E2E_DEPLOY_ENABLED", false)) revert DeployNotEnabled();
    }

    function _refuseMainnet() internal view {
        uint256 id = block.chainid;
        if (id == 1 || id == 8453) revert MainnetRefused(id);
    }

    function _requireDeployerPk() internal view returns (uint256) {
        if (!vm.envExists("DEPLOYER_PRIVATE_KEY")) revert DeployerPrivateKeyUnset();
        return vm.envUint("DEPLOYER_PRIVATE_KEY");
    }

    function _writeManifest(V2Deployed memory d) internal {
        if (!vm.envExists("PERPS_V2_E2E_MANIFEST_PATH")) revert ManifestPathUnset();
        string memory path = vm.envString("PERPS_V2_E2E_MANIFEST_PATH");

        string memory root = "perps_v2_e2e_manifest";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "marketId", d.marketId);
        vm.serializeUint(root, "initialPrice1e8", d.initialPrice1e8);
        vm.serializeUint(root, "clearingFundRaw", d.clearingFundRaw);
        vm.serializeBool(root, "sealed", d.sealed_);
        vm.serializeBytes32(root, "sealHash", d.sealHash);
        vm.serializeAddress(root, "deployer", d.deployer);
        vm.serializeAddress(root, "usdc", d.usdc);
        vm.serializeAddress(root, "weth", d.weth);
        vm.serializeAddress(root, "primarySource", d.primarySource);
        vm.serializeAddress(root, "secondarySource", d.secondarySource);
        vm.serializeAddress(root, "oracleRouter", d.oracleRouter);
        vm.serializeAddress(root, "vault", d.vault);
        vm.serializeAddress(root, "perpMarketRegistry", d.perpMarketRegistry);
        vm.serializeAddress(root, "perpEngineV2", d.perpEngineV2);
        vm.serializeAddress(root, "perpMatchingEngineV2", d.perpMatchingEngineV2);
        vm.serializeAddress(root, "perpClearingAccountV2", d.perpClearingAccountV2);
        vm.serializeAddress(root, "risk", d.risk);
        vm.serializeAddress(root, "traderA", d.traderA);
        vm.serializeAddress(root, "traderB", d.traderB);
        string memory json = vm.serializeAddress(root, "executor", d.executor);
        vm.writeJson(json, path);
    }

    function _logSanitized(V2Deployed memory d) internal view {
        console2.log("DeployPerpsV2E2E - full V2 stack");
        console2.log("chainId", block.chainid);
        console2.log("sealed", d.sealed_);
        console2.log("deployer", d.deployer);
        console2.log("usdc", d.usdc);
        console2.log("weth", d.weth);
        console2.log("oracleRouter", d.oracleRouter);
        console2.log("vault", d.vault);
        console2.log("perpMarketRegistry", d.perpMarketRegistry);
        console2.log("perpEngineV2", d.perpEngineV2);
        console2.log("perpMatchingEngineV2", d.perpMatchingEngineV2);
        console2.log("perpClearingAccountV2", d.perpClearingAccountV2);
        console2.log("risk", d.risk);
        console2.log("traderA", d.traderA);
        console2.log("traderB", d.traderB);
        console2.log("executor", d.executor);
    }
}
