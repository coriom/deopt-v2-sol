// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestnetFaucet} from "../src/testnet/TestnetFaucet.sol";

/// @title DeployTestnetFaucet
/// @notice TESTNET-PUBLIC-FAUCET-CONTRACT-V1 — deploys the
///         public-callable, reserve-based testnet faucet and
///         (optionally) registers the three mock tokens
///         (mUSDC / mWETH / mWBTC) with their per-claim amounts.
///
/// @dev DOES NOT mint or transfer any reserve tokens. The operator
///      funds the faucet separately via `FundTestnetFaucet.s.sol`
///      (or `cast send <mUSDC> "mint(address,uint256)" <faucet>
///      <amount>` if they prefer raw calls).
///
///      Safety guards on `run()`:
///        * `TESTNET_MOCKS_ENABLED=true` must be set.
///        * `block.chainid` must equal 84532 (Base Sepolia) — refuses
///          Base mainnet (8453) and every other chain id.
///
///      Required env (names only — never print values):
///        * `DEPLOYER_PRIVATE_KEY`           — broadcaster
///        * `TESTNET_MOCKS_ENABLED=true`
///        * `CHAIN_ID=84532` (optional cross-check)
///
///      Optional env (with safe defaults):
///        * `TESTNET_FAUCET_OWNER`           — owner of the deployed
///                                             faucet (defaults to
///                                             the deployer).
///        * `TESTNET_FAUCET_COOLDOWN_SECONDS`— per-caller rate-limit
///                                             window in seconds
///                                             (default 21600 = 6h).
///        * `TESTNET_FAUCET_MUSDC_ADDRESS`   — mUSDC address to
///                                             register.
///        * `TESTNET_FAUCET_MWETH_ADDRESS`   — mWETH address.
///        * `TESTNET_FAUCET_MWBTC_ADDRESS`   — mWBTC address.
///        * `TESTNET_FAUCET_MUSDC_PER_CLAIM` — wei amount per claim
///                                             (default 1_000 * 1e6).
///        * `TESTNET_FAUCET_MWETH_PER_CLAIM` — default 1 * 1e18.
///        * `TESTNET_FAUCET_MWBTC_PER_CLAIM` — default 5e7 (0.5 mWBTC).
///
///      If a token address env is unset (or `0x0`), the corresponding
///      `setToken` call is skipped — the operator can register it
///      later via a follow-up tx.
contract DeployTestnetFaucet is Script {
    function run() external returns (address faucet) {
        _requireTestnetFaucetRun();

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address faucetOwner = vm.envOr("TESTNET_FAUCET_OWNER", deployer);
        uint256 cooldownSeconds = vm.envOr("TESTNET_FAUCET_COOLDOWN_SECONDS", uint256(6 hours));

        address mUSDC = vm.envOr("TESTNET_FAUCET_MUSDC_ADDRESS", address(0));
        address mWETH = vm.envOr("TESTNET_FAUCET_MWETH_ADDRESS", address(0));
        address mWBTC = vm.envOr("TESTNET_FAUCET_MWBTC_ADDRESS", address(0));

        uint256 mUSDCPerClaim = vm.envOr("TESTNET_FAUCET_MUSDC_PER_CLAIM", uint256(1_000 * 1e6));
        uint256 mWETHPerClaim = vm.envOr("TESTNET_FAUCET_MWETH_PER_CLAIM", uint256(1 * 1e18));
        uint256 mWBTCPerClaim = vm.envOr("TESTNET_FAUCET_MWBTC_PER_CLAIM", uint256(5e7));

        vm.startBroadcast(deployerPrivateKey);

        TestnetFaucet deployed = new TestnetFaucet(faucetOwner, cooldownSeconds);
        faucet = address(deployed);

        // `setToken` calls go through `onlyOwner`. If the operator
        // chose a different `TESTNET_FAUCET_OWNER`, the deployer is
        // NOT the owner and these calls would revert — in that case
        // the operator must register the tokens themselves from the
        // owner key. Skip the auto-registration when ownership
        // differs.
        if (faucetOwner == deployer) {
            if (mUSDC != address(0)) {
                deployed.setToken(IERC20(mUSDC), mUSDCPerClaim);
            }
            if (mWETH != address(0)) {
                deployed.setToken(IERC20(mWETH), mWETHPerClaim);
            }
            if (mWBTC != address(0)) {
                deployed.setToken(IERC20(mWBTC), mWBTCPerClaim);
            }
        }

        vm.stopBroadcast();

        _logEnvLines(faucet, faucetOwner, cooldownSeconds, mUSDC, mWETH, mWBTC);
    }

    function _requireTestnetFaucetRun() internal view {
        if (!vm.envOr("TESTNET_MOCKS_ENABLED", false)) {
            revert("TESTNET_MOCKS_ENABLED false");
        }
        if (block.chainid == 8453) revert("Base mainnet not allowed");
        if (block.chainid != 84532) revert("DeployTestnetFaucet: chain id must be 84532 (Base Sepolia)");
        uint256 expectedChainId = vm.envOr("CHAIN_ID", block.chainid);
        if (expectedChainId != block.chainid) revert("CHAIN_ID mismatch");
    }

    function _logEnvLines(
        address faucet,
        address faucetOwner,
        uint256 cooldownSeconds,
        address mUSDC,
        address mWETH,
        address mWBTC
    ) internal view {
        console2.log("TestnetFaucet deployment");
        console2.log("chainId", block.chainid);
        console2.log("faucet", faucet);
        console2.log("faucetOwner", faucetOwner);
        console2.log("cooldownSeconds", cooldownSeconds);
        console2.log("");
        console2.log("Configured tokens (skipped if owner != deployer):");
        if (mUSDC != address(0)) console2.log("mUSDC", mUSDC);
        if (mWETH != address(0)) console2.log("mWETH", mWETH);
        if (mWBTC != address(0)) console2.log("mWBTC", mWBTC);
        console2.log("");
        console2.log("Frontend env line to publish (copy verbatim):");
        console2.log(string.concat("NEXT_PUBLIC_TESTNET_FAUCET_ADDRESS=", vm.toString(faucet)));
        console2.log("");
        console2.log("Funding hint: see script/FundTestnetFaucet.s.sol or mint reserves directly:");
        console2.log("  cast send <token> 'mint(address,uint256)' <faucet> <wei> --rpc-url $RPC_URL");
    }
}
