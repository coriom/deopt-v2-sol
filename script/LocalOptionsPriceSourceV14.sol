// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IPriceSource} from "../src/oracle/IPriceSource.sol";

/// @dev Deterministic Anvil fixture only. Never use as a production feed.
contract V14LocalPriceSource is IPriceSource {
    uint256 private price;
    uint256 private updatedAt;
    bool private valid;

    function set(uint256 price_, uint256 updatedAt_, bool valid_) external {
        price = price_;
        updatedAt = updatedAt_;
        valid = valid_;
    }

    function getLatestPrice() external view returns (uint256, uint256) {
        require(valid, "local feed unavailable");
        return (price, updatedAt);
    }
}
