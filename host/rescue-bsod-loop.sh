#!/usr/bin/env bash
# rescue-bsod-loop.sh - break an endless BSOD 0x116 loop (driver started without MSI).
# Waits for the short window in which the guest agent answers and disables the NVIDIA
# display driver service (nvlddmkm Start=4) + switches to small crash dumps (fast reboot).
# No InstanceId needed. Effective from the next boot; then run host/fix-msi.sh.
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID

MAX=${RESCUE_TIMEOUT:-1800}
vm_running || die "VM $VMID is not running"

step "Waiting for the guest agent window (up to ${MAX}s, Ctrl+C to abort)"
t=0
until qm guest cmd "$VMID" ping >/dev/null 2>&1; do
  sleep 1
  t=$((t + 1))
  ((t < MAX)) || die "agent never answered - alternative: qm stop $VMID && qm rollback $VMID pre-driver"
done
info "agent answered after ${t}s - applying"

check "nvlddmkm Start=4 (driver disabled)" \
  gx --timeout 15 -- reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' /v Start /t REG_DWORD /d 4 /f
check "CrashDumpEnabled=3 (small dump)" \
  gx --timeout 15 -- reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v CrashDumpEnabled /t REG_DWORD /d 3 /f

cat <<EOF

  The guest may crash once more; the NEXT boot starts without the NVIDIA driver (device code 32).
  When it is stable (agent answers for a minute):  host/fix-msi.sh  -> it enables MSI, sets Start=3, reboots.
  Crash details in the guest: C:\\Windows\\Minidump\\*.dmp, System event 1001 (BugCheck).
EOF
summary "host/fix-msi.sh"
