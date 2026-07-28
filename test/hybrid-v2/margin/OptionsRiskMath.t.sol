// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsRiskMath} from "../../../src/hybrid-v2/margin/OptionsRiskMath.sol";

/// @title OptionsRiskMathTest
/// @notice `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` — unit + fuzz for the pure
///         Options margin math primitives (Part G).
contract OptionsRiskMathTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PS = 1e8;

    /*//////////////////////////////////////////////////////////////
                              INTRINSIC
    //////////////////////////////////////////////////////////////*/

    function test_intrinsic_callInTheMoney() public pure {
        // spot=110, strike=100 → intrinsic call = 10
        assertEq(OptionsRiskMath.intrinsicPerContract(110 * PS, 100 * PS, true), 10 * PS);
    }

    function test_intrinsic_callOutOfTheMoney() public pure {
        assertEq(OptionsRiskMath.intrinsicPerContract(90 * PS, 100 * PS, true), 0);
    }

    function test_intrinsic_callAtTheMoney() public pure {
        assertEq(OptionsRiskMath.intrinsicPerContract(100 * PS, 100 * PS, true), 0);
    }

    function test_intrinsic_putInTheMoney() public pure {
        assertEq(OptionsRiskMath.intrinsicPerContract(90 * PS, 100 * PS, false), 10 * PS);
    }

    function test_intrinsic_putOutOfTheMoney() public pure {
        assertEq(OptionsRiskMath.intrinsicPerContract(120 * PS, 100 * PS, false), 0);
    }

    function test_intrinsic_putAtTheMoney() public pure {
        assertEq(OptionsRiskMath.intrinsicPerContract(100 * PS, 100 * PS, false), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               STRESSED
    //////////////////////////////////////////////////////////////*/

    function test_stressed_callWithShockUp() public pure {
        // spot=100, strike=100, shockUp=25%. Stressed spot = 125 → 25 intrinsic.
        uint256 stressed = OptionsRiskMath.stressedPerContract(100 * PS, 100 * PS, true, 2500, 0);
        assertEq(stressed, 25 * PS);
    }

    function test_stressed_callAlreadyDeepITMShockUp() public pure {
        // spot=200, strike=100, shockUp=25%. Stressed spot = 250 → 150 intrinsic.
        uint256 stressed = OptionsRiskMath.stressedPerContract(200 * PS, 100 * PS, true, 2500, 0);
        assertEq(stressed, 150 * PS);
    }

    function test_stressed_callDeepOTMShockUpStillZero() public pure {
        // spot=50, strike=100, shockUp=10%. Stressed spot = 55 < 100 → 0.
        uint256 stressed = OptionsRiskMath.stressedPerContract(50 * PS, 100 * PS, true, 1000, 0);
        assertEq(stressed, 0);
    }

    function test_stressed_putWithShockDown() public pure {
        // spot=100, strike=100, shockDown=25%. Stressed spot = 75 → 25 intrinsic.
        uint256 stressed = OptionsRiskMath.stressedPerContract(100 * PS, 100 * PS, false, 0, 2500);
        assertEq(stressed, 25 * PS);
    }

    function test_stressed_putFullWipeSpot() public pure {
        // shockDown >= 100% → strikeAmount = strike (worst case).
        uint256 stressed = OptionsRiskMath.stressedPerContract(100 * PS, 100 * PS, false, 0, BPS);
        assertEq(stressed, 100 * PS);
    }

    function test_stressed_putShockOverOneHundred() public pure {
        uint256 stressed = OptionsRiskMath.stressedPerContract(100 * PS, 100 * PS, false, 0, 15_000);
        assertEq(stressed, 100 * PS);
    }

    /*//////////////////////////////////////////////////////////////
                                  MM
    //////////////////////////////////////////////////////////////*/

    function test_mm_takesMaxOfThree() public pure {
        // intrinsic=10, stressed=5, floor=3 → 10
        assertEq(OptionsRiskMath.mmPerContract(10, 5, 3), 10);
        // intrinsic=5, stressed=10, floor=3 → 10
        assertEq(OptionsRiskMath.mmPerContract(5, 10, 3), 10);
        // intrinsic=5, stressed=3, floor=10 → 10
        assertEq(OptionsRiskMath.mmPerContract(5, 3, 10), 10);
        // all zero → 0
        assertEq(OptionsRiskMath.mmPerContract(0, 0, 0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                  IM
    //////////////////////////////////////////////////////////////*/

    function test_im_equalsMmAtBps10000() public pure {
        assertEq(OptionsRiskMath.imPerContract(1234, BPS), 1234);
    }

    function test_im_ceilRounding() public pure {
        // mm=100, im=100 * 12_501 / 10_000 = 125.01 → ceil = 126
        assertEq(OptionsRiskMath.imPerContract(100, 12_501), 126);
    }

    function test_im_exactDivisionNoCeilExtra() public pure {
        // mm=100, im=100 * 15_000 / 10_000 = 150 exactly
        assertEq(OptionsRiskMath.imPerContract(100, 15_000), 150);
    }

    function test_im_ofZeroIsZero() public pure {
        assertEq(OptionsRiskMath.imPerContract(0, 15_000), 0);
        assertEq(OptionsRiskMath.imPerContract(0, BPS), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         SERIES CONTRIBUTION
    //////////////////////////////////////////////////////////////*/

    function test_seriesContribution_zeroShortIsZero() public pure {
        assertEq(OptionsRiskMath.seriesContribution(0, 12345), 0);
    }

    function test_seriesContribution_singleContractIsPerContract() public pure {
        // shortQuantity = 1e8 (= 1 contract), perContract = 500 (in 1e8 units).
        // contribution = 1e8 * 500 / 1e8 = 500.
        assertEq(OptionsRiskMath.seriesContribution(1e8, 500), 500);
    }

    function test_seriesContribution_multipleContracts() public pure {
        // 5 contracts of 1000 = 5000
        assertEq(OptionsRiskMath.seriesContribution(5e8, 1000), 5000);
    }

    /*//////////////////////////////////////////////////////////////
                              SCALING
    //////////////////////////////////////////////////////////////*/

    function test_scale1e8To1e18_decimalAgnostic() public pure {
        // 100 in 1e8 → 100 * 1e10 = 1e12
        assertEq(OptionsRiskMath.scale1e8To1e18(100, 6), 100 * 1e10);
        assertEq(OptionsRiskMath.scale1e8To1e18(100, 18), 100 * 1e10);
        assertEq(OptionsRiskMath.scale1e8To1e18(100, 0), 100 * 1e10);
    }

    function test_scale1e8To1e18_zero() public pure {
        assertEq(OptionsRiskMath.scale1e8To1e18(0, 18), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_intrinsic_symmetryWithZeroSpread(uint128 spot, uint128 strike) public pure {
        // For any spot/strike, intrinsic_call + intrinsic_put == |spot - strike|.
        // Equivalently: exactly one of intrinsic_call or intrinsic_put equals
        // |diff|, and the other equals zero.
        uint256 iCall = OptionsRiskMath.intrinsicPerContract(uint256(spot), uint256(strike), true);
        uint256 iPut = OptionsRiskMath.intrinsicPerContract(uint256(spot), uint256(strike), false);
        uint256 absDiff = spot >= strike ? uint256(spot) - uint256(strike) : uint256(strike) - uint256(spot);
        assertEq(iCall + iPut, absDiff);
        // One side is exactly zero (unless spot == strike, in which case both are zero).
        if (spot != strike) {
            assertTrue(iCall == 0 || iPut == 0);
        } else {
            assertEq(iCall, 0);
            assertEq(iPut, 0);
        }
    }

    function testFuzz_stressed_callNeverNegative(uint96 spot, uint96 strike, uint16 shockBps) public pure {
        vm.assume(shockBps <= 20_000);
        uint256 s = OptionsRiskMath.stressedPerContract(uint256(spot), uint256(strike), true, uint256(shockBps), 0);
        assertGe(s, 0);
    }

    function testFuzz_mm_alwaysGe_baseFloor(uint128 intr, uint128 stressed, uint128 floor_) public pure {
        uint256 mm = OptionsRiskMath.mmPerContract(uint256(intr), uint256(stressed), uint256(floor_));
        assertGe(mm, uint256(floor_));
        assertGe(mm, uint256(intr));
        assertGe(mm, uint256(stressed));
    }

    function testFuzz_im_alwaysGe_mmWhenFactorGeBps(uint96 mm, uint32 imFactorBps) public pure {
        vm.assume(imFactorBps >= BPS);
        vm.assume(imFactorBps <= 1_000_000); // avoid overflow
        uint256 im = OptionsRiskMath.imPerContract(uint256(mm), uint256(imFactorBps));
        assertGe(im, uint256(mm));
    }

    function testFuzz_im_ceilNeverLoses(uint96 mm, uint32 imFactorBps) public pure {
        vm.assume(imFactorBps >= BPS);
        vm.assume(imFactorBps <= 500_000);
        vm.assume(mm > 0);
        uint256 im = OptionsRiskMath.imPerContract(uint256(mm), uint256(imFactorBps));
        // im * BPS >= mm * imFactorBps  (ceil property).
        assertGe(im * BPS, uint256(mm) * uint256(imFactorBps));
        // Ceil is tight: im - 1 would fail.
        if (im > 0 && im < type(uint128).max) {
            assertLt((im - 1) * BPS, uint256(mm) * uint256(imFactorBps));
        }
    }
}
