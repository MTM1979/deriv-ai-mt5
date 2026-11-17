# Architecture

The EA is a single expert advisor with one include per responsibility. This
page describes who owns what, the order of operations, and the invariants that
must survive future changes.

## Module map

| File | Owns | Does not own |
|---|---|---|
| `Config.mqh` | Enums, structs, defaults, reason codes and their names. | Reading inputs, validating them, I/O. |
| `Utils.mqh` | String/number/time helpers, CSV splitting, file and folder helpers, logging. | Trading semantics. |
| `Json.mqh` | Minimal JSON parse/write with typed accessors. | Schema knowledge. |
| `FeatureSpec.mqh` | Generated 30-feature order and clamp bounds. | Feature arithmetic. |
| `SymbolSpec.mqh` | CSV ingestion, logical→broker resolution, live contract snapshot, spread/market query. | Strategy, risk, sizing. |
| `Sessions.mqh` | UTC conversion, session state machine, risk scale, warnings. | Position management. |
| `Indicators.mqh` | Per-symbol indicator handles, snapshot build, data-quality checks. | Interpreting the snapshot. |
| `SignalEngine.mqh` | Four strategies, weighted score, one candidate per symbol per bar. | ML, AI, risk, execution. |
| `OnnxModel.mqh` | Metadata, hash, shape and feature validation, inference, circuit breaker, feature vector construction. | Any decision beyond the probability. |
| `AiAssistant.mqh` | Policy file, request/response, validation, cache, rate limit, breaker, veto/reduce decision. | Sizing or execution. |
| `NewsCalendar.mqh` | Live calendar + CSV fallback, blackout, medium-impact multiplier, next event. | Trading decisions. |
| `RiskEngine.mqh` | Final gate: halts, counts, correlation, headroom, sizing, margin and stop viability. | Sending orders. |
| `Execution.mqh` | Order send/retry, fill verification, protection repair, trailing/breakeven/partial/time exits, reconciliation. | Deciding to trade. |
| `State.mqh` | Atomic persistence of equity anchors, halts, counters and position metadata. | Journals. |
| `Journal.mqh` | Six append-only CSVs, rotation, redaction. | State or decisions. |
| `DerivAIPortfolioEA.mq5` | Inputs, validation, wiring, loop budget, operator files, orchestration. | Any of the above semantics. |

Dependencies point inward: `Config`/`Utils`/`Json` know nothing; domain modules
know config and shared structs; the EA composes them. No include calls another
module's private state. The EA is the only place that holds globals.

## Startup sequence

`OnInit` stops at the first failure; nothing trades before the last step.

1. `PrintBanner` — build, account, server, currency, leverage, tester flags.
2. `BuildConfig` — copy inputs into one `EAConfig`; compute the state path.
3. `ValidateConfig` — reject incoherent input combinations before any I/O.
4. `Journal.Init` — journals come first so later failures are recorded.
5. `EnsureFolder` + `State.Init` + `State.Load` — an unreadable or
   schema-mismatched `state.json` fails init.
6. Symbol CSV load and resolution; ATR-period consistency; warnings journaled.
7. Session engine init and first update; DST/offset warning.
8. Indicator hub init.
9. Calendar currencies collected, news init, first refresh; an unavailable
   calendar is a warning, then the runtime policy decides.
10. Signal engine init.
11. ONNX metadata and models; failure is a warning plus reject-only mode unless
    fail-on-load is set.
12. AI init; disabled in tester/optimizer regardless of inputs.
13. Risk engine init, attach to state and registry, first account read.
14. Execution init.
15. Initial state save, reconcile open positions, rebuild consecutive losses
    from history.
16. Timer (disabled in optimization), `ready` event.

Any error before step 16 returns `INIT_FAILED` or
`INIT_PARAMETERS_INCORRECT` and writes the reason to `events.csv` when the
journal is already open.

## Per-loop sequence

`OnTick` and `OnTimer` both call `ProcessAll`. In the optimizer only `OnTick`
runs, so results are deterministic.

```text
ProcessAll
  session update (offset, state, scales)
  account refresh (equity, margin)      -> abort loop on failure
  state.UpdateEquity
  RollAnchors (day/week)
  CheckOperatorFiles (KILL / RESET)
  HaltCheck                            -> close-all on drawdown (once)
  ManageAll (open positions)
  if halted: stop
  for each enabled symbol (loop budget):
      new closed bar? -> EvaluateSymbol
```

`ManageAll` runs even when halted: protective exits must keep working. New
entries stop.

### Loop budget

`InpMaxLoopMs` bounds the symbol scan. When exceeded, the loop journals
`BUDGET` and breaks. Symbols later in the list are evaluated on the next timer
tick, so a slow broker call cannot starve the whole portfolio indefinitely.
The budget is checked between symbols, not inside an HTTP or order call; those
have their own timeouts.

## Decision pipeline (`EvaluateSymbol`)

