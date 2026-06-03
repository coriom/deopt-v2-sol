#!/usr/bin/env bash
# V2G-OPS-HARDEN-P0 — Reserve-aware preflight for the OPTION RFQ smoke.
#
# Blocks any new OPTION RFQ smoke until ALL of these are true on-chain:
#   1. FM-V2.feeRecipient          == PROTOCOL_FEE_VAULT
#   2. FM-V2.rebateFundingAccount  == PROTOCOL_FEE_VAULT
#   3. FM-V2.protocolFeeVault      == PROTOCOL_FEE_VAULT
#   4. PFV.rebateReserve(asset)    >= EXPECTED_REBATE   (default 10)
#   5. FM-V2.rebateBudget(asset)   >= EXPECTED_REBATE
#   6. drift                       == 0
#   7. PFV.rebatesPaused           == false
#
# Prints the live OME nonces and the recommended next nonce pair. If the
# operator supplies INTENT_ID via env (32-byte hex), it is echoed verbatim
# as the recommended `intentId` — the script never generates one.
#
# Hard constraints:
#   - read-only (cast call only)
#   - no cast send
#   - no private key
#   - no admin token
#   - refuses CHAIN_ID != 84532 unless OPERATOR_OVERRIDE_CHAIN_ID=true
#
# Exit codes:
#   0  preflight passed; safe to smoke with the printed nonces
#   2  preflight FAILED — at least one gate is unsafe (DO NOT smoke)
#   4  missing dependency or unsupported chain id
#
# Usage:
#   RPC_URL=... EXPECTED_REBATE=10 ./preflight_option_rfq_smoke.sh
#   RPC_URL=... EXPECTED_REBATE=19 INTENT_ID=0x...32bytes ./preflight_option_rfq_smoke.sh

set -euo pipefail

if ! command -v cast >/dev/null 2>&1; then
  echo "ERROR: \`cast\` (foundry) not found in PATH" >&2
  exit 4
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "ERROR: \`timeout\` (coreutils) not found in PATH" >&2
  exit 4
fi

# Prefer explicit RPC_URL; otherwise extract from .env.base-sepolia.
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

CAST_TIMEOUT="${CAST_TIMEOUT:-20}"
if ! [[ "${CAST_TIMEOUT}" =~ ^[0-9]+$ ]] || (( CAST_TIMEOUT == 0 )); then
  echo "ERROR: CAST_TIMEOUT must be a positive integer (seconds), got '${CAST_TIMEOUT}'" >&2
  exit 4
fi
log() { printf '• %s\n' "$*" >&2; }

EXPECTED_REBATE="${EXPECTED_REBATE:-10}"
if ! [[ "${EXPECTED_REBATE}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: EXPECTED_REBATE must be a non-negative integer, got '${EXPECTED_REBATE}'" >&2
  exit 4
fi

# --- Canonical V2G-R5 addresses (Base Sepolia 84532) --------------------------
NEW_FM_V2="${NEW_FM_V2:-0xF6626177f3B85cc3239667Cc53C04A8007652944}"
PROTOCOL_FEE_VAULT="${PROTOCOL_FEE_VAULT:-0x7C0a3B6feBd5BFFc164f37738299AeB453181886}"
COLLATERAL_VAULT="${COLLATERAL_VAULT:-0x00340C360353a5AB784c5Bc5c44322A6AF0625D3}"
NEW_OME="${NEW_OME:-0x5a5EBF9A9CCd7c012518569DE8283982982670f6}"
M_USDC="${M_USDC:-0x6eAe407f5640B006faC9965182e238582A3B412E}"

TIER2_ADDRESS="${TIER2_ADDRESS:-0x77ca9dd6ccce2d692fb23877a2db7178807b0020}"
TIER4_ADDRESS="${TIER4_ADDRESS:-0x290bd12c93e467bf51c51f5273d35bddb19e9274}"

INTENT_ID="${INTENT_ID:-}"

# --- Network helpers (timeout-wrapped, no `cast send` reachable from here) ----
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
addr() { printf '%s' "$1" | tr -d '[:space:]'; }
uint() { printf '%s' "$1" | awk '{print $1}'; }

# --- Chain id guard -----------------------------------------------------------
log "probing chain id (timeout ${CAST_TIMEOUT}s)"
CHAIN_ID="$(tchainid)"
if [[ "${CHAIN_ID}" != "84532" && "${OPERATOR_OVERRIDE_CHAIN_ID:-false}" != "true" ]]; then
  echo "ERROR: connected to chain ${CHAIN_ID}, expected 84532 (Base Sepolia)" >&2
  exit 4
fi

# --- Reads --------------------------------------------------------------------
log "reading FM-V2.feeRecipient"
FM_FEE_RECIPIENT="$(addr "$(tcall "${NEW_FM_V2}" 'feeRecipient()(address)')")"
log "reading FM-V2.rebateFundingAccount"
FM_REBATE_FUNDING_ACCOUNT="$(addr "$(tcall "${NEW_FM_V2}" 'rebateFundingAccount()(address)')")"
log "reading FM-V2.protocolFeeVault"
FM_PROTOCOL_FEE_VAULT="$(addr "$(tcall "${NEW_FM_V2}" 'protocolFeeVault()(address)')")"
log "reading FM-V2.rebateBudget(mUSDC)"
FM_REBATE_BUDGET_MUSDC="$(uint "$(tcall "${NEW_FM_V2}" 'rebateBudget(address)(uint256)' "${M_USDC}")")"

log "reading vault.feeBalance(mUSDC)"
V_FEE_BALANCE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'feeBalance(address)(uint256)' "${M_USDC}")")"
log "reading vault.rebateReserve(mUSDC)"
V_REBATE_RESERVE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'rebateReserve(address)(uint256)' "${M_USDC}")")"
log "reading vault.rebatesPaused"
V_REBATES_PAUSED="$(tcall "${PROTOCOL_FEE_VAULT}" 'rebatesPaused()(bool)')"

