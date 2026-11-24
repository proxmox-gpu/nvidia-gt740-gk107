#!/usr/bin/env bash
# gpu-status.sh - quick read-only status: host side (driver binding, VM config, recent
# kernel messages for the card) and guest side (NVIDIA functions, MSI, IRQ).
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID GPU

step "Host"
lspci -nnk -s "${GPU#0000:}" | sed 's/^/    /'
info "VM $VMID: $(vm_status)"
vm_config_current | grep -E '^(hostpci|machine|bios|cpu|ide[0-9]):' | sed 's/^/    /'
step "Kernel messages for ${GPU#0000:} (last 30 min)"
journalctl -k --since -30min | grep -E "${GPU#0000:}|DMAR|AMD-Vi|AER" | tail -20 | sed 's/^/    /' || true

if vm_running && wait_agent 30; then
  step "Guest"
  guest_ps gpu-status.ps1 || true
else
  warn "guest agent not reachable - guest part skipped"
fi
