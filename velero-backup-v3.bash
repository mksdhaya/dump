#!/bin/bash

# Input variables
backup_tenant_name=$1
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

check_backup_storage_location() {
  info "Checking BackupStorageLocation state..."
  kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].status.phase}' | grep -q "Available"
  if [ $? -ne 0 ]; then
    fail "BackupStorageLocation is not in 'Available' state. Please check the configuration."
  fi
  info "BackupStorageLocation is in 'Available' state."

  kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].spec.accessMode}' | grep -q "ReadWrite"
  if [ $? -ne 0 ]; then
    fail "BackupStorageLocation access mode is not 'ReadWrite'. Please fix the configuration."
  fi
  info "BackupStorageLocation access mode is 'ReadWrite'."
}

check_tenant_label() {
  info "Checking if tenant has label 'capsule.clastix.io/tenant=$backup_tenant_name'..."
  kubectl get tenant -l capsule.clastix.io/tenant=$backup_tenant_name -o name | grep -q "tenant"
  if [ $? -ne 0 ]; then
    fail "Tenant with label 'capsule.clastix.io/tenant=$backup_tenant_name' not found."
  fi
  info "Tenant label matches: 'capsule.clastix.io/tenant=$backup_tenant_name'."
}

# ------------------------------
# Backup functions
# ------------------------------
backup_tenant_resource() {
  info "Taking backup of tenant resource $backup_tenant_name in cluster $cluster_name..."
  velero create backup "${backup_tenant_name}-${cluster_name}-tenant" \
    --include-cluster-resources=true \
    --include-resources=tenants.capsule.clastix.io \
    --selector "capsule.clastix.io/tenant=$backup_tenant_name" \
    -n $velero_namespace
  if [ $? -eq 0 ]; then
    info "Tenant resource backup created successfully."
  else
    fail "Tenant resource backup failed!"
  fi
}

backup_tenant_namespaces() {
  info "Backing up namespaces for tenant $backup_tenant_name..."
  TENANT_NS=$(kubectl get ns -l capsule.clastix.io/tenant=$backup_tenant_name -o jsonpath='{.items[*].metadata.name}')
  
  if [ -z "$TENANT_NS" ]; then
    info "No namespaces found for tenant $backup_tenant_name. Skipping namespace backup."
    return
  fi

  velero create backup "${backup_tenant_name}-${cluster_name}-ns" \
    --include-namespaces $TENANT_NS \
    --exclude-resources persistentvolumes,persistentvolumeclaims,volumesnapshots
  if [ $? -eq 0 ]; then
    info "Namespace backup completed for tenant $backup_tenant_name."
  else
    fail "Namespace backup failed!"
  fi
}

backup_tenant_storageclasses() {
  info "Backing up StorageClasses allowed for tenant $backup_tenant_name..."

  ALLOWED_SC=$(kubectl get tenant $backup_tenant_name -o jsonpath='{.spec.allowedStorageClasses[*]}')
  ALLOWED_REGEX=$(kubectl get tenant $backup_tenant_name -o jsonpath='{.spec.allowedStorageClassesRegex}')

  ALL_SC=$(kubectl get sc -o name | sed 's|^storageclass/||')
  MATCHED_SC=""
  for sc in $ALL_SC; do
    if [[ " $ALLOWED_SC " =~ " $sc " ]]; then
      MATCHED_SC="$MATCHED_SC $sc"
    elif [[ -n "$ALLOWED_REGEX" && $sc =~ $ALLOWED_REGEX ]]; then
      MATCHED_SC="$MATCHED_SC $sc"
    fi
  done

  if [ -z "$MATCHED_SC" ]; then
    info "No matching StorageClasses found for tenant $backup_tenant_name. Skipping SC backup."
    return
  fi

  TMP_FILE="/tmp/${backup_tenant_name}-sc-backup.yaml"
  kubectl get sc $MATCHED_SC -o yaml > $TMP_FILE

  velero create backup "${backup_tenant_name}-${cluster_name}-sc" \
    --include-cluster-resources \
    --include-resources customresourcedefinitions,storageclasses \
    --from-file $TMP_FILE

  if [ $? -eq 0 ]; then
    info "StorageClass backup completed for tenant $backup_tenant_name."
  else
    fail "StorageClass backup failed!"
  fi
}

# ------------------------------
# Main function
# ------------------------------
main() {
  if [ -z "$backup_tenant_name" ] || [ -z "$cluster_name" ]; then
    echo "Usage: $0 <backup-tenant-name> <cluster-name>"
    exit 1
  fi

  # Pre-checks
  check_velero_cli
  check_velero_installed
  check_velero_pod_running
  check_backup_storage_location
  check_tenant_label

  # Backup steps
  backup_tenant_resource
  backup_tenant_namespaces
  backup_tenant_storageclasses

  info "All backups completed for tenant $backup_tenant_name in cluster $cluster_name."
}

main "$@"
