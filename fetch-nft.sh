#!/bin/sh
# fetch-nft.sh - collect the 'nft' tool (and the libc/libs it needs) from this
# Debian qube into ./nftb, so build.sh can put it into the gateway image.
# Run once, in your 'work' qube:   sh fetch-nft.sh
# Debian-based Qubes templates already have nftables (the Qubes firewall uses
# it). If yours does not:  sudo apt install nftables   in the TEMPLATE.
# Tested with nftables 1.0.9; the ruleset needs 1.0 or newer.
set -e
cd "$(dirname "$0")"

NFT=
for c in "$(command -v nft 2>/dev/null)" /usr/sbin/nft /sbin/nft; do
	[ -n "$c" ] && [ -x "$c" ] && { NFT=$c; break; }
done
[ -n "$NFT" ] || { echo "fetch-nft: nft not found; install the 'nftables' package"; exit 1; }

rm -rf nftb
mkdir -p nftb/bin nftb/lib
cp -L "$NFT" nftb/bin/nft
cp -L /lib64/ld-linux-x86-64.so.2 nftb/ld.so
for l in $(ldd "$NFT" | awk '/=> \//{print $3}'); do
	cp -L "$l" nftb/lib/
done
chmod 755 nftb/ld.so nftb/bin/nft
./nftb/ld.so --inhibit-cache --library-path ./nftb/lib ./nftb/bin/nft --version
echo "fetch-nft: ok ($(du -sh nftb | cut -f1)) -> ./nftb"
