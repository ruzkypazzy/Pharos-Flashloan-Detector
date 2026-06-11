---
name: pharos-flashloan-detector
description: AI Agent skill for detecting flash loan attack patterns on Pharos blockchain. Use this skill whenever a Pharos agent needs to screen a wallet for flashloan activity before copy-trading, lending to, or subscribing to a "yield strategy" wallet. Triggers on phrases like "is this wallet safe", "check for flashloans", "detect exploit patterns", "pharos security check".
version: 2.0.0
author: ruzkypazzy
requires: read
bins: [bash, cast, jq]
network: pharos
tags: [security, flashloan, pharos, defi, attack-detection, exploit, foundry]
agents: [claude, codex, gemini, openclaw]
---

# Pharos Flashloan Detector

Detects and analyzes flash loan attack patterns on Pharos blockchain.

## Usage

```bash
TX_HASH=0x... forge script AnalyzeFlashloan.s.sol --rpc-url $PHAROS_RPC
TARGET_ADDR=0x... forge script AnalyzeFlashloan.s.sol --rpc-url $PHAROS_RPC
CONTRACT_ADDR=0x... forge script AnalyzeFlashloan.s.sol --rpc-url $PHAROS_RPC
```

## Detection Patterns

- Large Value Transfer (+30)
- Same Block Transactions (+25)
- Price Manipulation (+35)
- Reentrancy Pattern (+25)
- Unauthorized Access (+20)

## Risk Levels

- NONE / LOW / MEDIUM / HIGH / CRITICAL

## Configuration

```bash
export PHAROS_RPC=https://rpc.pharos.xyz
```

## Networks

- Mainnet: Chain ID 1672
- Testnet: Chain ID 688689

## Prerequisites

Foundry is **required** for this skill. All RPC reads go through `cast`:

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
cast --version   # should print 0.2.0 or later
```

`jq` is recommended for `--json` mode pretty-printing but not required.

The skill is **read-only** — no private key is required or accepted.

## Network Configuration

Network RPC URLs and chain IDs are sourced from
`assets/networks.json` (canonical Pharos Skill Engine schema). To
add a new network, append a new object to the `networks` array and
update `defaultNetwork` if needed.

## Capability Index

| User Need | Capability | Detailed Instructions |
|---|---|---|
| "Did this wallet use a flashloan?" | Per-tx flashloan pattern detection | Run `bash scripts/detect.sh 0xTX_HASH --chain mainnet`; the skill reads the tx receipt, scans logs for `Borrow` events from known providers, and checks for matching `Repay` events in the same atomic call |
| "Scan a wallet's history" | Bounded wallet scan | Run `python3 detector.py --wallet 0xWALLET --blocks 1000 --format markdown`; the skill walks the last N txs, classifies each, and emits a ranked Markdown/JSON report |
| "Is this a known flashloan provider?" | Match against selector table | Built-in selector table covers Aave V3, dYdX, Uniswap V3, Balancer; new providers can be added by appending to `FLASHLOAN_SELECTORS` in `detector.py` |
| "Get the report as JSON for an agent" | `--format json` | Output is structured JSON with `risk_level`, `risk_score`, `indicators[]`, and `verdict` — directly importable by an agent |
| "Avoid rate limits on the public RPC" | Bounded scan with binary search skip | The `--max-blocks` flag bounds the scan and uses binary-search-with-skip to stay within the public RPC's request rate |

## General Error Handling

| Error Scenario | CLI Error Signature | Handling |
|---|---|---|
| Tx hash not on the specified chain | `null` receipt from `eth_getTransactionReceipt` | Exit with "tx not found on chain=X; try `--chain <other>`" |
| RPC rate-limited (HTTP 429) | Backoff response from RPC | Built-in exponential backoff (0.4s, 0.8s, 1.6s, 3.2s) with 4 retry attempts; surface after exhaustion |
| Bad tx hash format | `analyze()` rejects malformed input | Python `analyze_rejects_bad_hash_format` test covers this; CLI prints a usage hint |
| `--wallet` not specified | `analyze()` rejects missing | CLI prints usage; no RPC call is made |
| No flashloans found (clean wallet) | `verdict: ✓ No flash-loan markers detected.` | Normal case — emit the "no markers" report, no error |

## Security Reminders

- **Private Key Protection** — the skill is read-only and never
  accepts a private key. Do not paste keys into chat.
- **Network Confirmation** — before any future write-skill
  integration, confirm the network with the user.
- **Wallet Privacy** — a wallet address is a public identifier; do
  not paste addresses that the user has not explicitly shared.

## Write Operation Pre-checks

This skill is **read-only** and never submits a transaction, so the
full 4-step write pre-check is not applicable. If a future version
adds a "blocklist at the RPC level" path, the pre-checks must
include:

1. **Private Key Check** — `--private-key` / `$PRIVATE_KEY` must be
   set; warn if the key has zero balance.
2. **Derive Public Address** — `cast wallet address`; confirm the
   key is for the intended network.
3. **Network Confirmation** — prompt the user with "You are about
   to write to Pacific mainnet. Continue? (y/N)".
4. **Automatic Balance Check** — `cast balance`; if below the
   operation cost + gas, abort with a clear error.
