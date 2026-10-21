#!/bin/bash
# Push: local working copy -> Mac drive.
# Newer wins, nothing is ever deleted, overwrites are archived.
set +e
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_mounted || exit 1
[ -d "$LOCAL_WSL" ] || { echo "NOTHING TO SYNC: no local working copy yet."; exit 0; }
BK="$ARCHIVE_WSL/up-$(date +%Y%m%d-%H%M%S)"

echo "source : $LOCAL_WSL"
echo "target : $MOUNTPOINT"
echo "mode   : newer-wins, no deletions, overwrites archived"

rsync -au --info=stats2 --backup --backup-dir="$BK" \
  "${MAC_EXCLUDES[@]}" "$LOCAL_WSL"/ "$MOUNTPOINT"/
RC=$?
echo "rsync rc=$RC"
sync

if [ -d "$BK" ]; then
  echo "archived overwrites: $(find "$BK" -type f | wc -l) file(s) in $BK"
else
  echo "archived overwrites: none"
fi
exit $RC
