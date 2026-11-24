#!/usr/bin/env bash
# 08-attach-gpu.sh - attach the card to the VM through the resource mapping:
# hostpci0: mapping=<MAP>,pcie=1 (q35 PCIe root port; on i440fx the driver ends in Code 43).
# Before that: no other running VM may hold the card, and if an NVIDIA driver is already
# installed in the guest it is disabled for one boot (it would start without MSI -> BSOD loop).
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID MAP GPU

vm_exists || die "VM $VMID does not exist"
pvesh get "/cluster/mapping/pci/$MAP" >/dev/null 2>&1 || die "mapping '$MAP' not found (host/05-mapping.sh)"

step "Machine type"
MACHINE=$(vm_config_current | awk -F': ' '/^machine:/{print $2}')
info "machine: ${MACHINE:-<default i440fx>}"
[[ $MACHINE == *q35* ]] || die "VM $VMID is not q35 - passthrough with pcie=1 needs q35 (README: troubleshooting)"
[[ $MACHINE == *viommu* ]] && die "machine has viommu=... - remove it, VM with a passed-through card will not start"
pass "q35 without vIOMMU"

step "Other VMs using the card"
busy=0
for conf in /etc/pve/qemu-server/*.conf; do
  id=$(basename "$conf" .conf)
  [[ $id == "$VMID" ]] && continue
  if vm_config_current "$id" | grep -E "^hostpci[0-9]+:.*(mapping=$MAP([,]|\$)|${GPU#0000:})" >/dev/null; then
    st=$(qm status "$id" | awk '{print $2}')
    info "VM $id references the card (status: $st)"
    [[ $st == running ]] && busy=1
  fi
done
((busy)) && die "the card is held by a running VM - stop it or remove its hostpci entry"
pass "no running VM holds the card"

if vm_running && wait_agent 60; then
  step "NVIDIA driver already installed in the guest?"
  out=$(guest_ps nvidia-precheck.ps1)
  printf '%s\n' "$out" | sed 's/^/    /'
  if grep -q 'DRIVER_PRESENT=1' <<<"$out"; then
    warn "NVIDIA driver is present: disabling nvlddmkm (Start=4) for the first boot with the card;"
    warn "host/10-install-driver.sh (or host/fix-msi.sh) enables MSI and sets Start=3 again."
    set_nvlddmkm_start 4
  fi
fi

step "Attaching the card"
shutdown_vm 300
qm set "$VMID" -hostpci0 "mapping=$MAP,pcie=1"
vm_config_current | grep '^hostpci0:' | sed 's/^/    /'
info "starting VM - 'failed to reset PCI device ... trying to continue' is NORMAL for Kepler (no FLR)"
qm start "$VMID"
wait_agent 600 || die "guest agent does not answer after attaching the card (console/noVNC; README troubleshooting)"

step "NVIDIA functions in the guest"
check "NVIDIA PCI functions visible in the guest" guest_ps gpu-status.ps1
info "expected now: video = 'Microsoft Basic Display Adapter' / Error (code 31) until the driver is installed"

summary "host/09-driver-iso.sh"
