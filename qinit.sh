#!/bin/sh
# qinit.sh - sysinit for the "Tiny Core userland on the Qubes kernel" VPN gateway.
# Runs as the busybox init sysinit action. Kernel command line (qvm-prefs
# kernelopts) carries the settings:
#   qip=A.B.C.D   this qube's own Qubes IP         (qvm-prefs <qube> ip)
#   qgw=A.B.C.D   its uplink gateway               (qvm-prefs <qube> visible_gateway)
#   qwg=NAME      which VPN config to use at boot  (see: qvpn list)
#   qvgw=A.B.C.D  optional: address put on downstream vifs (default: qip)
#   qmode=nat     optional: plain NAT, no VPN (for testing only)
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

log() { echo "qinit: $*"; }

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
# devtmpfs has no stdio symlinks; some tools (nft -f -, wg) open /dev/stdin.
ln -sf /proc/self/fd /dev/fd
ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr
mkdir -p /run /tmp

KV=$(uname -r)

# Qubes' kernel builds xen-blkfront as a module; we need it to see modules.img.
insmod /lib/modules/$KV/kernel/drivers/block/xen-blkfront.ko 2>/dev/null
i=0
while [ ! -b /dev/xvdd ] && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
if mount -o ro /dev/xvdd /lib/modules; then
	log "modules.img mounted ($KV)"
else
	log "FAILED to mount /dev/xvdd (modules.img)"
fi

modprobe xen-netfront || log "FAILED: modprobe xen-netfront"
modprobe xen-netback || log "FAILED: modprobe xen-netback"

# xenstore access for qvif: /dev/xen/xenbus normally, else xenfs.
if [ ! -e /dev/xen/xenbus ]; then
	modprobe xenfs 2>/dev/null
	mkdir -p /proc/xen 2>/dev/null
	mount -t xenfs xenfs /proc/xen 2>/dev/null
fi
[ -e /dev/xen/xenbus ] || [ -e /proc/xen/xenbus ] || log "WARNING: no xenstore device found"

for a in $(cat /proc/cmdline); do
	case $a in
	qip=*) QIP=${a#qip=} ;;
	qgw=*) QGW=${a#qgw=} ;;
	qvgw=*) QVGW=${a#qvgw=} ;;
	qmode=*) QMODE=${a#qmode=} ;;
	esac
done

# Nothing gets forwarded until a ruleset is loaded.
echo 0 > /proc/sys/net/ipv4/ip_forward
for f in all default; do
	[ -w "/proc/sys/net/ipv6/conf/$f/disable_ipv6" ] && echo 1 > "/proc/sys/net/ipv6/conf/$f/disable_ipv6"
done

# Netfilter modules (failures only matter if the ruleset then fails to load).
FAILED=
for m in nf_tables nf_conntrack nf_nat nft_chain_nat nft_nat nft_masq nft_ct; do
	modprobe "$m" 2>/dev/null || FAILED="$FAILED $m"
done

# Uplink: Qubes point-to-point style (/32, host route to the gateway, default).
i=0
while [ ! -e /sys/class/net/eth0 ] && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
if [ -n "$QIP" ] && [ -n "$QGW" ] && [ -e /sys/class/net/eth0 ]; then
	ifconfig eth0 "$QIP" netmask 255.255.255.255 up
	route add -host "$QGW" dev eth0
	route add default gw "$QGW" dev eth0
	echo "$QGW" > /run/qgw
	log "uplink eth0 $QIP via $QGW"
else
	log "uplink NOT configured (need qip= qgw= on the kernel command line and eth0)"
fi
echo "${QVGW:-$QIP}" > /run/qvgw
log "downstream vifs will use address ${QVGW:-$QIP}"

if [ "$QMODE" = nat ]; then
	if nft -f /etc/qnat.nft; then
		echo 1 > /proc/sys/net/ipv4/ip_forward
		log "NAT-only mode (no VPN): masquerade out of eth0"
	else
		log "FAILED to load /etc/qnat.nft (modprobe failures:${FAILED:- none})"
	fi
else
	# Kill switch first and synchronously, then allow forwarding, then bring
	# the tunnel up in the background so the console is usable meanwhile.
	if qvpn closed; then
		echo 1 > /proc/sys/net/ipv4/ip_forward
		(qvpn boot) &
	else
		log "kill switch FAILED to load (modprobe failures:${FAILED:- none}): forwarding stays OFF"
	fi
fi

log "ready - type 'qvpn' for status"
exit 0
