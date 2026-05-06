#!/bin/bash
set -euo pipefail

echo "================================================"
echo " K8s Worker Node Disk Migration (FINAL v2)"
echo "================================================"

### VARIABLES ###
OLD_VG="datavg"
NEW_DISK="/dev/sdc"
NEW_VG="newdatavg"

RUNTIME_MNT="/var/lib/containerd"
LOG_MNT="/var/log/data"
BACKUP_MNT="/opt/data/backup"
OPENEBS_MNT="/var/openebs/local"

TMP_BASE="/mnt/newdisk"

mkdir -p $TMP_BASE/{runtime,log,backup,openebs}

####################################################
echo "=== STEP 1: STOP SERVICES ==="
####################################################
systemctl stop kubelet
systemctl stop containerd
sleep 5

systemctl is-active --quiet kubelet && exit 1
systemctl is-active --quiet containerd && exit 1

####################################################
echo "=== STEP 2: CHECK ACTIVE USAGE ==="
####################################################
for d in $RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT; do
  lsof +D $d 2>/dev/null | grep -q . && { echo "IN USE: $d"; exit 1; }
done

####################################################
echo "=== STEP 3: CREATE NEW DISK ==="
####################################################
pvcreate $NEW_DISK
vgcreate $NEW_VG $NEW_DISK

lvcreate -L 200G -n runtimelv $NEW_VG
lvcreate -L 100G -n loglv $NEW_VG
lvcreate -L 50G  -n backuplv $NEW_VG
lvcreate -L 100G -n openebslv $NEW_VG

mkfs.xfs /dev/$NEW_VG/runtimelv
mkfs.xfs /dev/$NEW_VG/loglv
mkfs.xfs /dev/$NEW_VG/backuplv
mkfs.xfs /dev/$NEW_VG/openebslv

####################################################
echo "=== STEP 4: MOUNT TEMP NEW DISK ==="
####################################################
mount /dev/$NEW_VG/runtimelv $TMP_BASE/runtime
mount /dev/$NEW_VG/loglv $TMP_BASE/log
mount /dev/$NEW_VG/backuplv $TMP_BASE/backup
mount /dev/$NEW_VG/openebslv $TMP_BASE/openebs

for m in runtime log backup openebs; do
  mountpoint -q $TMP_BASE/$m || exit 1
  touch $TMP_BASE/$m/test && rm -f $TMP_BASE/$m/test
done

####################################################
echo "=== STEP 5: RSYNC DATA ==="
####################################################
rsync -aHAXx --numeric-ids $RUNTIME_MNT/ $TMP_BASE/runtime/
rsync -aHAXx --numeric-ids $LOG_MNT/ $TMP_BASE/log/
rsync -aHAXx --numeric-ids $BACKUP_MNT/ $TMP_BASE/backup/
rsync -aHAXx --numeric-ids $OPENEBS_MNT/ $TMP_BASE/openebs/

########################################
echo "=== STEP 6: VALIDATE FILESYSTEM USAGE (GB) ==="
########################################

compare_fs_usage_gb() {
  local src=$1
  local dst=$2
  local name=$3

  # Convert KB → GB (rounded)
  src_used=$(df -k "$src" | awk 'NR==2 {print int($3/1024/1024)}')
  dst_used=$(df -k "$dst" | awk 'NR==2 {print int($3/1024/1024)}')

  echo "$name:"
  echo "  Source : ${src_used} GB"
  echo "  Target : ${dst_used} GB"

  # Allow 5% tolerance
  upper_limit=$(( src_used + (src_used * 5 / 100) ))
  lower_limit=$(( src_used - (src_used * 5 / 100) ))

  if [ "$dst_used" -gt "$upper_limit" ] || [ "$dst_used" -lt "$lower_limit" ]; then
    echo "ERROR: FS size mismatch detected for $name"
    exit 1
  fi

  echo "OK: $name FS usage within acceptable range"
}

compare_fs_usage_gb $RUNTIME_MNT $TMP_BASE/runtime "containerd"
compare_fs_usage_gb $LOG_MNT $TMP_BASE/log "logs"
compare_fs_usage_gb $BACKUP_MNT $TMP_BASE/backup "backup"
compare_fs_usage_gb $OPENEBS_MNT $TMP_BASE/openebs "openebs"

echo "=== FS VALIDATION (GB) PASSED ==="

####################################################
echo "=== STEP 7: UNMOUNT OLD VG ==="
####################################################
get_old_mounts() {
  findmnt -rn -o TARGET,SOURCE | grep "$OLD_VG" | awk '{print $1}' | sort -r
}

for i in {1..10}; do
  mapfile -t mnts < <(get_old_mounts)

  [ ${#mnts[@]} -eq 0 ] && break

  for m in "${mnts[@]}"; do
    mountpoint -q $m && umount $m 2>/dev/null || umount -l $m || true
  done
  sleep 2
done

####################################################
echo "=== STEP 7B: UNMOUNT TEMP NEW VG (FIXED) ==="
####################################################
TMP_MOUNTS=(
  "$TMP_BASE/runtime"
  "$TMP_BASE/log"
  "$TMP_BASE/backup"
  "$TMP_BASE/openebs"
)

for m in "${TMP_MOUNTS[@]}"; do
  mountpoint -q $m && umount $m 2>/dev/null || umount -l $m || true
done

for m in "${TMP_MOUNTS[@]}"; do
  mountpoint -q $m && exit 1
done

####################################################
echo "=== STEP 8: UPDATE FSTAB ==="
####################################################
cp /etc/fstab /etc/fstab.bak.$(date +%F-%H%M)
sed -i "s/$OLD_VG/$NEW_VG/g" /etc/fstab

####################################################
echo "=== STEP 9: SWITCH MOUNTS ==="
####################################################
mount -a

for p in $RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT; do
  findmnt $p | grep -q $NEW_VG || exit 1
done

####################################################
echo "=== STEP 10: START SERVICES ==="
####################################################
systemctl start containerd
systemctl start kubelet
sleep 10

systemctl is-active --quiet kubelet || exit 1
systemctl is-active --quiet containerd || exit 1

df -h | grep $NEW_VG || exit 1
crictl ps >/dev/null 2>&1 || exit 1

echo "================================================"
echo " MIGRATION SUCCESSFUL"
echo "================================================"
