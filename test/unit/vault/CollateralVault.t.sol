// SPDX-License-Identifier: MIT
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
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT);
    }

    function testWithdrawSuccess() external {
        _deposit(ALICE, DEPOSIT_AMOUNT);

        vm.prank(ALICE);
        vault.withdraw(address(usdc), WITHDRAW_AMOUNT);

        assertEq(vault.balances(ALICE, address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(vault.idleBalances(ALICE, address(usdc)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        assertEq(usdc.balanceOf(ALICE), 1_000e6 - DEPOSIT_AMOUNT + WITHDRAW_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
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
        assertEq(usdc.balanceOf(address(vault)), totalBefore);
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
}
