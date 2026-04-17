// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVault} from "../../../src/collateral/CollateralVault.sol";

contract InvariantERC20Decimals is ERC20 {
    uint8 private immutable _DECIMALS_VALUE;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _DECIMALS_VALUE = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS_VALUE;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CollateralVaultInvariantHandler is Test {
    uint256 internal constant ACTOR_COUNT = 3;
    uint256 internal constant SUPPORTED_TOKEN_COUNT = 2;

    CollateralVault internal immutable vault;
    InvariantERC20Decimals internal immutable usdc;
    InvariantERC20Decimals internal immutable weth;
    InvariantERC20Decimals internal immutable unsupported;
    address internal immutable engine;

    address[] internal actors;
    address[] internal supportedTokens;

    mapping(address => uint256) internal _totalDeposited;
    mapping(address => uint256) internal _totalWithdrawn;

    constructor(
        CollateralVault vault_,
        InvariantERC20Decimals usdc_,
        InvariantERC20Decimals weth_,
        InvariantERC20Decimals unsupported_,
        address engine_
    ) {
        vault = vault_;
        usdc = usdc_;
        weth = weth_;
        unsupported = unsupported_;
        engine = engine_;

        actors.push(address(0xA1));
        actors.push(address(0xB2));
        actors.push(address(0xC3));

        supportedTokens.push(address(usdc_));
        supportedTokens.push(address(weth_));
    }

    function depositSupported(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        address token = _supportedToken(tokenSeed);
        uint256 amount = _boundedAmount(token, amountSeed);

        InvariantERC20Decimals(token).mint(actor, amount);

        vm.startPrank(actor);
        IERC20(token).approve(address(vault), amount);
        vault.deposit(token, amount);
        vm.stopPrank();

        _totalDeposited[token] += amount;
    }

    function withdrawSupported(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        address token = _supportedToken(tokenSeed);

        uint256 bal = vault.balances(actor, token);
        if (bal == 0) return;

        uint256 amount = bound(amountSeed, 1, bal);

        vm.prank(actor);
        vault.withdraw(token, amount);

        _totalWithdrawn[token] += amount;
    }

    function internalTransferSupported(
        uint256 fromSeed,
        uint256 toSeed,
        uint256 tokenSeed,
        uint256 amountSeed
    ) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        address token = _supportedToken(tokenSeed);
        uint256 bal = vault.balances(from, token);
        if (bal == 0) return;

        uint256 amount = bound(amountSeed, 1, bal);

        vm.prank(engine);
        vault.transferBetweenAccounts(token, from, to, amount);
    }

    function depositUnsupported(uint256 actorSeed, uint256 amountSeed) external {
        address actor = _actor(actorSeed);
        uint256 amount = _boundedAmount(address(unsupported), amountSeed);

        unsupported.mint(actor, amount);

        vm.startPrank(actor);
        unsupported.approve(address(vault), amount);
        try vault.deposit(address(unsupported), amount) {
            fail("unsupported deposit unexpectedly succeeded");
        } catch {}
        vm.stopPrank();
    }

    function actorAt(uint256 index) external view returns (address) {
        return actors[index];
    }

    function supportedTokenAt(uint256 index) external view returns (address) {
        return supportedTokens[index];
    }

    function unsupportedToken() external view returns (address) {
        return address(unsupported);
    }

    function totalDeposited(address token) external view returns (uint256) {
        return _totalDeposited[token];
    }

    function totalWithdrawn(address token) external view returns (uint256) {
        return _totalWithdrawn[token];
    }

    function netTracked(address token) external view returns (uint256) {
        return _totalDeposited[token] - _totalWithdrawn[token];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTOR_COUNT];
    }

    function _supportedToken(uint256 seed) internal view returns (address) {
        return supportedTokens[seed % SUPPORTED_TOKEN_COUNT];
    }

    function _boundedAmount(address token, uint256 seed) internal view returns (uint256) {
        uint256 unit = 10 ** InvariantERC20Decimals(token).decimals();
        return bound(seed, 1, 1_000 * unit);
    }
}

