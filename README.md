# PV Fault Diagnosis API

An HTTP API that takes a window of electrical readings from a grid-connected solar PV system and returns one diagnosis: healthy, one of seven fault types, or uncertain. Each diagnosis comes with the features that drove it.

The model comes from my research project on explainable machine-learning fault detection for solar PV. This repo turns that model into a service. The API layer is written in [Ballerina](https://ballerina.io), an open-source language from [Choreo Labs](https://choreolabs.com) (formerly WSO2).

## Use case

Solar plants stream electrical readings from their inverters all day, but many faults go unnoticed until output drops in a monthly report or someone visits the site. A monitoring system can send a window of readings to this API and get back a named fault (for example partial shading or a grid voltage sag) with the measurements behind it, so a technician knows what to check before they go out. Because it is an HTTP API, dashboards, alerting tools and vendor software can all call the same service.

> **Built with AI assistance.** I am an electrical and electronics engineering student, not a trained software engineer. I directed the design, ran and debugged everything, and Claude (Anthropic) wrote most of the code. I can explain every file here.

## Architecture

```
client --POST /api/v1/diagnose--> Ballerina gateway (:9090) --POST /predict--> Python model service (:8000)
                                  validates the window,                        XGBoost classifier +
                                  votes across readings,                       per-reading SHAP values
                                  returns one diagnosis
```

| Part | Folder | What it does |
|---|---|---|
| Ballerina gateway | `gateway/` | Validates input, calls the model service, turns per-reading predictions into one window verdict with an explanation. Has unit tests. |
| Model service | `model-service/` | FastAPI service. Classifies each reading and returns class probabilities plus the top 3 SHAP features, using XGBoost's built-in `pred_contribs`. |
| Model artifact | `model/` | Trained XGBoost model, metadata, and 16 real held-out readings. |
| Export tool | `tools/export_model.py` | The one-off script that retrained and exported the model from my research repo. That repo is private, so you cannot rerun this step. |

### Why a gateway?

The model classifies a single instant. Real monitoring works on a window of readings, so the gateway takes a majority vote across the window and reports how strongly the readings agree. A window is `uncertain` when the readings disagree (the top class holds half the votes or fewer) or the top class has low average confidence.

## Quick start (Windows)

You need Python 3.11+ and [Ballerina 2201.14.1](https://ballerina.io/downloads/).

```powershell
# 1. Model service
cd model-service
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m uvicorn app:app --port 8000

# 2. Gateway (new terminal)
cd gateway
bal run

# 3. Try it (new terminal, from the repo root)
curl -X POST http://localhost:9090/api/v1/diagnose -H "Content-Type: application/json" -d "@samples/fault_3.json"
```

If `bal` reports "Compatible JRE not found", point `JAVA_HOME` at the JRE bundled with Ballerina for that terminal, for example `C:\Program Files\Ballerina\dependencies\jdk-25.0.3+9-jre`.

Gateway tests: `cd gateway; bal test`.

## API

`POST /api/v1/diagnose` takes `{"readings": [ ... ]}`. Each reading has 14 fields: `current_a`, `voltage_v`, `Vdc`, `ia`, `ib`, `ic`, `va`, `vb`, `vc`, `Iabc`, `If`, `Vabc`, `Vf` and `operation_mode` (`"MPPT"` or `"IPPT"`). See `samples/` for full examples. Up to 5000 readings per request.

Response (shape):

```json
{
  "status": "fault_detected",
  "diagnosis": "fault_3",
  "confidence": 1.0,
  "agreement": 1.0,
  "fault_fraction": 1.0,
  "window_size": 2,
  "votes": {"fault_3": 2},
  "explanation": [{"feature": "Vdc", "mean_abs_shap": 12.37}]
}
```

`status` is `healthy`, `fault_detected` or `uncertain`. `GET /api/v1/health` is a liveness check. Invalid input returns 400. A model-service outage returns 502.

## Model and results

- **Data:** GPVS-Faults, a real lab-scale grid-connected PV microgrid sampled at about 100 kHz, 2,163,480 rows, 8 classes (healthy plus 7 fault types). Bakdi, Guichi, Mekhilef, Bounoua, Mendeley Data, DOI [10.17632/n76t439f65.1](https://doi.org/10.17632/n76t439f65.1), licensed CC BY 4.0. The data is not included here.
- **Model:** XGBoost on 14 electrical features, trained on a segment-based train/test split (1,730,769 train rows, 432,711 test rows).
- **Held-out test result:** accuracy 0.869, macro F1 0.864.

| Class | F1 |
|---|---|
| healthy | 0.890 |
| fault_1 (inverter IGBT failure) | 0.912 |
| fault_2 (phase sensor fault) | 0.933 |
| fault_3 (grid voltage sags) | 0.998 |
| fault_4 (partial shading) | 0.768 |
| fault_5 (open circuit in array) | 0.968 |
| fault_6 (MPPT controller gain error) | 0.598 |
| fault_7 (boost controller time constant) | 0.847 |

## Limitations

- **fault_6 is the weakest class (F1 0.598).** Short windows of fault_6 readings can come back healthy or uncertain. Use longer windows and treat `uncertain` as "needs a human".
- Faults are labelled by file and onset in the source dataset. Results come from one lab system and may not transfer to other plants.
- The dataset has no irradiance or temperature channels, so the API does not use them.
- The model scores readings independently. It does not look at the order of readings within a window.
- This is a demo built for learning and portfolio use, not a safety system.

## Roadmap

- Put Choreo API Manager (formerly WSO2 API Manager) in front of the gateway for API keys and rate limiting.
- Containerise both services with Docker.
- Retrain on data logged at the slower rates real plants use (seconds to minutes).

## Licence

Code: [MIT](LICENSE). The model artifact derives from the CC BY 4.0 GPVS-Faults dataset and must keep the attribution above.
