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
grep -Fq -- 'timedatectl show --property=Timezone --value' "$SETUP_SCRIPT"
grep -Fq -- 'is_valid_iana_timezone()' "$SETUP_SCRIPT"
grep -Fq -- '[[ "$timezone" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]]' "$SETUP_SCRIPT"
grep -Fq -- 'invalid IANA timezone received from host' "$SETUP_SCRIPT"
grep -Fq -- 'ln -sfn -- "$TIMEZONE_FILE" /etc/localtime' "$SETUP_SCRIPT"
grep -Fq -- 'gsettings get org.gnome.desktop.interface color-scheme' "$SETUP_SCRIPT"
grep -Fq -- 'prefer-dark|prefer-light|default' "$SETUP_SCRIPT"
grep -Fq -- 'HOST_GTK_THEME="Adwaita:dark"' "$SETUP_SCRIPT"
grep -Fq -- 'HOST_GTK_THEME="Adwaita"' "$SETUP_SCRIPT"
grep -Fq -- 'HOST_GTK_THEME=$HOST_GTK_THEME' "$SETUP_SCRIPT"
grep -Fq -- 'BEGIN Sandbox-managed GTK_THEME' "$SETUP_SCRIPT"
grep -Fq -- 'export GTK_THEME=%s' "$SETUP_SCRIPT"
grep -Fq -- 'END Sandbox-managed GTK_THEME' "$SETUP_SCRIPT"
grep -Fq -- 'gsettings set' "$SETUP_SCRIPT"
grep -Fq -- "' -- sandbox-color-scheme \"\$HOST_COLOR_SCHEME\"; then" "$SETUP_SCRIPT"
grep -Fq -- '?prefer-dark?|prefer-dark' "$SETUP_SCRIPT"
grep -Fq -- '?prefer-light?|prefer-light' "$SETUP_SCRIPT"
grep -Fq -- '?default?|default' "$SETUP_SCRIPT"
grep -Fq -- 'printf "%s\n" prefer-dark' "$SETUP_SCRIPT"
grep -Fq -- 'libglib2.0-bin' "$SETUP_SCRIPT"
grep -Fq -- 'gsettings-desktop-schemas' "$SETUP_SCRIPT"
grep -Fq -- 'tzdata' "$SETUP_SCRIPT"
grep -Fq -- 'Host gsettings is unavailable or does not expose the GNOME color-scheme setting; skipping color-scheme synchronization' "$SETUP_SCRIPT"
grep -Fq -- 'failed to apply color scheme' "$SETUP_SCRIPT"
grep -Fq -- 'network_type() {' "$SETUP_SCRIPT"
grep -Fq -- 'su - "$CONTAINER_USER" -s /bin/bash -c' "$SETUP_SCRIPT"

# The only Incus proxy added by setup.sh is the host Wayland socket.
! grep -Eq -- 'incus config device add.*(dbus|runtime|pulse)' "$SETUP_SCRIPT"
! grep -Eq -- 'connect="unix:[^"]*bus"' "$SETUP_SCRIPT"
! grep -Eq -- 'source="[^"]*/etc/(localtime|timezone)"' "$SETUP_SCRIPT"
! grep -Eq -- 'source="[^"]*/run/user/1000' "$SETUP_SCRIPT"
! grep -Fq -- 'eval "$(gnome-keyring-daemon' "$SETUP_SCRIPT"

echo "PASS: keyring package and container-local user-bus activation are configured"
