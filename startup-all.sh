#!/bin/bash
set -euo pipefail

###############################################################################
# Helpers
###############################################################################
check_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ ERROR: Missing required command: $cmd"
    exit 1
  fi
}

check_prereqs() {
  check_cmd terraform
  check_cmd aws
  check_cmd kubectl
  check_cmd helm
  check_cmd envsubst

  echo "🔐 Checking AWS credentials..."
  aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "❌ ERROR: AWS credentials not configured or not working."
    exit 1
  }
  echo "✅ AWS credentials look good."
}

tf_out() {
  local name="$1"
  terraform output -raw "$name"
}

wait_for_deploy() {
  local ns="$1"
  local deploy="$2"
  local timeout="${3:-300s}"
  echo "⏳ Waiting for deployment/$deploy in namespace $ns to be ready (timeout $timeout)..."
  kubectl -n "$ns" rollout status "deploy/$deploy" --timeout="$timeout"
}

ensure_ns() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
}

ensure_sa_with_irsa() {
  local ns="$1"
  local sa="$2"
  local role_arn="$3"

  kubectl -n "$ns" create serviceaccount "$sa" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" annotate serviceaccount "$sa" \
    "eks.amazonaws.com/role-arn=${role_arn}" \
    --overwrite
}

wait_for_nlb_hostname() {
  local ns="$1"
  local svc="$2"
  local host=""

  echo "⏳ Waiting for NLB hostname on Service ${ns}/${svc} ..."
  for i in {1..60}; do
    host="$(kubectl -n "${ns}" get svc "${svc}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -n "${host}" ]]; then
      echo "✅ NLB hostname: ${host}"
      echo "${host}"
      return 0
    fi
    echo "  ... still waiting (${i}/60)"
    sleep 5
  done

  echo "❌ ERROR: Timed out waiting for NLB hostname on ${ns}/${svc}"
  kubectl -n "${ns}" get svc "${svc}" -o yaml || true
  exit 1
}

wait_for_addon() {
  local cluster="$1"
  local region="$2"
  local addon="$3"
  local timeout=300
  local elapsed=0

  echo "⏳ Waiting for EKS addon '${addon}' to become ACTIVE..."
  while [[ $elapsed -lt $timeout ]]; do
    STATUS="$(aws eks describe-addon \
      --cluster-name "${cluster}" \
      --addon-name "${addon}" \
      --region "${region}" \
      --query 'addon.status' \
      --output text 2>/dev/null || echo "NOT_FOUND")"
    if [[ "${STATUS}" == "ACTIVE" ]]; then
      echo "✅ Addon '${addon}' is ACTIVE."
      return 0
    fi
    echo "  ... addon '${addon}' status: ${STATUS} (${elapsed}s / ${timeout}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  done

  echo "❌ ERROR: Timed out waiting for addon '${addon}' to become ACTIVE."
  exit 1
}

###############################################################################
# 0) Preconditions
###############################################################################
echo "🛰️ Checking prerequisites..."
check_prereqs

###############################################################################
# 1) Terraform: init + apply (EKS + node groups + IRSA roles + addons)
###############################################################################
echo "🎬 Booting up EKS infrastructure with Terraform..."

echo "🔧 Running terraform init..."
terraform init

echo "☁️  Step 1: Creating EKS cluster and dependencies..."
terraform apply -auto-approve

echo "🧾 Step 2: Reading Terraform outputs..."
AWS_REGION="$(tf_out aws_region)"
CLUSTER_NAME="$(tf_out cluster_name)"
EMAIL="$(tf_out cert_email)"
DOMAIN="$(tf_out domain_name)"
GRAFANA="$(tf_out grafana || true)"
CW_AGENT_ROLE_ARN="$(tf_out irsa_role_arn_cloudwatch_agent)"
ADOT_ROLE_ARN="$(tf_out irsa_role_arn_adot_collector)"
ADOT_NAMESPACE="$(tf_out adot_collector_namespace)"
CW_LOG_GROUP_APP="$(tf_out cloudwatch_log_group_application)"
CW_LOG_GROUP_PROMETHEUS="$(tf_out cloudwatch_log_group_prometheus)"
NAME_PREFIX="$(tf_out name_prefix)"

if [[ -z "${AWS_REGION}" || -z "${CLUSTER_NAME}" ]]; then
  echo "❌ AWS_REGION or CLUSTER_NAME empty. Check terraform outputs aws_region / cluster_name."
  exit 1
fi

if [[ -z "${EMAIL}" || -z "${DOMAIN}" ]]; then
  echo "❌ EMAIL or DOMAIN empty. Check terraform outputs cert_email / domain_name."
  exit 1
fi

if [[ -z "${NAME_PREFIX}" ]]; then
  echo "❌ name_prefix terraform output is empty."
  exit 1
