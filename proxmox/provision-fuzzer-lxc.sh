#!/usr/bin/env bash
#
# Provisions an Ubuntu 24.04 wtf fuzzer node as an LXC container on a Proxmox
# VE host.
#
# Two modes:
#   default          unprivileged container, bochscpu backend only.
#   --kvm            privileged container with /dev/kvm bind-mounted, so the
#                    wtf kvm backend works at native (non-nested) speed.
#
# Usage:
#   # bochscpu-only worker:
#   ./provision-fuzzer-lxc.sh --ctid 9201 --hostname wtf-fuzz-lxc-01
#
#   # kvm-capable worker (privileged, /dev/kvm passed through):
#   ./provision-fuzzer-lxc.sh --ctid 9202 --hostname wtf-fuzz-kvm-01 --kvm
#
# Re-run with different --ctid for additional containers. First run downloads
# the Ubuntu LXC template automatically.

set -euo pipefail

CTID=""
HOSTNAME=""
STORAGE=local-lvm
TEMPLATE_STORAGE=local
BRIDGE=vmbr0
CORES=8
MEMORY=8192
SWAP=512
DISK_SIZE=20
SSH_KEY="${HOME}/.ssh/id_ed25519.pub"
CI_USER=wtf
WTF_REPO="https://github.com/0vercl0k/wtf.git"
WTF_BRANCH="main"
TEMPLATE_NAME="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
UNPRIVILEGED=1
PASS_KVM=0

usage() {
    sed -n '2,21p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ctid)              CTID=$2; shift 2 ;;
        --hostname)          HOSTNAME=$2; shift 2 ;;
        --storage)           STORAGE=$2; shift 2 ;;
        --template-storage)  TEMPLATE_STORAGE=$2; shift 2 ;;
        --bridge)            BRIDGE=$2; shift 2 ;;
        --cores)             CORES=$2; shift 2 ;;
        --memory)            MEMORY=$2; shift 2 ;;
        --swap)              SWAP=$2; shift 2 ;;
        --disk-size)         DISK_SIZE=$2; shift 2 ;;
        --ssh-key)           SSH_KEY=$2; shift 2 ;;
        --user)              CI_USER=$2; shift 2 ;;
        --wtf-repo)          WTF_REPO=$2; shift 2 ;;
        --wtf-branch)        WTF_BRANCH=$2; shift 2 ;;
        --kvm)               PASS_KVM=1; UNPRIVILEGED=0; shift ;;
        --privileged)        UNPRIVILEGED=0; shift ;;
        -h|--help)           usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$CTID" || -z "$HOSTNAME" ]]; then
    echo "error: --ctid and --hostname are required" >&2
    usage 1
fi
if ! command -v pct >/dev/null 2>&1; then
    echo "error: 'pct' not found. Run this on a Proxmox VE host." >&2
    exit 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo "error: ssh public key not found at $SSH_KEY (override with --ssh-key)" >&2
    exit 1
fi
if pct status "$CTID" >/dev/null 2>&1; then
    echo "error: container $CTID already exists" >&2
    exit 1
fi
if [[ "$PASS_KVM" == "1" && ! -e /dev/kvm ]]; then
    echo "error: --kvm requested but /dev/kvm doesn't exist on the host" >&2
    exit 1
fi

TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
    echo "downloading $TEMPLATE_NAME ..."
    pveam update
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi

pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --ostype ubuntu \
    --unprivileged "$UNPRIVILEGED" \
    --features nesting=1 \
    --onboot 0 \
    --ssh-public-keys "$SSH_KEY" \
    --start 0

# Pass /dev/kvm through to the container. Prefer the modern `--dev0` flag
# (Proxmox VE 8.2+); fall back to raw lxc.* config for older versions.
if [[ "$PASS_KVM" == "1" ]]; then
    if pct set "$CTID" --dev0 /dev/kvm 2>/dev/null; then
        echo "passed /dev/kvm via --dev0"
    else
        KVM_MAJMIN=$(stat -c '%t:%T' /dev/kvm)
        KVM_MAJOR=$((16#${KVM_MAJMIN%:*}))
        KVM_MINOR=$((16#${KVM_MAJMIN#*:}))
        cat >> "/etc/pve/lxc/${CTID}.conf" <<EOF
lxc.cgroup2.devices.allow: c ${KVM_MAJOR}:${KVM_MINOR} rwm
lxc.mount.entry: /dev/kvm dev/kvm none bind,create=file,optional
EOF
        echo "passed /dev/kvm via raw lxc.* config (major=${KVM_MAJOR}, minor=${KVM_MINOR})"
    fi
fi

pct start "$CTID"

# Wait for the network to come up before apt.
for _ in $(seq 1 30); do
    if pct exec "$CTID" -- getent hosts archive.ubuntu.com >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Bootstrap inside the container. Mirrors the VM cloud-init user-data.
pct exec "$CTID" -- bash -euxc "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y upgrade
    apt-get -y install build-essential clang clang-tools lld cmake ninja-build \
        git curl ca-certificates python3 python3-pip python3-venv pkg-config libssl-dev
    id -u ${CI_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${CI_USER}
    install -d -m 700 -o ${CI_USER} -g ${CI_USER} /home/${CI_USER}/.ssh
    cp /root/.ssh/authorized_keys /home/${CI_USER}/.ssh/authorized_keys 2>/dev/null || true
    chown ${CI_USER}:${CI_USER} /home/${CI_USER}/.ssh/authorized_keys 2>/dev/null || true
    echo '${CI_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${CI_USER}
    chmod 0440 /etc/sudoers.d/90-${CI_USER}
"

if [[ "$PASS_KVM" == "1" ]]; then
    # Make sure the kvm group exists with the host gid and that the wtf user
    # is in it, so wtf can use /dev/kvm without sudo.
    HOST_KVM_GID=$(stat -c '%g' /dev/kvm)
    pct exec "$CTID" -- bash -euxc "
        if ! getent group kvm >/dev/null; then
            groupadd -g ${HOST_KVM_GID} kvm
        else
            groupmod -g ${HOST_KVM_GID} kvm || true
        fi
        usermod -aG kvm ${CI_USER}
    "
fi

pct exec "$CTID" -- sudo -u "$CI_USER" -H bash -lc "
    cd ~ && git clone --branch '$WTF_BRANCH' '$WTF_REPO' wtf
    cd ~/wtf/src/build && CXX=clang++ CC=clang ./build-release.sh
    mkdir -p ~/wtf/targets
"

IP=$(pct exec "$CTID" -- bash -lc "ip -4 -o addr show eth0 | awk '{print \$4}' | cut -d/ -f1" | tr -d '\r\n')
echo
echo "container $CTID ('$HOSTNAME') ready."
echo "ssh ${CI_USER}@${IP}"
if [[ "$PASS_KVM" == "1" ]]; then
    echo
    echo "kvm backend enabled. /dev/kvm is bind-mounted from the host; ${CI_USER}"
    echo "is in the kvm group. Verify inside the CT: 'ls -l /dev/kvm' and"
    echo "'wtf fuzz --backend=kvm ...'."
else
    echo
    echo "note: this container cannot use the kvm backend. Run fuzz clients with"
    echo "      --backend=bochscpu (the wtf default)."
fi
