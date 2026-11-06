// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {OptionWithdrawalRiskGate} from "../../src/collateral/OptionWithdrawalRiskGate.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {IRiskModule} from "../../src/risk/IRiskModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OptionWithdrawalRiskGateForkTest is Test {
    uint256 internal constant FORK_BLOCK = 55_041_332;
    address internal constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address internal constant ENGINE = 0x506cD65a63C53c66ab572B9f9dd819B7BfE00D30;
    address internal constant RISK = 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B;
    address internal constant REGISTRY = 0x3d52b033Fab00ed6104DD3bc0a715F8648344ecA;
    address internal constant ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address internal constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant WETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address internal constant BUYER = 0x77cA9DD6cCce2D692FB23877a2db7178807b0020;
    address internal constant SELLER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    address internal constant INSURANCE_FUND = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address internal constant PERP_ENGINE = 0xc6C592100723Fe0C66343A16e95eC34cC0c2141c;
    address internal constant PERP_BUYER = 0x8B94A83D1AD3bD2337b1886E7962CA8E0bba9A34;
    address internal constant PERP_SELLER = 0x475Fe397FA56884952D350aa9EE1c3946964BC0C;
    uint256 internal constant SERIES = 24145907678156652148089862289363692212069910767044828147380657249455352740183;

    CollateralVault internal vault;
    OptionWithdrawalRiskGate internal gate;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        vault = CollateralVault(VAULT);
        require(address(vault.riskModule()) == RISK && vault.marginEngine() == ENGINE, "fork wiring drift");
        gate = new OptionWithdrawalRiskGate(VAULT, ENGINE, RISK, REGISTRY, ORACLE);
    }

    function _install() internal {
        vm.prank(vault.owner()); // fork-only impersonation, not a Safe signature
        vault.setRiskModule(address(gate));
    }

    function _mockHealthyOracle() internal {
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.getPriceSafe.selector, WETH, TOKEN),
            abi.encode(uint256(3000e8), block.timestamp, true)
        );
    }

    function testGuardOnExistingVaultPreservesFundsAndPositions() public {
        uint256 totalBefore = vault.totalDepositedByToken(TOKEN);
        uint256 tokenBalanceBefore = IERC20(TOKEN).balanceOf(VAULT);
        uint256 buyerBefore = vault.balances(BUYER, TOKEN);
        uint256 sellerBefore = vault.balances(SELLER, TOKEN);
        (bool ok, bytes memory data) =
            ENGINE.staticcall(abi.encodeWithSignature("getPositionQuantity(address,uint256)", SELLER, SERIES));
        require(ok && abi.decode(data, (int128)) == -4, "seller position drift");

        _install();
        assertEq(address(vault.riskModule()), address(gate));
        assertEq(vault.totalDepositedByToken(TOKEN), totalBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), tokenBalanceBefore);
        assertEq(vault.balances(BUYER, TOKEN), buyerBefore);
        assertEq(vault.balances(SELLER, TOKEN), sellerBefore);

        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.getPriceSafe.selector, WETH, TOKEN),
            abi.encode(uint256(0), block.timestamp, false)
        );
        vm.prank(SELLER);
        vm.expectRevert();
        vault.withdraw(TOKEN, 1);
        vm.prank(ENGINE);
        vm.expectRevert();
        vault.withdrawFor(SELLER, TOKEN, 1);
        assertEq(vault.balances(SELLER, TOKEN), sellerBefore);

        _mockHealthyOracle();
        uint256 maxAllowed = gate.getWithdrawableAmount(SELLER, TOKEN);
        assertLt(maxAllowed, sellerBefore, "test requires an actual margin bound");
        vm.prank(SELLER);
        vm.expectRevert();
        vault.withdraw(TOKEN, maxAllowed + 1);
        uint256 buyerMax = gate.getWithdrawableAmount(BUYER, TOKEN);
        assertGt(buyerMax, 0, "healthy long account should have free collateral");
        vm.prank(BUYER);
        vault.withdraw(TOKEN, 1);
        assertEq(vault.balances(BUYER, TOKEN), buyerBefore - 1);
        assertEq(vault.balances(SELLER, TOKEN), sellerBefore);
        assertEq(vault.totalDepositedByToken(TOKEN), totalBefore - 1);

        vm.prank(SELLER);
        vm.expectRevert();
        vault.transferBetweenAccounts(TOKEN, SELLER, BUYER, 1);

        (ok, data) = ENGINE.staticcall(abi.encodeWithSignature("getPositionQuantity(address,uint256)", SELLER, SERIES));
        require(ok && abi.decode(data, (int128)) == -4, "seller position changed");
    }

    function testOnlyGovernanceCanInstallAndStaleWiringFailsClosed() public {
        vm.prank(SELLER);
        vm.expectRevert();
        vault.setRiskModule(address(gate));
        _install();
        _mockHealthyOracle();
        vm.prank(vault.owner());
        vault.setRiskModule(RISK);
        vm.expectRevert(OptionWithdrawalRiskGate.WiringChanged.selector);
        gate.getWithdrawableAmount(SELLER, TOKEN);
    }

    function testStaleAndFutureOracleReadingsFailClosed() public {
        _install();
        uint256 maxDelay = gate.engine().liquidationOracleMaxDelay();
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.getPriceSafe.selector, WETH, TOKEN),
            abi.encode(uint256(3000e8), block.timestamp - maxDelay - 1, true)
        );
        vm.expectRevert(OptionWithdrawalRiskGate.UnsafeOracle.selector);
        gate.getWithdrawableAmount(SELLER, TOKEN);

        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.getPriceSafe.selector, WETH, TOKEN),
            abi.encode(uint256(3000e8), block.timestamp + 1, true)
        );
        vm.expectRevert(OptionWithdrawalRiskGate.UnsafeOracle.selector);
        gate.getWithdrawableAmount(SELLER, TOKEN);

        _mockHealthyOracle();
        gate.getWithdrawableAmount(SELLER, TOKEN);
    }

    function testSharedVaultNonOptionAccountCanStillWithdrawWithinRiskLimit() public {
        uint256 insuranceBefore = vault.balances(INSURANCE_FUND, TOKEN);
        uint256 totalBefore = vault.totalDepositedByToken(TOKEN);
        assertEq(insuranceBefore, 2_100_010, "pinned InsuranceFund balance changed");
        assertEq(vault.getAuthorizedEngines().length > 0, true);
        _install();
        assertEq(vault.balances(INSURANCE_FUND, TOKEN), insuranceBefore);
        assertGt(gate.getWithdrawableAmount(INSURANCE_FUND, TOKEN), 0);
        uint256 recipientBefore = IERC20(TOKEN).balanceOf(INSURANCE_FUND);
        vm.prank(INSURANCE_FUND); // fork-only account impersonation
        vault.withdraw(TOKEN, 1);
        assertEq(vault.balances(INSURANCE_FUND, TOKEN), insuranceBefore - 1);
        assertEq(vault.totalDepositedByToken(TOKEN), totalBefore - 1);
        assertEq(IERC20(TOKEN).balanceOf(INSURANCE_FUND), recipientBefore + 1);
    }

    function testInternalAccountExitCannotBypassInvalidOracle() public {
        uint256 sellerBefore = vault.balances(SELLER, TOKEN);
        uint256 assetBefore = IERC20(TOKEN).balanceOf(VAULT);
        _install();
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.getPriceSafe.selector, WETH, TOKEN),
            abi.encode(uint256(0), block.timestamp, false)
        );
        vm.prank(SELLER);
        vm.expectRevert();
        vault.transferFromInternalAccount(TOKEN, SELLER, 1);
        assertEq(vault.balances(SELLER, TOKEN), sellerBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), assetBefore);
    }

    function testInternalTransferTrustBoundaryRemainsAfterGateInstallation() public {
        uint256 sellerBefore = vault.balances(SELLER, TOKEN);
        uint256 buyerBefore = vault.balances(BUYER, TOKEN);
        uint256 totalBefore = vault.totalDepositedByToken(TOKEN);
        uint256 assetBefore = IERC20(TOKEN).balanceOf(VAULT);
        assertGt(vault.idleBalances(SELLER, TOKEN), 0);
        _install();
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.getPriceSafe.selector, WETH, TOKEN),
            abi.encode(uint256(0), block.timestamp, false)
        );

        vm.prank(SELLER);
        vm.expectRevert();
        vault.transferBetweenAccounts(TOKEN, SELLER, BUYER, 1);

        // An authorized engine is an independent trust boundary. The
        // withdrawal-only adapter cannot validate this internal movement.
        vm.prank(ENGINE); // fork-only impersonation, not an externally reachable call path
        vault.transferBetweenAccounts(TOKEN, SELLER, BUYER, 1);
        assertEq(vault.balances(SELLER, TOKEN), sellerBefore - 1);
        assertEq(vault.balances(BUYER, TOKEN), buyerBefore + 1);
        assertEq(vault.totalDepositedByToken(TOKEN), totalBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), assetBefore);
    }

    function testGuardianPausesBothExitAndInternalMovementWithoutMovingAssets() public {
        uint256 sellerBefore = vault.balances(SELLER, TOKEN);
        uint256 buyerBefore = vault.balances(BUYER, TOKEN);
        uint256 totalBefore = vault.totalDepositedByToken(TOKEN);
        uint256 assetBefore = IERC20(TOKEN).balanceOf(VAULT);
        _install();
        vm.startPrank(vault.guardian()); // fork-only impersonation
        vault.pauseWithdrawals();
        vault.pauseInternalTransfers();
        vm.stopPrank();

        vm.prank(ENGINE);
        vm.expectRevert();
        vault.transferBetweenAccounts(TOKEN, SELLER, BUYER, 1);
        vm.prank(ENGINE);
        vm.expectRevert();
        vault.withdrawFor(SELLER, TOKEN, 1);
        vm.prank(SELLER);
        vm.expectRevert();
        vault.transferFromInternalAccount(TOKEN, SELLER, 1);
        assertEq(vault.balances(SELLER, TOKEN), sellerBefore);
        assertEq(vault.balances(BUYER, TOKEN), buyerBefore);
        assertEq(vault.totalDepositedByToken(TOKEN), totalBefore);
        assertEq(IERC20(TOKEN).balanceOf(VAULT), assetBefore);
    }

    function testExistingPerpAccountsRemainBoundedAndPositionsUnchanged() public {
        int256 buyerPositionBefore = _perpPosition(PERP_BUYER);
        int256 sellerPositionBefore = _perpPosition(PERP_SELLER);
        assertTrue(buyerPositionBefore != 0 || sellerPositionBefore != 0, "no representative perp position");
        uint256 buyerBalanceBefore = vault.balances(PERP_BUYER, TOKEN);
        uint256 sellerBalanceBefore = vault.balances(PERP_SELLER, TOKEN);
        uint256 oldBuyerMax = IRiskModule(RISK).getWithdrawableAmount(PERP_BUYER, TOKEN);
        uint256 oldSellerMax = IRiskModule(RISK).getWithdrawableAmount(PERP_SELLER, TOKEN);
        _install();
        assertLe(gate.getWithdrawableAmount(PERP_BUYER, TOKEN), oldBuyerMax);
        assertLe(gate.getWithdrawableAmount(PERP_SELLER, TOKEN), oldSellerMax);
        assertEq(_perpPosition(PERP_BUYER), buyerPositionBefore);
        assertEq(_perpPosition(PERP_SELLER), sellerPositionBefore);
        assertEq(vault.balances(PERP_BUYER, TOKEN), buyerBalanceBefore);
        assertEq(vault.balances(PERP_SELLER, TOKEN), sellerBalanceBefore);
    }

    function _perpPosition(address account) internal view returns (int256) {
        (bool ok, bytes memory data) =
            PERP_ENGINE.staticcall(abi.encodeWithSignature("getPositionSize(address,uint256)", account, 1));
        require(ok && data.length == 32, "perp position read failed");
        return abi.decode(data, (int256));
    }

    function testGuardianCanFreezeWithdrawalsBeforeGovernanceSwitch() public {
        vm.prank(vault.guardian()); // fork-only impersonation
        vault.pauseWithdrawals();
        vm.prank(BUYER);
        vm.expectRevert();
        vault.withdraw(TOKEN, 1);
        vm.prank(vault.owner());
        vault.unpauseWithdrawals();
        assertFalse(vault.withdrawalsPaused());
    }
}
