# Operations

This is the runbook for a live or demo instance. It assumes the EA is already
deployed per [06-deployment.md](06-deployment.md).

## 1. Daily routine (10 minutes)

Do this once per trading day, ideally before the first session you trade.

1. **Terminal is connected.** No "No connection" banner; `events.csv` has no
   `ACCOUNT` errors since the last check.
2. **EA is running.** The chart shows a smiley, and `events.csv` ends with
   `ready` or normal decision rows, not `DEINIT`.
3. **Halts.** Inspect `state.json` or the last `daily_summary.csv` row for a
   non-empty `halt_reason`.
4. **Equity and heat.** Compare `daily_summary.csv` `peak_heat_pct` with the
   configured heat limit. Heat near the cap for several days is a warning.
5. **Slippage.** Check `trades.csv` recent `slippage_points` and the R
   multiple. Persistent slippage above assumption is a stop signal.
6. **Rejections.** Look at `rejections.csv` stage distribution. A new dominant
   stage usually means a changed market or a misconfiguration.
7. **Open positions.** The terminal's Trade tab and `state.json` should agree
   in count and ticket. A mismatch triggers reconcile on the next start only;
   investigate now.
8. **Calendar.** The next high-impact event is visible and the blackout window
   is correct for the day.
9. **Disk.** Journals have space; rotation is working. A full disk loses
   state, not just logs.

PowerShell helpers (adjust the path):

```powershell
$dir = "$env:APPDATA\MetaQuotes\Terminal\<instance>\MQL5\Files\DerivAIPortfolioEA"
Get-Content "$dir\events.csv" -Tail 20
Import-Csv "$dir\daily_summary.csv" | Select-Object -Last 5
Import-Csv "$dir\rejections.csv" | Group-Object stage | Sort-Object Count -Descending
Import-Csv "$dir\trades.csv" | Where-Object event -eq "close" | Select-Object -Last 10
```

The instance ID differs per terminal installation. Use **File → Open Data
Folder** once to locate it, or put the journal in `Common\Files` with
`InpJournalCommonFolder=true` and use a stable path.

## 2. Weekly routine (30 minutes)

- Review `daily_summary.csv` as a series: return, trades, max drawdown, peak
  heat, halt reason.
- Compute expectancy and profit factor from `trades.csv` closed rows and
  compare with the deployment stage's expectation.
- Review the strategy mix: are all four strategies producing, or is one
  carrying the account?
- Review symbol attribution; a single symbol dominating is a concentration
  risk even inside the position caps.
- Review `ai_audit.csv`: veto rate, multiplier distribution, fallback rate,
  errors. A sudden change in veto rate means the endpoint or prompt changed.
- Review the ML probability distribution in `decisions.csv` (`ml_prob`). A
  constant value means the model is not discriminating.
- Back up the journal directory and model files.
- Check the server-UTC offset after any DST transition. The session engine
  warns, but verify the session state against the clock.

## 3. Monthly routine

- Reconcile the month's realized drawdown against the configured limit and
  against the tester's distribution.
- Re-run the Python evaluation on the newest data as a **monitor**, not as a
  parameter-tuning loop. If the model has drifted, plan a retrain with
  walk-forward evidence.
- Review every incident: what happened, which gate caught it, what changed.
- Verify backups restore: copy the journal directory to a scratch machine and
  read `state.json`.
- Check model hashes still match metadata (`models.package --check`).

## 4. Kill switches

There are two kinds: automatic (latched by the EA) and manual (operator file).

### Automatic

| Halt | Trigger | Effect | Clear |
|---|---|---|---|
| Daily loss | equity loss from day anchor ≥ `InpMaxDailyLossPct` | entries stop | next day anchor; `RESET` |
| Weekly loss | loss from week anchor ≥ `InpMaxWeeklyLossPct` | entries stop | next week anchor; `RESET` |
| Drawdown | equity below peak by `InpMaxDrawdownPct` | entries stop; close-all once if configured | `RESET` only |
| Loss streak | `InpMaxConsecutiveLosses` in a row | entries stop | a win; `RESET` |
| Slippage | average slippage > `InpMaxAvgSlipRatio` after `InpMinTradesForSlipHalt` | entries stop | `RESET` only |
| Rejections | broker rejections today > `InpMaxRejectionsPerDay` | entries stop | next day; `RESET` |
| News blackout | high-impact event window | entries stop for affected symbols (or all) | window ends |
| Spread | spread above the symbol ceiling | that candidate rejected | spread normalizes |
| AI/ML/calendar failure | policy-dependent | reject or reduce | source recovers; breaker timer |

### Manual

Create a file named exactly `KILL` (no extension) in the journal directory:

```powershell
$dir = "$env:APPDATA\MetaQuotes\Terminal\<instance>\MQL5\Files\DerivAIPortfolioEA"
New-Item -ItemType File "$dir\KILL" -Force
```

Within one loop, the EA latches the manual halt, journals
`manual kill switch latched by KILL file`, and stops entries. It does not close
positions automatically (unless a drawdown halt also trips). Deleting `KILL`
does **not** clear the halt; that is intentional. Use `RESET` when the incident
is resolved:

```powershell
New-Item -ItemType File "$dir\RESET" -Force
```

`RESET` clears every halt and deletes itself. It does not change positions,
state anchors or open risk.

**When to use KILL:** unexplained losses, a broker symbol change, an errant
model, a calendar/timezone error, a runaway rejection rate, or any situation
where you cannot explain the next order. When in doubt, KILL.

