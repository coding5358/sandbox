#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(id -u)" != 1000 ]]; then
    echo "SKIP: setup.sh requires host UID 1000"
    exit 0
fi

if [[ ! -x /usr/sbin/iptables ]]; then
    echo "SKIP: /usr/sbin/iptables is not available"
    exit 0
fi

if [[ ! -S /run/user/1000/wayland-0 ]]; then
    echo "SKIP: Wayland socket is not available"
    exit 0
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

PROJECT_DIR="$TEST_DIR/project"
mkdir -p "$PROJECT_DIR/scripts"
ln -s "$ROOT_DIR/scripts/setup.sh" "$PROJECT_DIR/scripts/setup.sh"
ln -s "$ROOT_DIR/scripts/remove_container.sh" "$PROJECT_DIR/scripts/remove_container.sh"

export MOCK_STATE_DIR="$TEST_DIR/state"
export MOCK_IPTABLES="$ROOT_DIR/tests/mocks/iptables"
export MOCK_INCUS="$ROOT_DIR/tests/mocks/incus"
export MOCK_SYSCTL="$ROOT_DIR/tests/mocks/sysctl"
export PATH="$ROOT_DIR/tests/mocks:$PATH"
export MOCK_TIMEZONE=Australia/Sydney

mkdir -p "$MOCK_STATE_DIR"
printf '%s\n' '-s 203.0.113.10 -j DROP' > "$MOCK_STATE_DIR/iptables.rules"

run_setup() {
    WAYLAND_DISPLAY=wayland-0 \
        APT_SNAPSHOT_DATE=20250101T000000Z \
        "$PROJECT_DIR/scripts/setup.sh" > "$TEST_DIR/setup.log" 2>&1
}

assert_rule_count() {
    local expected="$1"
    local actual

    actual="$(wc -l < "$MOCK_STATE_DIR/iptables.rules")"
    [[ "$actual" == "$expected" ]] || {
        echo "Expected $expected firewall rules, found $actual" >&2
        cat "$MOCK_STATE_DIR/iptables.rules" >&2
        exit 1
    }
}

assert_tag_count() {
    local tag="$1"
    local expected="$2"
    local actual

    actual="$(grep -Fc -- "$tag" "$MOCK_STATE_DIR/iptables.rules" || true)"
    [[ "$actual" == "$expected" ]] || {
        echo "Expected $expected rules tagged $tag, found $actual" >&2
        cat "$MOCK_STATE_DIR/iptables.rules" >&2
        exit 1
    }
}

run_setup
assert_rule_count 3
assert_tag_count sandbox-incus-egress 1
assert_tag_count sandbox-incus-return 1
grep -Fq -- '-m comment --comment sandbox-incus-egress' "$MOCK_STATE_DIR/iptables.rules"
grep -Fq -- '-m comment --comment sandbox-incus-return' "$MOCK_STATE_DIR/iptables.rules"
grep -Fq -- 'APT_SNAPSHOT_DATE=20250101T000000Z' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'HOST_TIMEZONE=Australia/Sydney' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'HOST_COLOR_SCHEME=prefer-dark' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'HOST_GTK_THEME=Adwaita:dark bash -s' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'https://snapshot.debian.org/archive/debian/${APT_SNAPSHOT_DATE}/' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'apt-get "${APT_OPTIONS[@]}" install -y' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'tzdata' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'libglib2.0-bin' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'gsettings-desktop-schemas' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'timedatectl show --property=Timezone --value' "$ROOT_DIR/scripts/setup.sh"
grep -Fq -- 'is_valid_iana_timezone "$HOST_TIMEZONE"' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'ln -sfn -- "$TIMEZONE_FILE" /etc/localtime' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'gsettings get org.gnome.desktop.interface color-scheme' "$ROOT_DIR/scripts/setup.sh"
grep -Fq -- 'gsettings set' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- "' -- sandbox-color-scheme \"\$HOST_COLOR_SCHEME\"; then" "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'export XDG_RUNTIME_DIR=/run/user/1000' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'HOST_GTK_THEME="${HOST_GTK_THEME:-}"' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'BEGIN Sandbox-managed GTK_THEME' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'export GTK_THEME=%s' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'echo "GTK_THEME=${GTK_THEME:-}"' "$ROOT_DIR/scripts/setup.sh"
grep -Fq -- 'su - "$CONTAINER_USER" -s /bin/bash -c' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- '    gnome-keyring' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'CONTAINER_UID="1000"' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'systemctl --user add-wants default.target gnome-keyring-daemon.service' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'systemctl --user enable gnome-keyring-daemon.socket' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'loginctl enable-linger "$CONTAINER_USER"' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'systemctl start "user@${CONTAINER_UID}.service"' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'busctl --user status org.freedesktop.secrets' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' "$MOCK_STATE_DIR/container-script.sh"

! grep -Fq -- 'connect=unix:/run/user/1000/bus' "$MOCK_STATE_DIR/devices"
! grep -Fq -- 'connect=unix:/run/user/1000/runtime' "$MOCK_STATE_DIR/devices"
! grep -Fq -- '/etc/localtime' "$MOCK_STATE_DIR/devices"
! grep -Fq -- '/etc/timezone' "$MOCK_STATE_DIR/devices"
! grep -Eq -- '^dbus\||^runtime\||^pulse\|' "$MOCK_STATE_DIR/devices"
grep -Fq -- '|proxy|bind=container connect=unix:/run/user/1000/wayland-0' "$MOCK_STATE_DIR/devices"

run_setup
assert_rule_count 3
assert_tag_count sandbox-incus-egress 1
assert_tag_count sandbox-incus-return 1
[[ "$(grep -Fc -- 'incus config device add' "$MOCK_STATE_DIR/incus.log")" == 7 ]]
grep -Fqx -- '-s 203.0.113.10 -j DROP' "$MOCK_STATE_DIR/iptables.rules"

export MOCK_COLOR_SCHEME=prefer-light
run_setup
grep -Fq -- 'HOST_COLOR_SCHEME=prefer-light' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'HOST_GTK_THEME=Adwaita bash -s' "$MOCK_STATE_DIR/incus.log"

export MOCK_COLOR_SCHEME=default
run_setup
grep -Fq -- 'HOST_COLOR_SCHEME=default' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'HOST_GTK_THEME= bash -s' "$MOCK_STATE_DIR/incus.log"

unset MOCK_COLOR_SCHEME

export MOCK_GSETTINGS_UNAVAILABLE=1
run_setup
unset MOCK_GSETTINGS_UNAVAILABLE
grep -Fq -- 'Host gsettings is unavailable or does not expose the GNOME color-scheme setting; skipping color-scheme synchronization' "$TEST_DIR/setup.log"
grep -Fq -- 'HOST_COLOR_SCHEME=' "$MOCK_STATE_DIR/incus.log"
grep -Fq -- 'HOST_GTK_THEME= bash -s' "$MOCK_STATE_DIR/incus.log"

"$PROJECT_DIR/scripts/remove_container.sh" > "$TEST_DIR/remove.log" 2>&1
assert_rule_count 1
assert_tag_count sandbox-incus-egress 0
assert_tag_count sandbox-incus-return 0
grep -Fqx -- '-s 203.0.113.10 -j DROP' "$MOCK_STATE_DIR/iptables.rules"

echo "PASS: setup tags rules, reruns without duplicates, and cleanup preserves unrelated rules"
