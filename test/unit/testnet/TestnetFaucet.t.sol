// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {TestnetFaucet} from "../../../src/testnet/TestnetFaucet.sol";

/// @dev Minimal local mock — no project dep on `TestnetMockERC20`
///      (which is inline in `script/DeployTestnetAssets.s.sol`).
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Always-revert ERC20 used to assert that a withdraw / claim
///      reverts cleanly when the token's `transfer` itself fails.
contract RevertOnTransfer is ERC20 {
    constructor() ERC20("RT", "RT") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("transfer-reverted");
    }

    function balanceOf(address) public pure override returns (uint256) {
        return type(uint256).max;
    }
}

contract TestnetFaucetTest is Test {
    TestnetFaucet internal faucet;
    MockERC20 internal mUSDC;
    MockERC20 internal mWETH;
    MockERC20 internal mWBTC;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xBEEF);
    address internal bob = address(0xCAFE);

    uint256 internal constant COOLDOWN_SECONDS = 6 hours;
    uint256 internal constant USDC_PER_CLAIM = 1_000 * 1e6; // 1000 mUSDC
    uint256 internal constant WETH_PER_CLAIM = 1 * 1e18; // 1 mWETH
    uint256 internal constant WBTC_PER_CLAIM = 5 * 1e7; // 0.5 mWBTC

    function setUp() public {
        mUSDC = new MockERC20("Mock USDC", "mUSDC", 6);
        mWETH = new MockERC20("Mock WETH", "mWETH", 18);
        mWBTC = new MockERC20("Mock WBTC", "mWBTC", 8);

        vm.prank(owner);
        faucet = new TestnetFaucet(owner, COOLDOWN_SECONDS);

        vm.startPrank(owner);
        faucet.setToken(IERC20(address(mUSDC)), USDC_PER_CLAIM);
        faucet.setToken(IERC20(address(mWETH)), WETH_PER_CLAIM);
        faucet.setToken(IERC20(address(mWBTC)), WBTC_PER_CLAIM);
        vm.stopPrank();

        // Pre-fund the faucet with enough reserves for plenty of
        // claims. Real deployment mints these into the faucet
        // via the operator's `TestnetMockERC20` owner key.
        mUSDC.mint(address(faucet), USDC_PER_CLAIM * 1_000);
        mWETH.mint(address(faucet), WETH_PER_CLAIM * 1_000);
        mWBTC.mint(address(faucet), WBTC_PER_CLAIM * 1_000);
    }

    // ── Happy path ───────────────────────────────────────────────

    function test_claim_transfers_configured_amounts_for_all_tokens() public {
        vm.prank(alice);
        faucet.claim();

        assertEq(mUSDC.balanceOf(alice), USDC_PER_CLAIM, "alice mUSDC");
        assertEq(mWETH.balanceOf(alice), WETH_PER_CLAIM, "alice mWETH");
        assertEq(mWBTC.balanceOf(alice), WBTC_PER_CLAIM, "alice mWBTC");
        assertEq(faucet.lastClaimedAt(alice), block.timestamp, "lastClaimedAt set");
    }

    function test_claim_emits_one_Claimed_event_per_token() public {
        vm.expectEmit(true, true, false, true, address(faucet));
        emit TestnetFaucet.Claimed(alice, address(mUSDC), USDC_PER_CLAIM);
        vm.expectEmit(true, true, false, true, address(faucet));
        emit TestnetFaucet.Claimed(alice, address(mWETH), WETH_PER_CLAIM);
        vm.expectEmit(true, true, false, true, address(faucet));
        emit TestnetFaucet.Claimed(alice, address(mWBTC), WBTC_PER_CLAIM);

        vm.prank(alice);
        faucet.claim();
    }

    function test_different_callers_have_independent_cooldowns() public {
        vm.prank(alice);
        faucet.claim();
        vm.prank(bob);
        faucet.claim();

        assertEq(mUSDC.balanceOf(alice), USDC_PER_CLAIM);
        assertEq(mUSDC.balanceOf(bob), USDC_PER_CLAIM);
    }

    // ── Cooldown ─────────────────────────────────────────────────

    function test_second_claim_before_cooldown_reverts() public {
        vm.prank(alice);
        faucet.claim();

        uint256 nextAt = block.timestamp + COOLDOWN_SECONDS;
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.CooldownNotElapsed.selector, nextAt));
        vm.prank(alice);
        faucet.claim();
    }

    function test_claim_at_exact_cooldown_boundary_succeeds() public {
        vm.prank(alice);
        faucet.claim();

        // First second AT the boundary should already be eligible
        // — the check is `block.timestamp < last + cooldown`.
        vm.warp(block.timestamp + COOLDOWN_SECONDS);
        vm.prank(alice);
        faucet.claim();
        assertEq(mUSDC.balanceOf(alice), USDC_PER_CLAIM * 2);
    }

    function test_claim_after_cooldown_succeeds() public {
        vm.prank(alice);
        faucet.claim();

        vm.warp(block.timestamp + COOLDOWN_SECONDS + 1);
        vm.prank(alice);
        faucet.claim();

        assertEq(mUSDC.balanceOf(alice), USDC_PER_CLAIM * 2);
    }

    function test_nextClaimAvailableAt_returns_zero_for_never_claimed() public view {
        assertEq(faucet.nextClaimAvailableAt(bob), 0);
    }

    function test_nextClaimAvailableAt_returns_last_plus_cooldown() public {
        vm.prank(alice);
        faucet.claim();
        assertEq(faucet.nextClaimAvailableAt(alice), block.timestamp + COOLDOWN_SECONDS);
    }

    // ── Pause / unpause ──────────────────────────────────────────

    function test_paused_faucet_rejects_claim() public {
        vm.prank(owner);
        faucet.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        faucet.claim();
    }

    function test_unpause_restores_claim() public {
        vm.startPrank(owner);
        faucet.pause();
        faucet.unpause();
        vm.stopPrank();

        vm.prank(alice);
        faucet.claim();
        assertEq(mUSDC.balanceOf(alice), USDC_PER_CLAIM);
    }

    function test_only_owner_can_pause() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        faucet.pause();
    }

    // ── Owner reconfiguration ────────────────────────────────────

    function test_owner_can_update_token_amount_in_place() public {
        vm.expectEmit(true, false, false, true, address(faucet));
        emit TestnetFaucet.TokenConfigUpdated(address(mUSDC), 42_000_000);

        vm.prank(owner);
        faucet.setToken(IERC20(address(mUSDC)), 42_000_000);

        (address tok, uint256 amt) = faucet.tokenAt(0);
        assertEq(tok, address(mUSDC));
        assertEq(amt, 42_000_000);
        assertEq(faucet.tokenCount(), 3, "no new token appended");
    }

    function test_owner_can_add_a_fourth_token() public {
        MockERC20 mTOKEN = new MockERC20("Mock TOK", "mTOK", 18);
        vm.prank(owner);
        faucet.setToken(IERC20(address(mTOKEN)), 7 * 1e18);

        assertEq(faucet.tokenCount(), 4);
        (address tok, uint256 amt) = faucet.tokenAt(3);
        assertEq(tok, address(mTOKEN));
        assertEq(amt, 7 * 1e18);
    }

    function test_non_owner_cannot_update_config() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        faucet.setToken(IERC20(address(mUSDC)), 1);
    }

    function test_set_zero_address_token_reverts() public {
        vm.expectRevert(TestnetFaucet.ZeroAddress.selector);
        vm.prank(owner);
        faucet.setToken(IERC20(address(0)), 1);
    }

    function test_set_zero_amount_reverts() public {
        vm.expectRevert(TestnetFaucet.ZeroAmount.selector);
        vm.prank(owner);
        faucet.setToken(IERC20(address(mUSDC)), 0);
    }

    function test_remove_token_drops_it_and_shifts_indices() public {
        // Remove the middle token (mWETH). The last one (mWBTC) is
        // swapped into the freed slot.
        vm.prank(owner);
        faucet.removeToken(IERC20(address(mWETH)));

        assertEq(faucet.tokenCount(), 2);
        (address t0,) = faucet.tokenAt(0);
        (address t1,) = faucet.tokenAt(1);
        assertEq(t0, address(mUSDC));
        assertEq(t1, address(mWBTC));
    }

    function test_remove_unregistered_token_reverts() public {
        MockERC20 stranger = new MockERC20("X", "X", 18);
        vm.expectRevert(abi.encodeWithSelector(TestnetFaucet.TokenNotRegistered.selector, address(stranger)));
        vm.prank(owner);
        faucet.removeToken(IERC20(address(stranger)));
    }

    function test_owner_can_update_cooldown() public {
        vm.expectEmit(false, false, false, true, address(faucet));
        emit TestnetFaucet.CooldownUpdated(1 hours);

        vm.prank(owner);
        faucet.setCooldown(1 hours);

        assertEq(faucet.cooldownSeconds(), 1 hours);
    }

    // ── Withdraw ─────────────────────────────────────────────────

    function test_owner_can_withdraw_reserves() public {
        vm.expectEmit(true, true, false, true, address(faucet));
        emit TestnetFaucet.Withdrawn(address(mUSDC), owner, 500 * 1e6);

        vm.prank(owner);
        faucet.withdraw(IERC20(address(mUSDC)), owner, 500 * 1e6);

        assertEq(mUSDC.balanceOf(owner), 500 * 1e6);
    }

    function test_non_owner_cannot_withdraw() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        faucet.withdraw(IERC20(address(mUSDC)), alice, 1);
    }

    // ── Reserves / failure modes ─────────────────────────────────

    function test_claim_with_no_tokens_configured_reverts() public {
        // Spin up a fresh faucet with no tokens registered.
        vm.prank(owner);
        TestnetFaucet empty = new TestnetFaucet(owner, COOLDOWN_SECONDS);

        vm.expectRevert(TestnetFaucet.NoTokensConfigured.selector);
        vm.prank(alice);
        empty.claim();
    }

    function test_claim_reverts_on_insufficient_reserves_for_any_token() public {
        // Drain mWBTC down to less than one claim. Compute the
        // amount FIRST: `vm.prank` only persists for the next call,
        // and `balanceOf(...)` would otherwise consume it.
        uint256 currentBal = mWBTC.balanceOf(address(faucet));
        uint256 drainAmount = currentBal - (WBTC_PER_CLAIM - 1);
        vm.prank(owner);
        faucet.withdraw(IERC20(address(mWBTC)), owner, drainAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                TestnetFaucet.InsufficientReserves.selector, address(mWBTC), WBTC_PER_CLAIM, WBTC_PER_CLAIM - 1
            )
        );
        vm.prank(alice);
        faucet.claim();
    }

    function test_claim_reverts_on_token_transfer_failure() public {
        // Replace the token list with one that always reverts on
        // transfer. The faucet's SafeERC20 wrapper propagates the
        // revert.
        RevertOnTransfer bad = new RevertOnTransfer();
        vm.startPrank(owner);
        faucet.removeToken(IERC20(address(mUSDC)));
        faucet.removeToken(IERC20(address(mWETH)));
        faucet.removeToken(IERC20(address(mWBTC)));
        faucet.setToken(IERC20(address(bad)), 1);
        vm.stopPrank();

        vm.expectRevert(); // SafeERC20 rethrows the underlying revert
        vm.prank(alice);
        faucet.claim();
    }

    // ── Constructor invariants ───────────────────────────────────

    function test_constructor_rejects_zero_owner() public {
        vm.expectRevert();
        new TestnetFaucet(address(0), COOLDOWN_SECONDS);
    }
}
