#!/bin/bash

set -euo pipefail

echo "================================================"
echo " K8s Worker Node Disk Migration Started"
echo "================================================"

### VARIABLES ###
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

systemctl is-active --quiet kubelet && { echo "kubelet still running"; exit 1; }
systemctl is-active --quiet containerd && { echo "containerd still running"; exit 1; }

####################################################
echo "=== STEP 2: CHECK FILESYSTEM USAGE ==="
####################################################
for dir in $RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT; do
  lsof +D $dir 2>/dev/null | grep -q . && { echo "ERROR: in use $dir"; exit 1; }
done

####################################################
echo "=== STEP 3: CREATE NEW STORAGE ==="
####################################################
pvcreate $NEW_DISK
vgcreate $NEW_VG $NEW_DISK

lvcreate -L 200G -n runtimelv $NEW_VG
lvcreate -L 100G -n loglv $NEW_VG
lvcreate -L 50G  -n backuplv $NEW_VG
lvcreate -L 100G -n openebslv $NEW_VG

####################################################
echo "=== STEP 4: FORMAT ==="
####################################################
mkfs.xfs /dev/$NEW_VG/runtimelv
mkfs.xfs /dev/$NEW_VG/loglv
mkfs.xfs /dev/$NEW_VG/backuplv
mkfs.xfs /dev/$NEW_VG/openebslv

####################################################
echo "=== STEP 5: MOUNT TEMP ==="
####################################################
mount /dev/$NEW_VG/runtimelv $TMP_BASE/runtime
mount /dev/$NEW_VG/loglv $TMP_BASE/log
mount /dev/$NEW_VG/backuplv $TMP_BASE/backup
mount /dev/$NEW_VG/openebslv $TMP_BASE/openebs

####################################################
echo "=== VALIDATE TEMP MOUNTS ==="
####################################################
for m in runtime log backup openebs; do
  mountpoint -q $TMP_BASE/$m || { echo "Mount failed $m"; exit 1; }
  findmnt $TMP_BASE/$m | grep -q $NEW_VG || { echo "Wrong VG for $m"; exit 1; }
  touch $TMP_BASE/$m/testfile && rm -f $TMP_BASE/$m/testfile
done

####################################################
echo "=== STEP 6: RSYNC DATA ==="
####################################################
rsync -aHAXx --numeric-ids $RUNTIME_MNT/ $TMP_BASE/runtime/
rsync -aHAXx --numeric-ids $LOG_MNT/ $TMP_BASE/log/
rsync -aHAXx --numeric-ids $BACKUP_MNT/ $TMP_BASE/backup/
rsync -aHAXx --numeric-ids $OPENEBS_MNT/ $TMP_BASE/openebs/

####################################################
echo "=== VALIDATE RSYNC SIZE ==="
####################################################
compare() {
  s=$(df -k $1 | awk 'NR==2{print $3}')
  d=$(df -k $2 | awk 'NR==2{print $3}')
  diff=$(( s>d?s-d:d-s ))
  pct=$(( diff*100/s ))
  echo "$1 vs $2 diff=${pct}%"
  [ $pct -gt 5 ] && { echo "Mismatch >5%"; exit 1; }
}
compare $RUNTIME_MNT $TMP_BASE/runtime
compare $LOG_MNT $TMP_BASE/log
compare $BACKUP_MNT $TMP_BASE/backup
compare $OPENEBS_MNT $TMP_BASE/openebs

####################################################
echo "=== PRE-SWITCH UNMOUNT LOOP ==="
####################################################
TARGETS=($RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT)

for i in {1..10}; do
  all_clean=true
  echo "Iteration $i"

  for p in "${TARGETS[@]}"; do
    mapfile -t mnts < <(findmnt -R $p -o TARGET -n | sort -r)

    if [ ${#mnts[@]} -gt 0 ]; then
      all_clean=false
      for m in "${mnts[@]}"; do
        mountpoint -q $m && umount $m 2>/dev/null || umount -l $m || true
      done
    fi
  done

  $all_clean && break
  sleep 2
done

####################################################
echo "=== FINAL UNMOUNT VALIDATION ==="
####################################################
for p in "${TARGETS[@]}"; do
  findmnt -R $p | grep -q . && { echo "Still mounted $p"; exit 1; }
done

####################################################
echo "=== STEP 7: UPDATE FSTAB ==="
####################################################
cp /etc/fstab /etc/fstab.bak.$(date +%F-%H%M)
sed -i 's/datavg/newdatavg/g' /etc/fstab

####################################################
echo "=== STEP 8: SWITCH MOUNTS ==="
####################################################
mount -a

####################################################
echo "=== VALIDATE NEW MOUNTS ==="
####################################################
for p in $RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT; do
  findmnt $p | grep -q $NEW_VG || { echo "Mount switch failed $p"; exit 1; }
done

####################################################
echo "=== STEP 9: START SERVICES ==="
####################################################
systemctl start containerd
systemctl start kubelet
sleep 10

####################################################
echo "=== FINAL VALIDATION ==="
####################################################
systemctl is-active --quiet kubelet || exit 1
systemctl is-active --quiet containerd || exit 1

df -h | grep $NEW_VG || exit 1

crictl ps >/dev/null 2>&1 || exit 1

echo "================================================"
echo " MIGRATION COMPLETED SUCCESSFULLY"
echo "================================================"
