"""Single source of truth for the 30 model features.

The MQL5 EA (``MQL5/Include/FeatureSpec.mqh``) and the ONNX metadata
(``feature_order``) are both generated from this module. If the order, the
names or the clamp bounds change here, regenerate the header and retrain:

    python -m features.spec --write-mqh

The runtime rejects any model whose ``feature_order`` differs from the EA's
order, so a mismatch can never silently mis-score a trade.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

FEATURE_SPEC_VERSION = 2

#: Canonical feature order. Index i is the i-th ONNX input column.
FEATURE_NAMES: tuple[str, ...] = (
    "ret_1",
    "ret_3",
    "ret_12",
    "ema_fast_rel",
    "ema_mid_rel",
    "ema_slow_rel",
    "ema_slow_slope",
    "rsi_norm",
    "macd_hist_norm",
    "macd_accel",
    "atr_percentile",
    "bb_width_atr",
    "bb_position",
    "adx_norm",
    "di_diff",
    "dist_session_high",
    "dist_session_low",
    "dist_vwap",
    "dist_day_high",
    "range_expansion",
    "htf_trend",
    "htf_rsi_norm",
    "minutes_since_open",
    "minutes_to_event",
    "event_impact",
    "spread_ratio",
    "volume_ratio",
    "trend_strength",
    "sweep_flag",
    "direction",
)

FEATURE_COUNT = len(FEATURE_NAMES)

#: Clamp bounds applied identically in MQL5 and Python.
FEATURE_LOWER: tuple[float, ...] = (
    -5.0, -8.0, -15.0, -3.0, -3.0, -3.0, -2.0, -1.0, -3.0, -3.0,
    0.0, 0.0, -3.0, 0.0, -1.0, -5.0, -5.0, -5.0, -8.0, 0.0,
    -3.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, -3.0, 0.0, -1.0,
)

FEATURE_UPPER: tuple[float, ...] = (
    5.0, 8.0, 15.0, 3.0, 3.0, 3.0, 2.0, 1.0, 3.0, 3.0,
    1.0, 6.0, 3.0, 1.0, 1.0, 5.0, 5.0, 5.0, 8.0, 10.0,
    3.0, 1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 3.0, 1.0, 1.0,
)

FEATURE_DOC: tuple[str, ...] = (
    "1-bar log return, percent",
    "3-bar log return, percent",
    "12-bar log return, percent",
    "(close - EMA fast) / ATR, signed by direction",
    "(EMA fast - EMA mid) / ATR, signed by direction",
    "(EMA mid - EMA slow) / ATR, signed by direction",
    "EMA slow slope over 10 bars, in ATR, signed",
    "(RSI - 50) / 50, signed",
    "MACD histogram / (0.5 ATR), signed",
    "MACD histogram change / (0.5 ATR), signed",
    "ATR percentile rank in the lookback window, 0..1",
    "Bollinger width / ATR",
    "(close - BB middle) / max(0.5 BB width, 0.1 ATR), signed",
    "ADX / 100",
    "(DI+ - DI-) / 100, signed",
    "(session high - close) / ATR, signed",
    "(close - session low) / ATR, signed",
    "(close - VWAP) / ATR, signed",
    "(day high - close) / ATR, signed",
    "(session high - session low) / ATR",
    "(HTF close - HTF EMA slow) / HTF ATR, signed",
    "(HTF RSI - 50) / 50, signed",
    "minutes since session open / 240",
    "minutes to next high-impact event / 240, 1.0 if none",
    "event impact / 3",
    "spread / max(1, symbol spread ceiling)",
    "tick volume / 20-bar average",
    "(EMA fast - EMA slow) / ATR, signed",
    "1 when a sweep supports the direction",
    "+1 for long, -1 for short",
)

#: Per-asset-class operating points taken from the specification ranges.
#: Treat these as starting points, calibrate them on out-of-sample data.
DEFAULT_THRESHOLDS: dict[str, float] = {
    "fx": 0.63,
    "metal": 0.66,
    "index": 0.65,
}


@dataclass(frozen=True)
class FeatureMismatch(ValueError):
    """Raised when an external feature order does not match the contract."""

    detail: str

    def __str__(self) -> str:  # pragma: no cover - trivial
        return self.detail


def clamp(value: float) -> list[float]:
    """Clamp a raw feature vector to the shared bounds."""
    if len(value) != FEATURE_COUNT:
        raise ValueError(f"expected {FEATURE_COUNT} features, got {len(value)}")
    out: list[float] = []
    for i, v in enumerate(value):
        if v != v or v in (float("inf"), float("-inf")):
            raise ValueError(f"feature {FEATURE_NAMES[i]} is not finite: {v!r}")
        out.append(min(max(float(v), FEATURE_LOWER[i]), FEATURE_UPPER[i]))
    return out


def validate_order(order: Sequence[str]) -> None:
    """Fail closed when a model declares a different feature order."""
    if tuple(order) != FEATURE_NAMES:
        if len(order) != FEATURE_COUNT:
            raise FeatureMismatch(
                f"feature_order has {len(order)} entries, expected {FEATURE_COUNT}"
            )
        for i, (got, want) in enumerate(zip(order, FEATURE_NAMES)):
            if got != want:
                raise FeatureMismatch(
                    f"feature_order[{i}] is '{got}', expected '{want}'"
                )
        raise FeatureMismatch("feature_order differs from the contract")


def render_mqh() -> str:
    """Render ``MQL5/Include/FeatureSpec.mqh`` exactly as it is shipped."""
    lines = [
        "//+------------------------------------------------------------------+",
        "//|                                                   FeatureSpec.mqh |",
        "//|  GENERATED FROM python/features/spec.py - DO NOT EDIT BY HAND.     |",
        "//|  Regenerate with:  python -m features.spec --write-mqh            |",
        "//|                                                                  |",
        "//|  The order and meaning of these features is a contract between    |",
        "//|  the Python training pipeline and OnnxModel.mqh. Model metadata   |",
        "//|  is rejected at load time when its feature_order differs.         |",
        "//+------------------------------------------------------------------+",
        "#ifndef __DERIV_AI_FEATURESPEC_MQH__",
        "#define __DERIV_AI_FEATURESPEC_MQH__",
        "",
        f"#define FEATURE_COUNT {FEATURE_COUNT}",
        "",
        "string FEATURE_NAMES[FEATURE_COUNT] =",
        "  {",
    ]
    for i, name in enumerate(FEATURE_NAMES):
        suffix = "," if i < FEATURE_COUNT - 1 else ""
        lines.append(f'   "{name}"{suffix}')
    lines += [
        "  };",
        "",
        "#endif",
        "//+------------------------------------------------------------------+",
        "",
    ]
    return "\n".join(lines)


def write_mqh(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendering = render_mqh()
    # Write CRLF to match the rest of the MQL5 tree.
    path.write_bytes(rendering.replace("\n", "\r\n").encode("utf-8"))


def check_mqh(path: Path) -> bool:
    if not path.exists():
        return False
    current = path.read_bytes().decode("utf-8").replace("\r\n", "\n")
    return current == render_mqh()


def metadata_fragment() -> dict[str, object]:
    return {
        "feature_spec_version": FEATURE_SPEC_VERSION,
        "feature_count": FEATURE_COUNT,
        "feature_order": list(FEATURE_NAMES),
        "feature_lower": list(FEATURE_LOWER),
        "feature_upper": list(FEATURE_UPPER),
    }


def _main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Feature contract tooling")
    parser.add_argument("--write-mqh", action="store_true",
                        help="write MQL5/Include/FeatureSpec.mqh")
    parser.add_argument("--check", action="store_true",
                        help="verify FeatureSpec.mqh is current")
    parser.add_argument("--json", action="store_true",
                        help="print the metadata fragment")
    parser.add_argument("--root", default=None,
                        help="repository root (default: two levels up)")
    args = parser.parse_args(list(argv) if argv is not None else None)

    root = Path(args.root) if args.root else Path(__file__).resolve().parents[2]
    target = root / "MQL5" / "Include" / "FeatureSpec.mqh"

    if args.write_mqh:
        write_mqh(target)
        print(f"wrote {target}")
    if args.check:
        ok = check_mqh(target)
        print("FeatureSpec.mqh is current" if ok else "FeatureSpec.mqh is STALE")
        if not ok:
            return 1
    if args.json:
        print(json.dumps(metadata_fragment(), indent=2))
    if not (args.write_mqh or args.check or args.json):
        parser.print_help()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(_main())
