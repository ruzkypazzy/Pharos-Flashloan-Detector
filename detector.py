#!/usr/bin/env python3
"""
pharos-flashloan-detector — Python detector for flash-loan attack patterns on Pharos.

A real flash-loan attack leaves fingerprints on-chain:
  1. The tx borrows a large amount from a known flash-loan provider.
  2. The same tx (or a tightly-coupled inner tx) calls a price oracle,
     a liquidity pool, or another contract that can be manipulated.
  3. The tx repays the loan and pockets a profit in the same atomic call.

This detector inspects a Pharos transaction and returns:
  - a list of features detected
  - a risk score (0-100)
  - a risk level (NONE / LOW / MEDIUM / HIGH / CRITICAL)
  - a list of indicators with human-readable explanations

The detector is **heuristic, not a proof**. Treat CRITICAL as "needs a
human to look at this".

Usage:
  python detector.py --tx 0x... [--chain mainnet|testnet] [--json]
  python detector.py demo
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from typing import Any, Dict, List, Optional


# Common flash-loan provider contract selectors. We don't have a
# canonical "is this a flash loan" event on Pharos yet, so we
# heuristically flag any tx that:
#   (a) emits a Transfer of an unusually large amount (≥ 1e9 raw with 6 decimals)
#   (b) calls one of the known flash-loan provider function selectors
#   (c) has more than N internal calls in a single tx (we use the receipt
#       log count as a cheap proxy)

# Borrow selectors from popular flash-loan providers.
FLASHLOAN_SELECTORS = {
    "0xab9c4b5d": "Aave V3 flashLoan(address[],uint256[],uint256[],address,bytes)",
    "0x5cffe9ea": "Aave V2 flashLoan(address,address,uint256,bytes)",
    "0x42b0bf78": "Balancer flashLoan(address,address[],uint256[],bytes)",
    "0x130d5b69": "dYdX withdraw(address,uint256)",
    "0x4f2be91d": "Euler flashLoan(uint256,bytes)",
    "0x5d5c1d77": "UniswapV3 flashLoan(address,uint256,bytes)",
}

# Method selectors that hint at manipulation candidates.
ORACLE_SELECTORS = {
    "0x59e02ddd": "Chainlink getReservePrice(address)",
    "0xb9e8c2a4": "Chainlink latestRoundData()",
    "0x2a4e8998": "UniswapV3 observe(uint32[])",
    "0xfa461e33": "UniswapV2 getReserves()",
    "0x0902f1ac": "UniswapV2 getAmountOut(uint256,uint256,uint256)",
}


CHAINS = {
    "mainnet": {
        "rpc": "https://rpc.pharos.xyz",
        "explorer": "https://www.pharosscan.xyz",
        "chain_id": 1672,
        "symbol": "PROS",
    },
    "testnet": {
        "rpc": "https://atlantic.dplabs-internal.com",
        "explorer": "https://atlantic.pharosscan.xyz",
        "chain_id": 688689,
        "symbol": "PHRS",
    },
}


class FlashloanDetector:
    """Heuristic flash-loan attack detector for Pharos."""

    def __init__(self, chain: str = "mainnet"):
        if chain not in CHAINS:
            raise ValueError(f"unknown chain: {chain!r}")
        self.chain = chain
        self.config = CHAINS[chain]

    # -------- low-level RPC helpers --------

    def _rpc(self, method: str, params: List[Any]) -> Any:
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.config["rpc"], data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=20) as r:
            resp = json.loads(r.read())
        if "error" in resp:
            raise RuntimeError(f"RPC error: {resp['error']}")
        return resp.get("result")

    def get_tx(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        return self._rpc("eth_getTransactionByHash", [tx_hash])

    def get_receipt(self, tx_hash: str) -> Optional[Dict[str, Any]]:
        return self._rpc("eth_getTransactionReceipt", [tx_hash])

    # -------- analysis --------

    def _hex_to_int(self, h: Optional[str]) -> int:
        if not h or h == "0x": return 0
        return int(h, 16)

    def _selector_of(self, input_hex: str) -> Optional[str]:
        if not input_hex or len(input_hex) < 10:
            return None
        return input_hex[:10].lower()

    def _decode_addresses_from_log_topics(self, log: Dict[str, Any]) -> List[str]:
        return [t.lower() for t in log.get("topics", []) if len(t) == 66]

    def analyze(self, tx_hash: str) -> Dict[str, Any]:
        """Run the heuristic analyzer on a Pharos tx hash."""
        if not tx_hash or not tx_hash.startswith("0x"):
            return {"error": "tx hash must be 0x-prefixed hex"}

        tx = self.get_tx(tx_hash)
        receipt = self.get_receipt(tx_hash)
        if not tx or not receipt:
            return {
                "error": "transaction not found on chain",
                "chain": self.chain,
                "tx_hash": tx_hash,
            }

        features: List[str] = []
        indicators: List[Dict[str, Any]] = []
        risk_score = 0

        # 1. Tx-level signals
        block_number = self._hex_to_int(receipt.get("blockNumber"))
        gas_used = self._hex_to_int(receipt.get("gasUsed"))
        value_wei = self._hex_to_int(tx.get("value"))
        input_data = tx.get("input", "0x")
        selector = self._selector_of(input_data)
        from_addr = (tx.get("from") or "").lower()
        to_addr = (tx.get("to") or "").lower() or None
        status = self._hex_to_int(receipt.get("status"))

        if status == 0:
            features.append("reverted_tx")
            risk_score += 5  # reverts are mildly suspicious

        # 2. Selector hint — is the top-level call a flash loan?
        if selector in FLASHLOAN_SELECTORS:
            features.append("top_level_flashloan_call")
            indicators.append({
                "type": "FLASHLOAN_SELECTOR",
                "selector": selector,
                "name": FLASHLOAN_SELECTORS[selector],
            })
            risk_score += 30

        # 3. Oracle-call heuristic
        if selector in ORACLE_SELECTORS:
            features.append("oracle_call_top_level")
            indicators.append({
                "type": "ORACLE_SELECTOR",
                "selector": selector,
                "name": ORACLE_SELECTORS[selector],
            })
            risk_score += 10

        # 4. Log analysis — look for large ERC-20 transfers
        erc20_transfers: List[Dict[str, Any]] = []
        large_transfer_count = 0
        for log in receipt.get("logs", []):
            topics = log.get("topics", [])
            if not topics or len(topics) < 3:
                continue
            # ERC-20 Transfer topic
            if topics[0].lower() == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef":
                from_topic = "0x" + topics[1][-40:]
                to_topic   = "0x" + topics[2][-40:]
                data = log.get("data", "0x")
                amount = self._hex_to_int(data) if data and data != "0x" else 0
                # Flag "large" as >= 1e9 raw (1B with 0 decimals, or 1000 with 6)
                is_large = amount >= 1_000_000_000
                if is_large:
                    large_transfer_count += 1
                erc20_transfers.append({
                    "token": log.get("address"),
                    "from": from_topic,
                    "to": to_topic,
                    "amount": amount,
                    "is_large": is_large,
                })

        if large_transfer_count >= 2:
            features.append("multiple_large_token_transfers")
            risk_score += 15
            indicators.append({
                "type": "LARGE_TRANSFERS",
                "count": large_transfer_count,
                "note": f"{large_transfer_count} large ERC-20 transfers in one tx",
            })

        # 5. Log count as proxy for inner-call complexity
        log_count = len(receipt.get("logs", []))
        if log_count >= 10:
            features.append("high_log_count")
            risk_score += 5
        if log_count >= 30:
            risk_score += 10

        # 6. Multi-action pattern: flash loan + transfer + same-tx
        if "top_level_flashloan_call" in features and "multiple_large_token_transfers" in features:
            features.append("flashloan_plus_swap_pattern")
            risk_score += 15
            indicators.append({
                "type": "FLASHLOAN_PLUS_TRANSFER",
                "note": "Tx calls a flash-loan entry point AND moves large token amounts in the same call",
            })

        # 7. Cap the score
        risk_score = min(risk_score, 100)

        # Map score to level
        if risk_score >= 70:
            level = "CRITICAL"
        elif risk_score >= 50:
            level = "HIGH"
        elif risk_score >= 30:
            level = "MEDIUM"
        elif risk_score >= 10:
            level = "LOW"
        else:
            level = "NONE"

        return {
            "type": "flashloan_analysis",
            "chain": self.chain,
            "chain_name": self.config["chain_id"],
            "tx_hash": tx_hash,
            "block": block_number,
            "from": from_addr,
            "to": to_addr,
            "value_native": value_wei / 1e18,
            "gas_used": gas_used,
            "status": "success" if status == 1 else "failed",
            "log_count": log_count,
            "erc20_transfers": len(erc20_transfers),
            "large_transfers": large_transfer_count,
            "top_level_selector": selector,
            "features": features,
            "indicators": indicators,
            "risk_score": risk_score,
            "risk_level": level,
            "verdict": self._verdict(level, features),
            "explorer_url": f"{self.config['explorer']}/tx/{tx_hash}",
        }

    def _verdict(self, level: str, features: List[str]) -> str:
        if level == "CRITICAL":
            return "🚨 Likely flash-loan attack. Replay with `cast run` + `--debug` to inspect inner calls before approving any follow-up tx."
        if level == "HIGH":
            return "⚠️  Suspicious — multiple flash-loan markers. Inspect before interacting with the contract that called this tx."
        if level == "MEDIUM":
            return "ℹ️  Some flash-loan-related signals present. Review indicators."
        if level == "LOW":
            return "✓ Low risk — minor signals only."
        return "✓ No flash-loan markers detected."


def main() -> int:
    p = argparse.ArgumentParser(
        description="Pharos Flashloan Detector — heuristic attack-pattern analyzer"
    )
    p.add_argument("--tx", help="transaction hash (0x...)")
    p.add_argument("--chain", default="mainnet", choices=list(CHAINS))
    p.add_argument("--json", action="store_true", help="output raw JSON")
    args = p.parse_args()

    if not args.tx:
        # Use a real public mainnet tx as a sample so the demo always works.
        args.tx = "0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7"
        print("ℹ️  No tx hash provided — running on a real public mainnet tx as a sample.\n")

    detector = FlashloanDetector(args.chain)
    result = detector.analyze(args.tx)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if "error" in result:
            print(f"❌ {result['error']}")
            return 1
        print("=" * 72)
        print(f"  Pharos Flashloan Detector — {result['risk_level']} (score {result['risk_score']}/100)")
        print("=" * 72)
        print(f"  chain:    {result['chain']}")
        print(f"  tx:       {result['tx_hash']}")
        print(f"  block:    {result['block']:,}")
        print(f"  from:     {result['from']}")
        print(f"  to:       {result['to']}")
        print(f"  status:   {result['status']}")
        print(f"  gas used: {result['gas_used']:,}")
        print(f"  logs:     {result['log_count']}  (ERC-20 transfers: {result['erc20_transfers']}, large: {result['large_transfers']})")
        print(f"  explorer: {result['explorer_url']}")
        print()
        print(f"  features: {', '.join(result['features']) or '—'}")
        print(f"  indicators:")
        for ind in result["indicators"]:
            note = ind.get("note") or ind.get("name") or str(ind)
            print(f"    • [{ind['type']}] {note}")
        print()
        print(f"  verdict: {result['verdict']}")
        print("=" * 72)

    return 0


if __name__ == "__main__":
    sys.exit(main())
