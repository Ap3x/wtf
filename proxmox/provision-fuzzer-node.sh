#!/usr/bin/env bash
#
# Provisions an Ubuntu 24.04 fuzzer node on a Proxmox VE host. The node is
# cloud-init customized to install build deps, clone wtf, and build it. Run
# this on the Proxmox host.
#
# The first invocation downloads the Ubuntu cloud image and builds a reusable
# template (default VMID 9100). Subsequent invocations with --clone clone that
# template into a fresh fuzzer node.
#
# Usage:
#   # Build template once:
#   ./provision-fuzzer-node.sh --build-template
#
#   # Spin up a fuzzer node from the template:
#   ./provision-fuzzer-node.sh --clone --vmid 9101 --name wtf-fuzz-01
#
#   # Spin up the master node:
#   ./provision-fuzzer-node.sh --clone --vmid 9100 --name wtf-master \
#       --cores 2 --memory 4096

set -euo pipefail

ACTION=""
TEMPLATE_VMID=9099
VMID=""
NAME=""
STORAGE=local-lvm
BRIDGE=vmbr0
CORES=4
MEMORY=8192
DISK_SIZE=40G
SSH_KEY="${HOME}/.ssh/id_ed25519.pub"
CI_USER=wtf
WTF_REPO="https://github.com/0vercl0k/wtf.git"
WTF_BRANCH="main"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_CACHE="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    sed -n '2,22p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-template) ACTION=template; shift ;;
        --clone)          ACTION=clone; shift ;;
        --template-vmid)  TEMPLATE_VMID=$2; shift 2 ;;
        --vmid)           VMID=$2; shift 2 ;;
        --name)           NAME=$2; shift 2 ;;
        --storage)        STORAGE=$2; shift 2 ;;
        --bridge)         BRIDGE=$2; shift 2 ;;
        --cores)          CORES=$2; shift 2 ;;
        --memory)         MEMORY=$2; shift 2 ;;
        --disk-size)      DISK_SIZE=$2; shift 2 ;;
        --ssh-key)        SSH_KEY=$2; shift 2 ;;
        --user)           CI_USER=$2; shift 2 ;;
        --wtf-repo)       WTF_REPO=$2; shift 2 ;;
        --wtf-branch)     WTF_BRANCH=$2; shift 2 ;;
        -h|--help)        usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

if ! command -v qm >/dev/null 2>&1; then
    echo "error: 'qm' not found. Run this on a Proxmox VE host." >&2
    exit 1
fi
if [[ -z "$ACTION" ]]; then
    echo "error: pass --build-template or --clone" >&2
    usage 1
fi
if [[ ! -f "$SSH_KEY" ]]; then
    echo "error: ssh public key not found at $SSH_KEY (override with --ssh-key)" >&2
    exit 1
fi

build_template() {
    if qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
        echo "template VM $TEMPLATE_VMID already exists; skipping build"
        return
    fi

    if [[ ! -f "$IMG_CACHE" ]]; then
        echo "downloading Ubuntu cloud image..."
        wget -O "$IMG_CACHE" "$IMG_URL"
    fi

    qm create "$TEMPLATE_VMID" \
        --name wtf-fuzzer-template \
        --machine q35 \
        --cpu host \
        --cores 2 \
        --memory 4096 \
        --net0 "virtio,bridge=${BRIDGE}" \
        --scsihw virtio-scsi-single \
        --ostype l26 \
        --agent enabled=1 \
        --serial0 socket \
        --vga serial0

    qm importdisk "$TEMPLATE_VMID" "$IMG_CACHE" "$STORAGE" --format raw
    qm set "$TEMPLATE_VMID" \
        --scsi0 "${STORAGE}:vm-${TEMPLATE_VMID}-disk-0,discard=on,iothread=1"
    qm set "$TEMPLATE_VMID" --boot "order=scsi0"
    qm set "$TEMPLATE_VMID" --ide2 "${STORAGE}:cloudinit"

    # Render the cloud-init user-data with the wtf repo/branch baked in, then
    # stage it as a Proxmox snippet (requires the 'snippets' content type on
    # the chosen storage; defaults to local for snippets).
    local snippet_dir="/var/lib/vz/snippets"
    mkdir -p "$snippet_dir"
    sed \
        -e "s|@@CI_USER@@|${CI_USER}|g" \
        -e "s|@@WTF_REPO@@|${WTF_REPO}|g" \
        -e "s|@@WTF_BRANCH@@|${WTF_BRANCH}|g" \
        "${SCRIPT_DIR}/cloud-init/fuzzer-user-data.yaml" \
        > "${snippet_dir}/wtf-fuzzer-user.yaml"

    qm set "$TEMPLATE_VMID" \
        --cicustom "user=local:snippets/wtf-fuzzer-user.yaml" \
        --ciuser "$CI_USER" \
        --sshkeys "$SSH_KEY" \
        --ipconfig0 ip=dhcp

    qm template "$TEMPLATE_VMID"
    echo "template VM $TEMPLATE_VMID built."
}

clone_node() {
    if [[ -z "$VMID" || -z "$NAME" ]]; then
        echo "error: --clone requires --vmid and --name" >&2
        exit 1
    fi
    if ! qm status "$TEMPLATE_VMID" >/dev/null 2>&1; then
        echo "error: template $TEMPLATE_VMID not found; run --build-template first" >&2
        exit 1
    fi
    if qm status "$VMID" >/dev/null 2>&1; then
        echo "error: VM $VMID already exists" >&2
        exit 1
    fi

    qm clone "$TEMPLATE_VMID" "$VMID" --name "$NAME" --full 1 --storage "$STORAGE"
    qm resize "$VMID" scsi0 "$DISK_SIZE"
    qm set "$VMID" --cores "$CORES" --memory "$MEMORY"
    qm start "$VMID"
    echo "node $VMID ('$NAME') started; ssh ${CI_USER}@<vm-ip>"
}

case "$ACTION" in
    template) build_template ;;
    clone)    clone_node ;;
esac
