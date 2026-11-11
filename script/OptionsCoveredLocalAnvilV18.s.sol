// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IOracle} from "../src/oracle/IOracle.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {CoveredCallMarginEngine} from "../src/experimental/CoveredCallMarginEngine.sol";

contract CoveredLocalTokenV18 is ERC20 {
    uint8 private immutable digits;

    constructor(string memory name_, uint8 digits_) ERC20(name_, name_) {
        digits = digits_;
    }

    function decimals() public view override returns (uint8) {
        return digits;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Deterministic local price; this does not qualify a live oracle.
contract CoveredLocalOracleV18 is IOracle {
    uint256 public immutable updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function getPrice(address, address) external view returns (uint256, uint256) {
        return (2_250e8, updatedAt);
    }

    function getPriceSafe(address, address) external view returns (uint256, uint256, bool) {
        return (2_250e8, updatedAt, true);
    }
}

/// @dev Two matcher calls in one local Anvil transaction.
contract CoveredLocalTradeBatchV18 {
    function executeTwo(
        OptionMatchingEngine matcher,
        OptionMatchingEngine.OptionTrade calldata first,
        bytes calldata firstBuyerSignature,
        bytes calldata firstSellerSignature,
        OptionMatchingEngine.OptionTrade calldata second,
        bytes calldata secondBuyerSignature,
        bytes calldata secondSellerSignature
    ) external {
        matcher.executeTrade(first, firstBuyerSignature, firstSellerSignature);
        matcher.executeTrade(second, secondBuyerSignature, secondSellerSignature);
    }
}

/// @notice Local Anvil receipt fixture for the V18 covered engine only.
contract OptionsCoveredLocalAnvilV18 is Script {
    uint256 private constant OWNER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 private constant BUYER_PK = 0xB0B;
    uint256 private constant SELLER_PK = 0xCA11;

    function run() external {
        require(block.chainid == 84532, "local chain ID required");
        require(vm.rpc("anvil_nodeInfo", "[]").length != 0, "Anvil RPC required");
        address buyer = vm.addr(BUYER_PK);
        address seller = vm.addr(SELLER_PK);
        address owner = vm.addr(OWNER_PK);

        vm.startBroadcast(OWNER_PK);
        CoveredLocalTokenV18 weth = new CoveredLocalTokenV18("mWETH", 18);
        CoveredLocalTokenV18 usdc = new CoveredLocalTokenV18("mUSDC", 6);
        CoveredLocalOracleV18 oracle = new CoveredLocalOracleV18();
        OptionProductRegistry registry = new OptionProductRegistry(owner);
        registry.setSettlementAssetAllowed(address(usdc), true);
        registry.setUnderlyingConfig(
            address(weth), OptionProductRegistry.UnderlyingConfig(address(oracle), 3_000, 3_000, 0, 2_000, true)
        );
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint256 optionId = registry.createSeries(address(weth), address(usdc), expiry, 2_250e8, true, true);
        CoveredCallMarginEngine engine =
            new CoveredCallMarginEngine(owner, address(registry), optionId, address(oracle), 1_500, 48 hours);
        if (vm.envOr("OPTIONS_V20_NONZERO_FEES", false)) {
            engine.configureFees(owner, 50, 250);
        }
        OptionMatchingEngine matcher = new OptionMatchingEngine(owner, address(engine), address(registry));
        CoveredLocalTradeBatchV18 batch = new CoveredLocalTradeBatchV18();
        matcher.setExecutor(address(batch), true);
        matcher.freezeConfiguration();
        engine.bindMatchingEngine(address(matcher));
        engine.setPaused(false);
        weth.mint(seller, 2e18);
        usdc.mint(buyer, 5_000e6);
        payable(buyer).transfer(1 ether);
        payable(seller).transfer(1 ether);
        vm.stopBroadcast();

        vm.startBroadcast(SELLER_PK);
        weth.approve(address(engine), 2e18);
        vm.stopBroadcast();
        vm.startBroadcast(BUYER_PK);
        uint256 localBuyerAllowance = vm.envOr("OPTIONS_V19_DEPLOY_ONLY", false)
            ? (vm.envOr("OPTIONS_V20_NONZERO_FEES", false) ? 200_050_000 : 200e6)
            : 5_000e6;
        usdc.approve(address(engine), localBuyerAllowance);
        vm.stopBroadcast();

        if (vm.envOr("OPTIONS_V19_DEPLOY_ONLY", false)) {
            console2.log("V18_ENGINE", address(engine));
            console2.log("V18_MATCHER", address(matcher));
            console2.log("V18_REGISTRY", address(registry));
            console2.log("V18_WETH", address(weth));
            console2.log("V18_USDC", address(usdc));
            console2.log("V18_OPTION_ID", optionId);
            console2.log("V18_EXPIRY", expiry);
            console2.log("V18_BUYER", buyer);
            console2.log("V18_SELLER", seller);
            return;
        }

        OptionMatchingEngine.OptionTrade memory trade = OptionMatchingEngine.OptionTrade({
            intentId: keccak256("v18-covered-local-anvil"),
            buyer: buyer,
            seller: seller,
            optionId: optionId,
            underlying: address(weth),
            settlementAsset: address(usdc),
            expiry: expiry,
            strike1e8: 2_250e8,
            isCall: true,
            contractSize1e8: 1e8,
            quantity: 1,
            premiumPerContract: 100e6,
            buyerIsMaker: true,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 1 hours
        });
        bytes32 digest = matcher.hashTrade(trade);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(BUYER_PK, digest);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(SELLER_PK, digest);
        OptionMatchingEngine.OptionTrade memory second =
            abi.decode(abi.encode(trade), (OptionMatchingEngine.OptionTrade));
        second.intentId = keccak256("v18-covered-local-anvil-second");
        second.buyerNonce = 1;
        second.sellerNonce = 1;
        bytes32 secondDigest = matcher.hashTrade(second);
        (uint8 b2v, bytes32 b2r, bytes32 b2s) = vm.sign(BUYER_PK, secondDigest);
        (uint8 s2v, bytes32 s2r, bytes32 s2s) = vm.sign(SELLER_PK, secondDigest);
        vm.startBroadcast(OWNER_PK);
        batch.executeTwo(
            matcher,
            trade,
            abi.encodePacked(br, bs, bv),
            abi.encodePacked(sr, ss, sv),
            second,
            abi.encodePacked(b2r, b2s, b2v),
            abi.encodePacked(s2r, s2s, s2v)
        );
        vm.stopBroadcast();

        console2.log("V18_ENGINE", address(engine));
        console2.log("V18_MATCHER", address(matcher));
        console2.log("V18_REGISTRY", address(registry));
        console2.log("V18_WETH", address(weth));
        console2.log("V18_USDC", address(usdc));
        console2.log("V18_OPTION_ID", optionId);
        console2.log("V18_EXPIRY", expiry);
        console2.log("V18_BUYER", buyer);
        console2.log("V18_SELLER", seller);
    }
}
