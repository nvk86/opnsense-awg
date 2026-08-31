#!/bin/sh
# AmneziaWG OPNsense Plugin Installer
# Obfuscated WireGuard (bypass DPI) for OPNsense 26.7.x / FreeBSD 15.1
#
# Usage:
#   sh install.sh            — install
#   sh install.sh uninstall  — remove

set -e
set -u

PLUGIN_VERSION="1.0.0"
PLUGIN_DIR="$(dirname "$0")/plugin"
VERSION_FILE="/usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/version.txt"
AWG_BIN="/usr/local/bin/awg"
AWG_QUICK="/usr/local/bin/awg-quick"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "uninstall" ]; then
    echo "==> Stopping AmneziaWG..."
    if [ -x /usr/local/opnsense/scripts/AmneziaWG/amneziawg-service-control.php ]; then
        _STOP_OUT=$(/usr/local/opnsense/scripts/AmneziaWG/amneziawg-service-control.php stop 2>&1 || true)
        printf '%s\n' "$_STOP_OUT"
        if echo "$_STOP_OUT" | grep -Eqi '(^|[[:space:]])ERROR:'; then
            die "AmneziaWG teardown was not confirmed. Refusing uninstall while a plugin-owned tunnel may still be live."
        fi
        if ! echo "$_STOP_OUT" | grep -Eq '(^|[[:space:]])OK($|[[:space:]])'; then
            die "Unexpected Stop response. Refusing uninstall until tunnel state is verified."
        fi
    else
        warn "Service-control script is missing; checking for plugin-owned live interfaces."
        _LIVE_OWNED=0
        for _CONF in /usr/local/etc/amnezia/awg*.conf; do
            [ -f "$_CONF" ] || continue
            _IFACE=$(basename "$_CONF" .conf)
            if /sbin/ifconfig "$_IFACE" >/dev/null 2>&1; then
                warn "Live plugin-owned interface detected: $_IFACE"
                _LIVE_OWNED=1
            fi
        done
        [ "$_LIVE_OWNED" = "0" ] || die "Cannot safely uninstall without service-control while plugin-owned interfaces are live."
    fi

    # Offer to remove amnezia packages. Keep any user-managed package lock
    # intact when the packages themselves are retained.
    if pkg info amnezia-kmod >/dev/null 2>&1 || pkg info amnezia-tools >/dev/null 2>&1; then
        echo ""
        printf "  Remove amnezia-kmod and amnezia-tools packages? [y/N] "
        read -r _RP < /dev/tty 2>/dev/null || _RP="n"
        case "$_RP" in
            [yY]*)
                pkg unlock -qy amnezia-kmod 2>/dev/null || true
                pkg delete -y amnezia-tools 2>/dev/null || true
                pkg delete -y amnezia-kmod 2>/dev/null || true
                sed -i '' '/^if_amn_load/d' /boot/loader.conf 2>/dev/null || true
                echo "[OK]  Packages removed"
                ;;
            *) echo "  Keeping packages." ;;
        esac
        echo ""
    fi

    echo ""
    printf "  Purge saved AmneziaWG configuration and private keys too? [y/N] "
    read -r _PURGE < /dev/tty 2>/dev/null || _PURGE="n"
    PURGE_DATA=0
    case "$_PURGE" in [yY]*) PURGE_DATA=1 ;; esac

    if [ "$PURGE_DATA" = "1" ] && [ -x /usr/local/bin/php ]; then
        /usr/local/bin/php -r '
            set_include_path("/usr/local/etc/inc" . PATH_SEPARATOR . get_include_path());
            require_once("config.inc");
            $cfg = OPNsense\Core\Config::getInstance();
            $obj = $cfg->object();
            if (isset($obj->OPNsense->amneziawg)) {
                unset($obj->OPNsense->amneziawg);
                $cfg->save(["description" => "Purge AmneziaWG configuration"]);
            }
        ' || warn "Could not purge AmneziaWG config.xml node"
    fi

    echo "==> Removing plugin files..."
    rm -f  /usr/local/opnsense/scripts/AmneziaWG/amneziawg-service-control.php
    rm -f  /usr/local/opnsense/scripts/AmneziaWG/amneziawg-ifstats.php
    rm -f  /usr/local/opnsense/scripts/AmneziaWG/amneziawg-testconnect.php
    rm -f  /usr/local/opnsense/scripts/AmneziaWG/amneziawg-watchdog.php
    rmdir  /usr/local/opnsense/scripts/AmneziaWG 2>/dev/null || true
    rm -f  /usr/local/opnsense/service/conf/actions.d/actions_amneziawg.conf
    rm -rf /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG  # includes version.txt
    # Canonical awgN.conf files are plugin-owned derived state.
    rm -f /usr/local/etc/amnezia/awg*.conf 2>/dev/null || true
    rm -rf /usr/local/etc/amnezia/runtime 2>/dev/null || true
    if [ "$PURGE_DATA" = "1" ]; then
        rm -f /usr/local/etc/amnezia/private.key
        rm -f /usr/local/etc/amnezia/*.key
        rmdir /usr/local/etc/amnezia 2>/dev/null || true
        echo "[OK]  Saved configuration and private keys purged"
    else
        echo "[OK]  Saved config.xml data and private key files preserved for reinstall"
    fi
    rm -rf /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG
    rm -rf /usr/local/opnsense/mvc/app/views/OPNsense/AmneziaWG
    rm -f  /usr/local/etc/inc/plugins.inc.d/amneziawg.inc
    rm -f  /etc/newsyslog.conf.d/amneziawg.conf
    rm -f  /usr/local/etc/rc.syshook.d/start/50-amneziawg
    rm -f  /var/run/amneziawg_stopped.flag
    rm -f  /var/run/amneziawg_stopped_awg*.flag
    rm -f  /var/run/amneziawg.pid
    rm -f  /var/run/amneziawg.lock

    echo "==> Restarting configd..."
    service configd restart

    echo "==> Clearing cache..."
    rm -f /var/lib/php/tmp/opnsense_menu_cache.xml

    echo ""
    echo "=============================="
    echo "  AmneziaWG plugin removed."
    echo "=============================="
    echo "Refresh browser with Ctrl+F5."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# VERSION CHECK & CONFIRMATION
# ─────────────────────────────────────────────────────────────────────────────
CURRENT_VERSION="not installed"
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
fi

echo "============================================================"
echo "  opnsense-awg plugin installer"
echo "============================================================"
echo ""
echo "  Current version : ${CURRENT_VERSION}"
echo "  New version     : ${PLUGIN_VERSION}"
echo ""

if [ "$CURRENT_VERSION" = "$PLUGIN_VERSION" ]; then
    echo "  Version ${PLUGIN_VERSION} is already installed."
    printf "  Reinstall? [y/N] "
    read -r _CONFIRM < /dev/tty 2>/dev/null || _CONFIRM="n"
    case "$_CONFIRM" in
        [yY]*) ;;
        *) echo "  Installation cancelled."; exit 0 ;;
    esac
elif [ "$CURRENT_VERSION" != "not installed" ]; then
    printf "  Upgrade from ${CURRENT_VERSION} to ${PLUGIN_VERSION}? [Y/n] "
    read -r _CONFIRM < /dev/tty 2>/dev/null || _CONFIRM="y"
    case "$_CONFIRM" in
        [nN]*) echo "  Installation cancelled."; exit 0 ;;
        *) ;;
    esac
else
    printf "  Install version ${PLUGIN_VERSION}? [Y/n] "
    read -r _CONFIRM < /dev/tty 2>/dev/null || _CONFIRM="y"
    case "$_CONFIRM" in
        [nN]*) echo "  Installation cancelled."; exit 0 ;;
        *) ;;
    esac
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# FreeBSD QUARTERLY REPO HELPER
#
# IMPORTANT: never edit OPNsense.conf or FreeBSD.conf. OPNsense deliberately
# disables the base FreeBSD repositories in /usr/local/etc/pkg/repos.
# FreeBSD quarterly is exposed only through a command-scoped temporary
# REPOS_DIR under /tmp; default OPNsense pkg invocations never see it.
# We still verify the original repository state byte-for-byte afterwards.
# ─────────────────────────────────────────────────────────────────────────────
OPNSENSE_REPO_CONF="/usr/local/etc/pkg/repos/OPNsense.conf"
FREEBSD_DISABLE_CONF="/usr/local/etc/pkg/repos/FreeBSD.conf"
FREEBSD_REPO_CREATED=0
PKG_LOCKED_BY_US=0
REPO_SNAPSHOT_DIR="$(mktemp -d /tmp/amneziawg-installer.XXXXXX)"
FREEBSD_REPO_DIR="$REPO_SNAPSHOT_DIR/freebsd-repo"
FREEBSD_REPO_CONF="$FREEBSD_REPO_DIR/FreeBSD-quarterly.conf"
ROLLBACK_DIR="$(mktemp -d /tmp/amneziawg-rollback.XXXXXX)"
chmod 0700 "$REPO_SNAPSHOT_DIR" "$ROLLBACK_DIR"
INSTALL_STARTED=0
INSTALL_COMMITTED=0
ENSURE_IF_AMN_LOADER=0
DRYRUN_LOCK_PACKAGE=""
DRYRUN_LOCK_WAS=""

TOOLS_TXN_ACTIVE=0
TOOLS_TXN_DIR=""
TOOLS_ROLLBACK_FAILED=0
TOOLS_LIVE_IFACES=""

KMOD_TXN_ACTIVE=0
KMOD_TXN_DIR=""
KMOD_LIVE_IFACES=""
KMOD_ROLLBACK_FAILED=0
KMOD_STOPPED_FLAG_WAS_PRESENT=0


snapshot_file() {
    _src="$1"
    _name="$2"
    if [ -f "$_src" ]; then
        cp -p "$_src" "$REPO_SNAPSHOT_DIR/$_name"
        echo "present" > "$REPO_SNAPSHOT_DIR/${_name}.state"
    else
        echo "absent" > "$REPO_SNAPSHOT_DIR/${_name}.state"
    fi
}

file_matches_snapshot() {
    _src="$1"
    _name="$2"
    _state=$(cat "$REPO_SNAPSHOT_DIR/${_name}.state" 2>/dev/null || echo "unknown")
    case "$_state" in
        present)
            [ -f "$_src" ] && cmp -s "$_src" "$REPO_SNAPSHOT_DIR/$_name"
            ;;
        absent)
            [ ! -e "$_src" ]
            ;;
        *)
            return 1
            ;;
    esac
}

restore_freebsd_catalog_state() {
    # pkg stores repository catalogues in PKG_DBDIR even when REPOS_DIR is
    # command-scoped. Restore this repo catalogue set exactly to its baseline.
    rm -f /var/db/pkg/repo-FreeBSD-quarterly.sqlite* 2>/dev/null || true
    for _CAT in "$REPO_SNAPSHOT_DIR"/freebsd-catalog-before/*; do
        [ -e "$_CAT" ] || continue
        cp -p "$_CAT" /var/db/pkg/
    done
}

setup_freebsd_repo() {
    rm -rf "$FREEBSD_REPO_DIR"
    mkdir -p "$FREEBSD_REPO_DIR"
    cat > "$FREEBSD_REPO_CONF" << 'REPOEOF'
FreeBSD-quarterly: {
    url: "pkg+https://pkg.FreeBSD.org/${ABI}/quarterly",
    mirror_type: "srv",
    signature_type: "fingerprints",
    fingerprints: "/usr/share/keys/pkg",
    enabled: yes
}
REPOEOF
    chmod 0600 "$FREEBSD_REPO_CONF"
    FREEBSD_REPO_CREATED=1
    echo "[OK]  Isolated FreeBSD quarterly repo configured in temporary REPOS_DIR"
}

pkg_freebsd() {
    # Command-scoped repository path: default OPNsense pkg invocations never
    # see this repository, even if this installer is killed unexpectedly.
    pkg -o REPOS_DIR="$FREEBSD_REPO_DIR" "$@"
}

cleanup_freebsd_repo() {
    if [ "$FREEBSD_REPO_CREATED" = "1" ]; then
        rm -rf "$FREEBSD_REPO_DIR"
        restore_freebsd_catalog_state
        FREEBSD_REPO_CREATED=0
        echo "[OK]  Isolated FreeBSD repository workspace/catalogue state restored"
    fi
}

backup_path() {
    _src="$1"
    _dst="$ROLLBACK_DIR/${_src#/}"
    if [ -e "$_src" ]; then
        mkdir -p "$(dirname "$_dst")"
        cp -Rp "$_src" "$_dst"
    fi
}

prepare_plugin_rollback() {
    echo "==> Creating rollback snapshot of installed AmneziaWG plugin..."
    backup_path /usr/local/opnsense/scripts/AmneziaWG
    backup_path /usr/local/opnsense/service/conf/actions.d/actions_amneziawg.conf
    backup_path /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG
    backup_path /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG
    backup_path /usr/local/opnsense/mvc/app/views/OPNsense/AmneziaWG
    backup_path /usr/local/etc/inc/plugins.inc.d/amneziawg.inc
    backup_path /etc/newsyslog.conf.d/amneziawg.conf
    backup_path /usr/local/etc/rc.syshook.d/start/50-amneziawg
    backup_path /usr/local/etc/amnezia
    backup_path /boot/loader.conf
    backup_path /conf/config.xml
    INSTALL_STARTED=1
    echo "[OK]  Rollback snapshot ready"
}

restore_path() {
    _dst="$1"
    _src="$ROLLBACK_DIR/${_dst#/}"
    rm -rf "$_dst"
    if [ -e "$_src" ]; then
        mkdir -p "$(dirname "$_dst")"
        cp -Rp "$_src" "$_dst"
    fi
}

rollback_plugin_install() {
    warn "Installation did not commit; restoring previous AmneziaWG plugin state."
    restore_path /usr/local/opnsense/scripts/AmneziaWG
    restore_path /usr/local/opnsense/service/conf/actions.d/actions_amneziawg.conf
    restore_path /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG
    restore_path /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG
    restore_path /usr/local/opnsense/mvc/app/views/OPNsense/AmneziaWG
    restore_path /usr/local/etc/inc/plugins.inc.d/amneziawg.inc
    restore_path /etc/newsyslog.conf.d/amneziawg.conf
    restore_path /usr/local/etc/rc.syshook.d/start/50-amneziawg
    restore_path /usr/local/etc/amnezia
    restore_path /boot/loader.conf
    restore_path /conf/config.xml
    rm -f /var/lib/php/tmp/opnsense_menu_cache.xml 2>/dev/null || true
    service configd restart >/dev/null 2>&1 || warn "Rollback restored files but configd restart failed; restart configd manually."
    warn "Previous plugin files/config restored."
}

installer_cleanup() {
    # A signal may arrive while a package lock is temporarily lifted for a
    # read-only dry-run. Restore that exact pre-dry-run state first.
    if [ -n "${DRYRUN_LOCK_PACKAGE:-}" ]; then
        _dry_pkg="$DRYRUN_LOCK_PACKAGE"
        _dry_was="${DRYRUN_LOCK_WAS:-0}"
        _dry_now=$(pkg query '%k' "$_dry_pkg" 2>/dev/null || echo "unknown")
        if [ "$_dry_was" = "1" ] && [ "$_dry_now" != "1" ]; then
            pkg lock -qy "$_dry_pkg" >/dev/null 2>&1 || \
                warn "CRITICAL: cleanup could not restore lock on $_dry_pkg after interrupted dry-run."
        elif [ "$_dry_was" = "0" ] && [ "$_dry_now" = "1" ]; then
            pkg unlock -qy "$_dry_pkg" >/dev/null 2>&1 || \
                warn "CRITICAL: cleanup could not restore unlocked state on $_dry_pkg after interrupted dry-run."
        fi
        DRYRUN_LOCK_PACKAGE=""
        DRYRUN_LOCK_WAS=""
    fi

    # Userspace tools transaction is independently rollback-protected.
    if [ "${TOOLS_TXN_ACTIVE:-0}" = "1" ]; then
        warn "Installer interrupted during amnezia-tools transaction; attempting automatic rollback."
        if tools_rollback_old_package; then
            TOOLS_TXN_ACTIVE=0
        else
            TOOLS_ROLLBACK_FAILED=1
            warn "CRITICAL: automatic amnezia-tools rollback was incomplete. Preserving $TOOLS_TXN_DIR for manual recovery."
        fi
    fi

    # If interrupted while the kernel-module transaction owns the machine
    # state, restore the locally backed-up old package and exact live tunnel set.
    if [ "${KMOD_TXN_ACTIVE:-0}" = "1" ]; then
        warn "Installer interrupted during amnezia-kmod transaction; attempting automatic rollback."
        if kmod_rollback_old_package; then
            KMOD_TXN_ACTIVE=0
        else
            KMOD_ROLLBACK_FAILED=1
            warn "CRITICAL: automatic amnezia-kmod rollback was incomplete. Preserving $KMOD_TXN_DIR for manual recovery."
        fi
    fi

    # Only undo transient state created by this installer.
    if [ "${FREEBSD_REPO_CREATED:-0}" = "1" ]; then
        cleanup_freebsd_repo >/dev/null 2>&1 || true
    fi
    if [ "${PKG_LOCKED_BY_US:-0}" = "1" ]; then
        pkg unlock -qy pkg >/dev/null 2>&1 || true
        PKG_LOCKED_BY_US=0
    fi

    if [ "${INSTALL_STARTED:-0}" = "1" ] && [ "${INSTALL_COMMITTED:-0}" != "1" ]; then
        rollback_plugin_install
        INSTALL_STARTED=0
    fi

    if [ -n "${REPO_SNAPSHOT_DIR:-}" ] && [ -d "$REPO_SNAPSHOT_DIR" ]; then
        rm -rf "$REPO_SNAPSHOT_DIR"
    fi
    if [ -n "${ROLLBACK_DIR:-}" ] && [ -d "$ROLLBACK_DIR" ]; then
        rm -rf "$ROLLBACK_DIR"
    fi
    if [ "${KMOD_ROLLBACK_FAILED:-0}" != "1" ] && [ -n "${KMOD_TXN_DIR:-}" ] && [ -d "$KMOD_TXN_DIR" ]; then
        rm -rf "$KMOD_TXN_DIR"
    fi
    if [ "${TOOLS_ROLLBACK_FAILED:-0}" != "1" ] && [ -n "${TOOLS_TXN_DIR:-}" ] && [ -d "$TOOLS_TXN_DIR" ]; then
        rm -rf "$TOOLS_TXN_DIR"
    fi
}
trap installer_cleanup EXIT
trap 'installer_cleanup; trap - EXIT; exit 129' HUP
trap 'installer_cleanup; trap - EXIT; exit 130' INT
trap 'installer_cleanup; trap - EXIT; exit 143' TERM

# Capture and validate the production repository baseline only after cleanup traps are active.
# Snapshot exactly the files whose state must not change.
snapshot_file "$OPNSENSE_REPO_CONF" "OPNsense.conf"
snapshot_file "$FREEBSD_DISABLE_CONF" "FreeBSD.conf"

PKG_WAS_LOCKED=$(pkg query '%k' pkg 2>/dev/null || echo "0")
KMOD_WAS_LOCKED=$(pkg query '%k' amnezia-kmod 2>/dev/null || echo "0")
TOOLS_WAS_LOCKED=$(pkg query '%k' amnezia-tools 2>/dev/null || echo "0")
PKG_VERSION_BEFORE=$(pkg query '%v' pkg 2>/dev/null || echo "")
PKG_REPO_BEFORE=$(pkg query '%R' pkg 2>/dev/null || echo "")
OPNSENSE_VERSION_BEFORE=$(pkg query '%v' opnsense 2>/dev/null || echo "")
OPNSENSE_REPO_BEFORE=$(pkg query '%R' opnsense 2>/dev/null || echo "")

# Snapshot effective repository state too (including pkg(8) enable/disable
# overrides under /var/db/pkg/repos_state, not only config files).
pkg repositories -e -l 2>/dev/null | sort > "$REPO_SNAPSHOT_DIR/repos.enabled"
pkg repositories -d -l 2>/dev/null | sort > "$REPO_SNAPSHOT_DIR/repos.disabled"
pkg repositories -l 2>/dev/null | sort > "$REPO_SNAPSHOT_DIR/repos.all"

mkdir -p "$REPO_SNAPSHOT_DIR/freebsd-catalog-before"
for _CAT in /var/db/pkg/repo-FreeBSD-quarterly.sqlite*; do
    [ -e "$_CAT" ] || continue
    cp -p "$_CAT" "$REPO_SNAPSHOT_DIR/freebsd-catalog-before/"
done

if grep -qx 'FreeBSD-quarterly' "$REPO_SNAPSHOT_DIR/repos.all"; then
    die "A repository named FreeBSD-quarterly already exists. Refusing to reuse or alter a repository not owned by this installer."
fi

# Production precondition: OPNsense must be the active firmware/package repo,
# and no FreeBSD* repository may already be enabled. If the box is already in
# a non-standard repository state, do not try to "fix" it automatically.
if ! grep -qx 'OPNsense' "$REPO_SNAPSHOT_DIR/repos.enabled"; then
    die "OPNsense repository is not enabled. Refusing installation on a non-standard repository state."
fi
if grep -Eq '^FreeBSD' "$REPO_SNAPSHOT_DIR/repos.enabled"; then
    die "A FreeBSD repository is already enabled before installation. Restore standard OPNsense repository state first."
fi


verify_pkg_repo_state() {
    echo "==> Verifying package repository state..."

    [ ! -e "$FREEBSD_REPO_DIR" ] || die "Temporary FreeBSD repository workspace was not removed: $FREEBSD_REPO_DIR"
    _CAT_NOW="$(mktemp -d "$REPO_SNAPSHOT_DIR/catalog-now.XXXXXX")"
    for _CAT in /var/db/pkg/repo-FreeBSD-quarterly.sqlite*; do
        [ -e "$_CAT" ] || continue
        cp -p "$_CAT" "$_CAT_NOW/"
    done
    diff -qr "$REPO_SNAPSHOT_DIR/freebsd-catalog-before" "$_CAT_NOW" >/dev/null 2>&1 || \
        die "FreeBSD-quarterly package catalogue state differs from pre-install baseline."
    rm -rf "$_CAT_NOW"
    file_matches_snapshot "$OPNSENSE_REPO_CONF" "OPNsense.conf" || \
        die "OPNsense.conf changed during installation; refusing to continue."
    file_matches_snapshot "$FREEBSD_DISABLE_CONF" "FreeBSD.conf" || \
        die "FreeBSD.conf changed during installation; refusing to continue."

    _pkg_locked_now=$(pkg query '%k' pkg 2>/dev/null || echo "0")
    [ "$_pkg_locked_now" = "$PKG_WAS_LOCKED" ] || \
        die "pkg lock state changed unexpectedly (was $PKG_WAS_LOCKED, now $_pkg_locked_now)."

    _kmod_locked_now=$(pkg query '%k' amnezia-kmod 2>/dev/null || echo "0")
    [ "$_kmod_locked_now" = "$KMOD_WAS_LOCKED" ] || \
        die "amnezia-kmod lock state changed unexpectedly (expected $KMOD_WAS_LOCKED, now $_kmod_locked_now)."

    _tools_locked_now=$(pkg query '%k' amnezia-tools 2>/dev/null || echo "0")
    [ "$_tools_locked_now" = "$TOOLS_WAS_LOCKED" ] || \
        die "amnezia-tools lock state changed unexpectedly (expected $TOOLS_WAS_LOCKED, now $_tools_locked_now)."

    _pkg_ver_now=$(pkg query '%v' pkg 2>/dev/null || echo "")
    _pkg_repo_now=$(pkg query '%R' pkg 2>/dev/null || echo "")
    _opnsense_ver_now=$(pkg query '%v' opnsense 2>/dev/null || echo "")
    _opnsense_repo_now=$(pkg query '%R' opnsense 2>/dev/null || echo "")
    [ "$_pkg_ver_now" = "$PKG_VERSION_BEFORE" ] || \
        die "pkg version changed during installation (${PKG_VERSION_BEFORE} -> ${_pkg_ver_now})."
    [ "$_pkg_repo_now" = "$PKG_REPO_BEFORE" ] || \
        die "pkg repository origin changed during installation (${PKG_REPO_BEFORE} -> ${_pkg_repo_now})."
    [ "$_opnsense_ver_now" = "$OPNSENSE_VERSION_BEFORE" ] || \
        die "OPNsense core package version changed unexpectedly during installation."
    [ "$_opnsense_repo_now" = "$OPNSENSE_REPO_BEFORE" ] || \
        die "OPNsense core package repository origin changed unexpectedly during installation."

    pkg repositories -e -l 2>/dev/null | sort > "$REPO_SNAPSHOT_DIR/repos.enabled.now"
    pkg repositories -d -l 2>/dev/null | sort > "$REPO_SNAPSHOT_DIR/repos.disabled.now"
    pkg repositories -l 2>/dev/null | sort > "$REPO_SNAPSHOT_DIR/repos.all.now"
    cmp -s "$REPO_SNAPSHOT_DIR/repos.enabled" "$REPO_SNAPSHOT_DIR/repos.enabled.now" || \
        die "Effective ENABLED repository set changed during installation."
    cmp -s "$REPO_SNAPSHOT_DIR/repos.disabled" "$REPO_SNAPSHOT_DIR/repos.disabled.now" || \
        die "Effective DISABLED repository set changed during installation."
    cmp -s "$REPO_SNAPSHOT_DIR/repos.all" "$REPO_SNAPSHOT_DIR/repos.all.now" || \
        die "Configured repository set changed during installation."

    grep -qx 'OPNsense' "$REPO_SNAPSHOT_DIR/repos.enabled.now" || \
        die "OPNsense repository is not enabled after cleanup."
    if grep -Eq '^FreeBSD' "$REPO_SNAPSHOT_DIR/repos.enabled.now"; then
        die "A FreeBSD repository remains enabled after cleanup."
    fi

    # This checks the actual repository path/configuration without installing
    # or upgrading any package. A broken OPNsense repository must stop the
    # installer before plugin files/configd are modified.
    if ! pkg update -r OPNsense >/dev/null 2>&1; then
        die "OPNsense repository verification failed. No plugin files will be changed."
    fi

    echo "[OK]  OPNsense repository reachable"
    echo "[OK]  OPNsense.conf unchanged"
    echo "[OK]  FreeBSD.conf unchanged"
    echo "[OK]  Temporary FreeBSD repository absent"
    echo "[OK]  pkg, amnezia-kmod and amnezia-tools lock states restored"
    echo "[OK]  pkg and OPNsense core package version/origin unchanged"
    echo "[OK]  Effective enabled/disabled repository sets restored exactly"
}

# pkg 2.3.1_1 on current OPNsense returns rc=1 for a valid `pkg install -n`
# transaction. Therefore dry-run success must be proven from the transaction
# plan itself, not from rc alone. A pre-existing package lock is lifted only
# around the read-only dry-run and restored immediately afterwards.
pkg_dry_run_single_package() {
    _pkgname="$1"
    _repo="$2"

    PKG_DRY_OUT=""
    PKG_DRY_RC=255

    _lock_before=$(pkg query '%k' "$_pkgname" 2>/dev/null || echo "unknown")
    case "$_lock_before" in
        0|1) ;;
        *)
            warn "Could not determine lock state for $_pkgname before dry-run."
            return 1
            ;;
    esac

    DRYRUN_LOCK_PACKAGE="$_pkgname"
    DRYRUN_LOCK_WAS="$_lock_before"

    if [ "$_lock_before" = "1" ]; then
        if ! pkg unlock -qy "$_pkgname" >/dev/null 2>&1; then
            DRYRUN_LOCK_PACKAGE=""
            DRYRUN_LOCK_WAS=""
            warn "Could not temporarily unlock $_pkgname for dry-run."
            return 1
        fi
    fi

    PKG_DRY_OUT=$(pkg_freebsd install -n -r "$_repo" "$_pkgname" 2>&1)
    PKG_DRY_RC=$?

    # Restore the exact pre-dry-run lock state before interpreting the plan.
    _lock_after=$(pkg query '%k' "$_pkgname" 2>/dev/null || echo "unknown")
    if [ "$_lock_before" = "1" ]; then
        if [ "$_lock_after" != "1" ]; then
            if ! pkg lock -qy "$_pkgname" >/dev/null 2>&1; then
                warn "CRITICAL: failed to restore $_pkgname lock after dry-run."
                return 1
            fi
        fi
    else
        if [ "$_lock_after" = "1" ]; then
            if ! pkg unlock -qy "$_pkgname" >/dev/null 2>&1; then
                warn "CRITICAL: $_pkgname became locked during dry-run and could not be restored."
                return 1
            fi
        fi
    fi

    _lock_final=$(pkg query '%k' "$_pkgname" 2>/dev/null || echo "unknown")
    if [ "$_lock_final" != "$_lock_before" ]; then
        warn "CRITICAL: $_pkgname lock state differs after dry-run (was $_lock_before, now $_lock_final)."
        return 1
    fi

    DRYRUN_LOCK_PACKAGE=""
    DRYRUN_LOCK_WAS=""

    # rc=1 is a confirmed normal result for a valid dry-run on pkg 2.3.1_1.
    # Any other non-zero code is still rejected.
    case "$PKG_DRY_RC" in
        0|1) ;;
        *)
            warn "pkg dry-run returned unexpected rc=$PKG_DRY_RC for $_pkgname."
            printf '%s\n' "$PKG_DRY_OUT" >&2
            return 1
            ;;
    esac

    # Require a real transaction summary. This prevents a warning/error that
    # merely mentions the package name from being mistaken for a valid plan.
    if ! printf '%s\n' "$PKG_DRY_OUT" | grep -Eq '^The following [0-9]+ package\(s\) will be affected'; then
        warn "pkg dry-run did not produce a transaction summary for $_pkgname."
        printf '%s\n' "$PKG_DRY_OUT" >&2
        return 1
    fi

    _names=$(printf '%s\n' "$PKG_DRY_OUT" |
        sed -nE 's/^[[:space:]]+([A-Za-z0-9][A-Za-z0-9_.+-]*):.*/\1/p' |
        sort -u)
    if [ "$_names" != "$_pkgname" ]; then
        warn "pkg dry-run scope is not exactly $_pkgname."
        printf '%s\n' "$PKG_DRY_OUT" >&2
        return 1
    fi

    _ops=$(printf '%s\n' "$PKG_DRY_OUT" |
        sed -nE 's/^Number of packages to be (upgraded|installed|reinstalled):[[:space:]]*([0-9]+).*$/\2/p' |
        awk '{s += $1} END {print s + 0}')
    if [ "$_ops" != "1" ]; then
        warn "pkg dry-run did not prove exactly one package operation for $_pkgname."
        printf '%s\n' "$PKG_DRY_OUT" >&2
        return 1
    fi

    return 0
}

