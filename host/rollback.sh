#!/usr/bin/env bash
# rollback.sh - undo the passthrough, step by step with confirmations:
#   1. VM level  : detach the card from the VM (hostpci0 removed; driver/MSI stay in the guest)
#   2. host level: remove the lines added by 03-vfio.sh (other content of the files
#                  stays), rebuild initramfs -> card returns to the host
#                  after a reboot (IOMMU kernel parameter is left as is - it is harmless)
#   3. mapping   : delete the PCI resource mapping
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID MAP IDS

if vm_exists && vm_config_current | grep '^hostpci0:' >/dev/null; then
  if confirm "1) Detach the card from VM $VMID (shutdown, delete hostpci0)?"; then
    shutdown_vm 300
    qm set "$VMID" -delete hostpci0
    pass "hostpci0 removed from VM $VMID"
  fi
fi

if confirm "2) Return the card to the host (remove the added vfio lines, update-initramfs)?"; then
  if grep -lE "^hostpci[0-9]+:.*mapping=$MAP([,]|\$)" /etc/pve/qemu-server/*.conf 2>/dev/null; then
    warn "the VM configs listed above still reference mapping '$MAP' - they will fail to start"
  fi
  # only the lines added by 03-vfio.sh are removed; other content of these files is kept
  vfio_conf_lines | remove_lines "$VFIO_CONF"
  bl_conf_lines | remove_lines "$BL_CONF"
  mod_conf_lines | remove_lines "$MOD_CONF"
  update-initramfs -u -k all
  warn "reboot the host to release the card from vfio-pci"
fi

if pvesh get "/cluster/mapping/pci/$MAP" >/dev/null 2>&1 && confirm "3) Delete the resource mapping '$MAP'?"; then
  pvesh delete "/cluster/mapping/pci/$MAP"
  pass "mapping '$MAP' deleted"
fi

info "VM-level alternative: qm shutdown $VMID && qm rollback $VMID <clean-os|pre-driver|gpu-ok>"
summary
