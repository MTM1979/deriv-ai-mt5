"""CSV loaders for bars and the EA's symbol configuration.

The research pipeline deliberately reads the *same* files the EA reads,
so a symbol renamed in ``deriv_symbols.csv`` cannot drift away from the
model that was trained for it.  Failures are explicit: a malformed row
raises ``DataError`` with the file, line number and column.
"""

from __future__ import annotations

import csv
import json
import math
import os
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Sequence

from features.indicators import Bars

__all__ = [
    "DataError",
    "SymbolRecord",
    "read_bars",
    "write_bars",
    "resample",
    "read_symbols",
    "read_json",
    "write_json_atomic",
    "asset_class_of",
]

ASSET_CLASSES = ("fx", "metal", "index")

_BAR_ALIASES = {
    "time": ("time", "date", "datetime", "timestamp", "bar_time"),
    "open": ("open", "o"),
    "high": ("high", "h"),
    "low": ("low", "l"),
    "close": ("close", "c", "last"),
    "volume": ("tick_volume", "tickvolume", "tick_vol", "volume", "vol", "v"),
    "spread": ("spread", "spread_points"),
}


class DataError(ValueError):
    """Raised for malformed or inconsistent input data."""


def _parse_time(value: str, where: str) -> datetime:
    text = (value or "").strip()
    if not text:
        raise DataError(f"{where}: empty timestamp")
    try:
        number = float(text)
    except ValueError:
        number = None
    if number is not None and number > 100_000_000:
        # MetaTrader epoch values are seconds; tolerate milliseconds.
        if number > 10_000_000_000:
            number /= 1000.0
        return datetime.fromtimestamp(number, tz=timezone.utc).replace(tzinfo=None)
    candidate = text.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(candidate)
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
        return parsed
    except ValueError:
        pass
    for fmt in (
        "%Y.%m.%d %H:%M:%S",
        "%Y.%m.%d %H:%M",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y/%m/%d %H:%M:%S",
        "%Y/%m/%d %H:%M",
        "%d.%m.%Y %H:%M:%S",
        "%d.%m.%Y %H:%M",
    ):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    raise DataError(f"{where}: unrecognized timestamp '{value}'")


def _normalize_header(name: str) -> str:
    return (name or "").strip().lstrip("\ufeff").lower().replace(" ", "_")


def _column_map(fieldnames: Sequence[str], required: Iterable[str]) -> dict[str, str]:
    normalized = {_normalize_header(f): f for f in fieldnames if f is not None}
    out: dict[str, str] = {}
    for logical in required:
        for alias in _BAR_ALIASES[logical]:
            if alias in normalized:
                out[logical] = normalized[alias]
                break
        if logical not in out:
            raise DataError(
                f"missing required column '{logical}' (accepted names: "
                f"{', '.join(_BAR_ALIASES[logical])})"
            )
    return out


def read_bars(path: str | os.PathLike[str], *, delimiter: str = ",") -> Bars:
    """Read OHLCV bars from a CSV file.

    Required columns: time, open, high, low, close, tick_volume (or
    volume).  ``spread`` is accepted and ignored by the feature layer.
    Timestamps are interpreted as UTC and must be strictly increasing.
    """
    file_path = Path(path)
    if not file_path.exists():
        raise DataError(f"bar file not found: {file_path}")
    times: list[datetime] = []
    opens: list[float] = []
    highs: list[float] = []
    lows: list[float] = []
    closes: list[float] = []
    volumes: list[float] = []
    with file_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        if reader.fieldnames is None:
            raise DataError(f"{file_path}: empty CSV")
        columns = _column_map(reader.fieldnames, ("time", "open", "high", "low", "close", "volume"))
        for line_no, row in enumerate(reader, start=2):
            where = f"{file_path.name}:{line_no}"
            try:
                stamp = _parse_time(row[columns["time"]], where)
                o = float(row[columns["open"]])
                h = float(row[columns["high"]])
                l = float(row[columns["low"]])
                c = float(row[columns["close"]])
                v = float(row[columns["volume"]])
            except (TypeError, ValueError) as exc:
                if isinstance(exc, DataError):
                    raise
                raise DataError(f"{where}: invalid numeric value ({exc})") from None
            if not all(math.isfinite(x) for x in (o, h, l, c, v)):
                raise DataError(f"{where}: non-finite OHLCV value")
            if min(o, h, l, c) <= 0.0:
                raise DataError(f"{where}: prices must be positive")
            if h < max(o, c) or l > min(o, c) or h < l:
                raise DataError(f"{where}: inconsistent OHLC (o={o}, h={h}, l={l}, c={c})")
            if v < 0.0:
                raise DataError(f"{where}: negative volume")
            if times and stamp <= times[-1]:
                raise DataError(f"{where}: timestamps must be strictly increasing")
            times.append(stamp)
            opens.append(o)
            highs.append(h)
            lows.append(l)
            closes.append(c)
            volumes.append(v)
    if not times:
        raise DataError(f"{file_path}: no data rows")
    return Bars(times, opens, highs, lows, closes, volumes)


