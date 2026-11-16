#!/bin/sh
# make-fake-vpn.sh OUT.tar - two throwaway WireGuard configs (random keys,
# documentation-range endpoints), packed with mkvpn.sh. For tests only.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: make-fake-vpn.sh OUT.tar}
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir "$D/vpn"
key() { head -c 32 /dev/urandom | base64; }
mk() { # name endpoint-ip
	cat > "$D/vpn/$1.conf" <<EOF
[Interface]
PrivateKey = $(key)
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = $(key)
AllowedIPs = 0.0.0.0/0
Endpoint = $2:51820
EOF
}
mk "Proton CH#12" 192.0.2.12
mk "NL-5" 198.51.100.2
sh "$ROOT/mkvpn.sh" -d "$D/vpn" -o "$OUT" -D proton-ch-12 > /dev/null
