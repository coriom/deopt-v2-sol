// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReplayAndEpochController} from "../../../../src/hybrid-v2/security/ReplayAndEpochController.sol";
import {IntentHash} from "../../../../src/hybrid-v2/libraries/IntentHash.sol";

/// @title ReplayAndEpochControllerHarness
/// @notice Test-only concrete inheritor of the abstract
///         `ReplayAndEpochController`. Exposes internal primitives + provides an
///         authority-driven epoch advance path so we can exercise the WP-10
///         integration surface without introducing production behavior.
contract ReplayAndEpochControllerHarness is ReplayAndEpochController {
    /// @notice Whether authority-driven epoch advances are enabled. Test-only toggle.
    bool public authorityEnabled = true;

    /// @notice Recovery-authority address. Test-only: WP-10 EscapeController will replace
    ///         this with its own on-chain gating.
    address public recoveryAuthority;

    error UnauthorizedRecoveryActor(address expected, address actual);

    constructor(address registry_, string memory eip712Name_, string memory eip712Version_, address recoveryAuthority_)
        ReplayAndEpochController(registry_, eip712Name_, eip712Version_)
    {
        recoveryAuthority = recoveryAuthority_;
    }

    /*//////////////////////////////////////////////////////////////
                        AUTHORITY-DRIVEN EPOCH PATH
    //////////////////////////////////////////////////////////////*/

    function setRecoveryAuthority(address newAuthority) external {
        recoveryAuthority = newAuthority;
    }

    function setAuthorityEnabled(bool enabled) external {
        authorityEnabled = enabled;
    }

    /// @notice Authority-driven owner-wide epoch advance. Test-only representative of
    ///         the WP-10 recovery-activation path.
    function authorityAdvanceOwnerRecoveryEpoch(address owner) external {
        if (!authorityEnabled || msg.sender != recoveryAuthority) {
            revert UnauthorizedRecoveryActor(recoveryAuthority, msg.sender);
        }
        _advanceOwnerRecoveryEpoch(owner, msg.sender);
    }

    /// @notice Authority-driven per-subaccount epoch advance.
    function authorityAdvanceSubaccountRecoveryEpoch(bytes32 subKey, address owner, uint32 subaccountId) external {
        if (!authorityEnabled || msg.sender != recoveryAuthority) {
            revert UnauthorizedRecoveryActor(recoveryAuthority, msg.sender);
        }
        _advanceSubaccountRecoveryEpoch(subKey, owner, subaccountId, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                      TEST-ONLY EXTERNAL PRIMITIVES
    //////////////////////////////////////////////////////////////*/

    /// @notice Consume an intent hash externally (test hook — real engines call
    ///         `_consumeIntent` internally as part of processing a signed action).
    function consumeIntent(bytes32 intentHash, address signer, bytes32 action) external {
        _consumeIntent(intentHash, signer, action);
    }

    /// @notice Consume a sequential nonce externally.
    function consumeNonce(address signer, uint256 provided) external {
        _consumeNonce(signer, provided);
    }

    /// @notice Deadline validation.
    function requireDeadlineNotExpired(uint256 deadline) external view {
        _requireDeadlineNotExpired(deadline);
    }

    /// @notice Envelope epoch validation.
    function requireEpochsFresh(
        address owner,
        bytes32 subKey,
        uint256 providedOwnerEpoch,
        uint256 providedSubaccountEpoch
    ) external view {
        _requireEpochsFresh(owner, subKey, providedOwnerEpoch, providedSubaccountEpoch);
    }

    /// @notice Static envelope binding validation.
    function requireEnvelopeBindingValid(IntentHash.SignedActionEnvelope memory envelope) external view {
        _requireEnvelopeBindingValid(envelope);
    }

    /// @notice Compute the EIP-712 digest for an envelope.
    function hashSignedActionEnvelopeDigest(IntentHash.SignedActionEnvelope memory envelope)
        external
        view
        returns (bytes32)
    {
        return _hashSignedActionEnvelopeDigest(envelope);
    }

    /// @notice Expose the domain separator for cross-domain hashing tests.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
