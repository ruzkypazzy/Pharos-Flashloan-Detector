---
name: pharos-flashloan-detector
description: Security-focused AI agent skill that inspects a Pharos transaction for flash-loan-attack fingerprints (large borrow, oracle manipulation, profit extraction) and reports a 0-100 risk score with a NONE / LOW / MEDIUM / HIGH / CRITICAL verdict. Read-only — never touches a private key. Use this skill whenever an agent needs to screen a wallet for flash-loan exposure before copy-trading, lending, or counterparty interaction.
version: 2.0.0
author: ruzkypazzy
requires: read
bins: [bash, cast, jq]
network: pharos
tags: [security, flashloan, pharos, defi, attack-detection, exploit, foundry, bash]
---

# Pharos Flashloan Detector

A bash + cast (Foundry) skill that inspects a single Pharos transaction for the three fingerprints every flash-loan attack leaves on-chain: a borrow from a known provider, a call to a manipulable price oracle in the same atomic tx, and a high log count (proxy for inner-tx burst). Emits a 0-100 risk score plus a five-tier verdict.

## How it scores

| Signal | Weight |
|---|---|
| Outer-call selector matches a known flash-loan provider (Aave V3, Aave V2, Balancer, dYdX, Euler, UniswapV3) | +60 |
| Outer-call selector matches a known oracle (Chainlink, UniswapV3 observe, UniswapV2 getReserves/getAmountOut) | +25 |
| Log count >= 5 (proxy for inner-tx burst) | +15 |
| Status = FAILED (small extra flag) | +5 |
| **Cap** | 100 |

**Verdict thresholds**: 0-19 NONE, 20-39 LOW, 40-59 MEDIUM, 60-79 HIGH, 80-100 CRITICAL.

## Quick Actions

### Detect a flash-loan attack on a specific tx
```
Was transaction 0xabc...def a flash-loan attack on Pharos mainnet?
```

### Run the demo (uses a real public mainnet tx)
```
Run the flash-loan detector demo
```

### Get the report as JSON (for downstream agent consumption)
```
Analyze tx 0xabc...def on Pharos mainnet and return JSON
```

## Invocation

```bash
# Analyze a specific transaction
bash scripts/detect.sh 0xYOUR_TX_HASH --chain mainnet

# Demo mode (uses a real public mainnet tx as a sample)
bash scripts/detect.sh demo

# JSON output
bash scripts/detect.sh 0xYOUR_TX_HASH --json

# Testnet
bash scripts/detect.sh 0xYOUR_TX_HASH --chain testnet
```

## Flags

| Flag | Description |
|---|---|
| `<TX_HASH>` | The transaction hash to analyze (positional, required unless `demo`) |
| `--chain mainnet \| testnet` | Which Pharos chain to read from (default: mainnet) |
| `--json` | Output as JSON (for agent consumption) |
| `-h`, `--help` | Show the help text |
| `demo` | Run on a known public mainnet tx (no args) |

## Networks

| Network | Chain ID | RPC URL |
|---|---:|---|
| mainnet (Pacific Ocean) | 1672 | `https://rpc.pharos.xyz` |
| atlantic-testnet | 688689 | `https://atlantic.dplabs-internal.com` |

Chain config is read from `assets/networks.json` at startup. Edit that file to add private RPC endpoints.

## Status extraction (3 branches)

The script uses an explicit 3-branch status extraction so it never claims a failed tx without positive evidence:

- `SUCCESS` — raw status is `0x1` or `1`
- `FAILED` — raw status is `0x0` or `0`
- `UNKNOWN` — anything else (empty, garbage, or RPC not responding)

If both `status` and `gasUsed` come back empty, the skill reports the tx as not found on the configured chain and lists 4 possible causes (wrong hash, wrong chain, RPC rate-limited, tx too old).

## Dependencies

- **Foundry** (gives you `cast`) — install with `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- **bash 4+** — preinstalled on macOS, Ubuntu 20+, most Linux
- **jq** — required only for `--json` output

## Security model

- The skill is **read-only** — it never imports, reads, or stores a private key.
- It reads tx receipts and tx data via `eth_getTransactionReceipt` / `eth_getTransactionByHash` (read-only RPC).
- It never submits a transaction, never writes to disk, never phones home.
- The only network call is to the user-configured RPC URL.

## Error handling

- Missing cast → "Error: 'cast' not found. Install Foundry..."
- Unknown flag → "Unknown flag: --foo"
- Bad chain → "Unknown chain: bogus (use 'mainnet' or 'testnet')"
- Missing tx hash → usage hint + exit 1
- Tx not on chain → "tx not found on chain=X" + 4 possible causes
- Empty/garbage status → UNKNOWN branch (never claim FAILED without evidence)

## Repository layout

```
pharos-flashloan-detector/
├── SKILL.md              # This file
├── README.md             # Full documentation
├── foundry.toml          # Minimal config so cast can find the project root
├── LICENSE               # MIT
├── assets/
│   └── networks.json     # mainnet + testnet chain config
├── scripts/
│   └── detect.sh         # The single bash script that does the work
└── tests/
    └── test_detect_smoke.sh   # Offline smoke test
```
