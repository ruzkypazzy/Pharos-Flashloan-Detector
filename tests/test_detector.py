"""
Smoke tests for pharos-flashloan-detector.

Covers:
  - Selector hint table
  - Heuristic scoring logic
  - Live RPC path (analyzes a real public mainnet tx)
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))

import pytest  # noqa: E402

import detector  # noqa: E402
from detector import FlashloanDetector, FLASHLOAN_SELECTORS, ORACLE_SELECTORS  # noqa: E402


def test_flashloan_selectors_table_nonempty():
    """The flash-loan selector table must have entries."""
    assert len(FLASHLOAN_SELECTORS) >= 4
    for sel, name in FLASHLOAN_SELECTORS.items():
        assert sel.startswith("0x") and len(sel) == 10
        assert name  # human-readable name


def test_oracle_selectors_table_nonempty():
    """The oracle selector table must have entries."""
    assert len(ORACLE_SELECTORS) >= 3


def test_chains_have_required_fields():
    """Each chain must have rpc, explorer, chain_id, symbol."""
    for k, c in detector.CHAINS.items():
        assert "rpc" in c
        assert "explorer" in c
        assert "chain_id" in c
        assert "symbol" in c


def test_analyze_rejects_missing_hash():
    """analyze() with no hash should return an error dict."""
    d = FlashloanDetector()
    r = d.analyze("")
    assert "error" in r


def test_analyze_rejects_bad_hash_format():
    """analyze() with a non-0x hash should return an error dict."""
    d = FlashloanDetector()
    r = d.analyze("not-a-hash")
    assert "error" in r


def test_hex_to_int_handles_zero():
    """_hex_to_int should gracefully handle 0x, 0x0, and None."""
    d = FlashloanDetector()
    assert d._hex_to_int("0x") == 0
    assert d._hex_to_int("0x0") == 0
    assert d._hex_to_int(None) == 0
    assert d._hex_to_int("0xff") == 255


def test_selector_of_normalizes():
    """_selector_of should lowercase and slice the first 10 chars."""
    d = FlashloanDetector()
    assert d._selector_of("0xAB9C4B5D1234567890") == "0xab9c4b5d"
    assert d._selector_of("") is None
    assert d._selector_of("0x1234") is None  # too short


def test_verdict_strings_dont_crash():
    """_verdict should produce a string for every level."""
    d = FlashloanDetector()
    for lvl in ("NONE", "LOW", "MEDIUM", "HIGH", "CRITICAL"):
        s = d._verdict(lvl, [])
        assert isinstance(s, str)
        assert len(s) > 5


@pytest.mark.skipif(
    not os.environ.get("PHAROS_LIVE", "1") == "1",
    reason="set PHAROS_LIVE=1 to run live RPC tests",
)
def test_live_mainnet_reverted_tx():
    """Analyze a real reverted public mainnet tx."""
    d = FlashloanDetector("mainnet")
    r = d.analyze("0x9606bcfd027b28e6783ca8b5fef1c3311476a1c30e5bf4464d0340a0d24ba7f7")
    if "error" in r:
        pytest.skip(f"RPC not reachable: {r['error']}")
    assert r["chain"] == "mainnet"
    assert r["status"] == "failed"
    assert r["tx_hash"].startswith("0x")
    assert isinstance(r["risk_score"], int)
    assert 0 <= r["risk_score"] <= 100
    assert r["risk_level"] in ("NONE", "LOW", "MEDIUM", "HIGH", "CRITICAL")


@pytest.mark.skipif(
    not os.environ.get("PHAROS_LIVE", "1") == "1",
    reason="set PHAROS_LIVE=1 to run live RPC tests",
)
def test_live_missing_tx_returns_error():
    """A non-existent tx hash should return an error dict, not crash."""
    d = FlashloanDetector("mainnet")
    r = d.analyze("0x0000000000000000000000000000000000000000000000000000000000000000")
    assert "error" in r
