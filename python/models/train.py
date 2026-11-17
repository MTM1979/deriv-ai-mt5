"""Train the ONNX-scored baseline model.

The shipped baseline is L2-regularised logistic regression with
standardised inputs and balanced class weights.  It is deliberately
small: 30 inputs, one linear layer, one sigmoid.  That makes the ONNX
graph auditable, the export dependency-free (see ``models.export_onnx``)
and the probability calibration easy to inspect.

A stronger model (gradient boosting, MLP) can replace it later.  The
only contract is the one enforced by the EA: 30 features in
``features.spec.FEATURE_NAMES`` order and a probability output.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

from data.loader import DataError, SymbolRecord, read_bars, read_json, write_json_atomic
from features.build import FEATURE_COUNT
from features.spec import FEATURE_NAMES, FEATURE_SPEC_VERSION, validate_order
from models.dataset import Dataset, DatasetOptions, build_dataset
from models.labels import LabelConfig
from models.metrics import (
    brier_score,
    calibration_table,
    log_loss,
    precision_recall_at,
    roc_auc,
    threshold_table,
)
from models.splits import purged_walk_forward

__all__ = [
    "TrainedModel",
    "train_logistic",
    "save_model",
    "load_model",
    "main",
]

MODEL_SCHEMA = 1


def _sigmoid(z: float) -> float:
    if z >= 0.0:
        return 1.0 / (1.0 + math.exp(-z))
    exp_z = math.exp(z)
    return exp_z / (1.0 + exp_z)


@dataclass
class TrainedModel:
    asset_class: str
    mean: list[float]
    std: list[float]
    weights: list[float]
    bias: float
    threshold: float
    version: str
    metrics: dict[str, object] = field(default_factory=dict)
    training: dict[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if len(self.mean) != FEATURE_COUNT or len(self.std) != FEATURE_COUNT:
            raise ValueError(f"scaler must have {FEATURE_COUNT} entries")
        if len(self.weights) != FEATURE_COUNT:
            raise ValueError(f"weights must have {FEATURE_COUNT} entries")
        for value in self.mean + self.std + self.weights + [self.bias]:
            if not math.isfinite(float(value)):
                raise ValueError("model contains non-finite parameters")
        if not 0.0 <= self.threshold <= 1.0:
            raise ValueError("threshold must be 0..1")

    def decision_function(self, features: Sequence[float]) -> float:
        if len(features) != FEATURE_COUNT:
            raise ValueError(f"expected {FEATURE_COUNT} features, got {len(features)}")
        total = self.bias
        for i, value in enumerate(features):
            if not math.isfinite(value):
                raise ValueError(f"feature {FEATURE_NAMES[i]} is not finite")
            z = (float(value) - self.mean[i]) / self.std[i]
            total += self.weights[i] * z
        return total

    def predict_proba(self, features: Sequence[float]) -> float:
        return _sigmoid(self.decision_function(features))

    def accepts(self, probability: float) -> bool:
        return probability >= self.threshold

    def to_dict(self) -> dict[str, object]:
        return {
            "schema": MODEL_SCHEMA,
            "kind": "logistic",
            "feature_spec_version": FEATURE_SPEC_VERSION,
            "feature_order": list(FEATURE_NAMES),
            "asset_class": self.asset_class,
            "version": self.version,
            "trained_at": datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
            "threshold": self.threshold,
            "scaler": {"mean": list(self.mean), "std": list(self.std)},
            "weights": list(self.weights),
            "bias": self.bias,
            "metrics": self.metrics,
            "training": self.training,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "TrainedModel":
        if not isinstance(data, dict):
            raise ValueError("model JSON root must be an object")
        if data.get("schema") != MODEL_SCHEMA:
            raise ValueError(f"model schema must be {MODEL_SCHEMA}")
        if data.get("kind") != "logistic":
            raise ValueError("only 'logistic' models can be loaded by this tool")
        order = data.get("feature_order")
        if not isinstance(order, list):
            raise ValueError("feature_order missing")
        try:
            validate_order(order)
        except ValueError as exc:
            raise ValueError(f"model feature_order rejected: {exc}") from None
        scaler = data.get("scaler") or {}
        mean = scaler.get("mean")
        std = scaler.get("std")
        weights = data.get("weights")
        if not isinstance(mean, list) or not isinstance(std, list) or not isinstance(weights, list):
            raise ValueError("scaler/weights missing")
        return cls(
            asset_class=str(data.get("asset_class", "all")),
            mean=[float(v) for v in mean],
            std=[float(v) for v in std],
            weights=[float(v) for v in weights],
            bias=float(data.get("bias", 0.0)),
            threshold=float(data.get("threshold", 0.5)),
            version=str(data.get("version", "unset")),
            metrics=dict(data.get("metrics") or {}),
            training=dict(data.get("training") or {}),
        )


@dataclass
class TrainResult:
    model: TrainedModel
    history: list[dict[str, float]]


def train_logistic(
    features: Sequence[Sequence[float]],
    labels: Sequence[int],
    *,
    asset_class: str,
    threshold: float = 0.5,
    l2: float = 1e-3,
    learning_rate: float = 0.15,
    epochs: int = 1200,
    balanced: bool = True,
    valid_features: Sequence[Sequence[float]] | None = None,
    valid_labels: Sequence[int] | None = None,
    patience: int = 80,
    version: str = "dev",
) -> TrainResult:
    """Fit the baseline model and return it with the loss history."""
    if len(features) != len(labels):
        raise ValueError("features and labels must align")
    if len(features) < 30:
        raise ValueError("need at least 30 training rows")
    for row in features:
        if len(row) != FEATURE_COUNT:
            raise ValueError(f"expected {FEATURE_COUNT} features per row")
    positives = sum(1 for y in labels if int(y) == 1)
    negatives = len(labels) - positives
    if positives == 0 or negatives == 0:
        raise ValueError("training labels must contain both classes")

    mean = [0.0] * FEATURE_COUNT
    variance = [0.0] * FEATURE_COUNT
    for row in features:
        for i, value in enumerate(row):
            mean[i] += float(value)
    for i in range(FEATURE_COUNT):
        mean[i] /= len(features)
    for row in features:
        for i, value in enumerate(row):
            delta = float(value) - mean[i]
            variance[i] += delta * delta
    std = [math.sqrt(variance[i] / len(features)) or 1e-8 for i in range(FEATURE_COUNT)]
    std = [max(s, 1e-6) for s in std]

    def standardise(row: Sequence[float]) -> list[float]:
        return [(float(row[i]) - mean[i]) / std[i] for i in range(FEATURE_COUNT)]

    xs = [standardise(row) for row in features]
    ys = [float(y) for y in labels]
    if balanced:
        weight_pos = len(labels) / (2.0 * positives)
        weight_neg = len(labels) / (2.0 * negatives)
        sample_weights = [weight_pos if y == 1.0 else weight_neg for y in ys]
    else:
        sample_weights = [1.0] * len(labels)

    valid_x = [standardise(row) for row in valid_features] if valid_features else []
    valid_y = [float(y) for y in valid_labels] if valid_labels else []

    weights = [0.0] * FEATURE_COUNT
    bias = 0.0
    best = (float("inf"), list(weights), bias)
    stale = 0
    history: list[dict[str, float]] = []
    n = len(xs)
    for epoch in range(1, int(epochs) + 1):
        grad_w = [0.0] * FEATURE_COUNT
        grad_b = 0.0
        loss = 0.0
        for x, y, sw in zip(xs, ys, sample_weights):
            z = bias
            for i in range(FEATURE_COUNT):
                z += weights[i] * x[i]
            p = _sigmoid(z)
            p = min(max(p, 1e-9), 1.0 - 1e-9)
            loss += -sw * (y * math.log(p) + (1.0 - y) * math.log(1.0 - p))
            g = (p - y) * sw
            grad_b += g
            for i in range(FEATURE_COUNT):
                grad_w[i] += g * x[i]
        loss /= n
        for i in range(FEATURE_COUNT):
            weights[i] -= learning_rate * (grad_w[i] / n + l2 * weights[i])
        bias -= learning_rate * (grad_b / n)

        record = {"epoch": float(epoch), "train_loss": loss, "bias": bias}
        if valid_x:
            vp = [_sigmoid(bias + sum(weights[i] * x[i] for i in range(FEATURE_COUNT))) for x in valid_x]
            vp = [min(max(p, 1e-9), 1.0 - 1e-9) for p in vp]
            vloss = -sum(
                y * math.log(p) + (1.0 - y) * math.log(1.0 - p)
                for p, y in zip(vp, valid_y)
            ) / len(vp)
            record["valid_loss"] = vloss
            monitored = vloss
        else:
            monitored = loss
        history.append(record)
        if monitored < best[0] - 1e-9:
            best = (monitored, list(weights), bias)
            stale = 0
        else:
            stale += 1
            if patience and stale >= patience:
                break

    weights, bias = best[1], best[2]
    model = TrainedModel(
        asset_class=asset_class,
        mean=mean,
        std=std,
        weights=weights,
        bias=bias,
        threshold=threshold,
        version=version,
        training={
            "rows": len(labels),
            "positives": positives,
            "negatives": negatives,
            "balanced": balanced,
            "l2": l2,
            "learning_rate": learning_rate,
            "epochs_requested": epochs,
            "epochs_run": len(history),
            "best_monitored_loss": best[0],
            "feature_spec_version": FEATURE_SPEC_VERSION,
        },
    )
    return TrainResult(model=model, history=history)


def evaluate_model(model: TrainedModel, dataset: Dataset, threshold: float | None = None) -> dict:
    """Compute classification metrics for a labelled dataset."""
    if not len(dataset):
        return {"rows": 0}
    probabilities = [model.predict_proba(row) for row in dataset.features]
    y = dataset.labels
    t = float(model.threshold if threshold is None else threshold)
    out: dict[str, object] = {
        "rows": len(y),
        "positive_rate": sum(y) / len(y),
        "threshold": t,
        "brier": brier_score(y, probabilities),
        "log_loss": log_loss(y, probabilities),
        "precision_recall": precision_recall_at(y, probabilities, t),
        "calibration": calibration_table(y, probabilities, bins=10),
    }
    try:
        out["auc"] = roc_auc(y, probabilities)
    except ValueError as exc:
        out["auc"] = None
        out["auc_error"] = str(exc)
    out["thresholds"] = [
        row for row in threshold_table(y, probabilities, [0.50, 0.55, 0.60, 0.63, 0.66, 0.70, 0.75])
    ]
    return out


def save_model(model: TrainedModel, path: str | Path) -> None:
    write_json_atomic(path, model.to_dict())


def load_model(path: str | Path) -> TrainedModel:
    return TrainedModel.from_dict(read_json(path))


def record_for(symbol: str, asset_class: str, path: str | None) -> SymbolRecord:
    if path:
        from data.loader import read_symbols

        for record in read_symbols(path):
            if record.symbol.upper() == symbol.upper():
                if asset_class and record.asset_class != asset_class:
                    raise DataError(
                        f"{record.symbol} is '{record.asset_class}' in the CSV, not '{asset_class}'"
                    )
                return record
        raise DataError(f"symbol '{symbol}' not found in {path}")
    return SymbolRecord(
        symbol=symbol,
        asset_class=asset_class,
        base_currency="",
        quote_currency="",
        session_profile="all",
        max_risk_pct=0.35,
        max_spread_points=50,
        atr_period=14,
        min_atr_points=0,
        max_positions=1,
        correlation_group="UNKNOWN",
        news_currencies=(),
    )


def _split(dataset: Dataset, valid_fraction: float, horizon: int) -> tuple[Dataset, Dataset]:
    n = len(dataset)
    if valid_fraction <= 0.0 or n < 60:
        return dataset, Dataset()
    cut = int(n * (1.0 - valid_fraction))
    cut = max(30, min(cut, n - 10))
    test_start = min(n, cut + horizon)
    train = Dataset()
    valid = Dataset()
    for i in range(min(cut, n)):
        train.add(dataset.features[i], dataset.rows[i])
    for i in range(test_start, n):
        valid.add(dataset.features[i], dataset.rows[i])
    return train, valid


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Train the logistic baseline model")
    parser.add_argument("--bars", required=True, help="execution-timeframe OHLCV CSV")
    parser.add_argument("--htf", help="higher-timeframe OHLCV CSV (default: exec bars)")
    parser.add_argument("--range", dest="range_bars", help="range/VWAP OHLCV CSV (default: exec bars)")
    parser.add_argument("--symbol", required=True)
    parser.add_argument("--asset-class", default="fx", choices=("fx", "metal", "index"))
    parser.add_argument("--symbols", help="deriv_symbols.csv used for risk and session profile")
    parser.add_argument("--out", default="model.json")
    parser.add_argument("--report", help="write training history and metrics JSON here")
    parser.add_argument("--threshold", type=float, default=0.63)
    parser.add_argument("--horizon", type=int, default=24, help="label horizon in bars")
    parser.add_argument("--stop-atr", type=float, default=1.5)
    parser.add_argument("--rr", type=float, default=1.5)
    parser.add_argument("--epochs", type=int, default=1200)
    parser.add_argument("--l2", type=float, default=1e-3)
    parser.add_argument("--learning-rate", type=float, default=0.15)
    parser.add_argument("--valid-fraction", type=float, default=0.3)
    parser.add_argument("--min-index", type=int, default=None)
    parser.add_argument("--spread", type=float, default=1.0, help="spread points used for feature 25")
    parser.add_argument("--point", type=float, default=None, help="price point used for ratios")
    parser.add_argument("--version", default=None)
    parser.add_argument("--day-roll-hour", type=int, default=0)
    args = parser.parse_args(list(argv) if argv is not None else None)

    record = record_for(args.symbol, args.asset_class, args.symbols)
    bars = read_bars(args.bars)
    htf = read_bars(args.htf) if args.htf else None
    range_bars = read_bars(args.range_bars) if args.range_bars else None
    options = DatasetOptions(
        label=LabelConfig(
            atr_stop_mult=args.stop_atr,
            rr_target=args.rr,
            horizon_bars=args.horizon,
        ),
        day_roll_hour_utc=args.day_roll_hour,
        default_spread_points=args.spread,
        min_index=args.min_index,
        point=args.point,
    )
    dataset = build_dataset(
        bars,
        record,
        htf_bars=htf,
        range_bars=range_bars,
        options=options,
    )
    print(f"dataset: {json.dumps(dataset.summary())}")
    if len(dataset) < 60:
        print("not enough labelled rows; supply more history or a shorter horizon", file=sys.stderr)
        return 2

    train, valid = _split(dataset, args.valid_fraction, args.horizon)
    version = args.version or datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    result = train_logistic(
        train.features,
        train.labels,
        asset_class=record.asset_class,
        threshold=args.threshold,
        l2=args.l2,
        learning_rate=args.learning_rate,
        epochs=args.epochs,
        valid_features=valid.features or None,
        valid_labels=valid.labels or None,
        version=version,
    )
    model = result.model
    model.metrics = {
        "train": evaluate_model(model, train),
        "validation": evaluate_model(model, valid) if len(valid) else {"rows": 0},
    }
    save_model(model, args.out)
    print(f"wrote {args.out} (threshold {model.threshold:.3f}, version {model.version})")
    if args.report:
        write_json_atomic(
            args.report,
            {
                "symbol": record.symbol,
                "asset_class": record.asset_class,
                "dataset": dataset.summary(),
                "split": {"train": len(train), "validation": len(valid)},
                "metrics": model.metrics,
                "history": result.history,
            },
        )
        print(f"wrote {args.report}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
