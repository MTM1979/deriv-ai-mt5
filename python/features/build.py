"""Exact Python port of ``COnnxModelStore::BuildFeatures``.

The MQL5 EA and this module must agree on every arithmetic step.  Any
change here must be mirrored in ``MQL5/Include/OnnxModel.mqh`` (and in
``features/spec.py`` if the contract itself changes).  ``models/parity.py``
compares this implementation with snapshots exported by the EA.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Sequence

from .indicators import SnapshotView
from .spec import FEATURE_COUNT, FEATURE_LOWER, FEATURE_NAMES, FEATURE_UPPER

__all__ = [
    "FEATURE_INDEX",
    "FeatureBuildError",
    "SymbolView",
    "CandidateView",
    "build_features",
    "build_feature_row",
    "explain",
]

FEATURE_INDEX: dict[str, int] = {name: i for i, name in enumerate(FEATURE_NAMES)}


class FeatureBuildError(ValueError):
    """Raised when a candidate cannot produce a valid feature vector."""


@dataclass(frozen=True)
class SymbolView:
    """The only symbol-spec fields the feature builder needs."""

    point: float
    max_spread_points: int


@dataclass(frozen=True)
class CandidateView:
    """The candidate fields used by the feature builder."""

    direction: int
    spread_points: float
    minutes_since_open: int
    minutes_to_event: int
    event_impact: int

    def __post_init__(self) -> None:
        if self.direction not in (-1, 0, 1):
            raise ValueError("direction must be -1, 0 or 1")
        if self.event_impact < 0 or self.event_impact > 3:
            raise ValueError("event_impact must be 0..3")
        if self.minutes_since_open < 0:
            raise ValueError("minutes_since_open must be >= 0")
        if self.minutes_to_event < 0:
            raise ValueError("minutes_to_event must be >= 0")


def _finite(value: float, name: str) -> float:
    if not math.isfinite(value):
        raise FeatureBuildError(f"feature '{name}' is not finite: {value!r}")
    return float(value)


def build_features(
    snapshot: SnapshotView,
    candidate: CandidateView,
    symbol: SymbolView,
) -> list[float]:
    """Return the clamped feature vector, or raise ``FeatureBuildError``."""
    if not snapshot.valid:
        raise FeatureBuildError("snapshot is not valid")
    if candidate.direction == 0:
        raise FeatureBuildError("candidate direction is zero")
    if not math.isfinite(snapshot.atr) or snapshot.atr <= 0.0:
        raise FeatureBuildError("ATR is not positive")
    if not math.isfinite(symbol.point) or symbol.point <= 0.0:
        raise FeatureBuildError("symbol point is not positive")

    direction = 1.0 if candidate.direction > 0 else -1.0
    atr = snapshot.atr
    point = symbol.point
    max_spread = max(1.0, float(symbol.max_spread_points))
    bb_half = max(0.5 * snapshot.bb_width, 0.1 * atr)

    raw = [0.0] * FEATURE_COUNT
    raw[0] = 100.0 * snapshot.ret1
    raw[1] = 100.0 * snapshot.ret3
    raw[2] = 100.0 * snapshot.ret12
    raw[3] = direction * (snapshot.close - snapshot.ema_fast) / atr
    raw[4] = direction * (snapshot.ema_fast - snapshot.ema_mid) / atr
    raw[5] = direction * (snapshot.ema_mid - snapshot.ema_slow) / atr
    raw[6] = direction * snapshot.ema_slow_slope
    raw[7] = direction * (snapshot.rsi - 50.0) / 50.0
    raw[8] = direction * snapshot.macd_hist / (0.5 * atr)
    raw[9] = direction * (snapshot.macd_hist - snapshot.macd_hist_prev) / (0.5 * atr)
    raw[10] = snapshot.atr_percentile
    raw[11] = snapshot.bb_width / atr
    raw[12] = direction * (snapshot.close - snapshot.bb_middle) / bb_half
    raw[13] = snapshot.adx / 100.0
    raw[14] = direction * (snapshot.di_plus - snapshot.di_minus) / 100.0
    raw[15] = direction * (snapshot.session_high - snapshot.close) / atr
    raw[16] = direction * (snapshot.close - snapshot.session_low) / atr
    raw[17] = direction * (snapshot.close - snapshot.vwap) / atr
    raw[18] = direction * (snapshot.day_high - snapshot.close) / atr
    raw[19] = (snapshot.session_high - snapshot.session_low) / atr
    raw[20] = direction * (snapshot.htf_close - snapshot.htf_ema_slow) / max(snapshot.htf_atr, point)
    raw[21] = direction * (snapshot.htf_rsi - 50.0) / 50.0
    raw[22] = float(candidate.minutes_since_open) / 240.0
    raw[23] = 1.0 if candidate.minutes_to_event >= 9999 else float(candidate.minutes_to_event) / 240.0
    raw[24] = float(candidate.event_impact) / 3.0
    raw[25] = float(candidate.spread_points) / max_spread
    raw[26] = snapshot.volume_ratio
    raw[27] = direction * (snapshot.ema_fast - snapshot.ema_slow) / atr
    sweep = (direction > 0 and snapshot.sweep_low) or (direction < 0 and snapshot.sweep_high)
    raw[28] = 1.0 if sweep else 0.0
    raw[29] = direction

    out: list[float] = []
    for i, value in enumerate(raw):
        value = _finite(value, FEATURE_NAMES[i])
        out.append(min(max(value, FEATURE_LOWER[i]), FEATURE_UPPER[i]))
    return out


def build_feature_row(
    snapshot: SnapshotView,
    candidate: CandidateView,
    symbol: SymbolView,
) -> dict[str, float]:
    """Named feature vector, useful for journals and boundary tests."""
    values = build_features(snapshot, candidate, symbol)
    return {name: values[i] for i, name in enumerate(FEATURE_NAMES)}


def explain(values: Sequence[float]) -> list[dict[str, float | str]]:
    """Pair each value with its name and clamp bounds."""
    if len(values) != FEATURE_COUNT:
        raise ValueError(f"expected {FEATURE_COUNT} features, got {len(values)}")
    return [
        {
            "name": FEATURE_NAMES[i],
            "value": float(values[i]),
            "lower": FEATURE_LOWER[i],
            "upper": FEATURE_UPPER[i],
        }
        for i in range(FEATURE_COUNT)
    ]
