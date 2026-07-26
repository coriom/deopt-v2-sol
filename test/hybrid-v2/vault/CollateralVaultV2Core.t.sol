// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

import {CollateralVaultV2CoreHarness} from "./harness/CollateralVaultV2CoreHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferToken, FalseReturningToken, ReentrantToken, DonationToken} from "./mocks/MaliciousTokens.sol";

/// @title CollateralVaultV2CoreTest
/// @notice Unit + fuzz coverage for WP-04A custody + isolated-balance + token-policy
///         + deposit + solvency-view foundation.
contract CollateralVaultV2CoreTest is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    SubaccountRegistry internal registry;
    CollateralVaultV2CoreHarness internal vault;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal unsupported;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant OWNER_A = address(0xA1);
    address internal constant OWNER_B = address(0xB2);
    address internal constant PAYER = address(0xC0);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() external {
        // The registry needs the vault's future address as capabilityAuthority. We
        // compute it via CREATE-nonce prediction (this test contract's next nonce).
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new CollateralVaultV2CoreHarness(address(registry), GOVERNANCE, GUARDIAN);
        assertEq(address(vault), predictedVault, "vault address prediction must match");

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        unsupported = new MockERC20("XXX", "XXX", 18);

        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.addSupportedToken(address(weth));
        // Grant the vault the lazy-registration capability so `deposit(subaccountId=1)`
        // works out of the box.
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_pinsRegistry() external view {
        assertEq(address(vault.REGISTRY()), address(registry));
    }

    function test_constructor_inheritsGovernanceAndGuardian() external view {
        assertEq(vault.governance(), GOVERNANCE);
        assertEq(vault.guardian(), GUARDIAN);
    }

    function test_constructor_rejectsZeroRegistry() external {
        vm.expectRevert(CollateralVaultV2Core.InvalidRegistry.selector);
        new CollateralVaultV2CoreHarness(address(0), GOVERNANCE, GUARDIAN);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN POLICY
    //////////////////////////////////////////////////////////////*/

    function test_tokenPolicy_initiallyDisabled() external {
        MockERC20 fresh = new MockERC20("F", "F", 18);
        assertFalse(vault.supportedTokens(address(fresh)));
    }

    function test_tokenPolicy_governanceEnable() external {
        MockERC20 fresh = new MockERC20("F", "F", 18);

        vm.expectEmit(true, false, false, true);
        emit CollateralVaultV2Core.SupportedTokenAdded(address(fresh), Versions.EVENT_VERSION);
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(fresh));

        assertTrue(vault.supportedTokens(address(fresh)));
    }

    function test_tokenPolicy_governanceDisable() external {
        vm.expectEmit(true, false, false, true);
        emit CollateralVaultV2Core.SupportedTokenRemoved(address(usdc), Versions.EVENT_VERSION);
        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));

        assertFalse(vault.supportedTokens(address(usdc)));
    }

    function test_tokenPolicy_addRejectsZero() external {
        vm.prank(GOVERNANCE);
        vm.expectRevert(CollateralVaultV2Core.InvalidToken.selector);
        vault.addSupportedToken(address(0));
    }

    function test_tokenPolicy_addRejectsDuplicate() external {
        vm.prank(GOVERNANCE);
        vm.expectRevert(CollateralVaultV2Core.TokenAlreadySupported.selector);
        vault.addSupportedToken(address(usdc));
    }

    function test_tokenPolicy_removeRejectsUnknown() external {
        MockERC20 fresh = new MockERC20("F", "F", 18);
        vm.prank(GOVERNANCE);
        vm.expectRevert(CollateralVaultV2Core.TokenNotEnabled.selector);
        vault.removeSupportedToken(address(fresh));
    }

    function test_tokenPolicy_addRejectsNonGovernance() external {
        MockERC20 fresh = new MockERC20("F", "F", 18);
        vm.prank(ATTACKER);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        vault.addSupportedToken(address(fresh));
    }

    function test_tokenPolicy_removeRejectsNonGovernance() external {
        vm.prank(ATTACKER);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        vault.removeSupportedToken(address(usdc));
    }

    function test_tokenPolicy_guardianCannotEnable() external {
        MockERC20 fresh = new MockERC20("F", "F", 18);
        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        vault.addSupportedToken(address(fresh));
    }

    function test_tokenPolicy_disablingPreservesBalances() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(usdc)), 100e6);

        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));

        // Balance + aggregate untouched.
        assertEq(vault.balanceOf(keyA, address(usdc)), 100e6);
        assertEq(vault.totalAccounted(address(usdc)), 100e6);
    }

    function test_tokenPolicy_disableThenNewDepositReverts() external {
        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));

        usdc.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(CollateralVaultV2Core.TokenNotSupported.selector);
        vault.deposit(1, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_tokenPolicy_reEnableAllowsDepositAgain() external {
        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));

        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(usdc)), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT — OWNER PATH
    //////////////////////////////////////////////////////////////*/

    function test_deposit_lazilyRegistersAccountOne() external {
        assertFalse(registry.existsOf(OWNER_A, 1));
        _mintApproveDeposit(OWNER_A, 1, usdc, 50e6);
        assertTrue(registry.existsOf(OWNER_A, 1));
    }

    function test_deposit_creditsExactAmount() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 50e6);
        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(usdc)), 50e6);
        assertEq(vault.totalAccounted(address(usdc)), 50e6);
        assertEq(vault.physicalBalance(address(usdc)), 50e6);
    }

    function test_deposit_emitsCorrectEvent() external {
        usdc.mint(OWNER_A, 50e6);
        bytes32 expectedKey = registry.subKeyOf(OWNER_A, 1);

        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 50e6);

        vm.expectEmit(true, true, true, true, address(vault));
        emit CollateralVaultV2Core.Deposit(
            expectedKey, OWNER_A, uint32(1), address(usdc), 50e6, OWNER_A, Versions.EVENT_VERSION
        );
        vault.deposit(1, address(usdc), 50e6);
        vm.stopPrank();
    }

    function test_deposit_intoRegisteredAccountTwo() external {
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 1
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 2

        _mintApproveDeposit(OWNER_A, 2, weth, 3 ether);

        bytes32 keyA2 = registry.subKeyOf(OWNER_A, 2);
        assertEq(vault.balanceOf(keyA2, address(weth)), 3 ether);
    }

    function test_deposit_unknownAccountReverts() external {
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 1 exists; Account 5 does NOT

        usdc.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2Core.SubaccountNotFound.selector, OWNER_A, uint32(5)));
        vault.deposit(5, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_deposit_accountZeroReverts() external {
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2Core.InvalidSubaccountId.selector);
        vault.deposit(0, address(usdc), 100e6);
    }

    function test_deposit_zeroTokenReverts() external {
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2Core.InvalidToken.selector);
        vault.deposit(1, address(0), 100e6);
    }

    function test_deposit_zeroAmountReverts() external {
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2Core.AmountZero.selector);
        vault.deposit(1, address(usdc), 0);
    }

    function test_deposit_unsupportedTokenReverts() external {
        unsupported.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        unsupported.approve(address(vault), 100e6);
        vm.expectRevert(CollateralVaultV2Core.TokenNotSupported.selector);
        vault.deposit(1, address(unsupported), 100e6);
        vm.stopPrank();
    }

    function test_deposit_requiresVaultCapabilityForLazy() external {
        // Revoke the vault's CAP_REGISTER_DEFAULT_ACCOUNT to prove the deposit path
        // fails cleanly if governance never granted it.
        vm.prank(GOVERNANCE);
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, false);

        usdc.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        vault.deposit(1, address(usdc), 100e6); // subaccount 1 does not yet exist
        vm.stopPrank();

        // Meanwhile, an already-registered account still deposits fine.
        vm.prank(OWNER_B);
        registry.registerNext();
        _mintApproveDeposit(OWNER_B, 1, usdc, 25e6);
    }

    /*//////////////////////////////////////////////////////////////
                       DEPOSIT — THIRD-PARTY PATH
    //////////////////////////////////////////////////////////////*/

    function test_depositFor_credits_ownerNotPayer() external {
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 1 required

        usdc.mint(PAYER, 200e6);
        vm.startPrank(PAYER);
        usdc.approve(address(vault), 200e6);

        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit CollateralVaultV2Core.Deposit(
            keyA1, OWNER_A, uint32(1), address(usdc), 200e6, PAYER, Versions.EVENT_VERSION
        );
        vault.depositFor(OWNER_A, 1, address(usdc), 200e6);
        vm.stopPrank();

        assertEq(vault.balanceOf(keyA1, address(usdc)), 200e6);
        // Payer's own subaccount (if it ever registered) receives nothing.
        assertFalse(registry.existsOf(PAYER, 1));
    }

    function test_depositFor_doesNotLazyRegister() external {
        assertFalse(registry.existsOf(OWNER_A, 1));
        usdc.mint(PAYER, 100e6);
        vm.startPrank(PAYER);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2Core.SubaccountNotFound.selector, OWNER_A, uint32(1)));
        vault.depositFor(OWNER_A, 1, address(usdc), 100e6);
        vm.stopPrank();
        assertFalse(registry.existsOf(OWNER_A, 1));
    }

    function test_depositFor_zeroOwnerReverts() external {
        vm.prank(PAYER);
        vm.expectRevert(CollateralVaultV2Core.InvalidOwner.selector);
        vault.depositFor(address(0), 1, address(usdc), 100e6);
    }

    function test_depositFor_accountZeroReverts() external {
        vm.prank(PAYER);
        vm.expectRevert(CollateralVaultV2Core.InvalidSubaccountId.selector);
        vault.depositFor(OWNER_A, 0, address(usdc), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                       MALICIOUS TOKEN POLICY
    //////////////////////////////////////////////////////////////*/

    function test_feeOnTransferToken_rejectedByDeltaCheck() external {
        FeeOnTransferToken fot = new FeeOnTransferToken(100); // 1% fee
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(fot));

        fot.mint(OWNER_A, 1000e18);
        vm.startPrank(OWNER_A);
        fot.approve(address(vault), 1000e18);
        // Actually credited = 1000 - 10 = 990. Expect revert with (requested=1000, credited=990).
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultV2Core.InvalidTokenBalanceDelta.selector, uint256(1000e18), uint256(990e18)
            )
        );
        vault.deposit(1, address(fot), 1000e18);
        vm.stopPrank();

        // No ledger credit. No aggregate liability. The reverted transferFrom did
        // move tokens (FoT burned some) but the vault's internal state is unchanged.
        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(fot)), 0);
        assertEq(vault.totalAccounted(address(fot)), 0);
    }

    function test_falseReturningToken_rejected() external {
        FalseReturningToken bad = new FalseReturningToken();
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(bad));

        bad.mint(OWNER_A, 100e18);
        vm.startPrank(OWNER_A);
        bad.approve(address(vault), 100e18);
        // SafeERC20 reverts on false-return.
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        vault.deposit(1, address(bad), 100e18);
        vm.stopPrank();

        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(bad)), 0);
        assertEq(vault.totalAccounted(address(bad)), 0);
    }

    function test_reentrantToken_blockedByGuard() external {
        ReentrantToken evil = new ReentrantToken();
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(evil));

        // Register Account 1 for OWNER_A (payer will be the token; needs an existing account).
        vm.prank(OWNER_A);
        registry.registerNext();

        // Arm the token to re-enter deposit during transferFrom.
        bytes memory reentryCall = abi.encodeWithSignature(
            "depositFor(address,uint32,address,uint256)", OWNER_A, uint32(1), address(evil), uint256(1e18)
        );
        evil.armReentry(address(vault), reentryCall);

        evil.mint(OWNER_A, 100e18);
        vm.startPrank(OWNER_A);
        evil.approve(address(vault), 100e18);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.deposit(1, address(evil), 10e18);
        vm.stopPrank();
    }

    function test_directDonation_createsSurplusOnly() external {
        DonationToken don = new DonationToken();
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(don));

        // Mint tokens directly to the vault — bypassing deposit.
        don.mint(address(vault), 500e18);

        assertEq(vault.physicalBalance(address(don)), 500e18);
        assertEq(vault.totalAccounted(address(don)), 0, "aggregate untouched by direct donation");
        assertEq(vault.surplus(address(don)), 500e18);
        assertTrue(vault.isSolvent(address(don)));

        // No account received credit.
        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(don)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_isolation_ownersIsolated() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        _mintApproveDeposit(OWNER_B, 1, usdc, 200e6);

        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        bytes32 keyB = registry.subKeyOf(OWNER_B, 1);

        assertEq(vault.balanceOf(keyA, address(usdc)), 100e6);
        assertEq(vault.balanceOf(keyB, address(usdc)), 200e6);
        assertEq(vault.totalAccounted(address(usdc)), 300e6);
    }

    function test_isolation_subaccountsIsolated() external {
        vm.startPrank(OWNER_A);
        registry.registerNext();
        registry.registerNext();
        vm.stopPrank();

        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        _mintApproveDeposit(OWNER_A, 2, usdc, 250e6);

        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        bytes32 keyA2 = registry.subKeyOf(OWNER_A, 2);

        assertEq(vault.balanceOf(keyA1, address(usdc)), 100e6);
        assertEq(vault.balanceOf(keyA2, address(usdc)), 250e6);
    }

    function test_isolation_tokensIsolated() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        _mintApproveDeposit(OWNER_A, 1, weth, 5 ether);

        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA1, address(usdc)), 100e6);
        assertEq(vault.balanceOf(keyA1, address(weth)), 5 ether);
        assertEq(vault.totalAccounted(address(usdc)), 100e6);
        assertEq(vault.totalAccounted(address(weth)), 5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              SOLVENCY
    //////////////////////////////////////////////////////////////*/

    function test_solvency_holdsAfterDeposits() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        _mintApproveDeposit(OWNER_B, 1, usdc, 50e6);

        assertTrue(vault.isSolvent(address(usdc)));
        assertEq(vault.physicalBalance(address(usdc)), vault.totalAccounted(address(usdc)));
        assertEq(vault.surplus(address(usdc)), 0);
    }

    function test_solvency_donationOnly() external {
        // Solvency vacuously holds for a token with zero deposits + donation.
        assertTrue(vault.isSolvent(address(usdc)));
        assertEq(vault.surplus(address(usdc)), 0);

        usdc.mint(address(vault), 5e6);
        assertTrue(vault.isSolvent(address(usdc)));
        assertEq(vault.surplus(address(usdc)), 5e6);
    }

    /*//////////////////////////////////////////////////////////////
                        CAPABILITY / REGISTRY INERT
    //////////////////////////////////////////////////////////////*/

    function test_depositDoesNotAlterCapabilityBits() external {
        uint256 before = vault.engineCapabilityBits(address(vault));
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        assertEq(vault.engineCapabilityBits(address(vault)), before);
    }

    function test_depositDoesNotAlterRegistryIdentity() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        assertEq(registry.ownerOf(key), OWNER_A);
        assertEq(registry.subaccountIdOf(key), uint32(1));
        assertEq(registry.nextIdFor(OWNER_A), uint32(2));
    }

    function test_tokenPolicyDoesNotAlterRegistry() external {
        // Snapshot registry state.
        vm.prank(OWNER_A);
        registry.registerNext();
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.startPrank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));
        vault.addSupportedToken(address(usdc));
        vm.stopPrank();

        assertEq(registry.ownerOf(key), OWNER_A);
        assertEq(registry.nextIdFor(OWNER_A), uint32(2));
    }

    /*//////////////////////////////////////////////////////////////
                              NATIVE ETH
    //////////////////////////////////////////////////////////////*/

    function test_noNativeAccounting() external view {
        assertEq(address(vault).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_depositAggregatesCorrectly(address owner, uint128 depositAmount) external {
        vm.assume(owner != address(0));
        vm.assume(owner.code.length == 0);
        vm.assume(owner != address(vault) && owner != address(registry) && owner != address(usdc));
        uint256 amount = uint256(depositAmount) + 1;
        _mintApproveDeposit(owner, 1, usdc, amount);

        bytes32 key = registry.subKeyOf(owner, 1);
        assertEq(vault.balanceOf(key, address(usdc)), amount);
        assertEq(vault.totalAccounted(address(usdc)), amount);
    }

    function testFuzz_donationCannotCredit(uint96 donation) external {
        vm.assume(donation > 0);
        usdc.mint(address(vault), donation);

        bytes32 keyA = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA, address(usdc)), 0);
        assertEq(vault.totalAccounted(address(usdc)), 0);
        assertEq(vault.surplus(address(usdc)), donation);
    }

    function testFuzz_unsupportedTokenAlwaysRejected(address rawToken, uint96 amount) external {
        vm.assume(rawToken != address(0));
        vm.assume(rawToken != address(usdc) && rawToken != address(weth));
        vm.assume(amount > 0);

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2Core.TokenNotSupported.selector);
        vault.deposit(1, rawToken, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mintApproveDeposit(address owner, uint32 subaccountId, MockERC20 token, uint256 amount) internal {
        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(subaccountId, address(token), amount);
        vm.stopPrank();
    }
}
