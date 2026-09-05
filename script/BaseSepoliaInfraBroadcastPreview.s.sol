// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ChainlinkPriceSource} from "../src/oracle/ChainlinkPriceSource.sol";
import {PythPriceSource} from "../src/oracle/PythPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";

/// @notice PERPS_BASE_SEPOLIA_INFRA_BROADCAST_V1 — preview / fork-simulation script.
///
///         READ ONLY. This script contains NO `vm.startBroadcast()` and NO `vm.broadcast()`
///         anywhere. It exists to:
///           1. Assert chain id 84532 (Base Sepolia).
///           2. Read authoritative on-chain state (owners, current feeds, executor set).
///           3. Simulate the exact broadcast sequence against a Base Sepolia fork:
///              - deploy 4 oracle adapters
///              - reconfigure OracleRouter through the ProtocolTimelock owner
///              - rotate PerpMatchingEngine executor off the deployer EOA
///           4. Print the target, selector, calldata, estimated gas, and expected post-state
///              for every proposed transaction so the operator can build the broadcast set
///              from a separate, explicitly-authorized broadcast script.
///
///         Nothing here can move funds, enable public perps, enable closed-test access,
///         enable per-market funding, submit a perp order, or open a position.
contract BaseSepoliaInfraBroadcastPreview is Script {
    /*//////////////////////////////////////////////////////////////
                          IMMUTABLE PROTOCOL STATE
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // Canonical stack (see BASE_SEPOLIA_CLOSED_TEST_PROVISIONING_V1.md §2).
    address internal constant ORACLE_ROUTER = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant PERP_MATCHING_ENGINE = 0x774d96E5739bffadEE91508b4D3D74F5BE29F165;
    address internal constant PROTOCOL_TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    address internal constant COLLATERAL_MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant ETH_MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BTC_MWBTC = 0x9D871aC7595E8Da271E866608E5145252047967c;

    /*//////////////////////////////////////////////////////////////
                          AUTHORITATIVE ORACLE INPUTS
    //////////////////////////////////////////////////////////////*/

    // Chainlink Base Sepolia proxies. Provenance:
    //   https://reference-data-directory.vercel.app/feeds-ethereum-testnet-sepolia-base-1.json
    // Both feeds are AggregatorV3Interface with decimals()==8 and heartbeat==1200s.
    address internal constant CHAINLINK_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant CHAINLINK_BTC_USD = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;

    // Pyth Base Sepolia core contract. Provenance:
    //   https://docs.pyth.network/price-feeds/contract-addresses/evm
    address internal constant PYTH_CORE = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;

    // Pyth feed ids (chain-agnostic). Provenance:
    //   https://hermes.pyth.network/v2/price_feeds?query=ETH/USD&asset_type=crypto
    //   https://hermes.pyth.network/v2/price_feeds?query=BTC/USD&asset_type=crypto
    bytes32 internal constant PYTH_ETH_USD_FEED = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 internal constant PYTH_BTC_USD_FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    /*//////////////////////////////////////////////////////////////
                        OPERATOR-TUNABLE PARAMS
    //////////////////////////////////////////////////////////////*/

    // Chainlink heartbeat on Base Sepolia is 1200s. We set the per-feed staleness bound
    // and the global router cap to 1500s to give a 300s safety margin above heartbeat.
    // Effective delay in _readConfiguredFeed is min(nonzero feedMaxDelay, nonzero global),
    // so both must be lifted together to actually loosen the bound.
    uint32 internal constant NEW_PER_FEED_MAX_DELAY = 1500;
    uint32 internal constant NEW_GLOBAL_MAX_ORACLE_DELAY = 1500;

    // Cross-source deviation ceiling. 1000 bps = 10 %. Observed live BTC deviation
    // Chainlink vs Pyth < 0.1 %. This is generous, matching the shape used for the
    // existing mock-feed configuration (see manifest.oracles.feeds[*].max_deviation_bps).
    uint16 internal constant NEW_MAX_DEVIATION_BPS = 1000;

    // Timelock queue eta: the operator must set this to some value >= block.timestamp + minDelay
    // at queue time. This preview picks minDelay + 3600s to allow block-time drift.
    uint256 internal constant ETA_SAFETY_MARGIN = 1 hours;

    /*//////////////////////////////////////////////////////////////
                              ENTRY POINT
    //////////////////////////////////////////////////////////////*/

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "not Base Sepolia (chain id must be 84532)");

        _printHeader();
        _printOnchainPreflight();

        // Phase A: adapter deployments (permissionless).
        (address chEth, address chBtc, address pyEth, address pyBtc) = _simulateAdapterDeploys();

        _printAdapterVerification(chEth, chBtc, pyEth, pyBtc);

        // Phase B: router reconfiguration (timelock-gated).
        _simulateRouterReconfig(chEth, chBtc, pyEth, pyBtc);

        // Phase C: executor rotation (direct, deployer-signed).
        _simulateExecutorRotation();

        _printFinalSummary();
    }

    /*//////////////////////////////////////////////////////////////
                              PREFLIGHT
    //////////////////////////////////////////////////////////////*/

    function _printHeader() internal view {
        console2.log("=================================================================");
        console2.log("PERPS_BASE_SEPOLIA_INFRA_BROADCAST_V1 - preview / fork simulation");
        console2.log("=================================================================");
        console2.log("chain id           :", block.chainid);
        console2.log("block number       :", block.number);
        console2.log("block timestamp    :", block.timestamp);
        console2.log("this script BROADCASTS NOTHING. no vm.startBroadcast anywhere.");
        console2.log("");
    }

    function _printOnchainPreflight() internal view {
        console2.log("--- preflight: on-chain state ---");

        OracleRouter router = OracleRouter(ORACLE_ROUTER);
        console2.log("OracleRouter          :", ORACLE_ROUTER);
        console2.log("  owner               :", router.owner());
        console2.log("  maxOracleDelay      :", router.maxOracleDelay());
        console2.log("  paused              :", router.paused());
        console2.log("  readPaused          :", router.readPaused());
        console2.log("  configPaused        :", router.configPaused());

        OracleRouter.FeedConfig memory ethFeed = router.getFeed(ETH_MWETH, COLLATERAL_MUSDC);
        console2.log("  ETH/mUSDC.primary   :", address(ethFeed.primarySource));
        console2.log("  ETH/mUSDC.secondary :", address(ethFeed.secondarySource));
        console2.log("  ETH/mUSDC.maxDelay  :", ethFeed.maxDelay);
        console2.log("  ETH/mUSDC.maxDevBps :", ethFeed.maxDeviationBps);
        console2.log("  ETH/mUSDC.isActive  :", ethFeed.isActive);

        OracleRouter.FeedConfig memory btcFeed = router.getFeed(BTC_MWBTC, COLLATERAL_MUSDC);
        console2.log("  BTC/mUSDC.primary   :", address(btcFeed.primarySource));
        console2.log("  BTC/mUSDC.secondary :", address(btcFeed.secondarySource));
        console2.log("  BTC/mUSDC.maxDelay  :", btcFeed.maxDelay);
        console2.log("  BTC/mUSDC.maxDevBps :", btcFeed.maxDeviationBps);
        console2.log("  BTC/mUSDC.isActive  :", btcFeed.isActive);

        PerpMatchingEngine pme = PerpMatchingEngine(PERP_MATCHING_ENGINE);
        console2.log("PerpMatchingEngine    :", PERP_MATCHING_ENGINE);
        console2.log("  owner               :", pme.owner());
        console2.log("  paused              :", pme.paused());
        console2.log("  isExecutor[deployer]:", pme.isExecutor(DEPLOYER));

        ProtocolTimelock tl = ProtocolTimelock(payable(PROTOCOL_TIMELOCK));
        console2.log("ProtocolTimelock      :", PROTOCOL_TIMELOCK);
        console2.log("  owner               :", tl.owner());
        console2.log("  guardian            :", tl.guardian());
        console2.log("  minDelay (s)        :", tl.minDelay());
        console2.log("  queuePaused         :", tl.queuePaused());
        console2.log("");
    }

    /*//////////////////////////////////////////////////////////////
                       PHASE A: ADAPTER DEPLOYMENTS
    //////////////////////////////////////////////////////////////*/

    function _simulateAdapterDeploys() internal returns (address chEth, address chBtc, address pyEth, address pyBtc) {
        console2.log("--- phase A: adapter deployments (permissionless) ---");

        // Measure gas via gasleft() deltas; forge script report also captures it.
        uint256 g0;

        g0 = gasleft();
        chEth = address(new ChainlinkPriceSource(CHAINLINK_ETH_USD));
        console2.log("TX-01  new ChainlinkPriceSource(ETH/USD proxy)");
        console2.log("       constructor arg      :", CHAINLINK_ETH_USD);
        console2.log("       deployed at (sim)    :", chEth);
        console2.log("       gas used (sim)       :", g0 - gasleft());

        g0 = gasleft();
        chBtc = address(new ChainlinkPriceSource(CHAINLINK_BTC_USD));
        console2.log("TX-02  new ChainlinkPriceSource(BTC/USD proxy)");
        console2.log("       constructor arg      :", CHAINLINK_BTC_USD);
        console2.log("       deployed at (sim)    :", chBtc);
        console2.log("       gas used (sim)       :", g0 - gasleft());

        g0 = gasleft();
        pyEth = address(new PythPriceSource(PYTH_CORE, PYTH_ETH_USD_FEED));
        console2.log("TX-03  new PythPriceSource(pythCore, ETH/USD feedId)");
        console2.log("       pyth core            :", PYTH_CORE);
        console2.log("       feed id (bytes32)    :");
        console2.logBytes32(PYTH_ETH_USD_FEED);
        console2.log("       deployed at (sim)    :", pyEth);
        console2.log("       gas used (sim)       :", g0 - gasleft());

        g0 = gasleft();
        pyBtc = address(new PythPriceSource(PYTH_CORE, PYTH_BTC_USD_FEED));
        console2.log("TX-04  new PythPriceSource(pythCore, BTC/USD feedId)");
        console2.log("       pyth core            :", PYTH_CORE);
        console2.log("       feed id (bytes32)    :");
        console2.logBytes32(PYTH_BTC_USD_FEED);
        console2.log("       deployed at (sim)    :", pyBtc);
        console2.log("       gas used (sim)       :", g0 - gasleft());
        console2.log("");
    }

    function _printAdapterVerification(address chEth, address chBtc, address pyEth, address pyBtc) internal view {
        console2.log("--- phase A verify: adapter readbacks (view calls, no tx) ---");
        _readAdapter("chainlink ETH/USD", chEth);
        _readAdapter("chainlink BTC/USD", chBtc);
        _readAdapter("pyth ETH/USD     ", pyEth);
        _readAdapter("pyth BTC/USD     ", pyBtc);
        console2.log("");
    }

    function _readAdapter(string memory label, address adapter) internal view {
        (uint256 price, uint256 updatedAt) = IPriceSource(adapter).getLatestPrice();
        console2.log(label, "price(1e8) :", price);
        console2.log(label, "updatedAt  :", updatedAt);
        if (updatedAt > 0 && updatedAt <= block.timestamp) {
            console2.log(label, "age (s)    :", block.timestamp - updatedAt);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     PHASE B: ROUTER RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function _simulateRouterReconfig(address chEth, address chBtc, address pyEth, address pyBtc) internal {
        console2.log("--- phase B: OracleRouter reconfig via ProtocolTimelock ---");
        console2.log("target        :", ORACLE_ROUTER);
        console2.log("eta suggested :", block.timestamp + ProtocolTimelock(payable(PROTOCOL_TIMELOCK)).minDelay() + ETA_SAFETY_MARGIN);
        console2.log("timelock min  :", ProtocolTimelock(payable(PROTOCOL_TIMELOCK)).minDelay());
        console2.log("");

        // Print calldata for each of the 3 timelock-wrapped router calls.
        _printRouterTimelockOp(
            "TX-05",
            "setMaxOracleDelay(1500)",
            abi.encodeWithSelector(OracleRouter.setMaxOracleDelay.selector, NEW_GLOBAL_MAX_ORACLE_DELAY)
        );

        _printRouterTimelockOp(
            "TX-06",
            "setFeed(mWETH,mUSDC,chEth,pyEth,1500,1000,true)",
            abi.encodeWithSelector(
                OracleRouter.setFeed.selector,
                ETH_MWETH,
                COLLATERAL_MUSDC,
                IPriceSource(chEth),
                IPriceSource(pyEth),
                NEW_PER_FEED_MAX_DELAY,
                NEW_MAX_DEVIATION_BPS,
                true
            )
        );

        _printRouterTimelockOp(
            "TX-07",
            "setFeed(mWBTC,mUSDC,chBtc,pyBtc,1500,1000,true)",
            abi.encodeWithSelector(
                OracleRouter.setFeed.selector,
                BTC_MWBTC,
                COLLATERAL_MUSDC,
                IPriceSource(chBtc),
                IPriceSource(pyBtc),
                NEW_PER_FEED_MAX_DELAY,
                NEW_MAX_DEVIATION_BPS,
                true
            )
        );

        // Now simulate the *effect*: prank as the timelock (owner) and apply the changes.
        console2.log("--- phase B simulate: prank timelock and apply state change ---");

        OracleRouter router = OracleRouter(ORACLE_ROUTER);

        vm.startPrank(PROTOCOL_TIMELOCK);
        uint256 g0 = gasleft();
        router.setMaxOracleDelay(NEW_GLOBAL_MAX_ORACLE_DELAY);
        console2.log("TX-05 effect gas (target=router)  :", g0 - gasleft());

        g0 = gasleft();
        router.setFeed(
            ETH_MWETH,
            COLLATERAL_MUSDC,
            IPriceSource(chEth),
            IPriceSource(pyEth),
            NEW_PER_FEED_MAX_DELAY,
            NEW_MAX_DEVIATION_BPS,
            true
        );
        console2.log("TX-06 effect gas (target=router)  :", g0 - gasleft());

        g0 = gasleft();
        router.setFeed(
            BTC_MWBTC,
            COLLATERAL_MUSDC,
            IPriceSource(chBtc),
            IPriceSource(pyBtc),
            NEW_PER_FEED_MAX_DELAY,
            NEW_MAX_DEVIATION_BPS,
            true
        );
        console2.log("TX-07 effect gas (target=router)  :", g0 - gasleft());
        vm.stopPrank();
        console2.log("");

        // Postcondition readback.
        console2.log("--- phase B verify: post-state ---");
        console2.log("router.maxOracleDelay             :", router.maxOracleDelay());

        OracleRouter.FeedConfig memory ethFeed = router.getFeed(ETH_MWETH, COLLATERAL_MUSDC);
        console2.log("ETH feed.primary                  :", address(ethFeed.primarySource));
        console2.log("ETH feed.secondary                :", address(ethFeed.secondarySource));
        console2.log("ETH feed.maxDelay                 :", ethFeed.maxDelay);
        console2.log("ETH feed.maxDeviationBps          :", ethFeed.maxDeviationBps);
        console2.log("ETH feed.isActive                 :", ethFeed.isActive);
        console2.log("router.hasActiveFeed(mWETH,mUSDC) :", router.hasActiveFeed(ETH_MWETH, COLLATERAL_MUSDC));
        (uint256 pEth, uint256 tEth, bool okEth) = router.getPriceSafe(ETH_MWETH, COLLATERAL_MUSDC);
        console2.log("router.getPriceSafe ETH.price     :", pEth);
        console2.log("router.getPriceSafe ETH.updatedAt :", tEth);
        console2.log("router.getPriceSafe ETH.ok        :", okEth);

        OracleRouter.FeedConfig memory btcFeed = router.getFeed(BTC_MWBTC, COLLATERAL_MUSDC);
        console2.log("BTC feed.primary                  :", address(btcFeed.primarySource));
        console2.log("BTC feed.secondary                :", address(btcFeed.secondarySource));
        console2.log("BTC feed.isActive                 :", btcFeed.isActive);
        console2.log("router.hasActiveFeed(mWBTC,mUSDC) :", router.hasActiveFeed(BTC_MWBTC, COLLATERAL_MUSDC));
        (uint256 pBtc, uint256 tBtc, bool okBtc) = router.getPriceSafe(BTC_MWBTC, COLLATERAL_MUSDC);
        console2.log("router.getPriceSafe BTC.price     :", pBtc);
        console2.log("router.getPriceSafe BTC.updatedAt :", tBtc);
        console2.log("router.getPriceSafe BTC.ok        :", okBtc);
        console2.log("");
    }

    function _printRouterTimelockOp(string memory tag, string memory sig, bytes memory data) internal view {
        uint256 eta = block.timestamp + ProtocolTimelock(payable(PROTOCOL_TIMELOCK)).minDelay() + ETA_SAFETY_MARGIN;
        bytes32 opHash = ProtocolTimelock(payable(PROTOCOL_TIMELOCK)).hashOperationBytes(ORACLE_ROUTER, 0, data, eta);
        bytes memory queueCd =
            abi.encodeWithSelector(ProtocolTimelock.queueTransaction.selector, ORACLE_ROUTER, uint256(0), data, eta);
        bytes memory execCd =
            abi.encodeWithSelector(ProtocolTimelock.executeTransaction.selector, ORACLE_ROUTER, uint256(0), data, eta);

        console2.log(tag, sig);
        console2.log("       target (via TL)      :", ORACLE_ROUTER);
        console2.log("       value                : 0");
        console2.log("       eta (unix)           :", eta);
        console2.log("       operation hash       :");
        console2.logBytes32(opHash);
        console2.log("       router-level calldata:");
        console2.logBytes(data);
        console2.log("       queueTransaction cd  :");
        console2.logBytes(queueCd);
        console2.log("       executeTransaction cd:");
        console2.logBytes(execCd);
        console2.log("");
    }

    /*//////////////////////////////////////////////////////////////
                     PHASE C: EXECUTOR ROTATION
    //////////////////////////////////////////////////////////////*/

    function _simulateExecutorRotation() internal {
        console2.log("--- phase C: PerpMatchingEngine executor rotation (direct, owner=deployer) ---");

        address newExec = _readNewExecutorEnv();
        if (newExec == address(0)) {
            console2.log("!! NEW_PERP_MATCHING_EXECUTOR env var missing; using dummy 0xExec for calldata display.");
            newExec = 0xEeEc00000000000000000000000000000000EEEC;
        }

        PerpMatchingEngine pme = PerpMatchingEngine(PERP_MATCHING_ENGINE);

        bytes memory addCd = abi.encodeWithSelector(PerpMatchingEngine.setExecutor.selector, newExec, true);
        bytes memory revokeCd = abi.encodeWithSelector(PerpMatchingEngine.setExecutor.selector, DEPLOYER, false);

        console2.log("TX-08  setExecutor(newExecutor, true)");
        console2.log("       target               :", PERP_MATCHING_ENGINE);
        console2.log("       new executor         :", newExec);
        console2.log("       sender (must be)     :", DEPLOYER, " (PME owner)");
        console2.log("       calldata             :");
        console2.logBytes(addCd);

        console2.log("TX-09  setExecutor(deployer, false)   [revoke deployer executor role]");
        console2.log("       target               :", PERP_MATCHING_ENGINE);
        console2.log("       calldata             :");
        console2.logBytes(revokeCd);

        // Simulate effect via prank.
        vm.startPrank(DEPLOYER);
        uint256 g0 = gasleft();
        pme.setExecutor(newExec, true);
        console2.log("TX-08 effect gas               :", g0 - gasleft());
        g0 = gasleft();
        pme.setExecutor(DEPLOYER, false);
        console2.log("TX-09 effect gas               :", g0 - gasleft());
        vm.stopPrank();

        console2.log("--- phase C verify: executor set ---");
        console2.log("isExecutor[newExecutor]        :", pme.isExecutor(newExec));
        console2.log("isExecutor[deployer]           :", pme.isExecutor(DEPLOYER));
        console2.log("");
    }

    function _readNewExecutorEnv() internal view returns (address) {
        try vm.envAddress("NEW_PERP_MATCHING_EXECUTOR") returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              FINAL SUMMARY
    //////////////////////////////////////////////////////////////*/

    function _printFinalSummary() internal pure {
        console2.log("=================================================================");
        console2.log("PERPS_BASE_SEPOLIA_INFRA_BROADCAST_PACKAGE_READY (simulation only)");
        console2.log("=================================================================");
        console2.log("");
        console2.log("NEXT STEP: user must explicitly authorize broadcasting TX-01..TX-09");
        console2.log("This script did NOT broadcast. No state changed. See");
        console2.log("BASE_SEPOLIA_INFRA_BROADCAST_V1.md for the operator-facing manifest.");
    }
}
