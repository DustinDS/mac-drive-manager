#!/bin/bash
# Report how many files differ in each direction, without transferring anything.
set +e
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

[ -d "$LOCAL_WSL" ] || { echo "NOLOCAL"; exit 0; }
mountpoint -q "$MOUNTPOINT" || { echo "NODRIVE"; exit 0; }

UP=$(rsync -aun --out-format='%n' "${MAC_EXCLUDES[@]}" \
      "$LOCAL_WSL"/ "$MOUNTPOINT"/ 2>/dev/null | grep -vc '/$')
DOWN=$(rsync -aun --out-format='%n' "${MAC_EXCLUDES[@]}" \
      "$MOUNTPOINT"/ "$LOCAL_WSL"/ 2>/dev/null | grep -vc '/$')

echo "PENDING_UP=$UP"
echo "PENDING_DOWN=$DOWN"
