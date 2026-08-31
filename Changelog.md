# Changelog

All notable public releases of `opnsense-awg` are documented here.

## v1.0.0 — 2026-08-31

### Initial release

- First public release under the `opnsense-awg` project name.
- Based on the client implementation from [MrTheory/os-amneziawg](https://github.com/MrTheory/os-amneziawg), retaining the upstream BSD 2-Clause license and copyright notice.
- Multi-instance AmneziaWG client support using the shared `awg0`–`awg99` namespace.
- Native `.conf` import, key generation, AWG 2.0 obfuscation/CPS fields, diagnostics, watchdog/sentinel handling and OPNsense selective-routing integration.
- Native AmneziaWG Server instances and multiple Server Peers.
- Server Peer client provisioning with generated client keypair/PSK, protected private-key storage, native `.conf` export and multipart QR import for AmneziaVPN.
- Shared client/server interface-number validation to prevent `awgN` namespace collisions.
- Per-instance Start / Stop / Restart and runtime status handling for both client and server instances.
- Differential Apply/Reconfigure: unchanged live tunnels remain untouched; changed tunnels are restarted individually; failed changed-config restarts attempt rollback to the previous canonical config.
- Persistent plugin-owned canonical configs under `/usr/local/etc/amnezia/awgN.conf`, written atomically and protected against unmanaged-interface takeover.
- Granular watchdog recovery for managed client/server interfaces.
- Protected client, server and provisioned-peer private keys stored outside `config.xml`.
- Hardened installer with repository-state verification, isolated command-scoped FreeBSD quarterly repository access, package-lock preservation and guarded `amnezia-tools` / `amnezia-kmod` update paths.
- Local rollback packages for AWG package replacement and capture/restore of the exact live managed interface set during kernel-module transactions.
- Safe uninstall flow with independent choices for AWG package removal and configuration/private-key purge.
- OPNsense 27.x / FreeBSD 15.x as the primary target platform.
