// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTradingV2} from "../../src/perp/PerpEngineTradingV2.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";

/// @notice Exact reviewed initcode is supplied from the non-secret D4 preparation artifact.
///         The fork and CREATE remain local to forge test; no broadcast path exists here.
contract PerpsV2ReplacementD4PreparationTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant PMR = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address constant SEIZER = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    bytes32 constant RUNTIME_HASH = 0x1ee5dc2756bea85a4ab327ff69f8652ef6aa0acf2883f00ad1a23c7f51f95785;
    bytes32 constant INITCODE_HASH = 0xa5e5dd10ae2aa241993192c0fcb13c817ecf98cd804fb1bc5b14f6f6068c6e7c;

    function testExactD4LocalCreationAndInitialSafety() public {
        vm.createSelectFork(vm.envString("DEOPT_REPLACEMENT_RPC"), 47_875_958);
        assertEq(block.chainid, 84532);

        bytes memory initcode = vm.envBytes("D4_CREATION_DATA");
        assertEq(initcode.length, 25_431);
        assertEq(keccak256(initcode), INITCODE_HASH);
        bytes memory constructorArgs = abi.encode(TIMELOCK, PMR, VAULT, ORACLE);
        for (uint256 i; i < constructorArgs.length; ++i) {
            assertEq(initcode[initcode.length - constructorArgs.length + i], constructorArgs[i]);
        }

        uint256 clearingBefore = CollateralVault(VAULT).balances(CLEARING, TOKEN);
        bytes32 pmrCodeBefore = PMR.codehash;
        bytes32 vaultCodeBefore = VAULT.codehash;
        bytes32 insuranceCodeBefore = INSURANCE.codehash;
        assertFalse(CollateralVault(VAULT).isEngineAuthorized(DEPLOYER));

        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertTrue(deployed != address(0));
        assertGt(deployed.code.length, 0);
        assertEq(deployed.codehash, RUNTIME_HASH);
        PerpEngineV2 engine = PerpEngineV2(deployed);

        assertEq(engine.owner(), TIMELOCK);
        assertEq(engine.pendingOwner(), address(0));
        assertEq(engine.guardian(), TIMELOCK);
        assertEq(engine.marketRegistry(), PMR);
        assertEq(engine.collateralVault(), VAULT);
        assertEq(engine.oracle(), ORACLE);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertEq(address(engine.feesManagerV2()), address(0));
        assertFalse(engine.useFeesManagerV2());
        assertEq(engine.collateralSeizer(), address(0));
        assertEq(engine.insuranceFund(), address(0));
        assertEq(engine.clearingAccount(), address(0));
        assertEq(engine.impactMidSource(), address(0));
        assertEq(uint8(engine.migrationState()), 0);
        assertEq(engine.migrationSnapshotHash(), bytes32(0));
        assertEq(engine.getTraderMarketsLength(DEPLOYER), 0);
        assertEq(engine.positions(DEPLOYER, 1).size1e8, 0);
        assertEq(engine.totalResidualBadDebtBase(), 0);
        assertFalse(engine.tradingPaused());
        assertFalse(engine.liquidationPaused());
        assertFalse(engine.fundingPaused());
        assertFalse(engine.collateralOpsPaused());
        assertFalse(CollateralVault(VAULT).isEngineAuthorized(deployed));
        assertFalse(InsuranceFund(INSURANCE).isBackstopCaller(deployed));
        (uint16 spread, bool enabled, bool isSet) = CollateralSeizer(SEIZER).seizeConfigs(TOKEN);
        assertEq(spread, 0);
        assertFalse(enabled);
        assertFalse(isSet);

        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        engine.updateFunding(1);
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        engine.liquidate(DEPLOYER, 1, 0);
        IPerpEngineTrade.Trade memory trade = IPerpEngineTrade.Trade({
            buyer: DEPLOYER, seller: TIMELOCK, marketId: 1, sizeDelta1e8: 1, executionPrice1e8: 1, buyerIsMaker: false
        });
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        engine.applyTrade(trade);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        engine.adminSeedResidualBadDebt(DEPLOYER, 1);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        engine.sealMigration(bytes32(uint256(1)));
        vm.prank(TIMELOCK);
        vm.expectRevert(PerpEngineTradingV2.MigrationClearingNotConfigured.selector);
        engine.sealMigration(bytes32(uint256(1)));

        assertEq(CollateralVault(VAULT).balances(CLEARING, TOKEN), clearingBefore);
        assertEq(PMR.codehash, pmrCodeBefore);
        assertEq(VAULT.codehash, vaultCodeBefore);
        assertEq(INSURANCE.codehash, insuranceCodeBefore);
    }
}
