#!/bin/bash
# pharos-flashloan-detector — bash + cast (Foundry) port.
#
# Inspects a single Pharos transaction and reports whether it shows
# flash-loan-attack fingerprints. The output is a 0-100 risk score
# and a verdict of NONE / LOW / MEDIUM / HIGH / CRITICAL.
#
# The skill reads the tx receipt, the tx input selector, and the
# log count via `cast`. It then matches the selector against a
# short list of known flash-loan-provider and price-oracle function
# selectors, and scores the result.
#
# Usage:
#   bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet] [--json]
#   bash scripts/detect.sh demo
#   bash scripts/detect.sh --help

set -euo pipefail

# -------- Foundry required (after arg parsing so --help works offline) --------
FOUNDRY_CONFIG_NONE_DONE=0
ensure_cast() {
  if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found. Install Foundry:" >&2
    echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
    exit 1
  fi
}

# -------- load network config from assets/networks.json --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"
[ ! -f "$NET_JSON" ] && { echo "Error: $NET_JSON not found"; exit 1; }

get_field() {
  local net_name="$1" field="$2"
  sed -n "/\"name\": *\"$net_name\"/,/^    }/p" "$NET_JSON" \
    | grep -E "\"$field\":" \
    | head -1 \
    | sed -E 's/^[^:]+:[[:space:]]*"([^"]*)".*/\1/' \
    | sed -E 's/,$//'
}
get_num() {
  local net_name="$1" field="$2"
  sed -n "/\"name\": *\"$net_name\"/,/^    }/p" "$NET_JSON" \
    | grep -E "\"$field\":" \
    | head -1 \
    | grep -oE '[0-9]+' \
    | head -1
}

# -------- known selectors --------
FLASHLOAN_SELECTORS=(
  "0xab9c4b5d|Aave V3 flashLoan"
  "0x5cffe9ea|Aave V2 flashLoan"
  "0x42b0bf78|Balancer flashLoan"
  "0x130d5b69|dYdX withdraw"
  "0x4f2be91d|Euler flashLoan"
  "0x5d5c1d77|UniswapV3 flashLoan"
)
ORACLE_SELECTORS=(
  "0x59e02ddd|Chainlink getReservePrice"
  "0xb9e8c2a4|Chainlink latestRoundData"
  "0x2a4e8998|UniswapV3 observe"
  "0xfa461e33|UniswapV2 getReserves"
  "0x0902f1ac|UniswapV2 getAmountOut"
)

# -------- arg parsing --------
TX_HASH=""
CHAIN="mainnet"
JSON_OUT=0
DEMO=0
PRINT_HELP=0
PREV=""

for arg in "$@"; do
  case "$PREV" in
    --chain) CHAIN="$arg"; PREV=""; continue ;;
  esac
  case "$arg" in
    -h|--help) PRINT_HELP=1 ;;
    --chain)   PREV="--chain" ;;
    --json)    JSON_OUT=1 ;;
    demo)      DEMO=1 ;;
    -*)        echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)         [ -z "$TX_HASH" ] && TX_HASH="$arg" ;;
  esac
done
[ -n "$PREV" ] && { echo "Error: $PREV requires a value" >&2; exit 1; }

# -------- early-exits (no cast needed) --------
if [ "$PRINT_HELP" = "1" ]; then
  cat <<'USAGE'
pharos-flashloan-detector — analyze a Pharos tx for flash-loan-attack fingerprints.

Usage:
  bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet] [--json]
  bash scripts/detect.sh demo
  bash scripts/detect.sh --help

Examples:
  bash scripts/detect.sh 0xabc... --chain mainnet
  bash scripts/detect.sh demo
  bash scripts/detect.sh 0xabc... --json

Prerequisites:
  - Foundry (cast): curl -L https://foundry.paradigm.xyz | bash && foundryup
  - jq: optional, only for --json pretty-printing
USAGE
  exit 0
fi

# Demo mode: pre-load a real public mainnet tx (the cast check still runs at the
# analyze step). Or do we skip cast for demo? Keep as-is for now.
if [ "$DEMO" = "1" ]; then
  TX_HASH="0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7"
  echo "ℹ️  Running demo against a real public mainnet tx as a sample."
  echo ""
fi

