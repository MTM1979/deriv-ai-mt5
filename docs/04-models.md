# Models: training, export, installation and rollback

The EA does not train. It loads one ONNX file per asset class, verifies it, and
turns features into a probability. Everything in this page happens in Python,
off the trading machine if you prefer. Read `python/README.md` for the
pipeline's own reference; this page covers the contract and the operational
path.

## 1. Inference contract

Every model must satisfy all of these or the EA refuses it:

| Item | Requirement |
|---|---|
| Input count | `1 input`, float32, shape `[1, 30]`, name `features`. |
| Output | `probability`: float32. `[1, 2]` with class 1 = success and Softmax applied, or `[1, 1]` with Sigmoid applied. |
| Values | Probabilities in `[0, 1]`, not logits. |
| Opset | 13 or newer, supported by the terminal's ONNX runtime. |
| External data | None. One self-contained file. |
| Feature order | Exactly `FeatureSpec.mqh`, which is generated from `python/features/spec.py`. |
| Preprocessing | Folded into the graph. The EA feeds raw clamped features; it does not standardize. |

`output_kind` in the metadata must match the graph: `binary_two` for `[1,2]`,
`binary_one` for `[1,1]`. A mismatch is an install error and an EA load error.

## 2. Feature contract

Index, name, bounds and meaning. The same table exists in
`MQL5/Include/FeatureSpec.mqh`; change `python/features/spec.py` and regenerate,
never hand-edit the header.

| # | Feature | Bounds | Meaning |
|---|---|---|---|
| 0 | `ret_1` | ±5 | 1-bar log return, percent. |
| 1 | `ret_3` | ±8 | 3-bar log return, percent. |
| 2 | `ret_12` | ±15 | 12-bar log return, percent. |
| 3 | `ema_fast_rel` | ±3 | `(close - EMA fast) / ATR`, signed by direction. |
| 4 | `ema_mid_rel` | ±3 | `(EMA fast - EMA mid) / ATR`, signed. |
| 5 | `ema_slow_rel` | ±3 | `(EMA mid - EMA slow) / ATR`, signed. |
| 6 | `ema_slow_slope` | ±2 | EMA slow slope over 10 bars, in ATR, signed. |
| 7 | `rsi_norm` | ±1 | `(RSI - 50) / 50`, signed. |
| 8 | `macd_hist_norm` | ±3 | MACD histogram / (0.5 ATR), signed. |
| 9 | `macd_accel` | ±3 | Histogram change / (0.5 ATR), signed. |
| 10 | `atr_percentile` | 0–1 | ATR rank in the lookback window. |
| 11 | `bb_width_atr` | 0–6 | Bollinger width / ATR. |
| 12 | `bb_position` | ±3 | `(close - BB middle) / max(0.5 width, 0.1 ATR)`, signed. |
| 13 | `adx_norm` | 0–1 | ADX / 100. |
| 14 | `di_diff` | ±1 | `(DI+ - DI-) / 100`, signed. |
| 15 | `dist_session_high` | ±5 | `(session high - close) / ATR`, signed. |
| 16 | `dist_session_low` | ±5 | `(close - session low) / ATR`, signed. |
| 17 | `dist_vwap` | ±5 | `(close - VWAP) / ATR`, signed. |
| 18 | `dist_day_high` | ±8 | `(day high - close) / ATR`, signed. |
| 19 | `range_expansion` | 0–10 | `(session high - session low) / ATR`. |
| 20 | `htf_trend` | ±3 | `(HTF close - HTF EMA slow) / HTF ATR`, signed. |
| 21 | `htf_rsi_norm` | ±1 | `(HTF RSI - 50) / 50`, signed. |
| 22 | `minutes_since_open` | 0–1 | Minutes since session open / 240. |
| 23 | `minutes_to_event` | 0–1 | Minutes to next high-impact event / 240; `1.0` when none. |
| 24 | `event_impact` | 0–1 | Impact / 3. |
| 25 | `spread_ratio` | 0–2 | Spread / max(1, CSV spread ceiling). |
| 26 | `volume_ratio` | 0–3 | Tick volume / 20-bar average. |
| 27 | `trend_strength` | ±3 | `(EMA fast - EMA slow) / ATR`, signed. |
| 28 | `sweep_flag` | 0–1 | 1 when a sweep supports the direction. |
| 29 | `direction` | ±1 | `+1` long, `-1` short. |

Direction-signed features flip with the candidate. That is why the model is
trained on labelled *direction-aware* rows, not on raw price direction alone.

Clamps are applied in both languages. If you change bounds or order:

```powershell
python -m features.spec --write-mqh
python -m features.spec --check
```

## 3. Data

### 3.1 Export

From MetaTrader, in order:

1. `Scripts/DiscoverDerivSymbols.mq5` — confirm the broker's exact names.
2. `Scripts/ExportBars.mq5` — execution timeframe, range timeframe and higher
   timeframe, one CSV each (for example `EURUSD_M5.csv`, `EURUSD_M15.csv`,
   `EURUSD_H1.csv`). Times are converted from server time to UTC.
