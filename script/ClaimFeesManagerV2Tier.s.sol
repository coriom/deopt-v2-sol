// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

/// @title ClaimFeesManagerV2Tier
/// @notice V2G-B preflight + optional broadcast for
///         `FeesManagerV2.claimTier(account, tier, volume28d,
///         volumeSharePpm, stakedDeopt, validFrom, validUntil,
///         proof)`. Called from the claimant account itself
///         (contract requires `msg.sender == account`).
/// @dev
///  Proof is supplied via `CLAIM_PROOF_LEN` + `CLAIM_PROOF_0`,
///  `CLAIM_PROOF_1`, ... since `forge-std` does not natively decode
///  JSON arrays into `bytes32[]`. For single-leaf trees (root ==
///  leaf), set `CLAIM_PROOF_LEN=0`.
///
///  Required env in all cases:
///    - `CLAIMANT_PRIVATE_KEY` (account key)
///    - `FEES_MANAGER_V2_ADDRESS`
///    - `CLAIM_TIER` (uint8)
///    - `CLAIM_VOLUME_28D` (uint256)
///    - `CLAIM_VOLUME_SHARE_PPM` (uint32)
///    - `CLAIM_STAKED_DEOPT` (uint256)
///    - `CLAIM_VALID_FROM` (uint64)
///    - `CLAIM_VALID_UNTIL` (uint64)
///    - `CLAIM_PROOF_LEN` (uint, may be 0)
///    - `CLAIM_PROOF_0` ... `CLAIM_PROOF_{LEN-1}` (bytes32 hex)
///
///  Optional env:
///    - `CLAIM_ACCOUNT` — cross-checked against the EOA derived from
///      `CLAIMANT_PRIVATE_KEY`; mismatch reverts before any tx.
///
///  Mutating call gated by:
///    - `CLAIM_FEES_MANAGER_V2_TIER_CONFIRM=true`
contract ClaimFeesManagerV2Tier is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address caller;
        address feesManager;
        address account;
        uint8 tier;
        uint256 volume28d;
        uint32 volumeSharePpm;
        uint256 stakedDeopt;
        uint64 validFrom;
        uint64 validUntil;
        bytes32[] proof;
        bool confirmed;
    }

    struct Snapshot {
        bytes32 merkleRoot;
        uint8 currentTier;
        uint64 claimedValidUntil;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeesManagerUnset();
    error NoCodeAt(string name, address target);
    error CallerNotAccount(address caller, address account);
    error MerkleRootUnset();
    error AlreadyAtRequestedTier(uint8 tier);
    error ClaimDidNotTake(uint8 expectedTier, uint8 observedTier);

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
            console2.log("CLAIM_FEES_MANAGER_V2_TIER_CONFIRM not set; preflight done, no transactions sent.");
            return;
        }

        uint256 claimantPk = vm.envUint("CLAIMANT_PRIVATE_KEY");
        vm.startBroadcast(claimantPk);
        FeesManagerV2(inputs.feesManager)
            .claimTier(
                inputs.account,
                inputs.tier,
                inputs.volume28d,
                inputs.volumeSharePpm,
                inputs.stakedDeopt,
                inputs.validFrom,
                inputs.validUntil,
                inputs.proof
            );
        vm.stopBroadcast();

        Snapshot memory after_ = _snapshot(inputs);
        _logSnapshot("after", after_);
        _verifyPostState(inputs, after_);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        uint256 claimantPk = vm.envUint("CLAIMANT_PRIVATE_KEY");
        inputs.caller = vm.addr(claimantPk);
        inputs.feesManager = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.account = vm.envOr("CLAIM_ACCOUNT", inputs.caller);
        inputs.tier = uint8(vm.envUint("CLAIM_TIER"));
        inputs.volume28d = vm.envUint("CLAIM_VOLUME_28D");
        inputs.volumeSharePpm = uint32(vm.envUint("CLAIM_VOLUME_SHARE_PPM"));
        inputs.stakedDeopt = vm.envUint("CLAIM_STAKED_DEOPT");
        inputs.validFrom = uint64(vm.envUint("CLAIM_VALID_FROM"));
        inputs.validUntil = uint64(vm.envUint("CLAIM_VALID_UNTIL"));
        inputs.confirmed = vm.envOr("CLAIM_FEES_MANAGER_V2_TIER_CONFIRM", false);

        uint256 proofLen = vm.envUint("CLAIM_PROOF_LEN");
        inputs.proof = new bytes32[](proofLen);
        for (uint256 i = 0; i < proofLen; i++) {
            inputs.proof[i] = vm.envBytes32(string.concat("CLAIM_PROOF_", vm.toString(i)));
        }
    }

    function _validateInputs(Inputs memory inputs) internal view {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.feesManager.code.length == 0) {
            revert NoCodeAt("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        }
        if (inputs.caller != inputs.account) {
            revert CallerNotAccount(inputs.caller, inputs.account);
        }
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);
        snap.merkleRoot = fm.merkleRoot();
        snap.currentTier = fm.currentTier(inputs.account);
        snap.claimedValidUntil = fm.claimedTiers(inputs.account).validUntil;
    }

    function _validatePreconditions(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (inputs.confirmed) {
            if (snap.merkleRoot == bytes32(0)) revert MerkleRootUnset();
            if (snap.currentTier == inputs.tier && snap.claimedValidUntil == inputs.validUntil) {
                revert AlreadyAtRequestedTier(inputs.tier);
            }
        }
    }

    function _verifyPostState(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (snap.currentTier != inputs.tier) revert ClaimDidNotTake(inputs.tier, snap.currentTier);
    }

    function _logInputs(Inputs memory inputs) internal view {
        console2.log("FeesManagerV2.claimTier preflight V2G-B");
        console2.log("chainId", block.chainid);
        console2.log("caller (sanitized, no key)", inputs.caller);
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("CLAIM_ACCOUNT", inputs.account);
        console2.log("CLAIM_TIER", inputs.tier);
        console2.log("CLAIM_VOLUME_28D", inputs.volume28d);
        console2.log("CLAIM_VOLUME_SHARE_PPM", inputs.volumeSharePpm);
        console2.log("CLAIM_STAKED_DEOPT", inputs.stakedDeopt);
        console2.log("CLAIM_VALID_FROM", inputs.validFrom);
        console2.log("CLAIM_VALID_UNTIL", inputs.validUntil);
        console2.log("CLAIM_PROOF_LEN", inputs.proof.length);
        for (uint256 i = 0; i < inputs.proof.length; i++) {
            console2.log("CLAIM_PROOF_", i);
            console2.logBytes32(inputs.proof[i]);
        }
        console2.log("CLAIM_FEES_MANAGER_V2_TIER_CONFIRM", inputs.confirmed);
    }

    function _logSnapshot(string memory label, Snapshot memory snap) internal pure {
        console2.log("State snapshot:", label);
        console2.log(" FeesManagerV2.merkleRoot()");
        console2.logBytes32(snap.merkleRoot);
        console2.log(" FeesManagerV2.currentTier(account)", snap.currentTier);
        console2.log(" FeesManagerV2.claimedTiers(account).validUntil", snap.claimedValidUntil);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
