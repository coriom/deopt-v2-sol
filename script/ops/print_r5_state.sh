#!/usr/bin/env bash
# V2G-OPS-HARDEN-P0 — Read-only ProtocolFeeVault + FeesManagerV2 state snapshot.
#
# Prints the canonical V2G-R5 addresses and the live R5 invariant fields
# (vault gauges, FM-V2 routing, CV balance, OME nonces) on the configured
# Base Sepolia RPC. The script never broadcasts, never signs, and never
# reads any private key material.
#
# Hard constraints:
#   - read-only (cast call only)
#   - no cast send
#   - no private key
#   - no admin token
#   - safe on testnet only by convention; refuses CHAIN_ID != 84532 unless
#     OPERATOR_OVERRIDE_CHAIN_ID=true
#
# Exit codes:
#   0  success, drift == 0 AND PFV wiring is complete
#   2  PFV wiring is NOT complete (feeRecipient / rebateFundingAccount /
#      protocolFeeVault not set to the vault)
#   3  drift != 0 (CV.balances(vault, mUSDC) - feeBalance - rebateReserve)
#   4  missing dependency (cast / RPC_URL) or unsupported chain id
#
# Usage:
#   RPC_URL="https://sepolia.base.org" ./print_r5_state.sh
#   RPC_URL=... TIER2_ADDRESS=0x... TIER4_ADDRESS=0x... ./print_r5_state.sh

set -euo pipefail

if ! command -v cast >/dev/null 2>&1; then
  echo "ERROR: \`cast\` (foundry) not found in PATH" >&2
  exit 4
fi
if ! command -v timeout >/dev/null 2>&1; then
  echo "ERROR: \`timeout\` (coreutils) not found in PATH" >&2
  exit 4
fi

# Prefer explicit RPC_URL; otherwise extract from .env.base-sepolia (we do
# not source it — the env file also carries DEPLOYER_PRIVATE_KEY).
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

# --- Canonical V2G-R5 addresses (Base Sepolia 84532) --------------------------
NEW_FM_V2="${NEW_FM_V2:-0xF6626177f3B85cc3239667Cc53C04A8007652944}"
PROTOCOL_FEE_VAULT="${PROTOCOL_FEE_VAULT:-0x7C0a3B6feBd5BFFc164f37738299AeB453181886}"
COLLATERAL_VAULT="${COLLATERAL_VAULT:-0x00340C360353a5AB784c5Bc5c44322A6AF0625D3}"
NEW_ME="${NEW_ME:-0x506cD65a63C53c66ab572B9f9dd819B7BfE00D30}"
NEW_OME="${NEW_OME:-0x5a5EBF9A9CCd7c012518569DE8283982982670f6}"
M_USDC="${M_USDC:-0x6eAe407f5640B006faC9965182e238582A3B412E}"
TIMELOCK="${TIMELOCK:-0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588}"
DEPLOYER="${DEPLOYER:-0xc35F7A8A103A9A4464adfaa76B9B514093D23C27}"

# Smoke addresses (last broadcast). Override if you rotate keys.
TIER2_ADDRESS="${TIER2_ADDRESS:-0x77ca9dd6ccce2d692fb23877a2db7178807b0020}"   # taker
TIER4_ADDRESS="${TIER4_ADDRESS:-0x290bd12c93e467bf51c51f5273d35bddb19e9274}"  # maker

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
addr() {
  # cast call with `...(address)` signature already returns a checksummed
  # 20-byte hex string. Strip leading/trailing whitespace defensively.
  printf '%s' "$1" | tr -d '[:space:]'
}
uint() {
  # cast call with `...(uint256)` signature returns e.g. "999947 [9.999e5]".
  # Strip the scientific-notation suffix and any whitespace.
  printf '%s' "$1" | awk '{print $1}'
}

