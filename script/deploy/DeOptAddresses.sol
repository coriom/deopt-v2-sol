// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Remplir ces adresses par réseau (Base / Ethereum / arbitrum…).
library DeOptAddresses {
    // Collateral tokens
    address internal constant USDC = address(0);
    address internal constant WETH = address(0);
    address internal constant WBTC = address(0);

    // ERC-4626 vaults (yield targets) par collateral
    address internal constant USDC_ERC4626_VAULT = address(0);
    address internal constant WETH_ERC4626_VAULT = address(0);
    address internal constant WBTC_ERC4626_VAULT = address(0);

    // Oracles / routers
    address internal constant ORACLE_ROUTER = address(0);
}
