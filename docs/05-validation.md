# Validation

This page defines how to run the validation protocol in the specification
(§9.1–§9.3) and what counts as a pass. It is a procedure, not a claim that the
procedure was executed. What was actually run for this delivery is in
[09-verification.md](09-verification.md).

Nothing here replaces a demo account. The tester cannot reproduce Deriv's
fills, swap, or weekend gaps.

## 1. Before the tester

1. Complete [01-setup.md](01-setup.md) including a clean dry run.
2. Put every symbol you intend to test in **Market Watch**. The multi-symbol
   EA iterates its own CSV; the tester needs the symbols available and with
   history.
3. Download history for each symbol, on the execution, range and higher
   timeframes. Scroll the chart back or use the terminal's history download;
   the tester will otherwise start with partial data.
4. Package and verify models: `python -m models.package --check`.
5. Export a calendar covering the whole test period plus the look-ahead.
6. Record the exact build, inputs, CSVs and model hashes in a validation log.

## 2. Tester configuration

| Setting | Value | Why |
|---|---|---|
| Model | **Every tick based on real ticks** when the broker provides them | Bar-based models hide intrabar stop/target order. |
| Period | The execution timeframe (`InpExecTf`) | The EA reads its own timeframes; the chart period should still match. |
| Deposit / currency | The intended live account scale | Risk is percent-based, but lot granularity is not. |
| Leverage | The demo/live leverage | Margin checks depend on it. |
| Delays | Non-zero, ideally random | Zero delay overstates fill quality. |
| Commission / swap | Real values | The acceptance targets are "after realistic costs". |
| Spread | Realistic; use the symbol spread override if your build offers one | A constant spread misrepresents session behaviour. |
| Optimization | Genetic or exhaustive, **no** forward on the first pass | Keep OOS separate and explicit. |

The EA disables the external AI in the tester and optimizer. That is by
design: `WebRequest` is unavailable. The news filter uses
`calendar_history.csv`. If the CSV is missing, the calendar policy (default
`BLOCK_ALL`) rejects everything; that is a configuration failure, not a
strategy result.

The timer is not used in optimization. `OnTick` drives the loop. Do not expect
the timer's wall-clock pacing in the tester.

## 3. Test sequence

Run in this order. Each step has a go/no-go before the next.

| # | Test | How | Pass looks like |
|---|---|---|---|
| 1 | Single-symbol smoke | One row enabled, one symbol, 1–3 months | Starts, journals decisions, no unexplained rejections, protection honoured. |
| 2 | Per-symbol baseline | Each symbol alone, same period and costs | Behaviour is explainable, not necessarily profitable. |
| 3 | In-sample optimization | Optimize a **small** parameter set on an early period | Robust neighbouring values, not a single spike. |
| 4 | Out-of-sample | Fixed parameters on a later, untouched period | Positive expectancy, profit factor in range, drawdown inside budget. |
| 5 | Walk-forward | Rolling/expanding blocks, purge = label horizon | Aggregate OOS metrics hold; folds are not dominated by one window. |
| 6 | Monte Carlo | Reshuffle trade order / bootstrap R multiples | 5th-percentile drawdown is survivable, not just the mean. |
| 7 | Spread stress | Rerun OOS with wider spread (tester override or tighter CSV cap) | Edge survives the realistic upper bound. |
| 8 | Slippage stress | Rerun with worse delays/deviation, or add a constant cost to the Python evaluation | Edge survives; rejection rate stays explainable. |
| 9 | News blackout | Run a period with high-impact events; inspect `decisions.csv` | Entries stop in the window; no look-ahead in the CSV times. |
| 10 | Correlation stress | Enable correlated pairs (for example USD legs, US indices) | Correlated exposure stays below the cap; group counts respected. |
| 11 | Symbol holdout | Remove the best-performing symbol and rerun the portfolio | Result is not dependent on that symbol. |
| 12 | Strategy attribution | Compare with each strategy disabled in turn | No single strategy is the only source of the result. |
| 13 | Restart/state | Stop mid-test, restart, inspect reconciliation and halts | No duplicate entries; halts persist; state matches the account. |
| 14 | Failure injection | Rename a model, corrupt `state.json` on a copy, remove the calendar CSV | Each fails closed with a clear journal message. |

Tests 13 and 14 are cheap and catch the failures that cost money. Do them
before demo.

## 4. Acceptance criteria

Use all six; one good metric does not compensate for another failing.

