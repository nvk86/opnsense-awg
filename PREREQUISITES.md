# Prerequisites

This page lists the requirements to check before installing `opnsense-awg`.

## Platform

The initial `v1.0.0` release is intended for:

- OPNsense 27.x
- FreeBSD 15.x amd64 (the OPNsense 27.x base)

Check the running system with:

```sh
opnsense-version
uname -r
uname -m
```

Other OPNsense/FreeBSD branches are not declared tested by this release.

## Backup

Create an OPNsense configuration backup before installation or upgrade:

**System → Configuration → Backups → Download configuration**

The installer is transactional and contains rollback safeguards, but a current firewall configuration backup is still recommended before changing VPN software or kernel packages.

## Shell access

Installation is performed from the OPNsense shell. SSH is convenient but not mandatory; the local console shell can also be used.

If connecting over SSH:

```sh
ssh root@<opnsense-ip>
```

Run the installer explicitly with POSIX `sh`:

```sh
sh install.sh
```

This avoids shell-syntax differences when the OPNsense root account uses `csh` interactively.

## AmneziaWG packages

The plugin requires both:

- `amnezia-tools`
- `amnezia-kmod`

For full AWG 2.0 parameter support, `amnezia-kmod` 2.0.x and a current `amnezia-tools` build are recommended.

You do not need to enable the FreeBSD repository globally or modify the normal OPNsense repository configuration manually. `install.sh` checks the installed packages and, when a package transaction is required, uses an isolated temporary FreeBSD quarterly repository configuration for that transaction only.

## Client mode network requirements

For an AmneziaWG client tunnel:

- the OPNsense firewall must be able to send UDP to the configured VPN endpoint;
- the imported/manual client settings must match the server, including keys, endpoint and AWG obfuscation parameters;
- when OPNsense itself is behind NAT, `PersistentKeepalive = 25` is generally recommended;
- policy routing, gateway selection and Outbound NAT are configured in OPNsense as described in the main [README](README.md).

A current native AmneziaWG client configuration can be imported with **Parse & Fill**, or the tunnel can be configured manually.

## Server mode network requirements

For an AmneziaWG server instance:

- the configured UDP listen port must be reachable on OPNsense from the intended clients;
- if OPNsense is behind another router/NAT device, that device must forward the UDP listen port to OPNsense;
- OPNsense firewall rules must explicitly allow the desired traffic;
- Outbound NAT is required if VPN peers should use the OPNsense WAN for Internet access, unless a deliberately routed no-NAT design is used.

The plugin manages the AWG interface and service lifecycle. It does not silently create WAN, inter-interface or Outbound NAT firewall policy.

## Before installation

Confirm that you have:

- a current OPNsense configuration backup;
- shell access to OPNsense;
- working DNS/Internet access from OPNsense for package checks;
- for client mode, valid AmneziaWG server/client parameters;
- for server mode, a chosen UDP listen port and the required upstream port forwarding if OPNsense is behind NAT.

Then continue with the [Installation](README.md#installation) section of the README.
