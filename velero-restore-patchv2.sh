#!/usr/bin/env bash
set -euo pipefail

# --------------------------
# DEFAULT CONFIG
# --------------------------
TENANT=""
LABEL_KEY="capsule.clastix.io/tenant"

usage() {
  echo "Usage: $0 --tenant <tenant-name> restore"
  exit 1
}

# --------------------------
# ARGUMENT PARSING
# --------------------------
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

echo "🔧 Restoring namespaces for tenant: ${TENANT}"
echo "🔧 Using label selector: ${LABEL_KEY}=${TENANT}"

# --------------------------
# FETCH TENANT NAMESPACES
# --------------------------
NAMESPACES=$(kubectl get ns -l "${LABEL_KEY}=${TENANT}" -o jsonpath='{.items[*].metadata.name}')

if [[ -z "${NAMESPACES}" ]]; then
  echo "❌ No namespaces found for tenant '${TENANT}'"
  exit 1
fi

echo "📝 Namespaces found: ${NAMESPACES}"

# --------------------------
# PATCH OWNERREFERENCES
# --------------------------
TENANT_UID=$(kubectl get tenant "${TENANT}" -o jsonpath='{.metadata.uid}')
TENANT_API_VERSION=$(kubectl get tenant "${TENANT}" -o jsonpath='{.apiVersion}')
TENANT_KIND="Tenant"
TENANT_NAME="${TENANT}"

echo "🔎 Tenant UID: ${TENANT_UID}"
echo ""

for ns in ${NAMESPACES}; do
  echo "➡️ Checking namespace: ${ns}"

  # Skip if already has ownerReference
  HAS_OWNER=$(kubectl get ns "${ns}" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)

  if [[ "${HAS_OWNER}" == "${TENANT_NAME}" ]]; then
    echo "   ✔️ Already correctly linked. Skipping."
    continue
  fi

  echo "   🔧 Patching ownerReference..."

  kubectl patch namespace "${ns}" --type='json' -p "
  [
    {
      \"op\": \"add\",
      \"path\": \"/metadata/ownerReferences\",
      \"value\": [
        {
          \"apiVersion\": \"${TENANT_API_VERSION}\",
          \"kind\": \"${TENANT_KIND}\",
          \"name\": \"${TENANT_NAME}\",
          \"uid\": \"${TENANT_UID}\"
        }
      ]
    }
  ]
  "

  echo "   ✔️ Patched for ${ns}"
done

echo ""
echo "🎉 Restore patch completed successfully for tenant '${TENANT}'"
