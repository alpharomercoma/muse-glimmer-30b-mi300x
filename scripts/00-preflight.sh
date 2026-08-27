#!/usr/bin/env bash
# Step 0. Check the machine can run this stack. Read-only, changes nothing.
set -uo pipefail
fail=0
ok()   { printf '  [ OK ]  %s\n' "$1"; }
bad()  { printf '  [FAIL]  %s\n' "$1"; fail=1; }
warn() { printf '  [WARN]  %s\n' "$1"; }

echo "== Preflight =="

# 1. AMD Instinct present on the PCI bus.
if lspci 2>/dev/null | grep -qi "Instinct\|Aqua Vanjaram"; then
  ok "MI300X found: $(lspci | grep -i 'Aqua Vanjaram' | cut -d: -f3- | sed 's/^ //')"
else
  bad "No AMD Instinct GPU on the PCI bus."
fi

# 2. amdgpu kernel module loaded.
if lsmod | grep -q "^amdgpu"; then ok "amdgpu module loaded"
else bad "amdgpu module not loaded (modprobe amdgpu)"; fi

# 3. This is the check that actually matters. /dev/kfd can exist while the GPU
#    failed to initialise. A dummy node reports simd_count 0 and device_id 0.
if [ -e /dev/kfd ]; then
  real=0
  for n in /sys/class/kfd/kfd/topology/nodes/*/; do
    simd=$(grep -oP '^simd_count \K\d+' "$n/properties" 2>/dev/null || echo 0)
    [ "${simd:-0}" -gt 0 ] && real=1
  done
  if [ "$real" = 1 ]; then ok "KFD reports a real GPU node"
  else bad "KFD exists but every node is a stub (simd_count 0). GPU init failed; run 01-gpu-firmware.sh"; fi
else
  bad "/dev/kfd missing. GPU init failed; run 01-gpu-firmware.sh"
fi

# 4. amdgpu firmware blobs. Missing blobs are the usual root cause.
missing=""
for f in gc_9_4_3_rlc.bin psp_13_0_6_ta.bin psp_13_0_6_sos.bin sdma_4_4_2.bin vcn_4_0_3.bin; do
  # Ubuntu 26.04 ships these zstd-compressed, so accept .zst / .xz too.
  compgen -G "/lib/firmware/amdgpu/$f*" > /dev/null || missing="$missing $f"
done
if [ -z "$missing" ]; then ok "amdgpu firmware present"
else bad "missing amdgpu firmware:$missing  -> run 01-gpu-firmware.sh"; fi

# 5. Disk. Image is ~69 GB, weights ~52 GB.
avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${avail:-0}" -ge 150 ]; then ok "disk free: ${avail}G (need ~150G)"
else bad "disk free ${avail}G, need ~150G for image + weights"; fi

# 6. RAM. Weights are read through page cache during load.
ram=$(free -g | awk '/^Mem:/{print $2}')
if [ "${ram:-0}" -ge 64 ]; then ok "RAM: ${ram}G"; else warn "RAM ${ram}G is low; 64G+ recommended"; fi

echo
[ "$fail" = 0 ] && echo "Preflight passed." || { echo "Preflight FAILED. Fix the items above first."; exit 1; }
