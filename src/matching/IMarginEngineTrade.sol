// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale pour que MatchingEngine puisse appeler MarginEngine.applyTrade()
/// @dev
///  - price est en unités natives du settlementAsset (ex: 1e6 pour USDC),
///    donc cashflow = quantity * price (attention overflow => MarginEngine check).
///  - Ajouts: batch + versioning léger + event signature (optionnel) pour out-of-band tracking.
///  - L’impl (MarginEngine) DOIT rester l’unique source de vérité sur les checks:
///    expiry, close-only, risk, etc.
interface IMarginEngineTrade {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct Trade {
        address buyer;
        address seller;
        uint256 optionId;
        uint128 quantity;
        uint128 price; // unités natives du settlementAsset (ex: 1e6 USDC)
    }

    /*//////////////////////////////////////////////////////////////
                              SINGLE TRADE
    //////////////////////////////////////////////////////////////*/

    /// @notice Applique un trade unique (appelé par MatchingEngine).
    function applyTrade(Trade calldata t) external;

    /*//////////////////////////////////////////////////////////////
                              BATCH TRADES
    //////////////////////////////////////////////////////////////*/

    /// @notice Applique un batch de trades (atomique) – optionnel mais recommandé pour l’efficience.
    /// @dev L’impl peut revert si non supporté, ou process en boucle avec mêmes invariants que applyTrade.
    function applyTrades(Trade[] calldata trades) external;

    /*//////////////////////////////////////////////////////////////
                              INTERFACE ID
    //////////////////////////////////////////////////////////////*/

    /// @notice Version d’interface (convenience).
    function interfaceVersion() external pure returns (uint256);
}
