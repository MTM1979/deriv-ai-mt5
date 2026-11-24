# Inputs, files and schemas

Everything the EA reads is either an input (set per chart) or a file under
`MQL5/Files` (or `Common\Files`). This page documents both, with defaults and
the validation that runs before trading starts.

## Conventions

- **Percent** means percentage points: `0.35` is 0.35% of equity. Used for
  risk, heat, loss cutoffs, drawdown and margin.
- **Fraction** means `0..1`: `0.75` is 75%. Used for scales, multipliers and
  thresholds.
- **R** is the initial risk distance of a position: `|entry - initial stop|`.
- **Points** are broker points (`SYMBOL_POINT`), not pips.
- Values marked **reserved** are rejected at startup when enabled; they exist
  so a chart preset written from the specification fails loudly instead of
  being silently ignored.

## Symbols

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpSymbolCsv` | `deriv_symbols.csv` | non-empty | File in `MQL5/Files` (or `Common\Files`) that defines the portfolio. |
| `InpSymbolsCommonFolder` | `false` | – | Read the CSV from the terminal's shared `Common\Files`. |
| `InpSymbolSuffix` | `""` | – | Appended when the CSV name does not exist in the terminal. |
| `InpSymbolResolution` | `override` | `exact`, `suffix`, `override` | How a logical name becomes a broker symbol. |
| `InpSymbolOverrides` | `""` | `KEY=VALUE;…` | Explicit logical→broker map, consulted before the suffix rule. |
| `InpAutoSelectSymbols` | `true` | – | Add resolved symbols to Market Watch; required for history and ticks. |
| `InpSpecRefreshSeconds` | `60` | 5–3600 | Contract-spec cache lifetime for position management. Specs are re-read on every evaluation and immediately before every order, modification and close, regardless of this cache. |
| `InpMaxTickAgeSeconds` | `120` | 10–3600 | Reject a symbol whose last tick is older than this. |

Resolution order is: explicit override → `exact` (logical name as-is) →
`suffix` (logical name + suffix) → normalized, unambiguous-prefix search in
`override` and `search` modes. A row that resolves to nothing is logged and
skipped; startup fails only when no row resolves. The EA never guesses a Deriv
symbol name and never reads contract values from the CSV.

## Sessions (UTC)

Session windows are configured in UTC. The server offset is detected from
`TimeTradeServer() - TimeGMT()` and rounded to 15 minutes; a fixed offset is
available when the workstation clock is unreliable.

| Input | Default | Validation |
|---|---|---|
| `InpUtcOffsetOverride` | `99` | `-12..14`, or `99` for auto |
| `InpAsianStartHour/Min` | `0/0` | 0–23 / 0–59 |
| `InpAsianEndHour/Min` | `8/0` | 0–23 / 0–59 |
| `InpLondonOpenHour/Min` | `7/0` | 0–23 / 0–59 |
| `InpNyOpenHour/Min` | `13/30` | 0–23 / 0–59 |
| `InpRolloverStartHour/Min` | `20/45` | 0–23 / 0–59 |
| `InpRolloverEndHour/Min` | `21/15` | 0–23 / 0–59 |
| `InpOpeningRangeMinutes` | `30` | 5–180 |
| `InpPreopenMinutes` | `15` | 0–120 |
| `InpEnableAsian` | `true` | at least one session must be enabled |
| `InpEnableLondon` | `true` | " |
| `InpEnableNy` | `true` | " |
| `InpRiskScaleAsian` | `0.50` | 0–1 |
| `InpRiskScaleOpen` | `1.00` | 0–1 |
| `InpRiskScaleCore` | `0.90` | 0–1 |
| `InpRiskScalePreopen` | `0.50` | 0–1 |

Session states are `ASIA`, `LONDON_OPEN`, `LONDON_CORE`, `NY_OPEN`, `NY_CORE`,
`LONDON_NY_OVERLAP`, `PREOPEN_*`, `ROLLOVER` and `CLOSED`. Only states that
allow entries reach the signal engine. Rollover blocking is always on: it is a
specification safety requirement, not an option.

The session engine warns when the detected offset changes by 30 minutes or
more (a DST transition). Verify the windows after any DST change; the EA does
not rewrite them.

## Signals

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpExecTf` / `InpHtfTf` / `InpRangeTf` | `M15` / `H1` / `M5` | not `PERIOD_CURRENT` | Signal and feature timeframes. |
| `InpMinTechnicalScore` | `65` | 0–100 | Minimum weighted setup score. |
| `InpEnableTrend/Orb/Sweep/MeanRev` | `true` | – | Strategy master switches. |
| `InpRequireHtfAlignTrend` | `true` | – | Trend entries must align with HTF trend. |
| `InpAtrPctMinTrend/Orb/Sweep/MeanRev` | `0.25/0.35/0.30/0.00` | 0–1 | Volatility floor per strategy. |
| `InpAtrPctMaxMeanRev` | `0.80` | 0–1, ≥ min | Volatility ceiling for mean reversion. |
| `InpAdxTrendMin` | `22` | – | Trend needs ADX above this. |
| `InpAdxRangeMax` | `20` | – | Mean reversion needs ADX at or below this. |
| `InpAtrStopTrend/Orb/Sweep/MeanRev` | `1.50/1.20/1.00/1.20` | > 0 | Stop distance in ATR. |
| `InpRrT1*` / `InpRrT2*` | per strategy | > 0 | Target 1/2 in R. Mean reversion prefers the Bollinger-middle/VWAP structure and uses these as fallbacks when the structure is closer than 0.8R or behind entry. |
| `InpOrbBufferAtr` | `0.15` | – | Breakout buffer beyond the opening range. |
| `InpOrbMinRangeAtr` / `InpOrbMaxRangeAtr` | `0.50` / `3.00` | – | Reject too-tight or exhausted ranges. |
| `InpSweepBufferAtr` / `InpSweepMinWickAtr` | `0.10` / `0.50` | – | Sweep confirmation. |
| `InpSwingLookback` | `20` | – | Structural swing window. |
| `InpCooldownMinutes` | `30` | 0–1440 | Per-symbol, per-strategy re-entry cooldown. |
| `InpRiskScaleSweep/MeanRev` | `0.75` | – | Strategy risk scale. |
| `InpScoreWeight*` | `0.30/0.20/0.15/0.20/0.15` | – | Technical score weights. |
| `InpMediumNewsScoreAdd` | `0.03` | – | Added to the ML threshold near medium-impact news. |
| `InpMinBarsRequired` | `200` | ≥ 60 | Bars required before a symbol is scored. |
| `InpEmaFast/Mid/Slow` | `21/50/200` | increasing | EMA stack. |
| `InpRsiPeriod` | `14` | – | RSI. |
| `InpMacdFast/Slow/Signal` | `12/26/9` | – | MACD. |
| `InpBbPeriod` / `InpBbDeviation` | `20` / `2.0` | – | Bollinger. |
| `InpAdxPeriod` | `14` | – | ADX/DI. |
| `InpAtrPeriod` | `14` | 2–200 | ATR for signals **and** model features. |
| `InpAtrPercentileLookback` | `200` | – | ATR percentile window. |
| `InpVolumeLookback` | `20` | – | Volume ratio window. |
| `InpSwingFractal` | `2` | – | Fractal strength. |
| `InpOrbEntryWindowMin` | `90` | – | ORB entries only this long after the open. |
| `InpSweepMaxAdx` | `28` | – | Sweep requires a non-trending tape. |