## 5. Restart and state

### Clean restart

1. `KILL` (optional but recommended while you inspect).
2. Remove the EA from the chart. This triggers `OnDeinit` and a final state
   save.
3. Inspect `events.csv` for `DEINIT` and any save error.
4. Reattach. `OnInit` saves, reconciles, and rebuilds the loss streak.
5. Verify `RECONCILE` and `ready` lines.

### Corrupt or missing state

| Situation | Action |
|---|---|
| `state.json` missing | Fresh start. The EA rebuilds the loss streak from history but not planned risk for open positions. Reconcile runs. |
| `state.json` malformed | Startup fails. Restore a backup, or deliberately remove it and reconcile open positions manually. |
| Schema mismatch | Same as malformed. Do not edit `schema` down; the fields may not mean the same thing. |
| Positions on the account but not in state | Journaled as untracked and managed conservatively. Verify each one; the EA will not invent risk metadata. |
| State positions absent from the account | Journaled and removed on reconcile. This is normal after a manual close. |

Never edit `state.json` to clear a halt. Use `RESET`, so the change is
journaled.

## 6. Model operations

- Install to a new file name, verify with `models.package --check`, then
  reattach. See [04-models.md](04-models.md#10-replacement-and-rollback).
- Roll back by restoring the previous metadata entry and `.onnx`.
- A hash mismatch makes that asset class reject-only (default). That is not a
  crash; check `events.csv` for the reason.
- Do not enable `InpMlAllowWithoutModel` in demo or live to "get trading
  again". It removes the gate the acceptance criteria assume.

## 7. Calendar operations

- **Live calendar preferred**; the CSV is the fallback and the tester source.
- If live times look shifted by the server offset, flip
  `InpCalendarTimeBasis` and verify against a known event. CSV times are always
  UTC.
- Refresh the CSV before a long test or when the terminal cannot reach the
  calendar.
- If no source is available and the policy is `BLOCK_ALL` (default), entries
  stop. That is the correct failure; do not switch the policy to `ALLOW` to
  keep trading without understanding why the calendar is down.

## 8. Monitoring dashboard

The specification's §10.2 list maps to the journals as follows.

| Metric | Source |
|---|---|
| Equity, balance | Terminal; `daily_summary.csv` end-of-day. |
| Daily/weekly P&L | `daily_summary.csv`, `trades.csv` |
| Open risk and portfolio heat | `state.json` positions, `daily_summary.csv` `peak_heat_pct` |
| Win rate, expectancy, profit factor | `trades.csv` closed rows (R multiples) |
| Average win/loss | `trades.csv` |
| Slippage and spread | `trades.csv` `slippage_points`, `decisions.csv` `spread_points` |
| Rejections and failures | `rejections.csv`, `events.csv` |
| AI confidence distribution | `ai_audit.csv` |
| ML probability distribution | `decisions.csv` `ml_prob` |
| Strategy-level performance | `trades.csv` + `decisions.csv` `strategy` |
| Symbol-level performance | `trades.csv` + `decisions.csv` `symbol` |
| Session-level performance | `decisions.csv` `session`; `trades.csv` by open time |
| News-window performance | `decisions.csv` `minutes_to_event`, `event_impact` |

A spreadsheet pivot over `trades.csv` is enough. Do not build a dashboard that
the EA depends on; journals are append-only and safe to read.

## 9. Common incidents

| Symptom | Likely cause | First action |
|---|---|---|
| No entries for hours | Session closed, all symbols filtered, halt latched, or calendar `BLOCK_ALL` | Check `rejections.csv` stages and `state.json` halt. |
| `spread` rejections dominate | CSV cap too tight or broker widened spreads | Compare `spread_points` with the cap; adjust the CSV deliberately. |
| `no_data` rejections | History not downloaded, tick stale, or symbol not in Market Watch | Open the chart, scroll back, keep the symbol selected. |
| `SYMBOLS` error at start | A CSV row does not resolve | Run `DiscoverDerivSymbols`, fix name/suffix/override. |
| `ATR period mismatch` | CSV and `InpAtrPeriod` differ | Make them equal; the feature contract has one period. |
| `ML` rejections at a constant probability | Feature vector degenerate, stale model, or parity bug | Check parity samples and the model hash. |
| `AI` fallback every decision | Endpoint/auth/timeout/HTTPS whitelist | Test the endpoint outside the EA; check the terminal URL whitelist. |
| `PROTECTION` error | Broker rejected SL/TP, stops level changed, or filling mode | The EA closes the fill when configured; investigate the symbol spec. |
| `RECONCILE` on every start | State not saving, wrong magic, or journal dir not writable | Check `STATE` errors and disk permissions. |
| Halt will not clear | Drawdown/slippage/manual are latched | Use `RESET`; do not edit state. |
| Offset warning after DST | Broker or workstation offset changed | Verify session state; set `InpUtcOffsetOverride` if the clock is unreliable. |

## 10. Evidence and privacy

- Journals contain symbol names, prices, setup ids, AI request/response text
  and error strings. Treat them as operational data, not public logs.
- The auth header value is never written. Do not paste request bodies into
  public issues without checking them.
- Keep journals for at least the validation period. Rotation preserves old
  files with a timestamp suffix; do not delete them during an incident.
- `state.json` contains position metadata and equity anchors. It is not
  secret, but it is not reconstructible from the journals alone.