3. `Scripts/ExportCalendar.mq5` — `calendar_history.csv`.

The pipeline also needs `deriv_symbols.csv` for session profile and risk
ceilings when you pass `--symbols`.

### 3.2 Assumptions you must accept or replace

- **Spread history is absent.** MT5 bars do not carry historical spread.
  Training uses a constant `--spread` in points. Run a grid (for example
  0.5×, 1×, 2× the current typical spread) and keep the result that survives
  the worst realistic case.
- **Point size is inferred** from the price scale unless `--point` is given.
  Pass the broker's real point for anything other than plain FX.
- **One ATR period.** `--symbols` rows must agree with the global ATR period;
  the EA enforces the same rule at startup.
- **Labels are path-dependent.** Triple-barrier labels use the next bar's open
  as entry, `--stop-atr` and `--rr` for the barriers, and `--horizon` bars. If
  the stop and target are both touched in one bar, the stop wins. This
  understates the result on ambiguous bars on purpose.

## 4. Train

Run from `python/`:

```powershell
python -m models.train `
  --bars  "C:\data\EURUSD_M15.csv" `
  --htf   "C:\data\EURUSD_H1.csv" `
  --range "C:\data\EURUSD_M5.csv" `
  --symbol EURUSD --asset-class fx `
  --symbols "..\MQL5\Files\deriv_symbols.csv" `
  --out build\fx.json --report build\fx_train.json `
  --threshold 0.63 --horizon 24 --stop-atr 1.5 --rr 1.5 `
  --spread 1.0 --version 2026-11-17
```

What it does:

1. Loads and validates OHLCV (monotonic time, consistent high/low, no
   duplicates).
2. Builds the exact 30-feature vector per bar, including HTF alignment and
   session state.
3. Labels rows with the triple barrier.
4. Holds out the newest `--valid-fraction` (default 0.3) for the report.
5. Fits L2 logistic regression with balanced class weights on standardized
   features.
6. Writes model JSON (weights, bias, means, scales, feature order, metadata)
   and an optional report with validation metrics.

This is a baseline. A low AUC or negative expectancy is a normal outcome, not
a bug; do not tune until the out-of-sample aggregate improves.

Useful flags: `--epochs` (1200), `--l2` (1e-3), `--learning-rate` (0.15),
`--min-index` to skip warmup, `--day-roll-hour` to match the EA's anchor.

## 5. Evaluate

```powershell
python -m models.evaluate `
  --bars "C:\data\EURUSD_M15.csv" --htf "C:\data\EURUSD_H1.csv" `
  --symbol EURUSD --asset-class fx `
  --model build\fx.json --threshold 0.63 `
  --last-fraction 0.3 --out build\fx_eval.json
```

Reports probability quality (AUC, Brier, log loss, calibration bins) and a
trading view on rows the EA would accept (`p >= threshold`): expectancy in R,
profit factor, max drawdown in R, and a bootstrap Monte Carlo. Pointing it at
the same data used for training gives in-sample numbers; use `--last-fraction`
or walk-forward for anything you intend to believe.

## 6. Walk-forward

```powershell
python -m models.walkforward `
  --bars "C:\data\EURUSD_M15.csv" --symbol EURUSD --asset-class fx `
  --train-bars 5000 --test-bars 1250 --horizon 24 `
  --threshold 0.63 --expanding `
  --out build\fx_wf.json --out-model build\fx_wf_model.json --final train-only
```

- Each test block is strictly newer than its training data; `--horizon` bars
  are purged so no training label can see a test price.
- `--step` defaults to `--test-bars`; overlapping test windows are rejected.
- `--expanding` grows the training window; otherwise it rolls.
- `--final train-only` exports the model from the last training window without
  touching the last test block. `--final all` retrains on all history after
  reporting.

Judge the aggregate, not one fold: fold count, AUC, Brier, accepted trades,
expectancy and Monte Carlo drawdown distribution.

## 7. Export ONNX

```powershell
python -m models.export_onnx --model build\fx.json --out build\fx.onnx --output-kind binary_two
python -m models.export_onnx --model build\fx.json --out build\fx.onnx --check
python -m models.export_onnx --model build\fx.json --out build\fx.onnx --inspect
```

The exporter folds standardization into the first layer:

```text
standardized = (x - mean) / scale
logit        = standardized · W + b
             = x · (W / scale) + (b - mean · (W / scale))
```

So the graph is `MatMul → Add → Softmax` (`binary_two`) or
`MatMul → Add → Sigmoid` (`binary_one`). `--check` re-exports in memory and
compares bytes; `--inspect` prints the parsed graph without writing.

The writer is a small dependency-free protobuf encoder. It is not a general
ONNX toolchain: it supports the ops this graph needs. If you export a different
architecture with `onnx`/`skl2onnx`, use `models.package --onnx`.

