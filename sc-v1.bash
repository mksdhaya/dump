#!/bin/bash
# Usage: ./velero-backup-sc.sh <tenant-name>

TENANT="$1"
VELERO_NS="velero-system"
BACKUP_NAME="sc-backup-$TENANT"

if [ -z "$TENANT" ]; then
  echo "Usage: $0 <tenant-name>"
  exit 1
fi

info() { echo "INFO: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# -------------------------
# Check Velero CLI
# -------------------------
command -v velero >/dev/null 2>&1 || fail "Velero CLI not installed"
info "Velero CLI is installed"

# -------------------------
# Extract allowedRegex
# -------------------------
info "Fetching allowedRegex for tenant '$TENANT'..."

ALLOWED_REGEX=$(kubectl get tenant "$TENANT" -o jsonpath='{.spec.storageClasses.allowedRegex}' | tr -d '"')

if [ -z "$ALLOWED_REGEX" ]; then
  fail "allowedRegex is empty for tenant '$TENANT'"
fi

info "allowedRegex: $ALLOWED_REGEX"

# -------------------------
# Find matching SCs (regex only)
# -------------------------
info "Finding StorageClasses matching regex..."

MATCHED_SCS=""

ALL_SCS=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for sc in $ALL_SCS; do
  if [[ "$sc" =~ $ALLOWED_REGEX ]]; then
    MATCHED_SCS+="$sc "
  fi
done

if [ -z "$MATCHED_SCS" ]; then
  fail "No StorageClasses match allowedRegex for tenant '$TENANT'"
fi

info "Matched SCs: $MATCHED_SCS"

# -------------------------
# Label matched SCs
# -------------------------
info "Labeling matched StorageClasses..."

for sc in $MATCHED_SCS; do
  kubectl label sc "$sc" tenant="$TENANT" --overwrite
  info "Labeled SC: $sc"
done

# -------------------------
# Velero backup
# -------------------------
info "Creating Velero backup..."

velero backup create "$BACKUP_NAME" \
  --selector tenant="$TENANT" \
  --include-cluster-resources=true \
  -n "$VELERO_NS"

if [ $? -ne 0 ]; then
  fail "Backup failed"
fi

info "Backup complete: $BACKUP_NAME"