# Check if amnezia-kmod ABI matches the running kernel (prevents kernel panics)
check_kernel_compat() {
    KERN_VER=$(uname -r)
    KERN_OSVERSION=$(uname -K 2>/dev/null || echo "")
    PKG_KMOD_VER=$(pkg_freebsd rquery -r FreeBSD-quarterly '%v' amnezia-kmod 2>/dev/null | head -n 1 || true)

    if [ -z "$PKG_KMOD_VER" ]; then
        warn "Could not query amnezia-kmod from FreeBSD-quarterly."
        return 1
    fi

    # FreeBSD kmod package versions carry the __FreeBSD_version they were
    # built for, e.g. amnezia-kmod-2.0.11.1500068.
    PKG_OSVERSION=$(echo "$PKG_KMOD_VER" | sed -nE 's/.*\.([0-9]{7})(_[0-9]+)?$/\1/p')
    if [ -n "$KERN_OSVERSION" ] && [ -n "$PKG_OSVERSION" ] && [ "$KERN_OSVERSION" != "$PKG_OSVERSION" ]; then
        # The package suffix is the build __FreeBSD_version, not a Linux-style
        # exact vermagic. A different suffix is therefore a warning, not proof
        # of incompatibility (the currently working module may legitimately
        # have been built against an earlier compatible 15.x kernel ABI).
        warn "KMOD BUILD VERSION DIFFERS FROM RUNNING KERNEL"
        warn "Running kernel: ${KERN_VER} (__FreeBSD_version=${KERN_OSVERSION})"
        warn "Repository kmod: amnezia-kmod-${PKG_KMOD_VER} (built for ${PKG_OSVERSION})"
        warn "Continuing only if pkg dry-run accepts the transaction; actual kldload is verified with rollback."
    fi

    if ! pkg_dry_run_single_package amnezia-kmod FreeBSD-quarterly; then
        warn "pkg dry-run transaction for amnezia-kmod could not be proven safe."
        return 1
    fi
    DRY_OUT="$PKG_DRY_OUT"
    if echo "$DRY_OUT" | grep -Eqi "ABI.*change|wrong ABI|incompatible|not compatible|FreeBSD_version"; then
        warn "pkg dry-run reports kernel/package incompatibility."
        warn "Running kernel: FreeBSD $KERN_VER"
        return 1
    fi

    echo "[OK]  amnezia-kmod candidate passed package compatibility dry-run"
    return 0
}


