#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Incus IPv4-only development sandbox
# ============================================================
#
# Container:
#   sandbox
#
# Container user:
#   user / UID 1000
#
# Networking:
#   IPv4 only
#   Incus managed bridge
#   IPv4 NAT
#
# GUI:
#   Native Wayland
#   Narrow Unix-socket proxy
#   Host Wayland socket:
#       /run/user/1000/wayland-0
#
#   Container Wayland socket:
#       /mnt/wayland/wayland-0
#
# GPU:
#   Incus GPU device
#
# Re-running this script reconciles existing state rather than
# creating duplicate resources.
# ============================================================

INSTANCE="sandbox"
IMAGE="images:debian/13/amd64"

CONTAINER_USER="user"
CONTAINER_UID="1000"

INCUS_NETWORK="incusbr0"
INCUS_IPV4="10.138.67.1/24"

IPTABLES="/usr/sbin/iptables"

# ------------------------------------------------------------
# Logging / errors
# ------------------------------------------------------------

log() {
    echo
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ------------------------------------------------------------
# Determine project directory from setup.sh location
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

[[ "$(basename "$SCRIPT_DIR")" == "scripts" ]] ||
    die "setup.sh must be located inside a project's scripts/ directory"

HOST_HOME="${PROJECT_DIR}/home"
HOST_WORKSPACE="${PROJECT_DIR}/workspace"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

device_exists() {
    sudo incus config device show "$INSTANCE" 2>/dev/null |
        grep -q "^${1}:"
}

# Add an IPv4 FORWARD rule only when it doesn't already exist.
iptables_add_once() {
    if ! sudo "$IPTABLES" -C FORWARD "$@" >/dev/null 2>&1; then
        sudo "$IPTABLES" -I FORWARD 1 "$@"
    fi
}

# ------------------------------------------------------------
# Basic host checks
# ------------------------------------------------------------

require_command sudo
require_command incus
require_command ip

[[ -x "$IPTABLES" ]] ||
    die "iptables not found at $IPTABLES"

[[ -d "$PROJECT_DIR" ]] ||
    die "Project directory does not exist: $PROJECT_DIR"

mkdir -p "$HOST_HOME"
mkdir -p "$HOST_WORKSPACE"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

log "Host identity"

echo "UID: $HOST_UID"
echo "GID: $HOST_GID"

if [[ "$HOST_UID" != "$CONTAINER_UID" ]]; then
    die "Expected host UID $CONTAINER_UID, found $HOST_UID"
fi

# ------------------------------------------------------------
# Detect outbound IPv4 interface
# ------------------------------------------------------------

OUT_IFACE="$(
    ip -4 route show default |
        awk 'NR==1 {print $5}'
)"

[[ -n "$OUT_IFACE" ]] ||
    die "Could not determine default IPv4 interface"

log "IPv4 outbound interface: $OUT_IFACE"

# ------------------------------------------------------------
# Ensure Incus is installed
# ------------------------------------------------------------

log "Checking Incus installation"

if ! command -v incus >/dev/null 2>&1; then

    log "Installing Incus"

    sudo apt-get update
    sudo apt-get install -y incus

fi

# ------------------------------------------------------------
# incus-admin membership
# ------------------------------------------------------------

log "Checking incus-admin membership"

if getent group incus-admin >/dev/null 2>&1; then

    if ! id -nG "$USER" |
        tr ' ' '\n' |
        grep -qx incus-admin; then

        sudo usermod -aG incus-admin "$USER"

        echo "Added $USER to incus-admin."
        echo "Continuing with sudo; no newgrp/re-login required."

    fi

fi

# ------------------------------------------------------------
# Initialize Incus
# ------------------------------------------------------------

log "Checking Incus initialization"

if ! sudo incus info >/dev/null 2>&1; then

    log "Initializing Incus"

    sudo incus admin init --minimal

fi

# ------------------------------------------------------------
# IPv4-only Incus network
# ------------------------------------------------------------

log "Checking network: $INCUS_NETWORK"

if ! sudo incus network show "$INCUS_NETWORK" >/dev/null 2>&1; then

    log "Creating IPv4-only network"

    sudo incus network create "$INCUS_NETWORK" \
        ipv4.address="$INCUS_IPV4" \
        ipv4.nat=true \
        ipv6.address=none

