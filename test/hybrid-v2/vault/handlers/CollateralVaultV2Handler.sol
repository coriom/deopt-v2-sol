// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVaultV2Core} from "../../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {CollateralVaultV2} from "../../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../../src/hybrid-v2/libraries/Capabilities.sol";

import {CollateralVaultV2Harness} from "../harness/CollateralVaultV2Harness.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title CollateralVaultV2Handler
/// @notice Bounded handler for VAULT-B-I1..I14 invariants. Exercises deposits,
///         reservations, unlocks, withdrawals, internal transfers and pause
///         transitions across a small actor + engine + token set.
contract CollateralVaultV2Handler is Test {
    CollateralVaultV2Harness public immutable vault;
    SubaccountRegistry public immutable registry;
    MockERC20 public immutable usdc;
    MockERC20 public immutable weth;

    address public immutable governance;
    address public immutable guardian;

    address[] internal _owners;
    address[] internal _engines;

    /*//////////////////////////////////////////////////////////////
                             GHOST STATE
    //////////////////////////////////////////////////////////////*/

    /// @dev Ghost balance per (owner, id, token).
    mapping(address => mapping(uint32 => mapping(address => uint256))) public ghostBalance;

    /// @dev Ghost per-engine reservation per (owner, id, token, engine).
    mapping(address => mapping(uint32 => mapping(address => mapping(address => uint256)))) public ghostEngineLocked;

    /// @dev Ghost aggregate locked per (owner, id, token) — sum of engine reservations.
    mapping(address => mapping(uint32 => mapping(address => uint256))) public ghostTotalLocked;

    /// @dev Ghost aggregate accounted per token.
    mapping(address => uint256) public ghostTotalAccounted;

    /// @dev Ghost total token outflow via withdraw per token.
    mapping(address => uint256) public ghostWithdrawn;

    constructor(
        CollateralVaultV2Harness vault_,
        SubaccountRegistry registry_,
        MockERC20 usdc_,
        MockERC20 weth_,
        address governance_,
        address guardian_
    ) {
        vault = vault_;
        registry = registry_;
        usdc = usdc_;
        weth = weth_;
        governance = governance_;
        guardian = guardian_;

        _owners.push(address(0xA001));
        _owners.push(address(0xA002));

        _engines.push(address(0xE001));
        _engines.push(address(0xE002));
    }

    /*//////////////////////////////////////////////////////////////
                             HANDLERS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 ownerSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        MockERC20 token = _pickToken(tokenSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;
        if (vault.depositsPaused()) return;

        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(1, address(token), amount);
        vm.stopPrank();

        ghostBalance[owner][1][address(token)] += amount;
        ghostTotalAccounted[address(token)] += amount;
    }

    function depositAccountTwo(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;
        if (vault.depositsPaused()) return;

        // Ensure Account 2 exists (register both accounts once).
        uint32 next = registry.nextIdFor(owner);
        if (next == 1) {
            vm.prank(owner);
            registry.registerNext(); // Account 1
        }
        if (registry.nextIdFor(owner) == 2) {
            vm.prank(owner);
            registry.registerNext(); // Account 2
        }

        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.deposit(2, address(usdc), amount);
        vm.stopPrank();

        ghostBalance[owner][2][address(usdc)] += amount;
        ghostTotalAccounted[address(usdc)] += amount;
    }

    function engineLock(uint256 ownerSeed, uint256 engineSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        address engine = _pickEngine(engineSeed);
        MockERC20 token = _pickToken(tokenSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;

        uint32 id = 1;
        if (!registry.existsOf(owner, id)) return;
        bytes32 key = registry.subKeyOf(owner, id);
        uint256 available = ghostBalance[owner][id][address(token)] - ghostTotalLocked[owner][id][address(token)];
        if (available < amount) return;

        vm.prank(engine);
        vault.applyLock(key, address(token), amount);

        ghostEngineLocked[owner][id][address(token)][engine] += amount;
        ghostTotalLocked[owner][id][address(token)] += amount;
    }

    function engineUnlock(uint256 ownerSeed, uint256 engineSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        address engine = _pickEngine(engineSeed);
        MockERC20 token = _pickToken(tokenSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;

        uint32 id = 1;
        uint256 held = ghostEngineLocked[owner][id][address(token)][engine];
        if (held < amount) return;
        bytes32 key = registry.subKeyOf(owner, id);

        vm.prank(engine);
        vault.applyUnlock(key, address(token), amount);

        ghostEngineLocked[owner][id][address(token)][engine] = held - amount;
        ghostTotalLocked[owner][id][address(token)] -= amount;
    }

    function engineTryCrossUnlock(uint256 ownerSeed, uint256 attackerSeed, uint256 tokenSeed, uint256 amountSeed)
        external
    {
        address owner = _pickOwner(ownerSeed);
        address attacker = _pickEngine(attackerSeed);
        MockERC20 token = _pickToken(tokenSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;

        uint32 id = 1;
        // Only exercise the negative path when the attacker holds NO reservation
        // but somebody else does. This is the "engine A holds, engine B tries to
        // unlock" scenario. Guaranteed to revert with InsufficientEngineReservation.
        if (ghostEngineLocked[owner][id][address(token)][attacker] > 0) return;
        if (ghostTotalLocked[owner][id][address(token)] == 0) return;
        bytes32 key = registry.subKeyOf(owner, id);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.InsufficientEngineReservation.selector, amount, 0));
        vault.applyUnlock(key, address(token), amount);
    }

    function withdraw(uint256 ownerSeed, uint256 tokenSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        MockERC20 token = _pickToken(tokenSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;
        if (vault.withdrawalsPaused()) return;
        if (!vault.allowWithdrawals()) return;

        uint32 id = 1;
        if (!registry.existsOf(owner, id)) return;
        uint256 available = ghostBalance[owner][id][address(token)] - ghostTotalLocked[owner][id][address(token)];
        if (available < amount) return;

        vm.prank(owner);
        vault.withdraw(id, address(token), amount);

        ghostBalance[owner][id][address(token)] -= amount;
        ghostTotalAccounted[address(token)] -= amount;
        ghostWithdrawn[address(token)] += amount;
    }

    function internalTransfer(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _pickOwner(ownerSeed);
        uint256 amount = _boundAmount(amountSeed);
        if (amount == 0) return;
        if (vault.internalTransfersPaused()) return;
        if (!vault.allowInternalTransfers()) return;

        // Ensure both Account 1 and Account 2 exist for this owner.
        uint32 next = registry.nextIdFor(owner);
        if (next == 1) {
            vm.prank(owner);
            registry.registerNext();
        }
        if (registry.nextIdFor(owner) == 2) {
            vm.prank(owner);
            registry.registerNext();
        }

        uint32 from = 1;
        uint32 to = 2;
        uint256 available = ghostBalance[owner][from][address(usdc)] - ghostTotalLocked[owner][from][address(usdc)];
        if (available < amount) return;

        vm.prank(owner);
        vault.internalTransfer(address(usdc), from, to, amount);

        ghostBalance[owner][from][address(usdc)] -= amount;
        ghostBalance[owner][to][address(usdc)] += amount;
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pickOwner(uint256 seed) internal view returns (address) {
        return _owners[seed % _owners.length];
    }

    function _pickEngine(uint256 seed) internal view returns (address) {
        return _engines[seed % _engines.length];
    }

    function _pickToken(uint256 seed) internal view returns (MockERC20) {
        return seed % 2 == 0 ? usdc : weth;
    }

    function _boundAmount(uint256 seed) internal pure returns (uint256) {
        return (seed % 1_000_000e6) + 1;
    }

    function ownerCount() external view returns (uint256) {
        return _owners.length;
    }

    function ownerAt(uint256 i) external view returns (address) {
        return _owners[i];
    }

    function engineCount() external view returns (uint256) {
        return _engines.length;
    }

    function engineAt(uint256 i) external view returns (address) {
        return _engines[i];
    }
}