# --- Chain id guard -----------------------------------------------------------
log "probing chain id (timeout ${CAST_TIMEOUT}s)"
CHAIN_ID="$(tchainid)"
if [[ "${CHAIN_ID}" != "84532" && "${OPERATOR_OVERRIDE_CHAIN_ID:-false}" != "true" ]]; then
  echo "ERROR: connected to chain ${CHAIN_ID}, expected 84532 (Base Sepolia)" >&2
  echo "       set OPERATOR_OVERRIDE_CHAIN_ID=true to bypass (NEVER do this on mainnet)" >&2
  exit 4
fi

# --- FM-V2 routing reads ------------------------------------------------------
log "reading FM-V2.feeRecipient"
FM_FEE_RECIPIENT="$(addr "$(tcall "${NEW_FM_V2}" 'feeRecipient()(address)')")"
log "reading FM-V2.rebateFundingAccount"
FM_REBATE_FUNDING_ACCOUNT="$(addr "$(tcall "${NEW_FM_V2}" 'rebateFundingAccount()(address)')")"
log "reading FM-V2.protocolFeeVault"
FM_PROTOCOL_FEE_VAULT="$(addr "$(tcall "${NEW_FM_V2}" 'protocolFeeVault()(address)')")"
log "reading FM-V2.rebateBudget(mUSDC)"
FM_REBATE_BUDGET_MUSDC="$(uint "$(tcall "${NEW_FM_V2}" 'rebateBudget(address)(uint256)' "${M_USDC}")")"

# --- Vault gauges -------------------------------------------------------------
log "reading vault.feeBalance(mUSDC)"
V_FEE_BALANCE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'feeBalance(address)(uint256)' "${M_USDC}")")"
log "reading vault.rebateReserve(mUSDC)"
V_REBATE_RESERVE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'rebateReserve(address)(uint256)' "${M_USDC}")")"
log "reading vault.grossFeesCollected(mUSDC)"
V_GROSS_FEES="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'grossFeesCollected(address)(uint256)' "${M_USDC}")")"
log "reading vault.rebatesPaid(mUSDC)"
V_REBATES_PAID="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'rebatesPaid(address)(uint256)' "${M_USDC}")")"
log "reading vault.netRevenue(mUSDC)"
V_NET_REVENUE="$(uint "$(tcall "${PROTOCOL_FEE_VAULT}" 'netRevenue(address)(uint256)' "${M_USDC}")")"
log "reading vault.rebatesPaused"
V_REBATES_PAUSED="$(tcall "${PROTOCOL_FEE_VAULT}" 'rebatesPaused()(bool)')"
log "reading vault.owner"
V_OWNER="$(addr "$(tcall "${PROTOCOL_FEE_VAULT}" 'owner()(address)')")"
log "reading vault.guardian"
V_GUARDIAN="$(addr "$(tcall "${PROTOCOL_FEE_VAULT}" 'guardian()(address)')")"

# --- Collateral vault balance (vault's internal CV account) -------------------
log "reading CV.balances(vault, mUSDC)"
CV_BAL_VAULT_MUSDC="$(uint "$(tcall "${COLLATERAL_VAULT}" 'balances(address,address)(uint256)' "${PROTOCOL_FEE_VAULT}" "${M_USDC}")")"

# --- OME nonces for smoke accounts --------------------------------------------
log "reading OME.nonces(Tier2)"
NONCE_TIER2="$(uint "$(tcall "${NEW_OME}" 'nonces(address)(uint256)' "${TIER2_ADDRESS}")")"
log "reading OME.nonces(Tier4)"
NONCE_TIER4="$(uint "$(tcall "${NEW_OME}" 'nonces(address)(uint256)' "${TIER4_ADDRESS}")")"

# --- Drift ---------------------------------------------------------------------
DRIFT=$(( CV_BAL_VAULT_MUSDC - V_FEE_BALANCE - V_REBATE_RESERVE ))

