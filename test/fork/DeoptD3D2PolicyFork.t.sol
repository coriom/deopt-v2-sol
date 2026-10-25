// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../src/fees/IFeesManagerV2.sol";

interface IMaintenanceReadback {
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
}

interface IPauseReadback {
    function paused() external view returns (bool);
}

/// @dev Fork-only policy rehearsal. Values used to exercise setters are synthetic,
///      not approved governance parameters. No Safe signatures are tested.
contract DeoptD3D2PolicyForkTest is Test {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address internal constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address internal constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address internal constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address internal constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant LEGACY_FEES = 0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f;
    uint256 internal constant REVIEW_BLOCK = 49_914_620;

    CollateralSeizer internal seizer;
    FeesManagerV2 internal fees;

    function setUp() public {
        string memory rpc = vm.envOr("DEOPT_POLICY_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "Set DEOPT_POLICY_FORK_RPC to a Base Sepolia RPC for this focused fork suite");
            return;
        }
        vm.createSelectFork(rpc, REVIEW_BLOCK);
        assertEq(block.chainid, 84532);
        seizer = CollateralSeizer(D3);
        fees = FeesManagerV2(D2);
        assertEq(seizer.owner(), TIMELOCK);
        assertEq(fees.owner(), TIMELOCK);
    }

    function _assertMaintenance() internal view {
        IMaintenanceReadback engine = IMaintenanceReadback(D4);
        assertTrue(engine.tradingPaused());
        assertTrue(engine.liquidationPaused());
        assertTrue(engine.fundingPaused());
        assertTrue(engine.collateralOpsPaused());
        assertTrue(IPauseReadback(D6).paused());
    }

    function testD3SyntheticValidTokenConfigPreservesMaintenance() public {
        (,, bool isSetBefore) = seizer.seizeConfigs(MUSDC);
        assertFalse(isSetBefore);
        // Unset does not mean disabled: the live legacy risk weight is 100%.
        assertEq(seizer.tokenDiscountBps(MUSDC), 10_000);
        // 5 bps is a test vector only. Governance must approve an exact spread.
        vm.prank(TIMELOCK);
        seizer.setTokenSeizeConfig(MUSDC, 5, true);
        (uint16 spread, bool enabled, bool isSet) = seizer.seizeConfigs(MUSDC);
        assertEq(spread, 5);
        assertTrue(enabled && isSet);
        assertEq(seizer.tokenDiscountBps(MUSDC), 9_995);
        _assertMaintenance();
        assertFalse(fees.isFeeConsumer(D4));
    }

    function testD3SetterAcceptsUnsupportedAddressButValuationRejectsIt() public {
        address unsupportedToken = address(0xBEEF);
        vm.prank(TIMELOCK);
        seizer.setTokenSeizeConfig(unsupportedToken, 5, true);
        (,, bool isSet) = seizer.seizeConfigs(unsupportedToken);
        assertTrue(isSet);
        assertEq(seizer.tokenDiscountBps(unsupportedToken), 0);
        vm.expectRevert(abi.encodeWithSelector(CollateralSeizer.TokenNotSupportedInVault.selector, unsupportedToken));
        seizer.previewEffectiveBaseValue(unsupportedToken, 1);
    }

    function testD3RejectsWrongCallerZeroTokenAndExcessSpread() public {
        vm.expectRevert(CollateralSeizer.NotAuthorized.selector);
        vm.prank(address(0xBEEF));
        seizer.setTokenSeizeConfig(MUSDC, 5, true);
        vm.expectRevert(CollateralSeizer.ZeroAddress.selector);
        vm.prank(TIMELOCK);
        seizer.setTokenSeizeConfig(address(0), 5, true);
        vm.expectRevert(CollateralSeizer.SpreadOutOfRange.selector);
        vm.prank(TIMELOCK);
        seizer.setTokenSeizeConfig(MUSDC, 10_001, true);
        (,, bool isSetAfter) = seizer.seizeConfigs(MUSDC);
        assertFalse(isSetAfter);
    }

    function testD3FutureD5RiskPointerIsAbiIncompatible() public {
        vm.prank(TIMELOCK);
        seizer.setRiskModule(D5);
        vm.expectRevert();
        seizer.tokenDiscountBps(MUSDC);
        _assertMaintenance();
    }

    function testD2SyntheticValidFeeProfilePreservesLegacyBudget() public {
        IFeesManagerV2.ProductFeeProfilePpm memory beforeProfile =
            fees.getFeeProfile(0, IFeesManagerV2.ProductKind.PERP);
        assertEq(beforeProfile.makerPpm, 50);
        assertEq(beforeProfile.takerPpm, 300);
        uint256 legacyBudget = FeesManagerV2(LEGACY_FEES).rebateBudget(MUSDC);
        // Synthetic test vector only; the fee policy remains undecided.
        vm.prank(TIMELOCK);
        fees.setFeeProfile(0, IFeesManagerV2.ProductKind.PERP, 50, 299);
        IFeesManagerV2.ProductFeeProfilePpm memory afterProfile = fees.getFeeProfile(0, IFeesManagerV2.ProductKind.PERP);
        assertEq(afterProfile.makerPpm, 50);
        assertEq(afterProfile.takerPpm, 299);
        assertEq(FeesManagerV2(LEGACY_FEES).rebateBudget(MUSDC), legacyBudget);
        assertEq(fees.rebateBudget(MUSDC), 0);
        assertFalse(fees.isFeeConsumer(D4));
        _assertMaintenance();
    }

    function testD2RejectsWrongCallerInvalidTierRatesAndRecipient() public {
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        vm.prank(address(0xBEEF));
        fees.setFeeRecipient(address(0xCAFE));
        vm.expectRevert(FeesManagerV2.ZeroAddress.selector);
        vm.prank(TIMELOCK);
        fees.setFeeRecipient(address(0));
        vm.expectRevert(FeesManagerV2.InvalidTier.selector);
        vm.prank(TIMELOCK);
        fees.setFeeProfile(5, IFeesManagerV2.ProductKind.PERP, 0, 300);
        vm.expectRevert(FeesManagerV2.InvalidFeeRate.selector);
        vm.prank(TIMELOCK);
        fees.setFeeProfile(0, IFeesManagerV2.ProductKind.PERP, -1_001, 300);
        assertEq(fees.feeRecipient(), TIMELOCK);
    }
}
