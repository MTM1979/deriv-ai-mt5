# Decisions, assumptions and deviations

The specification leaves several things open and a few parts cannot be built
exactly as written. This page records every choice, why it was made, and what
it costs. Read it before changing behaviour.

## 1. Pipeline order

**Specification (§8.1):** build candidate → validate → spread/session → ONNX →
AI → calendar → correlation/heat → size → order.

**Implementation:** duplicate/spread/market/session/data-quality → **calendar**
→ technical setup → ONNX → AI → risk (which includes correlation, heat,
daily/weekly, sizing) → execution.

**Why:** the calendar influences both the ML threshold (medium-impact add) and
the sizes; running it after inference would require re-scoring or throwing
away work. It is also cheaper to block an entry before inference. The risk
engine remains the last gate, as specified.

**Cost:** a candidate rejected for news never runs the model or the AI, so the
journals show fewer `ml`/`ai` rows than a literal §8.1 order would produce.
This is a behavioural difference, not a safety one.

## 2. AI is disabled in the tester and optimizer

`WebRequest` is unavailable there. The EA forces AI off regardless of inputs,
records `AI not used in tester/optimization`, and uses a multiplier of `1.0`.

**Tradeoff:** backtests cannot measure the AI filter's effect. The AI must be
validated on demo with `ai_audit.csv`, and its absence in the tester is stated
in every validation run.

**Rejected alternative:** stubbing the AI with a fixed multiplier. A stub
produces a backtest that looks like it includes the AI when it does not.

## 3. AI disabled by configuration means `1.0`, not veto

If `InpAiEnabled=false`, the AI contributes no reduction. This is the only
case where "AI off" does not fail closed. It is explicit and visible in the
journal.

**Why:** an operator disabling an optional advisor is a deliberate choice, not
a failure. An unavailable or invalid response is different: see below.

## 4. AI failure policy is explicit and defaults to veto

The policy file and `InpAiFallback` choose `veto` or `reduce`. Invalid JSON,
missing fields, out-of-range values, HTTP errors, timeouts, oversized
responses, low confidence and breaker-open states all count as unavailable.

`reduce` applies `fallback_reduce_factor` clamped to `[0,1]`. A zero factor
rejects through the risk engine (risk becomes zero), which is a veto in
practice.

**Assumption:** a 2xx response with a valid schema but `trade_allowed=true` and
`risk_multiplier=1.0` is a pass. The EA does not require a minimum confidence
for a pass; it uses `min_confidence` to decide whether the response is usable.
A response below it is treated as a failure and the fallback applies.

## 5. The AI can never raise risk

- The EA's `InpAiMaxRiskMultiplier` is a hard ceiling, clamped to `[0,1]`.
- The policy file cannot raise it; only lower the other knobs.
- The response multiplier is clamped to `[0,1]` and then to the EA ceiling
  before the risk engine sees it.
- The AI never receives or sets the lot size.

**Tradeoff:** an advisor that wants to say "this is unusually good, take more"
cannot. That is intentional; the specification says veto or reduce.

## 6. Reserved features fail loudly

`InpMlUseEnsembleMeta` (`ensemble_meta.onnx`) and `InpUsePendingBreakout`
(pending breakout orders) are not implemented. Enabling either fails
`ValidateConfig` with an explicit message.

**Why not remove them:** the specification names them; a chart preset that
enables them should fail with a clear reason instead of silently trading a
different system. The alternative — implementing partial behaviour — would be
worse than an honest gap.

**Related cleanup:** `InpMlMetaThreshold`, `InpPendingExpiryMin`,
`InpPendingOffsetAtr`, `InpAiAllowInTester` and `InpAiAllowOptimization` were
removed rather than left as dead inputs. Each had no effect; keeping them
would invite an operator to believe they did.

## 7. Sessions are UTC, with a detected server offset

Session windows, day anchors and the calendar CSV are UTC. The server offset is
detected from `TimeTradeServer() - TimeGMT()` and rounded to 15 minutes;
`InpUtcOffsetOverride` exists because the workstation clock may be wrong.

**Assumption:** the broker's server offset is a whole number of 15-minute
steps and does not change intraday. Both are normal for MT5 brokers, neither is
guaranteed. The EA warns when the offset moves by 30 minutes or more but does
not rewrite the windows.

**Weekly anchor:** ISO week computed on UTC dates, which resets Monday 00:00
UTC. The daily anchor uses `InpDayRollHourUtc`.

## 8. Rollover blocking is always on

The specification requires blocking entries during rollover. An earlier input
allowed disabling it; it was removed because it could contradict the safety
requirement and had no effect in the code. The window is configured, the block
is not optional.

