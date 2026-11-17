# Python research and training pipeline

This directory turns broker history into the ONNX models the EA scores with.
It is intentionally small and dependency-free: every executable path runs on
a bare CPython 3.11+ interpreter. The verified build used Python 3.15.2 with
no NumPy, scikit-learn, ONNX or onnxruntime installed.

The pipeline is a **research tool**, not a trading system. It labels history,
fits a baseline model, reports honest out-of-sample statistics and writes an
ONNX file plus metadata. The Strategy Tester and demo account remain the
authority on execution quality.

## Layout

| Path | Responsibility |
|---|---|
| `features/spec.py` | Single source of truth for the 30-feature order, bounds and MQL5 header generation. |
| `features/indicators.py` | Indicator formulas, session state machine, `SnapshotView`. |
| `features/build.py` | Exact Python port of `OnnxModel.mqh::BuildFeatures`. |
| `data/loader.py` | OHLCV CSV loading/validation, resampling, symbol CSV parsing, atomic JSON I/O. |
| `models/labels.py` | Triple-barrier labels with next-bar entry and conservative same-bar handling. |
| `models/dataset.py` | Assembles features + labels, including session and HTF alignment. |
| `models/splits.py` | Purged, time-ordered walk-forward and k-fold windows. |
| `models/metrics.py` | AUC, Brier, log loss, calibration, expectancy, drawdown, Monte Carlo. |
| `models/train.py` | Standardized L2 logistic regression, model JSON, evaluation. |
| `models/walkforward.py` | Rolling/expanding walk-forward with a purge equal to the label horizon. |
| `models/evaluate.py` | Probability and trading views on a labelled dataset. |
| `models/export_onnx.py` | Folds standardization into an affine layer and writes ONNX. |
| `models/onnx_writer.py` | Dependency-free ONNX protobuf encoder/reader. |
| `models/package.py` | Installs ONNX, updates `model_metadata.json`, enforces the contract. |
| `models/parity.py` | Compares EA feature vectors with Python's arithmetic. |
| `tests/` | `unittest` suite (76 tests). |

## Requirements

- Python 3.11 or newer. Nothing else.
- `requirements.txt` lists optional extras for replacing the baseline with a
  library model; none are imported by shipped code.

Run from this directory (`python/`):

```powershell
python -m unittest discover -s tests -t .
python -m features.spec --check
```

## Data preparation (inside MetaTrader 5)

All scripts write to `MQL5/Files` unless told otherwise.

1. **Discover broker symbols** — `MQL5/Scripts/DiscoverDerivSymbols.mq5`.
   Review its CSV output and copy the exact names into `deriv_symbols.csv`.
   Deriv is free to rename instruments; never assume a name from another
   broker.
2. **Export bars** — `MQL5/Scripts/ExportBars.mq5`.
   Choose a logical symbol, timeframe and bar count. Output is UTF-8 CSV with
   `time,open,high,low,close,tick_volume`, times converted from server time to
   UTC. Download enough history first: open the chart and scroll back, or use
   the terminal's history download.
3. **Export the calendar** — `MQL5/Scripts/ExportCalendar.mq5`.
   Produces `calendar_history.csv` used by the EA's tester fallback.
4. **Export feature parity samples** — `MQL5/Scripts/ExportFeatureSamples.mq5`.
   Run it on a chart with history after any change to the feature code.

### CSV assumptions and limits

- Timestamps are naive and interpreted as UTC. `ExportBars.mq5` converts
  server time using the detected or configured offset. A single offset is
  used for the whole export; if the range spans a daylight-saving change,
  export each period separately or set the offset for the dominant period.
- OHLC must be internally consistent (`low <= open/close <= high`) and strictly
  increasing; duplicate or non-finite rows are rejected.
- MT5 bar history does not contain historical spread. Training therefore uses
  a constant `--spread` (in points) for the spread-ratio feature and the
  label's cost adjustment. Run a spread grid, then confirm in the tester.
- The EA uses the broker's real `SYMBOL_POINT`. For CSV research the point is
  inferred from the price scale or supplied with `--point`; pass the real
  value when you know it.
- Session profiles and risk ceilings come from `MQL5/Files/deriv_symbols.csv`.
  Keep the file in sync with the terminal configuration.

## Train

```powershell
python -m models.train `
  --bars  "C:\path\EURUSD_M15.csv" `
  --htf   "C:\path\EURUSD_H1.csv" `
  --range "C:\path\EURUSD_M5.csv" `
  --symbol EURUSD `
  --asset-class fx `
  --symbols "..\MQL5\Files\deriv_symbols.csv" `
  --out build\fx.json `
  --report build\fx_train_report.json `
  --threshold 0.63 `
  --horizon 24 --stop-atr 1.5 --rr 1.5 `
  --spread 1.0
```

- `--bars` is the execution timeframe (the EA default is M15).
- `--htf` and `--range` default to the execution bars when omitted.
- The last `--valid-fraction` of rows (default 0.3) is held out for the
  reported validation metrics.
- Labels are `1` when the target is hit before the stop inside `--horizon`
  bars, `0` otherwise. Entry is the next bar's open. If stop and target are
  both touched in one bar, the stop wins; this is deliberately conservative.
- The model is L2 logistic regression with balanced class weights. It is a
  **baseline**, not a claim of edge.

## Evaluate

```powershell
python -m models.evaluate `
  --bars "C:\path\EURUSD_M15.csv" --symbol EURUSD --asset-class fx `
  --model build\fx.json --threshold 0.63 `
  --last-fraction 0.3 --out build\fx_eval.json
```