## 8. Install and validate

```powershell
python -m models.package `
  --model build\fx.json `
  --files-root ..\MQL5\Files `
  --key fx --threshold 0.63 --output-kind binary_two

python -m models.package --check --files-root ..\MQL5\Files
```

`package` writes `MQL5/Files/models/<key>.onnx`, computes SHA-256, and updates
`model_metadata.json` in place (atomically). It refuses to install when:

- the input is not `[1, 30]` or the output contradicts `--output-kind`;
- the metadata `feature_order` differs from `FeatureSpec.mqh`;
- a key is duplicated or the asset class is unknown;
- a hash is missing, malformed or does not match;
- `--files-root` does not look like an `MQL5/Files` tree.

`--check` re-verifies every installed model without writing.

A model installed for `fx` is used for every symbol whose CSV
`asset_class` is `fx`. Install `metal` and `index` the same way, or leave their
`sha256` empty and let the EA reject those classes (default
`allow_without_model=false`).

## 9. Parity

The MQL5 feature builder and the Python builder must agree. After touching
`features/build.py`, `features/indicators.py` or `OnnxModel.mqh`:

1. Run `Scripts/ExportFeatureSamples.mq5` on a chart with enough history.
2. Compare:

```powershell
python -m models.parity --samples ..\MQL5\Files\feature_samples.json --out build\parity.json
```

Parity checks the arithmetic to `1e-5`. It does not prove the indicator inputs
are the same; inspect the snapshots in the same JSON for that. A parity failure
means one language is wrong; never "fix" it by loosening the tolerance.

## 10. Replacement and rollback

Treat the model file and its metadata entry as one unit.

**Install a replacement**

```powershell
# 1. Package to a new file name so the old file stays intact
python -m models.package --model build\fx_v2.json `
  --files-root ..\MQL5\Files --key fx --file-name models/fx_v2.onnx --threshold 0.63
# 2. Validate
python -m models.package --check --files-root ..\MQL5\Files
# 3. Reattach the EA (or wait for the next init)
```

The metadata now points at `fx_v2.onnx`; the old file is still there.

**Roll back**

1. Stop the EA (remove from chart or `KILL`).
2. Restore the previous `model_metadata.json` entry (or the whole file from
   backup).
3. Ensure the old `.onnx` is still present.
4. Reattach; check `events.csv` for `ML` lines and verify the threshold.

Never edit `sha256` by hand. If you replace a file without repackaging, the
hash check fails and the class becomes reject-only, which is the intended
failure.

**A/B without changes**: install a second key (for example `fx_b`) and point a
second chart/instance at a metadata file that maps it. Do not run two
instances with the same magic on the same account.

## 11. Runtime behaviour in the EA

| Situation | Result |
|---|---|
| Metadata missing/malformed, `fail_on_load=false` | Startup warning; entries for that class rejected. |
| Metadata missing/malformed, `fail_on_load=true` | Init fails. |
| Hash mismatch | Model unusable; same as above. |
| Shape mismatch | Model unusable; journal names the expected shape. |
| `p` below threshold | Candidate rejected at stage `ml`. |
| Inference throws | Failure counter; after `InpMlMaxFailures` the model is quarantined and entries rejected. |
| `allow_without_model=true` | Entries proceed without a probability gate; intended only for smoke tests. |

Threshold resolution: the metadata threshold for the asset class, otherwise
`InpMlDefaultThreshold`. Near medium-impact news,
`InpMediumNewsScoreAdd` is added to the threshold, which makes the gate
stricter, never looser.

## 12. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `feature_order` mismatch | `FeatureSpec.mqh` stale or model trained on another order | Regenerate the header, retrain or re-export. |
| `ONNX output dim ... does not match` | Wrong `--output-kind` | Match the graph: `[1,2]`→`binary_two`, `[1,1]`→`binary_one`. |
| `sha256 mismatch` | File changed or wrong `--files-root` | Re-run `models.package`; do not patch the hash. |
| `no usable ONNX model` in the journal | Empty template hashes, or all files failed | Package real models, or disable ML deliberately. |
| Low AUC / no accepted trades | Baseline model, threshold too high, insufficient data | Check walk-forward first; lower the threshold only with out-of-sample evidence. |
| Parity mismatch | MQL5/Python arithmetic drift | Re-read both builders; the feature contract is the source of truth. |

## 13. Limits of the shipped pipeline

- The baseline is logistic regression, not a claim of predictive edge.
- The test suite uses synthetic data. It validates code paths and contracts,
  not market behaviour.
- ONNX execution was not verified in a live terminal during this delivery; the
  file format, graph structure and metadata are validated, but the terminal's
  runtime is the final authority. See [09-verification.md](09-verification.md).
- No hyperparameter search or feature selection is included. Adding one is a
  research change; keep the contract in section 1 fixed.
