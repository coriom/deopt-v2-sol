// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferToken
/// @notice Token that keeps a percentage fee on every transfer. Must be rejected
///         by the vault's exact-delta policy.
contract FeeOnTransferToken is ERC20 {
    /// @dev Basis-points fee kept by the token on every transfer (10000 == 100%).
    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps_) ERC20("FoT", "FOT") {
        FEE_BPS = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || FEE_BPS == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10000;
        uint256 net = value - fee;
        super._update(from, to, net);
        // Fee is burned rather than routed to a recipient; keeps the mock simple.
        if (fee != 0) super._update(from, address(0xdead), fee);
    }
}

/// @title FalseReturningToken
/// @notice Token whose `transferFrom` always returns `false`. Must revert deposits.
contract FalseReturningToken {
    string public constant name = "FRT";
    string public constant symbol = "FRT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @title ReentrantToken
/// @notice Token that attempts to call back into the vault's `deposit` during
///         `transferFrom`. Must be blocked by the vault's `nonReentrant`.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public reentryCalldata;

    constructor() ERC20("REN", "REN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armReentry(address target_, bytes calldata reentryCalldata_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Only attempt reentry mid-transfer (i.e., pull path).
        address t = target;
        if (t != address(0) && from != address(0) && to != address(0)) {
            (bool ok, bytes memory ret) = t.call(reentryCalldata);
            // Re-throw the inner revert so the outer call bubbles up the vault's
            // ReentrancyGuardReentrantCall selector.
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

/// @title DonationToken
/// @notice Standard ERC-20 used to simulate direct-donation surplus (a plain mint
///         to the vault address without going through `deposit`).
contract DonationToken is ERC20 {
    constructor() ERC20("DON", "DON") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
