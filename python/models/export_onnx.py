"""Export a trained model JSON to ONNX.

Run after ``models.train``::

    python -m models.train --bars EURUSD_M15.csv --symbol EURUSD \
        --asset-class fx --out build/fx.json
    python -m models.export_onnx --model build/fx.json --out build/fx.onnx

The logistic model is folded into a single affine layer so the EA can
feed the raw (already clamped) feature vector.  No scaler node is needed
at inference time, which keeps the graph and its latency minimal.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from typing import Iterable

from features.spec import FEATURE_COUNT
from models.onnx_writer import describe_model, encode_logistic
from models.train import TrainedModel, load_model

__all__ = ["effective_weights", "export_model", "main"]


def effective_weights(model: TrainedModel) -> tuple[list[float], float]:
    """Fold standardisation into the affine coefficients."""
    weights: list[float] = []
    bias = float(model.bias)
    for i in range(FEATURE_COUNT):
        w = float(model.weights[i]) / float(model.std[i])
        weights.append(w)
        bias -= w * float(model.mean[i])
    return weights, bias


def export_model(model: TrainedModel, output_kind: str = "binary_two") -> bytes:
    weights, bias = effective_weights(model)
    data = encode_logistic(
        weights,
        bias,
        output_kind=output_kind,
        producer_version=model.version,
    )
    described = describe_model(data)
    graph = described["graph"]
    expected_out = 2 if output_kind == "binary_two" else 1
    if graph["inputs"][0]["dims"] != [1, FEATURE_COUNT]:
        raise ValueError("exported input shape is wrong")
    if graph["outputs"][0]["dims"] != [1, expected_out]:
        raise ValueError("exported output shape is wrong")
    ops = [node["op_type"] for node in graph["nodes"]]
    if output_kind == "binary_two" and ops != ["MatMul", "Add", "Softmax"]:
        raise ValueError(f"unexpected graph {ops}")
    if output_kind == "binary_one" and ops != ["MatMul", "Add", "Sigmoid"]:
        raise ValueError(f"unexpected graph {ops}")
    return data


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Export a model JSON to ONNX")
    parser.add_argument("--model", required=True, help="model JSON from models.train")
    parser.add_argument("--out", required=True, help="destination .onnx file")
    parser.add_argument(
        "--output-kind",
        default="binary_two",
        choices=("binary_two", "binary_one"),
        help="binary_two = [1,2] softmax probabilities, binary_one = [1,1] sigmoid",
    )
    parser.add_argument("--check", action="store_true", help="verify an existing file matches")
    parser.add_argument("--inspect", action="store_true", help="print the parsed graph")
    args = parser.parse_args(list(argv) if argv is not None else None)

    model = load_model(args.model)
    data = export_model(model, args.output_kind)
    target = Path(args.out)
    target.parent.mkdir(parents=True, exist_ok=True)

    if args.check:
        if not target.exists():
            print(f"{target} does not exist", file=sys.stderr)
            return 1
        current = target.read_bytes()
        if current != data:
            print(f"{target} is stale (sha256 {_sha256(current)[:12]} != {_sha256(data)[:12]})", file=sys.stderr)
            return 1
        print(f"{target} is current ({len(data)} bytes, sha256 {_sha256(data)})")
        return 0

    target.write_bytes(data)
    print(f"wrote {target} ({len(data)} bytes, sha256 {_sha256(data)})")
    if args.inspect:
        import json

        print(json.dumps(describe_model(data), indent=2))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
