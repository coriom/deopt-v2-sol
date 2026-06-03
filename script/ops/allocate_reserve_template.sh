#!/usr/bin/env bash
# V2G-OPS-HARDEN-P0 — Reserve allocation template (DOUBLE-CONFIRM, NOT
# EXECUTABLE BY DEFAULT).
#
# Calls `ProtocolFeeVault.allocateToRebateReserve(asset, amount)` from the
# vault owner. Moves `amount` from feeBalance → rebateReserve. Preserves
# drift = 0 because both legs live inside the vault's CV account.
#
# This script will refuse to do anything unless the operator explicitly
# acknowledges intent. The first gate prints the simulated post-state and
# stops. Only when BOTH gates are set will it broadcast.
#
# Gates:
#   OPERATOR_CONFIRM_ALLOCATE_RESERVE=true   # required to print pre-state +
#                                            #   simulate the call
#   BROADCAST_ALLOCATE_RESERVE=true          # required additionally to send
#
# Inputs (env):
#   RPC_URL        required
#   ASSET          default mUSDC
#   AMOUNT         default 10
#   MAINNET_OK     default false; required true to allow chain != 84532
#
# Hard constraints:
#   - read-only by default
#   - no private key inline (uses `--account deopt-deployer` keystore)
#   - refuses amount > feeBalance
#   - refuses mainnet unless MAINNET_OK=true
#   - refuses if drift != 0 (would corrupt invariant 2)
#
# Exit codes:
#   0  printed dry-run only (gates partially set) OR broadcast succeeded
#   2  gate failed (insufficient feeBalance, mainnet without override,
#      drift != 0, missing confirmation)
#   4  missing dependency or unsupported chain id

set -euo pipefail

if ! command -v cast >/dev/null 2>&1; then
  echo "ERROR: \`cast\` not found in PATH" >&2
  exit 4
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "ERROR: \`timeout\` (coreutils) not found in PATH" >&2
  exit 4
fi

