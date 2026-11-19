#!/usr/bin/env bash
# Publish the PV Fault Diagnosis API on a local Choreo API Manager (formerly
# WSO2 API Manager) 4.7.0 and get a token to call it.
#
# Needs: API Manager running from apim/docker-compose.yml, the Ballerina
# gateway on :9090, curl and python. Uses the product's default admin/admin
# account, which only exists on this local test container.
#
# Usage: bash apim/setup.sh      (safe to re-run; it reuses what exists)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="https://localhost:9443"
GW="https://localhost:8243"
ADMIN="admin:admin"
API_NAME="PVFaultDiagnosisAPI"
API_VERSION="1.0.0"
CONTEXT="/pv"
BACKEND="${BACKEND:-http://host.docker.internal:9090/api/v1}"
APP_NAME="PVMonitoringApp"
SUB_POLICY="Bronze"   # 1000 requests per minute, enforced by the gateway

c() { curl -sk --fail-with-body "$@" || { echo "    request failed: ${*: -1}" >&2; return 1; }; }
j() { python -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

echo "1/8 Register a REST API client"
CLIENT=$(c -u "$ADMIN" -H "Content-Type: application/json" \
  -d '{"callbackUrl":"www.example.com","clientName":"pv_setup_client","owner":"admin","grantType":"password refresh_token","saasApp":true}' \
  "$HOST/client-registration/v0.17/register")
CID=$(echo "$CLIENT" | j 'd["clientId"]'); CSEC=$(echo "$CLIENT" | j 'd["clientSecret"]')

echo "2/8 Get an admin token for the Publisher and Developer Portal APIs"
SCOPES="apim:api_view apim:api_create apim:api_publish apim:api_import_export apim:subscribe apim:app_manage apim:sub_manage"
TOKEN=$(c -u "$CID:$CSEC" -d "grant_type=password&username=admin&password=admin&scope=$SCOPES" "$HOST/oauth2/token" | j 'd["access_token"]')
AUTH=(-H "Authorization: Bearer $TOKEN")
PUB="$HOST/api/am/publisher/v4"
DEV="$HOST/api/am/devportal/v3"

echo "3/8 Create the API from apim/openapi.yaml (backend: $BACKEND)"
API_ID=$(c "${AUTH[@]}" "$PUB/apis?query=name:$API_NAME" | j 'next((a["id"] for a in d["list"] if a["name"]=="'"$API_NAME"'"), "")')
if [ -z "$API_ID" ]; then
  PROPS=$(cat <<EOF
{"name":"$API_NAME","version":"$API_VERSION","context":"$CONTEXT",
 "description":"Diagnoses solar PV faults from a window of electrical readings.",
 "policies":["$SUB_POLICY","Unlimited"],
 "endpointConfig":{"endpoint_type":"http",
   "production_endpoints":{"url":"$BACKEND"},
   "sandbox_endpoints":{"url":"$BACKEND"}}}
EOF
)
  API_ID=$(c "${AUTH[@]}" -F "file=@$HERE/openapi.yaml" -F "additionalProperties=$PROPS" \
    "$PUB/apis/import-openapi" | j 'd["id"]')
fi
echo "    API id: $API_ID"

echo "4/8 Deploy a revision to the gateway"
REV_COUNT=$(c "${AUTH[@]}" "$PUB/apis/$API_ID/revisions?query=deployed:true" | j 'd["count"]')
if [ "$REV_COUNT" = "0" ]; then
  REV_ID=$(c "${AUTH[@]}" -H "Content-Type: application/json" -d '{"description":"First revision"}' \
    "$PUB/apis/$API_ID/revisions" | j 'd["id"]')
  c "${AUTH[@]}" -H "Content-Type: application/json" \
    -d '[{"name":"Default","vhost":"localhost","displayOnDevportal":true}]' \
    "$PUB/apis/$API_ID/deploy-revision?revisionId=$REV_ID" >/dev/null
fi

echo "5/8 Publish the API to the Developer Portal"
STATE=$(c "${AUTH[@]}" "$PUB/apis/$API_ID" | j 'd["lifeCycleStatus"]')
if [ "$STATE" != "PUBLISHED" ]; then
  c "${AUTH[@]}" -X POST "$PUB/apis/change-lifecycle?apiId=$API_ID&action=Publish" >/dev/null
fi

echo "6/8 Create a consumer application"
# The portal shows a consumer secret only once, so the first run caches the
# keys in apim/.app-keys (git-ignored). If the app exists but that file is
# gone, the secret is unrecoverable: delete the demo app and start it again.
KEYFILE="$HERE/.app-keys"
APP_ID=$(c "${AUTH[@]}" "$DEV/applications?query=$APP_NAME" | j 'next((a["applicationId"] for a in d["list"] if a["name"]=="'"$APP_NAME"'"), "")')
if [ -n "$APP_ID" ] && [ ! -f "$KEYFILE" ]; then
  echo "    keys for $APP_NAME were not cached; recreating the app"
  c "${AUTH[@]}" -X DELETE "$DEV/applications/$APP_ID" >/dev/null
  APP_ID=""
fi
if [ -z "$APP_ID" ]; then
  rm -f "$KEYFILE"
  APP_ID=$(c "${AUTH[@]}" -H "Content-Type: application/json" \
    -d '{"name":"'"$APP_NAME"'","throttlingPolicy":"Unlimited","description":"Example solar monitoring client","tokenType":"JWT"}' \
    "$DEV/applications" | j 'd["applicationId"]')
fi

echo "7/8 Subscribe the application to the API ($SUB_POLICY tier)"
SUBS=$(c "${AUTH[@]}" "$DEV/subscriptions?apiId=$API_ID" | j 'sum(1 for s in d["list"] if s["applicationId"]=="'"$APP_ID"'")')
if [ "$SUBS" = "0" ]; then
  c "${AUTH[@]}" -H "Content-Type: application/json" \
    -d '{"apiId":"'"$API_ID"'","applicationId":"'"$APP_ID"'","throttlingPolicy":"'"$SUB_POLICY"'"}' \
    "$DEV/subscriptions" >/dev/null
fi

echo "8/8 Get the application's OAuth2 keys and an access token"
if [ -f "$KEYFILE" ]; then
  KEYS=$(cat "$KEYFILE")
else
  KEYS=$(c "${AUTH[@]}" -H "Content-Type: application/json" \
    -d '{"keyType":"PRODUCTION","grantTypesToBeSupported":["client_credentials"],"keyManager":"Resident Key Manager","validityTime":3600}' \
    "$DEV/applications/$APP_ID/generate-keys")
  echo "$KEYS" > "$KEYFILE"
fi
CK=$(echo "$KEYS" | j 'd["consumerKey"]')
CS=$(echo "$KEYS" | j 'd["consumerSecret"]')
APP_TOKEN=$(c -u "$CK:$CS" -d "grant_type=client_credentials" "$HOST/oauth2/token" | j 'd["access_token"]')

echo "$APP_TOKEN" > "$HERE/.token"
echo
echo "Done. Token saved to apim/.token (git-ignored, valid for 1 hour)."
echo "Call the API through the gateway:"
echo "  curl -k -X POST $GW$CONTEXT/$API_VERSION/diagnose -H \"Authorization: Bearer \$(cat apim/.token)\" -H \"Content-Type: application/json\" -d @samples/fault_3.json"
