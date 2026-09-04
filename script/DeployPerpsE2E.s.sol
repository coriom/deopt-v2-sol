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
