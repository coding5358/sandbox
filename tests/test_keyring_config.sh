#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="$ROOT_DIR/scripts/setup.sh"

package_block_contains() {
    awk '
        /apt-get "\$\{APT_OPTIONS\[@\]\}" install -y/ { in_packages=1 }
        in_packages && /gnome-keyring/ { found=1 }
        in_packages && /^$/ { exit !found }
        END { exit !found }
    ' "$SETUP_SCRIPT"
}

package_block_contains
grep -Fq -- 'CONTAINER_UID="1000"' "$SETUP_SCRIPT"
grep -Fq -- 'systemctl --user add-wants default.target gnome-keyring-daemon.service' "$SETUP_SCRIPT"
grep -Fq -- 'systemctl --user enable gnome-keyring-daemon.socket' "$SETUP_SCRIPT"
grep -Fq -- 'systemctl --user start gnome-keyring-daemon.service' "$SETUP_SCRIPT"
grep -Fq -- 'loginctl enable-linger "$CONTAINER_USER"' "$SETUP_SCRIPT"
grep -Fq -- 'systemctl start "user-runtime-dir@${CONTAINER_UID}.service"' "$SETUP_SCRIPT"
grep -Fq -- 'systemctl start "user@${CONTAINER_UID}.service"' "$SETUP_SCRIPT"
grep -Fq -- 'busctl --user status org.freedesktop.secrets' "$SETUP_SCRIPT"
grep -Fq -- 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' "$SETUP_SCRIPT"
grep -Fq -- 'network_type() {' "$SETUP_SCRIPT"
grep -Fq -- 'su - "$CONTAINER_USER" -s /bin/bash -c' "$SETUP_SCRIPT"

# The only Incus proxy added by setup.sh is the host Wayland socket.
! grep -Eq -- 'incus config device add.*(dbus|runtime|pulse)' "$SETUP_SCRIPT"
! grep -Eq -- 'connect="unix:[^"]*bus"' "$SETUP_SCRIPT"
! grep -Fq -- 'eval "$(gnome-keyring-daemon' "$SETUP_SCRIPT"

echo "PASS: keyring package and container-local user-bus activation are configured"
