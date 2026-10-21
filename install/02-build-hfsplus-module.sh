#!/bin/bash
# ---------------------------------------------------------------------------
# Build the hfsplus kernel module for the running WSL2 kernel.
#
# WHY THIS IS NEEDED
#   Microsoft's stock WSL2 kernel ships with CONFIG_HFSPLUS_FS unset, so there
#   is no HFS+ driver and no module to load. The Kconfig symbol still exists,
#   so the source is present and can be built.
#
# WHY A FULL KERNEL BUILD
#   The stock kernel sets CONFIG_MODVERSIONS=y, so the module's symbol CRCs
#   must match. Those CRCs come from Module.symvers, which is only produced by
#   a complete build. A modules_prepare-only build yields a module that fails
#   to load with "disagrees about version of symbol module_layout".
#
#   Rebuilding also produces CRCs that differ from Microsoft's prebuilt binary
#   (different compiler), so the module will NOT load into the stock kernel.
#   That is why this script installs the kernel it builds and points WSL at it
#   via .wslconfig: kernel and modules then match by construction, and nothing
#   has to be force-loaded.
#
# GOTCHA THIS SCRIPT AVOIDS
#   scripts/setlocalversion appends "+" to the version string when it detects a
#   git checkout, producing "...-WSL2+" instead of "...-WSL2". The kernel then
#   looks for modules in a directory that does not exist. We delete .git before
#   building so the version strings match.
#
# Run as root inside WSL:  sudo bash install/02-build-hfsplus-module.sh
# ---------------------------------------------------------------------------
set -e

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run this as root (sudo)."; exit 1; }

KVER="$(uname -r)"                      # e.g. 6.18.54.1-microsoft-standard-WSL2
KBASE="${KVER%%-microsoft*}"            # e.g. 6.18.54.1
TAG="linux-msft-wsl-${KBASE}"
SRC=/usr/src/wsl-kernel
OUT_WIN="${1:-/mnt/c/Users/Public/wsl-kernel}"

echo "running kernel : $KVER"
echo "source tag     : $TAG"
echo "kernel output  : $OUT_WIN"
echo

if zcat /proc/config.gz | grep -q '^CONFIG_HFSPLUS_FS=m'; then
  echo "This kernel already has hfsplus. Nothing to do."
  exit 0
fi

echo "==> installing build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential flex bison libssl-dev libelf-dev \
                      bc dwarves cpio rsync kmod git python3

echo "==> fetching kernel source ($TAG)"
rm -rf "$SRC"
mkdir -p "$(dirname "$SRC")"
git clone --depth 1 --branch "$TAG" \
  https://github.com/microsoft/WSL2-Linux-Kernel.git "$SRC"

cd "$SRC"

# Critical: remove SCM metadata so setlocalversion cannot append "+".
rm -rf .git .scmversion

echo "==> configuring"
zcat /proc/config.gz > .config
scripts/config --disable LOCALVERSION_AUTO
scripts/config --module HFSPLUS_FS
scripts/config --module HFS_FS
make olddefconfig
grep -E '^CONFIG_HFS(PLUS)?_FS' .config

echo "==> backing up the stock module tree"
tar -czf "/root/stock-modules-${KVER}.tar.gz" -C /lib/modules "$KVER" 2>/dev/null \
  && echo "    saved /root/stock-modules-${KVER}.tar.gz"

echo "==> building kernel + modules (this takes a while)"
make -j"$(nproc)"
make -j"$(nproc)" modules

echo "==> verifying version strings match"
BUILT="$(cat include/generated/utsrelease.h | sed 's/.*"\(.*\)".*/\1/')"
echo "    built : $BUILT"
echo "    stock : $KVER"
[ "$BUILT" = "$KVER" ] || { echo "ERROR: version mismatch - modules would not load"; exit 2; }

echo "==> installing modules"
make INSTALL_MOD_STRIP=1 modules_install

echo "==> exporting kernel image to Windows"
mkdir -p "$OUT_WIN"
# The running kernel image is locked by the VM, so write a distinct filename.
cp arch/x86/boot/bzImage "$OUT_WIN/bzImage-hfsplus"
ls -la "$OUT_WIN"

WINPATH="$(echo "$OUT_WIN" | sed 's#^/mnt/\([a-z]\)#\U\1:#; s#/#\\\\#g')"

cat <<EOF

=============================================================
BUILD COMPLETE

Add this to your Windows user profile at  C:\\Users\\<you>\\.wslconfig
(note the DOUBLED backslashes - that is the documented format):

    [wsl2]
    kernel=${WINPATH}\\\\bzImage-hfsplus

Then from Windows:

    wsl --shutdown

Start WSL again and confirm:

    uname -r          # should print ${KVER}
    modprobe hfsplus  # should succeed silently
=============================================================
EOF