The report contains probability metrics (AUC, Brier, log loss, calibration)
and a trading view on the rows the EA would accept (`p >= threshold`):
expectancy, profit factor, max drawdown in R and a bootstrap Monte Carlo.
These are in-sample research numbers unless you point them at held-out data.

## Walk-forward

```powershell
python -m models.walkforward `
  --bars "C:\path\EURUSD_M15.csv" --symbol EURUSD --asset-class fx `
  --train-bars 5000 --test-bars 1250 --horizon 24 `
  --threshold 0.63 --out build\fx_wf.json `
  --out-model build\fx_wf_model.json --final train-only
```

- Training data is strictly older than the test block; `--horizon` bars are
  purged so no training label can see a test price.
- `--step` must be at least `--test-bars` so out-of-sample windows never
  overlap.
- `--final train-only` keeps the last test window untouched for the artefact;
  `--final all` retrains on all history after reporting.
- The aggregate block is the number to judge: fold count, AUC, Brier, accepted
  trade count, expectancy and Monte Carlo.

## Export ONNX

```powershell
python -m models.export_onnx --model build\fx.json --out build\fx.onnx
python -m models.export_onnx --model build\fx.json --out build\fx.onnx --check
```

The exported graph is `MatMul -> Add -> Softmax` for `binary_two`
(`[1,2]` output) or `MatMul -> Add -> Sigmoid` for `binary_one` (`[1,1]`).
Standardization is folded into the weights, so the EA feeds raw clamped
features. `--check` proves the file on disk is byte-identical to a fresh
export.

## Install and validate the model

```powershell
# Writes MQL5/Files/models/fx.onnx and updates MQL5/Files/model_metadata.json
python -m models.package `
  --model build\fx.json `
  --files-root ..\MQL5\Files `
  --key fx --threshold 0.63

# Re-verify every hash without writing
python -m models.package --check --files-root ..\MQL5\Files
```

`models.package` refuses to install when:

- the ONNX input is not `[1, 30]` or the output shape contradicts
  `--output-kind`;
- the metadata feature order differs from `FeatureSpec.mqh`;
- a key is duplicated or an asset class is unknown;
- a SHA-256 is missing, malformed or does not match the file.

The EA performs the same checks at load time. A mismatch is a startup error,
not a silent scoring failure.

## Feature parity

After changing `features/build.py`, `features/indicators.py` or
`OnnxModel.mqh`:

1. Run `MQL5/Scripts/ExportFeatureSamples.mq5` on a chart with history.
2. Compare:

```powershell
python -m models.parity --samples ..\MQL5\Files\feature_samples.json
```

Parity proves the arithmetic contract. It does not prove the indicator
inputs match; compare the snapshots in the same JSON file as well.

If you change the feature order or bounds, regenerate the MQL5 header:

```powershell
python -m features.spec --write-mqh
python -m features.spec --check
```

Never hand-edit `MQL5/Include/FeatureSpec.mqh`; retraining and metadata
validation both depend on it.

## Replacing the baseline

You may train a stronger model elsewhere, but it must honour the inference
contract:

- input `features`: float32 `[1, 30]`, same order and bounds as
  `features/spec.py`;
- output `probability`: float32 `[1, 2]` (index 1 = success, Softmax) or
  `[1, 1]` (Sigmoid), values in `[0, 1]`;
- no external data files, no dynamic shapes, opset 13 or newer supported by
  the terminal's ONNX runtime;
- probabilities, not logits.

Then install it:

```powershell
python -m models.package --model build\my_model.json --onnx build\my_model.onnx `
  --files-root ..\MQL5\Files --key fx --output-kind binary_two --threshold 0.63
```

`--onnx` bypasses the built-in exporter, but the shape checks, metadata update
and SHA-256 still run. Keep the model JSON's `feature_order` implicit: the
metadata owns the order.

## Tests

```powershell
python -m unittest discover -s tests -t .
```

Coverage includes feature arithmetic, indicator formulas, session windows,
triple-barrier edge cases, metric formulas, purged splits, CSV validation,
ONNX encoding/parsing, metadata/hash failures and an end-to-end synthetic
train → evaluate → export → package → walk-forward run.

The suite does not validate a real ONNX runtime, real tick data, or broker
execution. Those require MT5 and are covered by `docs/05-validation.md`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `missing required column 'volume'` | Header uses an unsupported volume name; rename to `tick_volume` or `volume`. |
| `unrecognized timestamp` | Not one of the documented formats; export with `ExportBars.mq5`. |
| `feature_order` problems | `FeatureSpec.mqh` is stale; run `python -m features.spec --write-mqh`. |
| `ONNX output dim ... does not match` | `--output-kind` contradicts the graph. |
| `sha256 mismatch` | File changed after packaging, or wrong `--files-root`. |
| Low AUC / negative expectancy | Normal for a baseline and short samples. Do not tune until the out-of-sample aggregate improves. |
