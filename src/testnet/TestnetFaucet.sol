// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TestnetFaucet
/// @notice Reserve-based testnet faucet that lets ANY caller pull a
///         fixed amount of each configured ERC20 with a per-caller
///         cooldown. The faucet does NOT own the underlying ERC20s
///         — the operator funds it by transferring tokens to the
///         faucet address after deployment. This means deploying the
///         faucet requires no ownership change on the existing
///         testnet mocks (`TestnetMockERC20`).
///
/// @dev Testnet-only. Deployed exclusively on Base Sepolia (chain id
///      84532) via `script/DeployTestnetFaucet.s.sol`. Refuses any
///      activity on mainnet via the deploy script's chain guard; the
///      contract itself does not gate by chain id because the
///      reserves themselves are valueless mock tokens.
///
///      Threat model is *exposure*, not value loss:
///        * `claim()` is `nonReentrant` despite being trivially
///          ERC20-only — defence in depth against a future
///          hostile-token configuration mistake.
///        * State writes (`lastClaimedAt`) happen BEFORE
///          `SafeERC20.safeTransfer` (CEI pattern) — a malicious
///          token can't re-enter and double-claim.
///        * Per-caller cooldown (not per-token) keeps the UX
///          predictable: one timestamp to display, one rate-limit
///          to enforce. Adding a new token after a caller has
///          already claimed simply means that caller picks it up on
///          their next claim.
///        * Owner can pause/unpause, reconfigure token amounts, and
///          withdraw reserves at any time. There is no time-locked
///          owner action — this is a testnet faucet, not a vault.
///
///      Funding model:
///        1. Operator deploys the faucet (constructor takes an
///           `initialOwner` + `initialCooldownSeconds`).
///        2. Operator registers each `TestnetMockERC20` and its
///           per-claim amount via `setToken`.
///        3. Operator mints tokens directly to the faucet address
///           (since they own the `TestnetMockERC20` instances) OR
///           transfers from a pre-minted operator wallet.
///        4. Public testers call `claim()` from `/api` in the
///           DeOpt frontend.
contract TestnetFaucet is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct TokenConfig {
        IERC20 token;
        uint256 amount;
    }

    /// @notice Ordered list of configured tokens. Iteration is safe:
    ///         token count is bounded by operator action only, and
    ///         the operator's interest is to keep it tiny (3 tokens
    ///         on the current Base Sepolia testnet: mUSDC, mWETH,
    ///         mWBTC).
    TokenConfig[] internal _tokens;

    /// @notice Maps token address → index-into-`_tokens` plus one.
    ///         Zero means "not present" — saves a sentinel value
    ///         without burning a separate "exists" mapping.
    mapping(address => uint256) internal _tokenIndexPlusOne;

    /// @notice Wall-clock seconds the same caller must wait between
    ///         consecutive claims. Configurable by the owner.
    uint256 public cooldownSeconds;

    /// @notice Per-caller last-claim timestamp. `0` means
    ///         "never claimed".
    mapping(address => uint256) public lastClaimedAt;

    // ── Errors ───────────────────────────────────────────────────

    error NoTokensConfigured();
    error CooldownNotElapsed(uint256 nextAvailableAt);
    error InsufficientReserves(address token, uint256 needed, uint256 available);
    error ZeroAddress();
    error ZeroAmount();
    error TokenNotRegistered(address token);

    // ── Events ───────────────────────────────────────────────────

    event Claimed(address indexed account, address indexed token, uint256 amount);
    event TokenConfigUpdated(address indexed token, uint256 amount);
    event TokenRemoved(address indexed token);
    event CooldownUpdated(uint256 cooldownSeconds);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    /// @param initialOwner            Address authorised to reconfigure
    ///                                / pause / withdraw. Pass the
    ///                                operator EOA or multisig.
    /// @param initialCooldownSeconds  Per-caller rate-limit window.
    ///                                Suggested: 6 hours (21600).
    constructor(address initialOwner, uint256 initialCooldownSeconds) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        cooldownSeconds = initialCooldownSeconds;
        emit CooldownUpdated(initialCooldownSeconds);
    }

    // ── Owner reconfiguration ────────────────────────────────────

    /// @notice Add or update a token + per-claim amount. Re-calling
    ///         with the same token address updates the amount in
    ///         place.
    function setToken(IERC20 token, uint256 amount) external onlyOwner {
        if (address(token) == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 idxPlusOne = _tokenIndexPlusOne[address(token)];
        if (idxPlusOne == 0) {
            _tokens.push(TokenConfig({token: token, amount: amount}));
            _tokenIndexPlusOne[address(token)] = _tokens.length;
        } else {
            _tokens[idxPlusOne - 1].amount = amount;
        }
        emit TokenConfigUpdated(address(token), amount);
    }

    /// @notice Remove a token from the rotation. Reserves stay in
    ///         the contract — withdraw them separately if needed.
    function removeToken(IERC20 token) external onlyOwner {
        uint256 idxPlusOne = _tokenIndexPlusOne[address(token)];
        if (idxPlusOne == 0) revert TokenNotRegistered(address(token));
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = _tokens.length - 1;
        if (idx != lastIdx) {
            TokenConfig memory swap = _tokens[lastIdx];
            _tokens[idx] = swap;
            _tokenIndexPlusOne[address(swap.token)] = idx + 1;
        }
        _tokens.pop();
        delete _tokenIndexPlusOne[address(token)];
        emit TokenRemoved(address(token));
    }

    function setCooldown(uint256 newCooldownSeconds) external onlyOwner {
        cooldownSeconds = newCooldownSeconds;
        emit CooldownUpdated(newCooldownSeconds);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Owner pulls reserves back out (e.g. to redeploy a new
    ///         faucet on a fresh testnet beta). Does NOT change
    ///         token registrations.
    function withdraw(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        emit Withdrawn(address(token), to, amount);
        token.safeTransfer(to, amount);
    }

    // ── Public read views ────────────────────────────────────────

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    function tokenAt(uint256 i) external view returns (address token, uint256 amount) {
        TokenConfig memory cfg = _tokens[i];
        return (address(cfg.token), cfg.amount);
    }

    /// @notice Returns the unix timestamp at which `caller` may
    ///         claim again. `0` means "no claim recorded — claim
    ///         is available right now".
    function nextClaimAvailableAt(address caller) external view returns (uint256) {
        uint256 last = lastClaimedAt[caller];
        if (last == 0) return 0;
        return last + cooldownSeconds;
    }

    // ── Public claim ─────────────────────────────────────────────

    /// @notice Transfer each registered token's per-claim amount to
    ///         `msg.sender`. Caller-side cooldown is enforced
    ///         BEFORE any transfer. The full claim either succeeds
    ///         (all tokens transferred + timestamp updated) or
    ///         reverts (no partial claim, no timestamp update).
    ///
    /// @dev Reverts with `NoTokensConfigured` if no tokens are
    ///      registered, `CooldownNotElapsed(nextAvailableAt)` if the
    ///      caller claimed recently, and
    ///      `InsufficientReserves(token, needed, available)` if any
    ///      token's reserve is below its per-claim amount.
    function claim() external whenNotPaused nonReentrant {
        uint256 count = _tokens.length;
        if (count == 0) revert NoTokensConfigured();

        uint256 last = lastClaimedAt[msg.sender];
        if (last != 0 && block.timestamp < last + cooldownSeconds) {
            revert CooldownNotElapsed(last + cooldownSeconds);
        }

        // Effects before interactions — CEI pattern.
        lastClaimedAt[msg.sender] = block.timestamp;

        for (uint256 i = 0; i < count; ++i) {
            TokenConfig memory cfg = _tokens[i];
            uint256 reserve = cfg.token.balanceOf(address(this));
            if (reserve < cfg.amount) {
                revert InsufficientReserves(address(cfg.token), cfg.amount, reserve);
            }
            emit Claimed(msg.sender, address(cfg.token), cfg.amount);
            cfg.token.safeTransfer(msg.sender, cfg.amount);
        }
    }
}
