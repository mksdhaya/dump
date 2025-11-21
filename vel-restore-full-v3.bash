#!/bin/bash
# Usage: ./velero-restore-full.sh <tenant-name> <cluster-name>

restore_tenant_name="$1"
cluster_name="$2"
velero_namespace="velero-system"
LABEL_KEY="capsule.clastix.io/tenant"

info() { echo "INFO:  $1"; }
fail() { echo "FAIL:  $1"; exit 1; }

# -------------------------
# Pre-checks
# -------------------------
check_velero_cli() {
  info "Checking Velero CLI..."
  command -v velero >/dev/null 2>&1 || fail "Velero CLI not found"
  info "Velero CLI installed"
}

check_velero_installed() {
  info "Checking if Velero is installed in cluster..."
  helm list -n $velero_namespace | grep -q velero || fail "Velero not installed in cluster"
  info "Velero installed"
}

check_velero_pod_running() {
  info "Checking if Velero pod is running..."
  kubectl get pods -n $velero_namespace | grep -q velero || fail "Velero pod not running"
  info "Velero pod running"
}

check_tenant_exists() {
  info "Checking if tenant '$restore_tenant_name' exists..."
  kubectl get tenant "$restore_tenant_name" >/dev/null 2>&1 || fail "Tenant '$restore_tenant_name' not found"
  info "Tenant '$restore_tenant_name' exists."
}

# -------------------------
# Restore functions
# -------------------------
restore_tenant_resource() {
  local backup_name="${restore_tenant_name}-${cluster_name}-tenant"
  info "Restoring tenant resource from backup: $backup_name"

  velero restore create --from-backup "$backup_name" || fail "Tenant resource restore failed!"
  info "Tenant resource restore completed"
}

wait_for_namespaces() {
  info "Waiting for tenant namespaces to be ready..."
  local timeout=30
  local interval=5
  local elapsed=0
  local ns_list
  ns_list=$(kubectl get ns -l "$LABEL_KEY=$restore_tenant_name" -o jsonpath='{.items[*].metadata.name}')

  while [[ -z "$ns_list" && $elapsed -lt $timeout ]]; do
    sleep $interval
    elapsed=$((elapsed + interval))
    ns_list=$(kubectl get ns -l "$LABEL_KEY=$restore_tenant_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  done

  [[ -n "$ns_list" ]] || fail "Timeout waiting for tenant namespaces to be restored"
  info "Namespaces restored: $ns_list"
}

restore_tenant_namespaces() {
  local backup_name="${restore_tenant_name}-${cluster_name}-ns"
  info "Restoring tenant namespaces from backup: $backup_name"

  velero restore create --from-backup "$backup_name" || fail "Tenant namespaces restore failed!"
  info "Tenant namespaces restore initiated"

  wait_for_namespaces
  patch_tenant_namespaces
}


restore_tenant_storageclasses() {
  local sc_backup_name="${restore_tenant_name}-${cluster_name}-sc"
  info "Restoring tenant StorageClasses from backup: $sc_backup_name"

  if ! velero get backup -n $velero_namespace | grep -q "$sc_backup_name"; then
    info "No StorageClass backup found for tenant $restore_tenant_name. Skipping SC restore."
    return
  fi

  velero restore create --from-backup "$sc_backup_name" \
    --selector tenant="$restore_tenant_name" \
    --include-resources storageclasses.storage.k8s.io -n $velero_namespace || fail "SC restore failed!"

  info "Tenant StorageClass restore completed"
}

# -------------------------
# Namespace patching
# -------------------------
patch_tenant_namespaces() {
  info "Patching namespaces for tenant '$restore_tenant_name'..."

  local namespaces
  namespaces=$(kubectl get ns -l "$LABEL_KEY=$restore_tenant_name" -o jsonpath='{.items[*].metadata.name}')
  [[ -n "$namespaces" ]] || { info "No namespaces found for tenant. Skipping patch."; return; }
  info "Namespaces to patch: $namespaces"

  local tenant_uid tenant_api_version
  tenant_uid=$(kubectl get tenant "$restore_tenant_name" -o jsonpath='{.metadata.uid}')
  tenant_api_version=$(kubectl get tenant "$restore_tenant_name" -o jsonpath='{.apiVersion}')
  info "Tenant UID: $tenant_uid, API Version: $tenant_api_version"

  for ns in $namespaces; do
    info "Processing namespace: $ns"

    local owner
    owner=$(kubectl get ns "$ns" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)

    if [[ "$owner" == "$restore_tenant_name" ]]; then
      info "Namespace '$ns' already linked. Skipping."
      continue
    fi

    info "Patching ownerReference for namespace '$ns'..."
    kubectl patch ns "$ns" --type=json -p "
    [
      {
        \"op\": \"add\",
        \"path\": \"/metadata/ownerReferences\",
        \"value\": [
          {
            \"apiVersion\": \"$tenant_api_version\",
            \"kind\": \"Tenant\",
            \"name\": \"$restore_tenant_name\",
            \"uid\": \"$tenant_uid\"
          }
        ]
      }
    ]
    "
    info "Namespace '$ns' patched successfully."
  done
}

# -------------------------
# Main function
# -------------------------
main() {
  [[ -z "$restore_tenant_name" || -z "$cluster_name" ]] && { echo "Usage: $0 <tenant-name> <cluster-name>"; exit 1; }

  info "Starting restore for tenant '$restore_tenant_name' in cluster '$cluster_name'"

  check_velero_cli
  check_velero_installed
  check_velero_pod_running
  check_tenant_exists

  restore_tenant_resource
  wait_for_namespaces
  restore_tenant_namespaces
  restore_tenant_storageclasses

  info "All restore steps completed for tenant '$restore_tenant_name' in cluster '$cluster_name'"
}

main "$@"
