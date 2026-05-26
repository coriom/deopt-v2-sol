// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {FeesManager} from "../../src/fees/FeesManager.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../src/fees/IFeesManagerV2.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {IRiskModule} from "../../src/risk/IRiskModule.sol";
import {IMarginEngineState} from "../../src/risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../../src/matching/IMarginEngineTrade.sol";
import {MarginEngine} from "../../src/margin/MarginEngine.sol";
import {MarginEngineTypes} from "../../src/margin/MarginEngineTypes.sol";

/// @notice Minimal ERC20 with configurable decimals, used by the fork harness.
contract ForkMockERC20 is ERC20 {
    uint8 private immutable _decimalsValue;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal oracle implementation; the V2 option fee path does not consult prices.
contract ForkMockOracle is IOracle {
    struct PriceData {
        uint256 price;
        uint256 updatedAt;
        bool ok;
    }

    mapping(bytes32 => PriceData) internal prices;

    function setPrice(address base_, address quote_, uint256 price, uint256 updatedAt, bool ok) external {
        prices[keccak256(abi.encode(base_, quote_))] = PriceData({price: price, updatedAt: updatedAt, ok: ok});
    }

    function getPrice(address base_, address quote_) external view returns (uint256 price, uint256 updatedAt) {
        PriceData memory data = prices[keccak256(abi.encode(base_, quote_))];
        require(data.ok, "fork:price-not-set");
        return (data.price, data.updatedAt);
    }

    function getPriceSafe(address base_, address quote_)
        external
        view
        returns (uint256 price, uint256 updatedAt, bool ok)
    {
        PriceData memory data = prices[keccak256(abi.encode(base_, quote_))];
        return (data.price, data.updatedAt, data.ok);
    }
}

/// @notice Minimal risk module; the V2 option fee path does not exercise risk math, but the
/// engine still calls into it for IM enforcement after the trade applies.
contract ForkMockRiskModule is IRiskModule {
    IMarginEngineState internal immutable marginState;
    address public immutable override baseCollateralToken;
    uint8 public immutable override baseDecimals;
    uint256 public immutable override baseMaintenanceMarginPerContract;
    uint256 public immutable override imFactorBps;

    mapping(address => int256) internal equityByTrader;

    constructor(
        address marginState_,
        address baseCollateralToken_,
        uint8 baseDecimals_,
        uint256 baseMaintenanceMarginPerContract_,
        uint256 imFactorBps_
    ) {
        marginState = IMarginEngineState(marginState_);
        baseCollateralToken = baseCollateralToken_;
        baseDecimals = baseDecimals_;
        baseMaintenanceMarginPerContract = baseMaintenanceMarginPerContract_;
        imFactorBps = imFactorBps_;
    }

    function setEquityBase(address trader, int256 equityBase_) external {
        equityByTrader[trader] = equityBase_;
    }

    function computeAccountRisk(address trader) public view returns (AccountRisk memory risk) {
        uint256 shortContracts = marginState.totalShortContracts(trader);
        uint256 mmBase = shortContracts * baseMaintenanceMarginPerContract;
        risk = AccountRisk({
            equityBase: equityByTrader[trader],
            maintenanceMarginBase: mmBase,
            initialMarginBase: (mmBase * imFactorBps) / 10_000
        });
    }

    function computeFreeCollateral(address trader) external view returns (int256) {
        AccountRisk memory risk = computeAccountRisk(trader);
        return risk.equityBase - int256(risk.initialMarginBase);
    }

    function computeMarginRatioBps(address trader) external view returns (uint256) {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.maintenanceMarginBase == 0) return type(uint256).max;
        if (risk.equityBase <= 0) return 0;
        return (uint256(risk.equityBase) * 10_000) / risk.maintenanceMarginBase;
    }

    function computeAccountRiskBreakdown(address trader) external view returns (AccountRiskBreakdown memory b) {
        AccountRisk memory risk = computeAccountRisk(trader);
        b.equityBase = risk.equityBase;
        b.maintenanceMarginBase = risk.maintenanceMarginBase;
        b.initialMarginBase = risk.initialMarginBase;
    }

    function getWithdrawableAmount(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function previewWithdrawImpact(address trader, address, uint256 amount)
        external
        view
        returns (WithdrawPreview memory preview)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        preview.requestedAmount = amount;
        preview.maxWithdrawable = type(uint256).max;
        preview.marginRatioBeforeBps = risk.maintenanceMarginBase == 0
            ? type(uint256).max
            : risk.equityBase <= 0 ? 0 : (uint256(risk.equityBase) * 10_000) / risk.maintenanceMarginBase;
        preview.marginRatioAfterBps = preview.marginRatioBeforeBps;
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

    /// @title FeesManagerV2OptionForkTest
    /// @notice V2D-G end-to-end simulation of the FeesManagerV2 option integration.
    /// @dev
    ///  The test harness deploys real `FeesManagerV2`, real `MarginEngine`, real `CollateralVault`,
    ///  and real `OptionProductRegistry`. Oracle and risk module are mocked because they are
    ///  outside the V2 option fee path under test — the fee logic itself is exercised through
    ///  `MarginEngine.applyTrade -> FeesManagerV2.consumeFees`, never faked.
    ///
    ///  Designed to run in two contexts:
    ///   - `forge test --match-path test/fork/FeesManagerV2OptionFork.t.sol`           (local EVM)
    ///   - `forge test --match-path test/fork/FeesManagerV2OptionFork.t.sol --fork-url $RPC_URL`
    ///
    ///  Under `--fork-url`, this proves Base Sepolia EVM compatibility (chainid, block timestamp,
    ///  opcode availability) for the entire deploy + wire + execute sequence without broadcasting.
    contract FeesManagerV2OptionForkTest is Test {
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

        uint256 internal constant V2_VOLUME_28D = 25_000_000 * BASE_UNIT;
        uint32 internal constant V2_VOLUME_SHARE_PPM = 50_000;
        uint256 internal constant V2_STAKED_DEOPT = 250_000e8;

        address internal constant OWNER = address(0xA11CE);
        address internal constant MATCHING_ENGINE = address(0xBEEF);
        address internal constant ALICE = address(0xA1);
        address internal constant BOB = address(0xB2);
        address internal constant CAROL = address(0xC3);
        address internal constant FEE_RECIPIENT = address(0xFEE);
        address internal constant REBATE_FUNDING = address(0xFAB);

        /*//////////////////////////////////////////////////////////////
                                      STATE
        //////////////////////////////////////////////////////////////*/

        CollateralVault internal vault;
        OptionProductRegistry internal registry;
        MarginEngine internal engine;
        ForkMockOracle internal oracle;
        ForkMockRiskModule internal riskModule;
        FeesManager internal feesManagerV1;
        FeesManagerV2 internal feesManagerV2;
        ForkMockERC20 internal usdc;
        ForkMockERC20 internal weth;

        uint256 internal callOptionId;

        /*//////////////////////////////////////////////////////////////
                                       SETUP
        //////////////////////////////////////////////////////////////*/

        function setUp() external {
            vault = new CollateralVault(OWNER);
            registry = new OptionProductRegistry(OWNER);
            oracle = new ForkMockOracle();
            engine = new MarginEngine(OWNER, address(registry), address(vault), address(oracle));

            usdc = new ForkMockERC20("Mock USDC", "mUSDC", 6);
            weth = new ForkMockERC20("Mock WETH", "mWETH", 18);

            riskModule = new ForkMockRiskModule(address(engine), address(usdc), 6, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);

            vm.startPrank(OWNER);
            vault.setCollateralToken(address(usdc), true, 6, 10_000);
            vault.setMarginEngine(address(engine));

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

            engine.setMatchingEngine(MATCHING_ENGINE);
            engine.setRiskModule(address(riskModule));
            engine.syncRiskParamsFromRiskModule();
            engine.setLiquidationParams(10_050, 500);
            engine.setLiquidationHardenParams(10_000, 1);
            engine.setLiquidationPricingParams(0, 0);
            engine.setLiquidationOracleMaxDelay(600);
            vm.stopPrank();

            vm.prank(OWNER);
            callOptionId = registry.createSeries(
                address(weth), address(usdc), uint64(block.timestamp + 7 days), uint64(STRIKE), true, true
            );

            oracle.setPrice(address(weth), address(usdc), STRIKE, block.timestamp, true);

            riskModule.setEquityBase(ALICE, int256(HEALTHY_EQUITY));
            riskModule.setEquityBase(BOB, int256(HEALTHY_EQUITY));
            riskModule.setEquityBase(CAROL, int256(HEALTHY_EQUITY));
            riskModule.setEquityBase(REBATE_FUNDING, int256(HEALTHY_EQUITY));

            _deposit(ALICE, 10_000 * BASE_UNIT);
            _deposit(BOB, 10_000 * BASE_UNIT);
            _deposit(CAROL, 10_000 * BASE_UNIT);
            _deposit(REBATE_FUNDING, 10_000 * BASE_UNIT);
        }

        /*//////////////////////////////////////////////////////////////
                                      TESTS
        //////////////////////////////////////////////////////////////*/

        /// @notice Verifies the deploy + wire + enable sequence step by step and asserts
        /// every read-only invariant the V2D-F wiring script checks before enabling V2.
        function testFork_deployWireAndEnableSequence() external {
            // 1) deploy FeesManagerV2 in the fork environment (no broadcast).
            feesManagerV2 = new FeesManagerV2(OWNER, FEE_RECIPIENT);
            assertEq(feesManagerV2.owner(), OWNER, "owner");
            assertEq(feesManagerV2.feeRecipient(), FEE_RECIPIENT, "feeRecipient");
            assertEq(feesManagerV2.rebateFundingAccount(), address(0), "rebateFundingAccount initial");

            // 2) operator sets the rebate funding account (must be nonzero before V2 is enabled).
            vm.prank(OWNER);
            feesManagerV2.setRebateFundingAccount(REBATE_FUNDING);
            assertEq(feesManagerV2.rebateFundingAccount(), REBATE_FUNDING, "rebateFundingAccount set");

            // 3) wire engine -> V2 manager.
            assertEq(address(engine.feesManagerV2()), address(0), "engine.feesManagerV2 pre-wire");
            vm.prank(OWNER);
            engine.setFeesManagerV2(address(feesManagerV2));
            assertEq(address(engine.feesManagerV2()), address(feesManagerV2), "engine.feesManagerV2 post-wire");

            // 4) authorize the engine as a fee consumer.
            assertFalse(feesManagerV2.isFeeConsumer(address(engine)), "isFeeConsumer pre");
            vm.prank(OWNER);
            feesManagerV2.setFeeConsumer(address(engine), true);
            assertTrue(feesManagerV2.isFeeConsumer(address(engine)), "isFeeConsumer post");

            // 5) V1 default is preserved until V2 is explicitly enabled.
            assertFalse(engine.useFeesManagerV2(), "useFeesManagerV2 still false post-wire");

            // 6) enabling V2 is a separate explicit step (fork-only; live contracts must remain V1).
            vm.prank(OWNER);
            engine.setUseFeesManagerV2(true);
            assertTrue(engine.useFeesManagerV2(), "useFeesManagerV2 enabled");
        }

        /// @notice Premium transfer and positions still update when V2 is wired but not enabled,
        /// and no V2 fee event is emitted on the trade.
        function testFork_v1RemainsDefaultWhenV2NotEnabled() external {
            _configureV2Fees({enable: false});

            assertFalse(engine.useFeesManagerV2(), "default V1");

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(FEE_RECIPIENT, address(usdc));

            vm.recordLogs();
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // V1 default behavior: no fee manager wired in this configuration path,
            // so the only cashflow is the premium from buyer to seller.
            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore - PREMIUM_PER_CONTRACT, "alice balance");
            assertEq(vault.balances(BOB, address(usdc)), bobBefore + PREMIUM_PER_CONTRACT, "bob balance");
            assertEq(vault.balances(FEE_RECIPIENT, address(usdc)), recipientBefore, "no fee recipient credit");

            // Positions still update normally.
            assertEq(engine.positions(ALICE, callOptionId).quantity, 1, "alice qty");
            assertEq(engine.positions(BOB, callOptionId).quantity, -1, "bob qty");

            // No V2 fee/rebate events were emitted.
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 0, "no FeeChargedV2");
            assertEq(_countLogs(logs, address(feesManagerV2), _feeRebatedV2Topic()), 0, "no FeeRebatedV2");
            assertEq(_countLogs(logs, address(feesManagerV2), _rebateBudgetSpentTopic()), 0, "no RebateBudgetSpent");
        }

        /// @notice Real `FeesManagerV2.consumeFees` path on a positive fee trade transfers fees from
        /// both sides into `feeRecipient`, leaves positions in sync, and emits two `FeeChargedV2`.
        function testFork_positiveOptionFeesTransferAndPositionsUpdate() external {
            _configureV2Fees({enable: true});

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 recipientBefore = vault.balances(FEE_RECIPIENT, address(usdc));

            vm.recordLogs();
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // tier0 launch schedule: option maker = 50 ppm, option taker = 250 ppm on 100_000_000 wei.
            uint256 makerFeeV2 = 5_000; // ceil(100e6 * 50 / 1e6)
            uint256 takerFeeV2 = 25_000; // ceil(100e6 * 250 / 1e6)

            assertEq(
                vault.balances(ALICE, address(usdc)),
                aliceBefore - PREMIUM_PER_CONTRACT - makerFeeV2,
                "alice paid premium + maker fee"
            );
            assertEq(
                vault.balances(BOB, address(usdc)),
                bobBefore + PREMIUM_PER_CONTRACT - takerFeeV2,
                "bob received premium less taker fee"
            );
            assertEq(
                vault.balances(FEE_RECIPIENT, address(usdc)),
                recipientBefore + makerFeeV2 + takerFeeV2,
                "recipient credit"
            );

            assertEq(engine.positions(ALICE, callOptionId).quantity, 1, "alice qty");
            assertEq(engine.positions(BOB, callOptionId).quantity, -1, "bob qty");

            // Two FeeChargedV2 events (one per side), no rebates, no budget spent.
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 2, "FeeChargedV2 count");
            assertEq(_countLogs(logs, address(feesManagerV2), _feeRebatedV2Topic()), 0, "FeeRebatedV2 count");
            assertEq(_countLogs(logs, address(feesManagerV2), _rebateBudgetSpentTopic()), 0, "RebateBudgetSpent count");
        }

        /// @notice With a funded budget, a Tier4 maker receives a real rebate from the funding account
        /// and the budget is decremented exactly by the rebate amount.
        function testFork_makerRebatePathWithFundedBudget() external {
            _configureV2Fees({enable: true});
            _claimV2Tier(ALICE, 4);

            vm.prank(OWNER);
            feesManagerV2.fundRebateBudget(address(usdc), 10_000);
            uint256 budgetBefore = feesManagerV2.rebateBudget(address(usdc));
            assertEq(budgetBefore, 10_000, "budget seeded");

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 fundingBefore = vault.balances(REBATE_FUNDING, address(usdc));
            uint256 recipientBefore = vault.balances(FEE_RECIPIENT, address(usdc));

            vm.recordLogs();
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            // ALICE (maker) is Tier4 -> -50 ppm rebate.
            // BOB (taker) has not claimed a tier and remains on Tier0 -> 250 ppm taker fee.
            uint256 makerRebate = 5_000; // floor(100e6 * 50 / 1e6)
            uint256 takerFee = 25_000; // ceil(100e6 * 250 / 1e6)

            assertEq(
                vault.balances(ALICE, address(usdc)),
                aliceBefore - PREMIUM_PER_CONTRACT + makerRebate,
                "alice paid premium, received maker rebate"
            );
            assertEq(
                vault.balances(BOB, address(usdc)),
                bobBefore + PREMIUM_PER_CONTRACT - takerFee,
                "bob received premium less taker fee"
            );
            assertEq(
                vault.balances(REBATE_FUNDING, address(usdc)), fundingBefore - makerRebate, "funding account debited"
            );
            assertEq(vault.balances(FEE_RECIPIENT, address(usdc)), recipientBefore + takerFee, "fee recipient credit");

            assertEq(feesManagerV2.rebateBudget(address(usdc)), budgetBefore - makerRebate, "budget decremented");

            assertEq(_countLogs(logs, address(feesManagerV2), _feeRebatedV2Topic()), 1, "one FeeRebatedV2");
            assertEq(_countLogs(logs, address(feesManagerV2), _feeChargedV2Topic()), 1, "one FeeChargedV2");
            assertEq(_countLogs(logs, address(feesManagerV2), _rebateBudgetSpentTopic()), 1, "one RebateBudgetSpent");
        }

        /// @notice Strict launch policy: when budget cannot fund the full rounded-down rebate,
        /// the entire trade reverts and nothing is touched (positions, balances, budget).
        function testFork_insufficientRebateBudgetRevertsTrade() external {
            _configureV2Fees({enable: true});
            _claimV2Tier(ALICE, 4);

            vm.prank(OWNER);
            feesManagerV2.fundRebateBudget(address(usdc), 4_999);

            uint256 aliceBefore = vault.balances(ALICE, address(usdc));
            uint256 bobBefore = vault.balances(BOB, address(usdc));
            uint256 fundingBefore = vault.balances(REBATE_FUNDING, address(usdc));

            vm.expectRevert(
                abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, address(usdc), 4_999, 5_000)
            );
            _trade(ALICE, BOB, callOptionId, 1, PREMIUM_PER_CONTRACT);

            // Whole trade rolled back: positions, balances, and budget unchanged.
            assertEq(engine.positions(ALICE, callOptionId).quantity, 0, "alice qty rolled back");
            assertEq(engine.positions(BOB, callOptionId).quantity, 0, "bob qty rolled back");
            assertEq(vault.balances(ALICE, address(usdc)), aliceBefore, "alice balance unchanged");
            assertEq(vault.balances(BOB, address(usdc)), bobBefore, "bob balance unchanged");
            assertEq(vault.balances(REBATE_FUNDING, address(usdc)), fundingBefore, "funding balance unchanged");
            assertEq(feesManagerV2.rebateBudget(address(usdc)), 4_999, "budget unchanged");
        }

        /*//////////////////////////////////////////////////////////////
                                    INTERNALS
        //////////////////////////////////////////////////////////////*/

        function _configureV2Fees(bool enable) internal {
            if (address(feesManagerV2) == address(0)) {
                feesManagerV2 = new FeesManagerV2(OWNER, FEE_RECIPIENT);
            }

            vm.startPrank(OWNER);
            feesManagerV2.setFeeConsumer(address(engine), true);
            feesManagerV2.setRebateFundingAccount(REBATE_FUNDING);
            engine.setFeesManagerV2(address(feesManagerV2));
            if (enable) {
                engine.setUseFeesManagerV2(true);
            }
            vm.stopPrank();
        }

        function _claimV2Tier(address account, uint8 tier) internal {
            uint64 validFrom = uint64(block.timestamp);
            uint64 validUntil = uint64(block.timestamp + 1 days);
            bytes32 root = feesManagerV2.hashTierLeaf(
                account, tier, V2_VOLUME_28D, V2_VOLUME_SHARE_PPM, V2_STAKED_DEOPT, validFrom, validUntil
            );

            vm.prank(OWNER);
            feesManagerV2.setMerkleRoot(root, validFrom, validUntil);

            vm.prank(account);
            feesManagerV2.claimTier(
                account,
                tier,
                V2_VOLUME_28D,
                V2_VOLUME_SHARE_PPM,
                V2_STAKED_DEOPT,
                validFrom,
                validUntil,
                new bytes32[](0)
            );
        }

        function _trade(address buyer, address seller, uint256 optionId, uint128 quantity, uint128 premiumPerContract)
            internal
        {
            vm.prank(MATCHING_ENGINE);
            engine.applyTrade(
                IMarginEngineTrade.Trade({
                    buyer: buyer,
                    seller: seller,
                    optionId: optionId,
                    quantity: quantity,
                    price: premiumPerContract,
                    buyerIsMaker: true
                })
            );
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

        function _rebateBudgetSpentTopic() internal pure returns (bytes32) {
            return keccak256("RebateBudgetSpent(address,uint256)");
        }
    }