The symbol CSV also carries `atr_period`. It must equal `InpAtrPeriod` for
every enabled row; a mismatch is a startup error because the ONNX feature
contract has exactly one ATR period. Similarly, the Python
`IndicatorConfig.atr_period` must match.

## Risk

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpRiskPerTradePct` | `0.35` | (0, 5]% | Base risk per entry. |
| `InpMaxPortfolioHeatPct` | `1.50` | ≥ risk per trade | Sum of open-position risk. |
| `InpMaxDailyLossPct` | `1.25` | > 0 | Daily loss cutoff. |
| `InpMaxWeeklyLossPct` | `3.50` | ≥ daily | Weekly loss cutoff. |
| `InpMaxDrawdownPct` | `9.00` | (0, 100] | Equity drawdown halt from peak. |
| `InpMaxCorrExposurePct` | `1.25` | > 0, ≤ heat | Correlated exposure ceiling. |
| `InpCorrelationThreshold` | `0.70` | 0–1 | `|Pearson|` treated as correlated. |
| `InpCorrelationLookback` | `120` | – | Correlation sample in exec bars. |
| `InpMaxOpenPositions` | `4` | 1–100 | Portfolio cap. |
| `InpMaxPosPerSymbol` | `2` | ≥ 1 | Per-symbol cap; also bounded by the CSV. |
| `InpMaxPosPerGroup` | `2` | ≥ 1 | Per-correlation-group cap. |
| `InpMaxMarginUsagePct` | `50` | – | Margin ceiling after the entry. |
| `InpMinFreeMarginPct` | `30` | – | Free-margin floor after the entry. |
| `InpLotRiskTolerance` | `1.25` | 1–3 | Allowed minimum-lot risk overshoot. |
| `InpMaxConsecutiveLosses` | `5` | – | Loss-streak halt. |
| `InpDayRollHourUtc` | `0` | – | Daily anchor hour (UTC). |
| `InpResetHaltsOnInit` | `false` | – | Clear latched halts at startup. |
| `InpCloseOnDrawdownHalt` | `true` | – | Close everything when drawdown trips. |
| `InpMaxAvgSlipRatio` | `0.35` | – | Slippage halt threshold in R. |
| `InpMaxRejectionsPerDay` | `3` | – | Broker-rejection halt threshold. |
| `InpMinTradesForSlipHalt` | `10` | – | Samples before the slippage halt applies. |
| `InpCorrelationEnabled` | `true` | – | Master switch for correlation math. |

Risk per trade is first reduced to the CSV `max_risk_pct` when that is lower,
then multiplied by the session, strategy, news and AI scales (each clamped to
`0..1`), then cut to the remaining heat, daily, weekly and correlated-exposure
headroom. A zero result rejects the entry. Sizing never rounds risk up beyond
`InpLotRiskTolerance`; if the minimum lot would exceed it, the entry is
rejected.

## Machine learning (ONNX)

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpMlEnabled` | `true` | – | Score candidates with the asset-class model. |
| `InpMlMetadataFile` | `model_metadata.json` | non-empty when ML is on | Model registry. |
| `InpMlModelDir` | `""` | – | Optional prefix for model file names. |
| `InpMlFailOnLoadError` | `false` | – | Fail init instead of starting in reject-only mode. |
| `InpMlRequireHash` | `true` | – | Every model must have a matching SHA-256. |
| `InpMlAllowWithoutModel` | `false` | – | Allow entries when no model is usable. |
| `InpMlDefaultThreshold` | `0.62` | (0,1) | Threshold for asset classes without a model entry. |
| `InpMlMaxFailures` | `5` | ≥ 1 | Consecutive inference failures before the model is quarantined. |
| `InpMlUseEnsembleMeta` | `false` | must stay `false` | Reserved; enabling fails startup. |
| `InpMlLogInference` | `false` | – | Log each score (verbose; off by default). |

