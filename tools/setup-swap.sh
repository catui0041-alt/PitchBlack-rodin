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
# Never let swap eat the disk the checkout and its output need: the build fails
# on ENOSPC long after the OOM killer would have. On a standard runner with
# ~55 GiB free the swap file has to stay small.
MAX_SWAP_GIB="${MAX_SWAP_GIB:-10}"
DISK_RESERVE_GIB="${DISK_RESERVE_GIB:-30}"

swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
swap_gib=$(( swap_kb / 1024 / 1024 ))

if (( swap_gib >= MIN_SWAP_GIB )); then
    echo "swap already sufficient: ${swap_gib} GiB (minimum ${MIN_SWAP_GIB} GiB)"
    exit 0
fi

needed_gib=$(( MIN_SWAP_GIB - swap_gib + HEADROOM_GIB ))
if (( needed_gib > MAX_SWAP_GIB )); then
    echo "capping the swap file at ${MAX_SWAP_GIB} GiB (wanted ${needed_gib} GiB)"
    needed_gib="${MAX_SWAP_GIB}"
fi

echo "swap is ${swap_gib} GiB; adding a ${needed_gib} GiB file at ${SWAP_FILE}"

free_kb="$(df -Pk "$(dirname "${SWAP_FILE}")" | awk 'NR == 2 {print $4}')"
free_gib=$(( free_kb / 1024 / 1024 ))
if (( free_gib < needed_gib + 4 )); then
    echo "error: ${free_gib} GiB free, a ${needed_gib} GiB swap file plus build output does not fit" >&2
    exit 1
fi

# Keep DISK_RESERVE_GIB free for the source checkout and out/.
budget_gib=$(( free_gib - DISK_RESERVE_GIB ))
if (( budget_gib < 2 )); then
    echo "error: only ${free_gib} GiB free; keeping ${DISK_RESERVE_GIB} GiB for the build leaves no room for swap" >&2
    exit 1
fi
if (( needed_gib > budget_gib )); then
    echo "capping the swap file at ${budget_gib} GiB so that ${DISK_RESERVE_GIB} GiB stays free for the build"
    needed_gib="${budget_gib}"
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
