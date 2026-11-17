"""Indicator and session math used by the research pipeline.

Everything here is pure Python (standard library only) so the research
pipeline can run on a bare interpreter.  The functions are deliberately
close to the MetaTrader 5 implementations used by ``Indicators.mqh``:

* EMAs are seeded with a simple average and then smoothed recursively.
* RSI, ATR and ADX use Wilder smoothing.
* Bollinger bands use the population standard deviation.
* Session state and day anchors are ported from ``Sessions.mqh`` and
  ``Utils.mqh`` so offline research sees the same UTC windows.

They are **not** bit-identical to MetaTrader's indicator buffers.  MT5
seeds EMAs from the first ever bar and computes them on every history
bar, whereas this module works on the slice of history it is given.
Long warmups converge to the same values; the first ``period`` bars do
not.  Exact parity of the *feature vector* is enforced separately in
``features.build`` against snapshots exported by
``MQL5/Scripts/ExportFeatureSamples.mq5``.
"""

from __future__ import annotations

import bisect
import math
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Iterable, Sequence

__all__ = [
    "sma",
    "ema",
    "rolling_std",
    "rsi",
    "true_range",
    "atr",
    "macd",
    "bollinger",
    "adx",
    "percentile_rank",
    "wilder_smooth",
    "IndicatorConfig",
    "SeriesBundle",
    "compute_series",
    "SessionConfig",
    "SessionContext",
    "SessionEngine",
    "profile_allows_session",
    "minute_in_window",
    "day_floor",
    "RangeTable",
    "HtfView",
    "SnapshotView",
    "snapshot_at",
]

Number = float


# ---------------------------------------------------------------------------
# Primitive rolling functions.  Every function returns a list with the same
# length as the input; entries that are not yet defined are ``None``.
# ---------------------------------------------------------------------------
def sma(values: Sequence[float], period: int) -> list[float | None]:
    period = int(period)
    if period < 1:
        raise ValueError("period must be >= 1")
    out: list[float | None] = [None] * len(values)
    running = 0.0
    for i, value in enumerate(values):
        running += float(value)
        if i >= period:
            running -= float(values[i - period])
        if i >= period - 1:
            out[i] = running / period
    return out


def ema(values: Sequence[float], period: int) -> list[float | None]:
    period = int(period)
    if period < 1:
        raise ValueError("period must be >= 1")
    out: list[float | None] = [None] * len(values)
    if len(values) < period:
        return out
    seed = sum(float(v) for v in values[:period]) / period
    out[period - 1] = seed
    alpha = 2.0 / (period + 1.0)
    previous = seed
    for i in range(period, len(values)):
        previous = alpha * float(values[i]) + (1.0 - alpha) * previous
        out[i] = previous
    return out


def rolling_std(values: Sequence[float], period: int) -> list[float | None]:
    period = int(period)
    if period < 1:
        raise ValueError("period must be >= 1")
    out: list[float | None] = [None] * len(values)
    window: list[float] = []
    total = 0.0
    total_sq = 0.0
    for i, value in enumerate(values):
        v = float(value)
        window.append(v)
        total += v
        total_sq += v * v
        if len(window) > period:
            old = window.pop(0)
            total -= old
            total_sq -= old * old
        if len(window) == period:
            mean = total / period
            variance = max(0.0, total_sq / period - mean * mean)
            out[i] = math.sqrt(variance)
    return out


def wilder_smooth(values: Sequence[float | None], period: int) -> list[float | None]:
    """Wilder's smoothing, seeded with the mean of the first ``period`` values."""
    period = int(period)
    if period < 1:
        raise ValueError("period must be >= 1")
    out: list[float | None] = [None] * len(values)
    seed: list[float] = []
    previous: float | None = None
    for i, value in enumerate(values):
        if value is None:
            continue
        if previous is None:
            seed.append(float(value))
            if len(seed) == period:
                previous = sum(seed) / period
                out[i] = previous
            continue
        previous = (previous * (period - 1) + float(value)) / period
        out[i] = previous
    return out


