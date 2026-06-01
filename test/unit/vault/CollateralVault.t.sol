// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";
import {CollateralVaultStorage} from "../../../src/collateral/CollateralVaultStorage.sol";

contract MockERC20Decimals is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CollateralVaultTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xB0B);
    address internal constant BOB = address(0xCAFE);
    address internal constant ENGINE = address(0xE11E);

    uint256 internal constant DEPOSIT_AMOUNT = 100e6;
    uint256 internal constant WITHDRAW_AMOUNT = 40e6;
    uint256 internal constant TRANSFER_AMOUNT = 30e6;

    CollateralVault internal vault;
    MockERC20Decimals internal usdc;
    MockERC20Decimals internal unsupported;

    function setUp() external {
        vault = new CollateralVault(OWNER);

        usdc = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        unsupported = new MockERC20Decimals("Mock Unsupported", "mUNSUP", 18);

        vm.prank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);

        vm.prank(OWNER);
        vault.setMarginEngine(ENGINE);

        usdc.mint(ALICE, 1_000e6);
        usdc.mint(BOB, 1_000e6);
        unsupported.mint(ALICE, 1_000e18);
    }

    function testDepositSuccess() external {
        vm.startPrank(ALICE);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT);
        assertEq(vault.idleBalances(ALICE, address(usdc)), DEPOSIT_AMOUNT);
        assertEq(vault.totalDepositedByToken(address(usdc)), DEPOSIT_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function testDepositCapBlocksDirectDepositsAboveCap() external {
        vm.prank(OWNER);
        vault.setTokenDepositCap(address(usdc), DEPOSIT_AMOUNT - 1);

        vm.startPrank(ALICE);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultStorage.DepositCapExceeded.selector, address(usdc), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT - 1
            )
        );
        vault.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(vault.totalDepositedByToken(address(usdc)), 0);
        assertEq(vault.balances(ALICE, address(usdc)), 0);
    }

    function testDepositCapBlocksDepositForAboveCap() external {
        vm.prank(OWNER);
        vault.setTokenDepositCap(address(usdc), DEPOSIT_AMOUNT - 1);

        vm.prank(ALICE);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);

        vm.prank(ENGINE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultStorage.DepositCapExceeded.selector, address(usdc), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT - 1
            )
        );
        vault.depositFor(ALICE, address(usdc), DEPOSIT_AMOUNT);

        assertEq(vault.totalDepositedByToken(address(usdc)), 0);
        assertEq(vault.balances(ALICE, address(usdc)), 0);
    }

    function testCollateralRestrictionModeBlocksInactiveCollateralIngressButAllowsWithdraw() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);

        vm.startPrank(OWNER);
        vault.setCollateralRestrictionMode(true);
        vault.setLaunchActiveCollateral(address(usdc), false);
        vm.stopPrank();

        vm.startPrank(ALICE);
        usdc.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultStorage.CollateralNotLaunchActive.selector, address(usdc))
        );
        vault.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.prank(ENGINE);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultStorage.CollateralNotLaunchActive.selector, address(usdc))
        );
        vault.depositFor(ALICE, address(usdc), DEPOSIT_AMOUNT);

        vm.prank(ALICE);
        vault.withdraw(address(usdc), WITHDRAW_AMOUNT);

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(vault.totalDepositedByToken(address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
    }

    function testWithdrawSuccess() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);

        vm.prank(ALICE);
        vault.withdraw(address(usdc), WITHDRAW_AMOUNT);

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(vault.idleBalances(ALICE, address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(vault.totalDepositedByToken(address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(usdc.balanceOf(ALICE), 1_000e6 - DEPOSIT_AMOUNT + WITHDRAW_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
    }

    function testLoweredDepositCapStillAllowsWithdrawals() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);

        vm.prank(OWNER);
        vault.setTokenDepositCap(address(usdc), DEPOSIT_AMOUNT - 1);

        vm.prank(ALICE);
        vault.withdraw(address(usdc), WITHDRAW_AMOUNT);

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(vault.totalDepositedByToken(address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
    }

    function testWithdrawInsufficientBalanceReverts() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);

        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.InsufficientBalance.selector);
        vault.withdraw(address(usdc), DEPOSIT_AMOUNT + 1);
    }

    function testUnsupportedTokenReverts() external {
        vm.startPrank(ALICE);
        unsupported.approve(address(vault), 1e18);
        vm.expectRevert(CollateralVaultStorage.TokenNotSupported.selector);
        vault.deposit(address(unsupported), 1e18);
        vm.stopPrank();
    }

    function testInternalTransferPreservesAccounting() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        _deposit(BOB, DEPOSIT_AMOUNT);

        uint256 totalBefore = vault.balances(ALICE, address(usdc)) + vault.balances(BOB, address(usdc));

        vm.prank(ENGINE);
        vault.transferBetweenAccounts(address(usdc), ALICE, BOB, TRANSFER_AMOUNT);

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - TRANSFER_AMOUNT);
        assertEq(vault.balances(BOB, address(usdc)), DEPOSIT_AMOUNT + TRANSFER_AMOUNT);
        assertEq(vault.idleBalances(ALICE, address(usdc)), DEPOSIT_AMOUNT - TRANSFER_AMOUNT);
        assertEq(vault.idleBalances(BOB, address(usdc)), DEPOSIT_AMOUNT + TRANSFER_AMOUNT);
        assertEq(vault.balances(ALICE, address(usdc)) + vault.balances(BOB, address(usdc)), totalBefore);
        assertEq(vault.totalDepositedByToken(address(usdc)), totalBefore);
        assertEq(usdc.balanceOf(address(vault)), totalBefore);
    }

    function testInternalTransferUnaffectedByLoweredDepositCap() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        _deposit(BOB, DEPOSIT_AMOUNT);

        uint256 totalBefore = vault.totalDepositedByToken(address(usdc));

        vm.prank(OWNER);
        vault.setTokenDepositCap(address(usdc), totalBefore - 1);

        vm.prank(ENGINE);
        vault.transferBetweenAccounts(address(usdc), ALICE, BOB, TRANSFER_AMOUNT);

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - TRANSFER_AMOUNT);
        assertEq(vault.balances(BOB, address(usdc)), DEPOSIT_AMOUNT + TRANSFER_AMOUNT);
        assertEq(vault.totalDepositedByToken(address(usdc)), totalBefore);
    }

    function testTokenConfigAndDecimalsSanity() external view {
        CollateralVaultStorage.CollateralTokenConfig memory cfg = vault.getCollateralConfig(address(usdc));
        address[] memory tokens = vault.getCollateralTokens();

        assertTrue(cfg.isSupported);
        assertEq(cfg.decimals, 6);
        assertEq(cfg.collateralFactorBps, 10_000);
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));
    }

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
        V2G-RX — transferFromInternalAccount extension tests
    //////////////////////////////////////////////////////////////*/

    function testV2GRX_TransferFromInternalAccountDebitsCallerAndCreditsExternalRecipient() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);

        uint256 externalBefore = usdc.balanceOf(BOB);
        uint256 totalBefore = vault.totalDepositedByToken(address(usdc));

        vm.prank(ALICE);
        vault.transferFromInternalAccount(address(usdc), BOB, TRANSFER_AMOUNT);

        // ALICE's internal balance debited by TRANSFER_AMOUNT.
        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - TRANSFER_AMOUNT);
        assertEq(vault.idleBalances(ALICE, address(usdc)), DEPOSIT_AMOUNT - TRANSFER_AMOUNT);

        // External wallet BOB credited by TRANSFER_AMOUNT.
        assertEq(usdc.balanceOf(BOB), externalBefore + TRANSFER_AMOUNT);

        // CV's totalDeposited bookkeeping decreases — funds left the vault.
        assertEq(vault.totalDepositedByToken(address(usdc)), totalBefore - TRANSFER_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), totalBefore - TRANSFER_AMOUNT);
    }

    function testV2GRX_TransferFromInternalAccountRejectsZeroTo() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.ZeroAddress.selector);
        vault.transferFromInternalAccount(address(usdc), address(0), TRANSFER_AMOUNT);
    }

    function testV2GRX_TransferFromInternalAccountRejectsZeroAmount() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.AmountZero.selector);
        vault.transferFromInternalAccount(address(usdc), BOB, 0);
    }

    function testV2GRX_TransferFromInternalAccountRejectsUnsupportedToken() external {
        // No deposit; use a fresh ERC20 not registered as supported.
        // `unsupported` is already created in setUp() as a non-whitelisted token.
        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.TokenNotSupported.selector);
        vault.transferFromInternalAccount(address(unsupported), BOB, 1);
    }

    function testV2GRX_TransferFromInternalAccountRejectsInsufficientBalance() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.InsufficientBalance.selector);
        vault.transferFromInternalAccount(address(usdc), BOB, DEPOSIT_AMOUNT + 1);
    }

    function testV2GRX_TransferFromInternalAccountOnlyMovesCallersBalance() external {
        // ALICE and BOB both deposit; BOB attempts to withdraw against ALICE's balance
        // via msg.sender semantics → BOB only sees their own balance.
        _deposit(ALICE, DEPOSIT_AMOUNT);
        _deposit(BOB, DEPOSIT_AMOUNT / 2);

        // BOB tries to withdraw MORE than BOB's balance — the function debits
        // msg.sender (BOB)'s balance, not ALICE's. So BOB cannot drain ALICE.
        vm.prank(BOB);
        vm.expectRevert(CollateralVaultStorage.InsufficientBalance.selector);
        vault.transferFromInternalAccount(address(usdc), address(0xFEED), DEPOSIT_AMOUNT);

        // ALICE's balance untouched.
        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT);
    }

    function testV2GRX_TransferFromInternalAccountRespectsWithdrawalsPause() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        vm.prank(OWNER);
        vault.pauseWithdrawals();

        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.WithdrawalsPaused.selector);
        vault.transferFromInternalAccount(address(usdc), BOB, TRANSFER_AMOUNT);
    }

    function testV2GRX_TransferFromInternalAccountRespectsInternalTransfersPause() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);
        vm.prank(OWNER);
        vault.pauseInternalTransfers();

        vm.prank(ALICE);
        vm.expectRevert(CollateralVaultStorage.InternalTransfersPaused.selector);
        vault.transferFromInternalAccount(address(usdc), BOB, TRANSFER_AMOUNT);
    }

    function testV2GRX_TransferFromInternalAccountAfterInternalTransferIsSelfConsistent() external {
        // Models the V2G-R5 flow: a user pays fees → vault account credited via
        // transferBetweenAccounts → vault later moves those funds out via
        // transferFromInternalAccount.
        _deposit(ALICE, DEPOSIT_AMOUNT);

        // Pretend ALICE is the trader and FAKE_VAULT is the vault address.
        address FAKE_VAULT = address(0xFA17);
        vm.prank(ENGINE);
        vault.transferBetweenAccounts(address(usdc), ALICE, FAKE_VAULT, TRANSFER_AMOUNT);

        assertEq(vault.balances(FAKE_VAULT, address(usdc)), TRANSFER_AMOUNT);
        assertEq(vault.idleBalances(FAKE_VAULT, address(usdc)), TRANSFER_AMOUNT);

        // Vault withdraws to its revenueReceiver.
        address REVENUE = address(0xBEA1);
        uint256 revenueBefore = usdc.balanceOf(REVENUE);

        vm.prank(FAKE_VAULT);
        vault.transferFromInternalAccount(address(usdc), REVENUE, TRANSFER_AMOUNT);

        assertEq(usdc.balanceOf(REVENUE), revenueBefore + TRANSFER_AMOUNT);
        assertEq(vault.balances(FAKE_VAULT, address(usdc)), 0);
        assertEq(vault.idleBalances(FAKE_VAULT, address(usdc)), 0);
    }
}
