"""Indicator formulas and the UTC session state machine."""

from __future__ import annotations

import unittest
from datetime import datetime

from features.indicators import (
    SessionConfig,
    SessionEngine,
    adx,
    atr,
    bollinger,
    ema,
    percentile_rank,
    profile_allows_session,
    rsi,
    sma,
    true_range,
)


class IndicatorTests(unittest.TestCase):
    def test_sma(self) -> None:
        self.assertEqual(sma([1, 2, 3, 4, 5], 3), [None, None, 2.0, 3.0, 4.0])

    def test_ema_seed_and_step(self) -> None:
        values = ema([1, 2, 3, 4, 5], 3)
        self.assertIsNone(values[1])
        self.assertAlmostEqual(values[2], 2.0)
        self.assertAlmostEqual(values[3], 3.0)
        self.assertAlmostEqual(values[4], 4.0)
        self.assertTrue(all(v is None for v in ema([1, 2], 3)))

    def test_rsi_extremes(self) -> None:
        rising = rsi([1, 2, 3, 4, 5, 6], 3)
        self.assertAlmostEqual(rising[-1], 100.0)
        falling = rsi([6, 5, 4, 3, 2, 1], 3)
        self.assertAlmostEqual(falling[-1], 0.0)
        flat = rsi([5, 5, 5, 5, 5, 5], 3)
        self.assertAlmostEqual(flat[-1], 50.0)

    def test_atr_constant_range(self) -> None:
        highs = [10.0] * 10
        lows = [9.0] * 10
        closes = [9.5] * 10
        tr = true_range(highs, lows, closes)
        self.assertAlmostEqual(tr[0], 1.0)
        values = atr(highs, lows, closes, 3)
        self.assertAlmostEqual(values[-1], 1.0)

    def test_bollinger_constant(self) -> None:
        upper, middle, lower, width = bollinger([5.0] * 20, 20, 2.0)
        self.assertAlmostEqual(middle[-1], 5.0)
        self.assertAlmostEqual(upper[-1], 5.0)
        self.assertAlmostEqual(lower[-1], 5.0)
        self.assertAlmostEqual(width[-1], 0.0)

    def test_adx_direction(self) -> None:
        highs = [10.0 + i for i in range(60)]
        lows = [9.0 + i for i in range(60)]
        closes = [9.5 + i for i in range(60)]
        adx_values, di_plus, di_minus = adx(highs, lows, closes, 14)
        self.assertIsNotNone(adx_values[-1])
        self.assertGreater(di_plus[-1], di_minus[-1])
        self.assertGreater(adx_values[-1], 0.0)

    def test_percentile_rank(self) -> None:
        self.assertEqual(percentile_rank([1.0, 2.0, 3.0], 2.0, minimum=3), 2 / 3)
        self.assertEqual(percentile_rank([1.0, 2.0, 3.0], 2.0, minimum=4), -1.0)


class SessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.engine = SessionEngine(SessionConfig())

    def test_london_core(self) -> None:
        ctx = self.engine.update(datetime(2024, 1, 2, 8, 0))
        self.assertEqual(ctx.state, "london_core")
        self.assertTrue(ctx.trading_allowed)
        self.assertEqual(ctx.minutes_since_open, 60)
        self.assertAlmostEqual(ctx.risk_scale, 0.90)

    def test_london_open_and_preopen(self) -> None:
        self.assertEqual(self.engine.update(datetime(2024, 1, 2, 7, 10)).state, "london_open")
        self.assertEqual(self.engine.update(datetime(2024, 1, 2, 6, 55)).state, "london_preopen")
        self.assertFalse(self.engine.update(datetime(2024, 1, 2, 6, 55)).trading_allowed)

    def test_new_york_windows(self) -> None:
        self.assertEqual(self.engine.update(datetime(2024, 1, 2, 13, 20)).state, "ny_preopen")
        self.assertEqual(self.engine.update(datetime(2024, 1, 2, 13, 30)).state, "ny_open")
        self.assertEqual(self.engine.update(datetime(2024, 1, 2, 14, 0)).state, "ny_core")

    def test_rollover_and_asian(self) -> None:
        rollover = self.engine.update(datetime(2024, 1, 2, 20, 50))
        self.assertEqual(rollover.state, "rollover")
        self.assertFalse(rollover.trading_allowed)
        asian = self.engine.update(datetime(2024, 1, 2, 3, 0))
        self.assertEqual(asian.state, "asian")
        self.assertTrue(asian.trading_allowed)

    def test_profiles(self) -> None:
        self.assertTrue(profile_allows_session("london_ny", "london_core"))
        self.assertTrue(profile_allows_session("us_cash", "ny_open"))
        self.assertFalse(profile_allows_session("us_cash", "london_core"))
        self.assertTrue(profile_allows_session("asia", "asian"))
        self.assertFalse(profile_allows_session("mystery", "london_core"))
        self.assertTrue(profile_allows_session("all", "asian"))

    def test_invalid_session_config(self) -> None:
        with self.assertRaises(ValueError):
            SessionEngine(SessionConfig(london_open_hour=14, ny_open_hour=13))


if __name__ == "__main__":
    unittest.main()