def rsi(values: Sequence[float], period: int) -> list[float | None]:
    period = int(period)
    gains: list[float | None] = [None] * len(values)
    losses: list[float | None] = [None] * len(values)
    for i in range(1, len(values)):
        change = float(values[i]) - float(values[i - 1])
        gains[i] = max(change, 0.0)
        losses[i] = max(-change, 0.0)
    avg_gain = wilder_smooth(gains, period)
    avg_loss = wilder_smooth(losses, period)
    out: list[float | None] = [None] * len(values)
    for i in range(len(values)):
        g = avg_gain[i]
        l = avg_loss[i]
        if g is None or l is None:
            continue
        if l <= 0.0:
            out[i] = 100.0 if g > 0.0 else 50.0
        else:
            out[i] = 100.0 - 100.0 / (1.0 + g / l)
    return out


def true_range(
    highs: Sequence[float], lows: Sequence[float], closes: Sequence[float]
) -> list[float | None]:
    out: list[float | None] = [None] * len(highs)
    previous_close: float | None = None
    for i in range(len(highs)):
        high = float(highs[i])
        low = float(lows[i])
        if previous_close is None:
            out[i] = high - low
        else:
            out[i] = max(high - low, abs(high - previous_close), abs(low - previous_close))
        previous_close = float(closes[i])
    return out


def atr(
    highs: Sequence[float], lows: Sequence[float], closes: Sequence[float], period: int
) -> list[float | None]:
    tr = true_range(highs, lows, closes)
    return wilder_smooth(tr, period)


def macd(
    closes: Sequence[float], fast: int = 12, slow: int = 26, signal: int = 9
) -> tuple[list[float | None], list[float | None], list[float | None]]:
    fast_ema = ema(closes, fast)
    slow_ema = ema(closes, slow)
    main: list[float | None] = [None] * len(closes)
    for i in range(len(closes)):
        f = fast_ema[i]
        s = slow_ema[i]
        if f is not None and s is not None:
            main[i] = f - s
    signal_line = _ema_optional(main, signal)
    hist: list[float | None] = [None] * len(closes)
    for i in range(len(closes)):
        m = main[i]
        s = signal_line[i]
        if m is not None and s is not None:
            hist[i] = m - s
    return main, signal_line, hist


def _ema_optional(values: Sequence[float | None], period: int) -> list[float | None]:
    """EMA over a series that may start with ``None`` values."""
    out: list[float | None] = [None] * len(values)
    seed: list[float] = []
    previous: float | None = None
    alpha = 2.0 / (period + 1.0)
    for i, value in enumerate(values):
        if value is None:
            continue
        if previous is None:
            seed.append(float(value))
            if len(seed) == period:
                previous = sum(seed) / period
                out[i] = previous
            continue
        previous = alpha * float(value) + (1.0 - alpha) * previous
        out[i] = previous
    return out


def bollinger(
    closes: Sequence[float], period: int, deviation: float
) -> tuple[list[float | None], list[float | None], list[float | None], list[float | None]]:
    middle = sma(closes, period)
    std = rolling_std(closes, period)
    upper: list[float | None] = [None] * len(closes)
    lower: list[float | None] = [None] * len(closes)
    width: list[float | None] = [None] * len(closes)
    for i in range(len(closes)):
        m = middle[i]
        s = std[i]
        if m is None or s is None:
            continue
        upper[i] = m + deviation * s
        lower[i] = m - deviation * s
        width[i] = upper[i] - lower[i]  # type: ignore[operator]
    return upper, middle, lower, width


def adx(
    highs: Sequence[float],
    lows: Sequence[float],
    closes: Sequence[float],
    period: int,
) -> tuple[list[float | None], list[float | None], list[float | None]]:
    """Wilder's ADX with +DI/-DI, matching the MT5 buffer layout."""
    n = len(highs)
    plus_dm: list[float | None] = [None] * n
    minus_dm: list[float | None] = [None] * n
    tr = true_range(highs, lows, closes)
    for i in range(1, n):
        up = float(highs[i]) - float(highs[i - 1])
        down = float(lows[i - 1]) - float(lows[i])
        plus_dm[i] = up if (up > down and up > 0.0) else 0.0
        minus_dm[i] = down if (down > up and down > 0.0) else 0.0
    tr_s = wilder_smooth(tr, period)
    plus_s = wilder_smooth(plus_dm, period)
    minus_s = wilder_smooth(minus_dm, period)
    di_plus: list[float | None] = [None] * n
    di_minus: list[float | None] = [None] * n
    dx: list[float | None] = [None] * n
    for i in range(n):
        t = tr_s[i]
        p = plus_s[i]
        m = minus_s[i]
        if t is None or p is None or m is None or t <= 0.0:
            continue
        dp = 100.0 * p / t
        dm = 100.0 * m / t
        di_plus[i] = dp
        di_minus[i] = dm
        total = dp + dm
        dx[i] = 100.0 * abs(dp - dm) / total if total > 0.0 else 0.0
    adx_values = wilder_smooth(dx, period)
    return adx_values, di_plus, di_minus


