#!/bin/sh
# Regression test: qvpn must load the kill switch where /dev has no /dev/stdin
# (the gateway's devtmpfs has none; 'nft -f -' used to fail there).
# Needs root, unshare, nft.   usage: sh tests/test_nodev.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$(mktemp -d)
trap 'rm -rf "$B"' EXIT
mkdir -p "$B/bin"
if [ -x "$ROOT/nftb/bin/nft" ]; then
	cp "$ROOT/nft-wrapper" "$B/bin/nft"; export NFTB=$ROOT/nftb
else
	ln -s "$(command -v nft)" "$B/bin/nft"
fi
export PATH=$B/bin:$PATH QVPN_PATH=$B/bin:/usr/bin:/bin QVPN_STATE=$B QVPN_ROOT=$B/vpn

out=$(unshare -m -n sh -c '
	mount -t tmpfs tmpfs /dev || exit 99
	mknod -m 666 /dev/null c 1 3
	[ -e /dev/stdin ] && exit 98
	"$1" closed >&2
	nft list table inet qvpn >/dev/null 2>&1 && echo LOADED || echo MISSING
' sh "$ROOT/qvpn")
rc=$?
case "$rc:$out" in
0:LOADED) echo "ok   kill switch loads without /dev/stdin" ;;
99:*) echo "skip cannot mount a private /dev here"; exit 0 ;;
*) echo "FAIL kill switch without /dev/stdin (rc=$rc out=$out)"; exit 1 ;;
esac
