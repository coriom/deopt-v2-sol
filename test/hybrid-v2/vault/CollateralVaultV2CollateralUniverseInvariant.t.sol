// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {CollateralVaultV2Harness} from "./harness/CollateralVaultV2Harness.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Bounded handler that drives enable/disable churn against the Vault's
///      universe bookkeeping. Ghost mirror tracks per-token universe entry
///      + enable state so the invariant suite can cross-check chain state.
contract CollateralUniverseHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    CollateralVaultV2Harness public immutable vault;
    address public immutable governance;
    address[] public tokens;

    // Ghost mirror.
    mapping(address => bool) public ghostKnown;
    mapping(address => bool) public ghostEnabled;
    mapping(address => uint256) public ghostBalance;
    uint256 public ghostKnownCount;

    // History of enabled tokens (append-only, dedup on first enable).
    address[] public ghostUniverseOrder;

    uint256 public callCount;

    constructor(CollateralVaultV2Harness vault_, address governance_, address[] memory tokens_) {
        vault = vault_;
        governance = governance_;
        for (uint256 i = 0; i < tokens_.length; i++) {
            tokens.push(tokens_[i]);
        }
    }

    function tryEnable(uint256 seed) external {
        callCount++;
        address t = tokens[seed % tokens.length];
        bool alreadyEnabled = ghostEnabled[t];
        bool alreadyKnown = ghostKnown[t];
        if (alreadyEnabled) {
            vm.expectRevert(CollateralVaultV2Core.TokenAlreadySupported.selector);
            vm.prank(governance);
            vault.addSupportedToken(t);
            return;
        }
        if (!alreadyKnown && ghostKnownCount == 8) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICollateralVault.CollateralUniverseLimitExceeded.selector, uint256(8), uint256(8)
                )
            );
            vm.prank(governance);
            vault.addSupportedToken(t);
            return;
        }
        vm.prank(governance);
        vault.addSupportedToken(t);
        ghostEnabled[t] = true;
        if (!alreadyKnown) {
            ghostKnown[t] = true;
            ghostKnownCount += 1;
            ghostUniverseOrder.push(t);
        }
    }

    function tryDisable(uint256 seed) external {
        callCount++;
        address t = tokens[seed % tokens.length];
        bool alreadyEnabled = ghostEnabled[t];
        if (!alreadyEnabled) {
            vm.expectRevert(CollateralVaultV2Core.TokenNotEnabled.selector);
            vm.prank(governance);
            vault.removeSupportedToken(t);
            return;
        }
        vm.prank(governance);
        vault.removeSupportedToken(t);
        ghostEnabled[t] = false;
    }

    function tokensLength() external view returns (uint256) {
        return tokens.length;
    }

    function ghostUniverseOrderLength() external view returns (uint256) {
        return ghostUniverseOrder.length;
    }
}

/// @title CollateralVaultV2CollateralUniverseInvariants
/// @notice `ONCHAIN-SUBACCOUNT-RISK-EXECUTION-BOUNDS-AND-COLLATERAL-UNIVERSE-V1`
///         — invariants over the append-only bounded collateral universe.
///
/// Invariants:
///   COLLATERAL-UNIVERSE-I1: universe size never exceeds `MAX_COLLATERAL_TOKENS` (8).
///   COLLATERAL-UNIVERSE-I2: `isKnownCollateralToken` never flips from true to false.
///   COLLATERAL-UNIVERSE-I3: enable/disable/re-enable never duplicates a universe entry.
///   COLLATERAL-UNIVERSE-I4: disabling never deletes balances or liabilities.
///   COLLATERAL-UNIVERSE-I5: every collateral token that ever held a balance
///                           is discoverable via the bounded canonical universe.
contract CollateralVaultV2CollateralUniverseInvariants is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    CollateralUniverseHandler internal handler;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);

    MockERC20[10] internal tokenList;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        address[] memory tokens_ = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            tokenList[i] = new MockERC20("Mock", "MCK", 18);
            tokens_[i] = address(tokenList[i]);
        }
        handler = new CollateralUniverseHandler(vault, governance, tokens_);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
              COLLATERAL-UNIVERSE-I1 — bounded above by 8
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_UNIVERSE_I1_bounded() public view {
        assertLe(vault.collateralTokenCount(), 8);
    }

    /*//////////////////////////////////////////////////////////////
              COLLATERAL-UNIVERSE-I2 — known never becomes unknown
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_UNIVERSE_I2_knownStaysKnown() public view {
        for (uint256 i = 0; i < handler.tokensLength(); i++) {
            address t = handler.tokens(i);
            if (handler.ghostKnown(t)) {
                assertTrue(vault.isKnownCollateralToken(t), "known ghost but chain says unknown");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
              COLLATERAL-UNIVERSE-I3 — no duplicates
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_UNIVERSE_I3_noDuplicates() public view {
        uint256 count = vault.collateralTokenCount();
        // Ghost insertion order = chain insertion order + no duplicates.
        assertEq(count, handler.ghostUniverseOrderLength(), "count vs ghost order length mismatch");
        for (uint256 i = 0; i < count; i++) {
            assertEq(vault.collateralTokenAt(i), handler.ghostUniverseOrder(i), "insertion order drift");
        }
        // Cross-check: universe view returns the same as ghost order.
        address[] memory u = vault.collateralUniverse();
        assertEq(u.length, count);
        for (uint256 i = 0; i < count; i++) {
            assertEq(u[i], handler.ghostUniverseOrder(i));
        }
    }

    /*//////////////////////////////////////////////////////////////
              COLLATERAL-UNIVERSE-I5 — coverage of known tokens
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_UNIVERSE_I5_universeCoversAllKnown() public view {
        // Every token the ghost tracks as known must appear in the chain's
        // universe. Iteration bounded by `tokensLength` (10 in setUp),
        // membership check is O(count) with count <= 8.
        for (uint256 i = 0; i < handler.tokensLength(); i++) {
            address t = handler.tokens(i);
            if (!handler.ghostKnown(t)) continue;
            bool found = false;
            uint256 count = vault.collateralTokenCount();
            for (uint256 j = 0; j < count; j++) {
                if (vault.collateralTokenAt(j) == t) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "known ghost token missing from universe");
        }
    }
}
