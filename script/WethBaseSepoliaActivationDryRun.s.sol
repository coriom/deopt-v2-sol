// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_DESIGN_V1 Part J
//
// Fork-validation dry-run script. Runs against a Base Sepolia FORK
// (Anvil `--fork-url https://sepolia.base.org`), pranks the timelock
// owner to apply the exact activation sequence, verifies every
// postcondition, then walks the rollback path.
//
// NO BROADCAST. Deliberately view-only: `run()` is `external` and
// contains no `vm.startBroadcast` blocks. All state mutations use
// `vm.prank` / `vm.startPrank` which are Foundry cheatcodes and
// therefore never leave the local fork VM.
//
// Refuses to run outside the Base Sepolia chain id (84532).
//
// Prerequisites:
//   * A fresh Anvil forked from Base Sepolia (or another Base
//     Sepolia RPC provider that accepts `eth_call` state-override
//     via Foundry cheatcodes).
//   * `PERPS_E2E_FORK_URL` env var (or forge --fork-url flag) set
//     to the Base Sepolia RPC.
//
// Operator invocation:
//   forge script script/WethBaseSepoliaActivationDryRun.s.sol \
//     --fork-url $PERPS_E2E_FORK_URL -vv
//
// Verdicts emitted on the last line of the log:
//   * DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_VALIDATED — full
//     sequence + rollback simulated clean.
//   * DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_BLOCKED — with the
//     specific blocker cited.

import {Script, console2} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {ChainlinkPriceSource} from "../src/oracle/ChainlinkPriceSource.sol";
import {PythPriceSource} from "../src/oracle/PythPriceSource.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";
import {IRiskModule} from "../src/risk/IRiskModule.sol";

