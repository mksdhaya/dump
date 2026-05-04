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

####################################################
echo "=== STEP 2: VERIFY SERVICES STOPPED ==="
####################################################
if systemctl is-active --quiet kubelet || systemctl is-active --quiet containerd; then
  echo "ERROR: Services still running. Aborting."
  exit 1
fi
echo "Services stopped successfully"

####################################################
echo "=== STEP 3: CHECK FILESYSTEM USAGE ==="
####################################################
for dir in $RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT; do
  echo "Checking $dir"

  if lsof +D $dir 2>/dev/null | grep -q .; then
    echo "ERROR: Files in use under $dir"
    lsof +D $dir | head
    exit 1
  fi

  if fuser -vm $dir 2>/dev/null | grep -q .; then
    echo "ERROR: Filesystem busy at $dir"
    fuser -vm $dir
    exit 1
  fi
done

echo "No active usage detected"

####################################################
echo "=== STEP 4: CREATE NEW STORAGE ==="
####################################################
pvcreate $NEW_DISK
vgcreate $NEW_VG $NEW_DISK

lvcreate -L 200G -n runtimelv $NEW_VG
lvcreate -L 100G -n loglv $NEW_VG
lvcreate -L 50G  -n backuplv $NEW_VG
lvcreate -L 100G -n openebslv $NEW_VG

####################################################
echo "=== STEP 5: FORMAT FILESYSTEMS ==="
####################################################
mkfs.xfs /dev/$NEW_VG/runtimelv
mkfs.xfs /dev/$NEW_VG/loglv
mkfs.xfs /dev/$NEW_VG/backuplv
mkfs.xfs /dev/$NEW_VG/openebslv

####################################################
echo "=== STEP 6: MOUNT TEMP LOCATIONS ==="
####################################################
mount /dev/$NEW_VG/runtimelv $TMP_BASE/runtime
mount /dev/$NEW_VG/loglv $TMP_BASE/log
mount /dev/$NEW_VG/backuplv $TMP_BASE/backup
mount /dev/$NEW_VG/openebslv $TMP_BASE/openebs

####################################################
echo "=== STEP 7: RSYNC DATA ==="
####################################################
rsync -aHAXx --numeric-ids $RUNTIME_MNT/ $TMP_BASE/runtime/
rsync -aHAXx --numeric-ids $LOG_MNT/ $TMP_BASE/log/
rsync -aHAXx --numeric-ids $BACKUP_MNT/ $TMP_BASE/backup/
rsync -aHAXx --numeric-ids $OPENEBS_MNT/ $TMP_BASE/openebs/

####################################################
echo "=== STEP 8: BACKUP FSTAB ==="
####################################################
cp /etc/fstab /etc/fstab.bak.$(date +%F-%H%M)

####################################################
echo "=== STEP 9: UPDATE FSTAB ==="
####################################################
sed -i 's|datavg-runtimelv|newdatavg-runtimelv|g' /etc/fstab
sed -i 's|datavg-loglv|newdatavg-loglv|g' /etc/fstab
sed -i 's|datavg-backuplv|newdatavg-backuplv|g' /etc/fstab
sed -i 's|datavg-openebslv|newdatavg-openebslv|g' /etc/fstab

####################################################
echo "=== STEP 10: SWITCH MOUNTS ==="
####################################################
umount $RUNTIME_MNT || true
umount $LOG_MNT || true
umount $BACKUP_MNT || true
umount $OPENEBS_MNT || true

echo "-- Running mount -a --"
if ! mount -a; then
  echo "ERROR: mount -a failed"
  exit 1
fi

####################################################
echo "=== VALIDATE MOUNTS ==="
####################################################
for mp in $RUNTIME_MNT $LOG_MNT $BACKUP_MNT $OPENEBS_MNT; do
  if ! findmnt -n $mp | grep -q $NEW_VG; then
    echo "ERROR: $mp not mounted correctly"
    findmnt $mp
    exit 1
  fi
done

echo "Mount validation successful"

####################################################
echo "=== STEP 11: START SERVICES ==="
####################################################
systemctl start containerd
systemctl start kubelet

####################################################
echo "=== STEP 12: POST-START VALIDATION ==="
####################################################
sleep 10

echo "-- Service check --"
systemctl is-active --quiet containerd || { echo "containerd failed"; exit 1; }
systemctl is-active --quiet kubelet || { echo "kubelet failed"; exit 1; }

echo "-- Disk check (df -h) --"
df -h | grep $NEW_VG || {
  echo "ERROR: New VG not found in df output"
  df -h
  exit 1
}

echo "-- Runtime check --"
crictl ps >/dev/null 2>&1 || {
  echo "ERROR: container runtime not responding"
  exit 1
}

echo "-- Log check --"
journalctl -u kubelet -n 20 --no-pager | grep -iE "error|fail|fatal" && echo "WARNING: kubelet logs issues"
journalctl -u containerd -n 20 --no-pager | grep -iE "error|fail|fatal" && echo "WARNING: containerd logs issues"

####################################################
echo "================================================"
echo " MIGRATION COMPLETED SUCCESSFULLY"
echo "================================================"
echo "Next steps:"
echo "- Validate node from Kubernetes control plane"
echo "- Uncordon node manually"
echo "- Monitor workloads before proceeding to next node"
echo "================================================"
