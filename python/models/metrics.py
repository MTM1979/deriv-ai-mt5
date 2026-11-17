"""Classification and trading metrics (standard library only).

The EA's acceptance criteria are expressed in probabilities and R
multiples, so the pipeline reports both.  Nothing here depends on
NumPy or scikit-learn; the formulas are short enough to audit.
"""

from __future__ import annotations

import math
import random
from typing import Iterable, Sequence

__all__ = [
    "roc_auc",
    "brier_score",
    "log_loss",
    "precision_recall_at",
    "confusion_at",
    "threshold_table",
    "calibration_table",
    "precision_at_k",
    "expectancy",
    "equity_curve",
    "max_drawdown",
    "monte_carlo",
    "percentile",
    "bootstrap_mean",
]


def _validate(y: Sequence[int], scores: Sequence[float]) -> None:
    if len(y) != len(scores):
        raise ValueError("y and scores must have the same length")
    if not y:
        raise ValueError("empty input")


def roc_auc(y: Sequence[int], scores: Sequence[float]) -> float:
    """Rank-based AUC with average ranks for ties."""
    _validate(y, scores)
    positives = sum(1 for value in y if value == 1)
    negatives = len(y) - positives
    if positives == 0 or negatives == 0:
        raise ValueError("AUC requires both classes")
    order = sorted(range(len(scores)), key=lambda i: scores[i])
    ranks = [0.0] * len(scores)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and scores[order[j + 1]] == scores[order[i]]:
            j += 1
        average = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[order[k]] = average
        i = j + 1
    rank_sum = sum(ranks[i] for i in range(len(y)) if y[i] == 1)
    return (rank_sum - positives * (positives + 1) / 2.0) / (positives * negatives)


def brier_score(y: Sequence[int], scores: Sequence[float]) -> float:
    _validate(y, scores)
    return sum((float(p) - float(t)) ** 2 for t, p in zip(y, scores)) / len(y)


def log_loss(y: Sequence[int], scores: Sequence[float], epsilon: float = 1e-9) -> float:
    _validate(y, scores)
    total = 0.0
    for target, score in zip(y, scores):
        p = min(max(float(score), epsilon), 1.0 - epsilon)
        total += -(target * math.log(p) + (1 - target) * math.log(1.0 - p))
    return total / len(y)


def confusion_at(y: Sequence[int], scores: Sequence[float], threshold: float) -> dict[str, int]:
    _validate(y, scores)
    tp = fp = tn = fn = 0
    for target, score in zip(y, scores):
        predicted = 1 if score >= threshold else 0
        if predicted and target:
            tp += 1
        elif predicted and not target:
            fp += 1
        elif not predicted and target:
            fn += 1
        else:
            tn += 1
    return {"tp": tp, "fp": fp, "tn": tn, "fn": fn}


def precision_recall_at(
    y: Sequence[int], scores: Sequence[float], threshold: float
) -> dict[str, float]:
    counts = confusion_at(y, scores, threshold)
    tp, fp, fn = counts["tp"], counts["fp"], counts["fn"]
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    specificity = counts["tn"] / (counts["tn"] + fp) if counts["tn"] + fp else 0.0
    return {
        "threshold": float(threshold),
        "precision": precision,
        "recall": recall,
        "specificity": specificity,
        "f1": (2 * precision * recall / (precision + recall)) if precision + recall else 0.0,
        "trades": tp + fp,
        **counts,
    }


def threshold_table(
    y: Sequence[int], scores: Sequence[float], thresholds: Iterable[float]
) -> list[dict[str, float]]:
    return [precision_recall_at(y, scores, t) for t in thresholds]


def calibration_table(
    y: Sequence[int], scores: Sequence[float], bins: int = 10
) -> list[dict[str, float]]:
    """Reliability table: mean predicted vs observed per probability bin."""
    if bins < 1:
        raise ValueError("bins must be >= 1")
    _validate(y, scores)
    edges = [i / bins for i in range(bins + 1)]
    rows: list[dict[str, float]] = []
    for b in range(bins):
        low, high = edges[b], edges[b + 1]
        members = [
            (float(t), float(p))
            for t, p in zip(y, scores)
            if (low <= p < high) or (b == bins - 1 and p == 1.0)
        ]
        if not members:
            rows.append(
                {"bin": b, "low": low, "high": high, "count": 0, "mean_predicted": 0.0, "observed": 0.0}
            )
            continue
        mean_predicted = sum(p for _, p in members) / len(members)
        observed = sum(t for t, _ in members) / len(members)
        rows.append(
            {
                "bin": b,
                "low": low,
                "high": high,
                "count": len(members),
                "mean_predicted": mean_predicted,
                "observed": observed,
            }
        )
    return rows


def precision_at_k(y: Sequence[int], scores: Sequence[float], k: int) -> float:
    _validate(y, scores)
    if k < 1:
        raise ValueError("k must be >= 1")
    ranked = sorted(zip(scores, y), key=lambda pair: pair[0], reverse=True)[:k]
    return sum(target for _, target in ranked) / len(ranked) if ranked else 0.0


