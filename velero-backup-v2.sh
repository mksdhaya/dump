#!/bin/bash

# Input variables
backup_tenant_name=$1
cluster_name=$2
velero_namespace="velero-system"

# ------------------------------
# Pre-check functions
# ------------------------------

check_velero_cli() {
  echo "Checking if Velero CLI is installed..."
  if ! command -v velero &>/dev/null; then
    echo "Velero CLI not found! Please install Velero CLI."
    exit 1
  else
    echo "Velero CLI is installed."
  fi
}

check_velero_installed() {
  echo "Checking if Velero is installed in the cluster..."
  helm list -n $velero_namespace | grep -q velero
  if [ $? -ne 0 ]; then
    echo "Velero is not installed in the cluster. Please install it via Helm."
    exit 1
  else
    echo "Velero is installed in the cluster."
  fi
}

check_velero_pod_running() {
  echo "Checking if Velero pod is running under the $velero_namespace namespace..."
  kubectl get pods -n $velero_namespace | grep -q velero
  if [ $? -ne 0 ]; then
    echo "Velero pod is not running. Please ensure the pod is deployed and running."
    exit 1
  else
    echo "Velero pod is running."
  fi
}

check_backup_storage_location() {
  echo "Checking BackupStorageLocation state..."
  kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].status.phase}' | grep -q "Available"
  if [ $? -ne 0 ]; then
    echo "BackupStorageLocation is not in 'Available' state. Please check the configuration."
    exit 1
  else
    echo "BackupStorageLocation is in 'Available' state."
  fi

  kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].spec.accessMode}' | grep -q "ReadWrite"
  if [ $? -ne 0 ]; then
    echo "BackupStorageLocation access mode is not 'ReadWrite'. Please fix the configuration."
    exit 1
  else
    echo "BackupStorageLocation access mode is 'ReadWrite'."
  fi
}

check_tenant_label() {
  echo "Checking if tenant has label 'capsule.clastix.io/tenant=$backup_tenant_name'..."
  kubectl get tenant -l capsule.clastix.io/tenant=$backup_tenant_name -o name | grep -q "tenant"
  if [ $? -ne 0 ]; then
    echo "Tenant with label 'capsule.clastix.io/tenant=$backup_tenant_name' not found."
    exit 1
  else
    echo "Tenant label matches: 'capsule.clastix.io/tenant=$backup_tenant_name'."
  fi
}

# ------------------------------
# Backup functions
# ------------------------------

# Part 1: Backup tenant resource (cluster-scoped)
backup_tenant_resource() {
  echo "Taking backup of tenant resource $backup_tenant_name in cluster $cluster_name..."
  velero create backup "${backup_tenant_name}-${cluster_name}-tenant" \
    --include-cluster-resources=true \
    --include-resources=tenants.capsule.clastix.io \
    --selector "capsule.clastix.io/tenant=$backup_tenant_name" \
    -n $velero_namespace

  if [ $? -eq 0 ]; then
    echo "Tenant resource backup created successfully."
  else
    echo "Tenant resource backup failed!"
    exit 1
  fi
}

# Part 2: Backup tenant namespace resources
backup_tenant_namespaces() {
  echo "Backing up namespaces for tenant $backup_tenant_name..."
  TENANT_NS=$(kubectl get ns -l capsule.clastix.io/tenant=$backup_tenant_name -o jsonpath='{.items[*].metadata.name}')
  
  if [ -z "$TENANT_NS" ]; then
    echo "No namespaces found for tenant $backup_tenant_name. Skipping namespace backup."
    return
  fi

  velero create backup "${backup_tenant_name}-${cluster_name}-ns" \
    --include-namespaces $TENANT_NS \
    --exclude-resources persistentvolumes,persistentvolumeclaims,volumesnapshots

  echo "Namespace backup completed for tenant $backup_tenant_name."
}

# Part 3: Backup tenant-specific StorageClasses
backup_tenant_storageclasses() {
  echo "Backing up StorageClasses allowed for tenant $backup_tenant_name..."

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
    echo "No matching StorageClasses found for tenant $backup_tenant_name. Skipping SC backup."
    return
  fi

  TMP_FILE="/tmp/${backup_tenant_name}-sc-backup.yaml"
  kubectl get sc $MATCHED_SC -o yaml > $TMP_FILE

  velero create backup "${backup_tenant_name}-${cluster_name}-sc" \
    --include-cluster-resources \
    --include-resources customresourcedefinitions,storageclasses \
    --from-file $TMP_FILE

  echo "StorageClass backup completed for tenant $backup_tenant_name."
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

  # Backups
  backup_tenant_resource
  backup_tenant_namespaces
  backup_tenant_storageclasses

  echo "All backups completed for tenant $backup_tenant_name in cluster $cluster_name."
}

main "$@"
