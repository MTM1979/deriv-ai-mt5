"""End-to-end research path on synthetic bars."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from data.loader import SymbolRecord, write_json_atomic
from features.spec import FEATURE_COUNT, metadata_fragment
from models.dataset import DatasetOptions, build_dataset
from models.export_onnx import export_model
from models.labels import LabelConfig
from models.onnx_writer import describe_model
from models.package import check_models, install_model
from models.train import evaluate_model, save_model, load_model, train_logistic
from models.walkforward import walk_forward
from tests.helpers import fast_indicator_config, synthetic_bars

RECORD = SymbolRecord(
    symbol="EURUSD",
    asset_class="fx",
    base_currency="EUR",
    quote_currency="USD",
    session_profile="all",
    max_risk_pct=0.35,
    max_spread_points=30,
    atr_period=14,
    min_atr_points=0,
    max_positions=2,
    correlation_group="USD_EUR",
    news_currencies=("USD", "EUR"),
)


def make_dataset(bars):
    return build_dataset(
        bars,
        RECORD,
        options=DatasetOptions(
            indicator=fast_indicator_config(),
            label=LabelConfig(atr_stop_mult=1.0, rr_target=1.5, horizon_bars=12),
            default_spread_points=1.0,
            min_index=60,
            point=0.0001,
        ),
    )


class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bars = synthetic_bars(800, seed=23)
        cls.dataset = make_dataset(cls.bars)

    def test_dataset_shape(self) -> None:
        self.assertGreater(len(self.dataset), 200)
        self.assertEqual(len(self.dataset.features[0]), FEATURE_COUNT)
        self.assertEqual(set(self.dataset.labels), {0, 1})
        self.assertEqual(len(self.dataset.rows), len(self.dataset.features))
        summary = self.dataset.summary()
        self.assertEqual(summary["rows"], len(self.dataset))

    def test_train_evaluate_export_package(self) -> None:
        split = int(len(self.dataset) * 0.7)
        result = train_logistic(
            self.dataset.features[:split],
            self.dataset.labels[:split],
            asset_class="fx",
            threshold=0.63,
            epochs=150,
            version="test",
        )
        model = result.model
        self.assertEqual(len(model.weights), FEATURE_COUNT)
        self.assertTrue(0.0 <= model.predict_proba(self.dataset.features[0]) <= 1.0)
        metrics = evaluate_model(model, self.dataset)
        self.assertEqual(metrics["rows"], len(self.dataset))
        self.assertIsNotNone(metrics["auc"])

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            model_path = root / "fx.json"
            save_model(model, model_path)
            reloaded = load_model(model_path)
            self.assertAlmostEqual(
                reloaded.predict_proba(self.dataset.features[0]),
                model.predict_proba(self.dataset.features[0]),
                places=12,
            )
            onnx = export_model(reloaded)
            described = describe_model(onnx)
            self.assertEqual(described["graph"]["inputs"][0]["dims"], [1, FEATURE_COUNT])
            self.assertEqual(described["graph"]["outputs"][0]["dims"], [1, 2])
            metadata = root / "model_metadata.json"
            write_json_atomic(metadata, {"schema": 1, **metadata_fragment(), "models": []})
            install_model(reloaded, onnx, metadata_path=metadata, files_root=root)
            self.assertEqual(check_models(metadata, root), [])

    def test_walk_forward(self) -> None:
        folds, aggregate, _, _ = walk_forward(
            self.dataset,
            train_bars=300,
            test_bars=150,
            horizon=12,
            threshold=0.63,
            min_train_rows=80,
            min_test_rows=20,
            epochs=120,
        )
        self.assertGreaterEqual(len(folds), 1)
        self.assertGreater(aggregate["rows"], 0)
        self.assertIn("brier", aggregate)
        self.assertGreaterEqual(aggregate["accepted"], 0)


if __name__ == "__main__":
    unittest.main()
