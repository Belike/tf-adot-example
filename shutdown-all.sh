#!/bin/bash
set -euo pipefail

###############################################################################
# 1. Get cluster info from Terraform
###############################################################################
echo "🧾 Reading Terraform outputs..."

AWS_REGION="$(terraform output -raw aws_region 2>/dev/null || true)"
CLUSTER_NAME="$(terraform output -raw cluster_name 2>/dev/null || true)"

if [[ -n "${AWS_REGION}" && -n "${CLUSTER_NAME}" ]]; then
  echo "✅ Found cluster: ${CLUSTER_NAME} in ${AWS_REGION}"

  echo "🔗 Updating kubeconfig..."
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --alias "${CLUSTER_NAME}" || true

  echo "🌐 Uninstalling ingress-nginx (removes NLB)..."
  if helm list -n ingress-nginx 2>/dev/null | grep -q ingress-nginx; then
    helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 5m || true
    echo "⏳ Waiting 30 seconds for AWS to cleanup LoadBalancer..."
    sleep 30
    echo "✅ ingress-nginx uninstalled."
  else
    echo "ℹ️  ingress-nginx not found, skipping."
  fi

  echo "🗑️  Removing EKS addons..."
  for addon in adot amazon-cloudwatch-observability; do
    STATUS="$(aws eks describe-addon \
      --cluster-name "${CLUSTER_NAME}" \
      --addon-name "${addon}" \
      --region "${AWS_REGION}" \
      --query 'addon.status' \
      --output text 2>/dev/null || echo "NOT_FOUND")"
    if [[ "${STATUS}" != "NOT_FOUND" ]]; then
      echo "  Deleting addon: ${addon}..."
      aws eks delete-addon \
        --cluster-name "${CLUSTER_NAME}" \
        --region "${AWS_REGION}" \
        --addon-name "${addon}" || true
    else
      echo "  ℹ️  Addon '${addon}' not found, skipping."
    fi
  done

  echo "🗑️  Uninstalling cert-manager..."
  if helm list -n cert-manager 2>/dev/null | grep -q cert-manager; then
    helm uninstall cert-manager -n cert-manager --wait --timeout 5m || true
    echo "✅ cert-manager uninstalled."
  else
    echo "ℹ️  cert-manager not found, skipping."
  fi
  echo "💾 Deleting all PVCs (triggers EBS volume deletion via CSI driver)..."
  kubectl delete pvc --all --all-namespaces --timeout=120s || true
  echo "⏳ Waiting for PersistentVolumes to be released..."
  kubectl wait --for=delete pv --all --timeout=120s 2>/dev/null || true
else
  echo "⚠️  Could not retrieve cluster info from Terraform state, skipping Helm/addon cleanup."
fi

###############################################################################
# 2. Terraform destroy
###############################################################################
echo
echo "💥 Destroying all Terraform-managed infrastructure..."
terraform destroy -auto-approve

###############################################################################
# 3. Clean up orphaned EBS volumes
###############################################################################
if [[ -n "${AWS_REGION}" && -n "${CLUSTER_NAME}" ]]; then
  echo "🧹 Checking for orphaned EBS volumes tagged for cluster '${CLUSTER_NAME}'..."
  ORPHANED_VOLUMES="$(aws ec2 describe-volumes \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text 2>/dev/null || true)"

  if [[ -n "${ORPHANED_VOLUMES}" ]]; then
    echo "  Found orphaned volumes: ${ORPHANED_VOLUMES}"
    for vol_id in ${ORPHANED_VOLUMES}; do
      echo "  Deleting EBS volume: ${vol_id}..."
      aws ec2 delete-volume --region "${AWS_REGION}" --volume-id "${vol_id}" || true
    done
    echo "✅ Orphaned EBS volumes deleted."
  else
    echo "ℹ️  No orphaned EBS volumes found."
  fi
fi

echo "✅ Cleanup complete!"
