// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./OptionProductRegistry.sol";
import "./CollateralVault.sol";
import "./oracle/IOracle.sol";
import "./risk/IRiskModule.sol";

/// @title MarginEngine
/// @notice Gère les positions, la marge, les liquidations et le settlement à l'expiration.
/// @dev Toute la logique de risque (equity / IM / MM) est déléguée au RiskModule (IRiskModule).
contract MarginEngine {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct Position {
        int128 quantity; // >0 = long, <0 = short
    }

    struct Trade {
        address buyer;
        address seller;
        uint256 optionId;
        uint128 quantity;
        uint128 price;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error InvalidTrade();
    error ZeroAddress();
    error NotLiquidatable();
    error LengthMismatch();
    error NotShortPosition();
    error NoBaseCollateral();
    error RiskModuleNotSet();

    // Expiration / payoff
    error NotExpired();
    error SettlementNotSet();
    error SettlementAlreadyProcessed();
    error SettlementAssetNotConfigured();
    error InsuranceFundNotSet();
    error InsuranceFundInsufficient();

    // Withdraw via MarginEngine
    error WithdrawTooLarge();
    error WithdrawWouldBreachMargin();

    // Liquidation hardening
    error LiquidationNotImproving();
    error SeriesExpired();
    error InvalidLiquidationParams();
    error LiquidationNothingToDo();
    error LiquidationCloseFactorZero();

    // Liquidation pricing
    error OraclePriceUnavailable();
    error OraclePriceStale();
    error LiquidationPricingParamsInvalid();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MatchingEngineSet(address indexed newMatchingEngine);

    event TradeExecuted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed optionId,
        uint128 quantity,
        uint128 price
    );

    event RiskParamsSet(
        address baseCollateralToken,
        uint256 baseMaintenanceMarginPerContract,
        uint256 imFactorBps
    );

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event OracleSet(address indexed newOracle);
    event RiskModuleSet(address indexed newRiskModule);

    event LiquidationParamsSet(
        uint256 liquidationThresholdBps,
        uint256 liquidationPenaltyBps
    );

    event LiquidationHardenParamsSet(
        uint256 liquidationCloseFactorBps,
        uint256 minLiquidationImprovementBps
    );

    event LiquidationPricingParamsSet(
        uint256 liquidationPriceSpreadBps,
        uint256 minLiquidationPriceBpsOfIntrinsic
    );

    /// @notice Fraîcheur minimale exigée côté liquidation (en secondes). 0 = désactivé.
    event LiquidationOracleMaxDelaySet(uint32 oldDelay, uint32 newDelay);

    event Liquidation(
        address indexed liquidator,
        address indexed trader,
        uint256[] optionIds,
        uint128[] quantities,
        uint256 collateralSeized
    );

    event LiquidationCashflow(
        address indexed liquidator,
        address indexed trader,
        address indexed settlementAsset,
        uint256 cashPaidByTrader,
        uint256 cashRequested
    );

    event CollateralDeposited(address indexed trader, address indexed token, uint256 amount);

    event CollateralWithdrawn(
        address indexed trader,
        address indexed token,
        uint256 amount,
        uint256 marginRatioAfterBps
    );

    event InsuranceFundSet(address indexed oldFund, address indexed newFund);

    event AccountSettled(
        address indexed trader,
        uint256 indexed optionId,
        int256 pnl,
        uint256 collectedFromTrader,
        uint256 paidToTrader,
        uint256 badDebt
    );

    event SeriesSettlementAccountingUpdated(
        uint256 indexed optionId,
        uint256 totalCollected,
        uint256 totalPaid,
        uint256 totalBadDebt
    );

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public matchingEngine;

    OptionProductRegistry public optionRegistry;
    CollateralVault public collateralVault;
    IOracle public oracle;
    IRiskModule public riskModule;

    mapping(address => mapping(uint256 => Position)) private _positions;

    /// @notice Nombre total de contrats shorts (toutes séries confondues) par trader
    mapping(address => uint256) public totalShortContracts;

    /// -----------------------------------------------------------------------
    /// OPEN SERIES TRACKING (anti-DoS gaz)
    /// -----------------------------------------------------------------------
    /// @notice Liste des séries sur lesquelles un trader a une position NON NULLE (open only).
    mapping(address => uint256[]) private traderSeries;

    /// @notice Index+1 dans traderSeries (0 = absent). Permet remove O(1).
    mapping(address => mapping(uint256 => uint256)) private traderSeriesIndexPlus1;

    address public baseCollateralToken;
    uint256 public baseMaintenanceMarginPerContract;
    uint256 public imFactorBps;

    bool public paused;

    uint256 public liquidationThresholdBps = 10050;
    uint256 public liquidationPenaltyBps = 500;

    // ===================== Liquidation hardening (A-1) =====================

    uint256 public liquidationCloseFactorBps = 5000;
    uint256 public minLiquidationImprovementBps = 1;

    // ===================== Liquidation pricing (A-1) =====================

    uint256 public liquidationPriceSpreadBps = 500;
    uint256 public minLiquidationPriceBpsOfIntrinsic = 0;

    /// @notice Fraîcheur exigée côté liquidation. 0 = off.
    uint32 public liquidationOracleMaxDelay = 600;

    // ===================== Settlement (claim-based) =====================

    address public insuranceFund;

    mapping(uint256 => mapping(address => bool)) public isAccountSettled;

    mapping(uint256 => uint256) public seriesCollected;
    mapping(uint256 => uint256) public seriesPaid;
    mapping(uint256 => uint256) public seriesBadDebt;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyMatchingEngine() {
        if (msg.sender != matchingEngine) revert NotAuthorized();
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _registry, address _vault, address _oracle) {
        if (
            _owner == address(0) ||
            _registry == address(0) ||
            _vault == address(0) ||
            _oracle == address(0)
        ) revert ZeroAddress();

        owner = _owner;
        optionRegistry = OptionProductRegistry(_registry);
        collateralVault = CollateralVault(_vault);
        oracle = IOracle(_oracle);

        emit OwnershipTransferred(address(0), _owner);
        emit OracleSet(_oracle);

        emit LiquidationOracleMaxDelaySet(0, liquidationOracleMaxDelay);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNERSHIP / CONFIG
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setMatchingEngine(address _matchingEngine) external onlyOwner {
        if (_matchingEngine == address(0)) revert ZeroAddress();
        matchingEngine = _matchingEngine;
        emit MatchingEngineSet(_matchingEngine);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();
        oracle = IOracle(_oracle);
        emit OracleSet(_oracle);
    }

    function setRiskModule(address _riskModule) external onlyOwner {
        if (_riskModule == address(0)) revert ZeroAddress();
        riskModule = IRiskModule(_riskModule);
        emit RiskModuleSet(_riskModule);
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        if (_insuranceFund == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = _insuranceFund;
        emit InsuranceFundSet(old, _insuranceFund);
    }

    function setRiskParams(
        address _baseToken,
        uint256 _baseMMPerContract,
        uint256 _imFactorBps
    ) external onlyOwner {
        if (_baseToken == address(0)) revert ZeroAddress();
        require(_imFactorBps >= 10_000, "IM_FACTOR_TOO_LOW");

        baseCollateralToken = _baseToken;
        baseMaintenanceMarginPerContract = _baseMMPerContract;
        imFactorBps = _imFactorBps;

        emit RiskParamsSet(_baseToken, _baseMMPerContract, _imFactorBps);
    }

    function setLiquidationParams(
        uint256 _liquidationThresholdBps,
        uint256 _liquidationPenaltyBps
    ) external onlyOwner {
        require(_liquidationThresholdBps >= 10_000, "THRESH_TOO_LOW");
        require(_liquidationPenaltyBps <= 10_000, "PENALTY_TOO_HIGH");

        liquidationThresholdBps = _liquidationThresholdBps;
        liquidationPenaltyBps = _liquidationPenaltyBps;

        emit LiquidationParamsSet(_liquidationThresholdBps, _liquidationPenaltyBps);
    }

    function setLiquidationHardenParams(
        uint256 _closeFactorBps,
        uint256 _minImprovementBps
    ) external onlyOwner {
        if (_closeFactorBps == 0) revert LiquidationCloseFactorZero();
        if (_closeFactorBps > 10_000) revert InvalidLiquidationParams();

        minLiquidationImprovementBps = _minImprovementBps;
        liquidationCloseFactorBps = _closeFactorBps;

        emit LiquidationHardenParamsSet(_closeFactorBps, _minImprovementBps);
    }

    function setLiquidationPricingParams(
        uint256 _liquidationPriceSpreadBps,
        uint256 _minLiquidationPriceBpsOfIntrinsic
    ) external onlyOwner {
        if (_liquidationPriceSpreadBps > 10_000) revert LiquidationPricingParamsInvalid();
        if (_minLiquidationPriceBpsOfIntrinsic > 10_000) revert LiquidationPricingParamsInvalid();

        liquidationPriceSpreadBps = _liquidationPriceSpreadBps;
        minLiquidationPriceBpsOfIntrinsic = _minLiquidationPriceBpsOfIntrinsic;

        emit LiquidationPricingParamsSet(_liquidationPriceSpreadBps, _minLiquidationPriceBpsOfIntrinsic);
    }

    function setLiquidationOracleMaxDelay(uint32 _delay) external onlyOwner {
        require(_delay <= 3600, "DELAY_OUT_OF_RANGE");
        uint32 old = liquidationOracleMaxDelay;
        liquidationOracleMaxDelay = _delay;
        emit LiquidationOracleMaxDelaySet(old, _delay);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 optionId)
        external
        view
        returns (Position memory)
    {
        return _positions[trader][optionId];
    }

    /// @notice OPEN series only (positions non nulles)
    function getTraderSeries(address trader)
        external
        view
        returns (uint256[] memory)
    {
        return traderSeries[trader];
    }

    /// @notice Longueur de la liste OPEN (utile pagination)
    function getTraderSeriesLength(address trader) external view returns (uint256) {
        return traderSeries[trader].length;
    }

    /// @notice Slice paginée [start, end) sur la liste OPEN.
    function getTraderSeriesSlice(
        address trader,
        uint256 start,
        uint256 end
    ) external view returns (uint256[] memory slice) {
        uint256 len = traderSeries[trader].length;
        if (start > len) start = len;
        if (end > len) end = len;
        if (end < start) end = start;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);
        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = traderSeries[trader][start + i];
        }
    }

    function getAccountRisk(address trader)
        external
        view
        returns (IRiskModule.AccountRisk memory risk)
    {
        if (address(riskModule) == address(0)) {
            IRiskModule.AccountRisk memory empty;
            return empty;
        }
        return riskModule.computeAccountRisk(trader);
    }

    function getFreeCollateral(address trader) external view returns (int256) {
        if (address(riskModule) == address(0)) return 0;
        return riskModule.computeFreeCollateral(trader);
    }

    function previewWithdrawImpact(
        address trader,
        address token,
        uint256 amount
    ) external view returns (IRiskModule.WithdrawPreview memory preview) {
        if (address(riskModule) == address(0)) return preview;
        return riskModule.previewWithdrawImpact(trader, token, amount);
    }

    function isSeriesExpired(uint256 optionId) public view returns (bool) {
        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(optionId);
        return block.timestamp >= series.expiry;
    }

    /*//////////////////////////////////////////////////////////////
                        USER COLLATERAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositCollateral(address token, uint256 amount) external whenNotPaused {
        collateralVault.deposit(token, amount);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external whenNotPaused {
        if (address(riskModule) == address(0)) revert RiskModuleNotSet();
        if (amount == 0) revert InvalidTrade();

        IRiskModule.WithdrawPreview memory preview =
            riskModule.previewWithdrawImpact(msg.sender, token, amount);

        if (amount > preview.maxWithdrawable) revert WithdrawTooLarge();
        if (preview.marginRatioAfterBps < liquidationThresholdBps) revert WithdrawWouldBreachMargin();

        collateralVault.withdraw(token, amount);

        emit CollateralWithdrawn(msg.sender, token, amount, preview.marginRatioAfterBps);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addOpenSeries(address trader, uint256 optionId) internal {
        if (traderSeriesIndexPlus1[trader][optionId] != 0) return; // already present
        traderSeries[trader].push(optionId);
        traderSeriesIndexPlus1[trader][optionId] = traderSeries[trader].length; // index+1
    }

    function _removeOpenSeries(address trader, uint256 optionId) internal {
        uint256 idxPlus1 = traderSeriesIndexPlus1[trader][optionId];
        if (idxPlus1 == 0) return; // absent

        uint256 idx = idxPlus1 - 1;
        uint256 lastIdx = traderSeries[trader].length - 1;

        if (idx != lastIdx) {
            uint256 lastId = traderSeries[trader][lastIdx];
            traderSeries[trader][idx] = lastId;
            traderSeriesIndexPlus1[trader][lastId] = idx + 1;
        }

        traderSeries[trader].pop();
        traderSeriesIndexPlus1[trader][optionId] = 0;
    }

    function _updateOpenSeriesOnChange(
        address trader,
        uint256 optionId,
        int128 oldQty,
        int128 newQty
    ) internal {
        if (oldQty == 0 && newQty != 0) {
            _addOpenSeries(trader, optionId);
        } else if (oldQty != 0 && newQty == 0) {
            _removeOpenSeries(trader, optionId);
        }
    }

    function _updateTotalShortContracts(
        address trader,
        int128 oldQty,
        int128 newQty
    ) internal {
        uint256 oldShort = oldQty < 0 ? uint256(int256(-oldQty)) : 0;
        uint256 newShort = newQty < 0 ? uint256(int256(-newQty)) : 0;

        if (newShort >= oldShort) totalShortContracts[trader] += (newShort - oldShort);
        else totalShortContracts[trader] -= (oldShort - newShort);
    }

    function _price1e8ToSettlementUnits(address settlementAsset, uint256 value1e8)
        internal
        view
        returns (uint256 valueNative)
    {
        CollateralVault.CollateralTokenConfig memory cfg =
            collateralVault.collateralConfigs(settlementAsset);

        if (cfg.decimals == 0) revert SettlementAssetNotConfigured();

        uint256 scale = 10 ** uint256(cfg.decimals);
        valueNative = (value1e8 * scale) / 1e8;
    }

    function _intrinsic1e8(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8
    ) internal pure returns (uint256 intrinsic) {
        if (spot1e8 == 0) return 0;

        if (s.isCall) {
            if (spot1e8 > uint256(s.strike)) intrinsic = spot1e8 - uint256(s.strike);
            else intrinsic = 0;
        } else {
            if (uint256(s.strike) > spot1e8) intrinsic = uint256(s.strike) - spot1e8;
            else intrinsic = 0;
        }
    }

    function _computeLiquidationPricePerContract(
        OptionProductRegistry.OptionSeries memory s
    ) internal view returns (uint256 pricePerContract) {
        (uint256 spot, uint256 updatedAt) = oracle.getPrice(s.underlying, s.settlementAsset);
        if (spot == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (block.timestamp > updatedAt && block.timestamp - updatedAt > maxDelay) {
                revert OraclePriceStale();
            }
        }

        uint256 intrinsic = _intrinsic1e8(s, spot);

        uint256 liqIntrinsic = intrinsic;

        if (intrinsic > 0 && minLiquidationPriceBpsOfIntrinsic > 0) {
            uint256 floorIntrinsic = (intrinsic * minLiquidationPriceBpsOfIntrinsic) / 10_000;
            if (liqIntrinsic < floorIntrinsic) liqIntrinsic = floorIntrinsic;
        }

        if (liquidationPriceSpreadBps > 0) {
            liqIntrinsic = (liqIntrinsic * (10_000 + liquidationPriceSpreadBps)) / 10_000;
        }

        pricePerContract = _price1e8ToSettlementUnits(s.settlementAsset, liqIntrinsic);
    }

    /*//////////////////////////////////////////////////////////////
                              CORE LOGIC (TRADING)
    //////////////////////////////////////////////////////////////*/

    function applyTrade(Trade calldata t) external onlyMatchingEngine whenNotPaused {
        if (
            t.buyer == address(0) ||
            t.seller == address(0) ||
            t.buyer == t.seller ||
            t.quantity == 0 ||
            t.price == 0
        ) revert InvalidTrade();

        if (address(riskModule) == address(0)) revert RiskModuleNotSet();

        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(t.optionId);
        require(series.isActive, "SERIES_NOT_ACTIVE");
        require(block.timestamp < series.expiry, "SERIES_EXPIRED");

        if (baseCollateralToken != address(0)) {
            require(series.settlementAsset == baseCollateralToken, "BAD_SETTLEMENT_ASSET");
        }

        Position storage buyerPos = _positions[t.buyer][t.optionId];
        Position storage sellerPos = _positions[t.seller][t.optionId];

        int128 oldBuyerQty = buyerPos.quantity;
        int128 oldSellerQty = sellerPos.quantity;

        buyerPos.quantity += int128(int256(uint256(t.quantity)));
        sellerPos.quantity -= int128(int256(uint256(t.quantity)));

        int128 newBuyerQty = buyerPos.quantity;
        int128 newSellerQty = sellerPos.quantity;

        _updateTotalShortContracts(t.buyer, oldBuyerQty, newBuyerQty);
        _updateTotalShortContracts(t.seller, oldSellerQty, newSellerQty);

        _updateOpenSeriesOnChange(t.buyer, t.optionId, oldBuyerQty, newBuyerQty);
        _updateOpenSeriesOnChange(t.seller, t.optionId, oldSellerQty, newSellerQty);

        uint256 cashAmount = uint256(t.quantity) * uint256(t.price);

        collateralVault.transferBetweenAccounts(
            series.settlementAsset,
            t.buyer,
            t.seller,
            cashAmount
        );

        emit TradeExecuted(t.buyer, t.seller, t.optionId, t.quantity, t.price);

        IRiskModule.AccountRisk memory sellerRisk = riskModule.computeAccountRisk(t.seller);
        require(sellerRisk.equity >= int256(sellerRisk.initialMargin), "MARGIN_SELLER");
    }

    /*//////////////////////////////////////////////////////////////
                      PAYOFF & PnL HELPERS (SETTLEMENT)
    //////////////////////////////////////////////////////////////*/

    function _computePerContractPayoff(
        OptionProductRegistry.OptionSeries memory series,
        uint256 settlementPrice
    ) internal view returns (uint256 payoffPerContract) {
        if (settlementPrice == 0) return 0;

        uint256 intrinsic;

        if (series.isCall) {
            intrinsic = settlementPrice > uint256(series.strike)
                ? (settlementPrice - uint256(series.strike))
                : 0;
        } else {
            intrinsic = uint256(series.strike) > settlementPrice
                ? (uint256(series.strike) - settlementPrice)
                : 0;
        }

        if (intrinsic == 0) return 0;

        CollateralVault.CollateralTokenConfig memory cfg =
            collateralVault.collateralConfigs(series.settlementAsset);

        if (cfg.decimals == 0) revert SettlementAssetNotConfigured();

        uint256 scale = 10 ** uint256(cfg.decimals);
        payoffPerContract = (intrinsic * scale) / 1e8;
    }

    function settleAccount(uint256 optionId, address trader) public whenNotPaused {
        if (trader == address(0)) revert ZeroAddress();
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();

        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(optionId);
        if (block.timestamp < series.expiry) revert NotExpired();

        (uint256 settlementPrice, bool isSet) = optionRegistry.getSettlementInfo(optionId);
        if (!isSet || settlementPrice == 0) revert SettlementNotSet();

        if (isAccountSettled[optionId][trader]) revert SettlementAlreadyProcessed();
        isAccountSettled[optionId][trader] = true;

        Position storage pos = _positions[trader][optionId];
        int128 oldQty = pos.quantity;

        if (oldQty == 0) {
            emit AccountSettled(trader, optionId, 0, 0, 0, 0);
            return;
        }

        uint256 payoffPerContract = _computePerContractPayoff(series, settlementPrice);

        int256 pnl;
        if (payoffPerContract == 0) {
            pnl = 0;
        } else if (oldQty > 0) {
            pnl = int256(uint256(int256(oldQty)) * payoffPerContract);
        } else {
            pnl = -int256(uint256(int256(-oldQty)) * payoffPerContract);
        }

        // close position
        pos.quantity = 0;

        _updateTotalShortContracts(trader, oldQty, 0);
        _updateOpenSeriesOnChange(trader, optionId, oldQty, 0);

        uint256 collectedFromTrader = 0;
        uint256 paidToTrader = 0;
        uint256 badDebt = 0;

        if (pnl > 0) {
            uint256 amount = uint256(pnl);
            uint256 fundBal = collateralVault.balances(insuranceFund, series.settlementAsset);
            if (fundBal < amount) revert InsuranceFundInsufficient();

            collateralVault.transferBetweenAccounts(series.settlementAsset, insuranceFund, trader, amount);

            paidToTrader = amount;
            seriesPaid[optionId] += amount;
        } else if (pnl < 0) {
            uint256 amountOwed = uint256(-pnl);

            uint256 traderBal = collateralVault.balances(trader, series.settlementAsset);
            uint256 amountToCollect = traderBal >= amountOwed ? amountOwed : traderBal;

            if (amountToCollect > 0) {
                collateralVault.transferBetweenAccounts(series.settlementAsset, trader, insuranceFund, amountToCollect);
                collectedFromTrader = amountToCollect;
                seriesCollected[optionId] += amountToCollect;
            }

            if (amountToCollect < amountOwed) {
                badDebt = amountOwed - amountToCollect;
                seriesBadDebt[optionId] += badDebt;
            }
        }

        emit AccountSettled(trader, optionId, pnl, collectedFromTrader, paidToTrader, badDebt);

        emit SeriesSettlementAccountingUpdated(
            optionId,
            seriesCollected[optionId],
            seriesPaid[optionId],
            seriesBadDebt[optionId]
        );
    }

    function settleAccounts(uint256 optionId, address[] calldata traders) external whenNotPaused {
        uint256 len = traders.length;
        for (uint256 i = 0; i < len; i++) {
            settleAccount(optionId, traders[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION LOGIC (A-1)
    //////////////////////////////////////////////////////////////*/

    function getMarginRatioBps(address trader) public view returns (uint256) {
        if (address(riskModule) == address(0)) return type(uint256).max;

        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(trader);

        if (risk.maintenanceMargin == 0) return type(uint256).max;
        if (risk.equity <= 0) return 0;

        return (uint256(risk.equity) * 10_000) / risk.maintenanceMargin;
    }

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(riskModule) == address(0)) return false;

        IRiskModule.AccountRisk memory risk = riskModule.computeAccountRisk(trader);

        if (risk.maintenanceMargin == 0) return false;
        if (risk.equity <= 0) return true;

        uint256 ratioBps = (uint256(risk.equity) * 10_000) / risk.maintenanceMargin;
        return ratioBps < liquidationThresholdBps;
    }

    function liquidate(
        address trader,
        uint256[] calldata optionIds,
        uint128[] calldata quantities
    ) external whenNotPaused {
        if (trader == address(0)) revert ZeroAddress();
        if (trader == msg.sender) revert InvalidTrade();
        if (optionIds.length == 0 || optionIds.length != quantities.length) revert LengthMismatch();
        if (baseCollateralToken == address(0)) revert NoBaseCollateral();
        if (address(riskModule) == address(0)) revert RiskModuleNotSet();
        if (liquidationCloseFactorBps == 0) revert LiquidationCloseFactorZero();

        uint256 ratioBeforeBps = getMarginRatioBps(trader);
        if (!isLiquidatable(trader)) revert NotLiquidatable();

        uint256 traderTotalShort = totalShortContracts[trader];
        if (traderTotalShort == 0) revert NotLiquidatable();

        uint256 maxCloseOverall = (traderTotalShort * liquidationCloseFactorBps) / 10_000;
        if (maxCloseOverall == 0) maxCloseOverall = 1;

        address liquidator = msg.sender;
        uint256 totalContractsClosed;

        uint256 totalCashRequested;
        address settlementAsset = baseCollateralToken;

        for (uint256 i = 0; i < optionIds.length; i++) {
            if (totalContractsClosed >= maxCloseOverall) break;

            uint256 optionId = optionIds[i];
            uint128 requestedQty = quantities[i];
            if (requestedQty == 0) continue;

            OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);

            if (block.timestamp >= s.expiry) continue;
            if (s.settlementAsset != baseCollateralToken) continue;

            Position storage traderPos = _positions[trader][optionId];
            if (traderPos.quantity >= 0) continue;

            Position storage liqPos = _positions[liquidator][optionId];

            int128 oldTraderQty = traderPos.quantity;
            int128 oldLiqQty = liqPos.quantity;

            uint256 traderShortAbs = uint256(int256(-oldTraderQty));
            uint256 remainingAllowance = maxCloseOverall - totalContractsClosed;

            uint256 liqQtyU = uint256(requestedQty);
            if (liqQtyU > traderShortAbs) liqQtyU = traderShortAbs;
            if (liqQtyU > remainingAllowance) liqQtyU = remainingAllowance;
            if (liqQtyU == 0) continue;

            uint128 liqQty = uint128(liqQtyU);

            uint256 liqPricePerContract = _computeLiquidationPricePerContract(s);
            totalCashRequested += liqPricePerContract * uint256(liqQty);

            traderPos.quantity = oldTraderQty + int128(int256(uint256(liqQty)));
            liqPos.quantity = oldLiqQty - int128(int256(uint256(liqQty)));

            int128 newTraderQty = traderPos.quantity;
            int128 newLiqQty = liqPos.quantity;

            _updateTotalShortContracts(trader, oldTraderQty, newTraderQty);
            _updateTotalShortContracts(liquidator, oldLiqQty, newLiqQty);

            _updateOpenSeriesOnChange(trader, optionId, oldTraderQty, newTraderQty);
            _updateOpenSeriesOnChange(liquidator, optionId, oldLiqQty, newLiqQty);

            totalContractsClosed += uint256(liqQty);
        }

        if (totalContractsClosed == 0) revert LiquidationNothingToDo();

        uint256 traderBalForCash = collateralVault.balances(trader, settlementAsset);
        uint256 cashPaid = totalCashRequested <= traderBalForCash ? totalCashRequested : traderBalForCash;

        if (cashPaid > 0) {
            collateralVault.transferBetweenAccounts(settlementAsset, trader, liquidator, cashPaid);
        }

        emit LiquidationCashflow(liquidator, trader, settlementAsset, cashPaid, totalCashRequested);

        uint256 mmBase = baseMaintenanceMarginPerContract * totalContractsClosed;
        uint256 penalty = (mmBase * liquidationPenaltyBps) / 10_000;

        uint256 traderBal = collateralVault.balances(trader, baseCollateralToken);
        uint256 seized = penalty <= traderBal ? penalty : traderBal;

        if (seized > 0) {
            collateralVault.transferBetweenAccounts(baseCollateralToken, trader, liquidator, seized);
        }

        uint256 ratioAfterBps = getMarginRatioBps(trader);
        if (ratioAfterBps < ratioBeforeBps + minLiquidationImprovementBps) revert LiquidationNotImproving();

        emit Liquidation(liquidator, trader, optionIds, quantities, seized);

        IRiskModule.AccountRisk memory liqRisk = riskModule.computeAccountRisk(liquidator);
        require(liqRisk.equity >= int256(liqRisk.initialMargin), "MARGIN_LIQUIDATOR");
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE HELPERS
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(uint256 optionId)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        OptionProductRegistry.OptionSeries memory series = optionRegistry.getSeries(optionId);
        return oracle.getPrice(series.underlying, series.settlementAsset);
    }
}
