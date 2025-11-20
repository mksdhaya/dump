#!/bin/bash

# Input variables
restore_tenant_name=$1
cluster_name=$2
velero_namespace="velero-system"

# ------------------------------
# Logging helpers
# ------------------------------
info() {
  echo "INFO:  \"$1\""
}

fail() {
  echo "FAIL:  \"$1\""
  exit 1
}

# ------------------------------
# Pre-check functions
# ------------------------------
check_velero_cli() {
  info "Checking if Velero CLI is installed..."
  if ! command -v velero &>/dev/null; then
    fail "Velero CLI not found! Please install Velero CLI."
  fi
  info "Velero CLI is installed."
}

check_velero_installed() {
  info "Checking if Velero is installed in the cluster..."
  helm list -n $velero_namespace | grep -q velero
  if [ $? -ne 0 ]; then
    fail "Velero is not installed in the cluster. Please install it via Helm."
  fi
  info "Velero is installed in the cluster."
}

check_velero_pod_running() {
  info "Checking if Velero pod is running in namespace $velero_namespace..."
  kubectl get pods -n $velero_namespace | grep -q velero
  if [ $? -ne 0 ]; then
    fail "Velero pod is not running. Please ensure it is deployed."
  fi
  info "Velero pod is running."
}

# ------------------------------
# Restore functions
# ------------------------------
restore_tenant_resource() {
  BACKUP_NAME="${restore_tenant_name}-${cluster_name}-tenant"
  info "Restoring tenant resource from backup: $BACKUP_NAME"
  
  velero restore create --from-backup $BACKUP_NAME
  if [ $? -eq 0 ]; then
    info "Tenant resource restore successful."
  else
    fail "Tenant resource restore failed!"
  fi
}

restore_tenant_storageclasses() {
  info "Restoring tenant StorageClasses from backup..."

  # Name of the SC backup created earlier
  SC_BACKUP_NAME="${restore_tenant_name}-${cluster_name}-sc"

  # Check if the SC backup exists
  if ! velero get backup -n $velero_namespace | grep -q "$SC_BACKUP_NAME"; then
    info "No StorageClass backup found for tenant $restore_tenant_name. Skipping SC restore."
    return
  fi

  # Restore the backup directly
  velero restore create --from-backup "$SC_BACKUP_NAME" -n $velero_namespace

  if [ $? -eq 0 ]; then
    info "StorageClass restore initiated for tenant $restore_tenant_name."
  else
    fail "StorageClass restore failed!"
  fi
}


restore_tenant_namespaces() {
  BACKUP_NAME="${restore_tenant_name}-${cluster_name}-ns"
  info "Restoring tenant namespaces from backup: $BACKUP_NAME"

  velero restore create --from-backup $BACKUP_NAME
  if [ $? -eq 0 ]; then
    info "Tenant namespace restore completed."
  else
    fail "Tenant namespace restore failed!"
  fi
}

# ------------------------------
# Main function
# ------------------------------
main() {
  if [ -z "$restore_tenant_name" ] || [ -z "$cluster_name" ]; then
    echo "Usage: $0 <restore-tenant-name> <cluster-name>"
    exit 1
  fi

  # Pre-checks
  check_velero_cli
  check_velero_installed
  check_velero_pod_running

  # Restore steps
  restore_tenant_resource
  restore_tenant_storageclasses
  restore_tenant_namespaces

  info "All restore steps completed for tenant $restore_tenant_name in cluster $cluster_name."
}

main "$@"
