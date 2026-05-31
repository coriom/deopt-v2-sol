// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function owner() external view returns (address);
    function decimals() external view returns (uint8);
}

/// @title TopUpRebateFundingAccount
/// @notice V2G-C safe-by-default helper for minting a small amount of
///         the testnet settlement asset (`REBATE_TOKEN`, e.g. mUSDC)
///         to `REBATE_FUNDING_ACCOUNT` so the V2G smoke maker rebates
///         can actually pay out.
/// @dev
///  IMPORTANT: this script targets **only** the testnet `REBATE_TOKEN`
///  contract — never `FeesManagerV2`, never any matching engine,
///  never any margin engine. It calls `mint(account, amount)` which
///  is `onlyOwner` on the `TestnetMockERC20` (see
///  `script/DeployTestnetAssets.s.sol`); on Base Sepolia the owner
///  is the DEPLOYER. The script reverts before any tx if the caller
///  is not the token's owner.
///
///  Required env in all cases:
///    - `DEPLOYER_PRIVATE_KEY` (= testnet token owner key)
///    - `REBATE_TOKEN`
///    - `REBATE_FUNDING_ACCOUNT`
///    - `REBATE_TOPUP_AMOUNT` (uint256 in the token's smallest unit;
///       e.g. 1_000_000 = 1 mUSDC at 6 decimals)
///
///  Mutating call gated by:
///    - `TOP_UP_REBATE_FUNDING_ACCOUNT_CONFIRM=true`
///
///  Hard-refuses (no transaction is sent):
///    - target token address has no code;
///    - caller is not the token's owner;
///    - `amount == 0`;
///    - destination is the zero address.
contract TopUpRebateFundingAccount is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address token;
        address fundingAccount;
        uint256 amount;
        bool confirmed;
    }

    struct Snapshot {
        address tokenOwner;
        uint8 tokenDecimals;
        uint256 fundingAccountBalance;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error TokenUnset();
    error FundingAccountUnset();
    error AmountZero();
    error NoCodeAt(string name, address target);
    error NotTokenOwner(address caller, address owner);
    error BalanceDidNotIncrease(uint256 before_, uint256 after_, uint256 expectedDelta);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory before_ = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot("before", before_);

        _validatePreconditions(inputs, before_);

        if (!inputs.confirmed) {
            console2.log("TOP_UP_REBATE_FUNDING_ACCOUNT_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        IMintableERC20(inputs.token).mint(inputs.fundingAccount, inputs.amount);
        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, before_, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.caller = vm.addr(deployerPk);
        inputs.token = _envAddressOrZero("REBATE_TOKEN");
        inputs.fundingAccount = _envAddressOrZero("REBATE_FUNDING_ACCOUNT");
        inputs.amount = vm.envUint("REBATE_TOPUP_AMOUNT");
        inputs.confirmed = vm.envOr("TOP_UP_REBATE_FUNDING_ACCOUNT_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.token == address(0)) revert TokenUnset();
        if (inputs.token.code.length == 0) revert NoCodeAt("REBATE_TOKEN", inputs.token);
        if (inputs.fundingAccount == address(0)) revert FundingAccountUnset();
        if (inputs.amount == 0) revert AmountZero();
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        IMintableERC20 token = IMintableERC20(inputs.token);
        try token.owner() returns (address owner) {
            snap.tokenOwner = owner;
        } catch {}
        try token.decimals() returns (uint8 d) {
            snap.tokenDecimals = d;
        } catch {}
        snap.fundingAccountBalance = token.balanceOf(inputs.fundingAccount);
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.confirmed && inputs.caller != snap.tokenOwner) {
            revert NotTokenOwner(inputs.caller, snap.tokenOwner);
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory before_, Snapshot memory after_) internal pure {
        uint256 expected = before_.fundingAccountBalance + inputs.amount;
        if (after_.fundingAccountBalance != expected) {
            revert BalanceDidNotIncrease(before_.fundingAccountBalance, after_.fundingAccountBalance, inputs.amount);
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("Testnet mUSDC top-up preflight V2G-C");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("REBATE_TOKEN", inputs.token);
        console2.log("REBATE_FUNDING_ACCOUNT", inputs.fundingAccount);
        console2.log("REBATE_TOPUP_AMOUNT", inputs.amount);
        console2.log("TOP_UP_REBATE_FUNDING_ACCOUNT_CONFIRM", inputs.confirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" REBATE_TOKEN.owner()", snap.tokenOwner);
        console2.log(" REBATE_TOKEN.decimals()", snap.tokenDecimals);
        console2.log(" REBATE_TOKEN.balanceOf(funder)", snap.fundingAccountBalance);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
