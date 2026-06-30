// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

/// @dev Minimal interface — we only need `mint(address,uint256)`.
///      Used by `FundTestnetFaucet` to call into the deployed
///      `TestnetMockERC20` instances (which expose this exact
///      signature, gated by `onlyOwner`).
interface IMintableMock {
    function mint(address to, uint256 amount) external;
}

/// @title FundTestnetFaucet
/// @notice TESTNET-PUBLIC-FAUCET-CONTRACT-V1 — mints mUSDC / mWETH /
///         mWBTC reserves to the deployed `TestnetFaucet` address.
///         Run separately from the deploy script so the operator can
///         pause / reconfigure / re-fund without redeploying.
///
/// @dev Requires the broadcaster (DEPLOYER_PRIVATE_KEY) to be the
///      current `owner()` of each `TestnetMockERC20` — otherwise
///      `mint(...)` reverts with `NotOwner()`. The deployer EOA
///      `0xc35F…3C27` was the original owner of all three tokens
///      per `deployments/base-sepolia.manifest.draft.json`.
///
///      Safety guards (mirror `DeployTestnetAssets.s.sol`):
///        * `TESTNET_MOCKS_ENABLED=true` required.
///        * `block.chainid` must equal 84532 (Base Sepolia); Base
///          mainnet (8453) is hard-refused.
///
///      Required env (names only — never print values):
///        * `DEPLOYER_PRIVATE_KEY`                — broadcaster (must
///                                                  be token owner)
///        * `TESTNET_FAUCET_ADDRESS`              — deployed faucet
///        * `TESTNET_FAUCET_MUSDC_ADDRESS`        — mUSDC token (opt)
///        * `TESTNET_FAUCET_MWETH_ADDRESS`        — mWETH token (opt)
///        * `TESTNET_FAUCET_MWBTC_ADDRESS`        — mWBTC token (opt)
///        * `TESTNET_FAUCET_MUSDC_RESERVE_AMOUNT` — wei to mint into
///                                                  the faucet (opt)
///        * `TESTNET_FAUCET_MWETH_RESERVE_AMOUNT` — (opt)
///        * `TESTNET_FAUCET_MWBTC_RESERVE_AMOUNT` — (opt)
///
///      For any token whose address OR amount is unset, the mint is
///      skipped. Defaults below provide reasonable "fund for ~1000
///      claims" amounts.
contract FundTestnetFaucet is Script {
    function run() external {
        _requireTestnetFundRun();

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address faucet = vm.envAddress("TESTNET_FAUCET_ADDRESS");

        address mUSDC = vm.envOr("TESTNET_FAUCET_MUSDC_ADDRESS", address(0));
        address mWETH = vm.envOr("TESTNET_FAUCET_MWETH_ADDRESS", address(0));
        address mWBTC = vm.envOr("TESTNET_FAUCET_MWBTC_ADDRESS", address(0));

        // Default reserves cover ~1000 claims at the default
        // per-claim amounts: 1_000_000 mUSDC, 1_000 mWETH, 500 mWBTC.
        uint256 mUSDCReserve = vm.envOr("TESTNET_FAUCET_MUSDC_RESERVE_AMOUNT", uint256(1_000_000 * 1e6));
        uint256 mWETHReserve = vm.envOr("TESTNET_FAUCET_MWETH_RESERVE_AMOUNT", uint256(1_000 * 1e18));
        uint256 mWBTCReserve = vm.envOr("TESTNET_FAUCET_MWBTC_RESERVE_AMOUNT", uint256(500 * 1e8));

        vm.startBroadcast(deployerPrivateKey);

        if (mUSDC != address(0) && mUSDCReserve != 0) {
            IMintableMock(mUSDC).mint(faucet, mUSDCReserve);
        }
        if (mWETH != address(0) && mWETHReserve != 0) {
            IMintableMock(mWETH).mint(faucet, mWETHReserve);
        }
        if (mWBTC != address(0) && mWBTCReserve != 0) {
            IMintableMock(mWBTC).mint(faucet, mWBTCReserve);
        }

        vm.stopBroadcast();

        _logSummary(faucet, mUSDC, mWETH, mWBTC, mUSDCReserve, mWETHReserve, mWBTCReserve);
    }

    function _requireTestnetFundRun() internal view {
        if (!vm.envOr("TESTNET_MOCKS_ENABLED", false)) {
            revert("TESTNET_MOCKS_ENABLED false");
        }
        if (block.chainid == 8453) revert("Base mainnet not allowed");
        if (block.chainid != 84532) revert("FundTestnetFaucet: chain id must be 84532 (Base Sepolia)");
        uint256 expectedChainId = vm.envOr("CHAIN_ID", block.chainid);
        if (expectedChainId != block.chainid) revert("CHAIN_ID mismatch");
    }

    function _logSummary(
        address faucet,
        address mUSDC,
        address mWETH,
        address mWBTC,
        uint256 mUSDCReserve,
        uint256 mWETHReserve,
        uint256 mWBTCReserve
    ) internal view {
        console2.log("TestnetFaucet funding complete");
        console2.log("chainId", block.chainid);
        console2.log("faucet", faucet);
        if (mUSDC != address(0)) console2.log("mUSDC reserve minted (wei)", mUSDCReserve);
        if (mWETH != address(0)) console2.log("mWETH reserve minted (wei)", mWETHReserve);
        if (mWBTC != address(0)) console2.log("mWBTC reserve minted (wei)", mWBTCReserve);
    }
}
