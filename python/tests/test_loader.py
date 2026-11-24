"""CSV parsing, validation and resampling."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from data.loader import DataError, read_bars, read_symbols, resample, write_bars
from tests.helpers import make_bars

ROOT = Path(__file__).resolve().parents[2]


class LoaderTests(unittest.TestCase):
    def test_round_trip(self) -> None:
        bars = make_bars(
            [
                (1.1000, 1.1010, 1.0990, 1.1005, 100),
                (1.1005, 1.1020, 1.1000, 1.1015, 120),
                (1.1015, 1.1030, 1.1010, 1.1025, 90),
            ]
        )
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bars.csv"
            write_bars(path, bars)
            loaded = read_bars(path)
        self.assertEqual(len(loaded), len(bars))
        for i in range(len(bars)):
            self.assertEqual(loaded.time[i], bars.time[i])
            for name in ("open", "high", "low", "close"):
                self.assertAlmostEqual(getattr(loaded, name)[i], getattr(bars, name)[i], places=9)
            self.assertAlmostEqual(loaded.volume[i], bars.volume[i])

    def test_alternate_headers_and_timestamp_formats(self) -> None:
        content = (
            "Date,Open,High,Low,Close,TickVolume\n"
            "2024.01.02 07:00,1.1,1.2,1.0,1.15,10\n"
            "2024.01.02 07:15,1.15,1.25,1.1,1.2,12\n"
        )
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bars.csv"
            path.write_text(content, encoding="utf-8")
            bars = read_bars(path)
        self.assertEqual(bars.time[0].hour, 7)
        self.assertAlmostEqual(bars.close[1], 1.2)

    def test_rejects_duplicate_timestamps(self) -> None:
        content = "time,open,high,low,close,volume\n2024-01-02 07:00,1,1,1,1,1\n2024-01-02 07:00,1,1,1,1,1\n"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bars.csv"
            path.write_text(content, encoding="utf-8")
            with self.assertRaises(DataError):
                read_bars(path)

    def test_rejects_inconsistent_ohlc(self) -> None:
        content = "time,open,high,low,close,volume\n2024-01-02 07:00,1,0.5,1.5,1,1\n"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bars.csv"
            path.write_text(content, encoding="utf-8")
            with self.assertRaises(DataError):
                read_bars(path)

    def test_rejects_non_finite(self) -> None:
        content = "time,open,high,low,close,volume\n2024-01-02 07:00,1,1,1,nan,1\n"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "bars.csv"
            path.write_text(content, encoding="utf-8")
            with self.assertRaises(DataError):
                read_bars(path)

    def test_resample(self) -> None:
        from datetime import datetime

        from features.indicators import Bars

        times = [
            datetime(2024, 1, 2, 7, 0),
            datetime(2024, 1, 2, 7, 5),
            datetime(2024, 1, 2, 7, 10),
            datetime(2024, 1, 2, 7, 15),
        ]
        bars = Bars(times, [1.0, 1.1, 1.2, 1.3], [1.2, 1.3, 1.4, 1.5], [0.9, 1.0, 1.1, 1.2], [1.1, 1.2, 1.3, 1.4], [10, 10, 10, 20])
        merged = resample(bars, 15)
        self.assertEqual(len(merged), 2)
        self.assertAlmostEqual(merged.open[0], 1.0)
        self.assertAlmostEqual(merged.high[0], 1.4)
        self.assertAlmostEqual(merged.low[0], 0.9)
        self.assertAlmostEqual(merged.close[0], 1.3)
        self.assertAlmostEqual(merged.volume[0], 30)
        self.assertAlmostEqual(merged.volume[1], 20)

    def test_reads_shipped_symbol_csv(self) -> None:
        path = ROOT / "MQL5" / "Files" / "deriv_symbols.csv"
        records = read_symbols(path)
        self.assertGreaterEqual(len(records), 10)
        by_symbol = {record.symbol: record for record in records}
        self.assertEqual(by_symbol["EURUSD"].asset_class, "fx")
        self.assertEqual(by_symbol["XAUUSD"].asset_class, "metal")
        self.assertEqual(by_symbol["Wall Street 30"].asset_class, "index")
        self.assertEqual(by_symbol["US SP 500"].correlation_group, "US_EQUITY")
        self.assertEqual(by_symbol["EURUSD"].correlation_group, "USD_EUR")
        self.assertEqual(by_symbol["EURUSD"].news_currencies, ("USD", "EUR"))
        self.assertTrue(by_symbol["EURUSD"].enabled)

    def test_rejects_bad_symbol_rows(self) -> None:
        header = (
            "symbol,asset_class,base_currency,quote_currency,session_profile,max_risk_pct,"
            "max_spread_points,atr_period,min_atr_points,max_positions,correlation_group,"
            "news_currencies,enabled\n"
        )
        good = "EURUSD,fx,EUR,USD,london_ny,0.35,30,14,0,2,USD_EUR,USD;EUR,1\n"
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "symbols.csv"
            path.write_text(header + good.replace(",fx,", ",equity,"), encoding="utf-8")
            with self.assertRaises(DataError):
                read_symbols(path)
            path.write_text(header + good + good, encoding="utf-8")
            with self.assertRaises(DataError):
                read_symbols(path)
            path.write_text(header + good.replace(",0.35,", ",-1,"), encoding="utf-8")
            with self.assertRaises(DataError):
                read_symbols(path)
            path.write_text(header + good.replace("USD_EUR", ""), encoding="utf-8")
            with self.assertRaises(DataError):
                read_symbols(path)


if __name__ == "__main__":
    unittest.main()
