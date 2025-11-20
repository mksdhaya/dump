#!/bin/bash

# Input variables
restore_tenant_name=$1
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

# ------------------------------
# Restore functions
# ------------------------------

# Part 1: Restore tenant resource
restore_tenant_resource() {
  BACKUP_NAME="${restore_tenant_name}-${cluster_name}-tenant"
  echo "Restoring tenant resource from backup: $BACKUP_NAME"
  velero restore create --from-backup $BACKUP_NAME
}

# Part 2: Restore tenant-specific StorageClasses
restore_tenant_storageclasses() {
  echo "Restoring tenant StorageClasses..."
  
  ALLOWED_SC=$(kubectl get tenant $restore_tenant_name -o jsonpath='{.spec.allowedStorageClasses[*]}')
  ALLOWED_REGEX=$(kubectl get tenant $restore_tenant_name -o jsonpath='{.spec.allowedStorageClassesRegex}')

  ALL_SC=$(kubectl get sc -o name | sed 's|^storageclass/||')
  MATCHED_SC=""
  for sc in $ALL_SC; do
    if [[ " $ALLOWED_SC " =~ " $sc " ]]; then
      MATCHED_SC="$MATCHED_SC $sc"
    elif [[ -n "$ALLOWED_REGEX" && $sc =~ $ALLOWED_REGEX ]]; then
      MATCHED_SC="$MATCHED_SC $sc"
    fi
  done

  if [[ -z "$MATCHED_SC" ]]; then
    echo "No matching StorageClasses found for tenant $restore_tenant_name. Skipping SC restore."
    return
  fi

  TMP_FILE="/tmp/${restore_tenant_name}-sc-restore.yaml"
  kubectl get sc $MATCHED_SC -o yaml > $TMP_FILE
  kubectl apply -f $TMP_FILE

  echo "StorageClass restore completed for tenant $restore_tenant_name."
}

# Part 3: Restore tenant namespaces
restore_tenant_namespaces() {
  BACKUP_NAME="${restore_tenant_name}-${cluster_name}-ns"
  echo "Restoring tenant namespaces from backup: $BACKUP_NAME"
  velero restore create --from-backup $BACKUP_NAME
  echo "Namespace restore completed for tenant $restore_tenant_name."
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

  echo "All restore steps completed for tenant $restore_tenant_name in cluster $cluster_name."
}

main "$@"
