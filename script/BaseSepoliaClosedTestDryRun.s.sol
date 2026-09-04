// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";
// `setImpactMidSource` / `pauseFunding` are declared in PerpEngineAdmin, and
// `updateImpactMid` is declared in PerpEngineTrading. Solidity resolves
// `.selector` against the DECLARING type, not the leaf contract, so we import
// the parent abstracts to build calldata and reference selectors from them.
import {PerpEngineAdmin} from "../src/perp/PerpEngineAdmin.sol";
import {PerpEngineTrading} from "../src/perp/PerpEngineTrading.sol";

/// @title BaseSepoliaClosedTestDryRun
/// @notice PERPS-BASE-SEPOLIA-CLOSED-TEST-PROVISIONING-V1 — Part F.
/// @dev
///  DRY-RUN ONLY. This script:
///   - MUST NEVER call `vm.startBroadcast()` (there is no such call anywhere in
///     this file — the operator MUST invoke forge script WITHOUT `--broadcast`).
///   - Refuses any chain other than Base Sepolia (`block.chainid == 84532`).
///   - Emits, for each of the 5 required actions:
///       * target contract address
///       * function selector (bytes4)
///       * full ABI-encoded calldata (as a hex bundle via `console2.logBytes`)
///       * semantic parameter breakdown (via `console2.log(...)`)
///       * expected signer role (protocol owner / guardian / keeper)
///       * a `cast call` readback command the operator can copy-paste to verify
///         the post-execution state
///       * the inverse (rollback / disable) call
///
///  How the operator runs it:
///
///      cd ~/DEOPT/deopt-v2-sol
///      forge script script/BaseSepoliaClosedTestDryRun.s.sol \
///          --rpc-url $BASE_SEPOLIA_RPC \
///          --sig 'run()'
///
///      # ABSOLUTELY NO --broadcast FLAG.
///
///  Env vars the operator MUST supply (script surfaces missing values as
///  explicit `0x0000...0000` placeholders in the logs so nothing silently
///  succeeds against a hollow config):
///
///      # Core contract addresses (already deployed on Base Sepolia)
///      BASE_SEPOLIA_ORACLE_ROUTER
///      BASE_SEPOLIA_PERP_MARKET_REGISTRY
///      BASE_SEPOLIA_PERP_ENGINE
///
///      # Underlyings / settlement asset
///      BASE_SEPOLIA_ETH_UNDERLYING
///      BASE_SEPOLIA_BTC_UNDERLYING
///      BASE_SEPOLIA_USDC_QUOTE
///      BASE_SEPOLIA_USDC_SETTLEMENT
///
///      # Oracle adapter addresses (Chainlink / Pyth wrappers)
///      BASE_SEPOLIA_ETH_USDC_PRIMARY_SOURCE
///      BASE_SEPOLIA_ETH_USDC_SECONDARY_SOURCE
///      BASE_SEPOLIA_BTC_USDC_PRIMARY_SOURCE
///      BASE_SEPOLIA_BTC_USDC_SECONDARY_SOURCE
///
///      # Impact-mid keeper
///      BASE_SEPOLIA_IMPACT_MID_PUBLISHER
///
///      # Existing market IDs (0 => script assumes market row does not exist
///      # yet and logs a `createMarket` call instead of `setRiskConfig` etc.).
///      BASE_SEPOLIA_ETH_PERP_MARKET_ID (optional)
///      BASE_SEPOLIA_BTC_PERP_MARKET_ID (optional)
///
///  ANY calldata output by this script is inspectable via `cast 4byte-decode`
///  or `cast decode-calldata` before the operator ever chooses to broadcast.
///
///  This script does NOT dispatch action (4) (`updateImpactMid`). It only
///  emits the selector + calldata; the operator simulates via
///  `cast call --from <publisher>` as shown in the log output.
///
///  Action (5) is a backend env-var checklist — it is out-of-band w.r.t. the
///  chain but is emitted here so a single dry-run produces the entire
///  operator playbook.
contract BaseSepoliaClosedTestDryRun is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // ---------------------------------------------------------------------
    // Recommended production defaults (aligned with existing spec constants).
    // These are DEFAULTS the operator may override at broadcast time.
    // ---------------------------------------------------------------------

    // Oracle router: 60s freshness ceiling on the primary source, 100 bps
    // primary-vs-secondary deviation cap. Both are well within the router's
    // hard bounds (MAX_ALLOWED_DELAY = 3600s; deviation <= BPS = 10_000).
    uint32 internal constant DEFAULT_ORACLE_MAX_DELAY_SEC = 60;
    uint16 internal constant DEFAULT_ORACLE_MAX_DEVIATION_BPS = 100;

    // Risk config defaults (BPS-scaled).
    uint32 internal constant DEFAULT_INITIAL_MARGIN_BPS = 1000; // 10%
    uint32 internal constant DEFAULT_MAINTENANCE_MARGIN_BPS = 500; // 5%
    uint32 internal constant DEFAULT_LIQ_PENALTY_BPS = 200; // 2%
    uint128 internal constant DEFAULT_MAX_POSITION_1E8 = 500 * 1e8; // 500 units
    uint128 internal constant DEFAULT_MAX_OI_1E8 = 5_000 * 1e8; // 5000 units
    bool internal constant DEFAULT_REDUCE_ONLY_DURING_CLOSE_ONLY = true;

    // Liquidation config defaults.
    uint32 internal constant DEFAULT_CLOSE_FACTOR_BPS = 5000; // 50%
    uint32 internal constant DEFAULT_PRICE_SPREAD_BPS = 50; // 0.5%
    uint32 internal constant DEFAULT_MIN_IMPROVEMENT_BPS = 25; // 0.25%
    uint32 internal constant DEFAULT_LIQ_ORACLE_MAX_DELAY = 60;

    // Funding config defaults (isEnabled=true so the keeper channel is live
    // once the impact-mid source is authorized in action 3).
    bool internal constant DEFAULT_FUNDING_ENABLED = true;
    uint32 internal constant DEFAULT_FUNDING_INTERVAL_SEC = 3600; // 1h
    uint32 internal constant DEFAULT_MAX_FUNDING_RATE_BPS = 75; // 0.75%
    uint32 internal constant DEFAULT_MAX_SKEW_FUNDING_BPS = 50; // 0.5%
    uint32 internal constant DEFAULT_ORACLE_CLAMP_BPS = 500; // 5%
    uint32 internal constant DEFAULT_IMPACT_MID_MAX_DELAY_SEC = 300; // 5m

    // Per-market execution-price deviation guard (matches
    // PerpMarketRegistry.RECOMMENDED_EXECUTION_DEVIATION_BPS).
    uint16 internal constant DEFAULT_MAX_EXECUTION_DEVIATION_BPS = 500;

    // Nominal first impact-mid publish sample: $2500.00 for ETH-PERP as an
    // illustrative example. The operator MUST replace with an actual TWAP
    // computation before broadcasting.
    uint128 internal constant SAMPLE_MID_1E8 = uint128(2500 * 1e8);

    // ---------------------------------------------------------------------
    // Entry point.
    // ---------------------------------------------------------------------

    function run() external view {
        require(
            block.chainid == BASE_SEPOLIA_CHAIN_ID,
            "BaseSepoliaClosedTestDryRun: chainid must be Base Sepolia (84532)"
        );

        console2.log("========================================================");
        console2.log(" PERPS-BASE-SEPOLIA-CLOSED-TEST-PROVISIONING-V1 Part F ");
        console2.log("                     DRY RUN (view-only)                ");
        console2.log("========================================================");
        console2.log("chainid                 :", block.chainid);
        console2.log("block.number            :", block.number);
        console2.log("block.timestamp         :", block.timestamp);
        console2.log("broadcast?              : NO --broadcast, NO vm.startBroadcast");
        console2.log("");

        _logResolvedAddresses();

        // Action 1 - Feed configuration (ETH, BTC).
        _logSectionHeader("ACTION 1/5 - OracleRouter.setFeed (ETH-PERP)");
        _logFeedConfig("ETH_USDC");
        _logSectionHeader("ACTION 1/5 - OracleRouter.setFeed (BTC-PERP)");
        _logFeedConfig("BTC_USDC");

        // Action 2 - Market configuration (ETH, BTC).
        _logSectionHeader("ACTION 2/5 - PerpMarketRegistry (ETH-PERP)");
        _logMarketConfig("ETH_PERP");
        _logSectionHeader("ACTION 2/5 - PerpMarketRegistry (BTC-PERP)");
        _logMarketConfig("BTC_PERP");

        // Action 3 - Impact-mid publisher authorization.
        _logSectionHeader("ACTION 3/5 - PerpEngine.setImpactMidSource");
        _logImpactMidPublisherAuth();

        // Action 4 - First updateImpactMid call (calldata + simulation cmd).
        _logSectionHeader("ACTION 4/5 - PerpEngine.updateImpactMid (SIMULATE via cast call)");
        _logFirstUpdateImpactMid();

        // Action 5 - Backend env checklist (off-chain).
        _logSectionHeader("ACTION 5/5 - Closed-test trading activation (BACKEND, off-chain)");
        _logClosedTestActivationSequence();

        console2.log("");
        console2.log("========================================================");
        console2.log(" End of dry-run. Zero transactions were broadcast.      ");
        console2.log("========================================================");
    }

    // ---------------------------------------------------------------------
    // Section 0 - address resolution (env, with placeholder fallbacks).
    // ---------------------------------------------------------------------

    function _logResolvedAddresses() internal view {
        console2.log("--- Resolved addresses (from env, 0x0 => operator must supply) ---");
        console2.log("OracleRouter               :", _envOrZero("BASE_SEPOLIA_ORACLE_ROUTER"));
        console2.log("PerpMarketRegistry         :", _envOrZero("BASE_SEPOLIA_PERP_MARKET_REGISTRY"));
        console2.log("PerpEngine                 :", _envOrZero("BASE_SEPOLIA_PERP_ENGINE"));
        console2.log("ETH underlying             :", _envOrZero("BASE_SEPOLIA_ETH_UNDERLYING"));
        console2.log("BTC underlying             :", _envOrZero("BASE_SEPOLIA_BTC_UNDERLYING"));
        console2.log("USDC quote                 :", _envOrZero("BASE_SEPOLIA_USDC_QUOTE"));
        console2.log("USDC settlement            :", _envOrZero("BASE_SEPOLIA_USDC_SETTLEMENT"));
        console2.log("ETH primary source         :", _envOrZero("BASE_SEPOLIA_ETH_USDC_PRIMARY_SOURCE"));
        console2.log("ETH secondary source       :", _envOrZero("BASE_SEPOLIA_ETH_USDC_SECONDARY_SOURCE"));
        console2.log("BTC primary source         :", _envOrZero("BASE_SEPOLIA_BTC_USDC_PRIMARY_SOURCE"));
        console2.log("BTC secondary source       :", _envOrZero("BASE_SEPOLIA_BTC_USDC_SECONDARY_SOURCE"));
        console2.log("Impact-mid publisher       :", _envOrZero("BASE_SEPOLIA_IMPACT_MID_PUBLISHER"));
        console2.log("Existing ETH-PERP marketId :", _envUintOrZero("BASE_SEPOLIA_ETH_PERP_MARKET_ID"));
        console2.log("Existing BTC-PERP marketId :", _envUintOrZero("BASE_SEPOLIA_BTC_PERP_MARKET_ID"));
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // ACTION 1 - OracleRouter.setFeed
    // ---------------------------------------------------------------------

    function _logFeedConfig(string memory prefix) internal view {
        address router = _envOrZero("BASE_SEPOLIA_ORACLE_ROUTER");
        address base;
        address quote = _envOrZero("BASE_SEPOLIA_USDC_QUOTE");
        address primary;
        address secondary;

        if (_streq(prefix, "ETH_USDC")) {
            base = _envOrZero("BASE_SEPOLIA_ETH_UNDERLYING");
            primary = _envOrZero("BASE_SEPOLIA_ETH_USDC_PRIMARY_SOURCE");
            secondary = _envOrZero("BASE_SEPOLIA_ETH_USDC_SECONDARY_SOURCE");
        } else {
            base = _envOrZero("BASE_SEPOLIA_BTC_UNDERLYING");
            primary = _envOrZero("BASE_SEPOLIA_BTC_USDC_PRIMARY_SOURCE");
            secondary = _envOrZero("BASE_SEPOLIA_BTC_USDC_SECONDARY_SOURCE");
        }

        uint32 maxDelay = DEFAULT_ORACLE_MAX_DELAY_SEC;
        uint16 maxDevBps = DEFAULT_ORACLE_MAX_DEVIATION_BPS;
        bool isActive = true;

        console2.log("Target contract           : OracleRouter");
        console2.log("Target address            :", router);
        console2.log("Expected signer role      : OracleRouter owner (governance)");
        console2.log("Function                  : setFeed(address,address,IPriceSource,IPriceSource,uint32,uint16,bool)");
        console2.log("Selector (bytes4)         :");
        console2.logBytes4(OracleRouter.setFeed.selector);
        console2.log("Params:");
        console2.log("  baseAsset               :", base);
        console2.log("  quoteAsset              :", quote);
        console2.log("  primarySource           :", primary);
        console2.log("  secondarySource         :", secondary);
        console2.log("  maxDelay (sec)          :", maxDelay);
        console2.log("  maxDeviationBps         :", maxDevBps);
        console2.log("  isActive                :", isActive);

        bytes memory data = abi.encodeCall(
            OracleRouter.setFeed,
            (base, quote, IPriceSource(primary), IPriceSource(secondary), maxDelay, maxDevBps, isActive)
        );
        console2.log("Full calldata (hex)       :");
        console2.logBytes(data);

        console2.log("Expected state transition :");
        console2.log("  feeds[keccak256(base,quote)] = FeedConfig(primary, secondary, maxDelay, maxDevBps, isActive)");
        console2.log("Readback (post-broadcast, still no --broadcast for the readback either):");
        console2.log(
            "  cast call <OracleRouter> 'feeds(bytes32)(address,address,uint32,uint16,bool)' \\\n"
            "    $(cast keccak $(cast abi-encode 'f(address,address)' <base> <quote>)) \\\n"
            "    --rpc-url $BASE_SEPOLIA_RPC"
        );
        console2.log("Rollback / disable path   : OracleRouter.setFeedStatus(base, quote, false)");
        bytes memory rollback = abi.encodeCall(OracleRouter.setFeedStatus, (base, quote, false));
        console2.log("  rollback calldata (hex) :");
        console2.logBytes(rollback);
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // ACTION 2 - PerpMarketRegistry: risk / liquidation / execution-deviation
    //            configuration (if market exists) OR full createMarket.
    // ---------------------------------------------------------------------

    function _logMarketConfig(string memory prefix) internal view {
        address registry = _envOrZero("BASE_SEPOLIA_PERP_MARKET_REGISTRY");
        address underlying;
        address settlement = _envOrZero("BASE_SEPOLIA_USDC_SETTLEMENT");
        bytes32 symbol;
        uint256 existingMarketId;

        if (_streq(prefix, "ETH_PERP")) {
            underlying = _envOrZero("BASE_SEPOLIA_ETH_UNDERLYING");
            symbol = bytes32("ETH-PERP");
            existingMarketId = _envUintOrZero("BASE_SEPOLIA_ETH_PERP_MARKET_ID");
        } else {
            underlying = _envOrZero("BASE_SEPOLIA_BTC_UNDERLYING");
            symbol = bytes32("BTC-PERP");
            existingMarketId = _envUintOrZero("BASE_SEPOLIA_BTC_PERP_MARKET_ID");
        }

        console2.log("Target contract           : PerpMarketRegistry");
        console2.log("Target address            :", registry);
        console2.log("Expected signer role      : PerpMarketRegistry owner (or marketCreator for createMarket)");
        console2.log("Market symbol             :");
        console2.logBytes32(symbol);
        console2.log("Underlying                :", underlying);
        console2.log("Settlement asset          :", settlement);
        console2.log("Existing marketId (0=new) :", existingMarketId);

        PerpMarketRegistry.RiskConfig memory risk = PerpMarketRegistry.RiskConfig({
            initialMarginBps: DEFAULT_INITIAL_MARGIN_BPS,
            maintenanceMarginBps: DEFAULT_MAINTENANCE_MARGIN_BPS,
            liquidationPenaltyBps: DEFAULT_LIQ_PENALTY_BPS,
            maxPositionSize1e8: DEFAULT_MAX_POSITION_1E8,
            maxOpenInterest1e8: DEFAULT_MAX_OI_1E8,
            reduceOnlyDuringCloseOnly: DEFAULT_REDUCE_ONLY_DURING_CLOSE_ONLY
        });
        PerpMarketRegistry.LiquidationConfig memory liq = PerpMarketRegistry.LiquidationConfig({
            closeFactorBps: DEFAULT_CLOSE_FACTOR_BPS,
            priceSpreadBps: DEFAULT_PRICE_SPREAD_BPS,
            minImprovementBps: DEFAULT_MIN_IMPROVEMENT_BPS,
            oracleMaxDelay: DEFAULT_LIQ_ORACLE_MAX_DELAY
        });
        PerpMarketRegistry.FundingConfig memory funding = PerpMarketRegistry.FundingConfig({
            isEnabled: DEFAULT_FUNDING_ENABLED,
            fundingInterval: DEFAULT_FUNDING_INTERVAL_SEC,
            maxFundingRateBps: DEFAULT_MAX_FUNDING_RATE_BPS,
            maxSkewFundingBps: DEFAULT_MAX_SKEW_FUNDING_BPS,
            oracleClampBps: DEFAULT_ORACLE_CLAMP_BPS,
            impactMidMaxDelay: DEFAULT_IMPACT_MID_MAX_DELAY_SEC
        });

        console2.log("--- RiskConfig ---");
        console2.log("  initialMarginBps        :", risk.initialMarginBps);
        console2.log("  maintenanceMarginBps    :", risk.maintenanceMarginBps);
        console2.log("  liquidationPenaltyBps   :", risk.liquidationPenaltyBps);
        console2.log("  maxPositionSize1e8      :", uint256(risk.maxPositionSize1e8));
        console2.log("  maxOpenInterest1e8      :", uint256(risk.maxOpenInterest1e8));
        console2.log("  reduceOnlyDuringCloseOn :", risk.reduceOnlyDuringCloseOnly);

        console2.log("--- LiquidationConfig ---");
        console2.log("  closeFactorBps          :", liq.closeFactorBps);
        console2.log("  priceSpreadBps          :", liq.priceSpreadBps);
        console2.log("  minImprovementBps       :", liq.minImprovementBps);
        console2.log("  oracleMaxDelay          :", liq.oracleMaxDelay);

        console2.log("--- FundingConfig ---");
        console2.log("  isEnabled               :", funding.isEnabled);
        console2.log("  fundingInterval (sec)   :", funding.fundingInterval);
        console2.log("  maxFundingRateBps       :", funding.maxFundingRateBps);
        console2.log("  maxSkewFundingBps       :", funding.maxSkewFundingBps);
        console2.log("  oracleClampBps          :", funding.oracleClampBps);
        console2.log("  impactMidMaxDelay (sec) :", funding.impactMidMaxDelay);

        console2.log("--- Execution deviation guard ---");
        console2.log("  maxExecutionDeviationBps:", DEFAULT_MAX_EXECUTION_DEVIATION_BPS);

        if (existingMarketId == 0) {
            // Path A - market does not exist yet: single atomic createMarket call.
            console2.log("");
            console2.log("Path                      : NEW MARKET => createMarket(...)");
            console2.log("Function                  : createMarket(address,address,address,bytes32,RiskConfig,LiquidationConfig,FundingConfig)");
            console2.log("Selector (bytes4)         :");
            console2.logBytes4(PerpMarketRegistry.createMarket.selector);
            // Note: market-level `oracle_` = address(0) => engine uses global oracle.
            bytes memory data = abi.encodeCall(
                PerpMarketRegistry.createMarket,
                (underlying, settlement, address(0), symbol, risk, liq, funding)
            );
            console2.log("Full calldata (hex)       :");
            console2.logBytes(data);
            console2.log("Post-create follow-up     : setMaxExecutionDeviationBps(<newMarketId>, %s)", uint256(DEFAULT_MAX_EXECUTION_DEVIATION_BPS));
            console2.log("Readback                  :");
            console2.log(
                "  cast call <PerpMarketRegistry> 'getMarket(uint256)((address,address,address,bytes32,bool,bool,bool))' \\\n"
                "    <newMarketId> --rpc-url $BASE_SEPOLIA_RPC"
            );
            console2.log("Rollback / disable path   : setMarketStatus(<newMarketId>, isActive=false, isCloseOnly=true)");
        } else {
            // Path B - market row exists: emit the three targeted setters.
            console2.log("");
            console2.log("Path                      : EXISTING MARKET => setRiskConfig + setLiquidationConfig + setMaxExecutionDeviationBps");

            console2.log("--- Call B1: setRiskConfig ---");
            console2.log("Selector (bytes4)         :");
            console2.logBytes4(PerpMarketRegistry.setRiskConfig.selector);
            bytes memory dataRisk = abi.encodeCall(PerpMarketRegistry.setRiskConfig, (existingMarketId, risk));
            console2.log("Full calldata (hex)       :");
            console2.logBytes(dataRisk);

            console2.log("--- Call B2: setLiquidationConfig ---");
            console2.log("Selector (bytes4)         :");
            console2.logBytes4(PerpMarketRegistry.setLiquidationConfig.selector);
            bytes memory dataLiq = abi.encodeCall(PerpMarketRegistry.setLiquidationConfig, (existingMarketId, liq));
            console2.log("Full calldata (hex)       :");
            console2.logBytes(dataLiq);

            console2.log("--- Call B3: setMaxExecutionDeviationBps ---");
            console2.log("Selector (bytes4)         :");
            console2.logBytes4(PerpMarketRegistry.setMaxExecutionDeviationBps.selector);
            bytes memory dataDev = abi.encodeCall(
                PerpMarketRegistry.setMaxExecutionDeviationBps,
                (existingMarketId, DEFAULT_MAX_EXECUTION_DEVIATION_BPS)
            );
            console2.log("Full calldata (hex)       :");
            console2.logBytes(dataDev);

            console2.log("Readback                  :");
            console2.log(
                "  cast call <PerpMarketRegistry> 'getRiskConfig(uint256)((uint32,uint32,uint32,uint128,uint128,bool))' \\\n"
                "    <marketId> --rpc-url $BASE_SEPOLIA_RPC"
            );
            console2.log(
                "  cast call <PerpMarketRegistry> 'getLiquidationConfig(uint256)((uint32,uint32,uint32,uint32))' \\\n"
                "    <marketId> --rpc-url $BASE_SEPOLIA_RPC"
            );
            console2.log(
                "  cast call <PerpMarketRegistry> 'getMaxExecutionDeviationBps(uint256)(uint16)' \\\n"
                "    <marketId> --rpc-url $BASE_SEPOLIA_RPC"
            );

            console2.log("Rollback / disable path   :");
            console2.log("  setMarketStatus(marketId, isActive=false, isCloseOnly=true)");
            console2.log("  setMaxExecutionDeviationBps(marketId, 0)  // 0 => fail-closed at engine");
            bytes memory rollbackStatus = abi.encodeCall(
                PerpMarketRegistry.setMarketStatus,
                (existingMarketId, false, true)
            );
            bytes memory rollbackDev = abi.encodeCall(
                PerpMarketRegistry.setMaxExecutionDeviationBps,
                (existingMarketId, uint16(0))
            );
            console2.log("  rollback setMarketStatus calldata (hex):");
            console2.logBytes(rollbackStatus);
            console2.log("  rollback setMaxExecutionDeviationBps calldata (hex):");
            console2.logBytes(rollbackDev);
        }
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // ACTION 3 - PerpEngine.setImpactMidSource
    // ---------------------------------------------------------------------

    function _logImpactMidPublisherAuth() internal view {
        address engine = _envOrZero("BASE_SEPOLIA_PERP_ENGINE");
        address publisher = _envOrZero("BASE_SEPOLIA_IMPACT_MID_PUBLISHER");

        console2.log("Target contract           : PerpEngine");
        console2.log("Target address            :", engine);
        console2.log("Expected signer role      : PerpEngine owner (governance)");
        console2.log("Function                  : setImpactMidSource(address)");
        console2.log("Selector (bytes4)         :");
        console2.logBytes4(PerpEngineAdmin.setImpactMidSource.selector);
        console2.log("Params:");
        console2.log("  source                  :", publisher);

        bytes memory data = abi.encodeCall(PerpEngineAdmin.setImpactMidSource, (publisher));
        console2.log("Full calldata (hex)       :");
        console2.logBytes(data);

        console2.log("Expected state transition : impactMidSource = <publisher>");
        console2.log("Readback                  :");
        console2.log(
            "  cast call <PerpEngine> 'impactMidSource()(address)' --rpc-url $BASE_SEPOLIA_RPC"
        );
        console2.log("Rollback / disable path   : setImpactMidSource(<noop-EOA>) then pauseFunding()");
        console2.log("  (setImpactMidSource(address(0)) is REJECTED by the contract via InvalidImpactMidSource.");
        console2.log("   To fully kill the keeper channel: EITHER rotate to a burner EOA that never publishes,");
        console2.log("   OR set FundingConfig.isEnabled=false on each market via setFundingConfig,");
        console2.log("   OR call PerpEngine.pauseFunding() [guardian OK].)");
        bytes memory rollbackPause = abi.encodeCall(PerpEngineAdmin.pauseFunding, ());
        console2.log("  rollback (pauseFunding) calldata (hex):");
        console2.logBytes(rollbackPause);
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // ACTION 4 - PerpEngine.updateImpactMid (simulate via cast call only).
    // ---------------------------------------------------------------------

    function _logFirstUpdateImpactMid() internal view {
        address engine = _envOrZero("BASE_SEPOLIA_PERP_ENGINE");
        address publisher = _envOrZero("BASE_SEPOLIA_IMPACT_MID_PUBLISHER");
        uint256 ethMarketId = _envUintOrZero("BASE_SEPOLIA_ETH_PERP_MARKET_ID");

        console2.log("Target contract           : PerpEngine");
        console2.log("Target address            :", engine);
        console2.log("Expected signer role      : configured impact-mid publisher (msg.sender == impactMidSource)");
        console2.log("Function                  : updateImpactMid(uint256 marketId, uint128 mid1e8)");
        console2.log("Selector (bytes4)         :");
        console2.logBytes4(PerpEngineTrading.updateImpactMid.selector);
        console2.log("Params:");
        console2.log("  marketId                :", ethMarketId);
        console2.log("  mid1e8 (SAMPLE VALUE)   :", uint256(SAMPLE_MID_1E8));
        console2.log("  (operator MUST replace SAMPLE_MID_1E8 with a real off-chain TWAP before broadcast)");

        bytes memory data = abi.encodeCall(PerpEngineTrading.updateImpactMid, (ethMarketId, SAMPLE_MID_1E8));
        console2.log("Full calldata (hex)       :");
        console2.logBytes(data);

        console2.log("SIMULATE (does NOT broadcast):");
        console2.log(
            "  cast call <PerpEngine> 'updateImpactMid(uint256,uint128)' <marketId> <mid1e8> \\\n"
            "    --from <publisher> --rpc-url $BASE_SEPOLIA_RPC"
        );
        console2.log("Post-simulation readback  :");
        console2.log("  NOTE: PerpEngine does NOT currently expose a `getImpactMidSample(uint256)` public getter.");
        console2.log("  The `_impactMidSamples` mapping is `internal`; the state transition is confirmed via:");
        console2.log("    - the `ImpactMidUpdated(marketId, mid1e8, updatedAt)` event on the successful tx,");
        console2.log("    - `PerpEngine.impactMidSource()` (verifies the authorized keeper is the sender),");
        console2.log("    - and indirectly by watching funding accrual on subsequent applyTrade cycles.");
        console2.log("  If a public view is required for the closed-test, add `getImpactMidSample(uint256)` in a");
        console2.log("  follow-up PR (out of scope for Part F -- flagged in the report).");

        console2.log("Expected state transition : _impactMidSamples[marketId] = ImpactMidSample(mid1e8, block.timestamp)");
        console2.log("Rollback / disable path   :");
        console2.log("  PerpEngine.pauseFunding()  // guardian OK, halts further updateImpactMid + funding accrual");
        bytes memory rollback = abi.encodeCall(PerpEngineAdmin.pauseFunding, ());
        console2.log("  rollback calldata (hex) :");
        console2.logBytes(rollback);
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // ACTION 5 - Backend env-var checklist (OFF-CHAIN, no calldata).
    // ---------------------------------------------------------------------

    function _logClosedTestActivationSequence() internal view {
        console2.log("Target                    : deopt-v2-backend (NOT on-chain)");
        console2.log("Expected signer role      : backend deployer (Kubernetes / systemd operator)");
        console2.log("");
        console2.log("Operator checklist:");
        console2.log("  1. Set backend env vars:");
        console2.log("       PERPS_CLOSED_TEST_ENABLED=true");
        console2.log("       PERPS_CLOSED_TEST_ALLOWLIST=<comma-separated 0x... wallet addresses>");
        console2.log("  2. Restart the backend (systemd / k8s rollout).");
        console2.log("  3. Verify GET /perps/markets returns the ETH-PERP and BTC-PERP rows seeded above.");
        console2.log("  4. Submit a probe order from an allowlisted wallet:");
        console2.log("       curl -X POST ... /perps/orders  (should reach Layer 6+, NOT 503 at Layer 1).");
        console2.log("  5. Submit a probe order from a NON-allowlisted wallet:");
        console2.log("       curl -X POST ... /perps/orders");
        console2.log("       (MUST return HTTP 503 with code=PerpsNotLive -- hard fail-closed at the route.)");
        console2.log("");
        console2.log("Rollback / disable path   :");
        console2.log("  1. Set PERPS_CLOSED_TEST_ENABLED=false and restart the backend.");
        console2.log("  2. All /perps/* routes MUST immediately fall back to 503 PerpsNotLive for ALL wallets.");
        console2.log("  3. Optional on-chain kill: PerpEngine.pauseTrading() (owner) as a belt-and-braces stop.");
        console2.log("");
        console2.log("NOTE: PERPS_CLOSED_TEST_ENABLED is the ONLY on/off switch that keeps perps fail-closed at");
        console2.log("      Layer 1 (public route boundary). Do NOT rely on the allowlist alone.");
        console2.log("");
    }

    // ---------------------------------------------------------------------
    // Helpers.
    // ---------------------------------------------------------------------

    function _logSectionHeader(string memory title) internal pure {
        console2.log("");
        console2.log("--------------------------------------------------------");
        console2.log(title);
        console2.log("--------------------------------------------------------");
    }

    /// @dev Returns the env address or `address(0)` when unset, so missing
    ///      operator input surfaces as an obvious placeholder in the log.
    function _envOrZero(string memory key) internal view returns (address) {
        return vm.envOr(key, address(0));
    }

    /// @dev Returns the env uint or 0 when unset (used to detect
    ///      "market row already exists" vs "must createMarket").
    function _envUintOrZero(string memory key) internal view returns (uint256) {
        return vm.envOr(key, uint256(0));
    }

    function _streq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
