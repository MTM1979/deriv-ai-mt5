# Deployment

Five stages, each with an entry gate and an exit gate. Do not skip a stage
because the tester looked good. The purpose of the gates is to make a bad
result cheap.

```text
Research -> Strategy Tester -> Demo -> Micro-live -> Scaled
```

The EA itself does not change between stages except for risk inputs and which
symbols are enabled. The models, code and contracts should be identical; if
they differ, the comparison is invalid.

## Stage 1 — Research

**Do**

- Export bars and the calendar from the actual Deriv terminal.
- Train and walk-forward per asset class; see [04-models.md](04-models.md).
- Verify feature parity after any feature change.
- Record the model hashes and the exact commands.

**Exit gate**

- A walk-forward aggregate with enough trades to be meaningful.
- The model is packaged and `models.package --check` passes.
- You can explain the label, the costs and the failure modes.

**Do not** proceed on in-sample metrics alone.

## Stage 2 — Strategy Tester

**Do**

- Run the sequence in [05-validation.md](05-validation.md), including
  restart/state and failure-injection tests.
- Test each symbol alone, then the portfolio.
- Keep the out-of-sample period untouched until parameters are frozen.

**Exit gate**

- Positive expectancy after costs and profit factor ≥ 1.3 out of sample.
- Max drawdown below the configured limit, with the strategy (not only the
  halt) controlling risk.
- Results survive spread stress, slippage stress and symbol holdout.
- No unexplained rejection stage dominates.

**Do not** proceed with a single profitable month, a single symbol carrying
the portfolio, or an unverified ONNX runtime path.

## Stage 3 — Demo (Deriv)

This is the first time the EA trades a real feed. The purpose is execution
fidelity, not profit.

**Setup**

| Item | Value |
|---|---|
| Account | Deriv demo, same server/leverage/currency as intended live |
| Symbols | The full intended portfolio, in Market Watch |
| Risk | Same as the tested configuration, or lower; never higher |
| AI | Off for the first week, then on only after the endpoint is verified |
| Journal | Default directory, verbosity 2, on a local disk you can inspect |
| Terminal | Running continuously; no sleep on the VPS |

**Run for at least four weeks.**

**Monitor daily**

- `events.csv` for `ERROR`, `KILL`, `STATE`, `PROTECTION`, `RECONCILE`;
- `trades.csv` slippage in R versus the tested assumption;
- `decisions.csv` stage distribution versus the tester;
- `daily_summary.csv` heat and drawdown;
- terminal journal for disconnects and trade-context errors.

**Exit gate**

- Demo expectancy inside the tester's confidence interval, not merely positive.
- Slippage, spread and rejection rates consistent with assumptions.
- No unexplained state or protection incident.
- Four weeks is a minimum, not a guarantee of statistical significance.

If demo diverges, stop and diagnose. Do not "wait for it to recover".

## Stage 4 — Micro-live

The first real-money stage. Size is chosen so that a total loss of the risk
budget is an acceptable cost of validation.

**Suggested starting point**

| Input | Demo value | Micro-live value | Reason |
|---|---|---|---|
| `InpRiskPerTradePct` | 0.35 | 0.10 | One third of demo risk. |
| `InpMaxPortfolioHeatPct` | 1.50 | 0.40 | Room for a few concurrent positions. |
| `InpMaxDailyLossPct` | 1.25 | 0.35 | A bad day stops early. |
| `InpMaxWeeklyLossPct` | 3.50 | 1.00 | A bad week stops early. |
| `InpMaxOpenPositions` | 4 | 2 | Fewer simultaneous bets. |
| `InpMaxCorrExposurePct` | 1.25 | 0.30 | Correlation headroom stays below heat. |
| `InpMlEnabled` | true | true | The gate is part of the system. |
| `InpAiEnabled` | true | true only if verified | Never enable an unverified endpoint live. |

Keep `InpMaxDrawdownPct` at the intended final value (default 9%) or lower;
scaling risk down should not relax the halt.

**Before the first order**

- [ ] Demo exit gate met and documented.
- [ ] `KILL` and `RESET` procedure rehearsed.
- [ ] Backups of `state.json`, journals and model files.
- [ ] Confirm the live account's contract specs match the demo (they can
      differ by account type).
- [ ] Confirm swap and commission in the terminal.
- [ ] Confirm the VPS clock/timezone and the detected server offset.
- [ ] Confirm the terminal will not restart mid-session for updates.

**Run for at least eight weeks.** Review weekly, not hourly.

**Exit gate**

- Live expectancy and slippage inside the demo range.
- No risk-limit breach.
- Operational incidents understood and fixed.
- You can state the worst realized drawdown and why it happened.

## Stage 5 — Scaled deployment

Increase size only after the micro-live gate. Scale in steps, never in one
move:

1. Raise per-trade risk first, heat second, position count last.
2. Keep daily/weekly limits proportional; a 1.5× risk with unchanged daily
   limit only changes how fast the halt trips.
3. Re-run the demo for a short period at the new risk if the change is large.
4. Re-check correlation headroom: more positions at the same heat means less
   per-position headroom.

There is no stage at which the EA should run without a human able to reach the
`KILL` file.

## Operating environment

| Item | Recommendation |
|---|---|
| Hosting | A Windows VPS close to the broker, with stable power and network. |
| Terminal | One instance, one chart with the EA. Auto-updates off during a session. |
| Clock | Windows time service enabled; verify the server offset after DST. |
| Disk | Local, monitored; journals and state must survive a reboot. |
| Backups | Daily copy of the journal directory and model files. |
| Remote access | Enough to place `KILL` and inspect logs; no unattended changes. |

Do not run the EA on a laptop that sleeps. A missed management loop can leave a
position without its trailing update, although the server-side stop remains.

## Change control

| Change | Gate |
|---|---|
| Code change | Recompile, rerun the tester smoke, then demo. |
| Model change | Package, verify hash, compare OOS, then demo. |
| Risk increase | Micro-live gate, then one step at a time. |
| New symbol | Single-symbol tester, then portfolio OOS; check correlation group. |
| New AI endpoint | Disabled first, then demo with audit, then live. |
| Calendar source change | Verify time basis and a known event before enabling. |

Every change gets a row in the validation log: date, stage, change, evidence,
decision.

## Incident response

1. **Stop entries:** create `KILL` in the journal directory.
2. **Assess exposure:** open positions, heat, correlated exposure, floating
   loss.
3. **Decide manually:** the EA keeps managing protection while halted. Closing
   positions is a human decision unless drawdown close-all already ran.
4. **Preserve evidence:** copy journals before restarting or reattaching.
5. **Fix and verify:** reproduce in the tester or dry run.
6. **Reset:** `RESET` only after the cause is understood; it clears every
   halt, including drawdown and manual.

Never delete `state.json` to "unstick" the EA without first reconciling open
positions. Deleting it loses the risk anchors and position metadata; the EA
will rebuild the loss streak from history but cannot reconstruct planned risk
for untracked positions.

## Rollback

- **Code:** keep the previous `.ex5` and `.mq5` pair; reattach after restoring.
- **Model:** keep the previous `.onnx` and its metadata entry; see
  [04-models.md](04-models.md#10-replacement-and-rollback).
- **Risk inputs:** keep a `.set` file per stage; the terminal can load it.
- **State:** restore the last known-good `state.json` only if the account
  positions match it; otherwise reconcile first.

A rollback that leaves positions open with the wrong magic or missing state is
worse than the incident you are rolling back from.