def percentile_rank(values: Sequence[float], current: float, minimum: int = 20) -> float:
    """Share of ``values`` that are <= ``current`` (MQL5 semantics)."""
    n = len(values)
    if n < minimum:
        return -1.0
    below = 0
    for value in values:
        if math.isfinite(value) and value <= current:
            below += 1
    return below / n


# ---------------------------------------------------------------------------
# UTC session engine (port of Sessions.mqh)
# ---------------------------------------------------------------------------
def minute_in_window(minute: int, start_min: int, end_min: int) -> bool:
    s = start_min % 1440
    e = end_min % 1440
    m = minute % 1440
    if s == e:
        return True
    if s < e:
        return s <= m < e
    return m >= s or m < e


def day_floor(utc: datetime, roll_hour_utc: int = 0) -> datetime:
    midnight = utc.replace(hour=0, minute=0, second=0, microsecond=0)
    shift = max(0, min(23, int(roll_hour_utc)))
    if (utc - midnight).total_seconds() < shift * 3600:
        midnight -= timedelta(days=1)
    return midnight + timedelta(hours=shift)


@dataclass
class SessionConfig:
    asian_start_hour: int = 0
    asian_start_min: int = 0
    asian_end_hour: int = 8
    asian_end_min: int = 0
    london_open_hour: int = 7
    london_open_min: int = 0
    ny_open_hour: int = 13
    ny_open_min: int = 30
    rollover_start_hour: int = 20
    rollover_start_min: int = 45
    rollover_end_hour: int = 21
    rollover_end_min: int = 15
    opening_range_minutes: int = 30
    preopen_minutes: int = 15
    enable_asian: bool = True
    enable_london: bool = True
    enable_ny: bool = True
    risk_scale_asian: float = 0.50
    risk_scale_open: float = 1.00
    risk_scale_core: float = 0.90
    risk_scale_preopen: float = 0.50


@dataclass(frozen=True)
class SessionContext:
    state: str
    utc_now: datetime
    session_start_utc: datetime | None
    minutes_since_open: int
    trading_allowed: bool
    risk_scale: float

    @property
    def is_open_window(self) -> bool:
        return self.state in (
            "london_open",
            "london_core",
            "ny_open",
            "ny_core",
        )