restore_tools_lock_state() {
    _now=$(pkg query '%k' amnezia-tools 2>/dev/null || echo "0")
    if [ "$TOOLS_WAS_LOCKED" = "1" ]; then
        if [ "$_now" != "1" ]; then
            pkg lock -qy amnezia-tools >/dev/null 2>&1 || return 1
        fi
    else
        if [ "$_now" = "1" ]; then
            pkg unlock -qy amnezia-tools >/dev/null 2>&1 || return 1
        fi
    fi
    return 0
}

tools_capture_live_ifaces() {
    TOOLS_LIVE_IFACES=""
    _ifaces=$(AWG_COLOR_MODE=never "$AWG_BIN" show interfaces 2>/dev/null || true)
    for _iface in $_ifaces; do
        case "$_iface" in
            awg[0-9]|awg[0-9][0-9]) ;;
            *) die "Unexpected AmneziaWG interface token during tools transaction: $_iface" ;;
        esac
        TOOLS_LIVE_IFACES="${TOOLS_LIVE_IFACES}${TOOLS_LIVE_IFACES:+ }${_iface}"
    done
}

tools_verify_userspace() {
    [ -x "$AWG_BIN" ] || return 1
    [ -x "$AWG_QUICK" ] || return 1
    "$AWG_BIN" --version >/dev/null 2>&1 || return 1

    for _iface in $TOOLS_LIVE_IFACES; do
        /sbin/ifconfig "$_iface" >/dev/null 2>&1 || return 1
        "$AWG_BIN" show "$_iface" >/dev/null 2>&1 || return 1
    done

    if [ -f /usr/local/opnsense/service/conf/actions.d/actions_amneziawg.conf ]; then
        _validate=$(/usr/local/sbin/configctl amneziawg validate 2>&1 || true)
        printf '%s\n' "$_validate" | grep -Eq '^OK([[:space:]]|$)' || return 1
    fi
    return 0
}

