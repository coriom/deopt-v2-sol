// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPriceSource.sol";

/// @title MockPriceSource
/// @notice Source de prix contrôlée par un owner pour tests / dev.
/// @dev price en 1e8, updatedAt = timestamp arbitraire (souvent block.timestamp).
contract MockPriceSource is IPriceSource {
    address public owner;

    uint256 private _price;
    uint256 private _updatedAt;

    error NotAuthorized();
    error ZeroAddress();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PriceUpdated(uint256 price, uint256 updatedAt);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(uint256 initialPrice, uint256 initialUpdatedAt) {
        owner = msg.sender;
        _price = initialPrice;
        _updatedAt = initialUpdatedAt;
        emit OwnershipTransferred(address(0), owner);
        emit PriceUpdated(initialPrice, initialUpdatedAt);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address old = owner;
        owner = newOwner;
        emit OwnershipTransferred(old, newOwner);
    }

    function setPrice(uint256 newPrice) external onlyOwner {
        _price = newPrice;
        _updatedAt = block.timestamp;
        emit PriceUpdated(newPrice, _updatedAt);
    }

    function setPriceWithTimestamp(uint256 newPrice, uint256 newUpdatedAt) external onlyOwner {
        _price = newPrice;
        _updatedAt = newUpdatedAt;
        emit PriceUpdated(newPrice, newUpdatedAt);
    }

    /// @inheritdoc IPriceSource
    function getLatestPrice() external view override returns (uint256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}
