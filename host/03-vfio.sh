#!/usr/bin/env bash
# 03-vfio.sh - hand all functions of the card to vfio-pci at boot:
#   /etc/modprobe.d/vfio.conf            options vfio-pci ids=... + softdeps (vfio-pci wins the race)
#   /etc/modprobe.d/blacklist-gpu.conf   nouveau / nvidiafb never load on the host
#   /etc/modules-load.d/vfio.conf        vfio modules loaded early
# Files are never rewritten: only missing lines are appended to the end (backup first).
# Then update-initramfs for all kernels. Requires ONE host reboot afterwards.
# Ref: https://pve.proxmox.com/wiki/PCI(e)_Passthrough  (vfio-pci ids, softdep, blacklisting)
source "$(dirname "$0")/../lib/common.sh"
init
require_vars GPU IDS

step "Conflicting vfio-pci ids= settings"
conflicts=$(foreign_ids_lines)
if [[ -n $conflicts ]]; then
  printf '%s\n' "$conflicts" | sed 's/^/        /'
  die "another vfio-pci ids= list exists (lines above). Merge it by hand into one list, then rerun - nothing was changed"
fi
pass "no other vfio-pci ids= settings"

step "Appending missing lines"
vfio_conf_lines | append_lines "$VFIO_CONF"
bl_conf_lines | append_lines "$BL_CONF"
mod_conf_lines | append_lines "$MOD_CONF"

for f in "$VFIO_CONF" "$BL_CONF" "$MOD_CONF"; do
  info "$f:"
  sed 's/^/        /' "$f"
done

step "update-initramfs -u -k all (takes ~1 min)"
update-initramfs -u -k all

warn "check the configuration, then REBOOT THE HOST"
summary "host/03-vfio-check.sh, then reboot"
