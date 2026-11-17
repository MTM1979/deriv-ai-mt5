"""Shared fixtures for the research-pipeline tests."""

from __future__ import annotations

import math
import random
from datetime import datetime, timedelta

from features.indicators import Bars, IndicatorConfig, SnapshotView

__all__ = ["synthetic_bars", "golden_snapshot", "fast_indicator_config", "make_bars"]


def make_bars(rows: list[tuple[float, float, float, float, float]], start: datetime | None = None) -> Bars:
    start = start or datetime(2024, 1, 2, 7, 0)
    times = [start + timedelta(minutes=15 * i) for i in range(len(rows))]
    return Bars(
        time=times,
        open=[r[0] for r in rows],
        high=[r[1] for r in rows],
        low=[r[2] for r in rows],
        close=[r[3] for r in rows],
        volume=[r[4] for r in rows],
    )


def synthetic_bars(
    count: int = 700,
    *,
    seed: int = 17,
    base: float = 1.10000,
    step_minutes: int = 15,
    start: datetime | None = None,
    volatility: float = 0.0009,
) -> Bars:
    """A deterministic random walk with enough structure to label."""
    rng = random.Random(seed)
    start = start or datetime(2024, 1, 2, 7, 0)
    times: list[datetime] = []
    opens: list[float] = []
    highs: list[float] = []
    lows: list[float] = []
    closes: list[float] = []
    volumes: list[float] = []
    price = base
    drift = 0.0
    for i in range(count):
        if i % 120 == 0:
            drift = rng.uniform(-0.00004, 0.00004)
        change = drift + rng.gauss(0.0, volatility)
        open_price = price
        close_price = max(0.0001, open_price + change)
        wick = abs(rng.gauss(0.0, volatility)) * 0.8
        high = max(open_price, close_price) + wick
        low = max(0.00005, min(open_price, close_price) - wick)
        times.append(start + timedelta(minutes=step_minutes * i))
        opens.append(open_price)
        highs.append(high)
        lows.append(low)
        closes.append(close_price)
        volumes.append(float(rng.randint(30, 400)))
        price = close_price
    return Bars(times, opens, highs, lows, closes, volumes)


def fast_indicator_config() -> IndicatorConfig:
    """Short warmups so tests run on a few hundred bars."""
    return IndicatorConfig(
        ema_fast=10,
        ema_mid=20,
        ema_slow=40,
        rsi_period=14,
        macd_fast=12,
        macd_slow=26,
        macd_signal=9,
        bb_period=20,
        bb_deviation=2.0,
        adx_period=14,
        atr_period=14,
        atr_percentile_lookback=60,
        volume_lookback=20,
        swing_lookback=20,
        swing_fractal=2,
        min_bars_required=60,
    )


def golden_snapshot(**overrides) -> SnapshotView:
    """A snapshot whose feature vector was computed by hand (see tests)."""
    values = dict(
        valid=True,
        bar_time=datetime(2024, 1, 2, 12, 0),
        open=100.0,
        high=100.5,
        low=99.5,
        close=100.0,
        ret1=0.01,
        ret3=0.02,
        ret12=0.03,
        atr=1.0,
        atr_percentile=0.5,
        ema_fast=100.0,
        ema_mid=100.0,
        ema_slow=100.0,
        ema_slow_slope=0.0,
        rsi=50.0,
        macd_hist=0.0,
        macd_hist_prev=0.0,
        bb_upper=101.0,
        bb_middle=100.0,
        bb_lower=99.0,
        bb_width=2.0,
        adx=50.0,
        di_plus=25.0,
        di_minus=25.0,
        session_high=101.0,
        session_low=99.0,
        day_high=102.0,
        day_low=98.0,
        prior_day_high=101.5,
        prior_day_low=98.5,
        vwap=100.0,
        htf_close=100.0,
        htf_ema_slow=100.0,
        htf_rsi=50.0,
        htf_atr=1.0,
        volume_ratio=1.0,
        sweep_high=False,
        sweep_low=True,
        last_high=(100.5, 100.4, 100.3, 100.2, 100.1, 100.0),
        last_low=(99.5, 99.4, 99.3, 99.2, 99.1, 99.0),
        last_close=(100.0, 100.0, 100.0, 100.0, 100.0, 100.0),
    )
    values.update(overrides)
    return SnapshotView(**values)


def finite(value: float) -> bool:
    return math.isfinite(value)
