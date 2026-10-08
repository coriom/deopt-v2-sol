// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpRiskModule} from "../../src/perp/PerpRiskModule.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";

/// @notice Read-only public fork plus six local CREATEs by an impersonated test actor.
/// No key, public transaction, code replacement or public-chain state edit.
contract PerpsV2ReplacementDeploymentPackageForkTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address constant COLLATERAL_RISK = 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant LOCAL_DEPLOYER = address(0xd3);

    function testD1ThroughD6LocalForkConstructorPostflight() public {
        vm.createSelectFork(vm.envString("DEOPT_REPLACEMENT_RPC"), 47_829_878);
        assertEq(block.chainid, 84532);
        assertGt(TIMELOCK.code.length, 0);
        assertGt(VAULT.code.length, 0);
        assertGt(ORACLE.code.length, 0);
        assertGt(COLLATERAL_RISK.code.length, 0);

        vm.startPrank(LOCAL_DEPLOYER);
        uint256 beforeGas = gasleft();
        PerpMarketRegistry pmr = new PerpMarketRegistry(TIMELOCK);
        emit log_named_uint("D1_gas_observed_local", beforeGas - gasleft());
        assertGt(address(pmr).code.length, 0);
        assertEq(pmr.owner(), TIMELOCK);
        assertEq(pmr.pendingOwner(), address(0));
        assertEq(pmr.guardian(), address(0));
        assertFalse(pmr.paused());
        assertFalse(pmr.creationPaused());
        assertFalse(pmr.configPaused());
        assertEq(pmr.nextMarketId(), 1);
        emit log_named_address("D1_local_address", address(pmr));
        emit log_named_bytes32("D1_local_runtime_hash", address(pmr).codehash);

        beforeGas = gasleft();
        FeesManagerV2 fees = new FeesManagerV2(TIMELOCK, TIMELOCK);
        emit log_named_uint("D2_gas_observed_local", beforeGas - gasleft());
        assertGt(address(fees).code.length, 0);
        assertEq(fees.owner(), TIMELOCK);
        assertEq(fees.feeRecipient(), TIMELOCK);
        assertEq(fees.protocolFeeVault(), address(0));
        emit log_named_address("D2_local_address", address(fees));
        emit log_named_bytes32("D2_local_runtime_hash", address(fees).codehash);

        beforeGas = gasleft();
        CollateralSeizer seizer = new CollateralSeizer(TIMELOCK, VAULT, ORACLE, COLLATERAL_RISK);
        emit log_named_uint("D3_gas_observed_local", beforeGas - gasleft());
        assertGt(address(seizer).code.length, 0);
        assertEq(seizer.owner(), TIMELOCK);
        assertEq(seizer.pendingOwner(), address(0));
        assertEq(address(seizer.collateralVault()), VAULT);
        assertEq(address(seizer.oracle()), ORACLE);
        assertEq(address(seizer.riskModule()), COLLATERAL_RISK);
        assertEq(seizer.oracleMaxDelay(), 600);
        emit log_named_address("D3_local_address", address(seizer));
        emit log_named_bytes32("D3_local_runtime_hash", address(seizer).codehash);

        beforeGas = gasleft();
        PerpEngineV2 engine = new PerpEngineV2(TIMELOCK, address(pmr), VAULT, ORACLE);
        emit log_named_uint("D4_gas_observed_local", beforeGas - gasleft());
        assertGt(address(engine).code.length, 0);
        assertEq(engine.owner(), TIMELOCK);
        assertEq(engine.pendingOwner(), address(0));
        assertEq(engine.guardian(), TIMELOCK);
        assertEq(engine.marketRegistry(), address(pmr));
        assertEq(address(engine.collateralVault()), VAULT);
        assertEq(address(engine.oracle()), ORACLE);
        assertFalse(engine.tradingPaused());
        assertFalse(engine.liquidationPaused());
        assertFalse(engine.fundingPaused());
        assertFalse(engine.collateralOpsPaused());
        assertEq(uint8(engine.migrationState()), 0);
        assertEq(engine.migrationSnapshotHash(), bytes32(0));
        assertEq(engine.matchingEngine(), address(0));
        assertEq(engine.riskModule(), address(0));
        assertFalse(CollateralVault(VAULT).isEngineAuthorized(address(engine)));
        assertFalse(InsuranceFund(0x009f38440F058d095b61E0E2ee7fAbDF05BE7500).isBackstopCaller(address(engine)));
        emit log_named_address("D4_local_address", address(engine));
        emit log_named_bytes32("D4_local_runtime_hash", address(engine).codehash);

        beforeGas = gasleft();
        PerpRiskModule risk = new PerpRiskModule(TIMELOCK, VAULT, address(engine), ORACLE, TOKEN);
        emit log_named_uint("D5_gas_observed_local", beforeGas - gasleft());
        assertGt(address(risk).code.length, 0);
        assertEq(risk.owner(), TIMELOCK);
        assertEq(risk.pendingOwner(), address(0));
        assertEq(risk.guardian(), address(0));
        assertEq(address(risk.perpEngine()), address(engine));
        assertEq(risk.maxOracleDelay(), 0);
        emit log_named_address("D5_local_address", address(risk));
        emit log_named_bytes32("D5_local_runtime_hash", address(risk).codehash);

        beforeGas = gasleft();
        PerpMatchingEngineV2 pme = new PerpMatchingEngineV2(TIMELOCK, address(engine));
        emit log_named_uint("D6_gas_observed_local", beforeGas - gasleft());
        assertGt(address(pme).code.length, 0);
        assertEq(pme.owner(), TIMELOCK);
        assertEq(pme.pendingOwner(), address(0));
        assertEq(pme.guardian(), address(0));
        assertFalse(pme.paused());
        assertEq(address(pme.perpEngine()), address(engine));
        assertTrue(pme.isExecutor(TIMELOCK));
        emit log_named_address("D6_local_address", address(pme));
        emit log_named_bytes32("D6_local_runtime_hash", address(pme).codehash);
        emit log_named_bytes32("D6_local_domain_separator", pme.domainSeparatorV4());
        vm.stopPrank();
    }
}
