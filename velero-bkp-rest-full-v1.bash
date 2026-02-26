#!/bin/bash
# Integrated Velero Tenant Backup/Restore Script
# Usage: ./velero-tenant-tool.sh --backup <tenant-name> <cluster-name>
#        ./velero-tenant-tool.sh --restore <tenant-name> <cluster-name>
#        ./velero-tenant-tool.sh --help

set -e

# Global variables
velero_namespace="velero-system"
LABEL_KEY="capsule.clastix.io/tenant"
mode=""
tenant_name=""
cluster_name=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# -------------------------
# Utility functions
# -------------------------
info() { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail() { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }

show_help() {
    cat << EOF
Usage: $0 [OPTION] <tenant-name> <cluster-name>

Options:
    --backup        Perform backup operation for tenant
    --restore       Perform restore operation for tenant
    --help          Show this help message

Examples:
    $0 --backup my-tenant prod-cluster
    $0 --restore my-tenant prod-cluster
EOF
    exit 0
}

# -------------------------
# Common pre-check functions
# -------------------------
check_velero_cli() {
    info "Checking Velero CLI..."
    command -v velero >/dev/null 2>&1 || fail "Velero CLI not found"
    info "Velero CLI installed"
}

check_velero_installed() {
    info "Checking if Velero is installed in cluster..."
    helm list -n $velero_namespace 2>/dev/null | grep -q velero || fail "Velero not installed in cluster"
    info "Velero installed"
}

check_velero_pod_running() {
    info "Checking if Velero pod is running..."
    kubectl get pods -n $velero_namespace 2>/dev/null | grep -q velero || fail "Velero pod not running"
    info "Velero pod running"
}

check_tenant_exists() {
    info "Checking if tenant '$tenant_name' exists..."
    kubectl get tenant "$tenant_name" >/dev/null 2>&1 || fail "Tenant '$tenant_name' not found"
    info "Tenant '$tenant_name' exists."
}

# -------------------------
# Backup-specific functions
# -------------------------
check_backup_storage_location() {
    info "Checking BackupStorageLocation..."
    local phase status access
    phase=$(kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    access=$(kubectl get backupstoragelocation -n $velero_namespace -o jsonpath='{.items[0].spec.accessMode}' 2>/dev/null)
    
    [[ "$phase" == "Available" ]] || fail "BackupStorageLocation not in 'Available' state."
    [[ "$access" == "ReadWrite" ]] || fail "BackupStorageLocation accessMode not 'ReadWrite'."
    info "BackupStorageLocation is ready."
}

backup_tenant_resource() {
    local backup_name="${tenant_name}-${cluster_name}-tenant"
    info "Backing up tenant resource: $backup_name"

    velero backup create "$backup_name" \
        --include-cluster-resources=true \
        --include-resources=tenants.capsule.clastix.io \
        --selector "capsule.clastix.io/tenant=$tenant_name" \
        -n $velero_namespace || fail "Tenant resource backup failed!"
    
    info "Tenant resource backup completed: $backup_name"
}

backup_tenant_namespaces() {
    local backup_name="${tenant_name}-${cluster_name}-ns"
    info "Backing up tenant namespaces: $backup_name"

    # Get namespaces as comma-separated list
    local ns_list
    ns_list=$(kubectl get ns -l capsule.clastix.io/tenant=$tenant_name -o jsonpath='{range .items[*]}{.metadata.name},{end}')
    ns_list=${ns_list%,}  # Remove trailing comma

    [[ -z "$ns_list" ]] && fail "No namespaces found for tenant $tenant_name"

    velero backup create "$backup_name" \
        --include-namespaces "$ns_list" \
        -n $velero_namespace || fail "Tenant namespaces backup failed!"

    info "Tenant namespaces backup completed: $backup_name"
}

backup_tenant_storageclasses() {
    local backup_name="${tenant_name}-${cluster_name}-sc"
    info "Backing up tenant StorageClasses: $backup_name"

    # Get allowedRegex
    local regex
    regex=$(kubectl get tenant "$tenant_name" -o jsonpath='{.spec.storageClasses.allowedRegex}' | tr -d '"')
    [[ -n "$regex" ]] || fail "Tenant has empty allowedRegex"

    info "allowedRegex: $regex"

    # Find matching SCs
    local all_scs matched_scs
    all_scs=$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    matched_scs=()
    while IFS= read -r sc; do
        [[ "$sc" =~ $regex ]] && matched_scs+=("$sc")
    done <<< "$all_scs"

    [[ ${#matched_scs[@]} -gt 0 ]] || fail "No StorageClasses match allowedRegex for tenant"

    info "Matched SCs: ${matched_scs[*]}"

    # Label matched SCs
    for sc in "${matched_scs[@]}"; do
        kubectl label sc "$sc" tenant="$tenant_name" --overwrite 2>/dev/null
        info "Labeled SC: $sc"
    done

    # Velero backup
    velero backup create "$backup_name" \
        --selector tenant="$tenant_name" \
        --include-cluster-resources=true \
        --include-resources=storageclasses.storage.k8s.io \
        -n $velero_namespace || fail "StorageClass backup failed!"

    info "Tenant StorageClass backup completed: $backup_name"
}

# -------------------------
# Restore-specific functions
# -------------------------
restore_tenant_resource() {
    local backup_name="${tenant_name}-${cluster_name}-tenant"
    info "Restoring tenant resource from backup: $backup_name"

    velero restore create --from-backup "$backup_name" --wait || fail "Tenant resource restore failed!"
    info "Tenant resource restore completed"
}

wait_for_namespaces() {
    info "Waiting for tenant namespaces to be ready..."
    local timeout=30
    local interval=5
    local elapsed=0
    local ns_list
    ns_list=$(kubectl get ns -l "$LABEL_KEY=$tenant_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    while [[ -z "$ns_list" && $elapsed -lt $timeout ]]; do
        sleep $interval
        elapsed=$((elapsed + interval))
        ns_list=$(kubectl get ns -l "$LABEL_KEY=$tenant_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    done

    [[ -n "$ns_list" ]] || fail "Timeout waiting for tenant namespaces to be restored"
    info "Namespaces restored: $ns_list"
}

restore_tenant_namespaces() {
    local backup_name="${tenant_name}-${cluster_name}-ns"
    info "Restoring tenant namespaces from backup: $backup_name"

    velero restore create --from-backup "$backup_name" --wait || fail "Tenant namespaces restore failed!"
    info "Tenant namespaces restore initiated"

    wait_for_namespaces
    patch_tenant_namespaces
}

restore_tenant_storageclasses() {
    local sc_backup_name="${tenant_name}-${cluster_name}-sc"
    info "Restoring tenant StorageClasses from backup: $sc_backup_name"

    if ! velero get backup -n $velero_namespace 2>/dev/null | grep -q "$sc_backup_name"; then
        warn "No StorageClass backup found for tenant $tenant_name. Skipping SC restore."
        return
    fi

    velero restore create --from-backup "$sc_backup_name" \
        --selector tenant="$tenant_name" \
        --include-resources storageclasses.storage.k8s.io \
        -n $velero_namespace --wait || fail "SC restore failed!"

    info "Tenant StorageClass restore completed"
}

patch_tenant_namespaces() {
    info "Patching namespaces for tenant '$tenant_name'..."

    local namespaces
    namespaces=$(kubectl get ns -l "$LABEL_KEY=$tenant_name" -o jsonpath='{.items[*].metadata.name}')
    [[ -n "$namespaces" ]] || { warn "No namespaces found for tenant. Skipping patch."; return; }
    info "Namespaces to patch: $namespaces"

    local tenant_uid tenant_api_version
    tenant_uid=$(kubectl get tenant "$tenant_name" -o jsonpath='{.metadata.uid}')
    tenant_api_version=$(kubectl get tenant "$tenant_name" -o jsonpath='{.apiVersion}')
    info "Tenant UID: $tenant_uid, API Version: $tenant_api_version"

    for ns in $namespaces; do
        info "Processing namespace: $ns"

        local owner
        owner=$(kubectl get ns "$ns" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)

        if [[ "$owner" == "$tenant_name" ]]; then
            info "Namespace '$ns' already linked. Skipping."
            continue
        fi

        info "Patching ownerReference for namespace '$ns'..."
        kubectl patch ns "$ns" --type=json -p "
        [
            {
                \"op\": \"add\",
                \"path\": \"/metadata/ownerReferences\",
                \"value\": [
                    {
                        \"apiVersion\": \"$tenant_api_version\",
                        \"kind\": \"Tenant\",
                        \"name\": \"$tenant_name\",
                        \"uid\": \"$tenant_uid\"
                    }
                ]
            }
        ]
        " 2>/dev/null || warn "Failed to patch namespace '$ns'"
        info "Namespace '$ns' patched successfully."
    done
}

# -------------------------
# Main execution
# -------------------------
main() {
    # Parse arguments
    if [[ $# -lt 3 ]]; then
        if [[ "$1" == "--help" ]]; then
            show_help
        else
            fail "Insufficient arguments. Use --help for usage information."
        fi
    fi

    mode="$1"
    tenant_name="$2"
    cluster_name="$3"

    # Validate mode
    case "$mode" in
        --backup)
            info "Starting BACKUP operation for tenant '$tenant_name' in cluster '$cluster_name'"
            
            # Common pre-checks
            check_velero_cli
            check_velero_installed
            check_velero_pod_running
            check_backup_storage_location
            check_tenant_exists
            
            # Backup operations
            backup_tenant_resource
            backup_tenant_namespaces
            backup_tenant_storageclasses
            
            info "All backups completed successfully for tenant '$tenant_name' in cluster '$cluster_name'"
            ;;
            
        --restore)
            info "Starting RESTORE operation for tenant '$tenant_name' in cluster '$cluster_name'"
            
            # Common pre-checks
            check_velero_cli
            check_velero_installed
            check_velero_pod_running
            check_tenant_exists
            
            # Restore operations
            restore_tenant_resource
            wait_for_namespaces
            restore_tenant_namespaces
            restore_tenant_storageclasses
            
            info "All restore steps completed successfully for tenant '$tenant_name' in cluster '$cluster_name'"
            ;;
            
        *)
            fail "Invalid option: $mode. Use --backup, --restore, or --help"
            ;;
    esac
}

# Run main function with all arguments
main "$@"
