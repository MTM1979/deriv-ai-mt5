"""Walk-forward validation on a single instrument.

Each fold trains on bars strictly older than the test block, with a
purge of ``horizon`` bars so no training label can see a test price.
The report aggregates every out-of-sample prediction, which is the
number that matters for acceptance: a model that only looks good inside
one fold is not ready for demo.

The final model is retrained on all history by default.  Use
``--final train-only`` to keep the last test window untouched, which is
the honest choice when producing an artefact for review.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

from data.loader import read_bars
from models.dataset import Dataset, DatasetOptions, build_dataset
from models.labels import LabelConfig
from models.metrics import (
    brier_score,
    equity_curve,
    expectancy,
    log_loss,
    max_drawdown,
    monte_carlo,
    precision_recall_at,
    roc_auc,
)
from models.train import evaluate_model, record_for, save_model, train_logistic

__all__ = ["FoldResult", "walk_forward", "main"]


@dataclass
class FoldResult:
    train_bars_start: int
    train_bars_end: int
    test_bars_start: int
    test_bars_end: int
    train_rows: int
    test_rows: int
    threshold: float
    metrics: dict


def _subset(dataset: Dataset, indices: Sequence[int]) -> Dataset:
    out = Dataset()
    for i in indices:
        out.add(dataset.features[i], dataset.rows[i])
    return out


def _aggregate(labels: Sequence[int], probabilities: Sequence[float], r_multiples: Sequence[float], threshold: float) -> dict:
    if not labels:
        return {"rows": 0}
    accepted = [r for p, r in zip(probabilities, r_multiples) if p >= threshold]
    out = {
        "rows": len(labels),
        "positive_rate": sum(labels) / len(labels),
        "threshold": threshold,
        "brier": brier_score(labels, probabilities),
        "log_loss": log_loss(labels, probabilities),
        "precision_recall": precision_recall_at(labels, probabilities, threshold),
        "accepted": len(accepted),
        "accepted_rate": len(accepted) / len(labels),
        "all_trades": expectancy(r_multiples),
        "accepted_trades": expectancy(accepted) if accepted else {"count": 0.0},
    }
    try:
        out["auc"] = roc_auc(labels, probabilities)
    except ValueError as exc:
        out["auc"] = None
        out["auc_error"] = str(exc)
    if accepted:
        out["max_drawdown_r"] = max_drawdown(equity_curve(accepted))["drawdown"]
        out["monte_carlo"] = monte_carlo(accepted, runs=2000, seed=7)
    return out


def walk_forward(
    dataset: Dataset,
    *,
    train_bars: int,
    test_bars: int,
    step: int | None = None,
    horizon: int,
    threshold: float,
    expanding: bool = False,
    min_train_rows: int = 60,
    min_test_rows: int = 10,
    epochs: int = 800,
    l2: float = 1e-3,
    learning_rate: float = 0.15,
    asset_class: str = "fx",
) -> tuple[list[FoldResult], dict, Dataset, list[float]]:
    if not len(dataset):
        raise ValueError("empty dataset")
    indices = [row.index for row in dataset.rows]
    first = min(indices)
    last = max(indices) + 1
    step = test_bars if step is None else step
    if step < test_bars:
        raise ValueError("step must be >= test_bars to keep out-of-sample windows disjoint")
    folds: list[FoldResult] = []
    oos_labels: list[int] = []
    oos_probs: list[float] = []
    oos_r: list[float] = []
    oos_dataset = Dataset()
    fold_predictions: list[tuple[Dataset, list[float]]] = []

    test_start = first + train_bars
    fold_index = 0
    while test_start + test_bars <= last:
        train_end = test_start - horizon
        train_start = first if expanding else max(first, train_end - train_bars)
        train_idx = [i for i, row in enumerate(dataset.rows) if train_start <= row.index < train_end]
        test_idx = [i for i, row in enumerate(dataset.rows) if test_start <= row.index < test_start + test_bars]
        if len(train_idx) >= min_train_rows and len(test_idx) >= min_test_rows:
            train = _subset(dataset, train_idx)
            test = _subset(dataset, test_idx)
            labels = set(train.labels)
            if len(labels) == 2:
                result = train_logistic(
                    train.features,
                    train.labels,
                    asset_class=asset_class,
                    threshold=threshold,
                    l2=l2,
                    learning_rate=learning_rate,
                    epochs=epochs,
                    version=f"wf{fold_index}",
                )
                metrics = evaluate_model(result.model, test, threshold)
                probs = [result.model.predict_proba(row) for row in test.features]
                folds.append(
                    FoldResult(
                        train_bars_start=train_start,
                        train_bars_end=train_end,
                        test_bars_start=test_start,
                        test_bars_end=test_start + test_bars,
                        train_rows=len(train),
                        test_rows=len(test),
                        threshold=threshold,
                        metrics=metrics,
                    )
                )
                oos_labels.extend(test.labels)
                oos_probs.extend(probs)
                oos_r.extend(test.r_multiples())
                for features, row, p in zip(test.features, test.rows, probs):
                    oos_dataset.add(features, row)
                fold_predictions.append((result.model, test))
                fold_index += 1
        test_start += step

    aggregate = _aggregate(oos_labels, oos_probs, oos_r, threshold)
    aggregate["folds"] = len(folds)
    return folds, aggregate, oos_dataset, oos_probs


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Walk-forward validation")
    parser.add_argument("--bars", required=True)
    parser.add_argument("--htf")
    parser.add_argument("--range", dest="range_bars")
    parser.add_argument("--symbol", required=True)
    parser.add_argument("--asset-class", default="fx", choices=("fx", "metal", "index"))
    parser.add_argument("--symbols")
    parser.add_argument("--train-bars", type=int, default=5000)
    parser.add_argument("--test-bars", type=int, default=1250)
    parser.add_argument("--step", type=int, default=None)
    parser.add_argument("--expanding", action="store_true")
    parser.add_argument("--horizon", type=int, default=24)
    parser.add_argument("--stop-atr", type=float, default=1.5)
    parser.add_argument("--rr", type=float, default=1.5)
    parser.add_argument("--threshold", type=float, default=0.63)
    parser.add_argument("--epochs", type=int, default=800)
    parser.add_argument("--l2", type=float, default=1e-3)
    parser.add_argument("--learning-rate", type=float, default=0.15)
    parser.add_argument("--min-index", type=int, default=None)
    parser.add_argument("--spread", type=float, default=1.0)
    parser.add_argument("--point", type=float, default=None)
    parser.add_argument("--day-roll-hour", type=int, default=0)
    parser.add_argument("--out", help="walk-forward report JSON")
    parser.add_argument("--out-model", help="retrain a final model and write it here")
    parser.add_argument("--final", default="all", choices=("all", "train-only"))
    args = parser.parse_args(list(argv) if argv is not None else None)

    record = record_for(args.symbol, args.asset_class, args.symbols)
    bars = read_bars(args.bars)
    dataset = build_dataset(
        bars,
        record,
        htf_bars=read_bars(args.htf) if args.htf else None,
        range_bars=read_bars(args.range_bars) if args.range_bars else None,
        options=DatasetOptions(
            label=LabelConfig(
                atr_stop_mult=args.stop_atr,
                rr_target=args.rr,
                horizon_bars=args.horizon,
            ),
            day_roll_hour_utc=args.day_roll_hour,
            default_spread_points=args.spread,
            min_index=args.min_index,
            point=args.point,
        ),
    )
    folds, aggregate, _, _ = walk_forward(
        dataset,
        train_bars=args.train_bars,
        test_bars=args.test_bars,
        step=args.step,
        horizon=args.horizon,
        threshold=args.threshold,
        expanding=args.expanding,
        epochs=args.epochs,
        l2=args.l2,
        learning_rate=args.learning_rate,
        asset_class=record.asset_class,
    )
    report = {
        "symbol": record.symbol,
        "asset_class": record.asset_class,
        "generated_at": datetime.now(tz=timezone.utc).isoformat(timespec="seconds"),
        "dataset": dataset.summary(),
        "configuration": {
            "train_bars": args.train_bars,
            "test_bars": args.test_bars,
            "step": args.step or args.test_bars,
            "expanding": args.expanding,
            "horizon": args.horizon,
            "stop_atr": args.stop_atr,
            "rr": args.rr,
            "threshold": args.threshold,
        },
        "aggregate": aggregate,
        "folds": [
            {
                "train_bars": [fold.train_bars_start, fold.train_bars_end],
                "test_bars": [fold.test_bars_start, fold.test_bars_end],
                "train_rows": fold.train_rows,
                "test_rows": fold.test_rows,
                "metrics": fold.metrics,
            }
            for fold in folds
        ],
    }
    text = json.dumps(report, indent=2)
    print(text)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text + "\n", encoding="utf-8")

    if args.out_model:
        if args.final == "train-only":
            last_test_start = min((fold.test_bars_start for fold in folds), default=min(r.index for r in dataset.rows))
            final_indices = [i for i, row in enumerate(dataset.rows) if row.index < last_test_start - args.horizon]
        else:
            final_indices = list(range(len(dataset)))
        final = _subset(dataset, final_indices)
        if len(set(final.labels)) < 2 or len(final) < 60:
            print("not enough final rows/classes to retrain", file=sys.stderr)
            return 2
        result = train_logistic(
            final.features,
            final.labels,
            asset_class=record.asset_class,
            threshold=args.threshold,
            l2=args.l2,
            learning_rate=args.learning_rate,
            epochs=args.epochs,
            version=datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        )
        result.model.metrics = {"walk_forward": aggregate}
        save_model(result.model, args.out_model)
        print(f"wrote final model {args.out_model} ({len(final)} rows)")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
