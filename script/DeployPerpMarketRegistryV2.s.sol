// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";

/// @title DeployPerpMarketRegistryV2
/// @notice PERPS_V2_BASE_SEPOLIA_RECOVERY_DEPLOYMENT_FREEZE_V1 §7 —
///         narrow, deterministic redeployment of the PerpMarketRegistry with
///         the execution-price deviation guard support that the currently
///         deployed OLD PMR (0xb4fcf45E…) lacks.
/// @dev
///  Scope: PMR only. This script does NOT deploy a new PerpEngineV2. It does
///  NOT touch the OLD PMR, the OLD ENGINE_V2, PME_V2, RISK_V2, CLEARING_V2,
///  FMV2, Vault, or backend config.
///
///  Configuration (both markets, byte-identical to the OLD PMR live-read
///  snapshot documented in
///  docs/PERPS_V2_BASE_SEPOLIA_V2_REDEPLOY_RECOVERY_PREFLIGHT_V1.md §I,
///  plus the operator-policy execution-deviation cap):
///
///    Market 1 — ETH-PERP
///      underlying         = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02
///      settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E (mUSDC)
///      oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
///      symbol             = "ETH-PERP"
///      riskConfig         = (1000, 750, 500, 10_000_000_000, 50_000_000_000, true)
///      liquidationConfig  = (5000, 100, 50, 60)
///      fundingConfig      = (false, 0, 0, 0, 0, 0)                       ← funding disabled
///      maxExecutionDeviationBps = 100                                    ← OPERATOR POLICY
///
///    Market 2 — BTC-PERP
///      underlying         = 0x9D871aC7595E8Da271E866608E5145252047967c
///      settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E (mUSDC)
///      oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
///      symbol             = "BTC-PERP"
///      riskConfig         = (1200, 800, 400, 1_000_000_000, 10_000_000_000, true)
///      liquidationConfig  = (5000, 80, 50, 60)
///      fundingConfig      = (false, 0, 0, 0, 0, 0)
///      maxExecutionDeviationBps = 100
///
///  Broadcast gate:
///    Default (no confirmation flag): read-only preflight. Prints intended
///    calls, verifies caller authority against expected OWNER, but does NOT
///    broadcast.
///    With `PERP_MARKET_REGISTRY_V2_DEPLOY_CONFIRM=true`: broadcasts the
///    canonical sequence and verifies every readback matches the expected
///    values.
///
///  Signing model:
///    - Broadcasts via `vm.startBroadcast(deployer)` where `deployer` is the
///      `--sender` address passed by the operator on the forge CLI. This
///      keeps the private material inside the keystore
///      (`~/.foundry/keystores/deopt-deployer` per operator policy) — the
///      script never handles the key itself.
///    - The script hard-stops if `--sender` does not resolve to the expected
///      OWNER address, so a wrong keystore/account cannot silently deploy.
///
///  Required forge CLI when broadcasting:
///    forge script script/DeployPerpMarketRegistryV2.s.sol \
///      --rpc-url <BASE_SEPOLIA_RPC> \
///      --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
///      --keystore ~/.foundry/keystores/deopt-deployer \
///      --password-file /run/user/$(id -u)/deopt-deployer.pw \
///      --broadcast
///
///  Deterministic parameter overrides (optional):
///    - `PERPS_V2_MARKET1_EXECUTION_BPS`  default 100
///    - `PERPS_V2_MARKET2_EXECUTION_BPS`  default 100
///  Any override MUST be documented in the operator's activation ticket.
contract DeployPerpMarketRegistryV2 is Script {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Base Sepolia (chainId 84532).
    uint256 internal constant EXPECTED_CHAIN_ID = 84532;

    address internal constant EXPECTED_OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant PERP_ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant WETH_UNDERLYING = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant WBTC_UNDERLYING = 0x9D871aC7595E8Da271E866608E5145252047967c;

    bytes32 internal constant ETH_PERP_SYMBOL = bytes32("ETH-PERP");
    bytes32 internal constant BTC_PERP_SYMBOL = bytes32("BTC-PERP");

    uint16 internal constant DEFAULT_EXECUTION_BPS = 100;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnexpectedChain(uint256 chainId);
    error DeployerNotOwner(address deployer, address expectedOwner);
    error ExecutionBpsOutOfRange(uint256 marketId, uint16 bps);
    error MarketCreationDrift(uint256 marketId, uint256 expected);
    error ExecutionBpsReadbackMismatch(uint256 marketId, uint16 expected, uint16 actual);

    /*//////////////////////////////////////////////////////////////
                                    RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        if (block.chainid != EXPECTED_CHAIN_ID) revert UnexpectedChain(block.chainid);

        // Signing address comes from forge --sender. The keystore holds the
        // private material; the script never touches it directly.
        address deployer = msg.sender;
        if (deployer != EXPECTED_OWNER) revert DeployerNotOwner(deployer, EXPECTED_OWNER);

        uint16 market1Bps = uint16(vm.envOr("PERPS_V2_MARKET1_EXECUTION_BPS", uint256(DEFAULT_EXECUTION_BPS)));
        uint16 market2Bps = uint16(vm.envOr("PERPS_V2_MARKET2_EXECUTION_BPS", uint256(DEFAULT_EXECUTION_BPS)));
        if (market1Bps == 0 || market1Bps > 10_000) revert ExecutionBpsOutOfRange(1, market1Bps);
        if (market2Bps == 0 || market2Bps > 10_000) revert ExecutionBpsOutOfRange(2, market2Bps);

        bool confirm = vm.envOr("PERP_MARKET_REGISTRY_V2_DEPLOY_CONFIRM", false);

        _log("PMR-V2 redeploy preflight");
        _log("chainId", block.chainid);
        _log("deployer", deployer);
        _log("market1 execution bps", market1Bps);
        _log("market2 execution bps", market2Bps);
        _log("confirm flag", confirm);

        if (!confirm) {
            console2.log("PERP_MARKET_REGISTRY_V2_DEPLOY_CONFIRM=false; no broadcast");
            return;
        }

        vm.startBroadcast(deployer);

        PerpMarketRegistry pmr = new PerpMarketRegistry(deployer);
        _log("deployed PerpMarketRegistry", address(pmr));

        pmr.setSettlementAssetAllowed(MUSDC, true);

        uint256 market1Id = pmr.createMarket(
            WETH_UNDERLYING,
            MUSDC,
            PERP_ORACLE,
            ETH_PERP_SYMBOL,
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_000,
                maintenanceMarginBps: 750,
                liquidationPenaltyBps: 500,
                maxPositionSize1e8: uint128(10_000_000_000),
                maxOpenInterest1e8: uint128(50_000_000_000),
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
        if (market1Id != 1) revert MarketCreationDrift(market1Id, 1);
        pmr.setMaxExecutionDeviationBps(1, market1Bps);

        uint256 market2Id = pmr.createMarket(
            WBTC_UNDERLYING,
            MUSDC,
            PERP_ORACLE,
            BTC_PERP_SYMBOL,
            PerpMarketRegistry.RiskConfig({
                initialMarginBps: 1_200,
                maintenanceMarginBps: 800,
                liquidationPenaltyBps: 400,
                maxPositionSize1e8: uint128(1_000_000_000),
                maxOpenInterest1e8: uint128(10_000_000_000),
                reduceOnlyDuringCloseOnly: true
            }),
            PerpMarketRegistry.LiquidationConfig({
                closeFactorBps: 5_000,
                priceSpreadBps: 80,
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
        if (market2Id != 2) revert MarketCreationDrift(market2Id, 2);
        pmr.setMaxExecutionDeviationBps(2, market2Bps);

        vm.stopBroadcast();

        // Post-broadcast readback assertions.
        uint16 r1 = pmr.getMaxExecutionDeviationBps(1);
        uint16 r2 = pmr.getMaxExecutionDeviationBps(2);
        if (r1 != market1Bps) revert ExecutionBpsReadbackMismatch(1, market1Bps, r1);
        if (r2 != market2Bps) revert ExecutionBpsReadbackMismatch(2, market2Bps, r2);

        _log("PMR-V2 deployed at", address(pmr));
        _log("market1 execution bps (readback)", r1);
        _log("market2 execution bps (readback)", r2);
    }

    function _log(string memory label) internal pure {
        console2.log(label);
    }

    function _log(string memory label, uint256 v) internal pure {
        console2.log(label, v);
    }

    function _log(string memory label, address v) internal pure {
        console2.log(label, v);
    }

    function _log(string memory label, bool v) internal pure {
        console2.log(label, v);
    }
}
