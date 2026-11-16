#!/bin/sh
# Flow test for qvpn: real nft inside a throwaway netns, stubs for the rest.
# usage: sh tests/test_qvpn.sh /path/to/vpn.tar   (made by tests/make-fake-vpn.sh)
HERE=$(cd "$(dirname "$0")/.." && pwd)
TAR=$1
T=$(mktemp -d)
mkdir -p "$T/bin" "$T/run" "$T/sys/net"
export TLOG=$T/calls.log T
: > "$TLOG"
if [ -x "$HERE/nftb/bin/nft" ]; then
	cp "$HERE/nft-wrapper" "$T/bin/nft"; export NFTB=$HERE/nftb
else
	ln -s "$(command -v nft)" "$T/bin/nft"   # no bundle: use the system nft
fi

cat > "$T/bin/ifconfig" <<'EOF'
#!/bin/sh
echo "ifconfig $*" >> $TLOG
EOF
cat > "$T/bin/route" <<'EOF'
#!/bin/sh
if [ "$1" = "-n" ]; then cat <<R
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.137.0.72     0.0.0.0         UG    0      0        0 eth0
10.137.0.72     0.0.0.0         255.255.255.255 UH    0      0        0 eth0
10.137.0.20     0.0.0.0         255.255.255.255 UH    0      0        0 vif7.0
10.137.0.30     0.0.0.0         255.255.255.255 UH    0      0        0 vif9.0
R
else echo "route $*" >> $TLOG; fi
EOF
cat > "$T/bin/ping" <<'EOF'
#!/bin/sh
echo "ping $*" >> $TLOG
EOF
cat > "$T/bin/modprobe" <<'EOF'
#!/bin/sh
echo "modprobe $*" >> $TLOG
EOF
cat > "$T/bin/qlink" <<'EOF'
#!/bin/sh
echo "qlink $*" >> $TLOG; mkdir -p "$T/sys/net/wg0"
EOF
cat > "$T/bin/wg" <<'EOF'
#!/bin/sh
case "$1 $2" in
"setconf wg0") cp "$3" "$TLOG.setconf"; echo "wg setconf $3" >> $TLOG ;;
"show wg0") case $3 in peers) echo PEERKEY= ;; latest-handshakes) printf 'PEERKEY=\t%s\n' "$(date +%s)" ;; transfer) printf 'PEERKEY=\t1234\t5678\n' ;; esac ;;
"set wg0") echo "wg $*" >> $TLOG ;;
esac
EOF
chmod +x "$T"/bin/*

export PATH=$T/bin:$HERE:/usr/bin:/bin
export QVPN_PATH=$T/bin:/usr/bin:/bin
export QVPN_ROOT=$T/run/vpn QVPN_STATE=$T/run QVPN_DEV=$TAR QVPN_SYSNET=$T/sys/net QVPN_RESOLV=$T/resolv.conf
export QVPN_CMDLINE=$T/cmdline
echo "console=hvc0 rdinit=/sbin/init qip=10.137.0.81 qgw=10.137.0.72" > "$T/cmdline"
echo 10.137.0.72 > "$T/run/qgw"

fail=0
check() { # description, command...
	d=$1; shift
	if "$@" >/dev/null 2>&1; then echo "ok   $d"; else echo "FAIL $d"; fail=1; fi
}
q="$HERE/qvpn"

unshare -n sh -c '
fail=0
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then echo "ok   $d"; else echo "FAIL $d"; fail=1; fi; }
q='"$q"'

$q closed
check "closed: table loaded"                 nft list table inet qvpn
check "closed: no endpoint rule"            sh -c "! nft list chain inet qvpn output | grep -q udp"
check "closed: forward policy drop"         sh -c "nft list chain inet qvpn forward | grep -q \"policy drop\""

check "list before boot extracts configs"   sh -c "$q list | grep -q proton-ch-12"
$q boot
check "boot: setconf temp file removed"     sh -c "[ ! -e '"$T"'/run/qvpn.wg ]"
check "boot: endpoint rule for default"     sh -c "nft list chain inet qvpn output | grep -q \"192.0.2.12 udp dport 51820\""
check "boot: DNAT to VPN DNS"               sh -c "nft list chain inet qvpn dns | grep -q \"dnat ip to 10.2.0.1\""
check "boot: allowed set refilled from routes" sh -c "nft list set inet qvpn allowed | grep -q \"vif7.0\" && nft list set inet qvpn allowed | grep -q \"vif9.0\""
check "boot: setconf got key but no Address/DNS" sh -c "grep -q PrivateKey $TLOG.setconf && ! grep -q -E \"^(Address|DNS)\" $TLOG.setconf"
check "boot: wg0 address+mtu set"           grep -q "ifconfig wg0 10.2.0.2 netmask 255.255.255.255 mtu 1420 up" $TLOG
check "boot: endpoint host route via uplink" grep -q "route add -host 192.0.2.12 gw 10.137.0.72 dev eth0" $TLOG
check "boot: /1 routes into tunnel"         sh -c "grep -q \"route add -net 0.0.0.0 netmask 128.0.0.0 dev wg0\" $TLOG && grep -q \"route add -net 128.0.0.0 netmask 128.0.0.0 dev wg0\" $TLOG"
check "boot: resolv.conf = VPN DNS"         grep -qx "nameserver 10.2.0.1" '"$T"'/resolv.conf
check "boot: state recorded"                sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = proton-ch-12 ]"

echo "--- status:"; $q status
echo "--- list:";   $q list

$q use nl-5
check "use: endpoint rule switched"         sh -c "nft list chain inet qvpn output | grep -q \"198.51.100.2 udp dport 51820\" && ! nft list chain inet qvpn output | grep -q 192.0.2.12"
check "use: old endpoint route removed"     grep -q "route del -host 192.0.2.12" $TLOG
check "use: allowed set survived the switch" sh -c "nft list set inet qvpn allowed | grep -q \"vif7.0\""
check "use: state updated"                  sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ]"

$q use nosuch
check "use nosuch: refused, state unchanged" sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ]"
$q use ../../etc/passwd
check "use ../x: refused (bad name)"        sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ]"

printf "[Interface]\nAddress = 10.2.0.2/32\n" > '"$T"'/run/vpn/wg/broken.conf
$q use broken
check "use broken config: refused, still on nl-5, rules intact" sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ] && nft list chain inet qvpn output | grep -q 198.51.100.2"

$q use 11
check "use: no match refused, state unchanged" sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ]"
$q use o
check "use: ambiguous part ('o') refused"    sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ]"
$q use ch-12
check "use: unique part of a name resolves"  sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = proton-ch-12 ]"
$q use nl
check "use: unique part 'nl' -> nl-5"        sh -c "[ \"\$(cat '"$T"'/run/qvpn.cur)\" = nl-5 ]"
echo "qwg=nosuch" >> '"$T"'/cmdline
check "bad qwg= falls back to volume default" sh -c "$q ruleset | grep -q 192.0.2.12"
echo "qwg=nl" >> '"$T"'/cmdline
check "qwg=<part of name> resolves"           sh -c "$q ruleset | grep -q 198.51.100.2"
exit $fail
'
rc=$?
echo "--- stub call log (tail):"; tail -n 14 "$TLOG"
rm -rf "$T"
exit $rc
