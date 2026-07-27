// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {RiskModuleV2Harness} from "../harness/RiskModuleV2Harness.sol";
import {RiskAwareVaultHarness} from "../harness/RiskAwareVaultHarness.sol";
import {OptionsPositionsLedger} from "../../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {MockERC20} from "../../vault/mocks/MockERC20.sol";
import {Capabilities} from "../../../../src/hybrid-v2/libraries/Capabilities.sol";

/// @title RiskModuleV2Handler
/// @notice Bounded fuzz handler + ghost mirror for the WP-07 RiskModule invariants.
contract RiskModuleV2Handler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    RiskModuleV2Harness public immutable module;
    RiskAwareVaultHarness public immutable vault;
    OptionsPositionsLedger public immutable ledger;
    SubaccountRegistry public immutable registry;
    MockERC20 public immutable token;

    address public immutable governance;
    address public immutable guardian;
    address public immutable engineFill;

    address[] public owners;
    bytes32[] public trackedSubKeys;

    // Ghost mirrors
    mapping(bytes32 => uint256) public ghostRequired;
    mapping(bytes32 => uint256) public ghostAvailable;
    mapping(bytes32 => uint256) public ghostVaultBalance;
    mapping(bytes32 => uint256) public ghostVaultLocked;

    // Tally of state changes we did NOT initiate on the module.
    uint256 public callCount;

    constructor(
        RiskModuleV2Harness module_,
        RiskAwareVaultHarness vault_,
        OptionsPositionsLedger ledger_,
        SubaccountRegistry registry_,
        MockERC20 token_,
        address governance_,
        address guardian_,
        address engineFill_
    ) {
        module = module_;
        vault = vault_;
        ledger = ledger_;
        registry = registry_;
        token = token_;
        governance = governance_;
        guardian = guardian_;
        engineFill = engineFill_;

        for (uint160 i = 1; i <= 3; i++) {
            owners.push(address(uint160(0x70000 + i)));
        }
    }

    function ownerRegister(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        uint32 nextId = registry.nextIdFor(owner);
        if (nextId >= 3) return;
        vm.prank(owner);
        registry.registerNext();
        trackedSubKeys.push(registry.subKeyOf(owner, nextId));
    }

    function setMargin(uint256 seed, uint64 required, uint64 available) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        module.setRequiredMargin(sk, uint256(required));
        module.setAvailableMargin(sk, uint256(available));
        ghostRequired[sk] = uint256(required);
        ghostAvailable[sk] = uint256(available);
    }

    function toggleProviderStale(bool stale) external {
        callCount++;
        module.setProviderStale(stale);
    }

    function fundSubaccount(uint256 seed, uint64 amount) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 amt = bound(uint256(amount), 1, 1e18);
        vault.testForceCredit(sk, address(token), amt);
        ghostVaultBalance[sk] += amt;
    }

    function lockCollateral(uint256 seed, uint64 amount) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 available = vault.availableOf(sk, address(token));
        if (available == 0) return;
        uint256 amt = bound(uint256(amount), 1, available);
        vm.prank(engineFill);
        vault.applyLock(sk, address(token), amt);
        ghostVaultLocked[sk] += amt;
    }

    function attemptWithdrawal(uint256 seed, uint64 amount) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 amt = uint256(amount) + 1;
        // Purely a view — no mutation. Result recorded implicitly (return value
        // discarded). Never affects invariants that check mirror equality.
        module.withdrawalAllowed(sk, address(token), amt);
    }

    // ----- accessors -----
    function ownersLength() external view returns (uint256) {
        return owners.length;
    }

    function trackedSubKeysLength() external view returns (uint256) {
        return trackedSubKeys.length;
    }
}