**Tradeoff:** an operator who wants to trade the rollover cannot. That is
accepted; rollover spreads and gaps are exactly what the block is for.

## 9. One ATR period for signals and features

The symbol CSV has an `atr_period` column (specification §1.2). The EA enforces
that every enabled row equals `InpAtrPeriod`, and rejects startup on a
mismatch. The Python `IndicatorConfig.atr_period` must match too.

**Why:** the ONNX contract has exactly one ATR period. Per-symbol periods
would make the feature vector incomparable across symbols and with the model.
Silently ignoring the CSV column was rejected as a trap; rejecting the
mismatch makes the setting meaningful.

**Cost:** a portfolio that needs different ATR periods needs separate model
contracts, which this build does not support.

## 10. Candidate flags are derived from reason codes

`news_blocked` and `correlation_blocked` are set inside `Reject` from
`RC_NEWS_BLOCKED`/`RC_NEWS_UNAVAILABLE` and `RC_CORR_LIMIT`. They are not set
ad hoc at call sites.

**Why:** the flags and the reason code must not disagree. A single owner
prevents a future rejection path from forgetting one.

## 11. Correlation: same group always correlated; otherwise Pearson

- Same non-empty `correlation_group` → correlated, no computation.
- Different groups → `|Pearson| >= InpCorrelationThreshold` over
  `InpCorrelationLookback` execution bars.
- Unresolvable series → treated as correlated.

Group count is a hard rejection (`RC_CORR_LIMIT`). Correlated exposure is
reduced to headroom, not rejected outright, unless the headroom is zero.

**Why:** a hard exposure block would reject a valid trade that could simply be
smaller; a count limit is a structural constraint, not a sizing one.
Treating unresolved correlation as correlated is the conservative default.

**Assumption:** log-return Pearson on the execution timeframe is an adequate
proxy for portfolio dependence. It is not a stress correlation and it does not
model regime shifts.

## 12. Risk sizes down, never up

`Evaluate` starts at `min(risk_per_trade, symbol cap)` and only multiplies by
factors in `[0,1]`, then takes the minimum of every headroom. The lot is
floored to the volume step. If the minimum lot would exceed the requested risk
by more than `InpLotRiskTolerance`, the entry is rejected.

**Tradeoff:** small accounts may be unable to trade some symbols. That is
correct: the alternative is risk larger than configured.

## 13. Partial take-profit is off by default

The specification says to use partial profits only when validation shows they
improve the outcome. It ships disabled. Breakeven, trailing and time exit are
enabled.

**Assumption:** no validation evidence exists yet for this portfolio. Turning
partials on without evidence would reduce the sample and complicate
attribution.

## 14. Time exit and session invalidation

`InpExitOnInvalidation=true` closes a position when its symbol's session
profile no longer allows the current session. This is an interpretation of
"manage stop, targets, trailing, and time exit" plus the session model.

**Tradeoff:** a position opened near the end of a session may be closed earlier
than a pure time exit would. The alternative leaves a position running through
a session the strategy was never validated for.

## 15. News and model failure defaults are the blocking ones

- No calendar source → `BLOCK_ALL` (default).
- No usable model → reject entries (`allow_without_model=false`).
- Model load error → start in reject-only mode unless fail-on-load.
- Inference failure → circuit breaker, then rejections.

**Why:** the EA is allowed to be idle. It is not allowed to trade without the
gates the acceptance criteria assume.

**Tradeoff:** a misconfigured calendar or model looks like "the EA does not
trade". The journals name the reason; that is the intended diagnostic path.

## 16. State is fail-closed and halts are latched

- Missing `state.json` → fresh start.
- Malformed or wrong schema → init failure.
- Halts persist across restarts.
- `RESET` clears them; `InpResetHaltsOnInit` does too, explicitly.

**Why:** a restart after a drawdown or manual kill must not re-enable trading
silently. The cost is that an operator must perform a deliberate reset, which
is the point.

**Atomic write:** serialize to `state.json.tmp` then `FileMove(..., 
FILE_REWRITE)`. A crash leaves the previous file, not a truncated one.

## 17. Journal failures do not stop trading; journal init does

Once journals are open, a failed append is logged to the terminal and does not
block an order. If journals cannot be opened at init, the EA fails init.

**Why:** an append failure mid-session (disk full, lock) should not create an
unmanaged open position. Starting without any audit trail is different: that is
not an operating mode this build supports.

## 18. Model registry and thresholds are data

`model_metadata.json` owns file names, hashes, thresholds, output kind and
feature order. CSV risk/spread/ATR values are configuration. None of these are
compiled constants, except the 30-feature contract itself.

**Assumption:** one model per asset class (`fx`, `metal`, `index`). A symbol
maps to a model by its CSV `asset_class`. Per-symbol models would need a
contract change.

