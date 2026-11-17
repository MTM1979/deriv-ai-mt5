"""Build a supervised dataset from OHLCV bars.

The feature vector comes from ``features.build`` (the exact EA port).
The label comes from ``models.labels`` (triple barrier).  Only bars in
which the EA would be allowed to trade are emitted: an enabled session
window, a profile that permits that window, and full indicator warmup.

Deliberate research simplifications, all surfaced in the report:

* the news features are neutral (``minutes_to_event=9999``,
  ``event_impact=0``) unless an ``event_lookup`` is supplied;
* the live spread is not in OHLCV history, so ``default_spread_points``
  is used unless ``spread_series`` is supplied;
* both directions are emitted per bar.  Strategy-specific gating stays
  in the EA, which applies the model only to actual candidates.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable, Sequence

from data.loader import SymbolRecord
from features.build import CandidateView, SymbolView, build_features
from features.indicators import (
    Bars,
    IndicatorConfig,
    SessionConfig,
    SessionEngine,
    RangeTable,
    align_htf,
    compute_series,
    day_floor,
    profile_allows_session,
    snapshot_at,
)
from models.labels import LabelConfig, TradeLabel, label_trade

__all__ = [
    "DatasetRow",
    "Dataset",
    "DatasetOptions",
    "build_dataset",
]


@dataclass(frozen=True)
class DatasetOptions:
    indicator: IndicatorConfig = field(default_factory=IndicatorConfig)
    session: SessionConfig = field(default_factory=SessionConfig)
    label: LabelConfig = field(default_factory=LabelConfig)
    day_roll_hour_utc: int = 0
    default_spread_points: float = 1.0
    min_index: int | None = None
    include_flat_timeouts: bool = True
    point: float | None = None

    def __post_init__(self) -> None:
        if not 0 <= int(self.day_roll_hour_utc) <= 23:
            raise ValueError("day_roll_hour_utc must be 0..23")
        if self.default_spread_points < 0.0:
            raise ValueError("default_spread_points must be >= 0")
        if self.point is not None and self.point <= 0.0:
            raise ValueError("point must be positive")


@dataclass(frozen=True)
class DatasetRow:
    symbol: str
    asset_class: str
    time: datetime
    index: int
    direction: int
    label: int
    outcome: str
    r_multiple: float
    bars_held: int
    mfe_r: float
    mae_r: float
    session_state: str
    minutes_since_open: int


@dataclass
class Dataset:
    features: list[list[float]] = field(default_factory=list)
    labels: list[int] = field(default_factory=list)
    rows: list[DatasetRow] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.labels)

    def add(self, features: Sequence[float], row: DatasetRow) -> None:
        self.features.append(list(features))
        self.labels.append(int(row.label))
        self.rows.append(row)

    def r_multiples(self) -> list[float]:
        return [row.r_multiple for row in self.rows]

    def by_asset(self) -> dict[str, "Dataset"]:
        groups: dict[str, Dataset] = {}
        for features, row in zip(self.features, self.rows):
            groups.setdefault(row.asset_class, Dataset()).add(features, row)
        return groups

    def summary(self) -> dict[str, object]:
        if not self.rows:
            return {"rows": 0}
        positives = sum(self.labels)
        outcomes: dict[str, int] = {}
        for row in self.rows:
            outcomes[row.outcome] = outcomes.get(row.outcome, 0) + 1
        return {
            "rows": len(self.rows),
            "positives": positives,
            "positive_rate": positives / len(self.rows),
            "outcomes": outcomes,
            "mean_r": sum(r.r_multiple for r in self.rows) / len(self.rows),
        }


def build_dataset(
    bars: Bars,
    symbol: SymbolRecord,
    *,
    htf_bars: Bars | None = None,
    range_bars: Bars | None = None,
    options: DatasetOptions | None = None,
    event_lookup: Callable[[datetime], tuple[int, int]] | None = None,
    spread_series: Sequence[float] | None = None,
) -> Dataset:
    """Generate labelled feature rows for one symbol."""
    options = options or DatasetOptions()
    cfg = options.indicator
    if spread_series is not None and len(spread_series) != len(bars):
        raise ValueError("spread_series must align with bars")
    if htf_bars is None:
        htf_bars = bars
    if range_bars is None:
        range_bars = bars

    series = compute_series(bars, cfg)
    htf = align_htf(bars, htf_bars, cfg)
    ranges = RangeTable(range_bars)
    sessions = SessionEngine(options.session)

    start = options.min_index
    if start is None:
        start = max(cfg.min_bars_required, 60)
    start = max(int(start), 12)
    point = options.point if options.point is not None else _point_of(bars)
    symbol_view = SymbolView(point=point, max_spread_points=int(symbol.max_spread_points))

    dataset = Dataset()
    for index in range(start, len(bars) - 1):
        stamp = bars.time[index]
        ctx = sessions.update(stamp)
        if not ctx.trading_allowed:
            continue
        if symbol.session_profile and not profile_allows_session(symbol.session_profile, ctx.state):
            continue
        anchor = day_floor(stamp, options.day_roll_hour_utc)
        try:
            snapshot = snapshot_at(
                index, series, cfg, ranges, htf, ctx.session_start_utc, anchor
            )
        except ValueError:
            # Warmup or missing range data: skip this bar, never guess.
            continue
        minutes_to_event, event_impact = (9999, 0)
        if event_lookup is not None:
            minutes_to_event, event_impact = event_lookup(stamp)
        spread = (
            float(spread_series[index])
            if spread_series is not None
            else float(options.default_spread_points)
        )
        for direction in (1, -1):
            candidate = CandidateView(
                direction=direction,
                spread_points=spread,
                minutes_since_open=ctx.minutes_since_open,
                minutes_to_event=int(minutes_to_event),
                event_impact=int(event_impact),
            )
            try:
                features = build_features(snapshot, candidate, symbol_view)
            except ValueError:
                continue
            label = label_trade(bars, index, direction, snapshot.atr, options.label)
            if label is None:
                continue
            if label.outcome == "timeout" and not options.include_flat_timeouts:
                continue
            dataset.add(
                features,
                DatasetRow(
                    symbol=symbol.symbol,
                    asset_class=symbol.asset_class,
                    time=stamp,
                    index=index,
                    direction=direction,
                    label=label.label,
                    outcome=label.outcome,
                    r_multiple=label.r_multiple,
                    bars_held=label.bars_held,
                    mfe_r=label.mfe_r,
                    mae_r=label.mae_r,
                    session_state=ctx.state,
                    minutes_since_open=ctx.minutes_since_open,
                ),
            )
    return dataset


def _point_of(bars: Bars) -> float:
    """Infer a tick size from price precision.

    MetaTrader prices are decimal, so the smallest published increment is
    a defensible proxy.  The EA uses the broker's real ``SYMBOL_POINT``;
    research only needs a scale for the ATR and spread ratios.
    """
    sample = bars.close[min(len(bars) - 1, 500)]
    text = f"{sample:.10f}".rstrip("0")
    decimals = len(text.split(".")[1]) if "." in text else 0
    decimals = max(1, min(decimals, 8))
    return 10.0 ** (-decimals)