class SessionEngine:
    """Stateless port of ``CSessionEngine::Update``."""

    def __init__(self, config: SessionConfig | None = None) -> None:
        self.config = config or SessionConfig()
        self._validate()

    def _validate(self) -> None:
        c = self.config
        for value in (
            c.asian_start_hour,
            c.asian_end_hour,
            c.london_open_hour,
            c.ny_open_hour,
            c.rollover_start_hour,
            c.rollover_end_hour,
        ):
            if not 0 <= int(value) <= 23:
                raise ValueError("session hours must be within 0..23")
        if not 5 <= int(c.opening_range_minutes) <= 180:
            raise ValueError("opening_range_minutes must be 5..180")
        if not 0 <= int(c.preopen_minutes) <= 120:
            raise ValueError("preopen_minutes must be 0..120")
        london = c.london_open_hour * 60 + c.london_open_min
        ny = c.ny_open_hour * 60 + c.ny_open_min
        if london >= ny:
            raise ValueError("london_open must precede ny_open")

    def update(self, utc_now: datetime) -> SessionContext:
        c = self.config
        minute = utc_now.hour * 60 + utc_now.minute
        asian_s = c.asian_start_hour * 60 + c.asian_start_min
        asian_e = c.asian_end_hour * 60 + c.asian_end_min
        london_s = c.london_open_hour * 60 + c.london_open_min
        ny_s = c.ny_open_hour * 60 + c.ny_open_min
        roll_s = c.rollover_start_hour * 60 + c.rollover_start_min
        roll_e = c.rollover_end_hour * 60 + c.rollover_end_min
        or_min = c.opening_range_minutes
        pre = c.preopen_minutes
        london_or_end = min(1439, london_s + or_min)
        ny_or_end = min(1439, ny_s + or_min)
        london_core_end = max(ny_s - pre, london_or_end)
        ny_core_end = roll_s if roll_s > ny_or_end else 1440

        state = "closed"
        start: datetime | None = None

        def start_today(start_min: int, forward: bool = False) -> datetime:
            midnight = utc_now.replace(hour=0, minute=0, second=0, microsecond=0)
            candidate = midnight + timedelta(minutes=start_min)
            if forward:
                if candidate < utc_now:
                    candidate += timedelta(days=1)
            elif candidate > utc_now:
                candidate -= timedelta(days=1)
            return candidate

        if minute_in_window(minute, roll_s, roll_e):
            state = "rollover"
            start = start_today(roll_s)
        elif pre > 0 and minute_in_window(minute, london_s - pre, london_s):
            state = "london_preopen"
            start = start_today(london_s, forward=True)
        elif london_s <= minute < london_or_end:
            state = "london_open"
            start = start_today(london_s)
        elif london_or_end <= minute < london_core_end:
            state = "london_core"
            start = start_today(london_s)
        elif pre > 0 and ny_s - pre <= minute < ny_s:
            state = "ny_preopen"
            start = start_today(ny_s, forward=True)
        elif ny_s <= minute < ny_or_end:
            state = "ny_open"
            start = start_today(ny_s)
        elif ny_or_end <= minute < ny_core_end:
            state = "ny_core"
            start = start_today(ny_s)
        elif minute_in_window(minute, asian_s, asian_e):
            state = "asian"
            start = start_today(asian_s)

        minutes_since = 0
        if start is not None:
            minutes_since = max(0, int((utc_now - start).total_seconds() // 60))
        allowed = self._trading_allowed(state)
        return SessionContext(
            state=state,
            utc_now=utc_now,
            session_start_utc=start,
            minutes_since_open=minutes_since,
            trading_allowed=allowed,
            risk_scale=self._risk_scale(state),
        )

    def _trading_allowed(self, state: str) -> bool:
        c = self.config
        if state == "asian":
            return c.enable_asian
        if state in ("london_open", "london_core"):
            return c.enable_london
        if state in ("ny_open", "ny_core"):
            return c.enable_ny
        return False

    def _risk_scale(self, state: str) -> float:
        c = self.config
        if state == "asian":
            return _clamp(c.risk_scale_asian, 0.0, 1.5) if c.enable_asian else 0.0
        if state in ("london_preopen", "ny_preopen"):
            return _clamp(c.risk_scale_preopen, 0.0, 1.5)
        if state in ("london_open", "ny_open"):
            return _clamp(c.risk_scale_open, 0.0, 1.5)
        if state in ("london_core", "ny_core"):
            return _clamp(c.risk_scale_core, 0.0, 1.5)
        return 0.0


def profile_allows_session(profile: str, state: str) -> bool:
    """Port of ``ProfileAllowsSession``; unknown profiles fail closed."""
    p = (profile or "").strip().lower()
    london = state in ("london_open", "london_core", "london_preopen")
    ny = state in ("ny_open", "ny_core", "ny_preopen")
    asian = state == "asian"
    if p in ("", "all", "any"):
        return state not in ("closed", "rollover")
    if p in ("london_ny", "london_newyork"):
        return london or ny
    if p in ("tokyo_london_ny", "asia_london_ny", "all_sessions"):
        return asian or london or ny
    if p in ("us_cash", "us", "newyork"):
        return state in ("ny_open", "ny_core")
    if p in ("europe_cash", "europe", "london"):
        return state in ("london_open", "london_core")
    if p in ("asia", "asian", "tokyo"):
        return asian
    return False


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, float(value)))


