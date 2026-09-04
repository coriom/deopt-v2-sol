// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title MockImpactMidSink
/// @notice PERPS-CLOSED-TEST-HARDENING-V1 Part E — local-anvil-only mock sink
///         for the impact-mid publisher path. Byte-compatible interface with
///         `PerpEngine.setImpactMidSource` + `PerpEngine.updateImpactMid` so
///         the backend's `LocalAnvilPublisher` can broadcast against it
///         without deploying a full `PerpEngine` topology
///         (`PerpRiskModule`, `CollateralVault`, `InsuranceFund`, ...).
///
/// @dev
///  # Scope
///  Test-only. Deployed exclusively by `DeployPerpsE2E.s.sol` into the
///  closed-test harness's local anvil. NEVER deployed to Base Sepolia or
///  any real network. No security guarantees beyond the mirror of the
///  auth check on `updateImpactMid`.
///
///  # Interface mirror
///   - `setImpactMidSource(address)` — governance surface. Not
///     `onlyOwner` on the mock (anyone may call) so the harness can
///     rotate the source in a single `cast send` without threading an
///     owner key. On the real `PerpEngine` this is `onlyOwner` and
///     rejects zero-address.
///   - `updateImpactMid(uint256 marketId, uint128 mid1e8)` — only the
///     configured `impactMidSource` may call. Reverts on mismatch, on
///     `mid1e8 == 0` (matches `PerpEngine`'s `OraclePriceUnavailable`
///     policy). The revert reason is a bare string so `cast` /
///     `alloy` decoding surfaces something human-readable in the
///     backend's error path.
///   - `getImpactMidSample(uint256 marketId)` — returns the stored
///     `(mid1e8, updatedAt)` tuple. Byte layout matches the real
///     `PerpEngineStorage.ImpactMidSample` struct.
contract MockImpactMidSink {
    struct ImpactMidSample {
        uint128 mid1e8;
        uint64 updatedAt;
    }

    address public impactMidSource;
    mapping(uint256 => ImpactMidSample) internal _samples;

    event ImpactMidSourceSet(address indexed oldSource, address indexed newSource);
    event ImpactMidUpdated(uint256 indexed marketId, uint128 mid1e8, uint64 updatedAt);

    error NotImpactMidSource();
    error ZeroMid();

    function setImpactMidSource(address source) external {
        address old = impactMidSource;
        impactMidSource = source;
        emit ImpactMidSourceSet(old, source);
    }

    function updateImpactMid(uint256 marketId, uint128 mid1e8) external {
        if (msg.sender != impactMidSource) revert NotImpactMidSource();
        if (mid1e8 == 0) revert ZeroMid();
        uint64 nowTs = uint64(block.timestamp);
        _samples[marketId] = ImpactMidSample({mid1e8: mid1e8, updatedAt: nowTs});
        emit ImpactMidUpdated(marketId, mid1e8, nowTs);
    }

    function getImpactMidSample(uint256 marketId)
        external
        view
        returns (uint128 mid1e8, uint64 updatedAt)
    {
        ImpactMidSample memory s = _samples[marketId];
        return (s.mid1e8, s.updatedAt);
    }
}
