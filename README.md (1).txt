# Pharos Flashloan Detector

AI Agent skill for detecting flash loan attack patterns on Pharos blockchain.

## Install

```bash
git clone https://github.com/ruzkypazzy/Pharos-Flashloan-Detector
cd Pharos-Flashloan-Detector
forge install
forge build
```

## Use

```bash
TX_HASH=0x... forge script AnalyzeFlashloan.s.sol --rpc-url $PHAROS_RPC
TARGET_ADDR=0x... forge script AnalyzeFlashloan.s.sol --rpc-url $PHAROS_RPC
CONTRACT_ADDR=0x... forge script AnalyzeFlashloan.s.sol --rpc-url $PHAROS_RPC
```

## Networks

- Mainnet: https://rpc.pharos.xyz (Chain ID: 1672)
- Testnet: https://atlantic.dplabs-internal.com (Chain ID: 688689)

## License

MIT