# ---------------------------------------------------------------------------
# Bar containers and range lookups
# ---------------------------------------------------------------------------
@dataclass
class Bars:
    """Column-oriented OHLCV data with UTC timestamps."""

    time: list[datetime]
    open: list[float]
    high: list[float]
    low: list[float]
    close: list[float]
    volume: list[float]

    def __post_init__(self) -> None:
        n = len(self.time)
        for name in ("open", "high", "low", "close", "volume"):
            if len(getattr(self, name)) != n:
                raise ValueError(f"column '{name}' has a different length")
        if n == 0:
            raise ValueError("bars are empty")
        last = None
        for stamp in self.time:
            if not isinstance(stamp, datetime):
                raise TypeError("bar timestamps must be datetime values")
            if last is not None and stamp <= last:
                raise ValueError("bar timestamps must be strictly increasing")
            last = stamp

    def __len__(self) -> int:
        return len(self.time)

    def slice(self, start: int, end: int) -> "Bars":
        return Bars(
            self.time[start:end],
            self.open[start:end],
            self.high[start:end],
            self.low[start:end],
            self.close[start:end],
            self.volume[start:end],
        )


class RangeTable:
    """High/low/VWAP over arbitrary UTC intervals (``RangeExtremes``)."""

    def __init__(self, bars: Bars) -> None:
        self.bars = bars

    def _index_at_or_before(self, when: datetime) -> int:
        return bisect.bisect_right(self.bars.time, when) - 1

    def range(self, start: datetime, end: datetime) -> tuple[float, float, int] | None:
        if end < start:
            return None
        first = self._index_at_or_before(start)
        last = self._index_at_or_before(end)
        if first < 0 or last < 0 or last < first:
            return None
        count = min(last - first + 1, 3000)
        first = last - count + 1
        high = max(self.bars.high[first:last + 1])
        low = min(self.bars.low[first:last + 1])
        if high <= 0.0 or low <= 0.0 or high < low:
            return None
        return high, low, count

    def vwap(self, start: datetime, end: datetime) -> float:
        if end < start:
            return 0.0
        first = self._index_at_or_before(start)
        last = self._index_at_or_before(end)
        if first < 0 or last < 0 or last < first:
            return 0.0
        count = min(last - first + 1, 3000)
        first = last - count + 1
        pv = 0.0
        volume = 0.0
        for i in range(first, last + 1):
            typical = (self.bars.high[i] + self.bars.low[i] + self.bars.close[i]) / 3.0
            v = self.bars.volume[i]
            if v <= 0.0:
                continue
            pv += typical * v
            volume += v
        return pv / volume if volume > 0.0 else 0.0


class HtfView:
    """Higher-timeframe values aligned to the last *closed* HTF bar."""

    def __init__(
        self,
        times: Sequence[datetime],
        close: Sequence[float],
        ema_fast: Sequence[float | None],
        ema_slow: Sequence[float | None],
        rsi: Sequence[float | None],
        atr: Sequence[float | None],
    ) -> None:
        self.times = list(times)
        self.close = list(close)
        self.ema_fast = list(ema_fast)
        self.ema_slow = list(ema_slow)
        self.rsi = list(rsi)
        self.atr = list(atr)

    def at(self, exec_time: datetime) -> int:
        """Index of the newest HTF bar strictly older than ``exec_time``."""
        return bisect.bisect_left(self.times, exec_time) - 1


# ---------------------------------------------------------------------------
# Series bundle
# ---------------------------------------------------------------------------
@dataclass
class IndicatorConfig:
    ema_fast: int = 21
    ema_mid: int = 50
    ema_slow: int = 200
    rsi_period: int = 14
    macd_fast: int = 12
    macd_slow: int = 26
    macd_signal: int = 9
    bb_period: int = 20
    bb_deviation: float = 2.0
    adx_period: int = 14
    atr_period: int = 14
    atr_percentile_lookback: int = 200
    volume_lookback: int = 20
    swing_lookback: int = 20
    swing_fractal: int = 2
    min_bars_required: int = 200