# --- RPC fallback: prefer explicit env, else .env.base-sepolia --------------
# We never source the env file directly (it contains DEPLOYER_PRIVATE_KEY).
# Only extract RPC_URL from it and only when the operator has not set one.
if [[ -z "${RPC_URL:-}" ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ENV_FILE="${HERE}/../../.env.base-sepolia"
  if [[ -f "${ENV_FILE}" ]]; then
    RPC_URL="$(grep -E '^RPC_URL=' "${ENV_FILE}" | head -1 | cut -d= -f2-)"
  fi
fi
if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL is not set and no .env.base-sepolia fallback found" >&2
  exit 4
fi

# --- Network timeout (seconds) ------------------------------------------------
# Hard ceiling per cast call/send. Set CAST_TIMEOUT to override; never disable.
CAST_TIMEOUT="${CAST_TIMEOUT:-20}"
if ! [[ "${CAST_TIMEOUT}" =~ ^[0-9]+$ ]] || (( CAST_TIMEOUT == 0 )); then
  echo "ERROR: CAST_TIMEOUT must be a positive integer (seconds), got '${CAST_TIMEOUT}'" >&2
  exit 4
fi

log() { printf '• %s\n' "$*" >&2; }

# --- Canonical addresses ------------------------------------------------------
PROTOCOL_FEE_VAULT="${PROTOCOL_FEE_VAULT:-0x7C0a3B6feBd5BFFc164f37738299AeB453181886}"
COLLATERAL_VAULT="${COLLATERAL_VAULT:-0x00340C360353a5AB784c5Bc5c44322A6AF0625D3}"
ASSET="${ASSET:-0x6eAe407f5640B006faC9965182e238582A3B412E}"   # mUSDC
AMOUNT="${AMOUNT:-10}"
DEPLOYER="${DEPLOYER:-0xc35F7A8A103A9A4464adfaa76B9B514093D23C27}"

OPERATOR_CONFIRM_ALLOCATE_RESERVE="${OPERATOR_CONFIRM_ALLOCATE_RESERVE:-false}"
BROADCAST_ALLOCATE_RESERVE="${BROADCAST_ALLOCATE_RESERVE:-false}"
MAINNET_OK="${MAINNET_OK:-false}"

if [[ "${OPERATOR_CONFIRM_ALLOCATE_RESERVE}" != "true" ]]; then
  cat >&2 <<'EOF'
REFUSED: this template requires explicit operator acknowledgement.

  Step 1 — dry-run preview:
    OPERATOR_CONFIRM_ALLOCATE_RESERVE=true \
    ASSET=... AMOUNT=... \
    ./allocate_reserve_template.sh

  Step 2 — broadcast (only after reviewing the dry-run output):
    OPERATOR_CONFIRM_ALLOCATE_RESERVE=true \
    BROADCAST_ALLOCATE_RESERVE=true \
    ASSET=... AMOUNT=... \
    ./allocate_reserve_template.sh

  RPC_URL falls back to RPC_URL= in deopt-v2-sol/.env.base-sepolia
  unless explicitly provided in the environment. CAST_TIMEOUT defaults
  to 20s per network call.
EOF
  exit 2
fi

if ! [[ "${AMOUNT}" =~ ^[0-9]+$ ]] || (( AMOUNT == 0 )); then
  echo "ERROR: AMOUNT must be a positive integer, got '${AMOUNT}'" >&2
  exit 4
fi

# --- Network helpers (every cast invocation is bounded by CAST_TIMEOUT) -------
# `timeout` exit 124 ⇒ command timed out. We translate that to exit 4 with a
# clear message so the dry-run path can never hang silently on a degraded RPC.
tcall() {
  local out rc
  set +e
  out="$(timeout --foreground "${CAST_TIMEOUT}s" cast call --rpc-url "${RPC_URL}" "$@" 2>&1)"
  rc=$?
  set -e
  if (( rc == 124 )); then
    echo "ERROR: cast call timed out after ${CAST_TIMEOUT}s — args: $*" >&2
    exit 4
  elif (( rc != 0 )); then
    echo "ERROR: cast call failed (rc=${rc}) — args: $*" >&2
    echo "${out}" >&2
    exit 4
  fi
  printf '%s' "${out}"
}
tsend() {
  set +e
  timeout --foreground "${CAST_TIMEOUT}s" cast send "$@"
  local rc=$?
  set -e
  if (( rc == 124 )); then
    echo "ERROR: cast send timed out after ${CAST_TIMEOUT}s — args: $*" >&2
    exit 4
  fi
  return "${rc}"
}
tchainid() {
  local out rc
  set +e
  out="$(timeout --foreground "${CAST_TIMEOUT}s" cast chain-id --rpc-url "${RPC_URL}" 2>&1)"
  rc=$?
  set -e
  if (( rc == 124 )); then
    echo "ERROR: cast chain-id timed out after ${CAST_TIMEOUT}s" >&2
    exit 4
  elif (( rc != 0 )); then
    echo "ERROR: cast chain-id failed (rc=${rc}): ${out}" >&2
    exit 4
  fi
  printf '%s' "${out}"
}
uint() { printf '%s' "$1" | awk '{print $1}'; }

# --- Chain id guard -----------------------------------------------------------
log "probing chain id (timeout ${CAST_TIMEOUT}s)"
CHAIN_ID="$(tchainid)"
if [[ "${CHAIN_ID}" != "84532" && "${MAINNET_OK}" != "true" ]]; then
  echo "ERROR: connected to chain ${CHAIN_ID}, expected 84532." >&2
  echo "       Set MAINNET_OK=true ONLY if this is intentional." >&2
  exit 4
fi

log "reading feeBalance(asset)"
V_FEE_BALANCE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'feeBalance(address)(uint256)' "${ASSET}")")"
log "reading rebateReserve(asset)"
V_REBATE_RESERVE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'rebateReserve(address)(uint256)' "${ASSET}")")"
log "reading CV.balances(vault, asset)"
CV_BAL="$(uint "$(tcall "${COLLATERAL_VAULT}" 'balances(address,address)(uint256)' "${PROTOCOL_FEE_VAULT}" "${ASSET}")")"
DRIFT=$(( CV_BAL - V_FEE_BALANCE - V_REBATE_RESERVE ))

