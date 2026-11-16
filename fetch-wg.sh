#!/bin/sh
# fetch-wg.sh - collect the 'wg' tool (and the libc it needs) from this Debian
# qube into ./wgb, so build.sh can put it into the gateway image.
# Run once, in your 'work' qube:   sh fetch-wg.sh
# If wg is not installed here it is downloaded and unpacked in a temp folder;
# nothing gets installed into the qube.
set -e
cd "$(dirname "$0")"
rm -rf wgb
mkdir -p wgb/bin wgb/lib

WG=$(command -v wg || true)
if [ -z "$WG" ]; then
	echo "fetch-wg: wg is not installed here; downloading wireguard-tools (not installing it)..."
	T=$(mktemp -d)
	trap 'rm -rf "$T"' EXIT
	(
		cd "$T"
		apt-get download wireguard-tools 2>/dev/null || {
			echo "fetch-wg: package lists are empty, running apt-get update first (sudo)..."
			sudo apt-get update
			apt-get download wireguard-tools
		}
	)
	dpkg-deb -x "$T"/wireguard-tools_*.deb "$T/x"
	WG=$T/x/usr/bin/wg
fi

cp -L "$WG" wgb/bin/wg
cp -L /lib64/ld-linux-x86-64.so.2 wgb/ld.so
for l in $(ldd "$WG" | awk '/=> \//{print $3}'); do
	cp -L "$l" wgb/lib/
done
chmod 755 wgb/ld.so wgb/bin/wg
./wgb/ld.so --inhibit-cache --library-path ./wgb/lib ./wgb/bin/wg --version
echo "fetch-wg: ok ($(du -sh wgb | cut -f1)) -> ./wgb"