The order is deliberately different from the specification's §8.1 listing
(which puts ONNX before the calendar). It is documented in
[08-decisions.md](08-decisions.md).

```text
0. bar gate + per-symbol warmup
1. duplicate guard (same symbol + bar already has a position)
2. live spread vs CSV cap (or baseline × multiplier)
3. broker market open
4. session allows entries
5. data quality: bars, tick age, ATR minimum
6. calendar context (blackout, medium-impact multiplier, next event)
7. technical setup (one candidate, highest weighted score)
8. ONNX probability vs threshold (+ medium-news add)
9. external AI (veto / reduce; disabled => 1.0)
10. risk gate (halts, counts, correlation, headroom, sizing, margin)
11. execution (or dry-run journal)
12. position record + journal
```

Every path that stops calls `Reject` exactly once, which writes one
`decisions.csv` row and one `rejections.csv` row. `Reject` also derives the
candidate's `news_blocked` and `correlation_blocked` flags from the reason
code, so those fields cannot disagree with the journal.

### Candidate fields

`TradeCandidate` carries the fields the specification requires: symbol,
direction, strategy, entry/stop/targets, ATR, technical score, ML probability,
AI multiplier, regime, session, news/correlation flags, approval, reason and
reason text, plus the scales and journal context. It is a value passed through
the pipeline; nothing downstream mutates the strategy's original levels except
`Execution`, which records the actual fill and protection.

### Signal priority

The four strategies run in a fixed order and all may produce a candidate. The
engine keeps the highest weighted score and returns at most one candidate per
symbol per bar. A cooldown blocks the same symbol+strategy from immediate
re-entry. The technical score is a weighted sum of trend, momentum, volatility,
location and structure sub-scores, normalized by the sum of weights, then
compared with `InpMinTechnicalScore`.

## Risk math

`CRiskEngine::Evaluate` is the only place that computes a lot size.

```text
base   = min(risk_per_trade_pct, symbol.max_risk_pct)
risk   = base × session_scale × strategy_scale × news_scale × ai_scale
risk   = min(risk, heat_headroom)
risk   = min(risk, daily_headroom)
risk   = min(risk, weekly_headroom)
risk   = min(risk, correlated_headroom)
money  = equity × risk / 100
lot    = money / risk_per_lot(direction, entry, stop)
```

Then:

- `lot` is floored to the broker volume step;
- if `lot` would exceed the requested risk by more than
  `InpLotRiskTolerance`, the entry is rejected rather than rounded up;
- stop and target must respect `SYMBOL_TRADE_STOPS_LEVEL` plus
  `InpSpreadBufferPoints`;
- the resulting margin must stay below `InpMaxMarginUsagePct` and leave at
  least `InpMinFreeMarginPct` free;
- the volume must be within `SYMBOL_VOLUME_MIN/MAX` and one step.

`risk_per_lot` converts a price distance to account currency using the live
tick value, contract size and currency conversion from the terminal. A zero or
non-finite result rejects the entry; there is no fallback estimate.

### Headroom semantics

- **Heat** is the sum of open risk in percent of current equity, estimated
  from entry-to-stop distance, not from floating P&L.
- **Daily/weekly loss** use the anchor equity and current equity; they also
  account for floating loss, so a bad open position consumes headroom.
- **Correlated exposure** is the sum of open risk in positions correlated with
  the candidate, not the whole portfolio.
- **Drawdown** is measured from peak equity and is a latched halt, not a
  headroom value.

All four are recomputed from live account and position data each loop; none is
cached across loops except the correlation series memo within one evaluation.

### Correlation

Correlation groups come from the CSV. Two positions are correlated when:

- they share the same non-empty `correlation_group`, or
- `|Pearson(log returns)|` over `InpCorrelationLookback` execution bars is at
  or above `InpCorrelationThreshold`.

When the correlation series cannot be computed (missing history), the pair is
treated as correlated. A candidate whose correlated exposure would exceed
`InpMaxCorrExposurePct` is rejected; if it merely would not fit, the risk is
reduced to headroom, including zero, which then rejects. Symbols in the same
group also obey `InpMaxPosPerGroup`; a group-count rejection returns
`RC_CORR_LIMIT` and marks the candidate.

The correlation series is memoized per symbol pair within an evaluation to
avoid repeated `CopyClose` calls. It is not persisted.

## Halt model

All halts are latched in `state.json`:

| Halt | Trips when | Clears |
|---|---|---|
| daily loss | daily loss ≥ limit | next day anchor, or `RESET` |
| weekly loss | weekly loss ≥ limit | next week anchor, or `RESET` |
| drawdown | equity drawdown ≥ limit | `RESET` only |
| loss streak | consecutive losses ≥ limit | a win, or `RESET` |
| slippage | average slippage > limit after N trades | `RESET` only |
| rejections | broker rejections today > limit | next day anchor, or `RESET` |
| manual | `KILL` file | `RESET` or `InpResetHaltsOnInit` |

