// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {TestnetMockERC20} from "./DeployTestnetAssets.s.sol";

interface ICollateralVaultDeposit {
    function deposit(address token, uint256 amount) external;
    function balances(address account, address token) external view returns (uint256);
    function launchActiveCollateral(address token) external view returns (bool);
    function depositsPaused() external view returns (bool);
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @title PrepareSmokeV1Accounts
/// @notice Safe-by-default V2F-J2 helper that, in a single broadcast, provisions two
///         testnet EOAs for the default/V1 perp smoke trade on the V2F-H NEW
///         PerpEngine. The deployer (testnet mUSDC owner) mints mUSDC and dusts a
///         small amount of native ETH to both EOAs, then **each EOA itself** approves
///         and deposits to `CollateralVault`. The script is testnet-only and refuses
///         Base mainnet.
/// @dev
///  Confirm flag (single):
///    - `PREPARE_SMOKE_V1_ACCOUNTS_CONFIRM=true` is required to send any tx.
///
///  Required env when confirmed:
///    - `DEPLOYER_PRIVATE_KEY` (must equal `TestnetMockERC20.owner()` on the
///       collateral token and must hold enough native ETH to dust both EOAs);
///    - `PERP_SMOKE_BUYER_PRIVATE_KEY` (operator-supplied; never echoed);
///    - `PERP_SMOKE_SELLER_PRIVATE_KEY` (operator-supplied; never echoed);
///    - `BASE_COLLATERAL_TOKEN` (= testnet mUSDC address);
///    - `COLLATERAL_VAULT`.
///
///  Defaults:
///    - `PERP_SMOKE_FUND_USDC_AMOUNT_NATIVE = 1_000_000` (1 mUSDC at 6 decimals,
///       plenty for the V1 fee on a smoke at size1e8 = 1, price = $3000).
///    - `PERP_SMOKE_FUND_ETH_WEI = 300_000_000_000_000` (0.0003 ETH per EOA, enough
///       for one `approve` + `deposit` + `executeTrade` at testnet gas prices).
///
///  Hard-refuses:
///    - chainId 8453 (Base mainnet);
///    - buyer or seller private key missing;
///    - buyer == seller;
///    - deployer is not the testnet mUSDC owner (mint would revert);
///    - `CollateralVault.launchActiveCollateral(BASE_COLLATERAL_TOKEN) = false`
///       under `collateralRestrictionMode = true`;
///    - `CollateralVault.depositsPaused() = true`.
///
///  Forbidden surface: no calls to `PerpEngine`, `PerpMatchingEngine`,
///  `FeesManagerV2`, `setFeesManagerV2`, `setUseFeesManagerV2`, `setFeeConsumer`,
///  `setFeeRecipient`. The post-state assertion verifies only mUSDC balances,
///  vault balances, and native ETH transfers.
contract PrepareSmokeV1Accounts is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address deployer;
        uint256 deployerPk;
        uint256 buyerPk;
        uint256 sellerPk;
        address buyer;
        address seller;
        address mUsdc;
        address collateralVault;
        uint256 fundUsdcNative;
        uint256 fundEthWei;
        bool confirmed;
    }

    struct Snapshot {
        address mUsdcOwner;
        uint8 mUsdcDecimals;
        bool launchActive;
        bool depositsPaused;
        uint256 buyerEthWei;
        uint256 sellerEthWei;
        uint256 buyerMUsdc;
        uint256 sellerMUsdc;
        uint256 buyerVaultBalance;
        uint256 sellerVaultBalance;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error MainnetForbidden();
    error BuyerKeyMissing();
    error SellerKeyMissing();
    error BuyerSellerSameAddress();
    error MockUsdcUnset();
    error CollateralVaultUnset();
    error NoCodeAt(string name, address target);
    error DeployerNotMockUsdcOwner(address caller, address owner);
    error CollateralNotLaunchActive(address token);
    error VaultDepositsPaused();
    error MintDidNotTake(address eoa, uint256 expected, uint256 actual);
    error VaultDepositDidNotTake(address eoa, uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DEFAULT_FUND_USDC_NATIVE = 1_000_000; // 1 mUSDC (6 decimals)
    uint256 internal constant DEFAULT_FUND_ETH_WEI = 300_000_000_000_000; // 0.0003 ETH

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
            console2.log("PREPARE_SMOKE_V1_ACCOUNTS_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        // Tier 1: deployer mints mUSDC + sends ETH dust to both EOAs.
        vm.startBroadcast(inputs.deployerPk);
        TestnetMockERC20(inputs.mUsdc).mint(inputs.buyer, inputs.fundUsdcNative);
        TestnetMockERC20(inputs.mUsdc).mint(inputs.seller, inputs.fundUsdcNative);
        if (inputs.fundEthWei != 0) {
            (bool ok1,) = inputs.buyer.call{value: inputs.fundEthWei}("");
            require(ok1, "ETH dust to buyer failed");
            (bool ok2,) = inputs.seller.call{value: inputs.fundEthWei}("");
            require(ok2, "ETH dust to seller failed");
        }
        vm.stopBroadcast();

        // Tier 2: buyer approves + deposits.
        vm.startBroadcast(inputs.buyerPk);
        IERC20Like(inputs.mUsdc).approve(inputs.collateralVault, inputs.fundUsdcNative);
        ICollateralVaultDeposit(inputs.collateralVault).deposit(inputs.mUsdc, inputs.fundUsdcNative);
        vm.stopBroadcast();

        // Tier 3: seller approves + deposits.
        vm.startBroadcast(inputs.sellerPk);
        IERC20Like(inputs.mUsdc).approve(inputs.collateralVault, inputs.fundUsdcNative);
        ICollateralVaultDeposit(inputs.collateralVault).deposit(inputs.mUsdc, inputs.fundUsdcNative);
        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, before_, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        inputs.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.deployer = vm.addr(inputs.deployerPk);

        inputs.buyerPk = vm.envOr("PERP_SMOKE_BUYER_PRIVATE_KEY", uint256(0));
        inputs.sellerPk = vm.envOr("PERP_SMOKE_SELLER_PRIVATE_KEY", uint256(0));

        if (inputs.buyerPk != 0) inputs.buyer = vm.addr(inputs.buyerPk);
        if (inputs.sellerPk != 0) inputs.seller = vm.addr(inputs.sellerPk);

        inputs.mUsdc = _envAddressOrZero("BASE_COLLATERAL_TOKEN");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");

        inputs.fundUsdcNative = vm.envOr("PERP_SMOKE_FUND_USDC_AMOUNT_NATIVE", DEFAULT_FUND_USDC_NATIVE);
        inputs.fundEthWei = vm.envOr("PERP_SMOKE_FUND_ETH_WEI", DEFAULT_FUND_ETH_WEI);

        inputs.confirmed = vm.envOr("PREPARE_SMOKE_V1_ACCOUNTS_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (block.chainid == 8453) revert MainnetForbidden();
        if (inputs.buyerPk == 0) revert BuyerKeyMissing();
        if (inputs.sellerPk == 0) revert SellerKeyMissing();
        if (inputs.buyer == inputs.seller) revert BuyerSellerSameAddress();
        if (inputs.mUsdc == address(0)) revert MockUsdcUnset();
        if (inputs.mUsdc.code.length == 0) revert NoCodeAt("BASE_COLLATERAL_TOKEN", inputs.mUsdc);
        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.collateralVault.code.length == 0) revert NoCodeAt("COLLATERAL_VAULT", inputs.collateralVault);
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        snap.mUsdcOwner = TestnetMockERC20(inputs.mUsdc).owner();
        snap.mUsdcDecimals = IERC20Like(inputs.mUsdc).decimals();
        snap.launchActive = ICollateralVaultDeposit(inputs.collateralVault).launchActiveCollateral(inputs.mUsdc);
        try ICollateralVaultDeposit(inputs.collateralVault).depositsPaused() returns (bool p) {
            snap.depositsPaused = p;
        } catch {}

        snap.buyerEthWei = inputs.buyer.balance;
        snap.sellerEthWei = inputs.seller.balance;
        snap.buyerMUsdc = IERC20Like(inputs.mUsdc).balanceOf(inputs.buyer);
        snap.sellerMUsdc = IERC20Like(inputs.mUsdc).balanceOf(inputs.seller);
        snap.buyerVaultBalance = ICollateralVaultDeposit(inputs.collateralVault).balances(inputs.buyer, inputs.mUsdc);
        snap.sellerVaultBalance = ICollateralVaultDeposit(inputs.collateralVault).balances(inputs.seller, inputs.mUsdc);
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.confirmed) {
            if (snap.mUsdcOwner != inputs.deployer) {
                revert DeployerNotMockUsdcOwner(inputs.deployer, snap.mUsdcOwner);
            }
            if (!snap.launchActive) revert CollateralNotLaunchActive(inputs.mUsdc);
            if (snap.depositsPaused) revert VaultDepositsPaused();
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory before_, Snapshot memory after_) internal pure {
        // mUSDC balance check: each EOA received `fundUsdcNative` and then transferred it
        // to the vault. Net change at the EOA level should be zero after mint+deposit.
        uint256 buyerExpectedNet = before_.buyerMUsdc;
        if (after_.buyerMUsdc != buyerExpectedNet) {
            revert MintDidNotTake(inputs.buyer, buyerExpectedNet, after_.buyerMUsdc);
        }
        uint256 sellerExpectedNet = before_.sellerMUsdc;
        if (after_.sellerMUsdc != sellerExpectedNet) {
            revert MintDidNotTake(inputs.seller, sellerExpectedNet, after_.sellerMUsdc);
        }

        // Vault balance MUST have increased by exactly fundUsdcNative for each EOA.
        if (after_.buyerVaultBalance != before_.buyerVaultBalance + inputs.fundUsdcNative) {
            revert VaultDepositDidNotTake(
                inputs.buyer, before_.buyerVaultBalance + inputs.fundUsdcNative, after_.buyerVaultBalance
            );
        }
        if (after_.sellerVaultBalance != before_.sellerVaultBalance + inputs.fundUsdcNative) {
            revert VaultDepositDidNotTake(
                inputs.seller, before_.sellerVaultBalance + inputs.fundUsdcNative, after_.sellerVaultBalance
            );
        }
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("Smoke V1 account preparation preflight V2F-J2");
        console2.log("chainId", block.chainid);
        console2.log("deployer (sanitized, no key)", inputs.deployer);
        console2.log("buyer  (derived from PERP_SMOKE_BUYER_PRIVATE_KEY)", inputs.buyer);
        console2.log("seller (derived from PERP_SMOKE_SELLER_PRIVATE_KEY)", inputs.seller);
        console2.log("BASE_COLLATERAL_TOKEN (mUSDC)", inputs.mUsdc);
        console2.log("COLLATERAL_VAULT", inputs.collateralVault);
        console2.log("PERP_SMOKE_FUND_USDC_AMOUNT_NATIVE", inputs.fundUsdcNative);
        console2.log("PERP_SMOKE_FUND_ETH_WEI", inputs.fundEthWei);
        console2.log("PREPARE_SMOKE_V1_ACCOUNTS_CONFIRM", inputs.confirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" mUSDC.owner()", snap.mUsdcOwner);
        console2.log(" mUSDC.decimals()", uint256(snap.mUsdcDecimals));
        console2.log(" Vault.launchActiveCollateral(mUSDC)", snap.launchActive);
        console2.log(" Vault.depositsPaused()", snap.depositsPaused);
        console2.log(" buyer  ETH balance (wei)", snap.buyerEthWei);
        console2.log(" seller ETH balance (wei)", snap.sellerEthWei);
        console2.log(" buyer  mUSDC balance (native)", snap.buyerMUsdc);
        console2.log(" seller mUSDC balance (native)", snap.sellerMUsdc);
        console2.log(" buyer  Vault.balances(buyer, mUSDC)", snap.buyerVaultBalance);
        console2.log(" seller Vault.balances(seller, mUSDC)", snap.sellerVaultBalance);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