else

    log "Reconciling existing network"

    sudo incus network set \
        "$INCUS_NETWORK" \
        ipv4.address "$INCUS_IPV4"

    sudo incus network set \
        "$INCUS_NETWORK" \
        ipv4.nat true

    # Explicitly remove IPv6 from the Incus network.
    sudo incus network set \
        "$INCUS_NETWORK" \
        ipv6.address none

fi

# ------------------------------------------------------------
# Storage pool
# ------------------------------------------------------------

log "Checking Incus storage"

STORAGE_POOL="$(
    sudo incus storage list --format csv 2>/dev/null |
        awk -F',' 'NF {print $1; exit}'
)"

if [[ -z "$STORAGE_POOL" ]]; then

    STORAGE_POOL="local"

    log "Creating storage pool: $STORAGE_POOL"

    sudo incus storage create "$STORAGE_POOL" dir

else

    log "Using existing storage pool: $STORAGE_POOL"

fi

# ------------------------------------------------------------
# Instance
# ------------------------------------------------------------

log "Checking instance: $INSTANCE"

if ! sudo incus info "$INSTANCE" >/dev/null 2>&1; then

    log "Creating instance"

    sudo incus init \
        "$IMAGE" \
        "$INSTANCE" \
        --storage "$STORAGE_POOL"

else

    log "Instance already exists"

fi

# ------------------------------------------------------------
# Instance configuration
# ------------------------------------------------------------

log "Configuring unprivileged container"

sudo incus config set \
    "$INSTANCE" \
    security.privileged false

# Direct host UID/GID mapping.
sudo incus config set \
    "$INSTANCE" \
    raw.idmap \
"uid ${HOST_UID} ${HOST_UID}"

# ------------------------------------------------------------
# Root disk
# ------------------------------------------------------------

log "Checking root disk"

if ! device_exists root; then

    sudo incus config device add \
        "$INSTANCE" \
        root \
        disk \
        path=/ \
        pool="$STORAGE_POOL"

else

    log "Root disk already exists"

fi

# ------------------------------------------------------------
# Network device
# ------------------------------------------------------------

log "Checking eth0"

if ! device_exists eth0; then

    sudo incus config device add \
        "$INSTANCE" \
        eth0 \
        nic \
        network="$INCUS_NETWORK" \
        name=eth0

else

    sudo incus config device set \
        "$INSTANCE" \
        eth0 \
        network "$INCUS_NETWORK"

fi

# ------------------------------------------------------------
# Project home
# ------------------------------------------------------------

log "Checking project home"

if ! device_exists project-home; then

    sudo incus config device add \
        "$INSTANCE" \
        project-home \
        disk \
        source="$HOST_HOME" \
        path="/home/${CONTAINER_USER}"

else

    sudo incus config device set \
        "$INSTANCE" \
        project-home \
        source "$HOST_HOME"

    sudo incus config device set \
        "$INSTANCE" \
        project-home \
        path="/home/${CONTAINER_USER}"

fi

# ------------------------------------------------------------
# Workspace
# ------------------------------------------------------------

log "Checking workspace"

if ! device_exists workspace; then

    sudo incus config device add \
        "$INSTANCE" \
        workspace \
        disk \
        source="$HOST_WORKSPACE" \
        path=/workspace

else

    sudo incus config device set \
        "$INSTANCE" \
        workspace \
        source "$HOST_WORKSPACE"

    sudo incus config device set \
        "$INSTANCE" \
        workspace \
        path=/workspace

fi

# ------------------------------------------------------------
# GPU
# ------------------------------------------------------------

log "Checking GPU"

if ! device_exists gpu; then

    sudo incus config device add \
        "$INSTANCE" \
        gpu \
        gpu

else

    log "GPU already configured"

fi

# ------------------------------------------------------------
# Start instance
# ------------------------------------------------------------

log "Checking instance state"

STATE="$(
    sudo incus list "$INSTANCE" \
        -f csv \
        -c s
)"

