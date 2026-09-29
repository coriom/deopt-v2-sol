// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployPerpEngineV2Recovery} from "../../script/DeployPerpEngineV2Recovery.s.sol";

contract RecoveryPreflightHarness is DeployPerpEngineV2Recovery {
    function checkPmr(address pmr) external view {
        _requireApprovedPmr(pmr);
    }

    function checkRuntime(bytes memory runtime) external view {
        _requireFrozenRuntime(runtime);
    }
}

contract DeployPerpEngineV2RecoveryTest is Test {
    address constant OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant PMR = 0xAD8B0855d1fd649539A344AD594bf86929cf0FF7;
    RecoveryPreflightHarness script;

    function setUp() public {
        script = new RecoveryPreflightHarness();
        vm.chainId(84532);
        vm.setEnv("PERP_MARKET_REGISTRY_V2_ADDRESS", vm.toString(PMR));
        vm.setEnv("PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM", "false");
        // STOP succeeds with empty return data: typed decoding must reject it
        // unless an explicit ABI-encoded mock response is supplied.
        vm.etch(PMR, hex"00");
        for (uint256 id = 1; id <= 2; ++id) {
            _mock("getMaxExecutionDeviationBps(uint256)", id, abi.encode(uint16(100)));
            _mock("marketExists(uint256)", id, abi.encode(true));
            _mock("isMarketActive(uint256)", id, abi.encode(true));
        }
    }

    function _mock(string memory sig, uint256 id, bytes memory result) internal {
        vm.mockCall(PMR, abi.encodeWithSignature(sig, id), result);
    }

    function testApprovedPmrBothMarketsAccepted() public view {
        script.checkPmr(PMR);
    }

    function testWrongChainRejectedBeforeEnvironmentReads() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.UnexpectedChain.selector, 1));
        script.run();
    }

    function testWrongSenderRejectedEvenWhenConfirmationFalse() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployPerpEngineV2Recovery.DeployerNotOwner.selector, address(this), OWNER)
        );
        script.run();
    }

    function testWrongPmrRejectedAtRunBeforeCreate() public {
        vm.setEnv("PERP_MARKET_REGISTRY_V2_ADDRESS", vm.toString(address(123)));
        vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.UnexpectedPmr.selector, address(123), PMR));
        vm.prank(OWNER);
        script.run();
    }

    function testPmrWithoutCodeRejected() public {
        vm.etch(PMR, hex"");
        vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.PmrHasNoCode.selector, PMR));
        script.checkPmr(PMR);
    }

    function testDeviationOnEitherMarketMustBeExactly100() public {
        for (uint256 id = 1; id <= 2; ++id) {
            _mock("getMaxExecutionDeviationBps(uint256)", id, abi.encode(uint16(99)));
            vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.UnexpectedPmrDeviation.selector, id, 99));
            script.checkPmr(PMR);
            _mock("getMaxExecutionDeviationBps(uint256)", id, abi.encode(uint16(100)));
        }
    }

    function testEitherMissingMarketRejected() public {
        for (uint256 id = 1; id <= 2; ++id) {
            _mock("marketExists(uint256)", id, abi.encode(false));
            vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.PmrMarketMissing.selector, id));
            script.checkPmr(PMR);
            _mock("marketExists(uint256)", id, abi.encode(true));
        }
    }

    function testEitherInactiveMarketRejected() public {
        for (uint256 id = 1; id <= 2; ++id) {
            _mock("isMarketActive(uint256)", id, abi.encode(false));
            vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.PmrMarketInactive.selector, id));
            script.checkPmr(PMR);
            _mock("isMarketActive(uint256)", id, abi.encode(true));
        }
    }

    function testSuccessfulStaticcallWithEmptyDataRejected() public {
        _mock("getMaxExecutionDeviationBps(uint256)", 2, hex"");
        vm.expectRevert();
        script.checkPmr(PMR);
    }

    function testMalformedBooleanRejected() public {
        _mock("marketExists(uint256)", 2, abi.encode(uint256(2)));
        vm.expectRevert();
        script.checkPmr(PMR);
    }

    function testWrongRuntimeSizeRejected() public {
        vm.expectRevert(abi.encodeWithSelector(DeployPerpEngineV2Recovery.UnexpectedRuntimeSize.selector, 1));
        script.checkRuntime(hex"00");
    }

    function testWrongRuntimeHashRejected() public {
        bytes memory runtime = new bytes(24_321);
        vm.expectRevert(
            abi.encodeWithSelector(DeployPerpEngineV2Recovery.UnexpectedRuntimeHash.selector, keccak256(runtime))
        );
        script.checkRuntime(runtime);
    }
}
