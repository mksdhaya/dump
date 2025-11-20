#!/usr/bin/env bash
set -euo pipefail

TENANT=""
LABEL_KEY="capsule.clastix.io/tenant"

usage() {
  echo "Usage: $0 --tenant <tenant-name> restore"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      TENANT="$2"
      shift 2
      ;;
    restore)
      ACTION="restore"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

if [[ -z "${TENANT}" || "${ACTION}" != "restore" ]]; then
  usage
fi

echo "➡️ Running restore for tenant: ${TENANT}"

# --------------------------
# FIX: filter only tenant namespaces
# --------------------------
NAMESPACES=$(kubectl get ns \
  -l "${LABEL_KEY}=${TENANT}" \
  -o jsonpath='{.items[*].metadata.name}')

if [[ -z "${NAMESPACES}" ]]; then
  echo "❌ No namespaces found for tenant '${TENANT}'."
  exit 1
fi

echo "Namespaces to patch: ${NAMESPACES}"

# --------------------------
# Get Tenant metadata
# --------------------------
TENANT_UID=$(kubectl get tenant "${TENANT}" -o jsonpath='{.metadata.uid}')
TENANT_API_VERSION=$(kubectl get tenant "${TENANT}" -o jsonpath='{.apiVersion}')

# --------------------------
# Patch each namespace
# --------------------------
for ns in ${NAMESPACES}; do
  echo "Processing namespace: ${ns}"

  HAS_OWNER=$(kubectl get ns "${ns}" \
    -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)

  if [[ "${HAS_OWNER}" == "${TENANT}" ]]; then
    echo " ✔ already linked. Skipping."
    continue
  fi

  echo " → Patching ownerReference..."

  kubectl patch ns "${ns}" --type=json -p "
  [
    {
      \"op\": \"add\",
      \"path\": \"/metadata/ownerReferences\",
      \"value\": [
        {
          \"apiVersion\": \"${TENANT_API_VERSION}\",
          \"kind\": \"Tenant\",
          \"name\": \"${TENANT}\",
          \"uid\": \"${TENANT_UID}\"
        }
      ]
    }
  ]
  "

  echo " ✔ patched"
done

echo "🎉 Completed restore for tenant '${TENANT}'."