if [ -z "$TX_HASH" ]; then
  echo "Usage: bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet] [--json]"
  echo "       bash scripts/detect.sh demo"
  echo "       bash scripts/detect.sh --help"
  exit 1
fi

# -------- resolve chain (after arg parsing, before cast) --------
case "$CHAIN" in
  mainnet) RPC_URL=$(get_field "mainnet" "rpcUrl"); EXPLORER_URL=$(get_field "mainnet" "explorerUrl"); CHAIN_ID=$(get_num "mainnet" "chainId"); NATIVE=$(get_field "mainnet" "nativeToken") ;;
  testnet) RPC_URL=$(get_field "atlantic-testnet" "rpcUrl"); EXPLORER_URL=$(get_field "atlantic-testnet" "explorerUrl"); CHAIN_ID=$(get_num "atlantic-testnet" "chainId"); NATIVE=$(get_field "atlantic-testnet" "nativeToken") ;;
  *) echo "Unknown chain: $CHAIN (use 'mainnet' or 'testnet')" >&2; exit 1 ;;
esac

# -------- cast is required from here on --------
ensure_cast

# -------- status extraction (3 branches, never claim success/failed on empty) --------
extract_status() {
  local h="$1"
  local s
  s=$(cast receipt --rpc-url "$RPC_URL" "$h" status 2>/dev/null | tr -d '[:space:]' || true)
  if [ -z "$s" ]; then
    echo "UNKNOWN"
    return
  fi
  s="${s,,}"
  if [[ "$s" == 0x1* ]] || [ "$s" = "1" ]; then
    echo "SUCCESS"
  elif [[ "$s" == 0x0* ]] || [ "$s" = "0" ]; then
    echo "FAILED"
  else
    echo "UNKNOWN"
  fi
}

