# Sandbox

A lightweight, unprivileged [Incus](https://linuxcontainers.org/incus/) development sandbox for running coding agents and GUI development applications with native Wayland and GPU access.

The sandbox provides an isolated Debian environment while keeping development files persistent on the host.

## Features

* Unprivileged Debian 13 Incus container
* Native Wayland GUI support
* Host GPU access through `/dev/dri`
* Persistent home and workspace directories
* IPv4 networking with NAT
* Reproducible setup through `scripts/setup.sh`

The setup script owns a project-specific Incus network named `sandboxbr0` and
records the absolute project path on both the network and container. Existing
resources with the same names are rejected unless they carry the matching
ownership marker and expected configuration.

## Directory Layout

```text
.
├── home/               # Persistent container home
├── workspace/          # Development projects
├── scripts/
│   └── setup.sh        # Sandbox setup script
├── LICENSE
└── README.md
```

### Host ↔ Container mounts

| Repository directory | Container path | Purpose                                            |
| -------------------- | -------------- | -------------------------------------------------- |
| `./home`             | `/home/user`   | Persistent user home and application configuration |
| `./workspace`        | `/workspace`   | Source code and development projects               |

The container can therefore be recreated without losing files stored in `home/` or `workspace/`.

## Requirements

The host requires:

* Linux with [Incus](https://linuxcontainers.org/incus/) installed (the setup
  script installs it with `apt-get` if it is missing)
* `sudo`
* A Wayland desktop session
* A GPU exposed through `/dev/dri`
* Host user with UID `1000`

The container uses:

```text
user: user
UID:  1000
```

## Setup

Clone the repository:

```bash
git clone https://github.com/coding5358/sandbox.git
cd sandbox
```

Run the setup script:

```bash
./scripts/setup.sh
```

For reproducible image and package inputs, provide a full Incus image
fingerprint and a Debian Snapshot timestamp:

```bash
IMAGE_FINGERPRINT=<64-character-sha256> \
APT_SNAPSHOT_DATE=YYYYMMDDTHHMMSSZ \
./scripts/setup.sh
```

Without these variables, the script uses the Debian 13 image alias and the
current Debian package repositories for convenience.

The script creates and configures the Incus container, including:

* Debian 13
* Persistent `/home/user` and `/workspace` mounts
* GPU access
* Wayland access
* Incus networking
* Container user and UID mapping

## Using the Sandbox

Enter the container:

```bash
incus exec sandbox -- sudo -u user bash
```

Or run a command directly:

```bash
incus exec sandbox -- sudo -u user <command>
```

The development workspace is available at:

```text
/workspace
```

and the persistent home directory at:

```text
/home/user
```

GUI applications launched inside the container use the host's Wayland display, while GPU-accelerated applications can access the host GPU.

## Architecture

```text
Host
│
├── ./home ───────────────► /home/user
├── ./workspace ──────────► /workspace
│
├── Wayland ── proxy ─────► /mnt/wayland/wayland-0
│
└── GPU ──────────────────► /dev/dri
                              │
                              ▼
                         Incus container
                         Debian 13
                         user (UID 1000)
```

The container is unprivileged and only the host resources required for development are exposed.

## License

See [LICENSE](LICENSE).