if [[ "$STATE" != "RUNNING" ]]; then

    log "Starting $INSTANCE"

    sudo incus start "$INSTANCE"

fi

# ------------------------------------------------------------
# Create Wayland proxy destination
# ------------------------------------------------------------
#
# The proxy listens inside the container at:
#
#   /mnt/wayland/wayland-0
#
# Therefore the parent directory must exist before the proxy
# is created.
# ------------------------------------------------------------

log "Preparing Wayland proxy directory"

sudo incus exec "$INSTANCE" -- mkdir -p /mnt/wayland

# ------------------------------------------------------------
# Wayland
# ------------------------------------------------------------
#
# IMPORTANT:
#
# Do NOT mount /run/user/1000 from the host.
#
# Do NOT use a disk device pointing directly at:
#
#   /run/user/1000/wayland-0
#
# Instead, use an Incus Unix socket proxy:
#
#   Host:
#       /run/user/1000/wayland-0
#
#        |
#        | Incus proxy
#        v
#
#   Container:
#       /mnt/wayland/wayland-0
#
# This exposes only the Wayland socket.
# ------------------------------------------------------------

log "Configuring Wayland proxy"

WAYLAND_DISPLAY_VALUE="${WAYLAND_DISPLAY:-wayland-0}"
WAYLAND_SOURCE="/run/user/${HOST_UID}/${WAYLAND_DISPLAY_VALUE}"
WAYLAND_LISTEN="/mnt/wayland/${WAYLAND_DISPLAY_VALUE}"

[[ -S "$WAYLAND_SOURCE" ]] ||
    die "Wayland socket not found: $WAYLAND_SOURCE"

# Remove any previous Wayland device.
#
# This deliberately handles old configurations such as:
#
#   type: disk
#
# or a proxy using an incorrect listen path.
#
# Recreating this one device makes the setup deterministic.
sudo incus config device remove \
    "$INSTANCE" \
    wayland \
    2>/dev/null || true

sudo incus config device add \
    "$INSTANCE" \
    wayland \
    proxy \
    bind=container \
    connect="unix:${WAYLAND_SOURCE}" \
    listen="unix:${WAYLAND_LISTEN}" \
    uid=1000 \
    gid=1000 \
    security.uid=1000 \
    security.gid=1000 \
    mode=0770

# ------------------------------------------------------------
# Remove old broad GUI devices
# ------------------------------------------------------------
#
# We intentionally do not expose:
#
#   /run/user/1000
#   D-Bus
#   PulseAudio/PipeWire
#
# The Wayland socket alone is sufficient for the GUI currently.
#
# Keeping these devices absent also reduces the host surface
# visible to applications inside the sandbox.
# ------------------------------------------------------------

log "Removing unnecessary GUI socket devices"

sudo incus config device remove \
    "$INSTANCE" \
    dbus \
    2>/dev/null || true

sudo incus config device remove \
    "$INSTANCE" \
    pulse \
    2>/dev/null || true

sudo incus config device remove \
    "$INSTANCE" \
    runtime \
    2>/dev/null || true

# ------------------------------------------------------------
# Host IPv4 forwarding
# ------------------------------------------------------------

log "Checking host IPv4 forwarding"

IP_FORWARD="$(
    sudo sysctl -n net.ipv4.ip_forward
)"

if [[ "$IP_FORWARD" != "1" ]]; then

    sudo sysctl -w net.ipv4.ip_forward=1

fi

# ------------------------------------------------------------
# Docker + Incus firewall compatibility
# ------------------------------------------------------------
#
# Docker may set:
#
#   FORWARD policy DROP
#
# Keep that policy.
#
# Explicitly allow Incus IPv4 traffic.
# ------------------------------------------------------------

log "Checking Incus IPv4 forwarding rules"

iptables_add_once \
    -i "$INCUS_NETWORK" \
    -o "$OUT_IFACE" \
    -j ACCEPT

iptables_add_once \
    -i "$OUT_IFACE" \
    -o "$INCUS_NETWORK" \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT

# ------------------------------------------------------------
# Restart instance
# ------------------------------------------------------------
#
# Restart after the final device configuration so the proxy
# starts cleanly.
# ------------------------------------------------------------