tools_rollback_old_package() {
    warn "Rolling back amnezia-tools to the pre-upgrade package."
    _oldpkg=$(find "$TOOLS_TXN_DIR/pkg" -type f -name 'amnezia-tools-*.pkg' -print 2>/dev/null | head -n 1)
    if [ -z "$_oldpkg" ]; then
        warn "CRITICAL: old amnezia-tools rollback package is missing: $TOOLS_TXN_DIR/pkg"
        return 1
    fi

    pkg unlock -qy amnezia-tools >/dev/null 2>&1 || true
    if ! pkg add -f "$_oldpkg" >/dev/null 2>&1; then
        warn "CRITICAL: failed to reinstall old amnezia-tools package from $_oldpkg"
        return 1
    fi

    if ! restore_tools_lock_state; then
        warn "CRITICAL: old tools restored but original amnezia-tools lock state could not be restored."
        return 1
    fi

    if ! tools_verify_userspace; then
        warn "CRITICAL: old amnezia-tools package was restored but userspace verification failed."
        return 1
    fi
    return 0
}

tools_abort_with_rollback() {
    _reason="$1"
    if tools_rollback_old_package; then
        echo "[OK]  Previous amnezia-tools package restored"
    else
        TOOLS_ROLLBACK_FAILED=1
        warn "CRITICAL: automatic amnezia-tools rollback was incomplete. Recovery files preserved in $TOOLS_TXN_DIR"
    fi
    TOOLS_TXN_ACTIVE=0
    cleanup_freebsd_repo
    die "$_reason"
}

tools_dry_run_scope_ok() {
    _out="$1"
    _names=$(printf '%s\n' "$_out" |
        sed -nE 's/^[[:space:]]+([A-Za-z0-9][A-Za-z0-9_.+-]*):.*/\1/p' |
        sort -u)
    [ -n "$_names" ] || return 1
    for _name in $_names; do
        [ "$_name" = "amnezia-tools" ] || return 1
    done
    return 0
}

maybe_upgrade_tools() {
    _installed=$(pkg query '%v' amnezia-tools 2>/dev/null || echo "")
    [ -n "$_installed" ] || return 0

    echo ""
    echo "==> Checking FreeBSD quarterly for amnezia-tools update..."
    setup_freebsd_repo
    if ! pkg_freebsd update -r FreeBSD-quarterly >/dev/null 2>&1; then
        cleanup_freebsd_repo
        warn "Could not refresh FreeBSD-quarterly; skipping optional amnezia-tools update check."
        return 0
    fi

    _candidate=$(pkg_freebsd rquery -r FreeBSD-quarterly '%v' amnezia-tools 2>/dev/null | head -n 1 || true)
    if [ -z "$_candidate" ]; then
        cleanup_freebsd_repo
        warn "No amnezia-tools candidate returned by FreeBSD-quarterly; continuing without tools update."
        return 0
    fi

    _cmp=$(pkg version -t "$_installed" "$_candidate" 2>/dev/null || echo "?")
    echo "  installed : ${_installed}"
    echo "  candidate : ${_candidate}"

    if [ "$_cmp" != "<" ]; then
        echo "[OK]  amnezia-tools is already current for this repository"
        cleanup_freebsd_repo
        return 0
    fi

    if ! pkg_dry_run_single_package amnezia-tools FreeBSD-quarterly; then
        cleanup_freebsd_repo
        die "amnezia-tools dry-run transaction could not be proven safe; refusing tools update."
    fi
    _dry="$PKG_DRY_OUT"
    echo "[OK]  Dry-run transaction is exactly one amnezia-tools operation (pkg rc=$PKG_DRY_RC)"

    printf "  Upgrade amnezia-tools ${_installed} -> ${_candidate} now? [y/N] "
    read -r _TU < /dev/tty 2>/dev/null || _TU="n"
    case "$_TU" in
        [yY]*) ;;
        *)
            echo "  Keeping installed amnezia-tools ${_installed}."
            cleanup_freebsd_repo
            return 0
            ;;
    esac

    TOOLS_TXN_DIR=$(mktemp -d /tmp/amneziawg-tools.XXXXXX)
    chmod 0700 "$TOOLS_TXN_DIR"
    install -d -m 0700 "$TOOLS_TXN_DIR/pkg"
    install -d -m 0700 "$TOOLS_TXN_DIR/new"

    echo "==> Creating local rollback package for amnezia-tools ${_installed}..."
    if ! pkg create -o "$TOOLS_TXN_DIR/pkg" amnezia-tools >/dev/null 2>&1; then
        cleanup_freebsd_repo
        die "Could not create local amnezia-tools rollback package; refusing tools update."
    fi
    _oldpkg=$(find "$TOOLS_TXN_DIR/pkg" -type f -name 'amnezia-tools-*.pkg' -print | head -n 1)
    [ -n "$_oldpkg" ] || {
        cleanup_freebsd_repo
        die "pkg create completed but amnezia-tools rollback package was not found."
    }

    echo "==> Fetching exact amnezia-tools candidate package..."
    if ! pkg_freebsd fetch -y -r FreeBSD-quarterly -o "$TOOLS_TXN_DIR/new" amnezia-tools >/dev/null 2>&1; then
        cleanup_freebsd_repo
        die "Could not fetch candidate amnezia-tools package; installed tools remain untouched."
    fi
    _newpkg=$(find "$TOOLS_TXN_DIR/new" -type f -name 'amnezia-tools-*.pkg' -print | head -n 1)
    [ -n "$_newpkg" ] || {
        cleanup_freebsd_repo
        die "Candidate fetch completed but amnezia-tools package file was not found."
    }
    _newmeta=$(pkg query -F "$_newpkg" '%n %v' 2>/dev/null || echo "")
    if [ "$_newmeta" != "amnezia-tools $_candidate" ]; then
        cleanup_freebsd_repo
        die "Fetched tools package manifest mismatch: '${_newmeta:-unreadable}', expected 'amnezia-tools $_candidate'."
    fi
    echo "[OK]  Candidate package manifest verified: $_newmeta"

    tools_capture_live_ifaces
    echo "  live tunnels to verify after userspace update: ${TOOLS_LIVE_IFACES:-none}"

    TOOLS_TXN_ACTIVE=1

    _tlock=$(pkg query '%k' amnezia-tools 2>/dev/null || echo "0")
    if [ "$_tlock" = "1" ]; then
        if ! pkg unlock -qy amnezia-tools >/dev/null 2>&1; then
            tools_abort_with_rollback "Could not temporarily unlock amnezia-tools."
        fi
    fi

    echo "==> Installing verified local amnezia-tools package only..."
    if ! pkg add -f "$_newpkg" >/dev/null 2>&1; then
        warn "Local amnezia-tools package transaction failed."
        tools_abort_with_rollback "amnezia-tools upgrade failed; installer stopped."
    fi

    _after=$(pkg query '%v' amnezia-tools 2>/dev/null || echo "")
    if [ "$_after" != "$_candidate" ]; then
        warn "Installed amnezia-tools version is '${_after}', expected '${_candidate}'."
        tools_abort_with_rollback "Unexpected amnezia-tools version after transaction."
    fi

    if ! tools_verify_userspace; then
        warn "New amnezia-tools failed userspace/live-interface/dry-run validation."
        tools_abort_with_rollback "New amnezia-tools failed verification."
    fi

    if ! restore_tools_lock_state; then
        warn "New tools work but original amnezia-tools lock state could not be restored."
        tools_abort_with_rollback "Could not restore amnezia-tools lock state."
    fi

    TOOLS_TXN_ACTIVE=0
    cleanup_freebsd_repo
    echo "[OK]  amnezia-tools upgraded ${_installed} -> ${_candidate}"
    echo "[OK]  userspace verification succeeded; live AWG interfaces remained up"

    rm -rf "$TOOLS_TXN_DIR"
    TOOLS_TXN_DIR=""
    return 0
}

