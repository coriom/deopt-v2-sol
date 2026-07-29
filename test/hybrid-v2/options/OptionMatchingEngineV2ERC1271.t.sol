// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionMatchingEngineV2TestBase} from "./OptionMatchingEngineV2.t.sol";
import {OptionOrderTypes} from "../../../src/hybrid-v2/options/OptionOrderTypes.sol";
import {IOptionMatchingEngine} from "../../../src/hybrid-v2/interfaces/IOptionMatchingEngine.sol";
import {IntentHash} from "../../../src/hybrid-v2/libraries/IntentHash.sol";
import {MockERC1271Wallet} from "./harness/MockERC1271Wallet.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title OptionMatchingEngineV2ERC1271
/// @notice `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` — smart-contract-
///         wallet ownership via ERC-1271 signature validation.
contract OptionMatchingEngineV2ERC1271 is OptionMatchingEngineV2TestBase {
    MockERC1271Wallet internal aliceWallet;

    function setUp() public override {
        super.setUp();
        aliceWallet = new MockERC1271Wallet(alice); // alice's EOA signs
        vm.prank(address(aliceWallet));
        registry.registerNext();
        _fund(bob, 1, 1000e6);
    }

    function _fundWalletHelper(address ownerAddr, uint32 subaccountId, uint256 amt) internal {
        usdc.mint(ownerAddr, amt);
        vm.prank(ownerAddr);
        usdc.approve(address(vault), amt);
        vm.prank(ownerAddr);
        vault.deposit(subaccountId, address(usdc), amt);
    }

    function test_eoaBuyer_erc1271Seller() public {
        // Reset: alice is BUYER (EOA), bob is SELLER as seller-wallet uses smart-contract wallet.
        // Simplification: use aliceWallet as the SELLER, bob as EOA buyer.
        _fund(bob, 1, 1000e6);
        _fundWalletHelper(address(aliceWallet), 1, 1000e6);

        // Buyer = bob EOA.
        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            salt: bytes32("b")
        });
        // Seller = smart-contract wallet with alice as internal signer.
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            salt: bytes32("s")
        });

        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(bob, 1, 0, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv = IntentHash.SignedActionEnvelope({
            owner: address(aliceWallet), // wallet contract is the OWNER
            subaccountId: 1,
            subKey: registry.subKeyOf(address(aliceWallet), 1),
            signer: address(aliceWallet), // signer == owner per V1
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(sOrder)
        });

        bytes memory bSig = _sign(bobPk, bEnv);
        // ERC-1271: sign the wallet's expected digest with alice's key (the
        // wallet's internal signer). The engine calls SignatureChecker which
        // routes to isValidSignature.
        bytes32 sDigest = engine.hashSignedActionEnvelopeDigest(sEnv);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, sDigest);
        bytes memory sSig = abi.encodePacked(r, s, v);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);

        bytes32 walletSk = registry.subKeyOf(address(aliceWallet), 1);
        PositionTypes.OptionPosition memory pos = ledger.positionOf(walletSk, 1);
        assertEq(uint256(pos.shortQuantity1e8), 1e8);
    }

    function test_erc1271_rejectAllPrevents() public {
        aliceWallet.setRejectAll(true);
        _fundWalletHelper(address(aliceWallet), 1, 1000e6);

        OptionOrderTypes.OptionOrder memory bOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_LONG,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 200e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_TAKER,
            salt: bytes32("b")
        });
        OptionOrderTypes.OptionOrder memory sOrder = OptionOrderTypes.OptionOrder({
            seriesId: 1,
            side: OptionOrderTypes.SIDE_SHORT,
            quantity1e8: 1e8,
            pricePerContract1e8: 100e8,
            limitPricePerContract1e8: 50e8,
            premiumToken: address(usdc),
            timeInForce: OptionOrderTypes.TIF_GTC,
            role: OptionOrderTypes.ROLE_MAKER,
            salt: bytes32("s")
        });
        IntentHash.SignedActionEnvelope memory bEnv =
            _makeEnvelope(bob, 1, 0, block.timestamp + 1 hours, OptionOrderTypes.hashOrder(bOrder));
        IntentHash.SignedActionEnvelope memory sEnv = IntentHash.SignedActionEnvelope({
            owner: address(aliceWallet),
            subaccountId: 1,
            subKey: registry.subKeyOf(address(aliceWallet), 1),
            signer: address(aliceWallet),
            engine: address(engine),
            action: OptionOrderTypes.ACTION_OPTION_ORDER,
            architectureVersion: 1,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            ownerRecoveryEpoch: 0,
            subaccountRecoveryEpoch: 0,
            payloadHash: OptionOrderTypes.hashOrder(sOrder)
        });
        bytes memory bSig = _sign(bobPk, bEnv);
        bytes32 sDigest = engine.hashSignedActionEnvelopeDigest(sEnv);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, sDigest);
        bytes memory sSig = abi.encodePacked(r, s, v);

        uint256[] memory ids = new uint256[](0);
        vm.expectRevert();
        engine.executeMatch(bEnv, bSig, bOrder, sEnv, sSig, sOrder, 1e8, ids, ids);
    }
}