# -------- main analysis --------
analyze_tx() {
  local hash="$1"

  # Fetch receipt fields
  local status_raw gas_used to from block
  status_raw=$(cast receipt --rpc-url "$RPC_URL" "$hash" status 2>/dev/null | tr -d '[:space:]' || true)
  gas_used=$(cast receipt --rpc-url "$RPC_URL" "$hash" gasUsed 2>/dev/null | tr -d '[:space:]' || true)
  to=$(cast receipt --rpc-url "$RPC_URL" "$hash" to 2>/dev/null | tr -d '[:space:]' || true)
  from=$(cast receipt --rpc-url "$RPC_URL" "$hash" from 2>/dev/null | tr -d '[:space:]' || true)
  block=$(cast receipt --rpc-url "$RPC_URL" "$hash" blockNumber 2>/dev/null | tr -d '[:space:]' || true)

  # If status came back empty, the tx probably doesn't exist on this chain
  if [ -z "$status_raw" ] && [ -z "$gas_used" ]; then
    if [ "$JSON_OUT" = "1" ]; then
      jq -n --arg chain "$CHAIN" --arg hash "$hash" \
        '{type:"flashloan_analysis", chain:$chain, tx:$hash, found:false, error:"tx not found on chain='"$CHAIN"' (public RPC may be missing this hash)"}'
    else
      echo "  ❌ tx not found on chain=$CHAIN"
      echo ""
      echo "  Possible causes:"
      echo "    - the hash is wrong"
      echo "    - the tx is on a different chain (try --chain testnet)"
      echo "    - the Pharos public RPC is rate-limited or down"
      echo "    - the tx is too old for this RPC node to remember"
    fi
    return 1
  fi

  local block_dec gas_dec
  block_dec=$(cast --to-dec "$block" 2>/dev/null | tr -d '[:space:]' || echo "?")
  gas_dec=$(cast --to-dec "$gas_used" 2>/dev/null | tr -d '[:space:]' || echo "?")

  local status_norm
  status_norm=$(extract_status "$hash")

  # Get the tx input to extract the function selector
  local input selector
  input=$(cast tx --rpc-url "$RPC_URL" "$hash" input 2>/dev/null | tr -d '[:space:]' || true)
  if [ -z "$input" ] || [ "$input" = "0x" ]; then
    input="0x"
    selector="0x00000000"
  else
    selector="${input:0:10}"
  fi

  # Count logs (proxy for inner-tx burst)
  local log_count
  log_count=$(cast receipt --rpc-url "$RPC_URL" "$hash" --json 2>/dev/null \
    | grep -oE '"logIndex":"0x[0-9a-fA-F]+"' | wc -l | tr -d ' ' || echo "0")
  if [ -z "$log_count" ]; then log_count=0; fi

  # Match the selector against known flash-loan and oracle providers
  local flashloan_match="" oracle_match=""
  for entry in "${FLASHLOAN_SELECTORS[@]}"; do
    local sel="${entry%%|*}"
    local name="${entry#*|}"
    if [ "$selector" = "$sel" ]; then
      flashloan_match="$name"
    fi
  done
  for entry in "${ORACLE_SELECTORS[@]}"; do
    local sel="${entry%%|*}"
    local name="${entry#*|}"
    if [ "$selector" = "$sel" ]; then
      oracle_match="$name"
    fi
  done

  # Heuristic scoring (0-100, capped)
  local score=0
  [ -n "$flashloan_match" ] && score=$((score + 60))
  [ -n "$oracle_match" ]    && score=$((score + 25))
  if [ "$log_count" -ge 5 ] 2>/dev/null; then
    score=$((score + 15))
  fi
  # Failed tx gets a small extra flag, not a major penalty
  if [ "$status_norm" = "FAILED" ]; then
    score=$((score + 5))
  fi
  if [ "$score" -gt 100 ]; then score=100; fi

  # Verdict
  local verdict
  if   [ "$score" -ge 80 ]; then verdict="CRITICAL"
  elif [ "$score" -ge 60 ]; then verdict="HIGH"
  elif [ "$score" -ge 40 ]; then verdict="MEDIUM"
  elif [ "$score" -ge 20 ]; then verdict="LOW"
  else                            verdict="NONE"
  fi

  if [ "$JSON_OUT" = "1" ]; then
    jq -n \
      --arg chain "$CHAIN" \
      --arg hash "$hash" \
      --arg block "$block_dec" \
      --arg from "$from" \
      --arg to "$to" \
      --arg status "$status_norm" \
      --arg gas "$gas_dec" \
      --arg selector "$selector" \
      --argjson log_count "$log_count" \
      --arg flashloan "${flashloan_match:-null}" \
      --arg oracle "${oracle_match:-null}" \
      --argjson score "$score" \
      --arg verdict "$verdict" \
      --arg explorer "${EXPLORER_URL}/tx/${hash}" \
      '{
        type: "flashloan_analysis",
        chain: $chain,
        tx: $hash,
        block: $block,
        from: $from,
        to: $to,
        status: $status,
        gas_used: $gas,
        selector: $selector,
        log_count: $log_count,
        flashloan_provider: $flashloan,
        oracle_used: $oracle,
        risk_score: $score,
        risk_level: $verdict,
        explorer: $explorer
      }'
  else
    echo "========================================================================"
    echo "  Pharos Flashloan Detector — single-tx analysis"
    echo "========================================================================"
    echo "  chain:    $CHAIN"
    echo "  tx:       $hash"
    echo "  rpc:      $RPC_URL"
    echo "  block:    $block_dec"
    echo "  from:     $from"
    echo "  to:       $to"
    echo "  status:   $status_norm (raw=$status_raw)"
    echo "  gas used: $gas_dec"
    echo "  selector: $selector"
    echo "  log count:$log_count"
    echo "  explorer: ${EXPLORER_URL}/tx/$hash"
    echo ""
    echo "  features:"
    if [ -n "$flashloan_match" ]; then
      echo "    flashloan_call: $flashloan_match"
    fi
    if [ -n "$oracle_match" ]; then
      echo "    oracle_call:    $oracle_match"
    fi
    if [ -z "$flashloan_match" ] && [ -z "$oracle_match" ]; then
      echo "    (no known flash-loan or oracle selector on the outer call)"
    fi
    echo ""
    echo "  >>> SCORE:    $score/100  <<<"
    echo "  >>> VERDICT:  $verdict  <<<"
    echo ""
    echo "  Thresholds: NONE 0-19, LOW 20-39, MEDIUM 40-59, HIGH 60-79, CRITICAL 80-100"
    echo "========================================================================"
  fi
}

analyze_tx "$TX_HASH"