@dataclass
class SeriesBundle:
    bars: Bars
    ema_fast: list[float | None]
    ema_mid: list[float | None]
    ema_slow: list[float | None]
    ema_slow_slope: list[float | None]
    ema_fast_prev: list[float | None]
    rsi: list[float | None]
    macd_hist: list[float | None]
    macd_hist_prev: list[float | None]
    atr: list[float | None]
    atr_percentile: list[float | None]
    bb_upper: list[float | None]
    bb_middle: list[float | None]
    bb_lower: list[float | None]
    bb_width: list[float | None]
    adx: list[float | None]
    di_plus: list[float | None]
    di_minus: list[float | None]
    volume_ratio: list[float | None]
    ret1: list[float | None]
    ret3: list[float | None]
    ret12: list[float | None]
    swing_high: list[float | None]
    swing_low: list[float | None]


def compute_series(bars: Bars, cfg: IndicatorConfig | None = None) -> SeriesBundle:
    cfg = cfg or IndicatorConfig()
    closes = bars.close
    highs = bars.high
    lows = bars.low
    ema_fast = ema(closes, cfg.ema_fast)
    ema_mid = ema(closes, cfg.ema_mid)
    ema_slow = ema(closes, cfg.ema_slow)
    atr_series = atr(highs, lows, closes, cfg.atr_period)
    rsi_series = rsi(closes, cfg.rsi_period)
    _, _, hist = macd(closes, cfg.macd_fast, cfg.macd_slow, cfg.macd_signal)
    upper, middle, lower, width = bollinger(closes, cfg.bb_period, cfg.bb_deviation)
    adx_series, di_plus, di_minus = adx(highs, lows, closes, cfg.adx_period)

    n = len(bars)
    ema_slow_slope: list[float | None] = [None] * n
    ema_fast_prev: list[float | None] = [None] * n
    for i in range(n):
        if i >= 1:
            ema_fast_prev[i] = ema_fast[i - 1]
        old = ema_slow[i - 10] if i >= 10 else None
        current = ema_slow[i]
        a = atr_series[i]
        if old is not None and current is not None and a is not None and a > 0.0:
            ema_slow_slope[i] = (current - old) / (10.0 * a)

    atr_pct: list[float | None] = [None] * n
    lookback = max(60, int(cfg.atr_percentile_lookback))
    for i in range(n):
        if atr_series[i] is None:
            continue
        start = max(0, i - lookback + 1)
        window = [v for v in atr_series[start:i + 1] if v is not None]
        if len(window) < 20:
            continue
        rank = percentile_rank(window, atr_series[i])  # type: ignore[arg-type]
        atr_pct[i] = rank if rank >= 0.0 else None

    volume_ratio: list[float | None] = [None] * n
    for i in range(n):
        start = max(0, i - max(5, cfg.volume_lookback) + 1)
        window = bars.volume[start:i + 1]
        if len(window) < 5:
            continue
        average = sum(window) / len(window)
        volume_ratio[i] = bars.volume[i] / average if average > 0.0 else 1.0

    rets = {}
    for lag in (1, 3, 12):
        series: list[float | None] = [None] * n
        for i in range(n):
            if i >= lag and closes[i - lag] > 0.0:
                series[i] = closes[i] / closes[i - lag] - 1.0
        rets[lag] = series

    swing_high, swing_low = _swing_levels(bars, cfg)
    return SeriesBundle(
        bars=bars,
        ema_fast=ema_fast,
        ema_mid=ema_mid,
        ema_slow=ema_slow,
        ema_slow_slope=ema_slow_slope,
        ema_fast_prev=ema_fast_prev,
        rsi=rsi_series,
        macd_hist=hist,
        macd_hist_prev=[hist[i - 1] if i >= 1 else None for i in range(n)],
        atr=atr_series,
        atr_percentile=atr_pct,
        bb_upper=upper,
        bb_middle=middle,
        bb_lower=lower,
        bb_width=width,
        adx=adx_series,
        di_plus=di_plus,
        di_minus=di_minus,
        volume_ratio=volume_ratio,
        ret1=rets[1],
        ret3=rets[3],
        ret12=rets[12],
        swing_high=swing_high,
        swing_low=swing_low,
    )


