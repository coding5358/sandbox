#!/usr/bin/env bash
set -Eeuo pipefail

INSTANCE="sandbox"
INCUS_NETWORK="sandboxbr0"
RESOURCE_OWNER_KEY="user.sandbox.project"
IPTABLES="/usr/sbin/iptables"
IPTABLES_EGRESS_COMMENT="sandbox-incus-egress"
IPTABLES_RETURN_COMMENT="sandbox-incus-return"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

log() {
    echo
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v sudo >/dev/null 2>&1 || die "Required command not found: sudo"
command -v incus >/dev/null 2>&1 || die "Required command not found: incus"

remove_tagged_iptables_rules() {
    local comment="$1"
    local line_number

    while true; do
        line_number="$(
            sudo "$IPTABLES" -L FORWARD --line-numbers -n -v 2>/dev/null |
                awk -v needle="$comment" 'index($0, needle) {print $1; exit}'
        )"

        [[ "$line_number" =~ ^[0-9]+$ ]] || break

        sudo "$IPTABLES" -D FORWARD "$line_number"
    done

    if sudo "$IPTABLES" -S FORWARD 2>/dev/null |
        awk -v needle="$comment" 'index($0, needle) {found=1} END {exit !found}'; then
        die "Could not remove all firewall rules tagged $comment"
    fi
}

INSTANCE_EXISTS=false

if sudo incus info "$INSTANCE" >/dev/null 2>&1; then
    INSTANCE_EXISTS=true

    INSTANCE_OWNER="$(
        sudo incus config get \
            "$INSTANCE" \
            "$RESOURCE_OWNER_KEY" \
            2>/dev/null || true
    )"

    [[ "$INSTANCE_OWNER" == "$PROJECT_DIR" ]] ||
        die "Instance $INSTANCE is not owned by this project; refusing to delete it"

    INSTANCE_STATE="$(
        sudo incus list "$INSTANCE" \
            -f csv \
            -c s
    )"

    if [[ "$INSTANCE_STATE" == "RUNNING" || "$INSTANCE_STATE" == "FROZEN" ]]; then
        log "Stopping $INSTANCE"
        sudo incus stop "$INSTANCE"
    fi

    log "Deleting $INSTANCE"
    sudo incus delete "$INSTANCE" --force
else
    log "$INSTANCE does not exist"
fi

NETWORK_OWNER="$(
    sudo incus network get \
        "$INCUS_NETWORK" \
        "$RESOURCE_OWNER_KEY" \
        2>/dev/null || true
)"

if [[ "$NETWORK_OWNER" == "$PROJECT_DIR" ]]; then
    [[ -x "$IPTABLES" ]] || die "iptables not found at $IPTABLES"
    sudo "$IPTABLES" -S FORWARD >/dev/null ||
        die "Could not inspect the host FORWARD chain"

    log "Removing sandbox firewall rules"
    remove_tagged_iptables_rules "$IPTABLES_EGRESS_COMMENT"
    remove_tagged_iptables_rules "$IPTABLES_RETURN_COMMENT"
else
    log "Skipping firewall cleanup because $INCUS_NETWORK is not owned by this project"
fi

log "Remaining containers"
sudo incus list

if [[ "$INSTANCE_EXISTS" == true ]]; then
    log "Sandbox removed"
else
    log "Nothing to remove"
fi