## 19. Python baseline and dependencies

- Stdlib-only: no NumPy, scikit-learn, onnx or onnxruntime is required to
  train, export, package or test.
- The baseline is L2 logistic regression with balanced class weights.
- ONNX is written by a minimal protobuf encoder that supports this graph.

**Why:** the verified environment had Python 3.15.2 with none of those
packages, and a pipeline that cannot run is not a deliverable. The baseline is
honest about being a baseline.

**Tradeoff:** stronger models require an external environment and
`models.package --onnx`. The contract in [04-models.md](04-models.md) is the
only interface that matters.

## 20. Labels are conservative

Triple-barrier labels enter at the next bar's open, use ATR stops and R
targets, and give the stop priority when both are touched in one bar.
`target_first` exists only for sensitivity runs.

**Why:** a backtest that assumes the target was hit first on ambiguous bars
overstates the edge. The cost is a pessimistic label and possibly a lower
measured AUC.

## 21. Research spread is a constant

MT5 bar history has no spread. Training and evaluation take `--spread` in
points and use it for the spread-ratio feature and cost adjustment. The tester
and demo use live spread.

**Risk:** a model trained at one spread can behave differently when spreads
widen. Mitigation: spread-grid runs and the tester's spread stress, not a
hidden fudge factor.

## 22. Symbol names and contract specs come from the terminal

The CSV supplies logical names and strategy parameters. Resolution tries an
explicit override (override mode), the exact name, the configured suffix, then a
normalized, unambiguous-prefix search over every broker symbol. A row that does
not resolve is logged and skipped; startup fails only when no row resolves.
Point, digits, tick value, volume limits, stops level, margin and trade mode are
read live: at init, on every evaluation, and immediately before each order,
modification and close.

**Why:** Deriv can rename instruments and contract specs vary by account type.
Hardcoding either is a defect, not a convenience.

**Assumption:** the CSV's ten rows are illustrative. They are not verified
against a live Deriv terminal in this delivery.

## 23. One instance, magic is identity

Positions are owned by `InpMagic`. Running two instances with the same magic
double-manages positions. Running with a different magic orphans existing
positions.

**Assumption:** one terminal, one chart, one instance. This is not enforced by
the EA beyond the magic.

## 24. No Python config file

The pipeline is flag-driven. There is no `config.json` that looks authoritative
but is never read. Commands and defaults are in `python/README.md` and
[04-models.md](04-models.md).

## 25. Init order differs from the specification's phases

The specification describes phases; the implementation orders them by
dependency: journal → state → symbols → sessions → indicators → news → signals
→ ML → AI → risk → execution → reconcile.

**Why:** every later component needs the earlier one, and the journal must
exist before anything can fail. The observable behaviour matches the phases;
the order is an implementation detail, except for the pipeline change in §1.

## 26. What is still unknown

These are not decisions; they are unresolved facts. They must be verified
before the corresponding stage:

| Unknown | Why it matters | How to resolve |
|---|---|---|
| Exact Deriv symbol names and suffixes | The shipped CSV rows may not resolve. | Run `DiscoverDerivSymbols.mq5` on the account. |
| Deriv contract specs (stops level, tick value, margin) | Sizing and stop validity depend on them. | `ExportSymbols.mq5` and the terminal specification. |
| ONNX runtime behaviour in the terminal | The graph and metadata are validated, but no live inference was run here. | Attach the EA with a packaged model on demo; check the `ML` line and `ml_prob`. |
| Live calendar time basis | A wrong basis shifts blackout windows. | Compare a known event with the terminal calendar. |
| Broker server offset and DST behaviour | Session windows and anchors are UTC. | Check the startup offset line after each DST change. |
| Demo execution quality | Acceptance criterion 4.6. | Four weeks on demo, per [06-deployment.md](06-deployment.md). |
| Whether the baseline has any edge | The pipeline is not evidence of profitability. | Walk-forward and demo. |

## 27. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Hardcode Deriv symbol names | Breaks on rename; violates the "live broker data" requirement. |
| Read contract specs from the CSV | Stale data would size and place orders incorrectly. |
| Let the AI raise risk within a cap | Specification says veto/reduce only. |
| Backtest with a stubbed AI | Misleading evidence. |
| Use the tester to validate the AI | `WebRequest` is unavailable; impossible. |
| Ignore CSV `atr_period` silently | A setting that does nothing is a trap. |
| Fall back to a default lot when sizing fails | Increases risk without a decision. |
| Delete `state.json` automatically when corrupt | Destroys halt and position history. |
| Tune the model until the backtest is positive | Overfitting; no out-of-sample meaning. |
| Ship a `config.json` the pipeline never reads | Misleading. |
