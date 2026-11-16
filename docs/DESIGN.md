# Qubes Core WG: design notes

How the gateway works and why it is built this way. Read this if you want to
change it or debug it.

## 1. Why not stock Tiny Core

A Qubes netvm needs the Xen network *backend* (`xen-netback`) so downstream
qubes can attach virtual interfaces. Tiny Core's kernel has the frontend only
(`CONFIG_XEN_NETDEV_BACKEND` is not set). The Qubes kernel that dom0 provides
has `xen-netback` as a module. So the gateway runs Tiny Core's *userland* on
the *Qubes kernel*.

## 2. Boot path

Qubes boots PVH qubes directly from `/var/lib/qubes/vm-kernels/<name>/`:

| file | content here |
|---|---|
| `vmlinuz` | copied unchanged from the Qubes kernel's folder |
| `modules.img` | copied from the same folder (ext4, becomes `xvdd`) |
| `initramfs` | Tiny Core's `rootfs64.gz` followed by our overlay (two gzip cpio archives concatenated; the kernel unpacks both) |

The kernel runs `rdinit=/sbin/init`: BusyBox init with our `/etc/inittab`,
which skips Tiny Core's `tc-config`. Disks: `xvda` root, `xvdb` private,
`xvdc` volatile, `xvdd` modules.

The Qubes kernel builds `xen-blkfront` and `xen-netfront` as modules. Without
`xen-blkfront` no disk, including `modules.img`, is visible. The overlay
therefore carries `xen-blkfront.ko`; `qinit.sh` loads it, mounts `xvdd` on
`/lib/modules`, and `modprobe` does the rest (`xen-netfront`, `xen-netback`,
netfilter, `wireguard`). The module version must equal the booted kernel's.

## 3. Vif hotplug (`qvif`)

On a normal Linux netvm, `xl devd` runs `vif-route-qubes` for each downstream
vif. `xen-netback` keeps the connection pending until the backend node's
`hotplug-status` is `connected`. Tiny Core has neither `xl` nor xenstore tools,
so `qvif` is a small static C daemon that:

1. speaks the xenstore wire protocol over `/dev/xen/xenbus` (or xenfs),
2. watches `backend/vif`, takes `vifDOMID.HANDLE` from each node's path and reads its `ip`,
3. runs `qvif-up vifDOMID.HANDLE IP...`, then writes `hotplug-status`
   `connected` (or `error`), and tears down on removal.

`qvif-up` follows the Qubes point-to-point scheme: the vif gets the gateway
address as a /32, `proxy_arp` is enabled, each client IP gets a host route, and
`(vif . client IP)` is added to the kill switch's `allowed` set. That set also
serves as anti-spoofing: a qube can only send from its own address.

`tests/test_qvif.py` runs `qvif` against a fake xenstore server speaking the
real wire protocol (including events interleaved with replies).

## 4. Addressing and NAT

The uplink is point-to-point as well (`qip` /32, host route to `qgw`, default
via `qgw`). mirage-firewall only accepts the source address it assigned, so
downstream traffic is masqueraded; it also does not answer pings addressed to
itself. Qubes' virtual DNS addresses (10.139.1.1, .2) are DNATed to the VPN's
DNS. TCP MSS is clamped to the route MTU.

## 5. Kill switch (`qvpn`)

One table, `inet qvpn`, all base chains `policy drop`:

- `input`: loopback, established/related, ping from vifs.
- `output`: loopback, `wg0`, vifs, and **only** UDP to the endpoint IP:port on
  the uplink.
- `forward`: only `(iifname . saddr)` pairs in `allowed`, only out of `wg0`;
  replies only from `wg0`.
- `nat`: masquerade out of `wg0`; DNS redirect.

Order is the safety property: `qinit.sh` loads the closed table first and only
then enables forwarding; `qvpn boot` then brings the tunnel up. A bad config,
a missing module or a failed handshake therefore leaves the gateway closed. A
switch (`qvpn use`) validates the new config first, replaces the table in one
transaction, then refills the `allowed` set from the host routes.

IPv6 is disabled on the gateway, and nothing but IPv4 `allowed` pairs is
forwarded.

## 6. WireGuard without iproute2

BusyBox has `ifconfig` and `route` but cannot create a WireGuard link, so:

- `qlink add wg0 wireguard MTU` creates the link over rtnetlink.
- `wg setconf` gets the config with wg-quick-only keys (`Address`, `DNS`,
  `MTU`, `Table`, `PreUp`, ...) stripped; `Address` and `DNS` are applied by
  `qvpn` itself.
- Routing: a host route for the endpoint via the uplink, and two /1 routes
  (`0.0.0.0/1`, `128.0.0.0/1`) into `wg0` instead of replacing the default.
- The endpoint must be an IPv4 literal (the gateway must not resolve names
  outside the tunnel); `mkvpn.sh` resolves hostnames for you.

## 7. Where configs live

Tiny Core has no qrexec and this console has no copy-paste, so nothing is sent
into the running qube. `mkvpn.sh` packs configs into a tar; dom0 imports it
over the qube's private volume (`qvm-volume import QUBE:private FILE`); at boot
`qvpn` extracts the tar from `/dev/xvdb` into RAM (`/run/vpn`, mode 700). The
image contains no secrets, nothing is written to disk by the gateway, and
`wg setconf` reads a mode-600 copy in RAM that is deleted at once.

## 8. Bundled binaries

`nft` and `wg` come from your Debian qube together with its `ld-linux` and
libraries (`fetch-nft.sh`, `fetch-wg.sh`) and are run through that loader
(`ld.so --library-path ...`), so they never touch Tiny Core's libc. They are
fetched, not committed: the repo contains no third-party binaries.

## 9. Things that bit us

- `devtmpfs` has no `/dev/stdin`: `nft -f -` and `wg setconf /dev/stdin` fail.
  `qvpn` uses files in RAM, and `qinit.sh` also creates the symlinks.
  (`tests/test_nodev.sh`)
- `nft_exthdr` and `nft_rt` are part of the `nf_tables` core, not separate
  modules; `modprobe` failing on them is normal.
- Qubes 4.3's kernel folder is named like `6.18.57-1.fc41`, the module folder
  inside is `6.18.57-1.qubes.fc41.x86_64`.
- Typed commands only: `qvpn use` accepts a unique part of a name.

## 10. Limits and ideas

- IPv4 only. x86_64 only.
- `qip`/`qgw` are kernel options because Tiny Core has no QubesDB; reading
  them from the system would remove that step.
- No qrexec, so no `qvm-copy`, no Qubes updates proxy, no clipboard.
- Leak-tested on hardware only for `ifconfig wg0 down` (the downstream qube loses all connectivity). DNS and IPv6 leak tests and reboot behaviour are still to do; run them before trusting it.
