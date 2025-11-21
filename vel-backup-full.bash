#!/bin/bash
# Usage: ./velero-backup-full.sh <tenant-name> <cluster-name>

backup_tenant_name="$1"
cluster_name="$2"
velero_namespace="velero-system"

info() { echo "INFO:  $1"; }
fail() { echo "FAIL:  $1"; exit 1; }

# -------------------------
# Pre-check functions
# -------------------------
check_velero_cli() {
  info "Checking if Velero CLI is installed..."
  command -v velero >/dev/null 2>&1 || fail "Velero CLI not found! Please install Velero CLI."
  info "Velero CLI is installed"
}

check_velero_installed() {
  info "Checking if Velero is installed in the cluster..."
  helm list -n $velero_namespace | grep -q velero || fail "Velero is not installed in the cluster. Please install it via Helm."
  info "Velero is installed in the cluster."
}

check_velero_pod_running() {
  info "Checking if Velero pod is running in namespace $velero_namespace..."
  kubectl get pods -n $velero_namespace | grep -q velero || fail "Velero pod is not running. Please ensure it is deployed."
  info "Velero pod is running."
}

check_backup_storage_location() {
  info "Checking BackupStorageLocation..."
  local status phase access
  phase=$(kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].status.phase}')
  access=$(kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].spec.accessMode}')
  [[ "$phase" == "Available" ]] || fail "BackupStorageLocation not in 'Available' state."
  [[ "$access" == "ReadWrite" ]] || fail "BackupStorageLocation accessMode not 'ReadWrite'."
  info "BackupStorageLocation is ready."
}

check_tenant_exists() {
  kubectl get tenant "$backup_tenant_name" >/dev/null 2>&1 || fail "Tenant '$backup_tenant_name' not found."
  info "Tenant '$backup_tenant_name' exists."
}

# -------------------------
# Backup functions
# -------------------------

backup_tenant_resource() {
  local backup_name="${backup_tenant_name}-${cluster_name}-tenant"
  info "Backing up tenant resource: $backup_name"

  velero backup create "$backup_name" \
    --include-cluster-resources=true \
    --include-resources=tenants.capsule.clastix.io \
    --selector "capsule.clastix.io/tenant=$backup_tenant_name" \
    -n $velero_namespace || fail "Tenant resource backup failed!"
  
  info "Tenant resource backup completed: $backup_name"
}

backup_tenant_namespaces() {
  local backup_name="${backup_tenant_name}-${cluster_name}-ns"
  info "Backing up tenant namespaces: $backup_name"

  velero backup create "$backup_name" \
    --include-namespaces $(kubectl get ns -l capsule.clastix.io/tenant=$backup_tenant_name -o jsonpath='{.items[*].metadata.name}') \
    -n $velero_namespace || fail "Tenant namespaces backup failed!"

  info "Tenant namespaces backup completed: $backup_name"
}

backup_tenant_storageclasses() {
  local backup_name="${backup_tenant_name}-${cluster_name}-sc"
  info "Backing up tenant StorageClasses: $backup_name"

  # Get allowedRegex
  local regex
  regex=$(kubectl get tenant "$backup_tenant_name" -o jsonpath='{.spec.storageClasses.allowedRegex}' | tr -d '"')
  [[ -n "$regex" ]] || fail "Tenant has empty allowedRegex"

  info "allowedRegex: $regex"

  # Find matching SCs
  local all_scs matched_scs
  all_scs=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  matched_scs=()
  for sc in $all_scs; do
    [[ "$sc" =~ $regex ]] && matched_scs+=("$sc")
  done

  [[ ${#matched_scs[@]} -gt 0 ]] || fail "No StorageClasses match allowedRegex for tenant"

  info "Matched SCs: ${matched_scs[*]}"

  # Label matched SCs
  for sc in "${matched_scs[@]}"; do
    kubectl label sc "$sc" tenant="$backup_tenant_name" --overwrite
    info "Labeled SC: $sc"
  done

  # Velero backup
  velero backup create "$backup_name" \
    --selector tenant="$backup_tenant_name" \
    --include-cluster-resources=true \
    --include-resources=storageclasses.storage.k8s.io \
    -n $velero_namespace || fail "StorageClass backup failed!"

  info "Tenant StorageClass backup completed: $backup_name"
}

# -------------------------
# Main function
# -------------------------
main() {
  [[ -z "$backup_tenant_name" || -z "$cluster_name" ]] && { echo "Usage: $0 <tenant-name> <cluster-name>"; exit 1; }

  check_velero_cli
  check_velero_installed
  check_velero_pod_running
  check_backup_storage_location
  check_tenant_exists

  backup_tenant_resource
  backup_tenant_namespaces
  backup_tenant_storageclasses

  info "All backups completed for tenant '$backup_tenant_name' in cluster '$cluster_name'."
}

main "$@"