Model-load failure with `InpMlFailOnLoadError=false` starts the EA in a
reject-only state for that asset class, not a crash. That is the default so an
operator can attach the EA and read the journal instead of watching init fail.

## External AI advisory

The AI can only veto or reduce risk. It never sees or sets the final lot size.

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpAiEnabled` | `false` | – | Master switch. Always disabled in the tester and optimizer. |
| `InpAiPolicyFile` | `ai_policy.json` | – | Transport, auth and policy details. |
| `InpAiMaxCallsPerHour` | `20` | ≥ 1 | Baseline; the policy file may override. |
| `InpAiCacheSeconds` | `300` | – | Baseline decision cache. |
| `InpAiTimeoutMs` | `3000` | 100–30000 | Baseline HTTP timeout; policy clamps to 250–5000. |
| `InpAiFallback` | `veto` | `veto`, `reduce` | Behaviour when the AI is unavailable. |
| `InpAiFallbackReduce` | `0.50` | 0–1 | Risk factor for `reduce`. |
| `InpAiMinConfidence` | `55` | 0–100 | Below this the response is treated as unusable. |
| `InpAiMaxRiskMultiplier` | `1.00` | (0,1] | Hard ceiling; the policy file cannot raise it. |
| `InpAiMaxFailures` | `3` | – | Consecutive failures before the breaker opens. |
| `InpAiBreakerSeconds` | `900` | – | Breaker duration. |
| `InpAiRequireHttps` | `true` | – | Reject non-TLS endpoints. |
| `InpAiMaxResponseBytes` | `65536` | 1024–65536 | Response size limit. |

The policy file is authoritative for `timeout_ms`, call limit, cache, fallback
mode, reduce factor, minimum confidence, response size, failure limit, breaker
duration and HTTPS. The EA's multiplier ceiling is applied after the policy is
loaded and is never raised by it. AI is hard-disabled in the tester because
`WebRequest` is unavailable there.

## News calendar

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpNewsEnabled` | `true` | – | Master switch. |
| `InpNewsCsv` | `calendar_history.csv` | required when live is off | Tester/outage fallback. |
| `InpNewsCommonFolder` | `false` | – | Read the CSV from `Common\Files`. |
| `InpNewsUseLiveCalendar` | `true` | – | Prefer the terminal calendar. |
| `InpNewsRefreshMinutes` | `15` | – | Cache refresh interval. |
| `InpNewsHighBlockBefore` | `30` | 0–240 | Blackout before high-impact events. |
| `InpNewsHighBlockAfter` | `15` | 0–240 | Blackout after high-impact events. |
| `InpNewsMediumWindowMin` | `120` | – | Medium-impact context window. |
| `InpNewsMediumRiskMult` | `0.75` | 0–1 | Risk factor near medium-impact events. |
| `InpNewsUnavailable` | `BLOCK_ALL` | enum | Policy when no calendar source exists. |
| `InpNewsHorizonHours` | `24` | 1–168 | Look-ahead for "next event". |
| `InpNewsGlobalBlackout` | `true` | – | A high-impact event blocks every symbol. |
| `InpCalendarTimeBasis` | `0` | `0`/`1` | Live calendar times: `0` server, `1` UTC. CSV is always UTC. |