def equity_curve(r_multiples: Sequence[float], start: float = 0.0) -> list[float]:
    curve = [float(start)]
    total = float(start)
    for value in r_multiples:
        total += float(value)
        curve.append(total)
    return curve


def max_drawdown(values: Sequence[float]) -> dict[str, float]:
    """Maximum peak-to-trough drawdown of an equity-like series."""
    if not values:
        return {"drawdown": 0.0, "peak_index": 0, "trough_index": 0}
    peak = float(values[0])
    peak_index = 0
    best = 0.0
    best_peak = 0
    best_trough = 0
    for i, value in enumerate(values):
        value = float(value)
        if value > peak:
            peak = value
            peak_index = i
        drop = peak - value
        if drop > best:
            best = drop
            best_peak = peak_index
            best_trough = i
    return {"drawdown": best, "peak_index": best_peak, "trough_index": best_trough}


def expectancy(r_multiples: Sequence[float]) -> dict[str, float]:
    if not r_multiples:
        return {"count": 0.0}
    wins = [float(r) for r in r_multiples if r > 0.0]
    losses = [float(r) for r in r_multiples if r <= 0.0]
    gross_win = sum(wins)
    gross_loss = -sum(losses)
    return {
        "count": float(len(r_multiples)),
        "mean_r": sum(r_multiples) / len(r_multiples),
        "win_rate": len(wins) / len(r_multiples),
        "avg_win_r": gross_win / len(wins) if wins else 0.0,
        "avg_loss_r": -gross_loss / len(losses) if losses else 0.0,
        "profit_factor": (gross_win / gross_loss) if gross_loss > 0.0 else float("inf"),
        "total_r": gross_win - gross_loss,
        "worst_r": min(float(r) for r in r_multiples),
        "best_r": max(float(r) for r in r_multiples),
    }


def percentile(values: Sequence[float], q: float) -> float:
    """Linear-interpolated percentile (NumPy's default)."""
    if not values:
        raise ValueError("empty values")
    if not 0.0 <= q <= 100.0:
        raise ValueError("q must be 0..100")
    ordered = sorted(float(v) for v in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * q / 100.0
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def monte_carlo(
    r_multiples: Sequence[float],
    runs: int = 2000,
    trades_per_run: int | None = None,
    seed: int = 7,
    ruin_threshold_r: float | None = None,
) -> dict[str, float]:
    """Bootstrap trade sequences and summarize final R and drawdown."""
    if not r_multiples:
        raise ValueError("empty r_multiples")
    if runs < 10:
        raise ValueError("runs must be >= 10")
    n = int(trades_per_run or len(r_multiples))
    rng = random.Random(seed)
    finals: list[float] = []
    drawdowns: list[float] = []
    worst_streaks: list[int] = []
    ruin = 0
    for _ in range(runs):
        sample = [r_multiples[rng.randrange(len(r_multiples))] for _ in range(n)]
        total = 0.0
        peak = 0.0
        max_dd = 0.0
        streak = 0
        worst = 0
        for value in sample:
            total += value
            if total > peak:
                peak = total
            max_dd = max(max_dd, peak - total)
            if value <= 0.0:
                streak += 1
                worst = max(worst, streak)
            else:
                streak = 0
        finals.append(total)
        drawdowns.append(max_dd)
        worst_streaks.append(worst)
        if ruin_threshold_r is not None and total <= ruin_threshold_r:
            ruin += 1
    return {
        "runs": float(runs),
        "trades_per_run": float(n),
        "final_r_p05": percentile(finals, 5),
        "final_r_p25": percentile(finals, 25),
        "final_r_p50": percentile(finals, 50),
        "final_r_p75": percentile(finals, 75),
        "final_r_p95": percentile(finals, 95),
        "max_dd_r_p50": percentile(drawdowns, 50),
        "max_dd_r_p95": percentile(drawdowns, 95),
        "worst_loss_streak_p95": percentile(worst_streaks, 95),
        "prob_negative": sum(1 for v in finals if v < 0.0) / runs,
        "prob_ruin": ruin / runs if ruin_threshold_r is not None else 0.0,
    }


def bootstrap_mean(
    values: Sequence[float], runs: int = 2000, seed: int = 11, confidence: float = 0.95
) -> dict[str, float]:
    if not values:
        raise ValueError("empty values")
    rng = random.Random(seed)
    means = []
    for _ in range(runs):
        means.append(sum(values[rng.randrange(len(values))] for _ in range(len(values))) / len(values))
    alpha = (1.0 - confidence) / 2.0 * 100.0
    return {
        "mean": sum(values) / len(values),
        "low": percentile(means, alpha),
        "high": percentile(means, 100.0 - alpha),
        "confidence": confidence,
    }
