#!/bin/bash
# Pull: Mac drive -> local working copy.
# Newer wins, nothing is ever deleted, overwrites are archived.
set +e
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_mounted || exit 1
mkdir -p "$LOCAL_WSL" || exit 3
BK="$ARCHIVE_WSL/down-$(date +%Y%m%d-%H%M%S)"

echo "source : $MOUNTPOINT"
echo "target : $LOCAL_WSL"
echo "mode   : newer-wins, no deletions, overwrites archived"

rsync -au --info=stats2 --backup --backup-dir="$BK" \
  "${MAC_EXCLUDES[@]}" "$MOUNTPOINT"/ "$LOCAL_WSL"/
RC=$?
echo "rsync rc=$RC"

if [ -d "$BK" ]; then
  echo "archived overwrites: $(find "$BK" -type f | wc -l) file(s) in $BK"
else
  echo "archived overwrites: none"
fi
echo "local size: $(du -sh "$LOCAL_WSL" 2>/dev/null | cut -f1)"
exit $RC