The three unavailable policies are `BLOCK_ALL`, `BLOCK_HIGH_RISK` (metals and
indices) and `ALLOW`. The default fails closed.

## Execution

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpMagic` | `20261116` | non-zero | Ownership tag for positions and history. |
| `InpAllowLong` / `InpAllowShort` | `true` | – | Master direction switches. |
| `InpMaxSpreadMultiplier` | `2.00` | > 0 | Cap when the CSV has no spread ceiling. |
| `InpSpreadBufferPoints` | `5` | – | Extra distance beyond the broker stops level. |
| `InpDeviationFx/Metal/Index` | `20/50/100` | ≥ 0 | Maximum deviation in points. |
| `InpMaxRetries` | `3` | 0–20 | Retryable attempts only. |
| `InpRetryPauseMs` | `500` | – | Pause between attempts. |
| `InpVerifyProtection` | `true` | – | Confirm SL/TP after the fill. |
| `InpCloseIfNoProtection` | `true` | – | Close a fill whose protection cannot be set. |
| `InpUsePendingBreakout` | `false` | must stay `false` | Reserved; enabling fails startup. |
| `InpBreakevenEnabled` | `true` | – | Move stop to breakeven. |
| `InpBreakevenAtR` | `1.00` | > 0 | Trigger in R. |
| `InpBreakevenBufferAtr` | `0.05` | – | Buffer beyond entry. |
| `InpTrailEnabled` | `true` | – | ATR trailing stop. |
| `InpTrailStartR` | `1.50` | > 0 | Trailing activation. |
| `InpTrailAtrMult` | `1.00` | – | Trail distance. |
| `InpTrailMinStepAtr` | `0.20` | – | Minimum improvement before modifying. |
| `InpPartialEnabled` | `false` | – | Partial take-profit. |
| `InpPartialAtR` | `1.50` | – | Partial trigger. |
| `InpPartialPct` | `0.33` | [0,1) | Fraction closed. |
| `InpTimeExitEnabled` | `true` | – | Time-based exit. |
| `InpMaxHoldMinutes` | `240` | ≥ 5 | Maximum hold. |
| `InpTimeExitMinR` | `0.30` | – | Close at time exit below this R. |
| `InpExitOnInvalidation` | `true` | – | Close when the symbol's session no longer allows it. |
| `InpModifyRetries` | `2` | – | SL/TP modify attempts. |
| `InpDryRun` | `false` | – | Log the full path, send nothing. |
| `InpEnableTrading` | `true` | – | Master execution switch. |

Retries apply only to retryable return codes (requotes, price changed, trade
context busy, timeout). A rejected order is not retried blindly. Every retry
re-reads the live spec.

## Journal

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpJournalEnabled` | `true` | – | Write CSV journals. |
| `InpJournalDir` | `DerivAIPortfolioEA` | – | Directory for journals and `state.json`. |
| `InpJournalCommonFolder` | `false` | – | Write to `Common\Files`. |
| `InpJournalVerbosity` | `2` | 0–2 | `0` errors, `1` decisions, `2` verbose (includes AI payloads). |
| `InpJournalRejections` | `true` | – | Write `rejections.csv`. |
| `InpJournalMaeMfe` | `true` | – | Track and journal MAE/MFE. |
| `InpJournalDailySummary` | `true` | – | Write `daily_summary.csv`. |
| `InpJournalMaxMb` | `32` | 0–1024, 0 = no rotation | Rotate a journal file above this size. |