### 4.1 Positive expectancy after realistic costs

From the tester report, or the Python evaluation on held-out rows:

```text
expectancy_R = mean(R multiple of closed trades)
```

Pass: `expectancy_R > 0` with the configured costs and spread. Report the
number of trades; fewer than ~100 trades is not evidence.

### 4.2 Profit factor 1.3–1.5 out of sample

```text
profit_factor = gross_profit / gross_loss
```

Pass: `>= 1.3` on untouched out-of-sample data, with `1.5` as the target.
Below 1.3 is a fail even if total profit is positive.

### 4.3 Drawdown inside the risk budget

Maximum equity drawdown must stay below `InpMaxDrawdownPct` (default 9%) and
should be consistent with the daily/weekly cutoffs. A drawdown that only stops
because the EA halted is a fail, not a pass: the strategy, not the circuit
breaker, must control risk.

### 4.4 Stability across years and regimes

Run at least two non-overlapping years and at least one high-volatility and one
low-volatility regime. Pass: positive expectancy in each year, no year carried
by a single month. Report the monthly R distribution.

### 4.5 No single point of dependence

Run tests 11 and 12: remove the best symbol and disable each strategy in turn.
Pass: the portfolio still clears criteria 4.1–4.3 without the removed
component, or the dependence is documented and accepted explicitly.

### 4.6 Demo consistency

For at least four weeks on a Deriv demo account:

- realized slippage distribution is inside the assumed range;
- spread at entry matches the tested regime;
- rejection and requote rates are not structurally higher than the tester;
- no unexplained differences between `decisions.csv` and the tester log for
  the same setup.

Pass: the demo expectancy is within the tester's confidence interval, not
merely positive. If it is outside, stop and diagnose before micro-live.

## 5. Evidence to capture

For every run, keep:

- build (`__DATETIME__` and terminal build), input set (`.set` file),
  `deriv_symbols.csv`, `calendar_history.csv`;
- `model_metadata.json` and the installed `.onnx` hashes;
- tester HTML report and the trade list;
- `decisions.csv`, `rejections.csv`, `trades.csv`, `events.csv`,
  `daily_summary.csv`;
- the Python walk-forward and evaluation JSON, with flags;
- the validation log row (below).

```text
date | stage | period | symbols | params | model hash | expectancy R | PF | max DD % | trades | notes
```

Do not record a pass without the artifacts. A remembered result is not
evidence.

## 6. Interpreting journals

| File | Question it answers |
|---|---|
| `decisions.csv` | Why was each candidate approved or blocked? Filter by `stage`. |
| `rejections.csv` | Which gate stops most candidates? A single dominant stage usually means a misconfiguration, not a market insight. |
| `trades.csv` | Realized R, MAE/MFE, slippage. Compare with the model's expectations. |
| `daily_summary.csv` | Day-level returns, trade counts, peak heat, halt reason. |
| `events.csv` | Startup, halts, configuration, reconcile, errors. |

Common misreadings:

- **Many `no_setup` decisions** with few `ml` rejections means the strategy
  gate, not the model, is binding. Lowering the ML threshold will not help.
- **Many `spread` rejections** means the CSV cap is too tight for the tested
  session, or the symbol's typical spread changed.
- **`news` rejections on every symbol** means the calendar CSV is stale or the
  time basis is wrong (`InpCalendarTimeBasis`).
- **`ml` rejections at a fixed probability** means the model is outputting a
  constant; check the feature vector and parity, not the threshold.

## 7. Known limitations

- The tester cannot validate the external AI endpoint.
- Bar history does not include historical spread; the EA uses live spread and
  the CSV ceiling, so tester spread behaviour depends on the tester's own
  spread model.
- Multi-symbol testing is sensitive to history availability per symbol; a
  missing symbol shows up as `no_data` rejections.
- The correlation estimate uses execution-timeframe closes and a fixed
  lookback; it is an approximation, not a risk model.
- Results from a synthetic or short sample are not evidence of edge. The
  Python test suite validates code paths only.

## 8. What to do when a test fails

1. Stop; do not tune on the failing period.
2. Identify the binding gate from `rejections.csv`.
3. Distinguish configuration (spread cap, calendar, model hash) from strategy
   (no setups, negative expectancy).
4. Fix the cause, then rerun the **same** period before touching parameters.
5. Record the failure and the change in the validation log.

Changing several parameters after a failure and reporting only the new result
is how a backtest becomes fiction.
