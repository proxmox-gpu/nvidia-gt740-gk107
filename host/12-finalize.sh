#!/usr/bin/env bash
# 12-finalize.sh - confirm that RDP used the NVIDIA hardware encoder, snapshot the
# working state "gpu-ok" and eject the driver ISO.
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID

require_agent

step "RDP hardware encoder (RdpCoreTS events 162/170)"
if guest_ps rdp-check.ps1; then
  pass "RDP sessions are encoded by NVIDIA H.264 Encoder MFT"
else
  warn "no event 170 with NVIDIA yet - open a NEW RDP session, play a video, rerun this script"
  confirm "Continue with the snapshot anyway?" || exit 1
fi

step "Final state"
check "all NVIDIA functions OK with MSI" guest_ps gpu-status.ps1 -Strict

if ((FAIL_COUNT == 0)); then
  snapshot gpu-ok "GT 740 + NVIDIA ${NV_VERSION:-} + MSI + RDP policies - working state"
  step "Ejecting the driver ISO"
  qm set "$VMID" -ide2 none,media=cdrom
fi
info "snapshots: $(qm listsnapshot "$VMID" | awk '{print $2}' | grep -v current | tr '\n' ' ')"
summary "done. Keep using qm shutdown/start; snapshots without RAM only"