## Runtime

| Input | Default | Validation | Effect |
|---|---|---|---|
| `InpTimerSeconds` | `5` | 1–300 | Timer period; `OnTick` also drives the loop. |
| `InpMaxLoopMs` | `3000` | 100–60000 | CPU budget per loop; aborts the symbol scan cleanly. |
| `InpFailOnModelLoad` | `false` | – | Equivalent to `InpMlFailOnLoadError`; either one fails init. |
| `InpPrintBanner` | `true` | – | Print account context at startup. |

The optimizer does not run the timer; it calls the loop from `OnTick`, which
keeps optimization passes deterministic.

## Symbol CSV (`deriv_symbols.csv`)

Header names are matched case-insensitively, so column order and extra columns
are tolerated. `symbol`, `asset_class` and `session_profile` are required.
Blank lines and lines starting with `#` are skipped.

| Column | Required | Default | Meaning |
|---|---|---|---|
| `symbol` | yes | – | Logical name or exact broker name; the key used in overrides, journals and the model config. The shipped index rows use exact Deriv names. |
| `asset_class` | yes | – | `fx`, `metal` or `index` (aliases accepted). Unknown disables the row. |
| `base_currency` | no | `""` | Informational; used by the AI request. |
| `quote_currency` | no | `""` | Informational; used by the AI request. |
| `session_profile` | yes | `all` if blank | `all`, `london_ny`, `tokyo_london_ny`, `us_cash`, `europe_cash`, `asia`. |
| `max_risk_pct` | no | `0.35` | Per-symbol risk ceiling. |
| `max_spread_points` | no | `50` | Spread ceiling; `0` falls back to the observed baseline × `InpMaxSpreadMultiplier`. |
| `atr_period` | no | `14` | Must equal `InpAtrPeriod`; otherwise startup fails. |
| `min_atr_points` | no | `0` | Reject setups whose ATR is below this, in broker points (ATR ÷ `point`). Calibrate per contract; index values differ by an order of magnitude from FX. |
| `max_positions` | no | `1` | Per-symbol cap, additionally bounded by `InpMaxPosPerSymbol`. |
| `correlation_group` | no | asset class | Symbols sharing a group are always correlated. |
| `news_currencies` | no | `""` | Comma list (quote the CSV field); drives the calendar filter. |
| `enabled` | no | `1` | `0` keeps the row but excludes it from the portfolio. |
| `strategies` | no | `all` | `trend`/`orb`/`sweep`/`meanrev` joined by `\|`, or `none`, `all`. |

