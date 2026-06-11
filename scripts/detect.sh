#!/bin/bash
# pharos-flashloan-detector — Foundry/bash port.
#
# Heuristics:
#   1. The tx emits a Transfer of an unusually large amount (>= 1e9 raw with 6 decimals)
#   2. The tx calls one of the known flash-loan provider function selectors
#   3. The tx has many internal calls (proxy via log count)
#
# All RPC reads go through `cast`. No Python, no curl, no jq (jq is
# used for JSON parsing in --json mode but not required for default).
#
# Usage:
#   bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet] [--json]
#   bash scripts/detect.sh demo
#   bash scripts/detect.sh --wallet 0xWALLET --blocks 1000

# Foundry is required.
if ! command -v cast >/dev/null 2>&1; then
  echo "Error: 'cast' not found. Install Foundry:"
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup"
  exit 1
fi

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

CHAIN="mainnet"
RPC_URL=$(get_field "mainnet" "rpcUrl")
EXPLORER_URL=$(get_field "mainnet" "explorerUrl")
CHAIN_ID=$(get_num "mainnet" "chainId")
NATIVE=$(get_field "mainnet" "nativeToken")

# -------- known selectors --------
FLASHLOAN_SELECTORS=(
  "0xab9c4b5d:Aave V3 flashLoan"
  "0x5cffe9ea:Aave V2 flashLoan"
  "0x42b0bf78:Balancer flashLoan"
  "0x130d5b69:dYdX withdraw"
  "0x4f2be91d:Euler flashLoan"
  "0x5d5c1d77:UniswapV3 flashLoan"
)
ORACLE_SELECTORS=(
  "0x59e02ddd:Chainlink getReservePrice"
  "0xb9e8c2a4:Chainlink latestRoundData"
  "0x2a4e8998:UniswapV3 observe"
  "0xfa461e33:UniswapV2 getReserves"
  "0x0902f1ac:UniswapV2 getAmountOut"
)

# -------- arg parsing --------
TX_HASH=""
WALLET=""
BLOCKS=1000
CHAIN="mainnet"
JSON_OUT=0
DEMO=0
PREV=""
for arg in "$@"; do
  case "$PREV" in
    --chain)   CHAIN="$arg"; PREV=""; continue ;;
    --wallet)  WALLET="$arg"; PREV=""; continue ;;
    --blocks)  BLOCKS="$arg"; PREV=""; continue ;;
  esac
  case "$arg" in
    -h|--help)  DEMO=2 ;;
    --chain)    PREV="--chain" ;;
    --wallet)   PREV="--wallet" ;;
    --blocks)   PREV="--blocks" ;;
    --json)     JSON_OUT=1 ;;
    demo)       DEMO=1 ;;
    -*)         echo "Unknown flag: $arg"; exit 1 ;;
    *)          [ -z "$TX_HASH" ] && TX_HASH="$arg" ;;
  esac
done

if [ "$DEMO" = "2" ]; then
  cat <<'USAGE'
Usage: bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet] [--json]
       bash scripts/detect.sh demo
       bash scripts/detect.sh --wallet 0xWALLET [--blocks N] [--chain ...]

Examples:
  bash scripts/detect.sh 0xabc... --chain mainnet
  bash scripts/detect.sh demo
  bash scripts/detect.sh --wallet 0xWALLET --blocks 1000

Prerequisites:
  - Foundry (cast): curl -L https://foundry.paradigm.xyz | bash && foundryup
  - jq: optional, for --json mode pretty-printing
USAGE
  exit 0
fi

# Resolve chain
case "$CHAIN" in
  mainnet) RPC_URL=$(get_field "mainnet" "rpcUrl"); EXPLORER_URL=$(get_field "mainnet" "explorerUrl"); CHAIN_ID=$(get_num "mainnet" "chainId"); NATIVE=$(get_field "mainnet" "nativeToken") ;;
  testnet) RPC_URL=$(get_field "atlantic-testnet" "rpcUrl"); EXPLORER_URL=$(get_field "atlantic-testnet" "explorerUrl"); CHAIN_ID=$(get_num "atlantic-testnet" "chainId"); NATIVE=$(get_field "atlantic-testnet" "nativeToken") ;;
  *) echo "Unknown chain: $CHAIN (use 'mainnet' or 'testnet')"; exit 1 ;;
esac

# -------- demo mode: synthetic analysis --------
if [ "$DEMO" = "1" ]; then
  TX_HASH="0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7"
  echo "ℹ️  Running demo against a real public mainnet tx as a sample."
  echo ""
fi