fi

echo "✅ Using:"
echo "    AWS_REGION=${AWS_REGION}"
echo "    CLUSTER_NAME=${CLUSTER_NAME}"
echo "    EMAIL=${EMAIL}"
echo "    DOMAIN=${DOMAIN}"
echo "    GRAFANA=${GRAFANA:-false}"
echo "    ADOT namespace: ${ADOT_NAMESPACE}"
echo

###############################################################################
# 2) kubeconfig for EKS
###############################################################################
echo "🔗 Step 3: Updating kubeconfig for EKS..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --alias "${CLUSTER_NAME}"

echo "📡 Verifying cluster access..."
kubectl get nodes
kubectl cluster-info
echo "✅ kubeconfig ready."

###############################################################################
# 3) Namespaces + IRSA ServiceAccounts
###############################################################################
echo "🧩 Step 4: Bootstrapping namespaces + IRSA ServiceAccounts..."
ensure_ns "camunda"
ensure_ns "cert-manager"
ensure_ns "ingress-nginx"

echo "✅ Namespaces and IRSA ServiceAccounts ready."

###############################################################################
# 4) Install cert-manager via Helm
# Required by the ADOT addon's OpenTelemetry Operator webhook certificates.
###############################################################################
echo "📦 Step 5: Installing cert-manager via Helm..."
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --wait --timeout 10m

wait_for_deploy cert-manager cert-manager 300s
wait_for_deploy cert-manager cert-manager-webhook 300s
wait_for_deploy cert-manager cert-manager-cainjector 300s

###############################################################################
# 5) Install EKS addons (after cert-manager is ready)
###############################################################################
echo "📦 Step 6a: Installing amazon-cloudwatch-observability addon..."
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --addon-name amazon-cloudwatch-observability \
  --service-account-role-arn "${CW_AGENT_ROLE_ARN}" \
  --resolve-conflicts OVERWRITE 2>/dev/null || \
aws eks update-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --addon-name amazon-cloudwatch-observability \
  --service-account-role-arn "${CW_AGENT_ROLE_ARN}" \
  --resolve-conflicts OVERWRITE

echo "📦 Step 6b: Installing adot addon..."
aws eks create-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --addon-name adot \
  --resolve-conflicts OVERWRITE 2>/dev/null || \
aws eks update-addon \
  --cluster-name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --addon-name adot \
  --resolve-conflicts OVERWRITE

###############################################################################
# 6) Install ingress-nginx via Helm (AWS NLB)
###############################################################################
echo "📦 Step 7: Installing ingress-nginx via Helm (AWS NLB)..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClassResource.controllerValue=k8s.io/ingress-nginx \
  --set controller.ingressClassResource.default=true \
  --set controller.watchNamespace="" \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-scheme"="internet-facing" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-cross-zone-load-balancing-enabled"="true" \
  --wait --timeout 10m

wait_for_deploy ingress-nginx ingress-nginx-controller 600s

if ! kubectl get ingressclass nginx >/dev/null 2>&1; then
  echo "❌ IngressClass 'nginx' not found. Run: kubectl get ingressclass"
  exit 1
fi

###############################################################################
# 7) Wait for NLB hostname
###############################################################################
echo "🌐 Step 8: Fetching NLB hostname for ingress-nginx..."
NLB_HOSTNAME="$(wait_for_nlb_hostname "ingress-nginx" "ingress-nginx-controller")"

###############################################################################
# 8) Apply ClusterIssuer (letsencrypt-prod)
###############################################################################
echo "🛡️  Step 9: Applying ClusterIssuer 'letsencrypt-prod'..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: "${EMAIL}"
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF

###############################################################################
# 9) Apply StorageClass for Camunda
###############################################################################
echo "🛡️  Step 10: Applying StorageClass for Camunda (gp3)..."
kubectl apply -n camunda -f storageclass.yaml

###############################################################################
# 10) Wait for EKS addons
###############################################################################
echo "📊 Step 11a: Waiting for amazon-cloudwatch-observability addon..."
wait_for_addon "${CLUSTER_NAME}" "${AWS_REGION}" "amazon-cloudwatch-observability"

# The CW addon owns the cloudwatch-agent SA — re-apply the IRSA annotation
# in case the addon recreates it after the IRSA role was attached.
if [[ -n "${CW_AGENT_ROLE_ARN}" ]]; then
  ensure_ns "amazon-cloudwatch"
  kubectl -n amazon-cloudwatch annotate serviceaccount cloudwatch-agent \
    "eks.amazonaws.com/role-arn=${CW_AGENT_ROLE_ARN}" \
    --overwrite 2>/dev/null || true
fi

echo "🔭 Step 11b: Waiting for adot addon..."
wait_for_addon "${CLUSTER_NAME}" "${AWS_REGION}" "adot"

