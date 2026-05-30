---
name: pharos-flashloan-detector
description: AI Agent skill for detecting flash loan attack patterns on Pharos blockchain
author: ruzkypazzy
version: 1.0.0
network: pharos
tags: [security, flashloan, pharos]
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
