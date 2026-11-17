# Setup

This page takes a clean Windows machine with MetaTrader 5 to a started EA that
has not placed an order yet. Do not skip the dry-run step at the end.

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Windows with MetaTrader 5 | Verified against MetaEditor/terminal build `5.0.0.6140`. Newer builds should compile, but re-run the checks in [09-verification.md](09-verification.md). |
| Deriv MT5 account | Use a **demo** account for setup. The EA never asks for credentials; the terminal session owns them. |
| Python 3.11+ (research only) | The pipeline is stdlib-only. Not needed on the trading VPS unless you retrain there. |
| Broker history | At least `min_bars_required` bars per symbol on the execution timeframe, plus H1 and M5. |

The EA does not install Java, Python, Ghidra or any runtime. It uses only what
the MetaTrader 5 terminal provides.

## 2. Copy the files

In MetaTrader 5: **File → Open Data Folder**. The target is the `MQL5`
subdirectory shown there (referred to below as `<MQL5>`).

Copy the repository tree so it becomes:

```text
<MQL5>\Experts\DerivAIPortfolioEA.mq5
<MQL5>\Include\Config.mqh
<MQL5>\Include\Utils.mqh
<MQL5>\Include\Json.mqh
<MQL5>\Include\FeatureSpec.mqh
<MQL5>\Include\SymbolSpec.mqh
<MQL5>\Include\Sessions.mqh
<MQL5>\Include\Indicators.mqh
<MQL5>\Include\SignalEngine.mqh
<MQL5>\Include\OnnxModel.mqh
<MQL5>\Include\AiAssistant.mqh
<MQL5>\Include\NewsCalendar.mqh
<MQL5>\Include\RiskEngine.mqh
<MQL5>\Include\Execution.mqh
<MQL5>\Include\State.mqh
<MQL5>\Include\Journal.mqh
<MQL5>\Scripts\DiscoverDerivSymbols.mq5
<MQL5>\Scripts\ExportSymbols.mq5
<MQL5>\Scripts\ExportBars.mq5
<MQL5>\Scripts\ExportCalendar.mq5
<MQL5>\Scripts\ExportFeatureSamples.mq5
<MQL5>\Files\deriv_symbols.csv
<MQL5>\Files\calendar_history.csv
<MQL5>\Files\model_metadata.json
<MQL5>\Files\ai_policy.json
```

Do not rename the include files: every module uses angle-bracket includes,
which resolve against `<MQL5>\Include`.

The shipped `.ex5` files are convenience builds. Recompile on the target
machine anyway; MetaEditor embeds build-specific data and the terminal may
refuse a binary from a newer build.

## 3. Compile

In MetaEditor, open each `.mq5` and press **F7**, or from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\compile.ps1 `
  -File "MQL5\Experts\DerivAIPortfolioEA.mq5"
```

Repeat for every script. The helper passes `/inc:<repo>\MQL5`, so the project
layout works without copying it into the terminal first. Success is:

```text
Result: 0 errors, 0 warnings
```

The MetaEditor process exit code is not reliable; read the result line.

If you see `cannot open <Config.mqh>`, the `/inc` path is wrong or the include
files are not in the expected `Include` directory.

## 4. Terminal permissions

1. Turn on **Algo Trading** in the toolbar.
2. In **Tools → Options → Expert Advisors**:
   - enable **Allow algorithmic trading**;
   - leave **Allow DLL imports** off (not needed);
   - only if you enable the external AI advisor, add its exact URL under
     **Allow WebRequest for listed URL**. The EA sends `POST` to the endpoint
     in `ai_policy.json`.
3. Confirm the account has trading permission for every configured symbol. A
   symbol can be visible but close-only.

WebRequest is unavailable in the Strategy Tester. The EA therefore disables AI
in the tester by default; the news filter uses the exported calendar CSV.

## 5. Configure symbols

Deriv symbol names and contract specifications are broker data. Never copy
names from a different broker or assume a suffix.

1. Run `Scripts/DiscoverDerivSymbols.mq5` once. It writes:
   - `deriv_symbols_discovered.csv` — every terminal symbol with live contract
     fields;
   - `deriv_symbols_template.csv` — one logical row per symbol in the strategy
     template, with a heuristic broker match and two extra review columns.
2. Review the matches. Deriv may name an instrument differently, and the
   heuristic can be wrong.
3. Build `deriv_symbols.csv` using either pattern:

   **A. Exact broker names in the `symbol` column (simplest).**
   Copy the resolved broker name into `symbol`, keep the strategy fields, and
   leave `InpSymbolResolution = exact`.

   **B. Logical names plus resolution.**
   Keep `symbol` as the logical key (for example `EURUSD`) and either set
   `InpSymbolSuffix` (for example `.deriv`) or list explicit mappings in
   `InpSymbolOverrides`:

   ```text
   EURUSD=EURUSD.raw;XAUUSD=XAUUSD.raw;US30=US30.cash
   ```

   Use `InpSymbolResolution = override` so the map is consulted first.