log "reading CV.balances(vault, mUSDC)"
CV_BAL_VAULT_MUSDC="$(uint "$(tcall "${COLLATERAL_VAULT}" 'balances(address,address)(uint256)' "${PROTOCOL_FEE_VAULT}" "${M_USDC}")")"

log "reading OME.nonces(Tier2)"
NONCE_TIER2="$(uint "$(tcall "${NEW_OME}" 'nonces(address)(uint256)' "${TIER2_ADDRESS}")")"
log "reading OME.nonces(Tier4)"
NONCE_TIER4="$(uint "$(tcall "${NEW_OME}" 'nonces(address)(uint256)' "${TIER4_ADDRESS}")")"

DRIFT=$(( CV_BAL_VAULT_MUSDC - V_FEE_BALANCE - V_REBATE_RESERVE ))
NEXT_TIER2=$(( NONCE_TIER2 + 1 ))
NEXT_TIER4=$(( NONCE_TIER4 + 1 ))

# --- Gate evaluation ----------------------------------------------------------
PASS=true
FAILS=()

LC_PFV="${PROTOCOL_FEE_VAULT,,}"
if [[ "${FM_FEE_RECIPIENT,,}" != "${LC_PFV}" ]]; then
  PASS=false
  FAILS+=("feeRecipient ${FM_FEE_RECIPIENT} != PFV ${PROTOCOL_FEE_VAULT}")
fi
if [[ "${FM_REBATE_FUNDING_ACCOUNT,,}" != "${LC_PFV}" ]]; then
  PASS=false
  FAILS+=("rebateFundingAccount ${FM_REBATE_FUNDING_ACCOUNT} != PFV ${PROTOCOL_FEE_VAULT}")
fi
if [[ "${FM_PROTOCOL_FEE_VAULT,,}" != "${LC_PFV}" ]]; then
  PASS=false
  FAILS+=("protocolFeeVault ${FM_PROTOCOL_FEE_VAULT} != PFV ${PROTOCOL_FEE_VAULT}")
fi

if [[ "${DRIFT}" != "0" ]]; then
  PASS=false
  FAILS+=("invariant 2 drift=${DRIFT} (expected 0)")
fi

if [[ "${V_REBATES_PAUSED}" != "false" ]]; then
  PASS=false
  FAILS+=("rebates are PAUSED on the vault")
fi

if (( V_REBATE_RESERVE < EXPECTED_REBATE )); then
  PASS=false
  FAILS+=("rebateReserve=${V_REBATE_RESERVE} < EXPECTED_REBATE=${EXPECTED_REBATE} (no reserve cover)")
fi
if (( FM_REBATE_BUDGET_MUSDC < EXPECTED_REBATE )); then
  PASS=false
  FAILS+=("rebateBudget=${FM_REBATE_BUDGET_MUSDC} < EXPECTED_REBATE=${EXPECTED_REBATE} (no FM budget cover)")
fi

# --- Output --------------------------------------------------------------------
echo "================================================================"
echo "OPTION RFQ SMOKE PREFLIGHT — chain ${CHAIN_ID}"
echo "EXPECTED_REBATE=${EXPECTED_REBATE}  (asset=mUSDC)"
echo "================================================================"
echo ""
echo "Routing:"
echo "  feeRecipient          = ${FM_FEE_RECIPIENT}"
echo "  rebateFundingAccount  = ${FM_REBATE_FUNDING_ACCOUNT}"
echo "  protocolFeeVault      = ${FM_PROTOCOL_FEE_VAULT}"
echo ""
echo "Budgets / reserves:"
echo "  FM-V2.rebateBudget(mUSDC) = ${FM_REBATE_BUDGET_MUSDC}"
echo "  PFV.feeBalance(mUSDC)     = ${V_FEE_BALANCE}"
echo "  PFV.rebateReserve(mUSDC)  = ${V_REBATE_RESERVE}"
echo "  CV.balances(vault,mUSDC)  = ${CV_BAL_VAULT_MUSDC}"
echo "  drift                     = ${DRIFT}"
echo "  rebatesPaused             = ${V_REBATES_PAUSED}"
echo ""
echo "OME nonces (Tier2 taker / Tier4 maker):"
echo "  current  Tier2 ${TIER2_ADDRESS} = ${NONCE_TIER2}"
echo "  current  Tier4 ${TIER4_ADDRESS} = ${NONCE_TIER4}"
echo "  recommended OPTION_BUYER_NONCE  = ${NEXT_TIER2}"
echo "  recommended OPTION_SELLER_NONCE = ${NEXT_TIER4}"
if [[ -n "${INTENT_ID}" ]]; then
  echo "  recommended intentId            = ${INTENT_ID}  (operator-supplied)"
else
  echo "  recommended intentId            = (not supplied — set INTENT_ID env to echo it back)"
fi
echo ""

if [[ "${PASS}" == "true" ]]; then
  echo "RESULT: PASS — smoke is SAFE under EXPECTED_REBATE=${EXPECTED_REBATE}"
  echo "        but you MUST still confirm intentId uniqueness and reserve top-up policy."
  exit 0
fi

echo "RESULT: FAIL — smoke is UNSAFE. Do NOT broadcast SmokeOptionRfqV2FeesExecute."
for f in "${FAILS[@]}"; do
  echo "  ✖ ${f}"
done
echo ""
echo "See: deopt-v2-sol/docs/OPERATOR_RUNBOOK_PROTOCOL_FEE_VAULT_V2G_R5.md"
exit 2
