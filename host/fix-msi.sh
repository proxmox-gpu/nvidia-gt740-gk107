#!/usr/bin/env bash
# fix-msi.sh - (re)enable MSI on all NVIDIA functions, RDP policies, nvlddmkm Start=3,
# then reboot the guest. Use after host/rescue-bsod-loop.sh, after a driver upgrade,
# or after the card got a new PCI address in the guest (other slot / machine type).
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID

require_agent

step "NVIDIA functions before"
guest_ps gpu-status.ps1 || true

apply_msi_and_policies

if ((FAIL_COUNT > 0)); then
  err "MSI/policies NOT confirmed - do not reboot"
  summary
fi
if confirm "Reboot VM $VMID now?"; then
  qm reboot "$VMID"
fi
summary "host/11-verify-gpu.sh"
