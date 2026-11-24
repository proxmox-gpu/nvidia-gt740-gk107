#!/usr/bin/env bash
# 01-preflight.sh - read-only inventory of the host + required packages:
# PVE version, CPU virtualization, the NVIDIA card and its functions, IOMMU state.
# Writes the detected GPU address and vendor:device IDs into .env (GPU=, IDS=).
source "$(dirname "$0")/../lib/common.sh"
init

step "Proxmox VE"
PVEVER=$(pveversion)
info "$PVEVER"
info "kernel: $(uname -r)"
if [[ $PVEVER =~ pve-manager/9\. ]]; then pass "PVE 9.x"; else fail "PVE 9.x expected"; fi

step "CPU virtualization"
VENDOR=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)
info "vendor: $VENDOR, model: $(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)"
case $VENDOR in
  GenuineIntel) check "VT-x (vmx) enabled" grep -qw vmx /proc/cpuinfo ;;
  AuthenticAMD) check "AMD-V (svm) enabled" grep -qw svm /proc/cpuinfo ;;
  *) fail "unknown CPU vendor $VENDOR" ;;
esac

step "NVIDIA display controllers"
mapfile -t CANDIDATES < <(
  for d in /sys/bus/pci/devices/*; do
    [[ $(cat "$d/vendor") == 0x10de && $(cat "$d/class") == 0x03* ]] && basename "$d"
  done
)
if ((${#CANDIDATES[@]} == 0)); then
  fail "no NVIDIA VGA/3D controller found (card seated? powered?)"
  summary
fi
for c in "${CANDIDATES[@]}"; do info "$(lspci -nns "${c#0000:}")"; done

if [[ -n ${GPU:-} ]]; then
  [[ -e /sys/bus/pci/devices/$GPU.0 ]] || die "GPU=$GPU from .env does not exist"
  info "using GPU=$GPU from .env"
elif ((${#CANDIDATES[@]} == 1)); then
  GPU=${CANDIDATES[0]%.*}
else
  die "several NVIDIA cards found - set GPU=<address without function> in .env"
fi

step "Functions of $GPU"
IDS=""
for f in /sys/bus/pci/devices/"$GPU".*; do
  id="$(sed 's/^0x//' "$f/vendor"):$(sed 's/^0x//' "$f/device")"
  IDS+="${IDS:+,}$id"
  drv=none
  [[ -e $f/driver ]] && drv=$(basename "$(readlink -f "$f/driver")")
  info "$(lspci -nns "$(basename "$f" | sed 's/^0000://')")  driver=$drv"
done
DEVID=$(sed 's/^0x//' "/sys/bus/pci/devices/$GPU.0/device")
SUBSYS="$(sed 's/^0x//' "/sys/bus/pci/devices/$GPU.0/subsystem_vendor"):$(sed 's/^0x//' "/sys/bus/pci/devices/$GPU.0/subsystem_device")"
info "IDS=$IDS  subsystem=$SUBSYS"
if [[ $DEVID == 0fc8 ]]; then
  pass "GK107 GeForce GT 740 (10de:0fc8)"
else
  warn "device 10de:$DEVID is not the GT 740 GK107 (10de:0fc8) this runbook targets - steps still apply to Kepler cards"
fi

if [[ $(cat "/sys/bus/pci/devices/$GPU.0/boot_vga" 2>/dev/null) == 1 ]]; then
  warn "the NVIDIA card is the BOOT VGA: the host console is shown on it. Prefer onboard graphics as primary in BIOS;"
  warn "otherwise the host console goes dark after vfio-pci takes the card (web UI keeps working)."
else
  pass "host console is not on the NVIDIA card (boot_vga=0)"
fi

step "IOMMU"
info "cmdline: $(cat /proc/cmdline)"
if compgen -G '/sys/class/iommu/*' >/dev/null; then
  pass "IOMMU active ($(ls /sys/class/iommu | tr '\n' ' '))"
  grp=$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU.0/iommu_group")")
  info "IOMMU group of $GPU.0: $grp"
else
  warn "IOMMU is not active yet -> host/02-iommu.sh"
fi
if dmesg | grep -iE 'Enabled IRQ remapping|Interrupt remapping enabled' >/dev/null; then
  pass "interrupt remapping enabled"
else
  warn "interrupt remapping not confirmed in dmesg (see README troubleshooting if VM start fails)"
fi

step "Required packages"
missing=()
for p in pciutils python3 curl genisoimage; do
  pkg_installed "$p" || missing+=("$p")
done
if [[ ${NV_INSTALL_MODE:-full} == driver-only ]] && ! pkg_installed 7zip; then missing+=(7zip); fi
if ((${#missing[@]})); then
  info "missing: ${missing[*]}"
  if confirm "apt install ${missing[*]}?"; then apt-get install -y "${missing[@]}"; fi
fi
for p in pciutils python3 curl genisoimage; do check "package $p" pkg_installed "$p"; done

step "Saving to .env"
config_set GPU "$GPU"
config_set IDS "$IDS"
info "GPU=$GPU"
info "IDS=$IDS"

summary "host/02-iommu.sh"