contract CollateralVaultInvariantsTest is StdInvariant, Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant ENGINE = address(0xE11E);

    uint256 internal constant ACTOR_COUNT = 3;
    uint256 internal constant SUPPORTED_TOKEN_COUNT = 2;

    CollateralVault internal vault;
    InvariantERC20Decimals internal usdc;
    InvariantERC20Decimals internal weth;
    InvariantERC20Decimals internal unsupported;
    CollateralVaultInvariantHandler internal handler;

    function setUp() external {
        vault = new CollateralVault(OWNER);

        usdc = new InvariantERC20Decimals("Mock USDC", "mUSDC", 6);
        weth = new InvariantERC20Decimals("Mock WETH", "mWETH", 18);
        unsupported = new InvariantERC20Decimals("Mock Unsupported", "mUNSUP", 8);

        vm.startPrank(OWNER);
        vault.setCollateralToken(address(usdc), true, 6, 10_000);
        vault.setCollateralToken(address(weth), true, 18, 8_000);
        vault.setMarginEngine(ENGINE);
        vm.stopPrank();

        handler = new CollateralVaultInvariantHandler(vault, usdc, weth, unsupported, ENGINE);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.depositSupported.selector;
        selectors[1] = handler.withdrawSupported.selector;
        selectors[2] = handler.internalTransferSupported.selector;
        selectors[3] = handler.depositUnsupported.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_internalTransfersConserveTotalAccountingAcrossParticipatingAccounts() external view {
        for (uint256 i = 0; i < SUPPORTED_TOKEN_COUNT; i++) {
            address token = handler.supportedTokenAt(i);
            uint256 sumBalances = _sumBalances(token);
            uint256 sumIdle = _sumIdleBalances(token);
            uint256 netTracked = handler.netTracked(token);

            assertEq(sumBalances, netTracked);
            assertEq(sumIdle, netTracked);
        }
    }

    function invariant_depositWithdrawFlowsNeverCreatePhantomBalance() external view {
        for (uint256 i = 0; i < SUPPORTED_TOKEN_COUNT; i++) {
            address token = handler.supportedTokenAt(i);
            uint256 sumBalances = _sumBalances(token);
            uint256 vaultTokenBalance = IERC20(token).balanceOf(address(vault));
            uint256 deposited = handler.totalDeposited(token);
            uint256 withdrawn = handler.totalWithdrawn(token);

            assertEq(sumBalances, vaultTokenBalance);
            assertEq(vaultTokenBalance, deposited - withdrawn);
        }
    }

    function invariant_unsupportedTokensNeverContributeToTrackedCollateralAccounting() external view {
        address token = handler.unsupportedToken();

        assertEq(IERC20(token).balanceOf(address(vault)), 0);

        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            address actor = handler.actorAt(i);
            (uint256 balanceClaimable, uint256 idle,, uint256 assetsFromShares, uint256 effective) =
                vault.checkInvariant(actor, token);

            assertEq(vault.balances(actor, token), 0);
            assertEq(vault.idleBalances(actor, token), 0);
            assertEq(balanceClaimable, 0);
            assertEq(idle, 0);
            assertEq(assetsFromShares, 0);
            assertEq(effective, 0);
        }
    }

    function invariant_noTestedActionSequenceCanProduceNegativeEffectiveAccountingBehavior() external view {
        for (uint256 tokenIndex = 0; tokenIndex < SUPPORTED_TOKEN_COUNT; tokenIndex++) {
            address token = handler.supportedTokenAt(tokenIndex);

            for (uint256 actorIndex = 0; actorIndex < ACTOR_COUNT; actorIndex++) {
                address actor = handler.actorAt(actorIndex);
                (uint256 balanceClaimable, uint256 idle, uint256 shares, uint256 assetsFromShares, uint256 effective) =
                    vault.checkInvariant(actor, token);

                assertEq(shares, 0);
                assertEq(assetsFromShares, 0);
                assertEq(effective, idle);
                assertEq(balanceClaimable, idle);
                assertEq(vault.balances(actor, token), balanceClaimable);
                assertEq(vault.idleBalances(actor, token), idle);
            }
        }
    }

    function _sumBalances(address token) internal view returns (uint256 total) {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            total += vault.balances(handler.actorAt(i), token);
        }
    }

    function _sumIdleBalances(address token) internal view returns (uint256 total) {
        for (uint256 i = 0; i < ACTOR_COUNT; i++) {
            total += vault.idleBalances(handler.actorAt(i), token);
        }
    }
}