`HaltCheck` runs before entries and before `ManageAll`'s snapshot work. A
drawdown halt with `InpCloseOnDrawdownHalt=true` closes every owned position
once, then keeps the halt latched. Other halts stop new entries but let
protection and exits work.

Latching is deliberate: a restart must not silently re-enable trading after a
risk event. That is also why `RESET` is a file an operator must create, not a
button in the EA.

## Persistence

`state.json` is the only mutable state. It is written:

- after init and after every entry/exit/partial/modify that changes metadata;
- when counters change (loss streak, rejections, slippage);
- on deinit;
- after halt changes.

The write is atomic: serialize to `state.json.tmp`, then
`FileMove(tmp, target, FILE_REWRITE)`. A crash between writes leaves the
previous file intact. A missing file is a fresh start; an unreadable file is a
startup failure.

`Reconcile` compares persisted positions with the account by magic number:

- a persisted position that no longer exists is closed in the journal and
  removed;
- an account position with the magic but no record is treated as untracked,
  journaled, and managed conservatively (it is not adopted with invented risk);
- volume/price drift is logged.

`RebuildLossStreak` scans closed history by magic to restore the streak after
a restart when the state file was lost or reset.

## Journals

Six CSVs, one writer (`CJournal`), append-only. Headers are written once per
file. Rotation renames the file when it exceeds `InpJournalMaxMb`. Writes are
best-effort: a journal failure logs to the terminal but never blocks trading.
The one exception is the initial journal open, which fails init, because
operating without an audit trail is not supported.

AI request/response bodies are written only at verbosity 2 and are redacted:
the auth header value is never written. Treat both the request and response as
untrusted text; they are quoted CSV fields, not executed.

## Failure domains

| Failure | Behaviour |
|---|---|
| Broker disconnected / account unavailable | Loop aborts, `ACCOUNT` error journaled, no entries. Open positions keep their server-side protection. |
| Symbol missing or not selectable | Init fails for a configured row; at runtime the symbol is skipped with a rejection/event. |
| Market closed / session closed | Candidate rejected with the specific reason; no order. |
| Spread too wide | Rejected before any model or AI call. |
| Stale tick / insufficient bars | Rejected with `RC_NO_DATA`; no inference on stale features. |
| ONNX load failure | Reject-only for that asset class unless `allow_without_model`; startup warning. |
| Inference failure | Circuit breaker after N consecutive failures; rejections. |
| AI unavailable | Policy: veto (default) or reduce; never a silent pass. |
| Calendar unavailable | Policy: block all (default), block high-risk, or allow. |
| Requote / context busy / timeout | Bounded retry with fresh spec; then rejection and rejection counter. |
| Protection cannot be set | Close the fill if configured; journal `PROTECTION` error. |
| State unreadable | Init fails. |
| Journal write failure | Terminal log only; trading continues. |
| Loop budget exceeded | `BUDGET` warning; remaining symbols deferred to the next tick. |

No failure path increases risk. The safe default in every policy is the
blocking one.

## Invariants

These are the rules a future change must not break:

1. The external AI multiplier and the configured ceiling are both clamped to
   `[0,1]`; neither can raise risk.
2. Session, strategy, news and AI factors multiply; they never add risk.
3. `Evaluate` returns a lot only when every headroom and viability check
   passed. There is no "best effort" size.
4. A rejection is journaled once, in one place.
5. Reason codes and candidate flags agree; flags are derived, not set ad hoc.
6. `state.json` is written atomically and read fail-closed.
7. Halts stay latched across restarts unless explicitly reset.
8. Position protection is verified after the fill; an unprotected fill is not
   left running silently.
9. The EA never writes contract specs; it reads them from the terminal.
10. Every model file is hash-verified before use when `require_hash` is on.
11. The feature order and bounds come from one generated header; Python and
    MQL5 compare against it.
12. The loop never blocks on one symbol longer than its own network/order
    timeouts and the journal records budget exhaustion.

## Threading and timing

MetaTrader calls `OnTick`/`OnTimer` sequentially per chart; there is no
application-level concurrency. The EA is attached once. Time semantics:

- `TimeTradeServer()` drives sessions, day/week anchors and position ages;
- `TimeGMT()` is used only to estimate the server-UTC offset;
- calendar CSV rows are UTC;
- live calendar rows are server time unless `InpCalendarTimeBasis=1`;
- journals record server time for events, and bar time for decisions.

A second instance with the same magic on another chart would double-manage the
same positions. The magic is the identity; run one instance.

## Generated code

`MQL5/Include/FeatureSpec.mqh` is generated by `python -m features.spec
--write-mqh` from `python/features/spec.py`. Do not hand-edit it. The others
are hand-written. `scripts/compile.ps1` compiles any `.mq5` with the project
`MQL5` root as the include path.
