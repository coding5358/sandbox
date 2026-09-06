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
grep -Fq -- 'https://snapshot.debian.org/archive/debian/${APT_SNAPSHOT_DATE}/' "$MOCK_STATE_DIR/container-script.sh"
grep -Fq -- 'apt-get "${APT_OPTIONS[@]}" install -y' "$MOCK_STATE_DIR/container-script.sh"

run_setup
assert_rule_count 3
assert_tag_count sandbox-incus-egress 1
assert_tag_count sandbox-incus-return 1
[[ "$(grep -Fc -- 'incus config device add' "$MOCK_STATE_DIR/incus.log")" == 7 ]]
grep -Fqx -- '-s 203.0.113.10 -j DROP' "$MOCK_STATE_DIR/iptables.rules"

"$PROJECT_DIR/scripts/remove_container.sh" > "$TEST_DIR/remove.log" 2>&1
assert_rule_count 1
assert_tag_count sandbox-incus-egress 0
assert_tag_count sandbox-incus-return 0
grep -Fqx -- '-s 203.0.113.10 -j DROP' "$MOCK_STATE_DIR/iptables.rules"

echo "PASS: setup tags rules, reruns without duplicates, and cleanup preserves unrelated rules"
