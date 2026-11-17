"""Triple-barrier labels: no look-ahead, conservative ambiguity."""

from __future__ import annotations

import unittest

from models.labels import LabelConfig, label_trade, summarize
from tests.helpers import make_bars

# signal bar (0), entry bar (1), outcome bar (2)
BASE = [
    (100.0, 100.0, 100.0, 100.0, 10.0),
    (100.0, 100.5, 99.5, 100.0, 10.0),
    (100.0, 101.2, 99.8, 101.0, 10.0),
]
CFG = LabelConfig(atr_stop_mult=1.0, rr_target=1.0, horizon_bars=2)


class LabelTests(unittest.TestCase):
    def test_target_hit(self) -> None:
        label = label_trade(make_bars(BASE), 0, 1, 1.0, CFG)
        self.assertIsNotNone(label)
        assert label is not None
        self.assertEqual(label.label, 1)
        self.assertEqual(label.outcome, "target")
        self.assertEqual(label.entry_index, 1)
        self.assertEqual(label.entry_price, 100.0)
        self.assertAlmostEqual(label.stop_price, 99.0)
        self.assertAlmostEqual(label.target_price, 101.0)
        self.assertEqual(label.exit_index, 2)
        self.assertAlmostEqual(label.r_multiple, 1.0)
        self.assertGreaterEqual(label.mfe_r, 1.0)

    def test_stop_hit(self) -> None:
        bars = make_bars(BASE[:2] + [(100.0, 100.2, 98.9, 99.0, 10.0)])
        label = label_trade(bars, 0, 1, 1.0, CFG)
        assert label is not None
        self.assertEqual(label.label, 0)
        self.assertEqual(label.outcome, "stop")
        self.assertAlmostEqual(label.r_multiple, -1.0)
        self.assertGreaterEqual(label.mae_r, 1.0)

    def test_same_bar_ambiguity_is_conservative(self) -> None:
        bars = make_bars(BASE[:2] + [(100.0, 101.5, 98.5, 100.0, 10.0)])
        stop_first = label_trade(bars, 0, 1, 1.0, CFG)
        assert stop_first is not None
        self.assertEqual(stop_first.outcome, "stop")
        target_first = label_trade(
            bars, 0, 1, 1.0, LabelConfig(1.0, 1.0, 2, ambiguity="target_first")
        )
        assert target_first is not None
        self.assertEqual(target_first.outcome, "target")

    def test_timeout_keeps_realized_r(self) -> None:
        bars = make_bars(BASE[:2] + [(100.0, 100.4, 99.6, 100.3, 10.0)])
        label = label_trade(bars, 0, 1, 1.0, CFG)
        assert label is not None
        self.assertEqual(label.label, 0)
        self.assertEqual(label.outcome, "timeout")
        self.assertAlmostEqual(label.r_multiple, 0.3)

    def test_short_mirror(self) -> None:
        bars = make_bars(BASE[:2] + [(100.0, 100.2, 98.8, 99.0, 10.0)])
        label = label_trade(bars, 0, -1, 1.0, CFG)
        assert label is not None
        self.assertEqual(label.label, 1)
        self.assertEqual(label.outcome, "target")
        self.assertAlmostEqual(label.exit_price, 99.0)

    def test_entry_is_next_open(self) -> None:
        bars = make_bars(
            [
                (100.0, 100.0, 100.0, 100.0, 10.0),
                (101.0, 102.2, 100.8, 102.0, 10.0),
                (102.0, 103.0, 101.9, 102.5, 10.0),
            ]
        )
        label = label_trade(bars, 0, 1, 1.0, CFG)
        assert label is not None
        self.assertEqual(label.entry_price, 101.0)
        self.assertEqual(label.outcome, "target")

    def test_unlabelable(self) -> None:
        bars = make_bars(BASE)
        self.assertIsNone(label_trade(bars, 2, 1, 1.0, CFG))
        self.assertIsNone(label_trade(bars, 0, 1, 0.0, CFG))
        self.assertIsNone(label_trade(bars, 0, 1, float("nan"), CFG))

    def test_summary(self) -> None:
        labels = [label_trade(make_bars(BASE), 0, 1, 1.0, CFG)]
        summary = summarize([label for label in labels if label is not None])
        self.assertEqual(summary["count"], 1)
        self.assertEqual(summary["target"], 1)

    def test_config_validation(self) -> None:
        with self.assertRaises(ValueError):
            LabelConfig(atr_stop_mult=0.0)
        with self.assertRaises(ValueError):
            LabelConfig(ambiguity="coin_flip")


if __name__ == "__main__":
    unittest.main()
