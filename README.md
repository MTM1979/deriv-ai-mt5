# Deriv AI MT5 Portfolio EA

A multi-asset MetaTrader 5 expert advisor for Deriv MT5, with a stdlib-only
Python research pipeline that trains models, exports ONNX and validates the
feature contract.

This is **not** a ready-to-trade profitable system. It is an implementation of
a specification, built to be inspectable, conservative and honest about what
has and has not been verified.

## What it does

- Resolves broker symbols at runtime from a CSV plus explicit rules; never
  hardcodes Deriv names or contract specifications.
- Reads point, tick size/value, volume limits, stops level, margin and trade
  mode from the terminal, and refreshes them before each order.
- Runs four strategies per symbol per bar: trend continuation, opening-range
  breakout, liquidity-sweep reversal and regime-limited mean reversion.
- Scores the strongest candidate with an ONNX model, then an optional external
  AI advisor that may only veto or reduce risk.
- Sizes from equity by portfolio heat, daily/weekly loss, drawdown,
  correlation and margin headroom. The risk engine is the final gate and can
  only reduce.
- Protects positions (SL/TP verification, breakeven, trailing, partial, time
  exit), reconciles state after restarts, and journals every decision.

## Safety properties

- Invalid or unavailable AI → configurable policy, default veto.
- Missing/invalid calendar → default `BLOCK_ALL`.
- Missing/unusable model → entries rejected by default.
- Corrupt state → startup fails; a missing state file is a fresh start.
- Halts latch across restarts; `RESET` is an explicit operator action.
- No failure path increases risk.

## Requirements

| Component | Requirement |
|---|---|
| Trading | Windows, MetaTrader 5, a Deriv MT5 account |
| Compiler | MetaEditor 5 (verified on `5.0.0.6140`) |
| Research | Python 3.11+, standard library only |
| Data | Broker history on M15/H1/M5 (or your chosen timeframes) |

No external Python packages are needed for the shipped pipeline.

## Quick start

1. Read [docs/01-setup.md](docs/01-setup.md). It covers copying files,
   compiling, terminal permissions and the first dry run.
2. Discover the broker's exact symbols with
   `MQL5/Scripts/DiscoverDerivSymbols.mq5` and build
   `MQL5/Files/deriv_symbols.csv`.
3. Export bars and the calendar, then train and package a model:
   [docs/04-models.md](docs/04-models.md).
4. Validate in the Strategy Tester and on demo:
   [docs/05-validation.md](docs/05-validation.md) and
   [docs/06-deployment.md](docs/06-deployment.md).
5. Operate with [docs/07-operations.md](docs/07-operations.md). Know where
   `KILL` goes before you trade.

Compile check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\compile.ps1 `
  -File "MQL5\Experts\DerivAIPortfolioEA.mq5"
```

Python checks (from `python/`):

```powershell
python -m features.spec --check
python -m unittest discover -s tests -t .
```

Expected: `0 errors, 0 warnings`, `FeatureSpec.mqh is current`, 76 tests
passing.

## Layout

```text
MQL5/
  Experts/DerivAIPortfolioEA.mq5      inputs, orchestration, operator files
  Include/
    Config.mqh                        enums, structs, reason codes
    Utils.mqh                         strings, time, files, CSV, logging
    Json.mqh                          minimal JSON
    FeatureSpec.mqh                   generated 30-feature contract
    SymbolSpec.mqh                    CSV + live contract resolution
    Sessions.mqh                      UTC sessions and risk scales
    Indicators.mqh                    handles, snapshots, data quality
    SignalEngine.mqh                  four strategies, weighted score
    OnnxModel.mqh                     metadata, hash, inference
    AiAssistant.mqh                   policy, HTTP, veto/reduce
    NewsCalendar.mqh                  live calendar + CSV fallback
    RiskEngine.mqh                    halts, correlation, sizing
    Execution.mqh                     orders, protection, management
    State.mqh                         atomic persistence
    Journal.mqh                       six CSV journals
  Scripts/                            discovery, exports, parity samples
  Files/                              templates: symbols, calendar, models, AI policy
python/
  features/                           feature contract and builders
  data/                               OHLCV loading and symbols
  models/                             labels, training, ONNX, packaging
  tests/                              76 unittest cases
docs/                                 setup through verification
scripts/compile.ps1                   portable MetaEditor wrapper
```

## Documentation

| Page | Contents |
|---|---|
| [docs/01-setup.md](docs/01-setup.md) | Install, compile, permissions, first dry run |
| [docs/02-inputs.md](docs/02-inputs.md) | Every input, file schema and validation rule |
| [docs/03-architecture.md](docs/03-architecture.md) | Modules, pipeline, risk math, persistence |
| [docs/04-models.md](docs/04-models.md) | Train, export, install, roll back ONNX models |
| [docs/05-validation.md](docs/05-validation.md) | Tester protocol and acceptance criteria |
| [docs/06-deployment.md](docs/06-deployment.md) | Research → tester → demo → micro-live |
| [docs/07-operations.md](docs/07-operations.md) | Daily operation, kill switches, recovery |
| [docs/08-decisions.md](docs/08-decisions.md) | Assumptions, deviations, tradeoffs |
| [docs/09-verification.md](docs/09-verification.md) | What was compiled and tested, and what was not |

## Verification status

- All MQL5 sources compile with 0 errors and 0 warnings on MetaEditor
  `5.0.0.6140`.
- 76 Python tests pass on Python 3.15.2 with no third-party packages.
- The feature header matches the Python contract.

Not verified, and required before live trading:

- live Deriv symbol names and contract specifications;
- ONNX inference inside a live terminal;
- Strategy Tester results, demo execution and acceptance criteria;
- the external AI endpoint;
- live calendar timing and DST behaviour.

See [docs/09-verification.md](docs/09-verification.md) for the exact record.

## Configuration files

| File | Purpose |
|---|---|
| `MQL5/Files/deriv_symbols.csv` | Portfolio, strategy parameters, risk/spread ceilings. |
| `MQL5/Files/model_metadata.json` | Model registry, feature order, hashes, thresholds. |
| `MQL5/Files/ai_policy.json` | AI endpoint, auth, limits, fallback. |
| `MQL5/Files/calendar_history.csv` | Calendar fallback for the tester and outages. |

The shipped files are templates. In particular, the metadata contains empty
hashes, so model-backed entries are rejected until you package real models.

## License and ownership

No license is granted by this repository. Deriv, MetaTrader and any third-party
names belong to their owners. Trading involves risk of loss; nothing here is
financial advice.
