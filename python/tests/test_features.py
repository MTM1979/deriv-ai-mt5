"""Exact feature arithmetic, matching OnnxModel.mqh::BuildFeatures."""

from __future__ import annotations

import unittest

from features.build import (
    CandidateView,
    FeatureBuildError,
    SymbolView,
    build_feature_row,
    build_features,
    explain,
)
from features.spec import FEATURE_COUNT, FEATURE_NAMES
from tests.helpers import golden_snapshot

SYMBOL = SymbolView(point=0.00001, max_spread_points=30)
CANDIDATE = CandidateView(
    direction=1,
    spread_points=15.0,
    minutes_since_open=120,
    minutes_to_event=9999,
    event_impact=0,
)

# Hand-computed from the formulas in OnnxModel.mqh with the golden
# snapshot values (ATR=1, point=1e-5, spread ceiling=30).
EXPECTED_LONG = [
    1.0, 2.0, 3.0,          # ret1/3/12 * 100
    0.0, 0.0, 0.0, 0.0,     # EMA distances, slope
    0.0, 0.0, 0.0,          # RSI, MACD histogram, acceleration
    0.5, 2.0, 0.0,          # ATR percentile, BB width/ATR, BB position
    0.5, 0.0,               # ADX/100, DI difference
    1.0, 1.0, 0.0,          # session high/low, VWAP
    2.0, 2.0,               # day high, session range
    0.0, 0.0,               # HTF trend, HTF RSI
    0.5, 1.0, 0.0,          # minutes since open, no event, impact
    0.5, 1.0, 0.0,          # spread ratio, volume, trend strength
    1.0, 1.0,               # sweep flag, direction
]
EXPECTED_SHORT = [
    1.0, 2.0, 3.0,
    0.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0,
    0.5, 2.0, 0.0,
    0.5, 0.0,
    -1.0, -1.0, 0.0,
    -2.0, 2.0,
    0.0, 0.0,
    0.5, 1.0, 0.0,
    0.5, 1.0, 0.0,
    0.0, -1.0,
]


class FeatureBuildTests(unittest.TestCase):
    def test_golden_long_vector(self) -> None:
        values = build_features(golden_snapshot(), CANDIDATE, SYMBOL)
        self.assertEqual(len(values), FEATURE_COUNT)
        for i, (got, want) in enumerate(zip(values, EXPECTED_LONG)):
            self.assertAlmostEqual(got, want, places=12, msg=FEATURE_NAMES[i])

    def test_golden_short_vector(self) -> None:
        short = CandidateView(
            direction=-1,
            spread_points=15.0,
            minutes_since_open=120,
            minutes_to_event=9999,
            event_impact=0,
        )
        values = build_features(golden_snapshot(), short, SYMBOL)
        for i, (got, want) in enumerate(zip(values, EXPECTED_SHORT)):
            self.assertAlmostEqual(got, want, places=12, msg=FEATURE_NAMES[i])

    def test_short_sweep_high_sets_flag(self) -> None:
        short = CandidateView(-1, 15.0, 120, 9999, 0)
        values = build_features(golden_snapshot(sweep_high=True, sweep_low=False), short, SYMBOL)
        self.assertEqual(values[28], 1.0)

    def test_long_ignores_sweep_high(self) -> None:
        values = build_features(golden_snapshot(sweep_high=True, sweep_low=False), CANDIDATE, SYMBOL)
        self.assertEqual(values[28], 0.0)

    def test_event_features(self) -> None:
        candidate = CandidateView(1, 30.0, 240, 60, 3)
        values = build_features(golden_snapshot(), candidate, SYMBOL)
        self.assertAlmostEqual(values[22], 1.0)
        self.assertAlmostEqual(values[23], 0.25)
        self.assertAlmostEqual(values[24], 1.0)
        self.assertAlmostEqual(values[25], 1.0)

    def test_clamping(self) -> None:
        snapshot = golden_snapshot(
            ret12=100.0,
            ema_fast=1000.0,
            ema_mid=-1000.0,
            ema_slow=-500.0,
            atr_percentile=9.0,
            bb_width=500.0,
            volume_ratio=99.0,
        )
        values = build_features(snapshot, CANDIDATE, SYMBOL)
        self.assertEqual(values[2], 15.0)
        self.assertEqual(values[3], -3.0)
        self.assertEqual(values[4], 3.0)
        self.assertEqual(values[5], -3.0)
        self.assertEqual(values[10], 1.0)
        self.assertEqual(values[11], 6.0)
        self.assertEqual(values[26], 3.0)

    def test_invalid_inputs_fail_closed(self) -> None:
        with self.assertRaises(FeatureBuildError):
            build_features(golden_snapshot(atr=0.0), CANDIDATE, SYMBOL)
        with self.assertRaises(FeatureBuildError):
            build_features(golden_snapshot(valid=False), CANDIDATE, SYMBOL)
        with self.assertRaises(FeatureBuildError):
            build_features(golden_snapshot(), CandidateView(0, 1.0, 1, 9999, 0), SYMBOL)
        with self.assertRaises(FeatureBuildError):
            build_features(golden_snapshot(), CANDIDATE, SymbolView(0.0, 30))
        with self.assertRaises(FeatureBuildError):
            build_features(golden_snapshot(ret1=float("nan")), CANDIDATE, SYMBOL)

    def test_zero_spread_ceiling_is_floored_to_one(self) -> None:
        candidate = CandidateView(1, 0.5, 120, 9999, 0)
        values = build_features(golden_snapshot(), candidate, SymbolView(0.00001, 0))
        self.assertEqual(values[25], 0.5)

    def test_named_row_and_explain(self) -> None:
        row = build_feature_row(golden_snapshot(), CANDIDATE, SYMBOL)
        self.assertEqual(list(row), list(FEATURE_NAMES))
        explained = explain(list(row.values()))
        self.assertEqual(explained[0]["name"], "ret_1")
        with self.assertRaises(ValueError):
            explain([0.0] * 3)


if __name__ == "__main__":
    unittest.main()