###############################################################################
# 11) ADOT: Kubernetes application resources
# Terraform owns AWS (IRSA role, EKS addon). The script owns the K8s layer:
# namespace, service account (with IRSA annotation), RBAC, and the collector CR.
#
# The OpenTelemetryCollector CR is applied from adot-otel-collector.yaml rather
# than an inline heredoc. This avoids bash expanding $1:$2 in Prometheus
# relabel replacement strings under set -u, which causes "unbound variable".
###############################################################################
echo "🔭 Step 11c: Deploying ADOT Kubernetes resources in '${ADOT_NAMESPACE}'..."

# Namespace
kubectl create namespace "${ADOT_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ServiceAccount — annotated with the IRSA role ARN provisioned by Terraform
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: adot-collector
  namespace: ${ADOT_NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: "${ADOT_ROLE_ARN}"
  labels:
    app.kubernetes.io/name: adot-collector
EOF

# ClusterRole + ClusterRoleBinding for Prometheus pod/service discovery
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${NAME_PREFIX}-adot-collector
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/proxy", "services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAME_PREFIX}-adot-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${NAME_PREFIX}-adot-collector
subjects:
  - kind: ServiceAccount
    name: adot-collector
    namespace: ${ADOT_NAMESPACE}
EOF

# OpenTelemetryCollector CR — applied from a static file to avoid bash
# expanding Prometheus back-references ($1, $2) inside an unquoted heredoc.
# The file has three placeholder values substituted here via envsubst.
ADOT_MANIFEST="$(dirname "$0")/adot-otel-collector.yaml"
if [[ ! -f "${ADOT_MANIFEST}" ]]; then
  echo "❌ ERROR: ${ADOT_MANIFEST} not found. It must sit alongside this script."
  exit 1
fi

# Export only the variables the manifest needs; envsubst will leave every other
# $-expression (including $1, $2 in YAML) untouched because they are not in
# the explicit variable list passed to envsubst.
export AWS_REGION ADOT_NAMESPACE CW_LOG_GROUP_PROMETHEUS ADOT_ROLE_ARN
envsubst '${AWS_REGION} ${ADOT_NAMESPACE} ${CW_LOG_GROUP_PROMETHEUS} ${ADOT_ROLE_ARN}' \
  < "${ADOT_MANIFEST}" \
  | kubectl apply -f -

echo "✅ ADOT Kubernetes resources applied."

###############################################################################
# 12) Grafana (optional)
###############################################################################
if [[ "${GRAFANA:-false}" == "true" ]]; then
  echo "📈 Step 12: Installing Grafana stack..."

  TPL="../../../../../grafana/kps-values.tpl.yaml"
  OUT="/tmp/kps-values.rendered.yaml"
  TLS_SECRET="grafana-${DOMAIN//./-}-tls"

  export DOMAIN TLS_SECRET
  envsubst < "${TPL}" > "${OUT}"

  if grep -q '\${DOMAIN}\|\${TLS_SECRET}' "${OUT}"; then
    echo "❌ ERROR: envsubst did not replace DOMAIN/TLS_SECRET in ${OUT}"
    grep -n '\${DOMAIN}\|\${TLS_SECRET}' "${OUT}" || true
    exit 1
  fi

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null

  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f "${OUT}" \
    --wait --timeout 15m
fi

###############################################################################
# 13) Final summary
###############################################################################
echo
echo "✅ NLB endpoint (use this in DNS as target):"
echo "  🌐 ${NLB_HOSTNAME}"
echo
echo "🧾 DNS suggestion for ${DOMAIN}:"
echo "  - CNAME @       -> ${NLB_HOSTNAME}   (requires apex flattening/ALIAS at provider)"
echo "  - CNAME grpc    -> ${NLB_HOSTNAME}"
echo "  - CNAME www     -> ${DOMAIN}"
echo
echo "📊 CloudWatch Container Insights:"
echo "  - Log group (application): ${CW_LOG_GROUP_APP}"
echo "  - Log group (prometheus):  ${CW_LOG_GROUP_PROMETHEUS}"
echo "  - Console: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#container-insights:infrastructure"
echo "  - CloudWatch Agent IRSA Role: ${CW_AGENT_ROLE_ARN}"
echo
echo "🔭 AWS Distro for OpenTelemetry (ADOT):"
echo "  - Collector namespace: ${ADOT_NAMESPACE}"
echo "  - Collector CR: camunda-prometheus (Prometheus -> CloudWatch EMF)"
echo "  - ADOT Collector IRSA Role: ${ADOT_ROLE_ARN}"
echo "  - CloudWatch Metrics namespace: ContainerInsights/Prometheus"
echo
echo "⚠️ Cloudflare: keep DNS-only (grey cloud) until cert issuance succeeds."
echo "✅ All done!"