// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {IMarginEngineTrade} from "../matching/IMarginEngineTrade.sol";
import {OptionMatchingEngine} from "../matching/OptionMatchingEngine.sol";

/// @notice Local-only experiment. Physical delivery needs separate product/API/indexer approval.
/// @dev No cash-settlement or legacy-vault path exists in this contract. A lot is
///      bound to its buyer and writer; transferability is not supported.
contract CoveredCallMarginEngine is IMarginEngineTrade, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotAuthorized();
    error InvalidConfiguration();
    error InvalidTrade();
    error NotExpired();
    error ExerciseWindowClosed();
    error ExerciseWindowOpen();
    error InsufficientPosition();
    error Insolvent();

    event CoveredFill(
        uint256 indexed optionId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 premium,
        uint256 lockedUnderlying
    );
    /// @dev Emitted immediately before CoveredFill for the same fill, including zero-fee fills.
    event PhysicalFeePaid(
        uint256 indexed optionId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 buyerFee,
        uint256 sellerFee,
        address recipient
    );
    event PhysicalExercise(
        uint256 indexed optionId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 strikePaid,
        uint256 underlyingDelivered
    );
    event LongWaived(
        uint256 indexed optionId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 underlyingReturned
    );
    event LongExpired(
        uint256 indexed optionId,
        address indexed buyer,
        address indexed seller,
        uint256 quantity,
        uint256 underlyingReturned
    );

    address public immutable owner;
    OptionProductRegistry public immutable registry;
    IERC20 public immutable underlying;
    IERC20 public immutable quote;
    address public immutable oracle;
    uint32 public immutable liquidationOracleMaxDelay;
    uint32 public immutable exerciseWindow;
    uint256 public immutable optionId;
    uint256 public immutable underlyingPerContract;
    uint256 public immutable strikePerContract;

    address public matchingEngine;
    address public feeRecipient;
    uint32 public makerFeePpm;
    uint32 public takerFeePpm;
    bool public paused = true;
    uint256 public totalLockedUnderlying;
    mapping(address => mapping(address => uint256)) public openLots;

    constructor(
        address owner_,
        address registry_,
        uint256 optionId_,
        address oracle_,
        uint32 maxDelay_,
        uint32 exerciseWindow_
    ) {
        if (
            owner_ == address(0) || registry_ == address(0) || oracle_ == address(0) || maxDelay_ == 0
                || exerciseWindow_ == 0 || exerciseWindow_ > 30 days
        ) {
            revert InvalidConfiguration();
        }
        OptionProductRegistry.OptionSeries memory s = OptionProductRegistry(registry_).getSeries(optionId_);
        if (!s.isCall || !s.isEuropean || s.contractSize1e8 != 1e8 || s.underlying == s.settlementAsset) {
            revert InvalidConfiguration();
        }
        // This prototype deliberately supports only mWETH(18)/mUSDC(6).
        // 1e8 price units convert exactly to 1e6 quote units only at 100-unit granularity.
        if (
            IERC20Metadata(s.underlying).decimals() != 18 || IERC20Metadata(s.settlementAsset).decimals() != 6
                || s.strike == 0 || s.strike % 100 != 0
        ) revert InvalidConfiguration();
        owner = owner_;
        registry = OptionProductRegistry(registry_);
        optionId = optionId_;
        underlying = IERC20(s.underlying);
        quote = IERC20(s.settlementAsset);
        oracle = oracle_;
        liquidationOracleMaxDelay = maxDelay_;
        exerciseWindow = exerciseWindow_;
        underlyingPerContract = 1e18;
        strikePerContract = uint256(s.strike) / 100;
    }

    /// @dev One-time binding avoids silently routing this reserve to a second matcher.
    function bindMatchingEngine(address engine) external {
        if (msg.sender != owner || engine == address(0) || matchingEngine != address(0)) revert NotAuthorized();
        OptionMatchingEngine configured = OptionMatchingEngine(engine);
        if (
            !configured.configurationFrozen() || address(configured.marginEngine()) != address(this)
                || address(configured.optionRegistry()) != address(registry)
        ) revert InvalidConfiguration();
        matchingEngine = engine;
    }

    /// @notice Local experimental fee schedule, frozen when the matcher is bound.
    /// @dev Rates are fractions of the premium; no exercise fee or change to strike delivery.
    function configureFees(address recipient, uint32 makerPpm, uint32 takerPpm) external {
        if (msg.sender != owner || matchingEngine != address(0)) revert NotAuthorized();
        // Reuse FeesManagerV2's positive-fee ceiling; rebates are not supported here.
        if (
            makerPpm > 1_000 || takerPpm > 1_000
                || ((makerPpm != 0 || takerPpm != 0) && (recipient == address(0) || recipient == address(this)))
        ) {
            revert InvalidConfiguration();
        }
        feeRecipient = recipient;
        makerFeePpm = makerPpm;
        takerFeePpm = takerPpm;
    }

    function setPaused(bool value) external {
        if (msg.sender != owner) revert NotAuthorized();
        paused = value;
    }

    function applyTrade(Trade calldata t) external nonReentrant {
        if (msg.sender != matchingEngine || paused) revert NotAuthorized();
        OptionProductRegistry.OptionSeries memory s = registry.getSeries(optionId);
        if (
            !s.isActive || block.timestamp >= s.expiry || t.optionId != optionId || t.quantity == 0
                || t.buyer == address(0) || t.seller == address(0) || t.buyer == t.seller || t.price == 0
        ) {
            revert InvalidTrade();
        }
        uint256 amount = uint256(t.quantity) * underlyingPerContract;
        uint256 premium = uint256(t.quantity) * uint256(t.price);
        uint256 buyerFee = Math.mulDiv(premium, t.buyerIsMaker ? makerFeePpm : takerFeePpm, 1_000_000);
        uint256 sellerFee = Math.mulDiv(premium, t.buyerIsMaker ? takerFeePpm : makerFeePpm, 1_000_000);
        uint256 fees = buyerFee + sellerFee;
        if (fees != 0 && (feeRecipient == t.buyer || feeRecipient == t.seller)) revert InvalidTrade();
        uint256 beforeBalance = underlying.balanceOf(address(this));
        uint256 sellerUnderlyingBefore = underlying.balanceOf(t.seller);
        underlying.safeTransferFrom(t.seller, address(this), amount);
        if (underlying.balanceOf(address(this)) - beforeBalance != amount) revert Insolvent();
        if (sellerUnderlyingBefore - underlying.balanceOf(t.seller) != amount) revert Insolvent();
        uint256 sellerQuoteBefore = quote.balanceOf(t.seller);
        uint256 buyerQuoteBefore = quote.balanceOf(t.buyer);
        uint256 recipientQuoteBefore = fees == 0 ? 0 : quote.balanceOf(feeRecipient);
        quote.safeTransferFrom(t.buyer, t.seller, premium - sellerFee);
        if (fees != 0) quote.safeTransferFrom(t.buyer, feeRecipient, fees);
        if (quote.balanceOf(t.seller) - sellerQuoteBefore != premium - sellerFee) revert Insolvent();
        if (buyerQuoteBefore - quote.balanceOf(t.buyer) != premium + buyerFee) revert Insolvent();
        if (fees != 0 && quote.balanceOf(feeRecipient) - recipientQuoteBefore != fees) revert Insolvent();
        openLots[t.buyer][t.seller] += t.quantity;
        totalLockedUnderlying += amount;
        if (underlying.balanceOf(address(this)) < totalLockedUnderlying) revert Insolvent();
        emit PhysicalFeePaid(optionId, t.buyer, t.seller, t.quantity, buyerFee, sellerFee, feeRecipient);
        emit CoveredFill(optionId, t.buyer, t.seller, t.quantity, premium, amount);
    }

    /// @notice European physical exercise; no oracle is needed for delivery.
    /// @dev Buyer pays strike in quote units; writer's pre-locked underlying is delivered.
    function exercise(address seller, uint256 quantity) external nonReentrant {
        uint256 expiry = registry.getSeries(optionId).expiry;
        if (block.timestamp < expiry) revert NotExpired();
        if (block.timestamp >= expiry + exerciseWindow) revert ExerciseWindowClosed();
        _consumeLot(msg.sender, seller, quantity);
        uint256 strikePaid = quantity * strikePerContract;
        uint256 delivered = quantity * underlyingPerContract;
        uint256 sellerQuoteBefore = quote.balanceOf(seller);
        uint256 buyerQuoteBefore = quote.balanceOf(msg.sender);
        quote.safeTransferFrom(msg.sender, seller, strikePaid);
        if (quote.balanceOf(seller) - sellerQuoteBefore != strikePaid) revert Insolvent();
        if (buyerQuoteBefore - quote.balanceOf(msg.sender) != strikePaid) revert Insolvent();
        uint256 buyerUnderlyingBefore = underlying.balanceOf(msg.sender);
        uint256 engineUnderlyingBefore = underlying.balanceOf(address(this));
        underlying.safeTransfer(msg.sender, delivered);
        if (underlying.balanceOf(msg.sender) - buyerUnderlyingBefore != delivered) revert Insolvent();
        if (engineUnderlyingBefore - underlying.balanceOf(address(this)) != delivered) revert Insolvent();
        if (underlying.balanceOf(address(this)) < totalLockedUnderlying) revert Insolvent();
        emit PhysicalExercise(optionId, msg.sender, seller, quantity, strikePaid, delivered);
    }

    /// @notice The buyer alone can relinquish exercise rights and release the writer's cover.
    /// @dev There is intentionally no unilateral writer reclaim or unapproved expiry window.
    function waive(address seller, uint256 quantity) external nonReentrant {
        if (block.timestamp < registry.getSeries(optionId).expiry) revert NotExpired();
        _consumeLot(msg.sender, seller, quantity);
        uint256 released = quantity * underlyingPerContract;
        uint256 sellerUnderlyingBefore = underlying.balanceOf(seller);
        uint256 engineUnderlyingBefore = underlying.balanceOf(address(this));
        underlying.safeTransfer(seller, released);
        if (underlying.balanceOf(seller) - sellerUnderlyingBefore != released) revert Insolvent();
        if (engineUnderlyingBefore - underlying.balanceOf(address(this)) != released) revert Insolvent();
        if (underlying.balanceOf(address(this)) < totalLockedUnderlying) revert Insolvent();
        emit LongWaived(optionId, msg.sender, seller, quantity, released);
    }

    /// @notice Anyone can release a lapsed lot to its writer after the fixed window.
    /// @dev The immutable window cannot be shortened after a position is opened.
    function releaseExpired(address buyer, address seller, uint256 quantity) external nonReentrant {
        if (block.timestamp < uint256(registry.getSeries(optionId).expiry) + exerciseWindow) {
            revert ExerciseWindowOpen();
        }
        _consumeLot(buyer, seller, quantity);
        uint256 released = quantity * underlyingPerContract;
        uint256 beforeBalance = underlying.balanceOf(seller);
        uint256 engineUnderlyingBefore = underlying.balanceOf(address(this));
        underlying.safeTransfer(seller, released);
        if (underlying.balanceOf(seller) - beforeBalance != released) revert Insolvent();
        if (engineUnderlyingBefore - underlying.balanceOf(address(this)) != released) revert Insolvent();
        if (underlying.balanceOf(address(this)) < totalLockedUnderlying) revert Insolvent();
        emit LongExpired(optionId, buyer, seller, quantity, released);
    }

    function _consumeLot(address buyer, address seller, uint256 quantity) private {
        uint256 current = openLots[buyer][seller];
        if (quantity == 0 || quantity > current) revert InsufficientPosition();
        openLots[buyer][seller] = current - quantity;
        totalLockedUnderlying -= quantity * underlyingPerContract;
    }
}
