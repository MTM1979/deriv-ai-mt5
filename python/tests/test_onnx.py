"""The hand-written ONNX graph parses back with the right shapes."""

from __future__ import annotations

import unittest

from features.spec import FEATURE_COUNT
from models.onnx_writer import OnnxFormatError, describe_model, encode_logistic


class OnnxWriterTests(unittest.TestCase):
    def test_binary_two_graph(self) -> None:
        weights = [0.01 * (i + 1) for i in range(FEATURE_COUNT)]
        data = encode_logistic(weights, -0.25, producer_version="test")
        model = describe_model(data)
        self.assertEqual(model["ir_version"], 8)
        self.assertEqual(model["producer"], "deriv-ai-mt5")
        graph = model["graph"]
        self.assertEqual([n["op_type"] for n in graph["nodes"]], ["MatMul", "Add", "Softmax"])
        self.assertEqual(graph["nodes"][2]["attributes"].get("axis"), 1)
        self.assertEqual(graph["inputs"][0]["name"], "features")
        self.assertEqual(graph["inputs"][0]["dims"], [1, FEATURE_COUNT])
        self.assertEqual(graph["inputs"][0]["elem_type"], 1)
        self.assertEqual(graph["outputs"][0]["dims"], [1, 2])
        initializers = {tensor["name"]: tensor for tensor in graph["initializers"]}
        self.assertEqual(initializers["W"]["dims"], [FEATURE_COUNT, 2])
        self.assertEqual(initializers["b"]["dims"], [2])
        self.assertEqual(initializers["b"]["values"], [0.0, -0.25])
        matrix = initializers["W"]["values"]
        self.assertEqual(matrix[:FEATURE_COUNT], [0.0] * FEATURE_COUNT)
        for i, weight in enumerate(weights):
            self.assertAlmostEqual(matrix[FEATURE_COUNT + i], weight, places=6)

    def test_binary_one_graph(self) -> None:
        data = encode_logistic([0.5] * FEATURE_COUNT, 0.1, output_kind="binary_one")
        graph = describe_model(data)["graph"]
        self.assertEqual([n["op_type"] for n in graph["nodes"]], ["MatMul", "Add", "Sigmoid"])
        self.assertEqual(graph["outputs"][0]["dims"], [1, 1])
        self.assertEqual(graph["initializers"][0]["dims"], [FEATURE_COUNT, 1])

    def test_rejects_bad_input(self) -> None:
        with self.assertRaises(ValueError):
            encode_logistic([], 0.0)
        with self.assertRaises(ValueError):
            encode_logistic([float("nan")] * FEATURE_COUNT, 0.0)
        with self.assertRaises(ValueError):
            encode_logistic([0.1] * FEATURE_COUNT, 0.0, output_kind="multiclass")

    def test_truncated_file_is_reported(self) -> None:
        data = encode_logistic([0.1] * FEATURE_COUNT, 0.0)
        with self.assertRaises(OnnxFormatError):
            describe_model(data[:20])


if __name__ == "__main__":
    unittest.main()
