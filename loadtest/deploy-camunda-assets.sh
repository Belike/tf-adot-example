#!/usr/bin/env bash
set -euo pipefail

# Fixed target for your environment
API_BASE="https://normunda.de/orchestration/v2"
DEPLOY_URL="${API_BASE}/deployments"

TOKEN_URL="https://normunda.de/auth/realms/camunda-platform/protocol/openid-connect/token"
CLIENT_ID="orchestration"

# Where the client secret lives in K8s
NAMESPACE="${NAMESPACE:-camunda}"
SECRET_NAME="${SECRET_NAME:-camunda-credentials}"
SECRET_KEY="${SECRET_KEY:-identity-orchestration-client-token}"

# Assets location on the machine running this script
ASSETS_DIR="${ASSETS_DIR:-./assets}"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

need kubectl
need curl
need python3
need base64
need find

log "API:   ${DEPLOY_URL}"
log "Token: ${TOKEN_URL}"
log "K8s secret: ${NAMESPACE}/${SECRET_NAME} key=${SECRET_KEY}"
log "Assets dir: ${ASSETS_DIR}"

# Read client secret from K8s and decode
CLIENT_SECRET="$(
  kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o "jsonpath={.data.${SECRET_KEY}}" \
  | base64 -d
)"

# Get access token (client_credentials)
log "Requesting OAuth token..."
TOKEN_JSON="$(
  curl -sS \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" \
    "${TOKEN_URL}"
)"

ACCESS_TOKEN="$(
  echo "${TOKEN_JSON}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))"
)"

if [[ -z "${ACCESS_TOKEN}" ]]; then
  echo "ERROR: Could not get access_token. Raw response:" >&2
  echo "${TOKEN_JSON}" >&2
  exit 1
fi

# Collect files
mapfile -t FILES < <(find "${ASSETS_DIR}" -maxdepth 1 -type f \( -name '*.bpmn' -o -name '*.dmn' -o -name '*.form' \) | sort)

if [[ "${#FILES[@]}" -eq 0 ]]; then
  echo "ERROR: No *.bpmn / *.dmn / *.form found in ${ASSETS_DIR}" >&2
  exit 1
fi

log "Deploying ${#FILES[@]} files..."
for f in "${FILES[@]}"; do
  log "Deploy: ${f}"
  curl -sS --fail \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/json" \
    -F "resources=@${f}" \
    "${DEPLOY_URL}" >/dev/null
done

log "Done."
