#!/usr/bin/env bash
# 11-verify-gpu.sh - after the reboot that follows the driver install:
#   - both NVIDIA functions OK, MSISupported=1, MSI interrupts
#   - nvidia-smi sees the card, no bugchecks, driver service Start=3, RDP policies
#   - watch the VM for WATCH_SECONDS (default 300): agent keeps answering, no vfio resets
#   - on success: CrashDumpEnabled back to 7 (automatic memory dump)
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID GPU

WATCH=${WATCH_SECONDS:-300}

require_agent 600

step "NVIDIA functions"
check "all NVIDIA functions OK with MSI" guest_ps gpu-status.ps1 -Strict

step "Driver"
check "driver checks (nvidia-smi, bugchecks, service, policies)" guest_ps verify-driver.ps1

step "Watching VM $VMID for ${WATCH}s (self-reboots / BSOD)"
T0=$(date '+%Y-%m-%d %H:%M:%S')
misses=0 t=0
while ((t < WATCH)); do
  sleep 15
  t=$((t + 15))
  if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
    printf '.'
  else
    misses=$((misses + 1))
    printf '!'
  fi
done
echo
RESETS=$(journalctl -k --since "$T0" | grep -cE "vfio-pci ${GPU}\.0: (resetting|reset done)" || true)
info "agent misses: $misses, vfio resets of $GPU.0 since $T0: $RESETS"
check "guest agent answered the whole time" test "$misses" -eq 0
check "no card resets (no guest reboots) during the watch" test "$RESETS" -eq 0

if ((FAIL_COUNT == 0)); then
  step "Crash dump mode back to automatic (7)"
  gx -- reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v CrashDumpEnabled /t REG_DWORD /d 7 /f
else
  warn "something failed: if the guest reboots in a loop -> host/rescue-bsod-loop.sh"
fi

cat <<'EOF'

  NEXT - check RDP acceleration manually:
   1. Open a NEW RDP session to the VM (policies apply to new sessions only).
   2. Play a video (e.g. in Edge) -> Task Manager -> Performance -> GPU "NVIDIA GeForce GT 740" shows load.
   3. Run host/12-finalize.sh - it looks for RdpCoreTS event 170 "NVIDIA H.264 Encoder MFT".
EOF
summary "RDP test, then host/12-finalize.sh"
