"""Evaluate a trained model on labelled bars.

Reports two views, because a classifier can be well calibrated and still
lose money:

* probability metrics (AUC, Brier, log loss, precision/recall,
  calibration);
* trading metrics on the subset the EA would actually take
  (``p >= threshold``) in R multiples: expectancy, profit factor,
  drawdown and a bootstrap Monte Carlo.

The R multiples come from the same triple-barrier labels used in
training, so they are an in-sample research signal, not a broker
statement.  Real-tick tester results remain the authority.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Iterable

from data.loader import read_bars
from features.spec import DEFAULT_THRESHOLDS
from models.dataset import Dataset, DatasetOptions, build_dataset
from models.labels import LabelConfig
from models.metrics import (
    equity_curve,
    expectancy,
    max_drawdown,
    monte_carlo,
    percentile,
)
from models.train import TrainedModel, evaluate_model, load_model, record_for

__all__ = ["evaluate_dataset", "main"]


def _trading_view(model: TrainedModel, dataset: Dataset, threshold: float) -> dict:
    accepted = []
    rejected = []
    for features, row in zip(dataset.features, dataset.rows):
        probability = model.predict_proba(features)
        (accepted if probability >= threshold else rejected).append((probability, row))
    accepted_r = [row.r_multiple for _, row in accepted]
    rejected_r = [row.r_multiple for _, row in rejected]
    view: dict = {
        "threshold": threshold,
        "accepted": len(accepted),
        "rejected": len(rejected),
        "accept_rate": len(accepted) / len(dataset) if len(dataset) else 0.0,
        "all": expectancy(dataset.r_multiples()),
        "accepted_stats": expectancy(accepted_r) if accepted_r else {"count": 0.0},
        "rejected_stats": expectancy(rejected_r) if rejected_r else {"count": 0.0},
    }
    if accepted_r:
        curve = equity_curve(accepted_r)
        view["max_drawdown_r"] = max_drawdown(curve)["drawdown"]
        view["monte_carlo"] = monte_carlo(accepted_r, runs=2000, seed=7)
        view["accepted_mean_r_p05_p95"] = [
            percentile(accepted_r, 5),
            percentile(accepted_r, 95),
        ]
        if len(rejected_r) >= 20:
            view["lift_r"] = (sum(accepted_r) / len(accepted_r)) - (sum(rejected_r) / len(rejected_r))
    return view


def evaluate_dataset(model: TrainedModel, dataset: Dataset, *, threshold: float | None = None) -> dict:
    if not len(dataset):
        return {"rows": 0}
    t = float(model.threshold if threshold is None else threshold)
    report = {
        "rows": len(dataset),
        "dataset": dataset.summary(),
        "classification": evaluate_model(model, dataset, t),
        "trading": _trading_view(model, dataset, t),
    }
    by_direction = {}
    for direction in (1, -1):
        subset = Dataset()
        for features, row in zip(dataset.features, dataset.rows):
            if row.direction == direction:
                subset.add(features, row)
        if len(subset):
            probs = [model.predict_proba(row) for row in subset.features]
            accepted = [row.r_multiple for p, row in zip(probs, subset.rows) if p >= t]
            by_direction["long" if direction > 0 else "short"] = {
                "rows": len(subset),
                "accepted": len(accepted),
                "mean_r_accepted": (sum(accepted) / len(accepted)) if accepted else 0.0,
            }
    report["by_direction"] = by_direction
    return report


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Evaluate a model on labelled bars")
    parser.add_argument("--bars", required=True)
    parser.add_argument("--htf")
    parser.add_argument("--range", dest="range_bars")
    parser.add_argument("--symbol", required=True)
    parser.add_argument("--asset-class", default="fx", choices=("fx", "metal", "index"))
    parser.add_argument("--symbols")
    parser.add_argument("--model", required=True)
    parser.add_argument("--threshold", type=float, default=None)
    parser.add_argument("--horizon", type=int, default=24)
    parser.add_argument("--stop-atr", type=float, default=1.5)
    parser.add_argument("--rr", type=float, default=1.5)
    parser.add_argument("--min-index", type=int, default=None)
    parser.add_argument("--spread", type=float, default=1.0)
    parser.add_argument("--point", type=float, default=None)
    parser.add_argument("--day-roll-hour", type=int, default=0)
    parser.add_argument("--out", help="write the report JSON here")
    parser.add_argument("--last-fraction", type=float, default=1.0, help="evaluate only the newest fraction")
    args = parser.parse_args(list(argv) if argv is not None else None)

    model = load_model(args.model)
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
    if not len(dataset):
        print("no labelled rows", file=sys.stderr)
        return 2
    if 0.0 < args.last_fraction < 1.0:
        keep = max(1, int(len(dataset) * args.last_fraction))
        trimmed = Dataset()
        for features, row in zip(dataset.features[-keep:], dataset.rows[-keep:]):
            trimmed.add(features, row)
        dataset = trimmed
    threshold = args.threshold if args.threshold is not None else model.threshold
    if args.threshold is None and model.asset_class in DEFAULT_THRESHOLDS:
        threshold = DEFAULT_THRESHOLDS[model.asset_class]
    report = evaluate_dataset(model, dataset, threshold=threshold)
    text = json.dumps(report, indent=2)
    print(text)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