log "Restarting instance with final configuration"

sudo incus restart "$INSTANCE"

# ------------------------------------------------------------
# Container provisioning
# ------------------------------------------------------------

log "Provisioning container"

sudo incus exec "$INSTANCE" -- bash -s <<'CONTAINER_SCRIPT'

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

CONTAINER_USER="user"

# ============================================================
# APT IPv4-only
# ============================================================

echo "==> Configuring APT for IPv4"

cat > /etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "5";
EOF

# ============================================================
# Disable IPv6
# ============================================================

echo "==> Disabling IPv6"

cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

sysctl \
    -w net.ipv6.conf.all.disable_ipv6=1 \
    >/dev/null 2>&1 || true

sysctl \
    -w net.ipv6.conf.default.disable_ipv6=1 \
    >/dev/null 2>&1 || true

# ============================================================
# APT update
# ============================================================

echo "==> Updating package lists"

apt-get update

# ============================================================
# Base packages
# ============================================================

echo "==> Installing base packages"

apt-get install -y \
    sudo \
    ca-certificates \
    curl \
    wget \
    git \
    vim \
    nano \
    less \
    procps \
    iproute2 \
    iputils-ping \
    dnsutils \
    net-tools \
    file \
    build-essential \
    pkg-config \
    dbus \
    dbus-user-session \
    fuse3 \
    libfuse2t64 \
    libnspr4 \
    libnss3 \
    libasound2t64 \
    libwayland-client0 \
    libwayland-cursor0 \
    libwayland-egl1 \
    libxkbcommon0 \
    libegl1 \
    libgl1 \
    libgbm1 \
    mesa-utils \
    libvulkan1 \
    pulseaudio-utils \
    xdg-utils \
    desktop-file-utils

# ============================================================
# Container user
# ============================================================

echo "==> Checking container user"

if ! id "$CONTAINER_USER" >/dev/null 2>&1; then

    useradd \
        --create-home \
        --uid 1000 \
        --shell /bin/bash \
        "$CONTAINER_USER"

fi

if [[ "$(id -u "$CONTAINER_USER")" != "1000" ]]; then

    echo "ERROR: $CONTAINER_USER does not have UID 1000"

    exit 1

fi

# ============================================================
# Preserve existing shell configuration
# ============================================================
#
# Only populate files from /etc/skel when they don't already
# exist.
#
# This means user customizations survive setup.sh reruns.
# ============================================================

USER_HOME="/home/${CONTAINER_USER}"

for f in .bashrc .profile .bash_logout; do
    if [[ ! -e "${USER_HOME}/${f}" ]]; then
        cp "/etc/skel/${f}" "${USER_HOME}/${f}"
        chown 1000:1000 "${USER_HOME}/${f}"
    fi
done

# ============================================================
# Sudo
# ============================================================

echo "==> Configuring sudo"

cat > /etc/sudoers.d/container-user <<'EOF'
user ALL=(ALL) NOPASSWD:ALL
EOF

chmod 0440 /etc/sudoers.d/container-user

visudo -cf /etc/sudoers.d/container-user >/dev/null

# ============================================================
# Wayland runtime directory
# ============================================================
#
# We deliberately use /mnt/wayland as XDG_RUNTIME_DIR.
#
# The Incus proxy creates:
#
#   /mnt/wayland/wayland-0
#
# There is no need to expose the host's entire:
#
#   /run/user/1000
#
# directory.
# ============================================================

echo "==> Configuring Wayland runtime directory"

mkdir -p /mnt/wayland

chown 1000:1000 /mnt/wayland
chmod 0700 /mnt/wayland

# ============================================================
# GUI environment
# ============================================================

echo "==> Configuring GUI environment"

cat > "${USER_HOME}/.gui-env" <<'EOF'
# Incus Wayland GUI environment

export XDG_RUNTIME_DIR=/mnt/wayland
export WAYLAND_DISPLAY=wayland-0
export XDG_SESSION_TYPE=wayland
export ELECTRON_OZONE_PLATFORM_HINT=wayland
EOF

chown 1000:1000 \
    "${USER_HOME}/.gui-env"

