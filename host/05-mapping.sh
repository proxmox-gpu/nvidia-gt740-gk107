#!/usr/bin/env bash
# 05-mapping.sh - create/update the cluster PCI resource mapping for the card.
# The path has no function number -> all functions (video + HDMI audio) are passed together.
# PVE validates vendor/device/subsystem/IOMMU group on every VM start.
# Ref: https://pve.proxmox.com/pve-docs/pve-admin-guide.html#resource_mapping
source "$(dirname "$0")/../lib/common.sh"
init
require_vars GPU MAP

D=/sys/bus/pci/devices/$GPU.0
[[ -e $D ]] || die "$D does not exist"
hex() { sed 's/^0x//' "$1"; }
GRP=$(basename "$(readlink -f "$D/iommu_group")")
MAPLINE="id=$(hex "$D/vendor"):$(hex "$D/device"),iommugroup=$GRP,node=$NODE,path=$GPU,subsystem-id=$(hex "$D/subsystem_vendor"):$(hex "$D/subsystem_device")"
DESC="$(lspci -s "${GPU#0000:}.0" | cut -d' ' -f2-)"

step "Mapping '$MAP'"
info "map: $MAPLINE"
if pvesh get "/cluster/mapping/pci/$MAP" >/dev/null 2>&1; then
  info "mapping exists - updating"
  pvesh set "/cluster/mapping/pci/$MAP" --map "$MAPLINE" --description "$DESC"
else
  pvesh create /cluster/mapping/pci --id "$MAP" --map "$MAPLINE" --description "$DESC"
fi

step "/etc/pve/mapping/pci.cfg"
sed 's/^/    /' /etc/pve/mapping/pci.cfg

check "mapping '$MAP' present with path=$GPU" bash -c "grep -A3 '^$MAP\$' /etc/pve/mapping/pci.cfg | grep 'path=$GPU,' >/dev/null"
summary "host/06-create-vm.sh"
