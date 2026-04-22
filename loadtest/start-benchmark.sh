#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="camunda"
RELEASE_NAME="${RELEASE_NAME:-camunda}"
CHART_REF="${CHART_REF:-camunda/camunda-platform}"
CHART_VERSION="${CHART_VERSION:-13.4.1}"
VALUES_FILE="${VALUES_FILE:-8.8-values-pod-annotations.yaml}"
HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"

JOB_NAME="benchmark-job"
JOB_YAML="./benchmark.yaml"
PAYLOAD_YAML="./payload-configmap.yaml"
DURATION_SECONDS=$((15 * 60))   # 15 minutes

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

need kubectl
need helm
need curl
need base64
need date

# ---------------------------------------------------------------------------
# Preflight checks - fail fast with clear messages before Helm install
# ---------------------------------------------------------------------------
echo "=== Preflight checks ==="

FAIL=0
warn() { echo "  [WARN] $*" >&2; }
fail() { echo "  [FAIL] $*" >&2; FAIL=1; }
ok()   { echo "  [ OK ] $*"; }

# 1. kubectl context is reachable
echo "-- Checking cluster connectivity..."
if CTX="$(kubectl config current-context 2>/dev/null)"; then
  if kubectl cluster-info >/dev/null 2>&1; then
    ok "kubectl context '${CTX}' is reachable"
  else
    fail "kubectl context '${CTX}' is set but cluster is unreachable"
  fi
else
  fail "No kubectl context set. Run 'aws eks update-kubeconfig ...' first."
fi

# 2. Required local files
echo "-- Checking local files..."
for f in "${VALUES_FILE}" "${JOB_YAML}" "${PAYLOAD_YAML}" "./deploy-camunda-assets.sh"; do
  if [[ -f "${f}" ]]; then
    ok "Found ${f}"
  else
    fail "Missing file: ${f}"
  fi
done

# 3. BPMN/DMN assets exist
echo "-- Checking process assets..."
ASSETS_DIR="${ASSETS_DIR:-./assets}"
if [[ -d "${ASSETS_DIR}" ]]; then
  ASSET_COUNT=$(find "${ASSETS_DIR}" -maxdepth 1 -type f \( -name '*.bpmn' -o -name '*.dmn' -o -name '*.form' \) | wc -l)
  if [[ "${ASSET_COUNT}" -gt 0 ]]; then
    ok "Found ${ASSET_COUNT} deployable asset(s) in ${ASSETS_DIR}"
  else
    fail "No *.bpmn / *.dmn / *.form files in ${ASSETS_DIR}"
  fi
else
  fail "Assets directory not found: ${ASSETS_DIR}"
fi

# 4. Namespace (create if missing — not a failure, just a note)
echo "-- Checking namespace..."
if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  ok "Namespace '${NAMESPACE}' exists"
else
  warn "Namespace '${NAMESPACE}' does not exist — will be created"
fi

# 5. camunda-credentials secret and all keys the values file references
echo "-- Checking camunda-credentials secret..."
REQUIRED_KEYS=(
  "identity-admin-client-token"
  "identity-orchestration-client-token"
  "identity-optimize-client-token"
  "identity-connectors-client-token"
  "identity-keycloak-admin-password"
  "identity-firstuser-password"
  "identity-postgresql-admin-password"
  "identity-postgresql-user-password"
  "identity-keycloak-postgresql-admin-password"
  "identity-keycloak-postgresql-user-password"
)

