// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {PerpEngineTradingV2} from "./PerpEngineTradingV2.sol";

/// @title PerpEngineV2
/// @notice V2 perpetual engine deployable. Same external ABI shape as V1's
///         `PerpEngine` except:
///           - adds `clearingAccount` view + `setClearingAccount` admin
///           - realized-PnL settlement is per-side through the clearing
///             account (fixes V1 2x mutual-close bug; see
///             `docs/PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1.md` and the
///             fixed `_applyRealizedCashflow` in `PerpEngineTradingV2`)
/// @dev
///  V2 inheritance stack (parallel to V1 — V1 files are untouched):
///
///   PerpEngineV2
///     -> PerpEngineTradingV2
///     -> PerpEngineViews (V1)
///     -> PerpEngineAdmin (V1)
///     -> PerpEngineStorage (V1)
///     -> PerpEngineTypes (V1)
///
///  Storage layout adds one slot (`address public clearingAccount`) at
///  the end of the V1 layout. Because V2 is deployed at a fresh address,
///  it does not collide with any live V1 engine instance.
contract PerpEngineV2 is PerpEngineTradingV2 {
    constructor(address _owner, address registry_, address vault_, address oracle_) {
        _initPerpEngineStorage(_owner, registry_, vault_, oracle_);
        _setGuardian(_owner);
    }
}