restore_kmod_lock_state() {
    _now=$(pkg query '%k' amnezia-kmod 2>/dev/null || echo "0")
    if [ "$KMOD_WAS_LOCKED" = "1" ]; then
        if [ "$_now" != "1" ]; then
            pkg lock -qy amnezia-kmod >/dev/null 2>&1 || return 1
        fi
    else
        if [ "$_now" = "1" ]; then
            pkg unlock -qy amnezia-kmod >/dev/null 2>&1 || return 1
        fi
    fi
    return 0
}

kmod_capture_live_ifaces() {
    KMOD_LIVE_IFACES=""
    _ifaces=$(AWG_COLOR_MODE=never "$AWG_BIN" show interfaces 2>/dev/null || true)
    for _iface in $_ifaces; do
        case "$_iface" in
            awg[0-9]|awg[0-9][0-9]) ;;
            *) die "Unexpected AmneziaWG interface token during kmod transaction: $_iface" ;;
        esac
        _conf="/usr/local/etc/amnezia/${_iface}.conf"
        [ -f "$_conf" ] || die "Live $_iface has no canonical $_conf. Refusing kmod update because exact tunnel restoration is not guaranteed."
        cp -p "$_conf" "$KMOD_TXN_DIR/${_iface}.conf" || die "Could not snapshot canonical config for $_iface."
        chmod 0600 "$KMOD_TXN_DIR/${_iface}.conf"
        KMOD_LIVE_IFACES="${KMOD_LIVE_IFACES}${KMOD_LIVE_IFACES:+ }${_iface}"
    done
}

