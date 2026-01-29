// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale pour que MatchingEngine puisse appeler MarginEngine.applyTrade()
/// @dev
///  - Ce fichier est OK tel quel.
///  - Reco d’usage: faire implémenter MarginEngine par cette interface.
interface IMarginEngineTrade {
    struct Trade {
        address buyer;
        address seller;
        uint256 optionId;
        uint128 quantity;
        uint128 price; // unités natives du settlementAsset (ex: 1e6 USDC)
    }

    function applyTrade(Trade calldata t) external;
}
