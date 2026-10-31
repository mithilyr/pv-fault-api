"""One-off export: retrain the thesis baseline (exp_002a, XGBoost) and save a
portable model artifact for the API.

Reads the thesis repo read-only (its src/ and the processed dataset) and
writes only into this project's model/ folder. It does not touch the thesis
experiment logs.

Usage (thesis venv, which has xgboost/pandas/scikit-learn):
    <thesis>\\.venv\\Scripts\\python.exe tools/export_model.py
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
from sklearn.metrics import accuracy_score, f1_score

DEFAULT_THESIS_ROOT = Path(r"E:\SecondBrain\Research\01_Projects\EEET4000_SolarPV_AI")
EXPERIMENT = "exp_002a_fault3_relabel_only"
SAMPLES_PER_CLASS = 2
OUT_DIR = Path(__file__).resolve().parents[1] / "model"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--thesis-root", type=Path, default=DEFAULT_THESIS_ROOT)
    args = parser.parse_args()

    sys.path.insert(0, str(args.thesis_root / "src"))
    from models import build_xgboost  # noqa: E402
    from run_experiment import build_dataset, load_config  # noqa: E402

    config_path = args.thesis_root / "experiments" / EXPERIMENT / "config.yaml"
    config = load_config(config_path)
    X_train, y_train, X_test, y_test, label_encoder, feature_columns = build_dataset(config)
    classes = [str(c) for c in label_encoder.classes_]

    model = build_xgboost(random_state=config.get("random_state", 42))
    start = time.time()
    model.fit(X_train, y_train)
    train_seconds = round(time.time() - start, 1)

    y_pred = model.predict(X_test)
    metrics = {
        "accuracy": float(accuracy_score(y_test, y_pred)),
        "macro_f1": float(f1_score(y_test, y_pred, average="macro")),
        "n_train": int(len(X_train)),
        "n_test": int(len(X_test)),
        "train_seconds": train_seconds,
    }
    print(f"accuracy={metrics['accuracy']:.4f} macro_f1={metrics['macro_f1']:.4f}")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    model.get_booster().save_model(str(OUT_DIR / "xgboost.json"))

    meta = {
        "source_experiment": EXPERIMENT,
        "model": "xgboost",
        "feature_columns": list(feature_columns),
        "classes": classes,
        "operation_mode_encoding": {"MPPT": 1, "IPPT": 0},
        "test_metrics": metrics,
        "dataset": "GPVS-Faults (Bakdi et al., Mendeley Data, DOI 10.17632/n76t439f65.1, CC BY 4.0)",
    }
    (OUT_DIR / "meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")

    # A few real held-out rows per class, so the demo and tests need no dataset.
    rng = np.random.default_rng(42)
    samples = []
    for class_idx, class_name in enumerate(classes):
        rows = np.flatnonzero(y_test == class_idx)
        if len(rows) == 0:
            continue
        for row in rng.choice(rows, size=min(SAMPLES_PER_CLASS, len(rows)), replace=False):
            reading = X_test.iloc[int(row)].to_dict()
            reading["operation_mode"] = "MPPT" if reading["operation_mode"] == 1 else "IPPT"
            samples.append({"true_label": class_name, "reading": reading})
    (OUT_DIR / "sample_readings.json").write_text(json.dumps(samples, indent=2), encoding="utf-8")

    print(f"Saved model, meta and {len(samples)} sample readings to {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