# ============================================================
# Bash configuration
# ============================================================
#
# Keep Debian's original .bashrc.
#
# Only add the GUI environment source line if it isn't
# already present.
# ============================================================

echo "==> Configuring Bash"

BASHRC="${USER_HOME}/.bashrc"

if ! grep -Fqx \
    'source ~/.gui-env' \
    "$BASHRC" \
    2>/dev/null; then

    printf '\n# Incus GUI environment\nsource ~/.gui-env\n' \
        >> "$BASHRC"

fi

chown 1000:1000 "$BASHRC"

# ============================================================
# Do NOT recursively chown /home/user or /workspace
# ============================================================
#
# Both are host-backed paths.
#
# UID 1000 is mapped directly to host UID 1000 using raw.idmap.
#
# Recursively chowning these paths from inside the container
# would be undesirable and could alter host ownership.
# ============================================================

echo "==> Leaving host-mounted home/workspace ownership unchanged"

# ============================================================
# Verify Wayland socket
# ============================================================

echo "==> Checking Wayland socket"

if [[ -S /mnt/wayland/wayland-0 ]]; then

    ls -l /mnt/wayland/wayland-0

else

    echo "WARNING: Wayland socket is not currently visible."

    echo "The Incus proxy may not have connected yet."

fi

# ============================================================
# Network information
# ============================================================

echo "==> IPv4 configuration"

ip -4 addr show eth0 || true
ip -4 route || true

echo
echo "==> IPv6 configuration"

ip -6 addr show || true
ip -6 route show || true

echo
echo "==> Container provisioning complete"

CONTAINER_SCRIPT

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

log "Final Incus configuration"

sudo incus config show "$INSTANCE"

echo
echo "============================================================"
echo " Wayland verification"
echo "============================================================"

echo
echo "==> Wayland socket"

sudo incus exec "$INSTANCE" \
    -- ls -l /mnt/wayland/wayland-0

echo
echo "==> Wayland environment"

sudo incus exec "$INSTANCE" \
    -- su - "$CONTAINER_USER" -c '
        source ~/.gui-env
        echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
        echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
        echo "XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
        echo "ELECTRON_OZONE_PLATFORM_HINT=$ELECTRON_OZONE_PLATFORM_HINT"
    '

echo
echo "============================================================"
echo " IPv4 network verification"
echo "============================================================"

echo
echo "==> Container IPv4 addresses"

sudo incus exec "$INSTANCE" -- ip -4 addr

echo
echo "==> Container IPv4 routes"

sudo incus exec "$INSTANCE" -- ip -4 route

echo
echo "==> Incus gateway"

sudo incus exec "$INSTANCE" \
    -- ping -4 -c 3 10.138.67.1

echo
echo "==> Internet"

sudo incus exec "$INSTANCE" \
    -- ping -4 -c 3 1.1.1.1

echo
echo "==> DNS"

sudo incus exec "$INSTANCE" \
    -- getent ahostsv4 deb.debian.org

echo
echo "==> IPv6 status"

sudo incus exec "$INSTANCE" \
    -- ip -6 addr || true

echo
echo "============================================================"
echo " Incus sandbox setup complete"
echo "============================================================"
echo
echo "Instance:"
echo "  $INSTANCE"
echo
echo "Home:"
echo "  $HOST_HOME"
echo "    -> /home/$CONTAINER_USER"
echo
echo "Workspace:"
echo "  $HOST_WORKSPACE"
echo "    -> /workspace"
echo
echo "Network:"
echo "  $INCUS_NETWORK"
echo "  $INCUS_IPV4"
echo "  IPv4 NAT: enabled"
echo "  IPv6: disabled"
echo
echo "Wayland:"
echo "  Host:      $WAYLAND_SOURCE"
echo "  Container: $WAYLAND_LISTEN"
echo
echo "Enter container:"
echo "  ./shell.sh"
echo
echo "or:"
echo "  incus exec $INSTANCE -- su - $CONTAINER_USER"
echo
echo "Enter workspace:"
echo "  incus exec $INSTANCE -- su - $CONTAINER_USER -c 'cd /workspace && bash'"
echo
echo "Run ZCode:"
echo "  zcode"
echo
