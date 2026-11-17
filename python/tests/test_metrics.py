"""Metric formulas and Monte Carlo determinism."""

from __future__ import annotations

import math
import unittest

from models import metrics


class MetricTests(unittest.TestCase):
    def test_auc(self) -> None:
        self.assertAlmostEqual(metrics.roc_auc([0, 0, 1, 1], [0.1, 0.2, 0.8, 0.9]), 1.0)
        self.assertAlmostEqual(metrics.roc_auc([1, 1, 0, 0], [0.1, 0.2, 0.8, 0.9]), 0.0)
        self.assertAlmostEqual(metrics.roc_auc([0, 1], [0.5, 0.5]), 0.5)
        with self.assertRaises(ValueError):
            metrics.roc_auc([0, 0], [0.1, 0.2])

    def test_brier_and_log_loss(self) -> None:
        self.assertAlmostEqual(metrics.brier_score([0, 1], [0.0, 1.0]), 0.0)
        self.assertAlmostEqual(metrics.brier_score([1, 0], [0.25, 0.75]), 0.5625)
        self.assertAlmostEqual(metrics.log_loss([1, 0], [0.5, 0.5]), math.log(2.0))
        self.assertGreater(metrics.log_loss([1, 0], [0.0, 1.0]), 10.0)

    def test_confusion_and_threshold(self) -> None:
        y = [0, 1, 1, 0, 1]
        p = [0.2, 0.9, 0.4, 0.6, 0.8]
        row = metrics.precision_recall_at(y, p, 0.5)
        self.assertEqual(row["tp"], 2)
        self.assertEqual(row["fp"], 1)
        self.assertEqual(row["fn"], 1)
        self.assertEqual(row["tn"], 1)
        self.assertAlmostEqual(row["precision"], 2 / 3)
        self.assertAlmostEqual(row["recall"], 2 / 3)

    def test_calibration(self) -> None:
        rows = metrics.calibration_table([0, 1, 1, 0], [0.05, 0.95, 0.85, 0.15], bins=2)
        self.assertEqual(sum(row["count"] for row in rows), 4)
        self.assertAlmostEqual(rows[0]["observed"], 0.0)
        self.assertAlmostEqual(rows[1]["observed"], 1.0)

    def test_precision_at_k(self) -> None:
        self.assertAlmostEqual(metrics.precision_at_k([1, 0, 1], [0.9, 0.8, 0.7], 2), 0.5)

    def test_expectancy(self) -> None:
        stats = metrics.expectancy([1.0, -1.0, 2.0, -0.5])
        self.assertAlmostEqual(stats["mean_r"], 0.375)
        self.assertAlmostEqual(stats["win_rate"], 0.5)
        self.assertAlmostEqual(stats["profit_factor"], 3.0 / 1.5)
        self.assertAlmostEqual(stats["total_r"], 1.5)

    def test_drawdown(self) -> None:
        result = metrics.max_drawdown([0.0, 1.0, 3.0, 1.0, -1.0])
        self.assertAlmostEqual(result["drawdown"], 4.0)
        self.assertEqual(result["peak_index"], 2)
        self.assertEqual(result["trough_index"], 4)
        self.assertEqual(metrics.max_drawdown([])["drawdown"], 0.0)

    def test_monte_carlo_is_deterministic(self) -> None:
        first = metrics.monte_carlo([1.0, -1.0, 2.0, -2.0], runs=50, seed=3)
        second = metrics.monte_carlo([1.0, -1.0, 2.0, -2.0], runs=50, seed=3)
        self.assertEqual(first, second)
        single = metrics.monte_carlo([-1.0], runs=20, trades_per_run=5, seed=1)
        self.assertEqual(single["final_r_p50"], -5.0)
        self.assertEqual(single["prob_negative"], 1.0)
        self.assertEqual(single["prob_ruin"], 0.0)

    def test_percentile(self) -> None:
        self.assertEqual(metrics.percentile([1, 2, 3, 4], 0), 1)
        self.assertEqual(metrics.percentile([1, 2, 3, 4], 100), 4)
        self.assertAlmostEqual(metrics.percentile([1, 2, 3, 4], 50), 2.5)

    def test_bootstrap_mean(self) -> None:
        out = metrics.bootstrap_mean([1.0, 2.0, 3.0], runs=100, seed=4)
        self.assertLessEqual(out["low"], out["mean"])
        self.assertGreaterEqual(out["high"], out["mean"])


if __name__ == "__main__":
    unittest.main()
