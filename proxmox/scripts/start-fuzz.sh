#!/usr/bin/env bash
#
# Starts a wtf fuzz client. Run on a Proxmox-provisioned fuzzer VM or LXC.
# Points at the master by IP.
#
# Backend notes:
#   --backend=kvm in a nested-KVM VM:   needs sudo (PMU MSR access).
#   --backend=kvm in an LXC w/ --kvm:   no sudo (wtf user is in kvm group).
#   --backend=bochscpu (default):       no sudo, works anywhere.
#
# Usage:
#   ./start-fuzz.sh <target-name> <master-ip> [--backend=kvm|bochscpu] [wtf args...]
# Example:
#   ./start-fuzz.sh hevd 10.0.0.50 --backend=kvm --limit 10000000

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <target-name> <master-ip> [wtf args...]" >&2
    exit 1
fi

NAME=$1; shift
MASTER_IP=$1; shift
WTF_ROOT="${WTF_ROOT:-$HOME/wtf}"
TARGET_DIR="${WTF_ROOT}/targets/${NAME}"

if [[ ! -d "$TARGET_DIR/state" ]]; then
    echo "error: $TARGET_DIR/state not found. Sync target dir from the master." >&2
    exit 1
fi

cd "$TARGET_DIR"
exec "${WTF_ROOT}/src/build/wtf" fuzz \
    --name "$NAME" \
    --address "tcp://${MASTER_IP}:31337" \
    "$@"