def write_bars(path: str | os.PathLike[str], bars: Bars) -> None:
    """Write bars in the format ``read_bars`` accepts (round-trip safe)."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["time", "open", "high", "low", "close", "tick_volume"])
        for i in range(len(bars)):
            writer.writerow(
                [
                    bars.time[i].strftime("%Y-%m-%d %H:%M:%S"),
                    f"{bars.open[i]:.10f}".rstrip("0").rstrip("."),
                    f"{bars.high[i]:.10f}".rstrip("0").rstrip("."),
                    f"{bars.low[i]:.10f}".rstrip("0").rstrip("."),
                    f"{bars.close[i]:.10f}".rstrip("0").rstrip("."),
                    f"{bars.volume[i]:.0f}",
                ]
            )


def resample(bars: Bars, minutes: int) -> Bars:
    """Aggregate bars into fixed ``minutes`` UTC buckets (left-labelled)."""
    minutes = int(minutes)
    if minutes <= 0:
        raise ValueError("minutes must be positive")
    step = timedelta(minutes=minutes)
    times: list[datetime] = []
    opens: list[float] = []
    highs: list[float] = []
    lows: list[float] = []
    closes: list[float] = []
    volumes: list[float] = []
    current_bucket: datetime | None = None
    for i, stamp in enumerate(bars.time):
        midnight = stamp.replace(hour=0, minute=0, second=0, microsecond=0)
        offset = int((stamp - midnight).total_seconds() // (minutes * 60))
        bucket = midnight + offset * step
        if bucket != current_bucket:
            current_bucket = bucket
            times.append(bucket)
            opens.append(bars.open[i])
            highs.append(bars.high[i])
            lows.append(bars.low[i])
            closes.append(bars.close[i])
            volumes.append(bars.volume[i])
        else:
            highs[-1] = max(highs[-1], bars.high[i])
            lows[-1] = min(lows[-1], bars.low[i])
            closes[-1] = bars.close[i]
            volumes[-1] += bars.volume[i]
    return Bars(times, opens, highs, lows, closes, volumes)


def asset_class_of(symbol: str) -> str:
    """Default asset-class guess used only when a CSV row omits the column.

    The EA never guesses: ``deriv_symbols.csv`` is authoritative.  This
    helper exists for research scripts that explore a raw broker export
    before it has been classified.
    """
    name = symbol.upper()
    if name.startswith(("XAU", "XAG", "XPT", "XPD")):
        return "metal"
    if name.startswith(("US30", "US500", "NAS100", "GER40", "UK100", "JP225", "HK50", "US2000", "USTEC", "DE40", "UK100")):
        return "index"
    return "fx"


@dataclass(frozen=True)
class SymbolRecord:
    symbol: str
    asset_class: str
    base_currency: str
    quote_currency: str
    session_profile: str
    max_risk_pct: float
    max_spread_points: int
    atr_period: int
    min_atr_points: int
    max_positions: int
    correlation_group: str
    news_currencies: tuple[str, ...]
    enabled: bool = True


def _parse_bool(value: str, where: str) -> bool:
    text = (value or "").strip().lower()
    if text in ("1", "true", "yes", "y", "on"):
        return True
    if text in ("0", "false", "no", "n", "off", ""):
        return False
    raise DataError(f"{where}: invalid boolean '{value}'")


def read_symbols(path: str | os.PathLike[str]) -> list[SymbolRecord]:
    """Read and validate ``deriv_symbols.csv`` (the EA's symbol config)."""
    file_path = Path(path)
    if not file_path.exists():
        raise DataError(f"symbol file not found: {file_path}")
    records: list[SymbolRecord] = []
    seen: set[str] = set()
    with file_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise DataError(f"{file_path}: empty CSV")
        required = (
            "symbol",
            "asset_class",
            "max_risk_pct",
            "max_spread_points",
            "min_atr_points",
        )
        fields = {_normalize_header(f): f for f in reader.fieldnames}
        missing = [name for name in required if name not in fields]
        if missing:
            raise DataError(f"{file_path}: missing columns {', '.join(missing)}")
        for line_no, row in enumerate(reader, start=2):
            where = f"{file_path.name}:{line_no}"
            symbol = (row.get(fields["symbol"]) or "").strip()
            if not symbol:
                raise DataError(f"{where}: empty symbol")
            if symbol in seen:
                raise DataError(f"{where}: duplicate symbol '{symbol}'")
            seen.add(symbol)
            asset_class = (row.get(fields["asset_class"]) or "").strip().lower()
            if asset_class not in ASSET_CLASSES:
                raise DataError(f"{where}: asset_class must be one of {ASSET_CLASSES}")

            def number(name: str, default: str) -> float:
                column = fields.get(name)
                text = (row.get(column) or default).strip() if column else default
                try:
                    value = float(text)
                except ValueError:
                    raise DataError(f"{where}: {name} is not numeric ('{text}')") from None
                if not math.isfinite(value):
                    raise DataError(f"{where}: {name} is not finite")
                return value

            max_risk = number("max_risk_pct", "0.35")
            if not 0.0 < max_risk <= 5.0:
                raise DataError(f"{where}: max_risk_pct must be in (0, 5]")
            spread = int(number("max_spread_points", "50"))
            if spread < 1:
                raise DataError(f"{where}: max_spread_points must be >= 1")
            atr_period = int(number("atr_period", "14"))
            if not 2 <= atr_period <= 500:
                raise DataError(f"{where}: atr_period must be 2..500")
            min_atr = int(number("min_atr_points", "0"))
            if min_atr < 0:
                raise DataError(f"{where}: min_atr_points must be >= 0")
            max_positions = int(number("max_positions", "1"))
            if max_positions < 1:
                raise DataError(f"{where}: max_positions must be >= 1")
            currencies = tuple(
                part.strip().upper()
                for part in (row.get(fields.get("news_currencies", ""), "") or "").replace(";", ",").split(",")
                if part.strip()
            )
            correlation = (row.get(fields.get("correlation_group", ""), "") or "").strip()
            if not correlation:
                raise DataError(f"{where}: correlation_group is required")
            records.append(
                SymbolRecord(
                    symbol=symbol,
                    asset_class=asset_class,
                    base_currency=(row.get(fields.get("base_currency", ""), "") or "").strip().upper(),
                    quote_currency=(row.get(fields.get("quote_currency", ""), "") or "").strip().upper(),
                    session_profile=(row.get(fields.get("session_profile", ""), "") or "").strip().lower(),
                    max_risk_pct=max_risk,
                    max_spread_points=spread,
                    atr_period=atr_period,
                    min_atr_points=min_atr,
                    max_positions=max_positions,
                    correlation_group=correlation,
                    news_currencies=currencies,
                    enabled=_parse_bool(row.get(fields.get("enabled", ""), "") or "1", where),
                )
            )
    if not records:
        raise DataError(f"{file_path}: no symbol rows")
    return records


def read_json(path: str | os.PathLike[str]) -> dict:
    file_path = Path(path)
    if not file_path.exists():
        raise DataError(f"file not found: {file_path}")
    try:
        with file_path.open("r", encoding="utf-8-sig") as handle:
            value = json.load(handle)
    except json.JSONDecodeError as exc:
        raise DataError(f"{file_path}: invalid JSON ({exc})") from None
    if not isinstance(value, dict):
        raise DataError(f"{file_path}: JSON root must be an object")
    return value


def write_json_atomic(path: str | os.PathLike[str], value: dict) -> None:
    """Write JSON via a temporary file and an atomic replace."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, target)
