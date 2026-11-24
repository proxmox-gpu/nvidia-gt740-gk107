#!/usr/bin/env bash
# 02-iommu.sh - make sure the IOMMU is enabled.
# The PVE kernel enables the Intel IOMMU by default and AMD-Vi is on by default, so on most
# hosts nothing is changed. Only if /sys/class/iommu is empty on Intel, intel_iommu=on is added
# to the kernel command line of the bootloader actually in use (existing params are kept).
# Refs: https://pve.proxmox.com/wiki/PCI(e)_Passthrough
#       https://pve.proxmox.com/pve-docs/pve-admin-guide.html#sysboot_edit_kernel_cmdline
source "$(dirname "$0")/../lib/common.sh"
init

VENDOR=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)
TS=$(date +%Y%m%d%H%M%S)

step "Current state"
info "cmdline: $(cat /proc/cmdline)"
if compgen -G '/sys/class/iommu/*' >/dev/null; then
  pass "IOMMU already active - nothing to change"
  summary "host/03-vfio.sh"
  exit 0
fi

if [[ $VENDOR != GenuineIntel ]]; then
  fail "IOMMU not active on $VENDOR: enable IOMMU / AMD-Vi (SVM + IOMMU) in BIOS, kernel params are not needed"
  summary
fi

PARAM=intel_iommu=on
warn "IOMMU is not active. If VT-d is disabled in BIOS, enable it there first - the kernel parameter alone does not help."

if [[ -f /etc/kernel/proxmox-boot-uuids ]]; then
  # systemd-boot or GRUB managed by proxmox-boot-tool (ZFS root, UEFI)
  step "Bootloader: proxmox-boot-tool -> /etc/kernel/cmdline"
  F=/etc/kernel/cmdline
  cp -a "$F" "$F.bak-$TS"
  if grep -qw "$PARAM" "$F"; then
    info "$PARAM already present in $F"
  else
    sed -i "1 s/\$/ $PARAM/" "$F"
  fi
  info "$F: $(cat "$F")"
  proxmox-boot-tool refresh
else
  step "Bootloader: GRUB -> /etc/default/grub (GRUB_CMDLINE_LINUX_DEFAULT)"
  F=/etc/default/grub
  cp -a "$F" "$F.bak-$TS"
  if grep -E "^GRUB_CMDLINE_LINUX_DEFAULT=" "$F" | grep -w "$PARAM" >/dev/null; then
    info "$PARAM already present"
  else
    sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"/\1 $PARAM\"/" "$F"
  fi
  grep -E '^GRUB_CMDLINE_LINUX(_DEFAULT)?=' "$F" | while read -r l; do info "$l"; done
  update-grub
fi
info "backup: $F.bak-$TS"

check "$PARAM written to $F" grep -qw "$PARAM" "$F"
warn "a host reboot is required - do it once, after host/03-vfio.sh"
summary "host/03-vfio.sh"
