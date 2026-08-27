#!/usr/bin/env bash
# Step 1. Install amdgpu firmware. Run only if 00-preflight.sh reports a GPU problem.
#
# Symptom this fixes:
#   dmesg: "Direct firmware load for amdgpu/gc_9_4_3_rlc.bin failed with error -2"
#          "early_init of IP block <gfx_v9_4_3> failed -19"
#          "amdgpu: Fatal error during GPU init"
#          "amdgpu: no gpu node! Cannot create KFD process"
# /dev/kfd may still exist, but its topology nodes report simd_count 0, so every
# ROCm tool reports "no GPU". The cause is that the base image ships without the
# linux-firmware AMD blobs.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }

echo "== Installing amdgpu firmware =="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y linux-firmware-amd-graphics
update-initramfs -u

echo
echo "Firmware installed. A REBOOT IS REQUIRED."
echo
echo "Do NOT try 'modprobe -r amdgpu' to avoid the reboot. On a device that failed"
echo "init, the unload path crashes, leaves the module in state 'going' with"
echo "refcnt -1, and it cannot be reinserted ('Device or resource busy'). Only a"
echo "reboot recovers it, so just reboot now."
echo
read -rp "Reboot now? [y/N] " a
[ "${a,,}" = y ] && reboot || echo "Reboot manually, then re-run 00-preflight.sh"
