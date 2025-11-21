#!/usr/bin/env bash
set -euo pipefail

TENANT=$1
CLUSTER=$2
VELERO_NS="velero-system"

info(){ echo "INFO:  $1"; }
fail(){ echo "FAIL:  $1"; exit 1; }

if [[ -z "$TENANT" || -z "$CLUSTER" ]]; then
  echo "Usage: $0 <tenant-name> <cluster-name>"
  exit 1
fi

info "Checking Velero CLI..."
command -v velero >/dev/null || fail "Velero CLI not found."

info "Checking tenant '$TENANT'..."
kubectl get tenant "$TENANT" >/dev/null 2>&1 || fail "Tenant not found."

# Extract allowed SCs
ALLOWED=$(kubectl get tenant "$TENANT" -o jsonpath='{.spec.storageClasses.allowed[*]}' 2>/dev/null || true)
REGEX=$(kubectl get tenant "$TENANT" -o jsonpath='{.spec.storageClasses.allowedRegex}' 2>/dev/null || true)

ALL_SCS=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

MATCHED=()

# explicit list
if [[ -n "$ALLOWED" ]]; then
  for s in $ALLOWED; do
    if kubectl get sc "$s" >/dev/null 2>&1; then
      MATCHED+=("$s")
    fi
  done
fi

# regex list
if [[ -n "$REGEX" ]]; then
  for s in $ALL_SCS; do
    if [[ "$s" =~ $REGEX ]]; then
      MATCHED+=("$s")
    fi
  done
fi

# remove duplicates
MATCHED=($(printf "%s\n" "${MATCHED[@]}" | sort -u))

if [[ ${#MATCHED[@]} -eq 0 ]]; then
  info "No StorageClasses matched for tenant. Skipping SC backup."
  exit 0
fi

SC_CSV=$(IFS=,; echo "${MATCHED[*]}")
BACKUP_NAME="${TENANT}-${CLUSTER}-sc"

info "StorageClasses to backup: $SC_CSV"

info "Creating tenant StorageClass backup '$BACKUP_NAME'..."
velero create backup "$BACKUP_NAME" \
  --include-cluster-resources=true \
  --include-resources=storageclasses.storage.k8s.io \
  --include-names="$SC_CSV" \
  -n "$VELERO_NS" || fail "Velero SC backup failed."

info "Tenant StorageClass backup completed: $BACKUP_NAME"
