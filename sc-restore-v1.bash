#!/bin/bash
# Usage: ./velero-restore-sc.sh <tenant-name> <backup-name>

TENANT="$1"
BACKUP_NAME="$2"
VELERO_NS="velero-system"
RESTORE_NAME="restore-sc-$TENANT"

if [ -z "$TENANT" ] || [ -z "$BACKUP_NAME" ]; then
  echo "Usage: $0 <tenant-name> <backup-name>"
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
# Check backup exists
# -------------------------
velero get backup | grep -q "$BACKUP_NAME"
if [ $? -ne 0 ]; then
  fail "Backup '$BACKUP_NAME' not found"
fi

info "Backup found: $BACKUP_NAME"

# -------------------------
# Restore only storageclasses with tenant label
# -------------------------
info "Restoring StorageClasses for tenant '$TENANT'..."

velero restore create "$RESTORE_NAME" \
  --from-backup "$BACKUP_NAME" \
  --selector tenant="$TENANT" \
  --include-resources storageclasses.storage.k8s.io \
  -n "$VELERO_NS"

if [ $? -ne 0 ]; then
  fail "Restore failed"
fi

info "Restore complete: $RESTORE_NAME"
