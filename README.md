# Pharos Flashloan Detector

> Inspect a Pharos transaction for flash-loan-attack fingerprints and get a 0-100 risk score with a five-tier verdict.

[![foundry](https://img.shields.io/badge/built%20with-Foundry-orange)]()
[![bash](https://img.shields.io/badge/script-bash-blue)]()
[![license](https://img.shields.io/badge/license-MIT-green)]()
[![pharos](https://img.shields.io/badge/network-Pharos-blueviolet)]()
[![ai-agent](https://img.shields.io/badge/callable%20by-AI%20agent-purple)]()

## What it is

This is a **skill built for the Pharos network** — a self-contained, deterministic bash script that runs on top of the [Pharos](https://pharos.network) EVM chains. It is **not** an AI agent itself, and not a chatbot. It is a single bash script that:

- takes input from the caller via CLI flags,
- reads live on-chain data from Pharos via `cast` (Foundry),
- runs its own scoring/heuristic logic in pure bash + `jq`,
- prints a structured report (text or JSON) to stdout.

Reads a single tx receipt via `cast`, extracts the outer-call selector, matches it against a curated list of known flash-loan-provider and price-oracle function selectors, counts the logs as a proxy for inner-tx burst, and rolls the signals into a 0-100 score and a NONE / LOW / MEDIUM / HIGH / CRITICAL verdict. The score is heuristic — treat CRITICAL as "needs a human review", not as a verdict.

## How it scores

| Signal | Weight |
|---|---|
| Outer-call selector matches a known flash-loan provider (Aave V3, Aave V2, Balancer, dYdX, Euler, UniswapV3) | +60 |
| Outer-call selector matches a known oracle (Chainlink, UniswapV3 observe, UniswapV2 getReserves / getAmountOut) | +25 |
| Log count >= 5 (proxy for inner-tx burst) | +15 |
| Status = FAILED (small extra flag) | +5 |
| **Cap** | 100 |

**Verdict thresholds**: 0-19 NONE, 20-39 LOW, 40-59 MEDIUM, 60-79 HIGH, 80-100 CRITICAL.

## Use it from an AI agent

This skill is designed to be **called by an AI agent** (a Claude Code / Codex / Cursor agent, the Pharos Agent Center, or any custom LLM agent). The agent reads `SKILL.md` to discover the skill's flags, fills them in based on the user's request, and runs the bash script in its sandbox. The agent's job is just to translate "was this a flash-loan attack?" into `bash scripts/detect.sh 0xTX_HASH --chain mainnet`.

Typical agent-side flow:

```text
User -> Agent: "Was tx 0xabc...def a flash-loan attack on Pharos mainnet?"
Agent -> looks up SKILL.md for Pharos Flashloan Detector
Agent -> picks the right flag combo: 0xabc...def --chain mainnet
Agent -> runs: bash scripts/detect.sh 0xabc...def --chain mainnet
Agent -> reads the verdict, presents the score + signals to the user
```

The script prints structured output to stdout and human-readable progress to stderr, so the agent can parse the stdout cleanly (with `jq`) without being polluted by progress messages.

## Install

You need three things: **Foundry** (for `cast`), **jq** (for JSON pretty-printing), and **git** (to clone the repo).

```bash
# 1. Install Foundry (gives you cast, forge, anvil, chisel)
curl -L https://foundry.paradigm.xyz | bash
foundryup
# Reload your shell so the new commands are on PATH:
exec $SHELL
cast --version   # should print 1.x or higher

# 2. Install jq (required for --json output)
# macOS:   brew install jq
# Ubuntu:  sudo apt-get install -y jq
# Alpine:  apk add jq
jq --version

# 3. Clone this repo
git clone https://github.com/ruzkypazzy/pharos-flashloan-detector.git
cd pharos-flashloan-detector
chmod +x scripts/*.sh tests/*.sh
```

## Quick test (30 seconds, no API keys needed)

```bash
bash scripts/detect.sh demo
```

The first time you run this, the script may take a few seconds to fetch the tx receipt over RPC. Subsequent runs are cached by the RPC provider.

## Usage

```bash
# Analyze a specific transaction on mainnet
bash scripts/detect.sh 0xYOUR_TX_HASH --chain mainnet

# Demo (uses a real public mainnet tx as a sample)
bash scripts/detect.sh demo

# Output as JSON (for an agent)
bash scripts/detect.sh 0xYOUR_TX_HASH --json

# Testnet
bash scripts/detect.sh 0xYOUR_TX_HASH --chain testnet
```

### All flags

```
<TX_HASH> --chain mainnet|testnet --json
```

| Flag | Description |
|---|---|
| `<TX_HASH>` | The transaction hash to analyze (positional, required unless `demo`) |
| `--chain mainnet \| testnet` | Which Pharos chain to read from (default: mainnet) |
| `--json` | Output as JSON (for agent consumption) |
| `-h`, `--help` | Show the help text |
| `demo` | Run on a known public mainnet tx (no args) |

## Status extraction (3 branches, never claim FAILED on empty)

The script uses an explicit 3-branch status extraction:

- **SUCCESS** — raw status is `0x1` or `1`
- **FAILED** — raw status is `0x0` or `0`
- **UNKNOWN** — anything else (empty, garbage, RPC not responding)

If both `status` and `gasUsed` come back empty, the skill reports the tx as not found on the configured chain and lists 4 possible causes (wrong hash, wrong chain, RPC rate-limited, tx too old for this RPC node to remember).

## Networks

The skill is built to run against the Pharos EVM chains. The chain config is stored in `assets/networks.json` and read at startup — no hardcoded URLs in the script.

| Network | Chain ID | RPC URL | Default |
|---|---:|---|:---:|
| mainnet (Pacific Ocean) | 1672 | `https://rpc.pharos.xyz` | ✓ |
| atlantic-testnet | 688689 | `https://atlantic.dplabs-internal.com` |  |

The script defaults to mainnet. Pass `--chain testnet` to use the testnet instead. You can also override the RPC URL by editing `assets/networks.json`.

## Set it up in an AI agent

Three install paths for any AI agent that wants to call this skill.

### Path A — Pharos Agent Center (for the official Pharos LLM agent)

The Pharos Agent Center is the official agent runtime for the Pharos network. It reads `SKILL.md` from any skill repo to discover capabilities, dependencies, and required flags.

1. **Copy the skill into the Agent Center's skills directory:**
   ```bash
   # After cloning this repo:
   cp -r scripts assets SKILL.md README.md foundry.toml LICENSE \
     ~/.pharos/agent-center/skills/pharos-flashloan-detector/
   ```

2. **Reload the Agent Center's skill registry:**
   ```bash
   pharos-agent reload-skills
   # or restart the Agent Center daemon
   ```

3. **Invoke from the agent's chat UI** (or via the Agent Center's CLI / API):
   ```text
   User: "Was transaction 0xabc...def a flash-loan attack on Pharos mainnet"
   Agent Center: loads Pharos Flashloan Detector, runs:
     bash ~/.pharos/agent-center/skills/pharos-flashloan-detector/scripts/detect.sh 0xTX_HASH --chain mainnet
   ```

### Path B — `npx skills add` (for Claude Code, Cursor, Codex, generic MCP agents)

```bash
npx skills add https://github.com/ruzkypazzy/pharos-flashloan-detector --skill pharos-flashloan-detector
```

The agent's `skills` plugin will discover the SKILL.md, surface the skill in its tool list, and let the LLM pick the right flags when the user asks.

### Path C — Manual copy (any agent that reads `~/.claude/skills/`)

```bash
mkdir -p ~/.claude/skills/pharos-flashloan-detector
cp -r scripts assets SKILL.md README.md foundry.toml LICENSE ~/.claude/skills/pharos-flashloan-detector/
```

Restart the agent. It will pick up the new skill on next tool discovery.

### Path D — Direct invocation (shell agents, cron jobs, CI pipelines)

```bash
bash scripts/detect.sh demo
```

No agent needed — just shell + Foundry.

### What the agent says to invoke this skill

| Caller says | Script invocation |
|---|---|
| Was transaction `0xabc...def` a flash-loan attack | `bash scripts/detect.sh 0xabc...def --chain mainnet` |
| Run the flash-loan detector demo | `bash scripts/detect.sh demo` |
| Analyze a tx and return JSON | `bash scripts/detect.sh 0xabc...def --json` |
| "Run the demo" | `bash scripts/detect.sh demo` |

The agent should read the script's `--help` output to discover all available flags, then build the right command line for the user's request.

## Security model

The skill is **read-only by design**:

- The script never imports, reads, or stores a private key.
- It reads tx receipts and tx data via `eth_getTransactionReceipt` / `eth_getTransactionByHash` (read-only RPC) — it cannot move funds.
- It never submits a transaction, never writes to disk, never phones home.
- The only network call is to the user-configured RPC URL.

If you (or your agent) want to extend the scorecard (e.g. add a new flash-loan provider or oracle), append to the `FLASHLOAN_SELECTORS` / `ORACLE_SELECTORS` arrays in `scripts/detect.sh`. The format is `"0xSELECTOR | Provider Name"` per line.

## Framework

| Layer | Tech | Purpose |
|---|---|---|
| Engine | **bash 4+** | Script host (single file per skill) |
| RPC client | **Foundry / cast** | All chain reads — `cast receipt`, `cast tx`, log count from `cast receipt --json` |
| Chain config | **JSON** (`assets/networks.json`) | Network endpoints + chain IDs |
| Data format | **JSON** | Cast's native output; `jq` used for pretty-printing and JSON building |
| Runtime | Any POSIX shell, Foundry 1.0+ | Tested on Linux + macOS |

## Dependencies

**Required:**
- [Foundry](https://getfoundry.sh) (gives you `cast`, `forge`, `anvil`)
- `bash` 4+ (preinstalled on macOS, Ubuntu 20+, most Linux)
- `jq` (for `--json` output)

**Optional:**
- `git` — only required if you're cloning the repo (you already have it)

## Tests

Each repo ships with a bash smoke test that verifies:
1. `--help` works (no cast required)
2. No-args shows the usage hint
3. Unknown flags are rejected
4. Bad chain names are rejected
5. The cast-missing error is clear (when cast is not installed)
6. The live cast read produces a verdict (when cast is installed)
7. The `--json` output is valid JSON (when cast + jq are installed)

```bash
bash tests/test_detect_smoke.sh
```

The test runs offline by default. If cast is installed, test 6 hits the live Pharos mainnet RPC against a known public tx.

## Repository layout

```
pharos-flashloan-detector/
├── SKILL.md              # Skill contract (Capability Index, Error Handling, Security Reminders)
├── README.md             # This file
├── foundry.toml          # Minimal config so cast can find the project root
├── LICENSE               # MIT
├── assets/
│   └── networks.json     # mainnet + testnet chain config (read by every script)
├── scripts/
│   └── detect.sh          # The single bash script that does the work
└── tests/
    └── test_detect_smoke.sh   # Offline smoke test (no cast required)
```

## License

MIT — see `LICENSE`.