`strategies` is the only optional column not present in the shipped template.
Add it if you need per-symbol strategy selection; `atr_period` is present and
must still equal `InpAtrPeriod`.

The EA reads point, digits, tick size/value, contract size, volume limits,
stops/freeze levels, margin, trade mode, filling modes and session schedule
from the terminal at init, on every evaluation and immediately before each
order, modification and close. Editing those values in the CSV has no effect.

## `model_metadata.json`

```json
{
  "schema": 1,
  "feature_order": ["ret_1", "...", "direction"],
  "models": [
    {
      "key": "fx",
      "asset_class": "fx",
      "file": "models/fx.onnx",
      "version": "2026-11-01",
      "sha256": "…64 hex chars…",
      "threshold": 0.63,
      "output_kind": "binary_two",
      "output_size": 2
    }
  ]
}
```

- `schema` must be `1`.
- `feature_order` must match `FeatureSpec.mqh` exactly (30 names, same order).
- `file` is relative to `MQL5/Files` unless `InpMlModelDir` supplies a prefix.
- `sha256` is required when `InpMlRequireHash=true`; an empty hash blocks the
  model.
- `output_kind` is `binary_two` (`[1,2]` + Softmax) or `binary_one`
  (`[1,1]` + Sigmoid).
- `threshold` is the probability gate for that key.
- `version` is free text and appears in the startup journal.

Generate and validate it with `python -m models.package`; do not hand-edit
hashes. See [04-models.md](04-models.md).

## `ai_policy.json`

| Field | Required | Meaning |
|---|---|---|
| `schema` | yes | Must be `1`. |
| `endpoint` | yes | `https://…` (or `http://` when HTTPS is not required). |
| `model` | no | Sent to the advisor as a model hint. |
| `auth_header_name` / `auth_header_value` | no | Static auth header. If a name is present, a value is required. |
| `timeout_ms` | no | Clamped to 250–5000. |
| `max_calls_per_hour` | no | Clamped to 1–600. |
| `cache_seconds` | no | Clamped to 0–3600. |
| `fallback` | no | `veto` or `reduce`. |
| `fallback_reduce_factor` | no | Clamped to 0–1. |
| `min_confidence` | no | Clamped to 0–100. |
| `max_response_bytes` | no | Clamped to 256–65536. |
| `max_consecutive_failures` | no | Clamped to 1–100. |
| `breaker_seconds` | no | Clamped to 10–86400. |
| `require_https` | no | Boolean. |

The shipped file points at `example.invalid` and contains no usable
credential. It is inert while `InpAiEnabled=false`. Treat
`auth_header_value` as a secret: the journal redacts it, but the file itself is
plain text.

## `calendar_history.csv`

```csv
event_id,time_utc,currency,country,event,impact,forecast,previous,actual
1,2026-11-17 13:30,USD,United States,CPI m/m,3,0.2,0.1,
```

- `time_utc` is `YYYY-MM-DD HH:MM`, UTC.
- `impact` is `1` low, `2` medium, `3` high (text values `low`/`medium`/`high`
  are also accepted).
- `currency` is matched against each symbol's `news_currencies`.
- Other columns are informational and may be empty.

`ExportCalendar.mq5` produces this format. The shipped file contains 2020
placeholder rows so the parser has something to read; replace it before
relying on the filter.

## Runtime files

All paths are relative to `MQL5/Files` unless `InpJournalCommonFolder=true`.

### `state.json`

Written atomically (temp file + `FileMove` with rewrite). A missing file is a
fresh start. An unreadable file, wrong schema or malformed positions fail
startup; the EA never trades on unknown state.