kmod_set_watchdog_hold() {
    _flag="/var/run/amneziawg_stopped.flag"
    _tmp="/var/run/.amneziawg-kmod-hold.$$"

    if [ -e "$_flag" ]; then
        cp -p "$_flag" "$KMOD_TXN_DIR/service-stopped.flag.before" || return 1
        KMOD_STOPPED_FLAG_WAS_PRESENT=1
    else
        KMOD_STOPPED_FLAG_WAS_PRESENT=0
    fi

    rm -f "$_tmp" 2>/dev/null || true
    if ! printf '%s\n' "$$" > "$_tmp"; then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    chmod 0600 "$_tmp" 2>/dev/null || true
    if ! mv -f "$_tmp" "$_flag"; then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

kmod_release_watchdog_hold() {
    _flag="/var/run/amneziawg_stopped.flag"
    if [ "${KMOD_STOPPED_FLAG_WAS_PRESENT:-0}" = "1" ]; then
        if [ -f "$KMOD_TXN_DIR/service-stopped.flag.before" ]; then
            cp -p "$KMOD_TXN_DIR/service-stopped.flag.before" "$_flag" || return 1
        else
            return 1
        fi
    else
        rm -f "$_flag" || return 1
    fi
    return 0
}

kmod_stop_captured_ifaces() {
    for _iface in $KMOD_LIVE_IFACES; do
        _conf="$KMOD_TXN_DIR/${_iface}.conf"
        if /sbin/ifconfig "$_iface" >/dev/null 2>&1; then
            echo "  stopping ${_iface}..."
            if ! "$AWG_QUICK" down "$_conf" >/dev/null 2>&1; then
                warn "Failed to stop ${_iface} during kmod transaction."
                return 1
            fi
            if /sbin/ifconfig "$_iface" >/dev/null 2>&1; then
                warn "${_iface} still exists after awg-quick down."
                return 1
            fi
        fi
    done
    return 0
}

kmod_restore_captured_ifaces() {
    _restore_ok=1
    for _iface in $KMOD_LIVE_IFACES; do
        _conf="$KMOD_TXN_DIR/${_iface}.conf"
        if /sbin/ifconfig "$_iface" >/dev/null 2>&1; then
            continue
        fi
        echo "  restoring ${_iface}..."
        if "$AWG_QUICK" up "$_conf" >/dev/null 2>&1             && /sbin/ifconfig "$_iface" >/dev/null 2>&1             && "$AWG_BIN" show "$_iface" >/dev/null 2>&1; then
            /usr/local/sbin/configctl -d interface newip "$_iface" >/dev/null 2>&1 || true
        else
            warn "Failed to restore ${_iface}."
            _restore_ok=0
        fi
    done
    [ "$_restore_ok" = "1" ]
}

kmod_rollback_old_package() {
    warn "Rolling back amnezia-kmod to the pre-upgrade package."

    if ! kmod_stop_captured_ifaces >/dev/null 2>&1; then
        warn "CRITICAL: cannot stop all captured tunnels before kmod rollback; refusing to replace package files under a live module."
        return 1
    fi

    if kldstat -q -m if_amn 2>/dev/null; then
        if ! kldunload if_amn >/dev/null 2>&1; then
            warn "CRITICAL: could not unload current if_amn before package rollback."
            return 1
        fi
    fi

    _oldpkg=$(find "$KMOD_TXN_DIR/pkg" -type f -name 'amnezia-kmod-*.pkg' -print 2>/dev/null | head -n 1)
    if [ -z "$_oldpkg" ]; then
        warn "CRITICAL: old amnezia-kmod package backup is missing: $KMOD_TXN_DIR/pkg"
        return 1
    fi

    pkg unlock -qy amnezia-kmod >/dev/null 2>&1 || true
    if ! pkg add -f "$_oldpkg" >/dev/null 2>&1; then
        warn "CRITICAL: failed to reinstall old amnezia-kmod package from $_oldpkg"
        return 1
    fi

    if ! kldload if_amn >/dev/null 2>&1 && ! kldstat -q -m if_amn 2>/dev/null; then
        warn "CRITICAL: old if_amn could not be loaded after package rollback."
        return 1
    fi

    if ! kmod_restore_captured_ifaces; then
        warn "CRITICAL: old kmod restored but one or more pre-upgrade tunnels could not be restored."
        return 1
    fi

    if ! restore_kmod_lock_state; then
        warn "CRITICAL: old kmod/tunnels restored but original amnezia-kmod lock state could not be restored."
        return 1
    fi

    if ! kmod_release_watchdog_hold; then
        warn "CRITICAL: old kmod/tunnels restored but watchdog hold state could not be restored."
        return 1
    fi

    /usr/local/sbin/configctl amneziawg sentinel_repair >/dev/null 2>&1 || true
    return 0
}

kmod_abort_with_rollback() {
    _reason="$1"
    if kmod_rollback_old_package; then
        echo "[OK]  Previous amnezia-kmod package and pre-upgrade tunnel set restored"
    else
        KMOD_ROLLBACK_FAILED=1
        warn "CRITICAL: automatic amnezia-kmod rollback was incomplete. Recovery files preserved in $KMOD_TXN_DIR"
    fi
    KMOD_TXN_ACTIVE=0
    cleanup_freebsd_repo
    die "$_reason"
}

kmod_dry_run_scope_ok() {
    _out="$1"
    _names=$(printf '%s\n' "$_out" |
        sed -nE 's/^[[:space:]]+([A-Za-z0-9][A-Za-z0-9_.+-]*):.*/\1/p' |
        sort -u)
    [ -n "$_names" ] || return 1
    for _name in $_names; do
        [ "$_name" = "amnezia-kmod" ] || return 1
    done
    return 0
}

maybe_upgrade_kmod() {
    _installed=$(pkg query '%v' amnezia-kmod 2>/dev/null || echo "")
    [ -n "$_installed" ] || return 0

    echo ""
    echo "==> Checking FreeBSD quarterly for amnezia-kmod update..."
    setup_freebsd_repo
    if ! pkg_freebsd update -r FreeBSD-quarterly >/dev/null 2>&1; then
        cleanup_freebsd_repo
        warn "Could not refresh FreeBSD-quarterly; skipping optional kmod update check."
        return 0
    fi

    _candidate=$(pkg_freebsd rquery -r FreeBSD-quarterly '%v' amnezia-kmod 2>/dev/null | head -n 1 || true)
    if [ -z "$_candidate" ]; then
        cleanup_freebsd_repo
        warn "No amnezia-kmod candidate returned by FreeBSD-quarterly; continuing without kmod update."
        return 0
    fi

    _cmp=$(pkg version -t "$_installed" "$_candidate" 2>/dev/null || echo "?")
    echo "  installed : ${_installed}"
    echo "  candidate : ${_candidate}"
    echo "  kernel ABI: $(uname -K 2>/dev/null || echo unknown)"

    if [ "$_cmp" != "<" ]; then
        echo "[OK]  amnezia-kmod is already current for this repository"
        cleanup_freebsd_repo
        return 0
    fi

    if ! check_kernel_compat; then
        cleanup_freebsd_repo
        warn "Newer amnezia-kmod exists but is not proven compatible with this running kernel; leaving current module untouched."
        return 0
    fi

    if ! pkg_dry_run_single_package amnezia-kmod FreeBSD-quarterly; then
        cleanup_freebsd_repo
        die "amnezia-kmod dry-run transaction could not be proven safe; refusing kmod update."
    fi
    _dry="$PKG_DRY_OUT"
    echo "[OK]  Dry-run transaction is exactly one amnezia-kmod operation (pkg rc=$PKG_DRY_RC)"

    printf "  Upgrade amnezia-kmod ${_installed} -> ${_candidate} now? [y/N] "
    read -r _KU < /dev/tty 2>/dev/null || _KU="n"
    case "$_KU" in
        [yY]*) ;;
        *)
            echo "  Keeping installed amnezia-kmod ${_installed}."
            cleanup_freebsd_repo
            return 0
            ;;
    esac

    KMOD_TXN_DIR=$(mktemp -d /tmp/amneziawg-kmod.XXXXXX)
    chmod 0700 "$KMOD_TXN_DIR"
    install -d -m 0700 "$KMOD_TXN_DIR/pkg"

    echo "==> Creating local rollback package for amnezia-kmod ${_installed}..."
    if ! pkg create -o "$KMOD_TXN_DIR/pkg" amnezia-kmod >/dev/null 2>&1; then
        cleanup_freebsd_repo
        die "Could not create local rollback package; refusing kmod update."
    fi
    _oldpkg=$(find "$KMOD_TXN_DIR/pkg" -type f -name 'amnezia-kmod-*.pkg' -print | head -n 1)
    [ -n "$_oldpkg" ] || {
        cleanup_freebsd_repo
        die "pkg create completed but rollback package was not found."
    }

    echo "==> Fetching exact amnezia-kmod candidate package..."
    install -d -m 0700 "$KMOD_TXN_DIR/new"
    if ! pkg_freebsd fetch -y -r FreeBSD-quarterly -o "$KMOD_TXN_DIR/new" amnezia-kmod >/dev/null 2>&1; then
        cleanup_freebsd_repo
        die "Could not fetch candidate amnezia-kmod package; current module remains untouched."
    fi
    _newpkg=$(find "$KMOD_TXN_DIR/new" -type f -name 'amnezia-kmod-*.pkg' -print | head -n 1)
    [ -n "$_newpkg" ] || {
        cleanup_freebsd_repo
        die "Candidate fetch completed but amnezia-kmod package file was not found."
    }
    _newmeta=$(pkg query -F "$_newpkg" '%n %v' 2>/dev/null || echo "")
    if [ "$_newmeta" != "amnezia-kmod $_candidate" ]; then
        cleanup_freebsd_repo
        die "Fetched package manifest mismatch: '${_newmeta:-unreadable}', expected 'amnezia-kmod $_candidate'."
    fi
    echo "[OK]  Candidate package manifest verified: $_newmeta"

    kmod_capture_live_ifaces
    echo "  live tunnels captured: ${KMOD_LIVE_IFACES:-none}"

    # pkg itself must never be eligible for replacement from FreeBSD.
    if [ "$PKG_WAS_LOCKED" != "1" ]; then
        if pkg lock -qy pkg >/dev/null 2>&1; then
            PKG_LOCKED_BY_US=1
        else
            cleanup_freebsd_repo
            die "Could not temporarily lock pkg; refusing kmod update."
        fi
    fi

    KMOD_TXN_ACTIVE=1
    if ! kmod_set_watchdog_hold; then
        KMOD_TXN_ACTIVE=0
        cleanup_freebsd_repo
        die "Could not establish watchdog hold; refusing kmod update."
    fi

    if ! kmod_stop_captured_ifaces; then
        kmod_restore_captured_ifaces || warn "WARNING: one or more tunnels needed recovery after a failed stop sequence."
        kmod_release_watchdog_hold || warn "WARNING: watchdog hold state could not be restored after failed stop sequence."
        KMOD_TXN_ACTIVE=0
        cleanup_freebsd_repo
        die "Could not stop all captured AWG interfaces; kmod package was not changed."
    fi

    # There must be no remaining AWG interface using if_amn. Foreign/manual
    # interfaces are therefore a hard stop, not something the installer destroys.
    _remain=$(AWG_COLOR_MODE=never "$AWG_BIN" show interfaces 2>/dev/null || true)
    if [ -n "$_remain" ]; then
        kmod_restore_captured_ifaces || true
        restore_kmod_lock_state || true
        kmod_release_watchdog_hold || true
        KMOD_TXN_ACTIVE=0
        cleanup_freebsd_repo
        die "AWG interfaces remain after stopping captured tunnels ($_remain); refusing to unload if_amn."
    fi

    if ! kldunload if_amn >/dev/null 2>&1; then
        kmod_restore_captured_ifaces || true
        restore_kmod_lock_state || true
        kmod_release_watchdog_hold || true
        KMOD_TXN_ACTIVE=0
        cleanup_freebsd_repo
        die "Could not unload if_amn; current kmod package remains installed."
    fi

    # Unlock only the target package after the module is safely unloaded.
    # From this point any interruption is covered by KMOD_TXN_ACTIVE rollback.
    _klock=$(pkg query '%k' amnezia-kmod 2>/dev/null || echo "0")
    if [ "$_klock" = "1" ]; then
        if ! pkg unlock -qy amnezia-kmod >/dev/null 2>&1; then
            kmod_abort_with_rollback "Could not temporarily unlock amnezia-kmod."
        fi
    fi

    echo "==> Installing verified local amnezia-kmod package only..."
    if ! pkg add -f "$_newpkg" >/dev/null 2>&1; then
        warn "Local amnezia-kmod package transaction failed."
        kmod_abort_with_rollback "amnezia-kmod upgrade failed; installer stopped."
    fi

    _after=$(pkg query '%v' amnezia-kmod 2>/dev/null || echo "")
    if [ "$_after" != "$_candidate" ]; then
        warn "Installed amnezia-kmod version is '${_after}', expected '${_candidate}'."
        kmod_abort_with_rollback "Unexpected amnezia-kmod version after transaction."
    fi

    if ! kldload if_amn >/dev/null 2>&1 && ! kldstat -q -m if_amn 2>/dev/null; then
        warn "New if_amn failed to load."
        kmod_abort_with_rollback "New amnezia-kmod failed load verification."
    fi

    if ! kmod_restore_captured_ifaces; then
        warn "New kmod loaded but pre-upgrade tunnel set could not be restored."
        kmod_abort_with_rollback "Tunnel restoration failed after kmod update."
    fi

    if ! kmod_release_watchdog_hold; then
        warn "New kmod/tunnels are up but watchdog hold state could not be restored."
        kmod_abort_with_rollback "Could not restore watchdog hold state after kmod update."
    fi
    /usr/local/sbin/configctl amneziawg sentinel_repair >/dev/null 2>&1 || true

    if ! restore_kmod_lock_state; then
        warn "New kmod works but original amnezia-kmod lock state could not be restored."
        kmod_abort_with_rollback "Could not restore amnezia-kmod lock state."
    fi

    if [ "$PKG_LOCKED_BY_US" = "1" ]; then
        if pkg unlock -qy pkg >/dev/null 2>&1; then
            PKG_LOCKED_BY_US=0
        else
            warn "New kmod works but temporary pkg lock could not be removed."
            kmod_abort_with_rollback "Could not restore pkg lock state after kmod update."
        fi
    fi

    KMOD_TXN_ACTIVE=0
    cleanup_freebsd_repo

    echo "[OK]  amnezia-kmod upgraded ${_installed} -> ${_candidate}"
    echo "[OK]  pre-upgrade AWG tunnel set restored"
    rm -rf "$KMOD_TXN_DIR"
    KMOD_TXN_DIR=""
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# PKG INTEGRITY PRE-CHECK
# If pkg was previously corrupted (e.g. upgraded from quarterly repo),
# detect and offer automatic recovery before proceeding.
# Checks: 1) pkg info works, 2) pkg not replaced by FreeBSD quarterly version
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Pre-check: Verifying pkg integrity..."

pkg_recover() {
    die "pkg/repository state is not healthy. Refusing automatic repair on a production firewall. Restore pkg from the OPNsense repository first, then rerun this installer."
}

PKG_NEEDS_FIX=0

# Check 1: can pkg query itself at all?
if ! pkg info pkg >/dev/null 2>&1; then
    warn "pkg appears broken (cannot query package database)."
    PKG_NEEDS_FIX=1
fi

# Check 2: was pkg replaced by a FreeBSD (non-OPNsense) version?
# On OPNsense, pkg should come from the "OPNsense" repo. If it came from
# "FreeBSD" or "FreeBSD-quarterly", it's incompatible and causes segfaults.
if [ "$PKG_NEEDS_FIX" = "0" ]; then
    _PKG_REPO=$(pkg-static query '%R' pkg 2>/dev/null || echo "")
    if [ -n "$_PKG_REPO" ] && ! echo "$_PKG_REPO" | grep -qi "OPNsense"; then
        _PKG_VER=$(pkg-static query '%v' pkg 2>/dev/null || echo "unknown")
        warn "pkg v${_PKG_VER} was installed from '${_PKG_REPO}' repo instead of OPNsense!"
        warn "This is known to cause segfaults in pkg update."
        PKG_NEEDS_FIX=1
    fi
fi

if [ "$PKG_NEEDS_FIX" = "1" ]; then
    echo ""
    pkg_recover
else
    echo "[OK]  pkg is healthy"
fi

echo ""
echo "==> Step 1: Checking AmneziaWG packages..."

NEED_KMOD=0
NEED_TOOLS=0

if [ ! -x /usr/local/bin/awg ] || ! pkg info amnezia-tools >/dev/null 2>&1; then
    NEED_TOOLS=1
fi

