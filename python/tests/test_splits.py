"""Purged, time-ordered splits."""

from __future__ import annotations

import unittest

from models.splits import Window, purged_kfold, purged_walk_forward


class SplitTests(unittest.TestCase):
    def test_rolling_windows_and_purge(self) -> None:
        windows = list(purged_walk_forward(100, 40, 20, horizon=5))
        self.assertEqual(len(windows), 2)
        first, second = windows
        self.assertEqual((first.train_start, first.train_end), (0, 40))
        self.assertEqual((first.test_start, first.test_end), (45, 65))
        self.assertEqual(first.purge, 5)
        self.assertEqual((second.train_start, second.train_end), (20, 60))
        self.assertEqual((second.test_start, second.test_end), (65, 85))
        for window in windows:
            self.assertLess(window.train_end, window.test_start)

    def test_expanding_windows(self) -> None:
        windows = list(purged_walk_forward(120, 50, 20, horizon=3, expanding=True))
        self.assertEqual(windows[0].train_start, 0)
        self.assertEqual(windows[1].train_start, 0)
        self.assertGreater(windows[1].train_end, windows[0].train_end)

    def test_embargo_is_at_least_horizon(self) -> None:
        window = next(purged_walk_forward(200, 50, 20, horizon=10, embargo=4))
        self.assertEqual(window.purge, 10)
        window = next(purged_walk_forward(200, 50, 20, horizon=2, embargo=9))
        self.assertEqual(window.purge, 9)

    def test_no_windows_when_history_is_short(self) -> None:
        self.assertEqual(list(purged_walk_forward(50, 40, 20)), [])
        with self.assertRaises(ValueError):
            list(purged_walk_forward(0, 10, 5))

    def test_window_validation(self) -> None:
        with self.assertRaises(ValueError):
            Window(10, 5, 20, 30)
        with self.assertRaises(ValueError):
            Window(0, 10, 5, 20)

    def test_kfold_leaves_purge(self) -> None:
        folds = purged_kfold(100, 5, horizon=3)
        self.assertEqual(len(folds), 4)  # the first fold has no left-side train data
        for window, _ in folds:
            self.assertLessEqual(window.train_end, window.test_start - 3)


if __name__ == "__main__":
    unittest.main()
