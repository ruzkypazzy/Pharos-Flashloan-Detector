#!/bin/bash
# Smoke test for pharos-flashloan-detector (Foundry/bash port, v2.0.0).
# Verifies the CLI parses, help text works offline, and error paths are clear.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$SKILL_DIR/scripts/detect.sh"

PASS=0
FAIL=0

# run <name> <expected-substring> -- runs script, checks substring appears in output
run() {
  local name="$1"
  local expected="$2"
  shift 2
  local out
  out=$(bash "$SCRIPT" "$@" 2>&1 || true)
  if echo "$out" | grep -q "$expected"; then
    echo "  OK: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "       expected substring: $expected"
    echo "       actual: $out" | head -3
    FAIL=$((FAIL + 1))
  fi
}

echo "Test 1: --help works (no cast required)"
run "help text present" "Usage:" --help

echo "Test 2: no args shows usage"
run "no-args shows usage" "Usage:"

echo "Test 3: unknown flag rejected"
run "unknown flag rejected" "Unknown flag" --foo

echo "Test 4: bad chain rejected"
run "bad chain rejected" "Unknown chain" 0xabc --chain bogus

echo "Test 5: cast-missing error is clear (only when cast is not installed)"
if ! command -v cast >/dev/null 2>&1; then
  run "cast-missing error clear" "cast.*not found" 0xabc --chain mainnet
else
  echo "  SKIP: cast is installed"
fi

echo "Test 6: live cast read (only when cast is installed)"
if command -v cast >/dev/null 2>&1; then
  run "live cast read produced verdict" "VERDICT: (NONE|LOW|MEDIUM|HIGH|CRITICAL)" \
    0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7 --chain mainnet
else
  echo "  SKIP: cast is not installed"
fi

echo "Test 7: --json output (only when cast is installed AND jq is installed)"
if command -v cast >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  if bash "$SCRIPT" 0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7 --json 2>&1 | jq . >/dev/null; then
    echo "  OK: json output valid"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: json output invalid"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP: cast or jq not installed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
