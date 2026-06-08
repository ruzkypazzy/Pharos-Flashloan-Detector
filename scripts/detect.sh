#!/bin/bash
# pharos-flashloan-detector — bash wrapper for the Python detector.
# Usage:
#   bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet] [--json]
#   bash scripts/detect.sh demo

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."

CMD="${1:-}"
shift || true

if [ "$CMD" = "demo" ]; then
  python3 detector.py
elif [ -n "$CMD" ]; then
  python3 detector.py --tx "$CMD" "$@"
else
  echo "Usage: bash scripts/detect.sh <TX_HASH> [--chain mainnet|testnet]"
  echo "       bash scripts/detect.sh demo"
  exit 1
fi
