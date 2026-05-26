// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";
import {FeesManager} from "../../src/fees/FeesManager.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {IRiskModule} from "../../src/risk/IRiskModule.sol";
import {IMarginEngineState} from "../../src/risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../../src/matching/IMarginEngineTrade.sol";
import {MarginEngine} from "../../src/margin/MarginEngine.sol";

/// @notice Minimal ERC20 with configurable decimals, reused for the rewire harness.
contract RewireMockERC20 is ERC20 {
    uint8 private immutable _decimalsValue;

    constructor(string memory n_, string memory s_, uint8 d_) ERC20(n_, s_) {
        _decimalsValue = d_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal oracle.
contract RewireMockOracle is IOracle {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => PriceData) internal prices;

    function setPrice(address base_, address quote_, uint256 price, uint256 updatedAt, bool ok) external {
        prices[keccak256(abi.encode(base_, quote_))] = PriceData({price: price, updatedAt: updatedAt, ok: ok});
    }

    function getPrice(address base_, address quote_) external view returns (uint256, uint256) {
        PriceData memory d = prices[keccak256(abi.encode(base_, quote_))];
        require(d.ok, "rewire:price-not-set");
        return (d.price, d.updatedAt);
    }

    function getPriceSafe(address base_, address quote_) external view returns (uint256, uint256, bool) {
        PriceData memory d = prices[keccak256(abi.encode(base_, quote_))];
        return (d.price, d.updatedAt, d.ok);
    }
}

/// @notice Minimal risk module with a rebindable margin engine, mirroring the production
/// `RiskModuleAdmin.setMarginEngine` admin setter.
contract RewireMockRiskModule is IRiskModule {
    address public immutable override baseCollateralToken;
    uint8 public immutable override baseDecimals;
    uint256 public immutable override baseMaintenanceMarginPerContract;
    uint256 public immutable override imFactorBps;
    address public ownerAccount;
    IMarginEngineState public marginEngine;

    mapping(address => int256) internal equityByTrader;

    constructor(
        address owner_,
        address marginEngine_,
        address baseCollateralToken_,
        uint8 baseDecimals_,
        uint256 baseMm_,
        uint256 imFactor_
    ) {
        ownerAccount = owner_;
        marginEngine = IMarginEngineState(marginEngine_);
        baseCollateralToken = baseCollateralToken_;
        baseDecimals = baseDecimals_;
        baseMaintenanceMarginPerContract = baseMm_;
        imFactorBps = imFactor_;
    }

    function setMarginEngine(address newEngine) external {
        require(msg.sender == ownerAccount, "rewire:not-owner");
        marginEngine = IMarginEngineState(newEngine);
    }

    function setEquityBase(address trader, int256 equity) external {
        equityByTrader[trader] = equity;
    }

    function computeAccountRisk(address trader) public view returns (AccountRisk memory r) {
        uint256 shortContracts = marginEngine.totalShortContracts(trader);
        uint256 mm = shortContracts * baseMaintenanceMarginPerContract;
        r = AccountRisk({
            equityBase: equityByTrader[trader],
            maintenanceMarginBase: mm,
            initialMarginBase: (mm * imFactorBps) / 10_000
        });
    }

    function computeFreeCollateral(address trader) external view returns (int256) {
        AccountRisk memory r = computeAccountRisk(trader);
        return r.equityBase - int256(r.initialMarginBase);
    }

    function computeMarginRatioBps(address trader) external view returns (uint256) {
        AccountRisk memory r = computeAccountRisk(trader);
        if (r.maintenanceMarginBase == 0) return type(uint256).max;
        if (r.equityBase <= 0) return 0;
        return (uint256(r.equityBase) * 10_000) / r.maintenanceMarginBase;
    }

    function computeAccountRiskBreakdown(address trader) external view returns (AccountRiskBreakdown memory b) {
        AccountRisk memory r = computeAccountRisk(trader);
        b.equityBase = r.equityBase;
        b.maintenanceMarginBase = r.maintenanceMarginBase;
        b.initialMarginBase = r.initialMarginBase;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewWithdrawImpact(address trader, address, uint256 amount)
        external
        view
        returns (WithdrawPreview memory p)
    {
        AccountRisk memory r = computeAccountRisk(trader);
        p.requestedAmount = amount;
        p.maxWithdrawable = type(uint256).max;
        p.marginRatioBeforeBps = r.maintenanceMarginBase == 0
            ? type(uint256).max
            : r.equityBase <= 0 ? 0 : (uint256(r.equityBase) * 10_000) / r.maintenanceMarginBase;
        p.marginRatioAfterBps = p.marginRatioBeforeBps;
    }

    function computeCollateralState(address) external pure returns (CollateralState memory s) {
        return s;
    }

    function computeProductRiskState(address) external pure returns (ProductRiskState memory s) {
        return s;
    }

    function getResidualBadDebt(address) external pure returns (uint256) {
        return 0;
    }
}

    /// @title MarginEngineV2RewireForkTest
    /// @notice V2D-L fork/local end-to-end simulation of the MarginEngine redeploy + rewire sequence.
    /// @dev
    ///  The test stands up an OLD MarginEngine wired to a CollateralVault, RewireMockRiskModule, and
    ///  InsuranceFund. It places a position on OLD via the matching-engine bypass, then deploys a NEW
    ///  MarginEngine and executes every rewire setter call that `script/RewireMarginEngineV2.s.sol`
    ///  would issue against the four contracts whose state we can fully model here (Vault, RiskModule,
    ///  InsuranceFund, plus the role played by MatchingEngine/OptionMatchingEngine via direct
    ///  matchingEngine pointer rewiring). MatchingEngine/OptionMatchingEngine/RiskGovernor rewiring is
    ///  exercised by the script itself; here we verify the on-chain effects of the underlying setters.
    ///
    ///  Designed to run in two contexts:
    ///   - `forge test --match-path test/fork/MarginEngineV2RewireFork.t.sol`            (local EVM)
    ///   - `forge test --match-path test/fork/MarginEngineV2RewireFork.t.sol --fork-url $RPC_URL`
    contract MarginEngineV2RewireForkTest is Test {
        /*//////////////////////////////////////////////////////////////
                                    CONSTANTS
        //////////////////////////////////////////////////////////////*/

        uint256 internal constant PRICE_SCALE = 1e8;
        uint256 internal constant BASE_UNIT = 1e6;
        uint256 internal constant STRIKE = 2_000 * PRICE_SCALE;
        uint128 internal constant PREMIUM_PER_CONTRACT = 100 * 1e6;
        uint256 internal constant BASE_MM_PER_CONTRACT = 10 * BASE_UNIT;
        uint256 internal constant IM_FACTOR_BPS = 12_000;
        uint256 internal constant HEALTHY_EQUITY = 1_000_000 * BASE_UNIT;

        address internal constant OWNER = address(0xA11CE);
        address internal constant MATCHING_ENGINE = address(0xBEEF);
        address internal constant ALICE = address(0xA1);
        address internal constant BOB = address(0xB2);
        address internal constant FEE_RECIPIENT = address(0xFEE);
        address internal constant REBATE_FUNDING = address(0xFAB);

        /*//////////////////////////////////////////////////////////////
                                      STATE
        //////////////////////////////////////////////////////////////*/

        CollateralVault internal vault;
        OptionProductRegistry internal registry;
        InsuranceFund internal insurance;
        RewireMockOracle internal oracle;
        RewireMockRiskModule internal riskModule;
        RewireMockERC20 internal usdc;
        RewireMockERC20 internal weth;

        MarginEngine internal oldEngine;
        MarginEngine internal newEngine;

        uint256 internal callOptionId;

        /*//////////////////////////////////////////////////////////////
                                       SETUP
        //////////////////////////////////////////////////////////////*/

        function setUp() external {
            vault = new CollateralVault(OWNER);
            registry = new OptionProductRegistry(OWNER);
            oracle = new RewireMockOracle();
            usdc = new RewireMockERC20("Mock USDC", "mUSDC", 6);
            weth = new RewireMockERC20("Mock WETH", "mWETH", 18);

            // OLD MarginEngine: representative of the pre-V2D-D production deployment.
            oldEngine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));

            riskModule =
                new RewireMockRiskModule(
                OWNER, address(oldEngine), address(usdc), 6, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS
            );
            insurance = new InsuranceFund(OWNER, address(vault));

            vm.startPrank(OWNER);

            vault.setCollateralToken(address(usdc), true, 6, 10_000);
            vault.setMarginEngine(address(oldEngine));

            registry.setSettlementAssetAllowed(address(usdc), true);
            registry.setUnderlyingConfig(
                address(weth),
                OptionProductRegistry.UnderlyingConfig({
                    oracle: address(oracle),
                    spotShockDownBps: 3_000,
                    spotShockUpBps: 3_000,
                    volShockDownBps: 0,
                    volShockUpBps: 2_000,
                    isEnabled: true
                })
            );

            oldEngine.setMatchingEngine(MATCHING_ENGINE);
            oldEngine.setRiskModule(address(riskModule));
            oldEngine.setInsuranceFund(address(insurance));
            oldEngine.syncRiskParamsFromRiskModule();
            oldEngine.setLiquidationParams(10_050, 500);
            oldEngine.setLiquidationHardenParams(10_000, 1);
            oldEngine.setLiquidationPricingParams(0, 0);
            oldEngine.setLiquidationOracleMaxDelay(600);

            insurance.setBackstopCaller(address(oldEngine), true);

            vm.stopPrank();

            vm.prank(OWNER);
            callOptionId = registry.createSeries(
                address(weth), address(usdc), uint64(block.timestamp + 7 days), uint64(STRIKE), true, true
            );

            oracle.setPrice(address(weth), address(usdc), STRIKE, block.timestamp, true);

            riskModule.setEquityBase(ALICE, int256(HEALTHY_EQUITY));
            riskModule.setEquityBase(BOB, int256(HEALTHY_EQUITY));

            _deposit(ALICE, 10_000 * BASE_UNIT);
            _deposit(BOB, 10_000 * BASE_UNIT);
        }

        /*//////////////////////////////////////////////////////////////
                                      TESTS
        //////////////////////////////////////////////////////////////*/

        /// @notice The new MarginEngine constructor produces a V2D-D-compatible contract whose V2
        /// toggle is off and whose `feesManagerV2` slot is unset. This is the property that V2D-K
        /// said the live engine lacks.
        function testFork_newEngineExposesV2GettersAndIsFeeManagerV2Disabled() external {
            newEngine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));

            // The selectors exist (no revert), values are the safe defaults.
            assertEq(newEngine.useFeesManagerV2(), false, "useFeesManagerV2 default false");
            assertEq(address(newEngine.feesManagerV2()), address(0), "feesManagerV2 default zero");
            // V1 path also reachable (will be set by the deploy script after construction).
            assertEq(address(newEngine.feesManager()), address(0), "feesManager default zero");
        }

        /// @notice Walks the rewire sequence end-to-end against the four dependents we can fully
        /// model in this harness (Vault, RiskModule, InsuranceFund, and MarginEngine's own
        /// `matchingEngine` pointer that holds OPTION ingress). Asserts every before/after read.
        function testFork_rewireSequenceMovesDependentsFromOldToNew() external {
            _bootstrapNewEngine();

            // Before-state.
            assertEq(vault.marginEngine(), address(oldEngine), "vault before: OLD");
            assertTrue(vault.isAuthorizedEngine(address(oldEngine)), "vault auth before: OLD true");
            assertFalse(vault.isAuthorizedEngine(address(newEngine)), "vault auth before: NEW false");
            assertEq(address(riskModule.marginEngine()), address(oldEngine), "risk before: OLD");
            assertTrue(insurance.isBackstopCaller(address(oldEngine)), "insurance before: OLD true");
            assertFalse(insurance.isBackstopCaller(address(newEngine)), "insurance before: NEW false");

            // Rewire (mirrors RewireMarginEngineV2._applyRewire for the holders this test models).
            vm.startPrank(OWNER);
            vault.setMarginEngine(address(newEngine));
            vault.setAuthorizedEngine(address(oldEngine), false);
            vault.setAuthorizedEngine(address(newEngine), true);
            riskModule.setMarginEngine(address(newEngine));
            insurance.setBackstopCaller(address(oldEngine), false);
            insurance.setBackstopCaller(address(newEngine), true);
            vm.stopPrank();

            // After-state.
            assertEq(vault.marginEngine(), address(newEngine), "vault after: NEW");
            assertFalse(vault.isAuthorizedEngine(address(oldEngine)), "vault auth after: OLD revoked");
            assertTrue(vault.isAuthorizedEngine(address(newEngine)), "vault auth after: NEW granted");
            assertEq(address(riskModule.marginEngine()), address(newEngine), "risk after: NEW");
            assertFalse(insurance.isBackstopCaller(address(oldEngine)), "insurance after: OLD revoked");
            assertTrue(insurance.isBackstopCaller(address(newEngine)), "insurance after: NEW granted");

            // V2 stays disabled across the entire rewire.
            assertFalse(newEngine.useFeesManagerV2(), "V2 stays false");
            assertEq(address(newEngine.feesManagerV2()), address(0), "V2 manager stays zero");
        }

        /// @notice After rewire, prior positions on OLD MarginEngine remain on OLD and the NEW engine
        /// starts from a clean position slate. This is the explicit stranded-state warning V2D-L
        /// documents — the test makes the strand visible.
        function testFork_oldEnginePositionStaysOnOldAfterRewire() external {
            // Place 1 contract on OLD via the matching-engine bypass.
            vm.prank(MATCHING_ENGINE);
            oldEngine.applyTrade(
                IMarginEngineTrade.Trade({
                    buyer: ALICE,
                    seller: BOB,
                    optionId: callOptionId,
                    quantity: 1,
                    price: PREMIUM_PER_CONTRACT,
                    buyerIsMaker: true
                })
            );

            assertEq(oldEngine.positions(ALICE, callOptionId).quantity, 1, "OLD: alice +1");
            assertEq(oldEngine.positions(BOB, callOptionId).quantity, -1, "OLD: bob -1");

            // Stand up NEW and rewire dependents.
            _bootstrapNewEngine();
            vm.startPrank(OWNER);
            vault.setMarginEngine(address(newEngine));
            vault.setAuthorizedEngine(address(oldEngine), false);
            vault.setAuthorizedEngine(address(newEngine), true);
            riskModule.setMarginEngine(address(newEngine));
            insurance.setBackstopCaller(address(oldEngine), false);
            insurance.setBackstopCaller(address(newEngine), true);
            vm.stopPrank();

            // OLD positions are preserved on OLD (history readable, not migrated).
            assertEq(oldEngine.positions(ALICE, callOptionId).quantity, 1, "OLD strand: alice +1");
            assertEq(oldEngine.positions(BOB, callOptionId).quantity, -1, "OLD strand: bob -1");

            // NEW starts blank — no implicit migration.
            assertEq(newEngine.positions(ALICE, callOptionId).quantity, 0, "NEW blank: alice 0");
            assertEq(newEngine.positions(BOB, callOptionId).quantity, 0, "NEW blank: bob 0");

            // Vault funds are still in the same accounts; the matching engine just now points NEW.
            assertGt(vault.balances(ALICE, address(usdc)), 0, "alice vault balance intact");
            assertGt(vault.balances(BOB, address(usdc)), 0, "bob vault balance intact");
        }

        /// @notice After rewire, FeesManagerV2 can be deployed, wired to the NEW engine, enabled, and
        /// drive a real V2 option fee — proving the redeploy unblocks the V2D-F sequence.
        function testFork_v2WireAndTinyTradeOnNewEngineAfterRewire() external {
            _bootstrapNewEngine();

            vm.startPrank(OWNER);
            vault.setMarginEngine(address(newEngine));
            vault.setAuthorizedEngine(address(oldEngine), false);
            vault.setAuthorizedEngine(address(newEngine), true);
            riskModule.setMarginEngine(address(newEngine));
            insurance.setBackstopCaller(address(oldEngine), false);
            insurance.setBackstopCaller(address(newEngine), true);
            vm.stopPrank();

            // Deploy + wire FeesManagerV2 against NEW, mirroring V2D-F's deploy + wire scripts.
            FeesManagerV2 feesV2 = new FeesManagerV2(OWNER, FEE_RECIPIENT);
            vm.startPrank(OWNER);
            feesV2.setRebateFundingAccount(REBATE_FUNDING);
            feesV2.setFeeConsumer(address(newEngine), true);
            newEngine.setFeesManagerV2(address(feesV2));
            newEngine.setUseFeesManagerV2(true);
            vm.stopPrank();

            assertTrue(newEngine.useFeesManagerV2(), "V2 enabled on NEW");
            assertEq(address(newEngine.feesManagerV2()), address(feesV2), "feesManagerV2 wired");

            // Tiny trade on NEW exercises the V2 positive-fee path.
            vm.recordLogs();
            vm.prank(MATCHING_ENGINE);
            newEngine.applyTrade(
                IMarginEngineTrade.Trade({
                    buyer: ALICE,
                    seller: BOB,
                    optionId: callOptionId,
                    quantity: 1,
                    price: PREMIUM_PER_CONTRACT,
                    buyerIsMaker: true
                })
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();

            assertEq(newEngine.positions(ALICE, callOptionId).quantity, 1, "NEW: alice +1");
            assertEq(newEngine.positions(BOB, callOptionId).quantity, -1, "NEW: bob -1");
            assertEq(_countLogs(logs, address(feesV2), _feeChargedV2Topic()), 2, "FeeChargedV2 x2 on NEW");
            assertEq(_countLogs(logs, address(feesV2), _feeRebatedV2Topic()), 0, "no rebates");
        }

        /*//////////////////////////////////////////////////////////////
                                    INTERNALS
        //////////////////////////////////////////////////////////////*/

        function _bootstrapNewEngine() internal {
            newEngine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));

            vm.startPrank(OWNER);
            newEngine.setMatchingEngine(MATCHING_ENGINE);
            newEngine.setRiskModule(address(riskModule));
            newEngine.setInsuranceFund(address(insurance));
            // V1 feesManager is intentionally left unset on the NEW engine for this harness.
            // (The production deploy script `DeployMarginEngineV2.s.sol` always sets a non-zero V1.)
            // Cannot call syncRiskParamsFromRiskModule yet because RiskModule.marginEngine still points
            // at OLD. Instead, set risk params explicitly using the RiskModule's view (same values).
            newEngine.setRiskParams(address(usdc), BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);
            newEngine.setLiquidationParams(10_050, 500);
            newEngine.setLiquidationHardenParams(10_000, 1);
            newEngine.setLiquidationPricingParams(0, 0);
            newEngine.setLiquidationOracleMaxDelay(600);
            vm.stopPrank();
        }

        function _deposit(address trader, uint256 amount) internal {
            usdc.mint(trader, amount);
            vm.startPrank(trader);
            usdc.approve(address(vault), amount);
            vault.deposit(address(usdc), amount);
            vm.stopPrank();
        }

        function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 topic0)
            internal
            pure
            returns (uint256 count)
        {
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                    ++count;
                }
            }
        }

        function _feeChargedV2Topic() internal pure returns (bytes32) {
            return keccak256("FeeChargedV2(address,address,address,address,uint8,uint8,bool,int32,uint256,uint256)");
        }

        function _feeRebatedV2Topic() internal pure returns (bytes32) {
            return keccak256("FeeRebatedV2(address,address,address,address,uint8,uint8,int32,uint256,uint256)");
        }
    }
