#!/usr/bin/env bash
#
# Provisions a Windows target VM on a Proxmox VE host suitable for wtf
# snapshotting (1 vCPU, 4GB RAM, host-passthrough CPU, VirtIO disk + NIC, a
# host-side serial socket for KD over COM, and the VirtIO drivers ISO mounted
# as a second CD).
#
# Run this on the Proxmox host (or as root over SSH). After it finishes:
#   1. Open the noVNC console and complete Windows setup, loading VirtIO
#      storage drivers from the second CD when prompted for a disk.
#   2. Inside Windows, install windbg (Debugging Tools for Windows) and copy
#      snapshot.dll from https://github.com/0vercl0k/snapshot.
#   3. Optionally enable kernel debugging over COM1 (see proxmox/README.md).
#   4. Take the snapshot with `!snapshot` and copy state/ off to a fuzzer node.
#
# Usage:
#   ./provision-windows-target.sh \
#       --vmid 9000 \
#       --name wtf-win-target \
#       --iso local:iso/Win11.iso \
#       --virtio-iso local:iso/virtio-win.iso \
#       --storage local-lvm \
#       --bridge vmbr0
#
# All flags have defaults; only --iso and --virtio-iso are normally required.

set -euo pipefail

VMID=9000
NAME=wtf-win-target
ISO=""
VIRTIO_ISO=""
STORAGE=local-lvm
BRIDGE=vmbr0
DISK_SIZE=64G
MEMORY=4096
CORES=1
SERIAL_SOCKET=1   # expose COM1 as a unix socket on the host for KD

usage() {
    sed -n '2,28p' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vmid)        VMID=$2; shift 2 ;;
        --name)        NAME=$2; shift 2 ;;
        --iso)         ISO=$2; shift 2 ;;
        --virtio-iso)  VIRTIO_ISO=$2; shift 2 ;;
        --storage)     STORAGE=$2; shift 2 ;;
        --bridge)      BRIDGE=$2; shift 2 ;;
        --disk-size)   DISK_SIZE=$2; shift 2 ;;
        --memory)      MEMORY=$2; shift 2 ;;
        --cores)       CORES=$2; shift 2 ;;
        --no-serial)   SERIAL_SOCKET=0; shift ;;
        -h|--help)     usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$ISO" || -z "$VIRTIO_ISO" ]]; then
    echo "error: --iso and --virtio-iso are required" >&2
    usage 1
fi

if ! command -v qm >/dev/null 2>&1; then
    echo "error: 'qm' not found. Run this on a Proxmox VE host." >&2
    exit 1
fi

if qm status "$VMID" >/dev/null 2>&1; then
    echo "error: VM $VMID already exists. Pick a different --vmid." >&2
    exit 1
fi

# 1 vCPU + 4GB matches the wtf README recommendation. host CPU type so that
# the snapshot we take matches what the KVM backend will execute against.
qm create "$VMID" \
    --name "$NAME" \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:1,format=raw,efitype=4m,pre-enrolled-keys=1" \
    --cpu host \
    --cores "$CORES" \
    --sockets 1 \
    --memory "$MEMORY" \
    --balloon 0 \
    --ostype win11 \
    --scsihw virtio-scsi-single \
    --net0 "virtio,bridge=${BRIDGE}" \
    --agent enabled=1 \
    --tablet 0

qm set "$VMID" --ide0 "${ISO},media=cdrom"
qm set "$VMID" --ide1 "${VIRTIO_ISO},media=cdrom"
qm set "$VMID" --scsi0 "${STORAGE}:${DISK_SIZE%G},format=raw,discard=on,iothread=1"
qm set "$VMID" --boot "order=ide0;scsi0;ide1"

if [[ "$SERIAL_SOCKET" == "1" ]]; then
    qm set "$VMID" --serial0 socket
    echo
    echo "COM1 is exposed at /var/run/qemu-server/${VMID}.serial0 once the VM"
    echo "is running. Attach KD on a second VM/host with e.g.:"
    echo "    socat - UNIX-CONNECT:/var/run/qemu-server/${VMID}.serial0"
    echo "and inside Windows enable kernel debugging over COM1:"
    echo "    bcdedit /debug on"
    echo "    bcdedit /dbgsettings serial debugport:1 baudrate:115200"
fi

echo
echo "VM $VMID ('$NAME') created."
echo "Start it with:  qm start $VMID"
echo "Console:        https://<proxmox-host>:8006 -> $VMID -> Console"
