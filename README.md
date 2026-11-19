# PV Fault Diagnosis API

An HTTP API that takes a window of electrical readings from a grid-connected solar PV system and returns one diagnosis: healthy, one of seven fault types, or uncertain. Each diagnosis comes with the features that drove it.

The model comes from my research project on explainable machine-learning fault detection for solar PV. This repo turns that model into a service and runs it behind two [Choreo Labs](https://choreolabs.com) (formerly WSO2) products: a gateway written in [Ballerina](https://ballerina.io), and Choreo API Manager, which handles OAuth2 tokens, subscriptions and rate limits.

## Use case

Solar plants stream electrical readings from their inverters all day, but many faults go unnoticed until output drops in a monthly report or someone visits the site. A monitoring system can send a window of readings to this API and get back a named fault (for example partial shading or a grid voltage sag) with the measurements behind it, so a technician knows what to check before they go out. Because it is an HTTP API, dashboards, alerting tools and vendor software can all call the same service.

> **Built with AI assistance.** I am an electrical and electronics engineering student, not a trained software engineer. I directed the design, ran and debugged everything, and Claude (Anthropic) wrote most of the code. I can explain every file here.

## Architecture

```
client --HTTPS + OAuth2 token--> Choreo API Manager gateway (:8243) --> Ballerina gateway (:9090) --> Python model service (:8000)
        POST /pv/1.0.0/diagnose  checks the token and subscription,    validates the window,        XGBoost classifier +
                                 applies the rate limit (Bronze tier)  votes across readings,       per-reading SHAP values
                                                                       returns one diagnosis
```

| Part | Folder | What it does |
|---|---|---|
| API management | `apim/` | Docker Compose file for Choreo API Manager 4.7.0, the OpenAPI definition (generated from the Ballerina service with `bal openapi`), and `setup.sh`, which publishes the API, creates a client app, subscribes it and fetches a token through the API Manager REST APIs. |
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
curl.exe -X POST http://localhost:9090/api/v1/diagnose -H "Content-Type: application/json" -d "@samples/fault_3.json"
```

If `bal` reports "Compatible JRE not found", point `JAVA_HOME` at the JRE bundled with Ballerina for that terminal, for example `C:\Program Files\Ballerina\dependencies\jdk-25.0.3+9-jre`.

Gateway tests: `cd gateway; bal test`. If the gateway is already running on 9090, set `$env:BAL_CONFIG_VAR_PORT = "9099"` first.

## Run it behind Choreo API Manager

You also need Docker Desktop and Git Bash (for `setup.sh`). Start the model service and gateway as above, then from the repo root:

```powershell
# 4. Start API Manager (first start takes about 5 minutes)
docker compose -f apim/docker-compose.yml up -d

# 5. Publish the API, create a client app, subscribe it and get a token
bash apim/setup.sh

# 6. Call the API through the API Manager gateway
curl.exe -k -X POST https://localhost:8243/pv/1.0.0/diagnose -H "Authorization: Bearer $(Get-Content apim/.token)" -H "Content-Type: application/json" -d "@samples/fault_3.json"
```

A call without a token returns `401 Missing Credentials`. The token lasts one hour; run `setup.sh` again for a new one (it reuses everything it created before). The Publisher (https://localhost:9443/publisher) and Developer Portal (https://localhost:9443/devportal) use the container's default `admin` / `admin` login, which is only for this local test setup.

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

- Containerise the model service and gateway so the whole stack starts with one `docker compose up`.
- Retrain on data logged at the slower rates real plants use (seconds to minutes).

## Licence

Code: [MIT](LICENSE). The model artifact derives from the CC BY 4.0 GPVS-Faults dataset and must keep the attribution above.
