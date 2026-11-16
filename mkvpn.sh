#!/bin/sh
# mkvpn.sh - pack WireGuard configs into vpn.tar for the gateway qube.
#
# Put any number of WireGuard .conf files (ProtonVPN or any other provider) in
# ~/vpn/ and run:
#       sh mkvpn.sh
# Each file becomes a config named after its file name (lowercased), e.g.
# "Proton-CH#12.conf" -> "proton-ch-12". It checks the keys, resolves a
# hostname Endpoint to an IPv4 address (the kill switch needs the literal
# address), and prints the dom0 commands that load the tar into the qube.
#
#   sh mkvpn.sh [-d DIR] [-o FILE] [-q QUBE] [-D DEFAULTNAME]
#       -d DIR      folder with the .conf files        (default ~/vpn)
#       -o FILE     tar to write                       (default ~/vpn.tar)
#       -q QUBE     name of the gateway qube           (default sys-vpn)
#       -D NAME     config used at boot unless the kernel option qwg=NAME
#                   says otherwise                     (default: first one)
set -e
DIR=$HOME/vpn
OUT=$HOME/vpn.tar
QUBE=sys-vpn
DEF=

while getopts d:o:q:D:h o; do
	case $o in
	d) DIR=$OPTARG ;;
	o) OUT=$OPTARG ;;
	q) QUBE=$OPTARG ;;
	D) DEF=$OPTARG ;;
	*) sed -n '2,19p' "$0"; exit 2 ;;
	esac
done

[ -d "$DIR" ] || { echo "mkvpn: put your .conf files in $DIR first (mkdir $DIR)"; exit 1; }
umask 077
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/wg"

getv() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$2" | head -n 1 | tr -d '\r '; }
iskey() { [ "$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c)" -eq 32 ]; }
isv4() {
	case $1 in '' | *[!0-9.]*) return 1 ;; esac
	[ "$(printf '%s' "$1" | tr -cd . | wc -c)" -eq 3 ]
}

n=0
bad=0
list=
for f in "$DIR"/*.conf; do
	[ -f "$f" ] || continue
	base=${f##*/}
	base=${base%.conf}
	name=$(printf '%s' "$base" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '-' | cut -c1-24)
	[ -n "$name" ] || { echo "  $base: empty name, skipped"; continue; }
	if [ -e "$T/wg/$name.conf" ]; then
		echo "  $base: becomes '$name', which is already used - rename one file"
		bad=1
		continue
	fi

	key=$(getv PrivateKey "$f")
	pub=$(getv PublicKey "$f")
	addr=$(getv Address "$f" | tr ',' '\n' | grep -v ':' | head -n 1)
	dns=$(getv DNS "$f" | tr ',' '\n' | grep -v ':' | head -n 1)
	ep=$(getv Endpoint "$f")
	host=${ep%:*}
	port=${ep##*:}
	allowed=$(getv AllowedIPs "$f")

	iskey "$key" || { echo "  $base: PrivateKey missing or not a valid key"; bad=1; continue; }
	iskey "$pub" || { echo "  $base: PublicKey missing or not a valid key"; bad=1; continue; }
	[ -n "$addr" ] || { echo "  $base: no IPv4 Address"; bad=1; continue; }
	[ -n "$dns" ] || { echo "  $base: no IPv4 DNS line (the gateway only ever uses the VPN's DNS)"; bad=1; continue; }
	case $port in '' | *[!0-9]*) echo "  $base: bad Endpoint '$ep'"; bad=1; continue ;; esac

	ip=$host
	if ! isv4 "$host"; then
		ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
		[ -n "$ip" ] || { echo "  $base: cannot resolve Endpoint host '$host' to IPv4"; bad=1; continue; }
		echo "  $base: Endpoint $host -> $ip (re-run mkvpn.sh if the provider changes it)"
	fi
	case $allowed in
	*0.0.0.0/0*) ;;
	*) echo "  $base: WARNING AllowedIPs has no 0.0.0.0/0: the rest of the traffic would be blocked" ;;
	esac

	sed "s|^\([[:space:]]*Endpoint[[:space:]]*=[[:space:]]*\).*|\1$ip:$port|" "$f" | tr -d '\r' > "$T/wg/$name.conf"
	n=$((n + 1))
	list="$list $name"
done

[ "$bad" -eq 0 ] || { echo "mkvpn: fix the problems above and run it again"; exit 1; }
[ "$n" -gt 0 ] || { echo "mkvpn: no .conf files in $DIR"; exit 1; }

[ -n "$DEF" ] || DEF=$(printf '%s\n' $list | head -n 1)
[ -f "$T/wg/$DEF.conf" ] || { echo "mkvpn: default '$DEF' is not one of:$list"; exit 1; }
printf '%s\n' "$DEF" > "$T/wg/default"

chmod 700 "$T/wg"
chmod 600 "$T/wg/"*
rm -f "$OUT"
tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "$OUT" -C "$T" wg
chmod 600 "$OUT"

SRC=$(hostname)
echo
echo "Packed $n config(s) into $OUT:$list   (boot default: $DEF)"
echo
echo "Now in dom0 (the gateway qube must be stopped for the import):"
echo "    qvm-kill $QUBE"
echo "    qvm-run -p $SRC 'cat $OUT' > ~/vpn.tar"
echo "    qvm-volume import $QUBE:private ~/vpn.tar"
echo "    shred -u ~/vpn.tar"
echo "    qvm-start $QUBE"
echo
echo "Then here:   shred -u $OUT     (it contains your private keys)"
echo "Pick another boot config later with the kernel option qwg=NAME, or switch live"
echo "on the gateway console with:  qvpn use NAME"
