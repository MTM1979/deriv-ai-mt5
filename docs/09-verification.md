# Verification record

This page records what was actually executed for this delivery. It separates
observed results from things that were not verified. Do not read a "not
verified" line as a pass.

Date of record: **2026-11-23**.

## 1. Environment

| Item | Value |
|---|---|
| OS | Windows (win32) |
| MetaEditor / terminal | `5.0.0.6140` |
| MetaEditor path | `C:\Program Files\MetaTrader 5\MetaEditor64.exe` |
| Python | `3.15.2`, no NumPy / scikit-learn / onnx / onnxruntime / pytest |
| Project root | `C:\Users\user\deriv-ai-mt5` |
| Broker terminal | Startup log supplied from account `41331946` on `Deriv-Demo`; not reproduced during this pass |

The Python environment is relevant: the pipeline was built stdlib-only so it
could be executed here. The absence of an ONNX runtime is why inference was
not executed.

## 2. MQL5 compilation

Command (from the project root):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\compile.ps1 -File "<path>"
```

Observed results:

| File | Result |
|---|---|
| `MQL5\Experts\DerivAIPortfolioEA.mq5` | `0 errors, 0 warnings` |
| `MQL5\Scripts\DiscoverDerivSymbols.mq5` | `0 errors, 0 warnings` |
| `MQL5\Scripts\ExportSymbols.mq5` | `0 errors, 0 warnings` |
| `MQL5\Scripts\ExportBars.mq5` | `0 errors, 0 warnings` |
| `MQL5\Scripts\ExportCalendar.mq5` | `0 errors, 0 warnings` |
| `MQL5\Scripts\ExportFeatureSamples.mq5` | `0 errors, 0 warnings` |

The compile step produced `.ex5` files alongside the sources. The transient
`.log` files are not part of the deliverable.

Compilation proves syntax, include resolution and the MQL5 type contract. It
does not prove runtime behaviour, terminal compatibility with a Deriv server,
or that the ONNX runtime accepts the files.

## 3. Python checks

From `C:\Users\user\deriv-ai-mt5\python`:

```text
> python -m unittest discover -s tests -t .
............................................................................
----------------------------------------------------------------------
Ran 76 tests in 3.191s