if pkg info amnezia-kmod >/dev/null 2>&1; then
    if ! kldstat -q -m if_amn 2>/dev/null; then
        echo "  amnezia-kmod is installed but if_amn is not loaded; trying kldload..."
        if kldload if_amn 2>/dev/null; then
            echo "[OK]  if_amn loaded from installed package"
        else
            die "amnezia-kmod is installed but if_amn cannot be loaded. Refusing to reinstall/replace the kernel module automatically."
        fi
    fi
else
    NEED_KMOD=1
fi

if [ "$NEED_KMOD" = "1" ] || [ "$NEED_TOOLS" = "1" ]; then
    echo ""
    echo "  Missing packages detected:"
    [ "$NEED_TOOLS" = "1" ] && echo "    - amnezia-tools (awg, awg-quick)"
    [ "$NEED_KMOD" = "1" ]  && echo "    - amnezia-kmod  (if_amn kernel module)"
    echo ""
    printf "  Install from FreeBSD quarterly repo? [Y/n] "
    read -r _REPLY < /dev/tty 2>/dev/null || _REPLY="y"
    case "$_REPLY" in
        [nN]*)
            die "Required AmneziaWG packages are missing. No plugin files have been changed."
            ;;
        *)
            setup_freebsd_repo

            # Lock pkg only if it was not already locked before this installer.
            # Never claim ownership of a pre-existing user/system lock.
            PKG_LOCKED_BY_US=0
            if [ "$PKG_WAS_LOCKED" != "1" ]; then
                if pkg lock -qy pkg 2>/dev/null; then
                    PKG_LOCKED_BY_US=1
                    echo "[OK]  pkg temporarily locked (preventing self-upgrade from FreeBSD quarterly)"
                else
                    cleanup_freebsd_repo
                    die "Could not temporarily lock pkg; refusing FreeBSD package transaction."
                fi
            else
                echo "[OK]  pkg was already locked before installer; preserving existing lock"
            fi

            if ! pkg_freebsd update -r FreeBSD-quarterly >/dev/null 2>&1; then
                cleanup_freebsd_repo
                die "Could not update FreeBSD-quarterly catalogue. Refusing package installation."
            fi

            if [ "$NEED_KMOD" = "1" ]; then
                # Check kernel compatibility before installing kmod
                KMOD_COMPAT=1
                if ! check_kernel_compat; then
                    cleanup_freebsd_repo
                    die "amnezia-kmod is not proven compatible with the running kernel. No plugin files have been changed."
                fi

                if [ "$KMOD_COMPAT" = "1" ]; then
                    echo "  Installing amnezia-kmod..."
                    if pkg_freebsd install -y -r FreeBSD-quarterly amnezia-kmod 2>/dev/null; then
                        echo "[OK]  amnezia-kmod installed"
                        # Do not permanently lock amnezia-kmod. The temporary
                        # FreeBSD repo is removed below, and keeping the kmod
                        # locked would block intentional future package updates.
                        if ! kldload if_amn 2>/dev/null && ! kldstat -q -m if_amn 2>/dev/null; then
                            cleanup_freebsd_repo
                            die "amnezia-kmod installed but if_amn could not be loaded."
                        fi
                        ENSURE_IF_AMN_LOADER=1
                    else
                        cleanup_freebsd_repo
                        die "Failed to install amnezia-kmod. Refusing partial plugin installation."
                    fi
                fi
            fi

            if [ "$NEED_TOOLS" = "1" ]; then
                echo "  Installing amnezia-tools..."
                if pkg_freebsd install -y -r FreeBSD-quarterly amnezia-tools 2>/dev/null; then
                    echo "[OK]  amnezia-tools installed"
                else
                    cleanup_freebsd_repo
                    die "Failed to install amnezia-tools. Refusing partial plugin installation."
                fi
            fi

            cleanup_freebsd_repo

            # Unlock pkg if we locked it
            if [ "$PKG_LOCKED_BY_US" = "1" ]; then
                if pkg unlock -qy pkg >/dev/null 2>&1; then
                    PKG_LOCKED_BY_US=0
                else
                    die "Could not restore pkg lock state after FreeBSD package transaction."
                fi
            fi

            # Post-install: never attempt an automatic pkg repair on a
            # production firewall. The transaction must leave pkg healthy.
            if ! pkg info pkg >/dev/null 2>&1; then
                die "pkg became unhealthy after FreeBSD package transaction. Automatic repair is intentionally disabled."
            fi
            ;;
    esac
else
    echo "[OK]  awg: $(awg --version 2>/dev/null || echo 'installed')"
    echo "[OK]  if_amn kernel module loaded"
    # Preserve a pre-existing amnezia-kmod lock. Package transactions below
    # may temporarily adjust lock state when required, but postflight restores
    # the exact state observed before the installer started.
    if pkg info amnezia-kmod >/dev/null 2>&1; then
        _KMOD_LOCKED=$(pkg query '%k' amnezia-kmod 2>/dev/null || echo "0")
        if [ "$_KMOD_LOCKED" = "1" ]; then
            echo "[OK]  Preserving existing amnezia-kmod pkg lock"
        fi
    fi
fi

# Existing installations may have newer userspace tools available even when
# the current binaries are operational. Update them independently before kmod
# so userspace compatibility is proven before any kernel-module transaction.
if pkg info amnezia-tools >/dev/null 2>&1; then
    maybe_upgrade_tools
fi

# Existing installations may have a newer kernel module available even when
# all required packages are already present. This is an independent,
# rollback-protected transaction and never uses pkg upgrade.
if pkg info amnezia-kmod >/dev/null 2>&1; then
    maybe_upgrade_kmod
fi

# Final binary check
BINARIES_OK=1
[ ! -x /usr/local/bin/awg ] && BINARIES_OK=0
kldstat -q -m if_amn 2>/dev/null || BINARIES_OK=0

if [ "$BINARIES_OK" = "0" ]; then
    die "Required AmneziaWG tools/module are not operational. No plugin files have been changed."
fi

if ! grep -Eq '^[[:space:]]*if_amn_load="YES"' /boot/loader.conf 2>/dev/null; then
    ENSURE_IF_AMN_LOADER=1
fi

# At this point any temporary FreeBSD transaction is finished. Prove that
# the system is back on its original OPNsense repository configuration before
# touching MVC/configd/plugin files.
verify_pkg_repo_state

# ─────────────────────────────────────────────────────────────────────────────
# DETECT EXISTING CONFIG (MED-8)
# Multi-instance (3.0.0): checks both the new collection path and the legacy
# flat node. A legacy node is migrated by the model migration (M2_0_0),
# executed in Step 4 via run_migrations.php — no manual import needed.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Checking for existing AmneziaWG configuration..."

CONFIG_XML_HAS_AWG=0

