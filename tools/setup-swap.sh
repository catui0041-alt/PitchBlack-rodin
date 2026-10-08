#!/usr/bin/env bash
#
# setup-swap.sh — give the build a swap file large enough to survive Soong.
#
# An Android build of this size peaks well above the RAM of a standard GitHub
# runner; without swap the OOM killer takes out ninja/soong halfway through.
# This script only creates the missing capacity, and never touches an existing
# swap device.
#
# Read-only device/CI safe: needs sudo for swapon.
#
set -euo pipefail

MIN_SWAP_GIB="${MIN_SWAP_GIB:-12}"
SWAP_FILE="${SWAP_FILE:-/swapfile-build}"
HEADROOM_GIB=2

swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
swap_gib=$(( swap_kb / 1024 / 1024 ))

if (( swap_gib >= MIN_SWAP_GIB )); then
    echo "swap already sufficient: ${swap_gib} GiB (minimum ${MIN_SWAP_GIB} GiB)"
    exit 0
fi

needed_gib=$(( MIN_SWAP_GIB - swap_gib + HEADROOM_GIB ))
echo "swap is ${swap_gib} GiB; adding a ${needed_gib} GiB file at ${SWAP_FILE}"

free_kb="$(df -Pk "$(dirname "${SWAP_FILE}")" | awk 'NR == 2 {print $4}')"
free_gib=$(( free_kb / 1024 / 1024 ))
if (( free_gib < needed_gib + 4 )); then
    echo "error: ${free_gib} GiB free, a ${needed_gib} GiB swap file plus build output does not fit" >&2
    exit 1
fi

sudo swapoff "${SWAP_FILE}" 2>/dev/null || true
sudo rm -f "${SWAP_FILE}"
sudo fallocate -l "${needed_gib}G" "${SWAP_FILE}" || {
    echo "error: could not allocate ${needed_gib} GiB for swap" >&2
    exit 1
}
sudo chmod 600 "${SWAP_FILE}"
sudo mkswap "${SWAP_FILE}" >/dev/null
sudo swapon "${SWAP_FILE}"

awk '/^SwapTotal:/ {printf "swap total now: %.1f GiB\n", $2 / 1024 / 1024}' /proc/meminfo
