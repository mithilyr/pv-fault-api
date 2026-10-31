"""Model service: scores PV electrical readings with the thesis XGBoost model.

Each reading is classified on its own (the model is per-sample, 14 features).
Per-reading SHAP contributions come from XGBoost's built-in `pred_contribs`,
so the `shap` package is not needed at inference time.

Run:
    uvicorn app:app --port 8000
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

import numpy as np
import xgboost as xgb
from fastapi import FastAPI
from pydantic import BaseModel, Field

MODEL_DIR = Path(__file__).resolve().parents[1] / "model"
TOP_FEATURES = 3
MAX_READINGS = 5000

meta = json.loads((MODEL_DIR / "meta.json").read_text(encoding="utf-8"))
FEATURES: list[str] = meta["feature_columns"]
CLASSES: list[str] = meta["classes"]
MODE_ENCODING: dict[str, int] = meta["operation_mode_encoding"]

booster = xgb.Booster()
booster.load_model(str(MODEL_DIR / "xgboost.json"))

app = FastAPI(title="PV fault model service", version="0.1.0")


class Reading(BaseModel):
    current_a: float
    voltage_v: float
    Vdc: float
    ia: float
    ib: float
    ic: float
    va: float
    vb: float
    vc: float
    Iabc: float
    If: float
    Vabc: float
    Vf: float
    operation_mode: Literal["MPPT", "IPPT"]


class PredictRequest(BaseModel):
    readings: list[Reading] = Field(min_length=1, max_length=MAX_READINGS)


class FeatureContribution(BaseModel):
    feature: str
    shap_value: float


class Prediction(BaseModel):
    predicted_class: str
    confidence: float
    probabilities: dict[str, float]
    top_features: list[FeatureContribution]


class PredictResponse(BaseModel):
    predictions: list[Prediction]


def to_matrix(readings: list[Reading]) -> xgb.DMatrix:
    rows = []
    for reading in readings:
        values = reading.model_dump()
        values["operation_mode"] = MODE_ENCODING[values["operation_mode"]]
        rows.append([values[name] for name in FEATURES])
    return xgb.DMatrix(np.asarray(rows, dtype=float), feature_names=FEATURES)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/model-info")
def model_info() -> dict:
    return {
        "source_experiment": meta["source_experiment"],
        "model": meta["model"],
        "features": FEATURES,
        "classes": CLASSES,
        "test_metrics": meta["test_metrics"],
        "dataset": meta["dataset"],
    }


@app.post("/predict", response_model=PredictResponse)
def predict(request: PredictRequest) -> PredictResponse:
    matrix = to_matrix(request.readings)
    probabilities = booster.predict(matrix)
    contributions = booster.predict(matrix, pred_contribs=True)  # (n, n_classes, n_features + 1)

    predictions = []
    for i, row in enumerate(probabilities):
        class_idx = int(np.argmax(row))
        shap_row = contributions[i, class_idx, :-1]  # last column is the bias term
        top = np.argsort(-np.abs(shap_row))[:TOP_FEATURES]
        predictions.append(Prediction(
            predicted_class=CLASSES[class_idx],
            confidence=float(row[class_idx]),
            probabilities={CLASSES[j]: float(p) for j, p in enumerate(row)},
            top_features=[
                FeatureContribution(feature=FEATURES[j], shap_value=float(shap_row[j])) for j in top
            ],
        ))
    return PredictResponse(predictions=predictions)