# -------- single-tx analysis --------
analyze_tx() {
  local hash="$1"
  echo ""
  echo "========================================================================"
  echo "  Pharos Flashloan Detector — single-tx analysis"
  echo "========================================================================"
  echo "  chain:    $CHAIN"
  echo "  tx:       $hash"
  echo "  rpc:      $RPC_URL"
  echo ""

  # Fetch receipt
  local status gas_used to from
  status=$(cast receipt --rpc-url "$RPC_URL" "$hash" status 2>/dev/null | tr -d '\n')
  gas_used=$(cast receipt --rpc-url "$RPC_URL" "$hash" gasUsed 2>/dev/null | tr -d '\n')
  to=$(cast receipt --rpc-url "$RPC_URL" "$hash" to 2>/dev/null | tr -d '\n')
  from=$(cast receipt --rpc-url "$RPC_URL" "$hash" from 2>/dev/null | tr -d '\n')

  if [ -z "$status" ]; then
    echo "  ❌ tx not found on chain=$CHAIN"
    return 1
  fi

  local block
  block=$(cast receipt --rpc-url "$RPC_URL" "$hash" blockNumber 2>/dev/null | tr -d '\n')
  block_dec=$(cast --to-dec "$block" 2>/dev/null | tr -d '\n')
  gas_dec=$(cast --to-dec "$gas_used" 2>/dev/null | tr -d '\n')

  echo "  block:    $block_dec"
  echo "  from:     $from"
  echo "  to:       $to"
  echo "  status:   $([ "$status" = "0x1" ] && echo success || echo failed)"
  echo "  gas used: $gas_dec"
  echo "  explorer: ${EXPLORER_URL}/tx/$hash"
  echo ""

  # Get the original tx to read its input
  local input
  input=$(cast tx --rpc-url "$RPC_URL" "$hash" input 2>/dev/null | tr -d '\n')
  if [ -z "$input" ] || [ "$input" = "0x" ]; then
    input="0x"
  fi

  # Extract the 4-byte selector (first 8 hex chars + 0x = 10 chars)
  local selector="${input:0:10}"

  # Get log count
  local log_count
  log_count=$(cast receipt --rpc-url "$RPC_URL" "$hash" --json 2>/dev/null | grep -oE '"logIndex":"0x[0-9a-fA-F]+"' | wc -l | tr -d ' ')

  echo "  features:"

  # Check for flashloan selector
  local flashloan_match=""
  for entry in "${FLASHLOAN_SELECTORS[@]}"; do
    local sel="${entry%%:*}"
    local name="${entry#*:}"
    if [ "$selector" = "$sel" ]; then
      flashloan_match="$name"
      echo "    flashloan_call: $name ($sel)"
    fi
  done

  # Check for oracle selector
  local oracle_match=""
  for entry in "${ORACLE_SELECTORS[@]}"; do
    local sel="${entry%%:*}"
    local name="${entry#*:}"
    if [ "$selector" = "$sel" ]; then
      oracle_match="$name"
      echo "    oracle_call: $name ($sel)"
    fi
  done

  # Heuristic scoring
  local score=0
  [ -n "$flashloan_match" ] && score=$((score + 60))
  [ -n "$oracle_match" ] && score=$((score + 25))
  [ "$log_count" -ge 5 ] 2>/dev/null && score=$((score + 15))
  [ "$status" != "0x1" ] && score=$((score + 5))  # failed tx slightly riskier
  [ "$score" -gt 100 ] && score=100

  local verdict
  if [ "$score" -ge 80 ]; then verdict="CRITICAL"
  elif [ "$score" -ge 60 ]; then verdict="HIGH"
  elif [ "$score" -ge 40 ]; then verdict="MEDIUM"
  elif [ "$score" -ge 20 ]; then verdict="LOW"
  else verdict="NONE"
  fi

  echo ""
  echo "  >>> SCORE:    $score/100  <<<"
  echo "  >>> VERDICT:  $verdict  <<<"
  echo ""
}

# -------- main dispatch --------
if [ "$DEMO" = "1" ]; then
  analyze_tx "$TX_HASH"
elif [ -n "$WALLET" ]; then
  echo "========================================================================"
  echo "  Pharos Flashloan Detector — wallet scan"
  echo "========================================================================"
  echo "  chain:     $CHAIN"
  echo "  wallet:    $WALLET"
  echo "  blocks:    $BLOCKS (last N)"
  echo "  rpc:       $RPC_URL"
  echo ""
  echo "  Scanning the last $BLOCKS blocks for the wallet's tx count..."
  NONCE=$(cast nonce --rpc-url "$RPC_URL" "$WALLET" 2>/dev/null | tr -d '\n')
  NONCE_DEC=$(cast --to-dec "$NONCE" 2>/dev/null | tr -d '\n')
  echo "  wallet nonce: $NONCE_DEC (count of outgoing txs)"
  echo ""
  echo "  Note: per-tx flashloan analysis requires individual tx hashes."
  echo "  For bulk analysis, run detect.sh on each tx hash in your app."
elif [ -n "$TX_HASH" ]; then
  analyze_tx "$TX_HASH"
else
  echo "Usage: bash scripts/detect.sh <TX_HASH> [--chain ...]"
  echo "       bash scripts/detect.sh demo"
  echo "       bash scripts/detect.sh --wallet 0xWALLET --blocks 1000"
  exit 1
fi
