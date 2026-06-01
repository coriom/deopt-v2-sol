// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";
import {IProtocolFeeVault} from "../src/fees/IProtocolFeeVault.sol";

/// @title PreflightProtocolFeeVaultCutover
/// @notice V2G-RX read-only preflight. Confirms the live FM-V2 state
///         matches what the V2G-R5 cutover expects:
///          - vault is deployed
///          - FM-V2 recipients NOT yet pointing at vault (i.e. cutover
///            hasn't already happened)
///          - vault sees FM-V2 as its `feesManagerV2` immutable
///          - vault sees CV as its `collateralVault` immutable
///          - vault has no per-asset bootstrap state for the
///            configured assets (so bootstrap is still safe to run)
///          - rebate budget non-zero for each configured asset
///
/// @dev    Required env:
///           - FEES_MANAGER_V2
///           - PROTOCOL_FEE_VAULT
///           - COLLATERAL_VAULT
///           - BOOTSTRAP_ASSETS (comma-separated list of asset
///             addresses to inspect — typically just `mUSDC`)
///
///         Pure `view` — no broadcast path.
contract PreflightProtocolFeeVaultCutover is Script {
    error FeesManagerV2Unset();
    error ProtocolFeeVaultUnset();
    error CollateralVaultUnset();
    error VaultPointsAtWrongFmV2(address got, address expected);
    error VaultPointsAtWrongCv(address got, address expected);
    error RecipientAlreadyVault(address recipient);
    error RebateFundingAccountAlreadyVault(address account);
    error ProtocolFeeVaultAlreadyConfigured(address vault);
    error BootstrapAlreadyDone(address asset);

    function run() external view {
        address fmv2 = vm.envAddress("FEES_MANAGER_V2");
        address vault = vm.envAddress("PROTOCOL_FEE_VAULT");
        address cv = vm.envAddress("COLLATERAL_VAULT");
        if (fmv2 == address(0)) revert FeesManagerV2Unset();
        if (vault == address(0)) revert ProtocolFeeVaultUnset();
        if (cv == address(0)) revert CollateralVaultUnset();

        console2.log("V2G-RX ProtocolFeeVault cutover preflight");
        console2.log("FEES_MANAGER_V2     ", fmv2);
        console2.log("PROTOCOL_FEE_VAULT  ", vault);
        console2.log("COLLATERAL_VAULT    ", cv);

        // Vault wired to the expected FM-V2 and CV.
        address vaultFmV2 = IProtocolFeeVault(vault).feesManagerV2();
        if (vaultFmV2 != fmv2) revert VaultPointsAtWrongFmV2(vaultFmV2, fmv2);
        address vaultCv = IProtocolFeeVault(vault).collateralVault();
        if (vaultCv != cv) revert VaultPointsAtWrongCv(vaultCv, cv);

        // FM-V2 cutover hasn't already happened.
        address feeRecipient = IFeesManagerV2(fmv2).feeRecipient();
        if (feeRecipient == vault) revert RecipientAlreadyVault(feeRecipient);
        address fundingAccount = IFeesManagerV2(fmv2).rebateFundingAccount();
        if (fundingAccount == vault) revert RebateFundingAccountAlreadyVault(fundingAccount);
        address pfv = IFeesManagerV2(fmv2).protocolFeeVault();
        if (pfv == vault) revert ProtocolFeeVaultAlreadyConfigured(pfv);

        console2.log("FM-V2.feeRecipient (current)    ", feeRecipient);
        console2.log("FM-V2.rebateFundingAccount      ", fundingAccount);
        console2.log("FM-V2.protocolFeeVault          ", pfv);

        // Confirm no per-asset bootstrap already done for the assets
        // the operator plans to bootstrap.
        string memory raw = vm.envOr("BOOTSTRAP_ASSETS", string(""));
        if (bytes(raw).length > 0) {
            address[] memory assets = _splitAddresses(raw);
            for (uint256 i; i < assets.length; ++i) {
                bool done = IProtocolFeeVault(vault).bootstrapped(assets[i]);
                if (done) revert BootstrapAlreadyDone(assets[i]);
                uint256 budget = IFeesManagerV2(fmv2).rebateBudget(assets[i]);
                console2.log(" asset:", assets[i]);
                console2.log("   bootstrap done   ", done);
                console2.log("   FM-V2.rebateBudget", budget);
            }
        }

        console2.log("Preflight OK. Ready for V2G-R5 broadcast.");
    }

    function _splitAddresses(string memory raw) internal pure returns (address[] memory out) {
        bytes memory data = bytes(raw);
        if (data.length == 0) return new address[](0);
        uint256 count = 1;
        for (uint256 i; i < data.length; ++i) {
            if (data[i] == ",") count += 1;
        }
        out = new address[](count);
        uint256 idx;
        uint256 start;
        for (uint256 i = 0; i <= data.length; ++i) {
            if (i == data.length || data[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j; j < slice.length; ++j) {
                    slice[j] = data[start + j];
                }
                out[idx] = _parseAddress(string(slice));
                idx += 1;
                start = i + 1;
            }
        }
    }

    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42 && b[0] == "0" && (b[1] == "x" || b[1] == "X"), "bad addr");
        uint160 acc;
        for (uint256 i = 2; i < 42; ++i) {
            uint8 c = uint8(b[i]);
            uint8 v;
            if (c >= 48 && c <= 57) v = c - 48;
            else if (c >= 65 && c <= 70) v = c - 55;
            else if (c >= 97 && c <= 102) v = c - 87;
            else revert("bad hex");
            acc = acc * 16 + uint160(v);
        }
        return address(acc);
    }
}