if kubectl -n "${NAMESPACE}" get secret camunda-credentials >/dev/null 2>&1; then
  ok "Secret 'camunda-credentials' exists"
  EXISTING_KEYS="$(kubectl -n "${NAMESPACE}" get secret camunda-credentials \
    -o jsonpath='{.data}' 2>/dev/null | tr ',' '\n' | { grep -oE '"[^"]+":' || true; } | tr -d '":')"
  for key in "${REQUIRED_KEYS[@]}"; do
    if echo "${EXISTING_KEYS}" | grep -qx "${key}"; then
      ok "  key present: ${key}"
    else
      fail "  key MISSING: ${key}"
    fi
  done

  # Verify orchestration client token is not empty after decode
  ORCH_VAL="$(kubectl -n "${NAMESPACE}" get secret camunda-credentials \
    -o "jsonpath={.data.identity-orchestration-client-token}" 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "${ORCH_VAL}" ]]; then
    fail "  'identity-orchestration-client-token' decodes to empty string"
  fi
else
  fail "Secret 'camunda-credentials' is missing in namespace '${NAMESPACE}'"
  fail "  (Helm will install, but pods will CrashLoopBackOff without it)"
fi

# 6. Default StorageClass (values file expects 'gp3' as default for PVCs)
echo "-- Checking default StorageClass..."
DEFAULT_SC="$(kubectl get sc -o json 2>/dev/null | \
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data.get('items', []):
        anns = item.get('metadata', {}).get('annotations', {}) or {}
        if anns.get('storageclass.kubernetes.io/is-default-class') == 'true':
            print(item['metadata']['name'])
            break
except Exception:
    pass
" 2>/dev/null || true)"

if [[ -n "${DEFAULT_SC}" ]]; then
  ok "Default StorageClass: ${DEFAULT_SC}"
  if [[ "${DEFAULT_SC}" != "gp3" ]]; then
    warn "  Expected 'gp3' per storageclass.yaml — PVCs will provision on '${DEFAULT_SC}' instead"
  fi
else
  warn "No default StorageClass set — PVCs will stay Pending. Apply storageclass.yaml first."
fi

# 7. Benchmark node pool - only required if benchmark.yaml has a nodeSelector for it
echo "-- Checking benchmark node pool..."
if grep -qE '^\s*workload:\s*benchmark\s*$' "${JOB_YAML}" 2>/dev/null; then
  BENCH_NODES="$(kubectl get nodes -l workload=benchmark --no-headers 2>/dev/null | wc -l)"
  if [[ "${BENCH_NODES}" -gt 0 ]]; then
    ok "Found ${BENCH_NODES} node(s) with label 'workload=benchmark'"
  else
    fail "${JOB_YAML} requires a 'workload=benchmark' node, but no such node exists"
    fail "  Fix: kubectl label node <n> workload=benchmark"
    fail "       (optional taint: kubectl taint node <n> workload=benchmark:NoSchedule)"
    fail "  Or: remove nodeSelector/tolerations from ${JOB_YAML} to schedule anywhere"
  fi
else
  ok "${JOB_YAML} has no benchmark-specific nodeSelector - will schedule on any node"
fi

# 8. DNS for token / deploy endpoints (best-effort)
echo "-- Checking DNS for normunda.de..."
if getent hosts normunda.de >/dev/null 2>&1; then
  ok "normunda.de resolves"
else
  warn "normunda.de does not resolve locally — deploy-camunda-assets.sh may fail"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo
  echo "Preflight failed. Fix the [FAIL] items above before running." >&2
  exit 1
fi

echo "=== Preflight OK ==="
echo

echo "=== Ensuring namespace exists ==="
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"

echo "=== Deploying Camunda to the cluster (Helm) ==="
helm repo add camunda https://helm.camunda.io >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "Using chart: ${CHART_REF} --version ${CHART_VERSION}"
echo "Using values file: ${VALUES_FILE}"

helm upgrade --install "${RELEASE_NAME}" "${CHART_REF}" \
  -n "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --wait \
  --timeout "${HELM_TIMEOUT}"

echo "=== Waiting for Camunda workloads to be Ready ==="
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod --all --timeout="${HELM_TIMEOUT}"

echo "=== Waiting 60s for cluster to stabilize ==="
sleep 60

echo "=== Applying payload ConfigMap ==="
kubectl apply -f "${PAYLOAD_YAML}"

echo "=== Rebalancing leaders via Zeebe Gateway actuator ==="
kubectl -n "${NAMESPACE}" port-forward svc/camunda-zeebe-gateway 9600:9600 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" >/dev/null 2>&1 || true' EXIT

# wait until actuator is reachable
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:9600/orchestration/actuator/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

curl -fsS -X POST "http://127.0.0.1:9600/orchestration/actuator/rebalance" || true
echo
echo "Rebalance triggered."

echo "=== Deploying Camunda Assets ==="
./deploy-camunda-assets.sh

echo
echo "=== Creating benchmark job ==="
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found
kubectl apply -n "${NAMESPACE}" -f "${JOB_YAML}"

echo "Waiting for pod creation..."
POD_NAME=""
for i in {1..120}; do
  POD_NAME="$(kubectl get pods -n "${NAMESPACE}" -l job-name="${JOB_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${POD_NAME}" ]] && break
  sleep 1
done

if [[ -z "${POD_NAME}" ]]; then
  echo "ERROR: Pod not created."
  exit 1
fi

echo "Pod detected: ${POD_NAME}"

echo "Waiting for container start..."
STARTED_AT=""
for i in {1..300}; do
  STARTED_AT="$(kubectl get pod -n "${NAMESPACE}" "${POD_NAME}" \
    -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null || true)"
  [[ -n "${STARTED_AT}" ]] && break
  sleep 1
done

if [[ -z "${STARTED_AT}" ]]; then
  echo "ERROR: Container never reached running state."
  exit 1
fi

START_EPOCH_MS=$(date -u -d "${STARTED_AT}" +%s%3N)

echo
echo "=== Benchmark started ==="
echo "Start time (RFC3339): ${STARTED_AT}"
echo "Start time (epoch ms): ${START_EPOCH_MS}"
echo "(Use these timestamps to align CloudWatch dashboard windows)"
echo

echo "Sleeping for ${DURATION_SECONDS}s (15 minutes)..."
sleep "${DURATION_SECONDS}"

END_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
END_EPOCH_MS=$(date -u -d "${END_AT}" +%s%3N)

echo
echo "=== Stopping benchmark ==="
kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" --wait=true

echo
echo "=== Benchmark finished ==="
echo "End time (RFC3339): ${END_AT}"
echo "End time (epoch ms): ${END_EPOCH_MS}"
echo

echo "=== Summary ==="
echo "Start (RFC3339): ${STARTED_AT}"
echo "End   (RFC3339): ${END_AT}"
echo "Duration: $(( (END_EPOCH_MS - START_EPOCH_MS) / 1000 )) seconds"