NEW_FEE_BALANCE=$(( V_FEE_BALANCE - AMOUNT ))
NEW_REBATE_RESERVE=$(( V_REBATE_RESERVE + AMOUNT ))

echo "================================================================"
echo "PROTOCOL FEE VAULT — allocateToRebateReserve (DRY-RUN PRESTATE)"
echo "  chain                  ${CHAIN_ID}"
echo "  vault                  ${PROTOCOL_FEE_VAULT}"
echo "  asset                  ${ASSET}"
echo "  amount                 ${AMOUNT}"
echo "  caller (keystore)      deopt-deployer  (--from ${DEPLOYER})"
echo "----------------------------------------------------------------"
echo "  pre  feeBalance        ${V_FEE_BALANCE}"
echo "  pre  rebateReserve     ${V_REBATE_RESERVE}"
echo "  pre  CV.balances(vault)${CV_BAL}"
echo "  pre  drift             ${DRIFT}"
echo "  post feeBalance        ${NEW_FEE_BALANCE}    (= pre - amount)"
echo "  post rebateReserve     ${NEW_REBATE_RESERVE} (= pre + amount)"
echo "  post drift             ${DRIFT}              (unchanged ✓)"
echo "================================================================"

if (( DRIFT != 0 )); then
  echo "REFUSED: drift=${DRIFT} != 0. Resolve invariant 2 before allocating." >&2
  exit 2
fi
if (( AMOUNT > V_FEE_BALANCE )); then
  echo "REFUSED: AMOUNT=${AMOUNT} > feeBalance=${V_FEE_BALANCE} (contract would revert InsufficientFeeBalance)." >&2
  exit 2
fi

if [[ "${BROADCAST_ALLOCATE_RESERVE}" != "true" ]]; then
  echo ""
  echo "DRY-RUN ONLY. Set BROADCAST_ALLOCATE_RESERVE=true to broadcast."
  exit 0
fi

echo ""
log "broadcasting allocateToRebateReserve(${ASSET}, ${AMOUNT}) (timeout ${CAST_TIMEOUT}s)"
echo "BROADCASTING ..."
tsend "${PROTOCOL_FEE_VAULT}" \
  'allocateToRebateReserve(address,uint256)' \
  "${ASSET}" \
  "${AMOUNT}" \
  --rpc-url "${RPC_URL}" \
  --account deopt-deployer \
  --from "${DEPLOYER}"

echo ""
echo "Re-reading vault post-state ..."
log "reading post feeBalance(asset)"
POST_FEE_BALANCE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'feeBalance(address)(uint256)' "${ASSET}")")"
log "reading post rebateReserve(asset)"
POST_REBATE_RESERVE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'rebateReserve(address)(uint256)' "${ASSET}")")"
log "reading post CV.balances(vault, asset)"
POST_CV_BAL="$(uint "$(tcall "${COLLATERAL_VAULT}" 'balances(address,address)(uint256)' "${PROTOCOL_FEE_VAULT}" "${ASSET}")")"
POST_DRIFT=$(( POST_CV_BAL - POST_FEE_BALANCE - POST_REBATE_RESERVE ))

echo "  post  feeBalance        ${POST_FEE_BALANCE}"
echo "  post  rebateReserve     ${POST_REBATE_RESERVE}"
echo "  post  CV.balances(vault)${POST_CV_BAL}"
echo "  post  drift             ${POST_DRIFT}"

if (( POST_DRIFT != 0 )); then
  echo "ALERT: post-broadcast drift=${POST_DRIFT} != 0. Investigate immediately." >&2
  exit 2
fi

echo "RESULT: allocation succeeded, drift preserved at 0"
exit 0
