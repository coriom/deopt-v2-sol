// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IOracleAdapter} from "../../../../src/hybrid-v2/interfaces/IOracleAdapter.sol";

/// @title MockOracleAdapter
/// @notice Test-only 1e8 price adapter with per-pair settable price + updatedAt
///         + `ok` flag. Not shipped as production source.
contract MockOracleAdapter is IOracleAdapter {
    struct Feed {
        uint256 price1e8;
        uint256 updatedAt;
        bool ok;
        bool revertOnRead;
    }

    mapping(bytes32 => Feed) internal _feeds;

    function _key(address base, address quote) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base, quote));
    }

    function setPrice(address base, address quote, uint256 price1e8, uint256 updatedAt) external {
        _feeds[_key(base, quote)] = Feed({price1e8: price1e8, updatedAt: updatedAt, ok: true, revertOnRead: false});
    }

    function setUnavailable(address base, address quote) external {
        _feeds[_key(base, quote)] = Feed({price1e8: 0, updatedAt: 0, ok: false, revertOnRead: false});
    }

    function setRevertOnRead(address base, address quote, bool doRevert) external {
        Feed storage f = _feeds[_key(base, quote)];
        f.revertOnRead = doRevert;
    }

    function getPrice1e8(address base, address quote) external view returns (uint256 price1e8, uint256 updatedAt) {
        Feed memory f = _feeds[_key(base, quote)];
        if (f.revertOnRead || !f.ok) revert("MockOracle: unavailable");
        return (f.price1e8, f.updatedAt);
    }

    function getPrice1e8Safe(address base, address quote)
        external
        view
        returns (uint256 price1e8, uint256 updatedAt, bool ok)
    {
        Feed memory f = _feeds[_key(base, quote)];
        if (f.revertOnRead) revert("MockOracle: revertOnRead");
        return (f.price1e8, f.updatedAt, f.ok);
    }
}
