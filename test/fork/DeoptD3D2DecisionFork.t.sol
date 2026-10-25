// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../src/fees/IFeesManagerV2.sol";

interface ISeizerWiring {
    function setCollateralSeizer(address seizer) external;
    function collateralSeizer() external view returns (address);
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
}

/// @dev Isolated fork only. Timelock impersonation tests contract authority, not Safe signatures.
contract DeoptD3D2DecisionForkTest is Test {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address internal constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address internal constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address internal constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address internal constant LEGACY_RISK = 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B;
    address internal constant LEGACY_FEES = 0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f;
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;

    CollateralSeizer internal seizer;
    FeesManagerV2 internal fees;

    function setUp() public {
        string memory rpc = vm.envOr("DEOPT_POLICY_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "Set DEOPT_POLICY_FORK_RPC to a Base Sepolia RPC");
            return;
        }
        vm.createSelectFork(rpc, 49_923_585);
        assertEq(block.chainid, 84532);
        seizer = CollateralSeizer(D3);
        fees = FeesManagerV2(D2);
        assertEq(seizer.owner(), TIMELOCK);
        assertEq(fees.owner(), TIMELOCK);
    }

    function testLegacyCollateralRiskSatisfiesPlannerAbiAndC13Wiring() public {
        assertEq(address(seizer.riskModule()), LEGACY_RISK);
        assertEq(seizer.riskModule().baseCollateralToken(), MUSDC);
        (uint64 weight, bool enabled) = seizer.riskModule().collateralConfigs(MUSDC);
        assertEq(weight, 10_000);
        assertTrue(enabled);
        assertEq(seizer.tokenDiscountBps(MUSDC), 10_000);
        (address[] memory tokens, uint256[] memory amounts, uint256 covered) =
            seizer.computeSeizurePlan(address(0xBEEF), 100e6);
        assertEq(tokens.length, 0);
        assertEq(amounts.length, 0);
        assertEq(covered, 0);

        vm.prank(TIMELOCK);
        ISeizerWiring(D4).setCollateralSeizer(D3);
        assertEq(ISeizerWiring(D4).collateralSeizer(), D3);
        assertTrue(ISeizerWiring(D4).tradingPaused());
        assertTrue(ISeizerWiring(D4).liquidationPaused());
        assertTrue(ISeizerWiring(D4).fundingPaused());
        assertTrue(ISeizerWiring(D4).collateralOpsPaused());
    }

    function testD5PointerBreaksNonzeroSeizurePlanner() public {
        vm.prank(TIMELOCK);
        seizer.setRiskModule(D5);
        vm.expectRevert();
        seizer.computeSeizurePlan(address(0xBEEF), 100e6);
    }

    function testProposedMusdcSpreadMakesUnsetExplicitAndConservative() public {
        (uint16 oldSpread, bool oldEnabled, bool oldSet) = seizer.seizeConfigs(MUSDC);
        assertEq(oldSpread, 0);
        assertFalse(oldEnabled);
        assertFalse(oldSet);
        vm.prank(TIMELOCK);
        seizer.setTokenSeizeConfig(MUSDC, 5, true);
        (uint16 spread, bool enabled, bool isSet) = seizer.seizeConfigs(MUSDC);
        assertEq(spread, 5);
        assertTrue(enabled && isSet);
        assertEq(seizer.tokenDiscountBps(MUSDC), 9_995);
        (uint256 raw, uint256 effective, bool ok) = seizer.previewEffectiveBaseValue(MUSDC, 100e6);
        assertTrue(ok);
        assertEq(raw, 100e6);
        assertEq(effective, 99_950_000);
    }

    function testProposedPerpFeeProfileHasNoRebateOrLegacyLedgerImpact() public {
        for (uint8 tier; tier < 5; ++tier) {
            vm.prank(TIMELOCK);
            fees.setFeeProfile(tier, IFeesManagerV2.ProductKind.PERP, 0, 200);
            IFeesManagerV2.ProductFeeProfilePpm memory p = fees.getFeeProfile(tier, IFeesManagerV2.ProductKind.PERP);
            assertEq(p.makerPpm, 0);
            assertEq(p.takerPpm, 200);
        }
        IFeesManagerV2.FeeQuote memory maker = fees.quoteFees(
            address(0xBEEF), IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.ORDERBOOK, true, MUSDC, 100e6
        );
        IFeesManagerV2.FeeQuote memory taker = fees.quoteFees(
            address(0xBEEF), IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.ORDERBOOK, false, MUSDC, 100e6
        );
        assertEq(maker.feeAmount, 0);
        assertEq(taker.feeAmount, 20_000);
        assertEq(taker.recipient, TIMELOCK);
        assertFalse(taker.isRebate);
        vm.expectRevert(abi.encodeWithSelector(FeesManagerV2.NotFeeConsumer.selector, address(this)));
        fees.consumeFees(
            address(0xBEEF), IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.ORDERBOOK, false, MUSDC, 100e6
        );
        vm.prank(TIMELOCK);
        fees.setFeeConsumer(address(this), true);
        IFeesManagerV2.FeeQuote memory consumed = fees.consumeFees(
            address(0xBEEF), IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.ORDERBOOK, false, MUSDC, 100e6
        );
        assertEq(consumed.feeAmount, 20_000);
        assertEq(fees.rebateBudget(MUSDC), 0);
        assertEq(FeesManagerV2(LEGACY_FEES).rebateBudget(MUSDC), 999_977);
    }

    function testUnbackedMakerRebateRevertsWithoutFunding() public {
        vm.startPrank(TIMELOCK);
        fees.setFeeProfile(0, IFeesManagerV2.ProductKind.PERP, -50, 200);
        fees.setFeeConsumer(address(this), true);
        vm.stopPrank();
        vm.expectRevert(FeesManagerV2.RebateFundingAccountUnset.selector);
        fees.consumeFees(
            address(0xBEEF), IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.ORDERBOOK, true, MUSDC, 100e6
        );
        vm.prank(TIMELOCK);
        fees.setRebateFundingAccount(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(FeesManagerV2.InsufficientRebateBudget.selector, MUSDC, 0, 5_000));
        fees.consumeFees(
            address(0xBEEF), IFeesManagerV2.ProductKind.PERP, IFeesManagerV2.FlowKind.ORDERBOOK, true, MUSDC, 100e6
        );
        assertEq(fees.rebateBudget(MUSDC), 0);
        assertEq(FeesManagerV2(LEGACY_FEES).rebateBudget(MUSDC), 999_977);
    }
}