if [ -x /usr/local/bin/php ]; then
    CONFIG_XML_HAS_AWG=$(/usr/local/bin/php -r '
        set_include_path("/usr/local/etc/inc" . PATH_SEPARATOR . get_include_path());
        @include_once("config.inc");
        try {
            $cfg = OPNsense\Core\Config::getInstance()->object();
            // New multi-instance path
            $new = isset($cfg->OPNsense->amneziawg->instances->instance) ? "1" : "0";
            // Server instances
            $servers = isset($cfg->OPNsense->amneziawg->servers->server) ? "1" : "0";
            // Legacy flat node (pre-3.0.0) — migrated automatically by M2_0_0
            $legacy = (string)($cfg->OPNsense->amneziawg->instance->peer_public_key ?? "");
            echo ($new === "1" || $servers === "1" || $legacy !== "") ? "1" : "0";
        } catch (Exception $e) {
            echo "0";
        }
    ' 2>/dev/null || echo "0")
fi

if [ "$CONFIG_XML_HAS_AWG" = "1" ]; then
    echo "[OK]  Existing configuration found in config.xml — will not overwrite."
    echo "      A pre-3.0.0 single-tunnel config is migrated automatically in Step 4."
else
    # Stray .conf files are reported only — import via GUI 'Import .conf' dialog
    for _f in /usr/local/etc/amnezia/awg*.conf; do
        if [ -f "$_f" ]; then
            echo "  Found tunnel config file: $_f"
            echo "  Use the GUI 'Import .conf' dialog to add it as a tunnel instance."
        fi
    done
    echo "[OK]  No existing configuration found (clean install)."
fi

echo ""
prepare_plugin_rollback

if [ "$ENSURE_IF_AMN_LOADER" = "1" ]; then
    echo "==> Ensuring if_amn autoload on boot..."
    printf '%s\n' 'if_amn_load="YES"' >> /boot/loader.conf
    echo "[OK]  /boot/loader.conf updated (rollback-protected)"
fi

echo ""
echo "==> Normalizing canonical AmneziaWG configs..."
install -d -m 0700 /usr/local/etc/amnezia

# An earlier development build briefly used /usr/local/etc/amnezia/runtime/ as its canonical
# location. The plugin standardizes on /usr/local/etc/amnezia/awgN.conf.
# If upgrading from that build, copy only interfaces present in the OPNsense
# model back to the canonical namespace before removing the obsolete directory.
if [ -d /usr/local/etc/amnezia/runtime ] && [ -x /usr/local/bin/php ]; then
    _MANAGED_IFACES=$(/usr/local/bin/php -r '
require_once("/usr/local/etc/inc/config.inc");
$c = OPNsense\Core\Config::getInstance()->object();
$out = [];
foreach (["instances"=>"instance","servers"=>"server"] as $container=>$item) {
    $n = $c->OPNsense->amneziawg->{$container} ?? null;
    if (!isset($n) || !isset($n->{$item})) continue;
    foreach ($n->{$item} as $x) {
        $v = trim((string)($x->interface_number ?? ""));
        if (!preg_match("/^(0|[1-9][0-9]?)$/", $v)) continue;
        $out["awg".(int)$v] = true;
    }
}
echo implode(" ", array_keys($out));
' 2>/dev/null || true)

    for _IFACE in $_MANAGED_IFACES; do
        _OLD="/usr/local/etc/amnezia/runtime/${_IFACE}.conf"
        _NEW="/usr/local/etc/amnezia/${_IFACE}.conf"
        if [ -f "$_OLD" ]; then
            if [ ! -f "$_NEW" ]; then
                cp -p "$_OLD" "$_NEW"
                chmod 0600 "$_NEW"
                echo "[OK]  Canonical config recovered from obsolete runtime tree: ${_IFACE}"
            else
                echo "[OK]  Canonical config already present; obsolete runtime copy ignored: ${_IFACE}"
            fi
        fi
    done
    unset _IFACE _OLD _NEW _MANAGED_IFACES
    rm -rf /usr/local/etc/amnezia/runtime
    echo "[OK]  Obsolete runtime directory removed"
fi

echo ""
echo "==> Step 3: Installing plugin files..."

install -d /usr/local/opnsense/scripts/AmneziaWG
install -m 0755 "$PLUGIN_DIR/scripts/AmneziaWG/amneziawg-service-control.php" \
                /usr/local/opnsense/scripts/AmneziaWG/
install -m 0755 "$PLUGIN_DIR/scripts/AmneziaWG/amneziawg-ifstats.php" \
                /usr/local/opnsense/scripts/AmneziaWG/
install -m 0755 "$PLUGIN_DIR/scripts/AmneziaWG/amneziawg-testconnect.php" \
                /usr/local/opnsense/scripts/AmneziaWG/
install -m 0755 "$PLUGIN_DIR/scripts/AmneziaWG/amneziawg-watchdog.php" \
                /usr/local/opnsense/scripts/AmneziaWG/

install -m 0644 "$PLUGIN_DIR/service/conf/actions.d/actions_amneziawg.conf" \
                /usr/local/opnsense/service/conf/actions.d/

install -d /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/Menu
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/General.xml" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/General.php" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Instance.xml" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Instance.php" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Server.xml" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Server.php" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Peer.xml" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Peer.php" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Menu/Menu.xml" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/Menu/

# Multi-instance (3.0.0): model migration from the legacy flat layout
install -d /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/Migrations
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/Migrations/M2_0_0.php" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/Migrations/

# IMP-6: install ACL definitions for API endpoints
install -d /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/ACL
install -m 0644 "$PLUGIN_DIR/mvc/app/models/OPNsense/AmneziaWG/ACL/ACL.xml" \
                /usr/local/opnsense/mvc/app/models/OPNsense/AmneziaWG/ACL/

_CTRL_SRC="$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG"
_CTRL_DST="/usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG"
install -d "$_CTRL_DST/Api"
install -d "$_CTRL_DST/forms"
# Keep the installed top-level controller set exactly in sync with this release.
# This also removes obsolete controllers left behind by older versions.
rm -f "$_CTRL_DST"/*.php
for _CTRL_FILE in "$_CTRL_SRC"/*.php; do
    install -m 0644 "$_CTRL_FILE" "$_CTRL_DST/"
done
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/Api/GeneralController.php" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/Api/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/Api/InstanceController.php" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/Api/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/Api/ServerController.php" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/Api/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/Api/PeerController.php" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/Api/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/Api/ServiceController.php" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/Api/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/Api/ImportController.php" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/Api/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/forms/general.xml" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/forms/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/forms/dialogInstance.xml" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/forms/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/forms/dialogServer.xml" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/forms/
install -m 0644 "$PLUGIN_DIR/mvc/app/controllers/OPNsense/AmneziaWG/forms/dialogPeer.xml" \
                /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/forms/
# Remove the pre-3.0.0 single-instance form if present
rm -f /usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG/forms/instance.xml

install -d /usr/local/opnsense/mvc/app/views/OPNsense/AmneziaWG
install -m 0644 "$PLUGIN_DIR/mvc/app/views/OPNsense/AmneziaWG/general.volt" \
                /usr/local/opnsense/mvc/app/views/OPNsense/AmneziaWG/

install -m 0644 "$PLUGIN_DIR/etc/inc/plugins.inc.d/amneziawg.inc" \
                /usr/local/etc/inc/plugins.inc.d/

# SEC-6: install newsyslog config for log rotation (max 1MB, 5 archives, gzip)
install -d /etc/newsyslog.conf.d
install -m 0644 "$PLUGIN_DIR/etc/newsyslog.conf.d/amneziawg.conf" \
                /etc/newsyslog.conf.d/

install -d -m 0700 /usr/local/etc/amnezia

# MED-2: install rc.syshook for autostart on boot
install -d /usr/local/etc/rc.syshook.d/start
install -m 0755 "$PLUGIN_DIR/etc/rc.syshook.d/start/50-amneziawg" \
                /usr/local/etc/rc.syshook.d/start/

echo "[OK]  Plugin files installed."

# ─────────────────────────────────────────────────────────────────────────────
# PORT CHECK (LOW-5)
# Warn if any configured listen port is already in use by another service.
# Multi-instance: iterates all instances (new path) + legacy flat node.
# ─────────────────────────────────────────────────────────────────────────────
if [ -x /usr/local/bin/php ]; then
    _LISTEN_PORTS=$(/usr/local/bin/php -r '
        set_include_path("/usr/local/etc/inc" . PATH_SEPARATOR . get_include_path());
        @include_once("config.inc");
        try {
            $cfg = OPNsense\Core\Config::getInstance()->object();
            $ports = [];
            $container = $cfg->OPNsense->amneziawg->instances ?? null;
            if (isset($container) && isset($container->instance)) {
                foreach ($container->instance as $inst) {
                    $p = (string)($inst->listen_port ?? "");
                    if ($p !== "") $ports[] = $p;
                }
            }
            $servers = $cfg->OPNsense->amneziawg->servers ?? null;
            if (isset($servers) && isset($servers->server)) {
                foreach ($servers->server as $srv) {
                    $p = (string)($srv->listen_port ?? "");
                    if ($p !== "") $ports[] = $p;
                }
            }
            $legacy = (string)($cfg->OPNsense->amneziawg->instance->listen_port ?? "");
            if ($legacy !== "") $ports[] = $legacy;
            echo implode(" ", array_unique($ports));
        } catch (Exception $e) { echo ""; }
    ' 2>/dev/null || echo "")
    _AWG_ACTIVE_PORTS=""
    if [ -x /usr/local/bin/awg ]; then
        _AWG_ACTIVE_PORTS=$(/usr/local/bin/awg show all listen-port 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || true)
    fi
    for _LISTEN_PORT in $_LISTEN_PORTS; do
        if [ "$_LISTEN_PORT" -gt 0 ] 2>/dev/null; then
            case " $_AWG_ACTIVE_PORTS " in
                *" $_LISTEN_PORT "*) continue ;; # our already-running tunnel during upgrade
            esac
            if sockstat -l -P udp 2>/dev/null | grep -q ":${_LISTEN_PORT} " 2>/dev/null; then
                echo ""
                warn "UDP port ${_LISTEN_PORT} is already in use by another service!"
                warn "AmneziaWG may fail to start. Check: sockstat -l -P udp | grep ${_LISTEN_PORT}"
            fi
        fi
    done
fi

echo ""
echo "==> Step 4: Running model migrations..."
# Multi-instance (3.0.0): migrate a pre-3.0.0 flat single-instance config to
# the ArrayField collection (M2_0_0). Safe to run repeatedly (idempotent).
if [ -x /usr/local/bin/php ]; then
    _MIG_OUT="$(mktemp /tmp/amneziawg-migrations.XXXXXX)"
    if (cd /usr/local/opnsense/mvc && /usr/local/bin/php script/run_migrations.php >"$_MIG_OUT" 2>&1); then
        grep -i amnezia "$_MIG_OUT" || true
        rm -f "$_MIG_OUT"
    else
        warn "OPNsense model migrations failed:"
        tail -n 40 "$_MIG_OUT" >&2 || true
        rm -f "$_MIG_OUT"
        die "Migration failure; previous plugin state will be restored automatically."
    fi
fi

echo ""
echo "==> Step 5: Restarting configd..."
service configd restart

echo ""
echo "==> Step 6: Clearing cache..."
rm -f /var/lib/php/tmp/opnsense_menu_cache.xml
rm -f /var/lib/php/tmp/PHP_errors.log

echo ""
echo "==> Step 7: Smoke-testing installed backend..."
_STATUS_OUT=$(/usr/local/sbin/configctl amneziawg status 2>&1 || true)
if ! printf '%s\n' "$_STATUS_OUT" | grep -q '"status":"ok"'; then
    warn "AmneziaWG status smoke-test failed:"
    printf '%s\n' "$_STATUS_OUT" >&2
    die "Installed backend failed status smoke-test; previous plugin state will be restored automatically."
fi
echo "[OK]  configd status action operational"

_VALIDATE_OUT=$(/usr/local/sbin/configctl amneziawg validate 2>&1 || true)
if ! printf '%s\n' "$_VALIDATE_OUT" | grep -Eq '^OK([[:space:]]|$)'; then
    warn "AmneziaWG validate smoke-test failed:"
    printf '%s\n' "$_VALIDATE_OUT" >&2
    die "Installed backend failed dry-run validation; previous plugin state will be restored automatically."
fi
echo "[OK]  dry-run validation successful"

_CTRL_DST="/usr/local/opnsense/mvc/app/controllers/OPNsense/AmneziaWG"
test -f "$_CTRL_DST/PageControllerBase.php" || \
    die "Installed UI controller set is incomplete: PageControllerBase.php is missing."
test ! -f "$_CTRL_DST/BaseController.php" || \
    die "Obsolete BaseController.php is still installed."
grep -q "jquery.qrcode.js" "$_CTRL_DST/PageControllerBase.php" || \
    die "Installed PageControllerBase.php is missing the QR JavaScript include."
for _PAGE_CTRL in General Server Clients Diagnostics; do
    grep -Eq "class ${_PAGE_CTRL}Controller extends PageControllerBase" "$_CTRL_DST/${_PAGE_CTRL}Controller.php" || \
        die "Installed ${_PAGE_CTRL}Controller.php does not extend PageControllerBase."
done
echo "[OK]  UI controller set and QR includes verified"

echo ""
echo "==> Step 8: Final package/repository postflight..."
verify_pkg_repo_state

# Commit the installed version only after files, migrations, configd reload,
# backend smoke-tests and final repository postflight have all completed successfully.
# A failed/partial upgrade must not advertise the new version.
echo "$PLUGIN_VERSION" > "$VERSION_FILE"
chmod 0644 "$VERSION_FILE"
INSTALL_COMMITTED=1

echo ""
echo "============================================================"
echo "  opnsense-awg v${PLUGIN_VERSION} installed!"
echo "============================================================"
echo ""
