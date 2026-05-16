#!/usr/bin/env bash
#
# Starts a wtf master node. Run on the Proxmox-provisioned master VM.
#
# Usage:
#   ./start-master.sh <target-name> [extra wtf args...]
# Example:
#   ./start-master.sh hevd --max_len=1028 --runs=10000000

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <target-name> [extra wtf args...]" >&2
    exit 1
fi

NAME=$1; shift
WTF_ROOT="${WTF_ROOT:-$HOME/wtf}"
TARGET_DIR="${WTF_ROOT}/targets/${NAME}"

if [[ ! -d "$TARGET_DIR/state" ]]; then
    echo "error: $TARGET_DIR/state not found. Copy the snapshot (mem.dmp, regs.json, symbol-store.json) here first." >&2
    exit 1
fi

cd "$TARGET_DIR"
exec "${WTF_ROOT}/src/build/wtf" master \
    --name "$NAME" \
    --address tcp://0.0.0.0:31337 \
    "$@"