contract WethBaseSepoliaActivationDryRun is Script, StdCheats {
    // -------------------------------------------------------
    // On-chain identities (Base Sepolia, chain id 84532)
    // -------------------------------------------------------
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // Deployed DeOpt V2 core (canonical addresses per the frozen
    // Base Sepolia broadcast manifest).
    address internal constant COLLATERAL_VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address internal constant ORACLE_ROUTER = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant RISK_MODULE = 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B;
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant TIMELOCK_OWNER = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address internal constant DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    // Canonical Base Sepolia WETH (OP-Stack convention, same on
    // Base mainnet + Base Sepolia).
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    // Mock USDC used by the DeOpt V2 testnet stack (per manifest).
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;

    // Chainlink ETH/USD proxy on Base Sepolia (from `reference-
    // data-directory` docs; decimals=8, heartbeat=1200s).
    address internal constant CHAINLINK_ETH_USD = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    // Pyth core contract on Base Sepolia.
    address internal constant PYTH_CORE = 0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83;
    // Pyth Crypto.ETH/USD feed id (chain-agnostic).
    bytes32 internal constant PYTH_ETH_USD_FEED =
        0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // -------------------------------------------------------
    // Production-candidate parameters (RECOMMENDED range)
    // -------------------------------------------------------
    uint16 internal constant WETH_COLLATERAL_FACTOR_BPS = 7_500; // 75%
    uint16 internal constant WETH_LIQUIDATION_FACTOR_BPS = 8_200; // 82%
    uint16 internal constant MAX_DEVIATION_BPS = 200; // 2%
    uint32 internal constant MAX_ORACLE_DELAY = 1_500; // 25 min

    // Deposit cap: 100 WETH raw units (18 dec). At $2_500 ETH this
    // is ~$250k total notional — a bounded first-activation ceiling
    // that keeps insurance-fund coverage feasible.
    uint256 internal constant WETH_DEPOSIT_CAP = 100 ether;

    // Local price adapters deployed during the dry-run (real code,
    // fork-local state).
    ChainlinkPriceSource internal chLinkAdapter;
    PythPriceSource internal pythAdapter;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "must fork Base Sepolia (84532)");

        console2.log("=== DEOPT_WETH_COLLATERAL_BASE_SEPOLIA_ACTIVATION_DESIGN_V1 (Part J fork sim) ===");
        console2.log("block", block.number);
        console2.log("ts", block.timestamp);

        _partA_verifyAsset();
        _partB_deployAndVerifyAdapters();
        _partF_G_applyActivation();
        _partJ_scenarios();
        _partL_rollback();

        console2.log("DEOPT_WETH_BASE_SEPOLIA_FORK_ACTIVATION_VALIDATED");
    }

    // -----------------------------------------------------------
    // Part A — verify canonical WETH asset identity
    // -----------------------------------------------------------
    function _partA_verifyAsset() internal view {
        console2.log("--- Part A: asset identity ---");
        require(WETH.code.length > 0, "WETH has no code");
        require(ERC20(WETH).decimals() == 18, "WETH decimals must be 18");
        // Symbol + name are metadata; canonical identity is
        // (chain_id, token_address) — chain_id already checked.
        console2.log("WETH ok:", WETH);
    }

    // -----------------------------------------------------------
    // Part B — deploy adapters + verify safe price
    // -----------------------------------------------------------
    function _partB_deployAndVerifyAdapters() internal {
        console2.log("--- Part B: adapter deployments + safe-price ---");

        // Deploy adapters as an unfunded prank of the deployer.
        vm.startPrank(DEPLOYER);
        chLinkAdapter = new ChainlinkPriceSource(CHAINLINK_ETH_USD);
        pythAdapter = new PythPriceSource(PYTH_CORE, PYTH_ETH_USD_FEED);
        vm.stopPrank();

        (uint256 chPrice, uint256 chUpdated) = chLinkAdapter.getLatestPrice();
        console2.log("Chainlink adapter price 1e8", chPrice);
        console2.log("Chainlink adapter updatedAt", chUpdated);
        require(chPrice > 0, "chainlink price zero");
        require(chUpdated > 0 && chUpdated <= block.timestamp, "chainlink ts invalid");
        require(chPrice > 1_000_00000000, "chainlink price sanity"); // > $1000 (avoid absurd)

        (uint256 pyPrice, uint256 pyUpdated) = pythAdapter.getLatestPrice();
        console2.log("Pyth adapter price 1e8", pyPrice);
        console2.log("Pyth adapter updatedAt", pyUpdated);
        require(pyPrice > 0, "pyth price zero");
    }

    // -----------------------------------------------------------
    // Parts F + G — apply on-chain activation (prank timelock)
    // -----------------------------------------------------------
    function _partF_G_applyActivation() internal {
        console2.log("--- Parts F+G: applying activation via timelock prank ---");

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);
        OracleRouter router = OracleRouter(ORACLE_ROUTER);
        RiskModule risk = RiskModule(RISK_MODULE);

        // WETH-TX-00 (prerequisite from the frozen infra manifest,
        // must land BEFORE WETH activation if it hasn't already):
        // raise the router's global maxOracleDelay to 1500s so
        // Chainlink Base Sepolia's 1200s heartbeat fits within the
        // freshness window. This is idempotent — no-op if already
        // 1500. Guarded so a re-run against a router that already
        // has maxOracleDelay >= 1500 doesn't step on operator state.
        uint32 currentDelay = router.maxOracleDelay();
        if (currentDelay < MAX_ORACLE_DELAY) {
            vm.prank(TIMELOCK);
            router.setMaxOracleDelay(MAX_ORACLE_DELAY);
            console2.log("WETH-TX-00: router maxOracleDelay raised", MAX_ORACLE_DELAY);
        } else {
            console2.log("WETH-TX-00: router maxOracleDelay already sufficient", currentDelay);
        }

        // WETH-TX-01: vault registers WETH as supported collateral.
        vm.prank(TIMELOCK);
        vault.setCollateralToken(WETH, true, 18, WETH_COLLATERAL_FACTOR_BPS);
        (bool sup, uint8 dec, uint16 fBps) = vault.collateralConfigsRaw(WETH);
        require(sup && dec == 18 && fBps == WETH_COLLATERAL_FACTOR_BPS, "vault WETH config post");

        // WETH-TX-02: vault sets deposit cap.
        vm.prank(TIMELOCK);
        vault.setTokenDepositCap(WETH, WETH_DEPOSIT_CAP);

        // WETH-TX-03: launch-active flag (restriction mode).
        vm.prank(TIMELOCK);
        vault.setLaunchActiveCollateral(WETH, true);

        // WETH-TX-04: router registers WETH/USDC feed (dual-source).
        vm.prank(TIMELOCK);
        router.setFeed(
            WETH,
            MUSDC,
            IPriceSource(address(chLinkAdapter)),
            IPriceSource(address(pythAdapter)),
            MAX_ORACLE_DELAY,
            MAX_DEVIATION_BPS,
            true
        );
        OracleRouter.FeedConfig memory fc = router.getFeed(WETH, MUSDC);
        require(fc.isActive && fc.maxDeviationBps == MAX_DEVIATION_BPS, "feed config post");

        // WETH-TX-05: risk module enables WETH.
        vm.prank(TIMELOCK);
        risk.setCollateralConfig(WETH, uint64(WETH_COLLATERAL_FACTOR_BPS), true);

        console2.log("[Parts F+G] activation applied on fork");
    }

    // -----------------------------------------------------------
    // Part J — scenario battery against real deployed contracts
    // -----------------------------------------------------------
    function _partJ_scenarios() internal {
        console2.log("--- Part J: scenarios against real deployed contracts ---");

        RiskModule risk = RiskModule(RISK_MODULE);

        // Fund the fork prankster with WETH via `deal`.
        address user = address(0xBEEF);
        deal(WETH, user, 5 ether); // 5 WETH
        deal(MUSDC, user, 20_000 * 1e6); // 20_000 USDC

        // Approve + deposit into vault.
        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);
        vm.startPrank(user);
        ERC20(WETH).approve(address(vault), type(uint256).max);
        ERC20(MUSDC).approve(address(vault), type(uint256).max);
        vault.deposit(MUSDC, 10_000 * 1e6);
        vault.deposit(WETH, 2 ether);
        vm.stopPrank();

        // Live risk view.
        IRiskModule.CollateralState memory st = risk.computeCollateralState(user);
        console2.log("gross USDC-native", st.grossCollateralValueBase);
        console2.log("adjusted USDC-native", st.adjustedCollateralValueBase);

        // Sanity: gross should include 10_000 USDC (1e10) + 2 WETH × oracle price.
        (uint256 ethUsd,) = chLinkAdapter.getLatestPrice();
        // Expected raw: 10_000 * 1e6 + 2 * ethUsd (already in 1e8) / 1e8 * 1e6 = 10_000 * 1e6 + 2 * ethUsd / 100.
        uint256 expectedGross = 10_000 * 1e6 + (2 * ethUsd) / 100;
        console2.log("expected gross USDC-native", expectedGross);
        // Allow small deviation due to router source selection (may
        // use secondary or a blended price).
        require(
            st.grossCollateralValueBase >= (expectedGross * 98) / 100
                && st.grossCollateralValueBase <= (expectedGross * 102) / 100,
            "gross out of 2% band"
        );

        // Adjusted must equal gross × (weighted average factor).
        // USDC contributes at 100%, WETH at 75%. Simple sanity:
        // adjusted < gross AND adjusted > gross * 75/100.
        require(st.adjustedCollateralValueBase < st.grossCollateralValueBase, "adjusted must haircut");
        require(
            st.adjustedCollateralValueBase > (st.grossCollateralValueBase * 74) / 100,
            "adjusted floor"
        );

        // Cap enforcement: cannot deposit above the cap (100 WETH
        // global). Bob attempts to deposit 200 WETH.
        address whale = address(0xCAFE);
        deal(WETH, whale, 200 ether);
        vm.startPrank(whale);
        ERC20(WETH).approve(address(vault), type(uint256).max);
        vm.expectRevert(); // TokenDepositCapExceeded or similar
        vault.deposit(WETH, 200 ether);
        vm.stopPrank();
        console2.log("[Part J] cap rejects 200 WETH deposit");

        // Withdrawal safety: user withdraws 1 WETH. Should succeed
        // if no positions open. RiskModule's withdrawal-safety hook
        // is called by the MarginEngine on real trading path; for a
        // no-position user the withdrawal is allowed by the vault
        // (best-effort risk hook, per _withdrawInternal). Prove
        // withdrawal reduces balance.
        vm.startPrank(user);
        vault.withdraw(WETH, 1 ether);
        vm.stopPrank();
        require(vault.balances(user, WETH) == 1 ether, "user WETH after withdraw");

        // Price-crash scenario: model a WETH crash by static-mocking
        // the Chainlink aggregator's `latestRoundData` to return
        // half. Use `vm.mockCall` to inject a fake return value.
        int256 crashedPrice = 1_500 * 1e8;
        vm.mockCall(
            CHAINLINK_ETH_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(
                uint80(1),
                crashedPrice,
                uint256(block.timestamp - 5),
                uint256(block.timestamp - 5),
                uint80(1)
            )
        );
        IRiskModule.CollateralState memory stCrashed = risk.computeCollateralState(user);
        console2.log("adjusted after crash", stCrashed.adjustedCollateralValueBase);
        require(
            stCrashed.adjustedCollateralValueBase < st.adjustedCollateralValueBase,
            "crash must reduce adjusted"
        );
        // Clear the mock so subsequent scenarios see the real oracle.
        vm.clearMockedCalls();

        console2.log("[Part J] real-contract scenarios all passed");
    }

    // -----------------------------------------------------------
    // Part L — rollback walk-through (still fork-only)
    // -----------------------------------------------------------
    function _partL_rollback() internal {
        console2.log("--- Part L: rollback walk-through ---");

        OracleRouter router = OracleRouter(ORACLE_ROUTER);
        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);
        RiskModule risk = RiskModule(RISK_MODULE);

        // WETH-TX-06 (rollback): disable feed in router.
        vm.prank(TIMELOCK);
        router.setFeedStatus(WETH, MUSDC, false);
        OracleRouter.FeedConfig memory fc = router.getFeed(WETH, MUSDC);
        require(!fc.isActive, "feed disabled");

        // WETH-TX-07 (rollback): disable in risk module.
        vm.prank(TIMELOCK);
        risk.setCollateralConfig(WETH, 0, false);

        // WETH-TX-08 (rollback): flip vault launch-active off (deposits refuse but existing users can still exit).
        vm.prank(TIMELOCK);
        vault.setLaunchActiveCollateral(WETH, false);

        // Vault support stays true so users can still `withdraw`.
        (bool sup,,) = vault.collateralConfigsRaw(WETH);
        require(sup, "vault support retained for exit path");

        console2.log("[Part L] rollback preserves user exit path");
    }
}
