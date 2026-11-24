#!/usr/bin/env bash
# 04-verify-host.sh - after the host reboot: IOMMU on, card isolated in its IOMMU group,
# every function of the card bound to vfio-pci. Read-only.
source "$(dirname "$0")/../lib/common.sh"
init
require_vars GPU

step "Kernel"
info "kernel : $(uname -r)"
info "cmdline: $(cat /proc/cmdline)"
info "uptime : $(uptime -p)"

step "IOMMU"
# 'DMAR: IOMMU enabled' is not printed when the IOMMU is on by default -> check sysfs
check "IOMMU active (/sys/class/iommu not empty)" compgen -G '/sys/class/iommu/*'

step "IOMMU group of $GPU"
GRP_PATH=$(readlink -f "/sys/bus/pci/devices/$GPU.0/iommu_group" 2>/dev/null || true)
if [[ -z $GRP_PATH || ! -d $GRP_PATH ]]; then
  fail "no iommu_group for $GPU.0"
else
  info "group ${GRP_PATH##*/}:"
  foreign=0
  for dev in "$GRP_PATH"/devices/*; do
    bdf=${dev##*/}
    info "  $(lspci -nns "${bdf#0000:}")"
    [[ $(cat "$dev/class") == 0x0604* ]] && continue   # PCI bridges do not count
    [[ ${bdf%.*} == "$GPU" ]] || foreign=1
  done
  if ((foreign)); then
    fail "foreign devices share the IOMMU group - move the card to another PCIe slot (do NOT use pcie_acs_override)"
  else
    pass "only functions of the card in its IOMMU group"
  fi
fi

step "Drivers"
check "vfio_pci module loaded" bash -c "lsmod | grep '^vfio_pci ' >/dev/null"
for f in /sys/bus/pci/devices/"$GPU".*; do
  bdf=${f##*/}
  drv=none
  [[ -e $f/driver ]] && drv=$(basename "$(readlink -f "$f/driver")")
  info "$(lspci -nns "${bdf#0000:}")"
  if [[ $drv == vfio-pci ]]; then pass "$bdf -> vfio-pci"; else fail "$bdf -> $drv (expected vfio-pci)"; fi
done

step "Interrupt remapping"
if dmesg | grep -iE 'Enabled IRQ remapping|Interrupt remapping enabled' >/dev/null; then
  pass "interrupt remapping enabled"
else
  warn "interrupt remapping not confirmed (VM start may fail - see README troubleshooting)"
fi

summary "host/05-mapping.sh"
