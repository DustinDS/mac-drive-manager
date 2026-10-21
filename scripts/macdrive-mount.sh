#!/bin/bash
# Mount the Mac HFS+ drive read-write inside WSL.
#
# NOTE: journaled HFS+ needs -o force because Linux does not maintain Apple's
# journal. Always unmount cleanly (macdrive-umount.sh) before unplugging.
set +e
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

modprobe hfsplus || { echo "ERROR: hfsplus module failed to load. Run install/02-build-hfsplus-module.sh"; exit 1; }

DEV=$(lsblk -pnlo NAME,FSTYPE | awk '$2=="hfsplus"{print $1; exit}')
if [ -z "$DEV" ]; then
  echo "ERROR: no HFS+ partition found. Is the drive attached with 'usbipd attach'?"
  exit 2
fi
echo "device: $DEV"

mkdir -p "$MOUNTPOINT"
if mountpoint -q "$MOUNTPOINT"; then
  echo "already mounted:"
else
  mount -t hfsplus -o rw,force,uid=1000,gid=1000,umask=022,nls=utf8 "$DEV" "$MOUNTPOINT" \
    || { echo "ERROR: mount failed"; exit 3; }
  echo "mounted read-write."
fi
mount | grep "$MOUNTPOINT"
df -h "$MOUNTPOINT" | tail -1