def _swing_levels(bars: Bars, cfg: IndicatorConfig) -> tuple[list[float | None], list[float | None]]:
    """Most recent confirmed fractal high/low, or the window extreme."""
    n = len(bars)
    f = max(1, int(cfg.swing_fractal))
    lookback = max(2, int(cfg.swing_lookback))
    highs = bars.high
    lows = bars.low
    out_hi: list[float | None] = [None] * n
    out_lo: list[float | None] = [None] * n
    for i in range(n):
        end = i
        start = max(0, end - (lookback + 2 * f))
        if end - start < 2 * f + 2:
            continue
        found_hi = None
        found_lo = None
        # Search newest to oldest, exactly like SwingLevels().
        for j in range(end - f, start + f - 1, -1):
            if j - f < start or j + f > end:
                continue
            if found_hi is None and all(
                highs[j] >= highs[j - k] and highs[j] >= highs[j + k]
                for k in range(1, f + 1)
            ):
                found_hi = highs[j]
            if found_lo is None and all(
                lows[j] <= lows[j - k] and lows[j] <= lows[j + k]
                for k in range(1, f + 1)
            ):
                found_lo = lows[j]
            if found_hi is not None and found_lo is not None:
                break
        out_hi[i] = found_hi if found_hi is not None else max(highs[start:end + 1])
        out_lo[i] = found_lo if found_lo is not None else min(lows[start:end + 1])
    return out_hi, out_lo


# ---------------------------------------------------------------------------
# Snapshot at a closed bar
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class SnapshotView:
    """Values consumed by ``features.build.build_features``.

    Field names intentionally mirror ``IndicatorSnapshot`` in
    ``MQL5/Include/Indicators.mqh``.
    """

    valid: bool
    bar_time: datetime
    open: float
    high: float
    low: float
    close: float
    ret1: float
    ret3: float
    ret12: float
    atr: float
    atr_percentile: float
    ema_fast: float
    ema_mid: float
    ema_slow: float
    ema_slow_slope: float
    rsi: float
    macd_hist: float
    macd_hist_prev: float
    bb_upper: float
    bb_middle: float
    bb_lower: float
    bb_width: float
    adx: float
    di_plus: float
    di_minus: float
    session_high: float
    session_low: float
    day_high: float
    day_low: float
    prior_day_high: float
    prior_day_low: float
    vwap: float
    htf_close: float
    htf_ema_slow: float
    htf_rsi: float
    htf_atr: float
    volume_ratio: float
    sweep_high: bool
    sweep_low: bool
    last_high: tuple[float, ...]
    last_low: tuple[float, ...]
    last_close: tuple[float, ...]


def _value(series: Sequence[float | None], index: int) -> float:
    if index < 0 or index >= len(series):
        raise ValueError("series index out of range")
    value = series[index]
    if value is None:
        raise ValueError("indicator value unavailable")
    return float(value)


