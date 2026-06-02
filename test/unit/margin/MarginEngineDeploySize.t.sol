// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {MarginEngine} from "../../../src/margin/MarginEngine.sol";

/// @title MarginEngineDeploySizeTest
/// @notice V2G-P guard: hard-fails CI if `MarginEngine`'s runtime
///         bytecode crosses the EIP-170 24,576-byte contract size
///         limit. Without this test the only signal of a size
///         regression is a Foundry "Do you wish to continue?"
///         warning at broadcast time — which an operator can
///         override, sending an on-chain CREATE that the EVM then
///         rejects (status=0). The
///         `2026-06-02 0xf1d41f2a...` failed deploy on Base Sepolia
///         (V2G-P MarginEngine attempt) is the historical incident
///         that motivates this guard.
/// @dev    The test measures `address(engine).code.length` after
///         the constructor runs — that's the *runtime* bytecode
///         that EIP-170 actually limits, not the larger
///         deployment-time initcode.
contract MarginEngineDeploySizeTest is Test {
    /// @dev EIP-170 contract code size cap (24,576 bytes).
    uint256 internal constant EIP170_LIMIT = 24_576;

    function test_marginEngine_runtime_under_eip170() public {
        // The MarginEngine constructor requires real addresses for
        // registry / vault / oracle and refuses zero; we use the
        // {address(this)} as a placeholder for all four since the
        // constructor doesn't read code at those addresses — it just
        // assigns them to storage.
        address placeholder = address(this);

        MarginEngine engine = new MarginEngine(placeholder, placeholder, placeholder, placeholder);

        uint256 runtimeSize = address(engine).code.length;
        emit log_named_uint("MarginEngine runtime size (bytes)", runtimeSize);
        emit log_named_uint("EIP-170 limit (bytes)", EIP170_LIMIT);

        assertLe(runtimeSize, EIP170_LIMIT, "MarginEngine exceeds EIP-170 limit");
    }
}
