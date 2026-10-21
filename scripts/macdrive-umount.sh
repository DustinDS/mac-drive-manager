#!/bin/bash
# Flush and unmount the Mac HFS+ drive. ALWAYS run before unplugging:
# this is what sets the volume's "cleanly unmounted" flag that macOS checks.
set +e
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

sync
if mountpoint -q "$MOUNTPOINT"; then
  umount "$MOUNTPOINT" && echo "unmounted cleanly." || { echo "ERROR: umount failed (file still open?)"; exit 1; }
else
  echo "not mounted."
fi