def snapshot_at(
    index: int,
    series: SeriesBundle,
    cfg: IndicatorConfig,
    range_table: RangeTable,
    htf: HtfView,
    session_start: datetime | None,
    day_start: datetime,
) -> SnapshotView:
    """Build a snapshot for a *closed* bar.

    ``index`` points at the bar whose close is being evaluated.  The
    caller is responsible for only requesting bars that have a full
    indicator warmup and for passing the session/day anchors that the
    EA would have used (``Sessions.mqh`` / ``DayFloor``).
    """
    bars = series.bars
    if index < 0 or index >= len(bars):
        raise IndexError("bar index out of range")
    if index < cfg.min_bars_required:
        raise ValueError("not enough bars for a snapshot")
    if index < 12:
        raise ValueError("not enough bars for returns")

    close = bars.close[index]
    if close <= 0.0:
        raise ValueError("non-positive close")
    snap_atr = _value(series.atr, index)
    if snap_atr <= 0.0:
        raise ValueError("ATR unavailable")
    ret1 = _value(series.ret1, index)
    ret3 = _value(series.ret3, index)
    ret12 = _value(series.ret12, index)
    atr_pct = _value(series.atr_percentile, index)
    ema_fast = _value(series.ema_fast, index)
    ema_mid = _value(series.ema_mid, index)
    ema_slow = _value(series.ema_slow, index)
    ema_slow_slope = _value(series.ema_slow_slope, index)
    rsi_value = _value(series.rsi, index)
    macd_hist = _value(series.macd_hist, index)
    macd_hist_prev = _value(series.macd_hist_prev, index)
    bb_upper = _value(series.bb_upper, index)
    bb_lower = _value(series.bb_lower, index)
    bb_middle = _value(series.bb_middle, index)
    bb_width = _value(series.bb_width, index)
    adx_value = _value(series.adx, index)
    di_plus = _value(series.di_plus, index)
    di_minus = _value(series.di_minus, index)
    volume_ratio = _value(series.volume_ratio, index)

    bar_time = bars.time[index]
    start = session_start if session_start is not None and session_start <= bar_time else day_start
    session_range = range_table.range(start, bar_time)
    if session_range is None:
        raise ValueError("session range unavailable")
    session_high, session_low, _ = session_range
    day_range = range_table.range(day_start, bar_time)
    if day_range is None:
        raise ValueError("day range unavailable")
    day_high, day_low, _ = day_range
    prior_range = range_table.range(
        day_start - timedelta(days=1), day_start - timedelta(seconds=1)
    )
    prior_day_high, prior_day_low = (prior_range[0], prior_range[1]) if prior_range else (0.0, 0.0)

    vwap = range_table.vwap(start, bar_time)
    if vwap <= 0.0:
        vwap = (session_high + session_low + close) / 3.0

    htf_index = htf.at(bar_time)
    if htf_index < 0:
        raise ValueError("higher timeframe unavailable")
    htf_close = float(htf.close[htf_index])
    htf_ema_slow = _value(htf.ema_slow, htf_index)
    htf_rsi = _value(htf.rsi, htf_index)
    htf_atr = _value(htf.atr, htf_index)

    last_high = tuple(float(bars.high[max(0, index - k)]) for k in range(6))
    last_low = tuple(float(bars.low[max(0, index - k)]) for k in range(6))
    last_close = tuple(float(bars.close[max(0, index - k)]) for k in range(6))

    sweep_high = False
    sweep_low = False
    if prior_day_high > 0.0 and prior_day_low > 0.0:
        tolerance = 0.10 * snap_atr
        for k in range(3):
            if last_high[k] > prior_day_high + tolerance and last_close[k] < prior_day_high:
                sweep_high = True
                break
        for k in range(3):
            if last_low[k] < prior_day_low - tolerance and last_close[k] > prior_day_low:
                sweep_low = True
                break

    return SnapshotView(
        valid=True,
        bar_time=bar_time,
        open=bars.open[index],
        high=bars.high[index],
        low=bars.low[index],
        close=close,
        ret1=ret1,
        ret3=ret3,
        ret12=ret12,
        atr=snap_atr,
        atr_percentile=atr_pct,
        ema_fast=ema_fast,
        ema_mid=ema_mid,
        ema_slow=ema_slow,
        ema_slow_slope=ema_slow_slope,
        rsi=rsi_value,
        macd_hist=macd_hist,
        macd_hist_prev=macd_hist_prev,
        bb_upper=bb_upper,
        bb_middle=bb_middle,
        bb_lower=bb_lower,
        bb_width=bb_width,
        adx=adx_value,
        di_plus=di_plus,
        di_minus=di_minus,
        session_high=session_high,
        session_low=session_low,
        day_high=day_high,
        day_low=day_low,
        prior_day_high=prior_day_high,
        prior_day_low=prior_day_low,
        vwap=vwap,
        htf_close=htf_close,
        htf_ema_slow=htf_ema_slow,
        htf_rsi=htf_rsi,
        htf_atr=htf_atr,
        volume_ratio=volume_ratio,
        sweep_high=sweep_high,
        sweep_low=sweep_low,
        last_high=last_high,
        last_low=last_low,
        last_close=last_close,
    )


def align_htf(exec_bars: Bars, htf_bars: Bars, cfg: IndicatorConfig) -> HtfView:
    """Compute HTF indicators and expose them for alignment by time."""
    htf_series = compute_series(htf_bars, cfg)
    return HtfView(
        times=htf_bars.time,
        close=htf_bars.close,
        ema_fast=htf_series.ema_fast,
        ema_slow=htf_series.ema_slow,
        rsi=htf_series.rsi,
        atr=htf_series.atr,
    )
