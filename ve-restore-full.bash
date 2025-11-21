#!/bin/bash
# Usage: ./velero-restore-full.sh <tenant-name> <cluster-name>

restore_tenant_name="$1"
cluster_name="$2"
velero_namespace="velero-system"

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

# -------------------------
# Restore functions
# -------------------------
restore_tenant_resource() {
  local backup_name="${restore_tenant_name}-${cluster_name}-tenant"
  info "Restoring tenant resource from backup: $backup_name"

  velero restore create --from-backup "$backup_name" || fail "Tenant resource restore failed!"
  info "Tenant resource restore completed"
}

restore_tenant_namespaces() {
  local backup_name="${restore_tenant_name}-${cluster_name}-ns"
  info "Restoring tenant namespaces from backup: $backup_name"

  velero restore create --from-backup "$backup_name" || fail "Tenant namespaces restore failed!"
  info "Tenant namespaces restore completed"
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
# Main function
# -------------------------
main() {
  [[ -z "$restore_tenant_name" || -z "$cluster_name" ]] && { echo "Usage: $0 <tenant-name> <cluster-name>"; exit 1; }

  check_velero_cli
  check_velero_installed
  check_velero_pod_running

  restore_tenant_resource
  restore_tenant_namespaces
  restore_tenant_storageclasses

  info "All restore steps completed for tenant '$restore_tenant_name' in cluster '$cluster_name'"
}

main "$@"
