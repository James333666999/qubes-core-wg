#!/bin/sh
# build.sh - make initramfs.gz for the Tiny Core + Qubes-kernel VPN gateway.
# Run in the qube that has /lib/modules from the Qubes kernel (your 'work'
# qube), from this folder:
#     sh fetch-wg.sh                  # once: collects the 'wg' tool into ./wgb
#     sh build.sh ~/rootfs64.gz       # path of Tiny Core's rootfs64.gz
# Needs: cpio, gzip. Output: ./initramfs.gz (rootfs64.gz + a small overlay).
# The image contains no keys; VPN configs come separately (see mkvpn.sh).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOTFS=${1:-rootfs64.gz}
OUT=${OUT:-initramfs.gz}
MODROOT=${MODROOT:-/lib/modules}

[ -s "$ROOTFS" ] || { echo "build: cannot find $ROOTFS (pass its path as the argument)"; exit 1; }
for f in qvif qlink qvpn qvif-up qvif-down qinit.sh inittab nft-wrapper wg-wrapper qnat.nft nftb/ld.so nftb/bin/nft; do
	[ -s "$HERE/$f" ] || { echo "build: $HERE/$f missing (qvif/qlink: run 'make'; nftb/: run 'sh fetch-nft.sh')"; exit 1; }
done
if [ ! -s "$HERE/wgb/bin/wg" ]; then
	echo "build: ./wgb is missing - run 'sh fetch-wg.sh' first (once, in this qube)"
	exit 1
fi

# Kernel version: must equal the kernel dir you copied vmlinuz/modules.img from.
if [ -z "$KV" ]; then
	KV=$(uname -r)
	[ -f "$MODROOT/$KV/kernel/drivers/block/xen-blkfront.ko" ] ||
		KV=$(ls "$MODROOT" | grep qubes | sort -V | tail -n 1)
fi
BLK="$MODROOT/$KV/kernel/drivers/block/xen-blkfront.ko"
[ -f "$BLK" ] || { echo "build: $BLK not found (set KV=... to the Qubes kernel version)"; exit 1; }
echo "build: kernel modules for $KV"

# We boot with rdinit=/sbin/init (busybox init) and our own inittab.
if ! zcat "$ROOTFS" | cpio -it 2>/dev/null | grep -Eq '^(\./)?sbin/init$'; then
	echo "build: WARNING: sbin/init not found in $ROOTFS - is it Tiny Core's rootfs64.gz?"
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/lib/modules/$KV/kernel/drivers/block" "$W/usr/local/sbin" "$W/etc" "$W/opt"
cp "$BLK" "$W/lib/modules/$KV/kernel/drivers/block/"
cp "$HERE/qvif" "$HERE/qlink" "$HERE/qvpn" "$HERE/qvif-up" "$HERE/qvif-down" "$W/usr/local/sbin/"
cp "$HERE/nft-wrapper" "$W/usr/local/sbin/nft"
cp "$HERE/wg-wrapper" "$W/usr/local/sbin/wg"
cp "$HERE/qinit.sh" "$HERE/inittab" "$HERE/qnat.nft" "$W/etc/"
cp -a "$HERE/nftb" "$W/opt/nftb"
cp -a "$HERE/wgb" "$W/opt/wgb"
chmod 755 "$W/usr/local/sbin/"* "$W/etc/qinit.sh" "$W/opt/nftb/ld.so" "$W/opt/nftb/bin/nft" "$W/opt/wgb/ld.so" "$W/opt/wgb/bin/wg"
chmod 644 "$W/etc/inittab" "$W/etc/qnat.nft"

(cd "$W" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9) > ov2.gz
cat "$ROOTFS" ov2.gz > "$OUT"
ls -l "$ROOTFS" ov2.gz "$OUT"
echo "build: done -> $OUT (kernel $KV)"
