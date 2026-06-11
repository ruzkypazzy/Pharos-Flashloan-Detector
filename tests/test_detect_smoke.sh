#!/bin/bash
# Smoke test for the Foundry/bash port of pharos-flashloan-detector.
set -e
SCRIPT="scripts/detect.sh"

# Test 1: help flag
bash "$SCRIPT" --help >/dev/null

# Test 2: no args
if bash "$SCRIPT" 2>&1 | grep -q "Usage"; then
  echo "OK: no-args shows usage"
else
  echo "FAIL: no-args did not show usage"
  exit 1
fi

# Test 3: unknown flag
if bash "$SCRIPT" --foo 2>&1 | grep -q "Unknown flag"; then
  echo "OK: unknown flag rejected"
else
  echo "FAIL: unknown flag not rejected"
  exit 1
fi

# Test 4: cast missing (if cast not installed, should fail with the right message)
if ! command -v cast >/dev/null 2>&1; then
  if bash "$SCRIPT" 0xabc --chain mainnet 2>&1 | grep -q "cast.*not found"; then
    echo "OK: cast-missing error is clear"
  else
    echo "FAIL: cast-missing error unclear"
    exit 1
  fi
else
  # Cast installed: try a real mainnet tx
  if bash "$SCRIPT" 0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7 --chain mainnet 2>&1 | grep -qE "VERDICT: (NONE|LOW|MEDIUM|HIGH|CRITICAL)"; then
    echo "OK: live cast read worked"
  else
    echo "FAIL: live cast read did not produce a verdict"
    exit 1
  fi
fi

echo ""
echo "All smoke tests passed."