# --- Output --------------------------------------------------------------------
echo "================================================================"
echo "V2G-R5 STATE SNAPSHOT — chain ${CHAIN_ID}"
echo "================================================================"
echo ""
echo "Canonical addresses:"
echo "  NEW_FM_V2            = ${NEW_FM_V2}"
echo "  PROTOCOL_FEE_VAULT   = ${PROTOCOL_FEE_VAULT}"
echo "  COLLATERAL_VAULT     = ${COLLATERAL_VAULT}"
echo "  NEW_ME               = ${NEW_ME}"
echo "  NEW_OME              = ${NEW_OME}"
echo "  mUSDC                = ${M_USDC}"
echo "  TIMELOCK             = ${TIMELOCK}"
echo "  DEPLOYER             = ${DEPLOYER}"
echo ""
echo "FM-V2 routing:"
echo "  feeRecipient          = ${FM_FEE_RECIPIENT}"
echo "  rebateFundingAccount  = ${FM_REBATE_FUNDING_ACCOUNT}"
echo "  protocolFeeVault      = ${FM_PROTOCOL_FEE_VAULT}"
echo "  rebateBudget(mUSDC)   = ${FM_REBATE_BUDGET_MUSDC}"
echo ""
echo "ProtocolFeeVault gauges (asset = mUSDC):"
echo "  feeBalance            = ${V_FEE_BALANCE}"
echo "  rebateReserve         = ${V_REBATE_RESERVE}"
echo "  grossFeesCollected    = ${V_GROSS_FEES}"
echo "  rebatesPaid           = ${V_REBATES_PAID}"
echo "  netRevenue            = ${V_NET_REVENUE}"
echo "  rebatesPaused         = ${V_REBATES_PAUSED}"
echo "  owner                 = ${V_OWNER}"
echo "  guardian              = ${V_GUARDIAN}"
echo ""
echo "Collateral vault:"
echo "  CV.balances(vault, mUSDC) = ${CV_BAL_VAULT_MUSDC}"
echo ""
echo "OME nonces:"
echo "  Tier2 ${TIER2_ADDRESS} = ${NONCE_TIER2}"
echo "  Tier4 ${TIER4_ADDRESS} = ${NONCE_TIER4}"
echo ""
echo "Invariant — V2G-R1 inv. 2:"
echo "  drift = CV.balances(vault,mUSDC) - feeBalance - rebateReserve"
echo "        = ${CV_BAL_VAULT_MUSDC} - ${V_FEE_BALANCE} - ${V_REBATE_RESERVE}"
echo "        = ${DRIFT}"
echo ""

# --- Gates --------------------------------------------------------------------
WIRING_OK=true
LC_PFV="${PROTOCOL_FEE_VAULT,,}"
if [[ "${FM_FEE_RECIPIENT,,}" != "${LC_PFV}" ]]; then
  WIRING_OK=false
  echo "WIRING FAIL: feeRecipient ${FM_FEE_RECIPIENT} != PROTOCOL_FEE_VAULT ${PROTOCOL_FEE_VAULT}"
fi
if [[ "${FM_REBATE_FUNDING_ACCOUNT,,}" != "${LC_PFV}" ]]; then
  WIRING_OK=false
  echo "WIRING FAIL: rebateFundingAccount ${FM_REBATE_FUNDING_ACCOUNT} != PROTOCOL_FEE_VAULT ${PROTOCOL_FEE_VAULT}"
fi
if [[ "${FM_PROTOCOL_FEE_VAULT,,}" != "${LC_PFV}" ]]; then
  WIRING_OK=false
  echo "WIRING FAIL: protocolFeeVault ${FM_PROTOCOL_FEE_VAULT} != PROTOCOL_FEE_VAULT ${PROTOCOL_FEE_VAULT}"
fi

if [[ "${WIRING_OK}" != "true" ]]; then
  echo ""
  echo "RESULT: WIRING_INCOMPLETE"
  exit 2
fi

if [[ "${DRIFT}" != "0" ]]; then
  echo "DRIFT FAIL: invariant 2 violated (drift=${DRIFT})"
  echo ""
  echo "RESULT: DRIFT_NONZERO"
  exit 3
fi

echo "RESULT: OK (wiring complete, drift=0)"
exit 0
