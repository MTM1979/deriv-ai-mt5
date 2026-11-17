"""Install exported models and keep ``model_metadata.json`` honest.

The EA validates the metadata at load time:

* ``schema`` must be 1;
* ``feature_order`` must equal ``FeatureSpec.mqh``;
* every model needs ``key``, ``asset_class``, ``file`` and a probability
  threshold;
* when ``require_hash`` is on (the default), ``sha256`` must match.

This tool performs the same checks before writing, so a typo cannot
produce a terminal that starts but silently refuses to score.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Iterable

from data.loader import DataError, read_json, write_json_atomic
from features.spec import FEATURE_NAMES, metadata_fragment, validate_order
from models.export_onnx import effective_weights, export_model
from models.onnx_writer import describe_model
from models.train import TrainedModel, load_model

__all__ = [
    "MetadataError",
    "validate_metadata",
    "install_model",
    "check_models",
    "main",
]


class MetadataError(ValueError):
    pass


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_metadata(meta: dict, *, files_root: Path | None = None, allow_empty_hash: bool = True) -> list[str]:
    """Return a list of problems; an empty list means the metadata is valid."""
    problems: list[str] = []
    if not isinstance(meta, dict):
        return ["metadata root must be an object"]
    if meta.get("schema") != 1:
        problems.append("schema must be 1")
    order = meta.get("feature_order")
    if not isinstance(order, list):
        problems.append("feature_order missing")
    else:
        try:
            validate_order(order)
        except ValueError as exc:
            problems.append(f"feature_order: {exc}")
    models = meta.get("models")
    if not isinstance(models, list) or not models:
        problems.append("models array missing or empty")
        return problems
    seen: set[str] = set()
    for index, model in enumerate(models):
        where = f"models[{index}]"
        if not isinstance(model, dict):
            problems.append(f"{where} is not an object")
            continue
        key = str(model.get("key") or "").strip()
        if not key:
            problems.append(f"{where}.key missing")
        elif key in seen:
            problems.append(f"{where}.key '{key}' duplicated")
        seen.add(key)
        asset = str(model.get("asset_class") or "").strip().lower()
        if asset not in ("fx", "metal", "index", "all"):
            problems.append(f"{where}.asset_class must be fx/metal/index/all")
        file_name = str(model.get("file") or "").strip()
        if not file_name:
            problems.append(f"{where}.file missing")
        try:
            threshold = float(model.get("threshold"))
        except (TypeError, ValueError):
            problems.append(f"{where}.threshold is not a number")
        else:
            if not 0.0 <= threshold <= 1.0:
                problems.append(f"{where}.threshold must be 0..1")
        kind = str(model.get("output_kind") or "binary_two").strip().lower()
        if kind not in ("binary_two", "binary_one", "up_down_two", "regime_probs"):
            problems.append(f"{where}.output_kind '{kind}' is not supported")
        size = model.get("output_size", 1)
        try:
            size = int(size)
        except (TypeError, ValueError):
            problems.append(f"{where}.output_size is not an integer")
        else:
            if kind in ("binary_two", "up_down_two") and size < 2:
                problems.append(f"{where}.output_size must be >= 2 for {kind}")
        sha = str(model.get("sha256") or "").strip()
        if not sha and not allow_empty_hash:
            problems.append(f"{where}.sha256 is empty")
        elif sha and (len(sha) != 64 or any(c not in "0123456789abcdefABCDEF" for c in sha)):
            problems.append(f"{where}.sha256 is not a hex digest")
        if files_root is not None and file_name:
            path = files_root / file_name
            if not path.exists():
                problems.append(f"{where}.file not found: {path}")
            elif sha and not allow_empty_hash:
                actual = _sha256_file(path)
                if actual.lower() != sha.lower():
                    problems.append(f"{where}.sha256 mismatch for {path}")
    return problems


def _load_metadata(path: Path) -> dict:
    if not path.exists():
        return {
            "schema": 1,
            "generated_by": "python -m models.package",
            **metadata_fragment(),
            "models": [],
        }
    meta = read_json(path)
    return meta


def install_model(
    model: TrainedModel,
    onnx: bytes,
    *,
    metadata_path: str | Path,
    files_root: str | Path,
    key: str | None = None,
    file_name: str | Path | None = None,
    output_kind: str = "binary_two",
    threshold: float | None = None,
) -> dict:
    """Write ``onnx`` and update the metadata entry for ``key``."""
    metadata_path = Path(metadata_path)
    files_root = Path(files_root)
    key = (key or model.asset_class or "all").strip().lower()
    if not key:
        raise MetadataError("model key is empty")
    relative = Path(file_name) if file_name else Path("models") / f"{key}.onnx"
    destination = files_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_bytes(onnx)
    temporary.replace(destination)

    graph = describe_model(onnx)["graph"]
    output_dim = graph["outputs"][0]["dims"][-1]
    expected_dim = 2 if output_kind == "binary_two" else 1
    if output_dim != expected_dim:
        raise MetadataError(f"ONNX output dim {output_dim} does not match {output_kind}")
    if graph["inputs"][0]["dims"] != [1, len(FEATURE_NAMES)]:
        raise MetadataError("ONNX input shape does not match the feature contract")

    digest = _sha256_bytes(onnx)
    meta = _load_metadata(metadata_path)
    meta["schema"] = 1
    meta["generated_by"] = "python -m models.package"
    meta.setdefault("feature_order", list(FEATURE_NAMES))
    meta.setdefault("models", [])
    entry = {
        "key": key,
        "asset_class": model.asset_class if model.asset_class in ("fx", "metal", "index", "all") else key,
        "file": relative.as_posix(),
        "version": model.version,
        "sha256": digest,
        "threshold": float(model.threshold if threshold is None else threshold),
        "output_kind": output_kind,
        "output_size": expected_dim,
    }
    replaced = False
    for index, existing in enumerate(meta["models"]):
        if isinstance(existing, dict) and str(existing.get("key", "")).lower() == key:
            meta["models"][index] = entry
            replaced = True
            break
    if not replaced:
        meta["models"].append(entry)
    meta["note"] = (
        "Installed by python -m models.package. "
        "Thresholds are operating points, not guarantees; recalibrate on out-of-sample data."
    )
    problems = validate_metadata(meta, files_root=files_root, allow_empty_hash=False)
    if problems:
        raise MetadataError("; ".join(problems))
    write_json_atomic(metadata_path, meta)
    return meta


def check_models(metadata_path: str | Path, files_root: str | Path) -> list[str]:
    metadata_path = Path(metadata_path)
    files_root = Path(files_root)
    try:
        meta = read_json(metadata_path)
    except DataError as exc:
        return [str(exc)]
    return validate_metadata(meta, files_root=files_root, allow_empty_hash=False)


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Install an ONNX model and update metadata")
    parser.add_argument("--model", help="trained model JSON")
    parser.add_argument("--onnx", help="existing ONNX file (otherwise export from --model)")
    parser.add_argument("--key", help="metadata key (default: asset_class)")
    parser.add_argument("--file-name", help="path relative to MQL5/Files (default: models/<key>.onnx)")
    parser.add_argument("--output-kind", default="binary_two", choices=("binary_two", "binary_one"))
    parser.add_argument("--threshold", type=float, default=None)
    parser.add_argument(
        "--metadata",
        default=None,
        help="model metadata JSON (default: <files-root>/model_metadata.json)",
    )
    parser.add_argument("--files-root", default="MQL5/Files", help="EA MQL5/Files directory")
    parser.add_argument("--check", action="store_true", help="validate only, never write")
    args = parser.parse_args(list(argv) if argv is not None else None)

    files_root = Path(args.files_root)
    metadata_path = Path(args.metadata) if args.metadata else files_root / "model_metadata.json"

    if args.check:
        problems = check_models(metadata_path, files_root)
        if problems:
            for problem in problems:
                print(f"ERROR {problem}", file=sys.stderr)
            return 1
        print(f"{metadata_path} is valid and every model hash matches")
        return 0

    if not args.model:
        parser.error("--model is required unless --check is used")
    model = load_model(args.model)
    if args.threshold is not None:
        model.threshold = args.threshold
    if args.onnx:
        onnx = Path(args.onnx).read_bytes()
    else:
        onnx = export_model(model, args.output_kind)
    meta = install_model(
        model,
        onnx,
        metadata_path=metadata_path,
        files_root=files_root,
        key=args.key,
        file_name=args.file_name,
        output_kind=args.output_kind,
        threshold=args.threshold,
    )
    entry = next(m for m in meta["models"] if str(m.get("key", "")).lower() == (args.key or model.asset_class).lower())
    print(
        f"installed {entry['file']} ({len(onnx)} bytes)\n"
        f"  key={entry['key']} version={entry['version']} threshold={entry['threshold']:.3f}\n"
        f"  sha256={entry['sha256']}"
    )
    weights, bias = effective_weights(model)
    print(f"  affine: {len(weights)} weights, bias {bias:+.6f}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
