#!/usr/bin/env bash
# Build (and optionally install) a patched mt7921e + mt7921-common for PS5 Linux.
#
# The patch disables runtime power management and deep sleep in mt7921/init.c.
# With them enabled, the MT7921 low-power transition takes down the PS5's
# Salina southbridge (USB + Ethernet + Wi-Fi) and the console powers off.
#
# Usage:
#   ./build-mt7921e.sh            build only, nothing installed
#   ./build-mt7921e.sh --install  build, then install to /lib/modules/<kver>/updates

set -euo pipefail

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

KVER=$(uname -r)
KMAJ=${KVER%%.*}
CFG=/boot/config-$KVER
KBUILD=/lib/modules/$KVER/build
WORK=${WORK:-$HOME/mt7921e}
BASE_URL="https://cdn.kernel.org/pub/linux/kernel/v${KMAJ}.x"
TARBALL="linux-$KVER.tar.xz"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> Kernel: $KVER"

# --- Sanity checks -----------------------------------------------------------
lspci -nn -d 14c3:7961 | grep -q . \
  || die "No MT7921 [14c3:7961] found. This script is only for MediaTek-equipped consoles."
[[ -f $CFG ]] || die "$CFG not found."
[[ -f $KBUILD/Module.symvers ]] || die "Kernel headers/build tree missing at $KBUILD."
grep -q '^CONFIG_MT7921_COMMON=m' "$CFG" || die "CONFIG_MT7921_COMMON is not =m in this kernel."
grep -q '^CONFIG_MT792x_LIB=m'    "$CFG" || die "CONFIG_MT792x_LIB is not =m in this kernel."

# --- Compiler matching the kernel's -------------------------------------------
GCCMAJ=$(sed -nE 's/^CONFIG_CC_VERSION_TEXT=".*gcc.* ([0-9]+)\.[0-9]+\.[0-9]+"$/\1/p' "$CFG")
[[ -n $GCCMAJ ]] || die "Could not detect the kernel's GCC version from $CFG."
CC=gcc-$GCCMAJ
echo "==> Kernel was built with GCC $GCCMAJ, using $CC"

sudo apt-get update
sudo apt-get install -y build-essential "$CC" wget xz-utils

# --- Source -------------------------------------------------------------------
mkdir -p "$WORK" && cd "$WORK"
wget -q -O sha256sums.asc "$BASE_URL/sha256sums.asc"

verify() { grep " $TARBALL\$" sha256sums.asc | sha256sum -c - >/dev/null 2>&1; }

if [[ -f $TARBALL ]] && verify; then
  echo "==> Using existing $TARBALL (checksum OK)"
else
  echo "==> Downloading $TARBALL"
  rm -f "$TARBALL"
  wget "$BASE_URL/$TARBALL"
  verify || die "Checksum mismatch on $TARBALL. Delete it and try again."
fi

rm -rf mt76 "linux-$KVER"
tar xf "$TARBALL" "linux-$KVER/drivers/net/wireless/mediatek/mt76"
cp -r "linux-$KVER/drivers/net/wireless/mediatek/mt76" .
cd mt76/mt7921

# --- Patch: disable runtime PM and deep sleep ---------------------------------
sed -i -E 's/(pm\.(enable|enable_user|ds_enable|ds_enable_user)[[:space:]]*=[[:space:]]*)true/\1false/' init.c
COUNT=$(grep -cE 'pm\.(enable|enable_user|ds_enable|ds_enable_user)[[:space:]]*=[[:space:]]*false' init.c || true)
[[ $COUNT -eq 4 ]] || die "Expected 4 PM defaults set to false in init.c, found $COUNT. The source layout may have changed."
echo "==> init.c patched:"
grep -nE 'pm\.(enable|enable_user|ds_enable|ds_enable_user)' init.c

# --- Build --------------------------------------------------------------------
make -C "$KBUILD" M="$PWD" CC="$CC" CONFIG_MT7921E=m CONFIG_MT7921_COMMON=m modules
modinfo ./mt7921e.ko | grep -E 'vermagic|depends'
MODDIR=$PWD

if [[ $INSTALL -eq 0 ]]; then
  cat <<EOF

==> Build done. Nothing installed.

Test by hand first:
  sync
  sudo rmmod mt7921e mt7921-common 2>/dev/null
  sudo modprobe -a mt76 mt76-connac-lib mt792x-lib
  sudo insmod $MODDIR/mt7921-common.ko
  sudo insmod $MODDIR/mt7921e.ko disable_aspm=1

When it's been stable in use, run: $0 --install
EOF
  exit 0
fi

# --- Install ------------------------------------------------------------------
echo "==> Installing to /lib/modules/$KVER/updates"
sudo mkdir -p "/lib/modules/$KVER/updates"
sudo cp mt7921-common.ko mt7921e.ko "/lib/modules/$KVER/updates/"
echo "options mt7921e disable_aspm=1" | sudo tee /etc/modprobe.d/mt7921e.conf >/dev/null
sudo rm -f /etc/modprobe.d/mt7921e-blacklist.conf
sudo depmod -a

for m in mt7921_common mt7921e; do
  p=$(modinfo -n "$m")
  echo "    $m -> $p"
  [[ $p == */updates/* ]] || die "$m does not resolve to updates/. Do NOT reboot until this is fixed."
done

if lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -qE 'mt79.*\.ko'; then
  echo "==> initramfs contains mt79 modules, regenerating"
  sudo update-initramfs -u -k "$KVER"
fi

echo
echo "==> Installed. Reboot; Wi-Fi should auto-connect."
echo "    Recovery: delete lib/modules/$KVER/updates/mt7921*.ko from the USB drive on another PC."
