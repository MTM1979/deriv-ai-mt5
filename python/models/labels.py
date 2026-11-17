"""Triple-barrier labels for the ONNX classifier.

A label answers one question: *if the EA entered this signal at the next
bar's open with this ATR stop and this R multiple, would price reach the
target before the stop within the horizon?*

Rules that matter for honesty:

* Entry is the **next** bar's open (``entry_at_next_open``).  Using the
  signal bar's close would leak the bar that produced the signal.
* If the stop and the target are both touched inside the same bar, the
  stop wins by default.  Intrabar ordering is unknown, so the
  conservative branch is the only defensible one.  ``ambiguity`` can be
  set to ``"target_first"`` for a sensitivity run, never for production.
* A timeout is labelled ``0`` (the target was not reached) but keeps the
  realized R so evaluation can distinguish "flat" from "stopped".
* Bars with no ATR or an incomplete horizon are returned as ``None`` and
  must be dropped by the caller.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Sequence

from features.indicators import Bars

__all__ = ["LabelConfig", "TradeLabel", "label_trade", "horizon_end"]


@dataclass(frozen=True)
class LabelConfig:
    atr_stop_mult: float = 1.5
    rr_target: float = 1.5
    horizon_bars: int = 24
    entry_at_next_open: bool = True
    ambiguity: str = "stop_first"

    def __post_init__(self) -> None:
        if self.atr_stop_mult <= 0.0:
            raise ValueError("atr_stop_mult must be positive")
        if self.rr_target <= 0.0:
            raise ValueError("rr_target must be positive")
        if not 1 <= int(self.horizon_bars) <= 2000:
            raise ValueError("horizon_bars must be 1..2000")
        if self.ambiguity not in ("stop_first", "target_first"):
            raise ValueError("ambiguity must be 'stop_first' or 'target_first'")


@dataclass(frozen=True)
class TradeLabel:
    index: int
    direction: int
    entry_index: int
    entry_price: float
    stop_price: float
    target_price: float
    label: int
    outcome: str
    exit_index: int
    exit_price: float
    r_multiple: float
    mfe_r: float
    mae_r: float
    bars_held: int


def horizon_end(index: int, count: int, cfg: LabelConfig) -> int:
    start = index + (1 if cfg.entry_at_next_open else 0)
    return min(count, start + int(cfg.horizon_bars))


def label_trade(
    bars: Bars,
    index: int,
    direction: int,
    atr_value: float,
    cfg: LabelConfig | None = None,
) -> TradeLabel | None:
    """Label one candidate, or return ``None`` when it cannot be labelled."""
    cfg = cfg or LabelConfig()
    if direction not in (-1, 1):
        raise ValueError("direction must be -1 or 1")
    count = len(bars)
    if index < 0 or index >= count:
        raise IndexError("signal index out of range")
    if not math.isfinite(atr_value) or atr_value <= 0.0:
        return None
    entry_index = index + (1 if cfg.entry_at_next_open else 0)
    if entry_index >= count:
        return None
    entry = float(bars.open[entry_index]) if cfg.entry_at_next_open else float(bars.close[index])
    if entry <= 0.0:
        return None
    risk = cfg.atr_stop_mult * float(atr_value)
    if risk <= 0.0:
        return None
    if direction > 0:
        stop = entry - risk
        target = entry + cfg.rr_target * risk
    else:
        stop = entry + risk
        target = entry - cfg.rr_target * risk
    if stop <= 0.0:
        return None

    end = horizon_end(index, count, cfg)
    if end <= entry_index:
        return None

    mfe_r = 0.0
    mae_r = 0.0
    for j in range(entry_index, end):
        high = float(bars.high[j])
        low = float(bars.low[j])
        hit_stop = low <= stop if direction > 0 else high >= stop
        hit_target = high >= target if direction > 0 else low <= target
        if hit_stop and hit_target:
            hit_stop = cfg.ambiguity == "stop_first"
            hit_target = not hit_stop
        # Excursions are measured before resolving the bar, using the
        # worst-case ordering when both levels are inside the bar.
        favorable = (high - entry) if direction > 0 else (entry - low)
        adverse = (entry - low) if direction > 0 else (high - entry)
        mfe_r = max(mfe_r, favorable / risk)
        mae_r = max(mae_r, adverse / risk)
        if hit_target:
            return TradeLabel(
                index=index,
                direction=direction,
                entry_index=entry_index,
                entry_price=entry,
                stop_price=stop,
                target_price=target,
                label=1,
                outcome="target",
                exit_index=j,
                exit_price=target,
                r_multiple=cfg.rr_target,
                mfe_r=max(mfe_r, cfg.rr_target),
                mae_r=mae_r,
                bars_held=j - entry_index + 1,
            )
        if hit_stop:
            return TradeLabel(
                index=index,
                direction=direction,
                entry_index=entry_index,
                entry_price=entry,
                stop_price=stop,
                target_price=target,
                label=0,
                outcome="stop",
                exit_index=j,
                exit_price=stop,
                r_multiple=-1.0,
                mfe_r=mfe_r,
                mae_r=max(mae_r, 1.0),
                bars_held=j - entry_index + 1,
            )

    last = end - 1
    exit_price = float(bars.close[last])
    realized = (exit_price - entry) * direction / risk
    return TradeLabel(
        index=index,
        direction=direction,
        entry_index=entry_index,
        entry_price=entry,
        stop_price=stop,
        target_price=target,
        label=0,
        outcome="timeout",
        exit_index=last,
        exit_price=exit_price,
        r_multiple=realized,
        mfe_r=mfe_r,
        mae_r=mae_r,
        bars_held=last - entry_index + 1,
    )


def summarize(labels: Sequence[TradeLabel]) -> dict[str, float | int]:
    """Small descriptive summary used by tests and reports."""
    if not labels:
        return {"count": 0}
    wins = sum(1 for lab in labels if lab.outcome == "target")
    stops = sum(1 for lab in labels if lab.outcome == "stop")
    timeouts = sum(1 for lab in labels if lab.outcome == "timeout")
    return {
        "count": len(labels),
        "target": wins,
        "stop": stops,
        "timeout": timeouts,
        "win_rate": wins / len(labels),
        "avg_r": sum(lab.r_multiple for lab in labels) / len(labels),
        "avg_bars": sum(lab.bars_held for lab in labels) / len(labels),
    }