OK
```

```text
> python -m features.spec --check
FeatureSpec.mqh is current
```

The 76 tests cover:

- feature order, bounds, clamping and header generation;
- indicator formulas and session windows;
- triple-barrier edges, including same-bar ambiguity and next-bar entry;
- metrics (AUC, Brier, log loss, calibration, expectancy, drawdown, bootstrap);
- purged walk-forward and k-fold splits;
- OHLCV CSV validation and timestamp parsing;
- ONNX protobuf encoding/parsing and graph inspection;
- metadata, feature-order and SHA-256 failures;
- an end-to-end synthetic run: bars → labels → train → evaluate → export ONNX
  → package → metadata/hash check → walk-forward.

These are unit and integration tests on synthetic or in-repo fixtures. They do
not establish market behaviour, and they do not exercise a real ONNX runtime.

## 4. End-to-end synthetic pipeline

Observed during development, reproduced by the test suite:

- 800 synthetic bars produced 1,248 labelled rows containing both classes;
- `models.train` produced a model JSON and a report;
- `models.evaluate` produced probability and trading metrics;
- `models.export_onnx` wrote a `[1,30] → [1,2]` graph;
- `models.package` installed it, wrote metadata and a SHA-256, and `--check`
  re-verified the hash;
- `models.walkforward` produced folds and a final model.

This validates the code path and the file contract. It says nothing about
predictive quality.

## 5. Repository checks

| Check | Result |
|---|---|
| `scripts/compile.ps1` is portable (root derived from `$PSScriptRoot`) | Yes; default file is the EA |
| No `*.log` artifacts retained | Yes (transient compile logs were removed) |
| Feature header generated, not hand-edited | Yes: `python -m features.spec --check` passes |
| Dead inputs/config fields | Removed: tester/optimizer AI allowances, ensemble meta threshold, pending expiry/offset, rollover-management toggle, duplicate runtime banner/model flags. Reserved booleans remain and fail validation. |
| Candidate correlation/news flags | Derived from reason codes in `Reject`; no ad-hoc writers remain. |
| ATR period consistency | Every enabled CSV row must equal `InpAtrPeriod`; mismatch fails init. |
| Shipped symbol CSV | All ten `symbol` values match the demo account's discovery export exactly; the Python fixture check asserts the new index names. |
| Journal paths | One `CJournal::Path` helper owns the directory prefix for every journal file, including rotation. |

## 6. Live demo-terminal runs (operator-supplied)

Both runs are from account `41331946` on server `Deriv-Demo`, chart
`EURUSD,M5`. The operator supplied the logs; this record reads them and the
journals they produced but did not re-run the terminal.

### 6.1 2026-11-23 — before the fixes

Observed:

- `SYMBOLS` warnings for `US30`, `US500`, `NAS100` and `GER40`: no broker match.
  `EURUSD`, `GBPUSD`, `USDJPY`, `XAUUSD`, `XAGUSD` and `UK100` resolved.
- `ERROR` for models `fx`, `metal` and `index`: `models/<key>.onnx` not found.
  No model has been packaged yet, so ML-gated entries are rejected by design.
- `zero divide` at `Indicators.mqh(499,31)`, roughly 4–5 seconds after init, on
  both starts.
- The banner printed the compile timestamp into a `%s` `build` slot.
- `events.csv` and `daily_summary.csv` were written to `MQL5\Files\` while
  `state.json` was in `MQL5\Files\DerivAIPortfolioEA\`, although every document
  places all journal files under `InpJournalDir`.
- The startup line reported `ready: 10 symbols` even though four had not
  resolved.

Root cause and fix:

| Symptom | Root cause | Fix |
|---|---|---|
| Zero divide in `BuildSnapshot` | Contract values were only read from order-send paths, so `point` and `tick_size` were still zero when the first snapshot divided the ATR by `point`. Sizing and stops would also have used zero values. | `RefreshAll` at init; a spec refresh on every evaluation; `RefreshStaleSpecs` before position management; checked refresh before each order, modification and close. `BuildSnapshot` now rejects a non-positive `point`/`tick_size` instead of dividing. |
| Banner `build (non-string passed)` | `__DATETIME__` was passed to `%s`. | Banner prints `TERMINAL_BUILD` as an integer and the compile time via `TimeToString`. |
| Journal files outside `InpJournalDir` | `CJournal::Append`/`Rotate` opened bare filenames; only `state.json` built its path from the configured directory. | A single `CJournal::Path` helper prefixes every journal file, and rotation now finds the extension after the last separator. |
| `ready: 10 symbols` with 4 unresolved | The line printed the configured row count, not the resolved count. | `ResolvedCount` reports enabled and resolved rows, so the line reads `ready: 6 of 10 symbols resolved`. |

The index warnings were a data problem, not a code defect: those logical names
had no matching broker symbol on that account. `deriv_symbols_discovered.csv`
showed the account's actual names, which are now in the shipped CSV:
`Wall Street 30`, `US SP 500`, `US Tech 100`, `Germany 40` and `UK 100`. Note
`US SP 500` is the symbol name while its terminal description reads `US 500`,
which is why the earlier guess did not match.

These fixes were then recompiled and reattached; §6.2 records that run.

### 6.2 2026-11-24 — after the fixes

The same operator reattached the EA after recompiling (terminal build 6230,
compiled 09:54 local). Confirmed in the log and journals:

- No `zero divide`; the EA stayed attached for the whole session.
- `ready: 10 of 10 symbols resolved, 0 positions, heat 0.00%`.
- No `SYMBOLS` warning: every index row matched by its exact broker name.
- `events.csv`, `rejections.csv`, `decisions.csv`, `daily_summary.csv` and
  `state.json` all under `MQL5\Files\DerivAIPortfolioEA\`.
- Calendar: `calendar live: 48 events (4 queries)`.
- Models still absent, so the three `ERROR: model '<key>' unusable` lines
  remain. No candidate reached the ML stage, so that gate was not exercised.

The first real decisions arrived for the M15 bar `2026.11.24 08:00` (server
time), about 40 seconds after attach:

| Symbol | Stage | Reason | Observed |
|---|---|---|---|
| EURUSD | volatility | `ATR_TOO_SMALL` | ATR 47 points, minimum 50 |
| GBPUSD, USDJPY, XAUUSD, XAGUSD, UK 100 | signal | `NO_SETUP` | valid snapshots, no qualifying setup |
| Wall Street 30, US SP 500, US Tech 100 | session | `SESSION_BLOCKED` | `us_cash` profile at 08:00 UTC |
| Germany 40 | spread | `SPREAD_TOO_WIDE` | spread 120 > cap 100 points |

These are data, not defects: the thresholds are illustrative defaults and the
two rejections show they bind. `US SP 500` and `US Tech 100` have different
point sizes from the FX pairs, so their point-based thresholds need their own
calibration.

The run also exposed a scan-latency problem. The first pass over ten symbols
took ~20 seconds and emitted `BUDGET` warnings: first-time history and
indicator loads dominate, and the old loop checked the budget before the first
symbol, so a slow preparation phase could skip every symbol in a pass. The
loop now:

- reports preparation time, elapsed time and the slowest symbol in the
  `BUDGET` line, at most once a minute;
- stops before starting another symbol once the budget is spent, but always
  evaluates at least one pending symbol per pass;
- journals `DATA` when a symbol's time series cannot be read (`CopyTime`
  failure), throttled per symbol to once per ten minutes, instead of dropping
  the symbol from every scan silently.

Runtime confirmation of the second bar with the new loop is pending.

## 7. Not verified

These were **not** executed. Each is a real gap, not a formality.

| Area | Why it was not verified | Where it must be closed |
|---|---|---|
| Deriv symbol names and suffixes | One demo account was observed (§6): four index names did not match the original template, were identified from the discovery export and are now in the CSV. No other account, region or server was checked. | Run `DiscoverDerivSymbols.mq5` on each account; adjust the CSV or `InpSymbolOverrides`. |
| Deriv contract specs (point, tick value, stops level, margin, trade mode) | The 2026-11-24 run produced non-zero ATR and spread values and no zero divide, which shows the specs were read; the individual values were not compared with the terminal's own specification dialog. | `ExportSymbols.mq5` plus the terminal specification, compared with the journal startup lines. |
| ONNX inference in the terminal | No packaged model and no live terminal session here; no onnxruntime installed. | Attach the EA on demo with a packaged model; confirm the `ML` startup line and a non-constant `ml_prob`. |
| Strategy Tester runs | Not run for this delivery. | [05-validation.md](05-validation.md). |
| Demo execution | Not run. | Four weeks minimum, [06-deployment.md](06-deployment.md). |
| Live calendar and time basis | No live calendar to compare against. | Compare a known event; flip `InpCalendarTimeBasis` only with evidence. |
| Server offset / DST behaviour | No broker session observed. | Check the offset line after each DST change. |
| External AI endpoint | No endpoint or credentials were provided; the shipped policy points at `example.invalid`. | Configure a real endpoint, keep `InpAiEnabled=false` until the audit looks correct. |
| Multi-symbol portfolio behaviour | Requires history for all symbols and a tester run. | Portfolio stage in [05-validation.md](05-validation.md). |
| Performance | The live run shows ~20 s for the first ten-symbol pass, dominated by first-time history and indicator loads; later bars were not measured with the new loop, and no before/after benchmark exists. | Watch the new `BUDGET` line over a full session; measure again only if it keeps binding. |

## 8. Claims this record supports

Supported:

- the source compiles cleanly against MetaEditor `5.0.0.6140`;
- the Python pipeline is importable and tested on a stdlib-only interpreter;
- the feature header matches the Python contract;
- the documented files and schemas exist and parse;
- the code paths for rejection, halting, persistence and packaging are
  covered by tests at the unit/integration level;
- the startup zero divide reported from the demo terminal was traced to
  contract values that had never been read, and a second live run on
  2026-11-24 confirms the fix: all ten rows resolved, no zero divide, and
  journal files under `InpJournalDir`. The revised scan loop has not yet run
  live.

Not supported:

- that the EA is profitable;
- that Deriv's symbols, spreads or contract specs match the template;
- that the ONNX runtime in a live terminal accepts the exported graph;
- that the demo or live behaviour matches any backtest;
- that the external AI improves results.

## 9. Reproduction

From a clean checkout with MetaTrader 5 installed:

```powershell
# 1. Compile everything
$files = @(
  "MQL5\Experts\DerivAIPortfolioEA.mq5",
  "MQL5\Scripts\DiscoverDerivSymbols.mq5",
  "MQL5\Scripts\ExportSymbols.mq5",
  "MQL5\Scripts\ExportBars.mq5",
  "MQL5\Scripts\ExportCalendar.mq5",
  "MQL5\Scripts\ExportFeatureSamples.mq5"
)
foreach($f in $files){
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\compile.ps1 -File $f
}

# 2. Python
cd python
python -m features.spec --check
python -m unittest discover -s tests -t .
```

Expected: six `0 errors, 0 warnings` results, `FeatureSpec.mqh is current`,
and 76 tests passing. Any other result means the checkout differs from the
verified one; report the difference rather than adjusting the expectation.
