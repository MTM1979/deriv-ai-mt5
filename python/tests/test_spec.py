"""The feature contract is shared by MQL5, Python and the metadata."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from features import spec

ROOT = Path(__file__).resolve().parents[2]


class FeatureSpecTests(unittest.TestCase):
    def test_order_and_bounds_are_complete(self) -> None:
        self.assertEqual(len(spec.FEATURE_NAMES), spec.FEATURE_COUNT)
        self.assertEqual(len(spec.FEATURE_LOWER), spec.FEATURE_COUNT)
        self.assertEqual(len(spec.FEATURE_UPPER), spec.FEATURE_COUNT)
        self.assertEqual(len(spec.FEATURE_DOC), spec.FEATURE_COUNT)
        for low, high in zip(spec.FEATURE_LOWER, spec.FEATURE_UPPER):
            self.assertLess(low, high)

    def test_shipped_header_is_current(self) -> None:
        target = ROOT / "MQL5" / "Include" / "FeatureSpec.mqh"
        self.assertTrue(target.exists(), target)
        self.assertTrue(spec.check_mqh(target), "FeatureSpec.mqh is stale; run python -m features.spec --write-mqh")

    def test_write_and_check_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "FeatureSpec.mqh"
            spec.write_mqh(path)
            self.assertTrue(spec.check_mqh(path))
            path.write_bytes(path.read_bytes().replace(b"ret_1", b"ret_x"))
            self.assertFalse(spec.check_mqh(path))

    def test_validate_order_rejects_reordering(self) -> None:
        spec.validate_order(spec.FEATURE_NAMES)
        swapped = list(spec.FEATURE_NAMES)
        swapped[0], swapped[1] = swapped[1], swapped[0]
        with self.assertRaises(spec.FeatureMismatch):
            spec.validate_order(swapped)
        with self.assertRaises(spec.FeatureMismatch):
            spec.validate_order(list(spec.FEATURE_NAMES)[:-1])

    def test_clamp(self) -> None:
        values = [1000.0] * spec.FEATURE_COUNT
        clamped = spec.clamp(values)
        self.assertEqual(clamped, list(spec.FEATURE_UPPER))
        with self.assertRaises(ValueError):
            spec.clamp([0.0] * (spec.FEATURE_COUNT - 1))
        with self.assertRaises(ValueError):
            spec.clamp([float("nan")] * spec.FEATURE_COUNT)

    def test_metadata_fragment_matches_header(self) -> None:
        fragment = spec.metadata_fragment()
        self.assertEqual(fragment["feature_order"], list(spec.FEATURE_NAMES))
        self.assertEqual(fragment["feature_count"], spec.FEATURE_COUNT)
        json.dumps(fragment)


if __name__ == "__main__":
    unittest.main()
