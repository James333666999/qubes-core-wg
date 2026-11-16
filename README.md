# Qubes Core WG

> **Alpha, version 0.1.0-alpha.** Works on the author's setup, has had little testing
> beyond it, and may change without notice. See [Status](#status).

A WireGuard VPN gateway qube for Qubes OS that fits in a ~9 MB initramfs: Tiny
Core Linux's userland, booted on the kernel dom0 provides, with a fail-closed
kill switch. Other qubes use it as their `netvm`; all their traffic goes
through the tunnel or nowhere.

    sys-net  ->  firewall qube  ->  [this qube]  ->  your qubes
                                      wg0 tunnel

Why it exists: a `sys-vpn` built on a Debian or Fedora template is hundreds of
MB. Tiny Core's own kernel cannot be a netvm (it has no `xen-netback`), but the
Qubes kernel has it as a module. So this boots Tiny Core's userland on the
Qubes kernel and replaces the one thing a Linux netvm normally gets from
`xl devd`: the Xen network-backend hotplug. See [docs/DESIGN.md](docs/DESIGN.md).

## Status

**Alpha.** Experimental, one-person tested, not audited. Commands, file formats and
kernel options may still change.

| | |
|---|---|
| Tested on | Qubes 4.3, dom0 kernel `6.18.57-1.qubes.fc41`, Xen 4.19, mirage-firewall as the upstream qube, ProtonVPN WireGuard configs |
| Seen working on hardware | boot, `xen-netback`, downstream qube networking (NAT), WireGuard handshake, a downstream qube's traffic leaving through the VPN, live config switching, kill switch (with `wg0` down the downstream qube has no connection) |
| Not yet tested on hardware | DNS and IPv6 leak tests, the endpoint going away while the tunnel is up, long uptimes, reboot/autostart |

If you rely on this for anonymity, run your own leak tests first.

## What you get

- **Kill switch.** An nftables table with `policy drop` on input, output and
  forward is loaded before the tunnel exists. The gateway itself may only send
  UDP to the VPN endpoint. Only downstream qubes' own addresses are forwarded,
  and only into `wg0`. Any failure leaves the switch closed.
- **DNS** queries to Qubes' virtual DNS (10.139.1.1 / .2) are redirected to the
  VPN's DNS server. IPv6 is disabled and dropped.
- **Config switching.** Any number of WireGuard `.conf` files (ProtonVPN,
  Mullvad, your own) live on the qube's private volume. Switch live with
  `qvpn use NAME`, set the boot default with a kernel option, or replace them
  all with one script and one dom0 command.
- **No keys in the image.** The image can be shared; configs are separate.

## Requirements

- Qubes OS with PVH qubes; a firewall/netvm qube above the gateway.
- In `work` (any Debian-based qube running the *same Qubes kernel* as the
  gateway): `gcc`, `make`, `cpio`, `gzip`, `tar`, `nftables`,
  and `wireguard-tools` (or let `fetch-wg.sh` download it).
- Tiny Core's `rootfs64.gz` (x86_64), e.g.
  `curl -LO http://tinycorelinux.net/17.x/x86_64/release/distribution_files/rootfs64.gz`

## Quick start

**1. dom0: kernel directory and qube** (names are examples; use your own).
Check the folder name of your Qubes kernel with `ls $K`.

    K=/var/lib/qubes/vm-kernels
    S=$K/6.18.57-1.qubes.fc41.x86_64          # your Qubes kernel's folder
    sudo mkdir $K/qcwg
    sudo cp $S/vmlinuz $S/modules.img $K/qcwg/

    qvm-create -C StandaloneVM -l gray --property virt_mode=pvh --property kernel=qcwg sys-vpn
    qvm-features sys-vpn no-default-kernelopts 1
    qvm-prefs sys-vpn maxmem 0
    qvm-prefs sys-vpn memory 512
    qvm-prefs sys-vpn netvm mirage-fw          # or sys-firewall
    qvm-prefs sys-vpn provides_network True
    qvm-prefs sys-vpn ip                       # note it: qip=
    qvm-prefs sys-vpn visible_gateway          # note it: qgw=

**2. work: build.**

    git clone <this repo> && cd qubes-core-wg
    make                          # builds the static helpers qvif and qlink
    sh fetch-nft.sh               # bundles nft (once)
    sh fetch-wg.sh                # bundles wg (once)
    mkdir ~/vpn                   # put your *.conf files here (see "Configs")
    sh mkvpn.sh                   # validates and packs them into ~/vpn.tar (-q NAME if your qube is not "sys-vpn")
    sh build.sh ~/rootfs64.gz     # writes ./initramfs.gz

**3. dom0: install, import the configs, start.** `mkvpn.sh` prints the exact
import commands; they amount to:

    K=/var/lib/qubes/vm-kernels
    qvm-kill sys-vpn
    qvm-run -p work 'cat ~/qubes-core-wg/initramfs.gz' | sudo tee $K/qcwg/initramfs >/dev/null
    qvm-run -p work 'cat ~/vpn.tar' > ~/vpn.tar
    qvm-volume import sys-vpn:private ~/vpn.tar
    shred -u ~/vpn.tar
    qvm-prefs sys-vpn kernelopts 'console=hvc0 rdinit=/sbin/init qip=<IP> qgw=<GATEWAY> qwg=<NAME>'
    qvm-start sys-vpn
    sudo xl console sys-vpn                    # leave with Ctrl+]

Then in `work`: `shred -u ~/vpn.tar` and keep the `.conf` files only there.

**4. Check.** On the gateway console type `qvpn`. You want a recent handshake,
`killsw : loaded`, and your downstream qubes under `vifs`. Then
`qvm-prefs <qube> netvm sys-vpn`, start the qube, and visit an
"what is my IP" page. Test the switch: `ifconfig wg0 down` on the gateway
console must cut the downstream qube off completely; `qvpn use NAME` restores it.

To start it with Qubes: `qvm-prefs sys-vpn autostart true`.

## Configs

A config is a normal WireGuard file: `[Interface]` with `PrivateKey`, an IPv4
`Address` and a `DNS` line, and a `[Peer]` with `PublicKey`, `Endpoint` and
`AllowedIPs = 0.0.0.0/0`. `mkvpn.sh` checks them, resolves a hostname endpoint
to an IPv4 address (the gateway needs a literal), and names each config after
its file (`Proton CH#12.conf` becomes `proton-ch-12`).

    qvpn                 status: config, handshake age, downstream qubes, kill switch
    qvpn list            available configs (* = active)
    qvpn use NAME        switch live; a unique part of the name is enough (qvpn use 11)

To add or replace configs: put the files in `~/vpn`, run `sh mkvpn.sh`, repeat
the import commands from step 3 (`qvm-kill` first; the volume cannot be
replaced while the qube runs). No rebuild is needed.

## Kernel options

| option | meaning |
|---|---|
| `qip=` | the qube's own Qubes IP (`qvm-prefs <qube> ip`) |
| `qgw=` | its uplink gateway (`qvm-prefs <qube> visible_gateway`) |
| `qwg=` | config to use at boot; a unique part of a name works. If it matches nothing, the volume's default is used |
| `qvgw=` | only if downstream qubes must see a different gateway address than `qip` |
| `qmode=nat` | testing: plain NAT without a VPN |

`qip`/`qgw` belong to the qube: if you clone or rename it, update them.

## Troubleshooting

| symptom | meaning |
|---|---|
| `kill switch FAILED to load` | the console shows the `nft` error; check that the kernel's netfilter modules loaded (`qinit:` lines) |
| `no configs read from /dev/xvdb` | the tar was not imported, or the qube was running during the import |
| `NO HANDSHAKE` | endpoint unreachable, or the config expired or was revoked (regenerate it). Traffic is blocked, not leaked |
| `could not create wg0` | the kernel has no `wireguard` module |
| downstream qube has no network | `qvpn` shows `vifs :` empty: `qvif` did not see it; look for `qvif:` lines on the console |
| pings to the gateway's own address fail | normal with mirage-firewall; test with a public address |

## Layout

    qvif.c  qlink.c        static helpers: xenstore vif hotplug daemon; creates wg0 via netlink
    qvif-up  qvif-down     per-vif setup/teardown called by qvif
    qvpn                   the control script: kill switch, tunnel, status, switching
    qinit.sh  inittab      init (replaces Tiny Core's tc-config)
    nft-wrapper wg-wrapper run the bundled nft/wg with their own libc
    build.sh               assembles initramfs.gz (rootfs64.gz + overlay)
    fetch-nft.sh fetch-wg.sh   bundle nft and wg from your Debian qube
    mkvpn.sh               validates configs and packs them for import
    tests/                 fake-xenstore test for qvif, qvpn flow test, regression tests
    docs/DESIGN.md         how and why
    VERSION                0.1.0-alpha

## Tests

    make test            # needs root (network namespaces), nft, unshare, python3

The qvpn flow test loads the real nftables ruleset in a throwaway namespace and
stubs `ifconfig`, `route` and `wg`. It uses generated fake keys; nothing real.
It does not replace testing on Xen with a real VPN.

## Never commit

`*.conf`, `vpn.tar`, `nftb/`, `wgb/`, `initramfs.gz`: they hold private keys or
third-party binaries. `.gitignore` excludes them. Scan before every push.

## License

MIT, see [LICENSE](LICENSE). The bundled `nft` and `wg` you fetch yourself are under their
own licenses (GPL).

## Credits

Built on Tiny Core Linux, BusyBox, nftables, wireguard-tools and the Qubes OS
network model. The starting point was unman's Tiny Core Qubes template
(https://qubes.3isec.org/Templates/). Not affiliated with or endorsed by any of them, the
Qubes OS Project, or ProtonVPN.
