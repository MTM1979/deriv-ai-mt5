"""Compare Python feature construction with the EA's own output.

``MQL5/Scripts/ExportFeatureSamples.mq5`` writes a JSON document with
the raw ``IndicatorSnapshot`` fields, the candidate fields, the symbol
point/spread ceiling and the 30 features the EA computed.  This module
rebuilds the vector from the raw fields and reports any difference.

Run it after changing ``features/build.py`` or ``OnnxModel.mqh``::

    python -m models.parity --samples MQL5/Files/feature_samples.json

A clean run proves the arithmetic contract.  It does not prove the
indicator inputs match; that is checked separately by comparing the
snapshot fields in the same file.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Iterable, Sequence

from features.build import CandidateView, FeatureBuildError, SymbolView, build_features
from features.indicators import SnapshotView
from features.spec import FEATURE_NAMES

__all__ = ["snapshot_from_dict", "compare_sample", "compare_document", "main"]


def _timestamp(value: str) -> datetime:
    text = str(value).strip().replace("Z", "+00:00")
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is not None:
        parsed = parsed.replace(tzinfo=None)
    return parsed


def _snapshot(data: dict) -> SnapshotView:
    required = (
        "valid",
        "bar_time",
        "open",
        "high",
        "low",
        "close",
        "ret1",
        "ret3",
        "ret12",
        "atr",
        "atr_percentile",
        "ema_fast",
        "ema_mid",
        "ema_slow",
        "ema_slow_slope",
        "rsi",
        "macd_hist",
        "macd_hist_prev",
        "bb_upper",
        "bb_middle",
        "bb_lower",
        "bb_width",
        "adx",
        "di_plus",
        "di_minus",
        "session_high",
        "session_low",
        "day_high",
        "day_low",
        "prior_day_high",
        "prior_day_low",
        "vwap",
        "htf_close",
        "htf_ema_slow",
        "htf_rsi",
        "htf_atr",
        "volume_ratio",
        "sweep_high",
        "sweep_low",
        "last_high",
        "last_low",
        "last_close",
    )
    missing = [name for name in required if name not in data]
    if missing:
        raise ValueError(f"snapshot is missing fields: {', '.join(missing)}")
    return SnapshotView(
        valid=bool(data["valid"]),
        bar_time=_timestamp(data["bar_time"]),
        open=float(data["open"]),
        high=float(data["high"]),
        low=float(data["low"]),
        close=float(data["close"]),
        ret1=float(data["ret1"]),
        ret3=float(data["ret3"]),
        ret12=float(data["ret12"]),
        atr=float(data["atr"]),
        atr_percentile=float(data["atr_percentile"]),
        ema_fast=float(data["ema_fast"]),
        ema_mid=float(data["ema_mid"]),
        ema_slow=float(data["ema_slow"]),
        ema_slow_slope=float(data["ema_slow_slope"]),
        rsi=float(data["rsi"]),
        macd_hist=float(data["macd_hist"]),
        macd_hist_prev=float(data["macd_hist_prev"]),
        bb_upper=float(data["bb_upper"]),
        bb_middle=float(data["bb_middle"]),
        bb_lower=float(data["bb_lower"]),
        bb_width=float(data["bb_width"]),
        adx=float(data["adx"]),
        di_plus=float(data["di_plus"]),
        di_minus=float(data["di_minus"]),
        session_high=float(data["session_high"]),
        session_low=float(data["session_low"]),
        day_high=float(data["day_high"]),
        day_low=float(data["day_low"]),
        prior_day_high=float(data["prior_day_high"]),
        prior_day_low=float(data["prior_day_low"]),
        vwap=float(data["vwap"]),
        htf_close=float(data["htf_close"]),
        htf_ema_slow=float(data["htf_ema_slow"]),
        htf_rsi=float(data["htf_rsi"]),
        htf_atr=float(data["htf_atr"]),
        volume_ratio=float(data["volume_ratio"]),
        sweep_high=bool(data["sweep_high"]),
        sweep_low=bool(data["sweep_low"]),
        last_high=tuple(float(v) for v in data["last_high"]),
        last_low=tuple(float(v) for v in data["last_low"]),
        last_close=tuple(float(v) for v in data["last_close"]),
    )


def snapshot_from_dict(data: dict) -> SnapshotView:
    return _snapshot(data)


def compare_sample(sample: dict, tolerance: float = 1e-5) -> dict:
    expected = sample.get("features")
    if not isinstance(expected, list) or len(expected) != len(FEATURE_NAMES):
        raise ValueError("sample is missing a full 'features' array")
    snapshot = _snapshot(sample["snapshot"])
    candidate = CandidateView(
        direction=int(sample["direction"]),
        spread_points=float(sample["spread_points"]),
        minutes_since_open=int(sample["minutes_since_open"]),
        minutes_to_event=int(sample["minutes_to_event"]),
        event_impact=int(sample["event_impact"]),
    )
    symbol = SymbolView(
        point=float(sample["point"]),
        max_spread_points=int(sample["max_spread_points"]),
    )
    actual = build_features(snapshot, candidate, symbol)
    mismatches = []
    max_diff = 0.0
    for i, (want, got) in enumerate(zip(expected, actual)):
        diff = abs(float(want) - float(got))
        max_diff = max(max_diff, diff)
        if not math.isfinite(float(want)) or diff > tolerance:
            mismatches.append(
                {
                    "index": i,
                    "name": FEATURE_NAMES[i],
                    "expected": float(want),
                    "actual": float(got),
                    "diff": diff,
                }
            )
    return {
        "symbol": sample.get("symbol", "?"),
        "direction": candidate.direction,
        "max_abs_diff": max_diff,
        "mismatches": mismatches,
        "ok": not mismatches,
    }


def compare_document(document: dict, tolerance: float = 1e-5) -> dict:
    samples = document.get("samples")
    if not isinstance(samples, list):
        raise ValueError("document must contain a 'samples' array")
    results = []
    for sample in samples:
        try:
            results.append(compare_sample(sample, tolerance))
        except (ValueError, KeyError, FeatureBuildError) as exc:
            results.append(
                {
                    "symbol": sample.get("symbol", "?"),
                    "ok": False,
                    "error": str(exc),
                    "mismatches": [],
                }
            )
    failed = [r for r in results if not r["ok"]]
    return {
        "samples": len(results),
        "failed": len(failed),
        "max_abs_diff": max((r.get("max_abs_diff", 0.0) for r in results), default=0.0),
        "ok": not failed,
        "results": results,
    }


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify Python/EA feature parity")
    parser.add_argument("--samples", required=True, help="JSON from ExportFeatureSamples.mq5")
    parser.add_argument("--tolerance", type=float, default=1e-5)
    parser.add_argument("--out", help="write the detailed comparison here")
    args = parser.parse_args(list(argv) if argv is not None else None)

    document = json.loads(Path(args.samples).read_text(encoding="utf-8-sig"))
    report = compare_document(document, args.tolerance)
    text = json.dumps(report, indent=2)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text + "\n", encoding="utf-8")
    if report["ok"]:
        print(f"feature parity OK ({report['samples']} samples, max diff {report['max_abs_diff']:.3g})")
        return 0
    print(
        f"feature parity FAILED ({report['failed']}/{report['samples']} samples, "
        f"max diff {report['max_abs_diff']:.3g})",
        file=sys.stderr,
    )
    for result in report["results"]:
        if result["ok"]:
            continue
        if "error" in result:
            print(f"  {result['symbol']}: {result['error']}", file=sys.stderr)
        for mismatch in result.get("mismatches", [])[:5]:
            print(
                f"  {result['symbol']} [{mismatch['index']}] {mismatch['name']}: "
                f"EA {mismatch['expected']!r} != Python {mismatch['actual']!r}",
                file=sys.stderr,
            )
    return 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
