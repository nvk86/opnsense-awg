# opnsense-awg

**AmneziaWG Client + Server plugin for OPNsense** — v1.0.0

`opnsense-awg` integrates AmneziaWG into OPNsense as a native VPN service with multiple client tunnels, native server instances, server peers, client provisioning, selective routing and a transactional installer.

AmneziaWG is an obfuscated WireGuard-compatible VPN protocol designed to make WireGuard traffic harder to identify by DPI while retaining the familiar WireGuard network model.

> This is a third-party community plugin. It is not an official OPNsense or AmneziaVPN component.

## Upstream and attribution

This project is based on the client implementation from [MrTheory/os-amneziawg](https://github.com/MrTheory/os-amneziawg).

The upstream project provided the original OPNsense AmneziaWG client integration, including multi-instance client tunnels, AWG 2.0 parameters, configuration import, watchdog/sentinel handling, diagnostics and selective-routing support. `opnsense-awg` keeps that foundation and extends it with native server mode, server peers, client provisioning, differential lifecycle reconciliation and a hardened installer/update path.

The original copyright notice and BSD 2-Clause License are retained in [LICENSE](LICENSE).

## What the plugin provides

### Client mode

- Multiple independent client tunnels in the shared `awg0`–`awg99` namespace.
- Import of native AmneziaWG `.conf` files with **Parse & Fill**.
- Direct keypair generation from the OPNsense GUI.
- AWG 2.0 parameters: `Jc`, `Jmin`, `Jmax`, `S1`–`S4`, `H1`–`H4` including ranges, and `I1`–`I5` CPS values.
- `Table = off`: the plugin does not install policy routes itself. OPNsense Firewall Rules + Gateway remain the source of routing policy.
- Per-instance Start / Stop / Restart.
- Runtime statistics, handshake state and connection diagnostics.
- Private client keys stored outside `config.xml` in root-only files.

### Server mode

- Multiple native AmneziaWG server instances in the same `awg0`–`awg99` namespace as client tunnels.
- Multiple peers per server.
- Server and peer key generation from the GUI.
- Per-peer runtime state: `active`, `inactive`, `never` or `stopped`, with latest handshake and learned endpoint where available.
- Client provisioning directly from a Server Peer:
  - client keypair generation;
  - unique PSK generation;
  - native AmneziaWG `.conf` export;
  - multipart QR generation compatible with AmneziaVPN native AWG import.
- Provisioning settings such as client endpoint, client DNS and client keepalive are kept separate from the server runtime configuration.

### Lifecycle and watchdog

- Persistent canonical managed configs in `/usr/local/etc/amnezia/awgN.conf` with mode `0600`.
- Differential Apply/Reconfigure:
  - unchanged live tunnels remain untouched;
  - changed tunnels are restarted individually;
  - newly enabled tunnels are started;
  - disabled/deleted tunnels are reconciled safely.
- If a changed tunnel fails to restart, the lifecycle engine attempts to restore its previous working canonical config.
- Lifecycle operations are serialized with `flock(2)`.
- The watchdog repairs only the failed managed instance instead of restarting every tunnel.
- A live `awgN` interface without the expected plugin-owned canonical config is treated as unmanaged and is not taken over blindly.

## Installer and package handling

`install.sh` handles plugin installation, upgrade and removal. It also performs defensive checks around the FreeBSD packages required by AmneziaWG.

The installer:

- verifies the current plugin version and asks before install/reinstall/upgrade;
- verifies `pkg`/repository state before modifying packages;
- never edits the normal OPNsense repository configuration to expose FreeBSD packages;
- uses an isolated, command-scoped temporary FreeBSD quarterly `REPOS_DIR` only when needed;
- preserves pre-existing package lock state;
- handles `amnezia-tools` and `amnezia-kmod` independently;
- creates local rollback packages before replacing installed AWG packages;
- validates package identity/version before installation;
- for a kmod replacement, records the exact live managed AWG interface set, stops it, replaces the module and restores that exact set;
- rolls back package/plugin state when a transactional step fails before commit;
- refuses unsafe kmod replacement if a live AWG interface cannot be mapped to a canonical plugin config.

A userspace-only `amnezia-tools` update intentionally leaves live tunnels running when it can safely do so.

## Requirements

| Component | Supported / expected |
|---|---|
| OPNsense | 27.x |
| FreeBSD | 15.x amd64 (OPNsense 27.x base) |
| `amnezia-kmod` | 2.0.x recommended for full AWG 2.0 support |
| `amnezia-tools` | 1.0.20250903 or newer recommended |
| Browser | Current Chromium/Firefox-compatible browser |

For VM networking, shell and tunnel prerequisites, read [PREREQUISITES.md](PREREQUISITES.md) before installation.

## Installation

### 1. Download the plugin

For the current repository snapshot on a workstation:

```sh
git clone https://github.com/nvk86/opnsense-awg.git
cd opnsense-awg
```

Alternatively, download the repository archive from GitHub and unpack it locally.

### 2. Copy it to OPNsense

```sh
scp -r opnsense-awg root@<opnsense-ip>:/tmp/opnsense-awg
```

Then connect to OPNsense:

```sh
ssh root@<opnsense-ip>
sh
cd /tmp/opnsense-awg
```

`sh` is intentional: the interactive OPNsense/FreeBSD root shell may be `csh`, while the installer is a POSIX shell script.

### 3. Run the installer

```sh
sh install.sh
```

The installer shows the currently installed plugin version and the version being installed, checks the AWG userspace/kernel prerequisites and asks before any relevant package transaction.

After installation, refresh the OPNsense GUI and open:

**VPN → AmneziaWG**

The plugin exposes native pages for **General**, **Server**, **Clients** and **Diagnostics**.

## Client configuration

### Add a client tunnel

Open **VPN → AmneziaWG → Clients** and either:

- create a client instance manually; or
- import a native AmneziaWG `.conf` with **Parse & Fill**.

Enable the instance, verify its interface number and AWG parameters, then Apply.

### Assign the AWG interface

For policy routing, assign the generated `awgN` interface in:

**Interfaces → Assignments**

Add the required `awgN`, enable the assigned interface and leave IPv4/IPv6 configuration type at `None` unless your network design explicitly requires something else.

### Create an OPNsense gateway

For a typical client tunnel with local tunnel address `10.8.1.14/32` and remote tunnel address `10.8.1.1`, create a gateway under:

**System → Gateways → Configuration**

Example:

| Field | Value |
|---|---|
| Name | `AWG_GW` |
| Interface | assigned `awgN` interface |
| IP address | remote address inside the AWG tunnel, e.g. `10.8.1.1` |
| Far Gateway | enabled |
| Gateway Monitoring | disable it unless you intentionally configure monitoring |

The public VPS address belongs in the AmneziaWG `Endpoint`; it is **not** the OPNsense policy-routing gateway address.

### Outbound NAT for Internet breakout

For the normal “send selected LAN/VLAN traffic to the Internet through the VPS” design, create an Outbound NAT rule on the assigned AWG interface:

- source: the local networks that may use the tunnel;
- translation: **Interface address**.

This SNATs LAN/VLAN client addresses to the OPNsense AWG tunnel address before the packet reaches the VPS. A fully routed no-NAT design is possible, but then the VPS/server peer must explicitly route and permit all original LAN/VLAN prefixes in its `AllowedIPs`/routing design.

### Route selected traffic through AWG

Create a normal OPNsense firewall rule on the source LAN/VLAN and choose `AWG_GW` in the rule's **Gateway** field.

The rule must be evaluated before the ordinary default allow rule that would otherwise use the normal WAN routing path.

Because managed client configs use:

```ini
Table = off
```

OPNsense remains responsible for policy routing; `awg-quick` does not install its own default routes.

## Server configuration

Open **VPN → AmneziaWG → Server**.

### Create a server instance

Create an enabled Server instance and configure:

- `awgN` interface number;
- tunnel address/subnet;
- listen port;
- AWG obfuscation parameters;
- public endpoint used when generating client configurations;
- optional client DNS and keepalive provisioning values.

Server and client instances share `awg0`–`awg99`, so the plugin rejects interface-number collisions between them.

### Add Server Peers

Add one or more peers to the server. The plugin can generate client keys and a unique PSK, then use the server settings to produce a complete native client configuration.

For a provisioned peer you can export:

- `.conf` for native AmneziaWG tools;
- QR data for import into AmneziaVPN.

### Firewall and routing for server mode

The plugin manages the AWG interface/configuration. It intentionally does **not** silently create OPNsense firewall or NAT policy for you.

You must configure the surrounding OPNsense policy appropriate for your design, for example:

- a WAN rule allowing the configured UDP listen port to the firewall itself;
- rules on the assigned AWG interface permitting peer traffic to the desired local networks;
- Outbound NAT if VPN peers should use the OPNsense WAN for Internet access;
- routes/firewall policy for site-to-site networks when peer prefixes represent routed remote networks.

This keeps the VPN service lifecycle separate from OPNsense security policy.

## Updating

Download/unpack the newer `opnsense-awg` release or repository snapshot, copy it to OPNsense and run its installer exactly as for the initial installation:

```sh
cd /tmp/opnsense-awg
sh install.sh
```

If an older version is installed, the script displays both versions and asks to upgrade.

Plugin configuration and protected private-key files are preserved across a normal upgrade. The installer creates rollback state before replacing plugin files and validates the resulting runtime before committing the new plugin version.

If a newer `amnezia-tools` or `amnezia-kmod` package is available, it is handled as a separate guarded transaction rather than as an uncontrolled general `pkg upgrade`.

After upgrading, verify:

```sh
configctl amneziawg version
configctl amneziawg validate
awg show
```

## Removing

Run the installer from any matching source directory:

```sh
sh install.sh uninstall
```

Removal first stops plugin-owned AWG interfaces safely. It then asks two independent questions:

1. whether `amnezia-kmod` and `amnezia-tools` should also be removed;
2. whether saved AmneziaWG configuration and private keys should be purged.

By default, package removal and configuration/key purge are **not** forced. This makes reinstalling the plugin without losing its saved configuration possible.

Plugin-owned canonical `awgN.conf` files are removed during uninstall because they are derived lifecycle state.

## Useful commands

```sh
awg show
configctl amneziawg status
configctl amneziawg version
configctl amneziawg validate
configctl amneziawg restart
```

Logs:

```text
/var/log/amneziawg.log
/var/lib/php/tmp/PHP_errors.log
/var/log/system/latest.log
```

## Important file locations

```text
/usr/local/etc/amnezia/<uuid>.key
    protected client-instance private key

/usr/local/etc/amnezia/server-<uuid>.key
    protected server-instance private key

/usr/local/etc/amnezia/peer-<uuid>.key
    protected provisioned client private key for a Server Peer

/usr/local/etc/amnezia/awg<N>.conf
    persistent plugin-owned canonical managed tunnel config

/usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/version.txt
    installed plugin version

/var/run/amneziawg.pid
    service sentinel PID

/var/run/amneziawg.lock
    lifecycle serialization lock

/var/log/amneziawg.log
    plugin log
```

## Project layout

```text
plugin/
├── etc/
│   ├── inc/plugins.inc.d/amneziawg.inc
│   ├── newsyslog.conf.d/amneziawg.conf
│   └── rc.syshook.d/start/50-amneziawg
├── mvc/app/
│   ├── controllers/OPNsense/AmneziaWG/
│   ├── models/OPNsense/AmneziaWG/
│   └── views/OPNsense/AmneziaWG/
├── scripts/AmneziaWG/
│   ├── amneziawg-service-control.php
│   ├── amneziawg-watchdog.php
│   ├── amneziawg-ifstats.php
│   └── amneziawg-testconnect.php
└── service/conf/actions.d/actions_amneziawg.conf
```

The internal `AmneziaWG` MVC namespace and `amneziawg` configd/service identifiers are intentionally retained for compatibility with the existing OPNsense configuration model and upgrade path. The project/repository/plugin distribution name is `opnsense-awg`.

## License

BSD 2-Clause License. See [LICENSE](LICENSE).

Original upstream source: [MrTheory/os-amneziawg](https://github.com/MrTheory/os-amneziawg).

Additional projects used by or relevant to this plugin:

- [AmneziaVPN](https://github.com/amnezia-vpn) / AmneziaWG
- [OPNsense](https://opnsense.org/)
- [FreeBSD ports/packages](https://www.freebsd.org/)