| Field | Meaning |
|---|---|
| `ea`, `version`, `schema`, `saved_at` | Identity and schema (`1`). |
| `day_id`, `week_id` | Anchors derived from UTC and `InpDayRollHourUtc`. |
| `day_start_equity`, `week_start_equity` | Equity at the anchor. |
| `peak_equity`, `last_equity` | Drawdown reference and last mark. |
| `consecutive_losses` | Loss-streak counter. |
| `rejections_today` | Broker rejection counter. |
| `slip_count`, `slip_sum_ratio` | Slippage samples in R. |
| `halt` | Latched `daily_loss`, `weekly_loss`, `drawdown`, `loss_streak`, `slippage`, `rejections`, `manual`, plus `reason` and `since`. |
| `positions[]` | One record per owned position: ticket, symbol, strategy, direction, entry, stops, risk, MAE/MFE, AI/ML values, flags, timestamps, setup id, comment. |

Halts are latched: they stay set across restarts until `RESET` or
`InpResetHaltsOnInit` clears them. Daily and weekly halts also clear when the
anchor rolls forward.

### Journals

| File | Header (abridged) | Contents |
|---|---|---|
| `decisions.csv` | time, bar_time, symbol, strategy, direction, regime, session, score, ml_prob, ai_mult, scales, risk_pct, lot, spread, atr, news, entry/stop/tp, setup_id, outcome, reason, detail, stage, notes | One row per evaluated candidate, including approvals and dry runs. |
| `rejections.csv` | time, symbol, strategy, stage, reason, session, regime, direction, entry, stop, detail | One row per rejection at any stage. |
| `trades.csv` | time, event, ticket, symbol, strategy, direction, lots, price, initial_stop, sl, tp, risk_money, r_multiple, mae_r, mfe_r, slippage, setup_id, note, opened_at, closed_at | Open, close, partial and modify events. |
| `ai_audit.csv` | time, symbol, decision, multiplier, confidence, reason, fallback, available, request, response, error | Redacted AI request/response pairs. |
| `events.csv` | time, level, code, text | Lifecycle, halts, configuration and error events. |
| `daily_summary.csv` | time, day_id, start_equity, end_equity, return_pct, net_pnl, trades, wins, losses, r_sum, max_dd_pct, peak_heat_pct, halt_reason, currency | One row per trading day. |

Rotation renames a file to `<name>_<timestamp>.csv` when it exceeds
`InpJournalMaxMb` (0 disables rotation).

### Operator files

| File | Action |
|---|---|
| `<journal dir>/KILL` | Latches the manual halt. Entries stop; open positions continue to be managed unless the halt type closes them. Delete the file after the incident is resolved; the halt stays latched. |
| `<journal dir>/RESET` | Clears every latched halt, then deletes itself. Manual halt included. |

Both are checked once per loop. The `KILL` file is deliberately not
auto-deleted: presence is the audit trail.

## Coupled constraints

Startup fails unless all of these hold:

- at least one session enabled;
- EMA periods strictly increasing, `min_bars_required >= 60`;
- `max_portfolio_heat_pct >= risk_per_trade_pct`;
- `max_weekly_loss_pct >= max_daily_loss_pct`;
- `0 < max_correlated_exposure_pct <= max_portfolio_heat_pct`;
- per-symbol and per-group position caps `>= 1`;
- ML metadata file non-empty when ML is enabled;
- live calendar off requires a calendar CSV;
- `InpUsePendingBreakout` and `InpMlUseEnsembleMeta` false;
- each enabled CSV `atr_period` equals `InpAtrPeriod`.

Change these in the input dialog, not by editing `state.json`.

## Changing inputs safely

1. Stop trading: set `InpEnableTrading=false` or create `KILL`.
2. Back up the journal directory, including `state.json`.
3. Change one risk-affecting parameter at a time.
4. Reattach the EA. Changing inputs triggers `OnDeinit`/`OnInit`; state is
   saved and reloaded, halts stay latched.
5. Watch `events.csv` for the startup summary and `decisions.csv` for the
   effect.

Changing `InpMagic` orphans existing positions as far as the EA is concerned.
Close them first, or keep the magic and accept the old positions are outside
the new state.
