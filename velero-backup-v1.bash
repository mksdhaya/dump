#!/bin/bash

# Input variables
backup_tenant_name=$1
cluster_name=$2
velero_namespace="velero-system"

# Check if Velero CLI is installed
check_velero_cli() {
  echo "Checking if Velero CLI is installed..."
  if ! command -v velero &>/dev/null; then
    echo "Velero CLI not found! Please install Velero CLI."
    exit 1
  else
    echo "Velero CLI is installed."
  fi
}

# Check if Velero is installed and running in the cluster via Helm
check_velero_installed() {
  echo "Checking if Velero is installed in the cluster..."

  # Check if Velero is installed via Helm
  helm list -n $velero_namespace | grep -q velero
  if [ $? -ne 0 ]; then
    echo "Velero is not installed in the cluster. Please install it via Helm."
    exit 1
  else
    echo "Velero is installed in the cluster."
  fi
}

# Check if Velero pod is running
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

# Check if the BackupStorageLocation is in the correct state
check_backup_storage_location() {
  echo "Checking BackupStorageLocation state..."

  kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].status.phase}' | grep -q "Available"
  if [ $? -ne 0 ]; then
    echo "BackupStorageLocation is not in 'Available' state. Please check the configuration."
    exit 1
  else
    echo "BackupStorageLocation is in 'Available' state."
  fi

  # Ensure access mode is readwrite
  kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].spec.accessMode}' | grep -q "ReadWrite"
  if [ $? -ne 0 ]; then
    echo "BackupStorageLocation access mode is not 'ReadWrite'. Please fix the configuration."
    exit 1
  else
    echo "BackupStorageLocation access mode is 'ReadWrite'."
  fi
}

# Check if the tenant has the correct label
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

# Take the backup of the tenant
take_backup() {
  echo "Taking backup of tenant $backup_tenant_name in cluster $cluster_name..."
  
  velero create backup "$backup_tenant_name-$cluster_name" \
    --include-cluster-resources=true \
    --include-resources=tenants.capsule.clastix.io \
    --selector "capsule.clastix.io/tenant=$backup_tenant_name" \
    -n $velero_namespace
  
  if [ $? -eq 0 ]; then
    echo "Backup of tenant '$backup_tenant_name' in cluster '$cluster_name' was created successfully."
  else
    echo "Backup failed! Please check the logs for more details."
    exit 1
  fi
}

# Main function to call the steps
main() {
  if [ -z "$backup_tenant_name" ] || [ -z "$cluster_name" ]; then
    echo "Usage: $0 <backup-tenant-name> <cluster-name>"
    exit 1
  fi
  
  # Check the required conditions
  check_velero_cli
  check_velero_installed
  check_velero_pod_running
  check_backup_storage_location
  check_tenant_label
  
  # Take the backup
  take_backup
}

# Run the main function
main "$@"
