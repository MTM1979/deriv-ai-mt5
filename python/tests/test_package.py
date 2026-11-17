"""Model installation and metadata validation."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from data.loader import read_json, write_json_atomic
from features.spec import FEATURE_COUNT, metadata_fragment
from models.export_onnx import export_model
from models.onnx_writer import encode_logistic
from models.package import MetadataError, check_models, install_model, validate_metadata
from models.train import TrainedModel


def make_model(**overrides) -> TrainedModel:
    values = dict(
        asset_class="fx",
        mean=[0.0] * FEATURE_COUNT,
        std=[1.0] * FEATURE_COUNT,
        weights=[0.01] * FEATURE_COUNT,
        bias=-0.2,
        threshold=0.63,
        version="test-1",
    )
    values.update(overrides)
    return TrainedModel(**values)


class PackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.metadata = self.root / "model_metadata.json"
        write_json_atomic(
            self.metadata,
            {"schema": 1, **metadata_fragment(), "models": []},
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_install_and_check(self) -> None:
        model = make_model()
        onnx = export_model(model)
        meta = install_model(model, onnx, metadata_path=self.metadata, files_root=self.root)
        self.assertEqual(len(meta["models"]), 1)
        entry = meta["models"][0]
        self.assertEqual(entry["key"], "fx")
        self.assertEqual(entry["file"], "models/fx.onnx")
        self.assertEqual(entry["output_size"], 2)
        self.assertEqual(len(entry["sha256"]), 64)
        self.assertTrue((self.root / "models" / "fx.onnx").exists())
        self.assertEqual(check_models(self.metadata, self.root), [])

    def test_tampered_file_is_detected(self) -> None:
        model = make_model()
        install_model(model, export_model(model), metadata_path=self.metadata, files_root=self.root)
        (self.root / "models" / "fx.onnx").write_bytes(b"not onnx")
        problems = check_models(self.metadata, self.root)
        self.assertTrue(any("sha256 mismatch" in problem for problem in problems), problems)

    def test_missing_file_is_detected(self) -> None:
        model = make_model()
        install_model(model, export_model(model), metadata_path=self.metadata, files_root=self.root)
        (self.root / "models" / "fx.onnx").unlink()
        problems = check_models(self.metadata, self.root)
        self.assertTrue(any("not found" in problem for problem in problems), problems)

    def test_output_kind_and_threshold(self) -> None:
        model = make_model()
        onnx = encode_logistic([0.1] * FEATURE_COUNT, -0.1, output_kind="binary_one")
        meta = install_model(
            model,
            onnx,
            metadata_path=self.metadata,
            files_root=self.root,
            output_kind="binary_one",
            threshold=0.7,
        )
        entry = meta["models"][0]
        self.assertEqual(entry["output_size"], 1)
        self.assertAlmostEqual(entry["threshold"], 0.7)

    def test_feature_order_mismatch_is_rejected(self) -> None:
        meta = read_json(self.metadata)
        meta["feature_order"] = list(reversed(meta["feature_order"]))
        problems = validate_metadata(meta, files_root=self.root)
        self.assertTrue(any("feature_order" in problem for problem in problems), problems)

    def test_duplicate_key_is_rejected(self) -> None:
        model = make_model()
        install_model(model, export_model(model), metadata_path=self.metadata, files_root=self.root)
        meta = read_json(self.metadata)
        meta["models"].append(dict(meta["models"][0]))
        problems = validate_metadata(meta, files_root=self.root, allow_empty_hash=False)
        self.assertTrue(any("duplicated" in problem for problem in problems), problems)

    def test_install_rejects_wrong_output_shape(self) -> None:
        model = make_model()
        onnx = encode_logistic([0.1] * FEATURE_COUNT, 0.0, output_kind="binary_one")
        with self.assertRaises(MetadataError):
            install_model(model, onnx, metadata_path=self.metadata, files_root=self.root, output_kind="binary_two")

    def test_installs_into_new_metadata_file(self) -> None:
        fresh = self.root / "nested" / "model_metadata.json"
        model = make_model(asset_class="metal")
        install_model(model, export_model(model), metadata_path=fresh, files_root=self.root)
        meta = read_json(fresh)
        self.assertEqual(meta["models"][0]["key"], "metal")
        json.dumps(meta)


if __name__ == "__main__":
    unittest.main()
