// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpRiskModule} from "../../src/perp/PerpRiskModule.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";

/// @notice Exact D5 initcode is supplied by the non-secret preparation tool.
///         All CREATE and governance calls in this test are isolated to the fork.
contract PerpsV2ReplacementD5PreparationTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant LOST = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address constant PMR = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    bytes32 constant INITCODE_HASH = 0xf13dc356f5a7a61cc5528392334339694a67907c05230f5955cedf0feaddfb49;
    bytes32 constant RUNTIME_HASH = 0x8c782209845865d35ecff80c00525ef3f0f335bea4e7b9846f01199c60fb5a2c;

    function testExactD5ForkCreationAndInitialSafety() public {
        vm.createSelectFork(vm.envString("DEOPT_REPLACEMENT_RPC"), vm.envUint("D5_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertEq(vm.getNonce(DEPLOYER), 4);
        assertEq(D5.code.length, 0);

        bytes memory initcode = vm.envBytes("D5_CREATION_DATA");
        assertEq(initcode.length, 10_697);
        assertEq(keccak256(initcode), INITCODE_HASH);
        bytes memory constructorArgs = abi.encode(TIMELOCK, VAULT, D4, ORACLE, TOKEN);
        for (uint256 i; i < constructorArgs.length; ++i) {
            assertEq(initcode[initcode.length - constructorArgs.length + i], constructorArgs[i]);
        }

        uint256 clearingBefore = CollateralVault(VAULT).balances(CLEARING, TOKEN);
        bytes32[4] memory codeBefore = [PMR.codehash, D4.codehash, VAULT.codehash, INSURANCE.codehash];
        address riskBefore = PerpEngineV2(D4).riskModule();
        assertEq(riskBefore, address(0));

        address deployed;
        vm.startPrank(DEPLOYER);
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        vm.stopPrank();
        assertEq(deployed, D5);
        assertEq(deployed.codehash, RUNTIME_HASH);
        PerpRiskModule risk = PerpRiskModule(deployed);

        assertEq(risk.owner(), TIMELOCK);
        assertEq(risk.pendingOwner(), address(0));
        assertEq(risk.guardian(), address(0));
        assertEq(address(risk.collateralVault()), VAULT);
        assertEq(address(risk.perpEngine()), D4);
        assertEq(address(risk.oracle()), ORACLE);
        assertEq(risk.baseCollateralToken(), TOKEN);
        assertEq(risk.maxOracleDelay(), 0);
        assertFalse(risk.paused());
        assertFalse(risk.riskComputationPaused());
        assertFalse(risk.withdrawPreviewPaused());
        assertEq(risk.PRICE_SCALE(), 1e8);
        assertEq(risk.BPS(), 10_000);

        address emptyTrader = address(0xD500);
        PerpRiskModule.AccountRisk memory account = risk.computeAccountRisk(emptyTrader);
        assertEq(account.equityBase, 0);
        assertEq(account.maintenanceMarginBase, 0);
        assertEq(account.initialMarginBase, 0);
        assertEq(risk.computeFreeCollateral(emptyTrader), 0);
        assertEq(risk.getWithdrawableAmount(emptyTrader, TOKEN), 0);
        assertEq(PerpEngineV2(D4).getTraderMarketsLength(emptyTrader), 0);
        assertEq(PerpEngineV2(D4).getResidualBadDebt(emptyTrader), 0);

        vm.prank(DEPLOYER);
        vm.expectRevert(PerpRiskModule.NotAuthorized.selector);
        risk.setPerpEngine(DEPLOYER);
        vm.prank(LOST);
        vm.expectRevert(PerpRiskModule.NotAuthorized.selector);
        risk.setMaxOracleDelay(600);
        vm.prank(SAFE);
        vm.expectRevert(PerpRiskModule.NotAuthorized.selector);
        risk.setPerpEngine(SAFE);

        // This is fork-local governance rehearsal, never a public Timelock action.
        vm.prank(TIMELOCK);
        risk.setMaxOracleDelay(600);
        assertEq(risk.maxOracleDelay(), 600);
        vm.prank(TIMELOCK);
        risk.setGuardian(SAFE);
        vm.prank(SAFE);
        risk.pauseRiskComputation();
        vm.prank(SAFE);
        vm.expectRevert(PerpRiskModule.NotAuthorized.selector);
        risk.unpauseRiskComputation();
        vm.prank(SAFE);
        vm.expectRevert(PerpRiskModule.NotAuthorized.selector);
        risk.setPerpEngine(SAFE);

        assertEq(PerpEngineV2(D4).riskModule(), address(0));
        assertEq(uint8(PerpEngineV2(D4).migrationState()), 0);
        assertEq(PerpEngineV2(D4).matchingEngine(), address(0));
        assertEq(PerpMarketRegistry(PMR).getAllMarketIds().length, 0);
        assertFalse(CollateralVault(VAULT).isEngineAuthorized(D4));
        assertFalse(InsuranceFund(INSURANCE).isBackstopCaller(D4));
        assertEq(CollateralVault(VAULT).balances(CLEARING, TOKEN), clearingBefore);
        (uint16 spread, bool enabled, bool isSet) = CollateralSeizer(D3).seizeConfigs(TOKEN);
        assertEq(spread, 0);
        assertFalse(enabled);
        assertFalse(isSet);
        assertEq(PMR.codehash, codeBefore[0]);
        assertEq(D4.codehash, codeBefore[1]);
        assertEq(VAULT.codehash, codeBefore[2]);
        assertEq(INSURANCE.codehash, codeBefore[3]);
    }
}