The schema and every field are documented in
[02-inputs.md](02-inputs.md#symbol-csv). The EA reads all contract values
(point, tick size/value, volume limits, stops level, margin, trade mode) from
the terminal at startup and refreshes them before each order. The CSV never
supplies contract values.

If a row cannot be resolved, startup fails and the journal names the row. That
is deliberate: silently dropping a configured symbol changes portfolio risk.

## 6. Configure the calendar

The news filter needs a calendar in the Strategy Tester and during outages.

1. Run `Scripts/ExportCalendar.mq5` with a range that covers your test period
   (for example 365 past days and 60 future days).
2. Save the result as `calendar_history.csv` in `<MQL5>\Files` (UTF-8).
3. In live trading the EA prefers the terminal's economic calendar and falls
   back to the CSV. `InpCalendarTimeBasis` controls whether live calendar
   times are treated as server time (`0`, default) or UTC (`1`). CSV times are
   always UTC.

Placeholder rows are shipped so the file parses. Replace them before relying
on the filter; placeholder events are dated 2020 and have no effect on current
trading, but they are not evidence that the filter works.

## 7. Build and install models

You cannot trade with the shipped metadata template: every `sha256` is empty
and `require_hash` is on. Either:

- train and package a model (see [04-models.md](04-models.md)); or
- deliberately disable ML with `InpMlEnabled = false` and accept that the EA
  then has no probability gate.

For a first smoke test, disabling ML is acceptable. It is not acceptable for
demo or live evaluation, because the acceptance targets assume the model gate
is part of the system.

Verify the installation before starting:

```powershell
cd python
python -m models.package --check --files-root ..\MQL5\Files
```

## 8. First start (dry run)

Attach `DerivAIPortfolioEA` to any chart. The chart symbol is irrelevant; the
EA iterates the configured portfolio on a timer. Set:

```text
InpDryRun          = true
InpEnableTrading   = true
InpAiEnabled       = false
InpNewsEnabled     = true
InpJournalVerbosity= 2
```

`InpDryRun = true` logs the complete decision path and never sends an order.
Leave it on until the startup report and at least one full session look
correct.

### What a healthy startup looks like

In the **Experts** tab and `events.csv`:

- `INIT` banner with build, account, server, currency and leverage;
- `SYMBOLS` warnings for any heuristic resolution you should review;
- `SESSIONS` offset line, normally non-zero;
- `ML` line per loaded model, or an explicit warning that no model is usable;
- `NEWS` source (`live` or `csv`) and next refresh;
- `ready: N symbols, M positions, heat X%`;
- `RECONCILE` if the terminal already had EA positions.

Common startup failures:

| Message | Meaning | Action |
|---|---|---|
| `symbol configuration failed` | CSV missing or unreadable | Check path, `InpSymbolsCommonFolder`, encoding. |
| `symbol resolution failed` | A row does not match a terminal symbol | Fix the CSV or overrides. |
| `state load failed` | `state.json` is corrupt or from another schema | Restore a backup or remove it deliberately (this resets halts). |
| `ONNX init failed` | Metadata missing/malformed and fail-on-load is set | Package a model or fix metadata. |
| `account state unavailable` | Terminal not connected or account not ready | Wait for connection, then reattach. |
| `news init failed` | Live calendar requested with no CSV and no terminal calendar | Provide the CSV or disable news. |

## 9. First-run checklist

- [ ] Every `.mq5` compiles with 0 errors and 0 warnings.
- [ ] Algo Trading is on.
- [ ] `deriv_symbols.csv` rows resolve; no `SYMBOLS` errors.
- [ ] Contract values in the journal match the terminal's specification.
- [ ] Server-UTC offset is plausible and the session state matches the clock.
- [ ] Calendar source is available and the next high-impact event is listed.
- [ ] Model hashes verify and the journal lists every expected model.
- [ ] State directory exists and `state.json` is written.
- [ ] Dry run produced `decisions.csv` rows with a reason for each rejection.
- [ ] No `ERROR` line in `events.csv` during a full session.
- [ ] You have read [07-operations.md](07-operations.md) and know where
      `KILL` and `RESET` go.

Only then move to the Strategy Tester ([05-validation.md](05-validation.md)).
Do not go from dry run to live.

## 10. Updating and rollback

- **Code:** recompile, then reattach the EA. Inputs are preserved by the
  terminal's saved chart settings.
- **Models:** install to a new file name or keep the previous `.onnx` and
  `model_metadata.json` pair. Rollback is restoring both files and reattaching.
  Never edit `sha256` by hand.
- **State:** back up `state.json` before changing risk limits or the magic
  number. Changing the magic number orphans existing positions as far as the
  EA is concerned; close them first.
- **Journal directory:** changing `InpJournalDir` or
  `InpJournalCommonFolder` starts a fresh state. Do not change it casually.
