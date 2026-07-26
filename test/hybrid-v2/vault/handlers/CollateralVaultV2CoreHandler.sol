// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVaultV2Core} from "../../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../../src/hybrid-v2/libraries/Capabilities.sol";

import {CollateralVaultV2CoreHarness} from "../harness/CollateralVaultV2CoreHarness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FeeOnTransferToken} from "../mocks/MaliciousTokens.sol";

/// @title CollateralVaultV2CoreHandler
/// @notice Bounded fuzz handler for VAULT-A-I1..I10 invariants.
/// @dev Actor and token sets are finite. Handler updates ghost mirrors ONLY on
///      successful mutation paths so any unauthorized/malicious behavior widening
///      canonical state becomes observable via a ghost-vs-storage divergence.
contract CollateralVaultV2CoreHandler is Test {
    CollateralVaultV2CoreHarness public immutable vault;
    SubaccountRegistry public immutable registry;

    MockERC20 public immutable usdc;
    MockERC20 public immutable weth;
    FeeOnTransferToken public immutable fot;
    MockERC20 public immutable unsupported;

    address public immutable governance;
    address public immutable guardian;

    address[] internal _owners;

    /*//////////////////////////////////////////////////////////////
                             GHOST STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Ghost balance mirror per (owner, subaccountId, token).
    mapping(address => mapping(uint32 => mapping(address => uint256))) public ghostBalance;

    /// @dev Ghost aggregate liability per token.
    mapping(address => uint256) public ghostTotalAccounted;

    /// @dev Ghost event-derived aggregate per token (for reconstruction check).
    mapping(address => uint256) public ghostFromEvents;

    constructor(
        CollateralVaultV2CoreHarness vault_,
        SubaccountRegistry registry_,
        MockERC20 usdc_,
        MockERC20 weth_,
        FeeOnTransferToken fot_,
        MockERC20 unsupported_,
        address governance_,
        address guardian_
    ) {
        vault = vault_;
        registry = registry_;
        usdc = usdc_;
        weth = weth_;
        fot = fot_;
        unsupported = unsupported_;
        governance = governance_;
        guardian = guardian_;

        _owners.push(address(0xA001));
        _owners.push(address(0xA002));
        _owners.push(address(0xA003));
    }

    /*//////////////////////////////////////////////////////////////
                            SUCCESS PATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner deposits into their Account 1 (lazily registered on first call).
    function ownerDepositAccountOne(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;

        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.deposit(1, address(usdc), amount);
        vm.stopPrank();

        ghostBalance[owner][1][address(usdc)] += amount;
        ghostTotalAccounted[address(usdc)] += amount;
        ghostFromEvents[address(usdc)] += amount;
    }

    /// @notice Owner explicitly registers Account N (via registry) and deposits WETH.
    function ownerDepositRegisteredAccount(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;

        // Register the next available account for this owner (bounded to ~50 per fuzz run).
        uint32 next = registry.nextIdFor(owner);
        if (next > 30) return; // cap to keep ghost/storage cheap
        vm.prank(owner);
        (uint32 id,) = registry.registerNext();

        weth.mint(owner, amount);
        vm.startPrank(owner);
        weth.approve(address(vault), amount);
        vault.deposit(id, address(weth), amount);
        vm.stopPrank();

        ghostBalance[owner][id][address(weth)] += amount;
        ghostTotalAccounted[address(weth)] += amount;
        ghostFromEvents[address(weth)] += amount;
    }

    /// @notice Third-party depositor funds an existing subaccount.
    function thirdPartyDepositExistingAccount(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;
        if (!registry.existsOf(owner, 1)) return; // Requires an existing Account 1.

        address payer = address(uint160(uint256(keccak256(abi.encode("payer", amountSeed)))));
        vm.assume(payer != address(0));
        usdc.mint(payer, amount);
        vm.startPrank(payer);
        usdc.approve(address(vault), amount);
        vault.depositFor(owner, 1, address(usdc), amount);
        vm.stopPrank();

        ghostBalance[owner][1][address(usdc)] += amount;
        ghostTotalAccounted[address(usdc)] += amount;
        ghostFromEvents[address(usdc)] += amount;
    }

    /*//////////////////////////////////////////////////////////////
                            NEGATIVE PATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice Attempt to deposit an unsupported token. MUST always revert.
    function tryUnsupportedTokenDeposit(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;

        unsupported.mint(owner, amount);
        vm.startPrank(owner);
        unsupported.approve(address(vault), amount);
        vm.expectRevert(CollateralVaultV2Core.TokenNotSupported.selector);
        vault.deposit(1, address(unsupported), amount);
        vm.stopPrank();
    }

    /// @notice Attempt to deposit a fee-on-transfer token. MUST always revert
    ///         with `InvalidTokenBalanceDelta` and MUST leave ghost/storage unchanged.
    function tryFotDeposit(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount < 100) return; // FoT fee is 1%; below 100 units the fee rounds to 0.

        fot.mint(owner, amount);
        vm.startPrank(owner);
        fot.approve(address(vault), amount);
        uint256 fee = (amount * 100) / 10000;
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultV2Core.InvalidTokenBalanceDelta.selector, amount, amount - fee)
        );
        vault.deposit(1, address(fot), amount);
        vm.stopPrank();
    }

    /// @notice A raw ERC-20 donation directly to the vault. MUST create surplus
    ///         only; MUST NEVER modify accounted state or subaccount balance.
    function directDonate(uint256 amountSeed) external {
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;
        usdc.mint(address(vault), amount);
        // No ghost mutation — donation is surplus only.
    }

    /// @notice A random attacker tries to grant themselves capability. MUST always revert.
    function attackerTryGrant(uint256 seed) external {
        address attacker = address(uint160(uint256(keccak256(abi.encode("attacker", seed)))));
        vm.assume(attacker != governance && attacker != address(0));
        vm.prank(attacker);
        vm.expectRevert();
        vault.setEngineCapability(attacker, Capabilities.CAP_APPLY_FEE, true);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pickOwner(uint256 seed) internal view returns (address) {
        return _owners[seed % _owners.length];
    }

    function _boundAmount(uint256 seed) internal pure returns (uint256) {
        return (seed % 1_000_000e6) + 1;
    }

    /*//////////////////////////////////////////////////////////////
                         READ HELPERS FOR TESTS
    //////////////////////////////////////////////////////////////*/

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    function ownerAt(uint256 i) external view returns (address) {
        return _owners[i];
    }
}
