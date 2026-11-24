#!/usr/bin/env bash
# 03-vfio-check.sh - read-only check of the vfio-pci configuration written by 03-vfio.sh.
# Run it BEFORE the host reboot (is everything in place for the next boot?) and any time
# later. Checks:
#   - IDS in .env match the real functions of the card
#   - required lines in vfio.conf / blacklist-gpu.conf / modules-load.d/vfio.conf
#     (other content of these files is shown but not judged)
#   - effective modprobe configuration (modprobe -c) and conflicting files
#   - every initramfs contains the files and was rebuilt after they changed
#   - kernel command line for the next boot enables the IOMMU (if it is not active yet)
#   - current driver binding (vfio-pci expected after the reboot)
source "$(dirname "$0")/../lib/common.sh"
init
require_vars GPU IDS

# has_exact FILE LINE -> file exists and contains exactly this line
has_exact() { [[ -f $1 ]] && grep -qxF -- "$2" "$1"; }
# in_text REGEX TEXT -> TEXT contains a line matching REGEX
in_text() { grep -E "$1" <<<"$2" >/dev/null; }

# check_lines FILE GENERATOR -> one PASS/FAIL per required line
check_lines() {
  local path=$1 gen=$2 line
  step "$path"
  if [[ -f $path ]]; then sed 's/^/        /' "$path"; else info "(missing)"; fi
  while IFS= read -r line; do
    check "$line" has_exact "$path" "$line"
  done < <("$gen")
}

step "IDS vs. the card"
REAL_IDS=""
for f in /sys/bus/pci/devices/"$GPU".*; do
  REAL_IDS+="${REAL_IDS:+,}$(sed 's/^0x//' "$f/vendor"):$(sed 's/^0x//' "$f/device")"
done
info ".env IDS : $IDS"
info "card IDS : $REAL_IDS"
check "IDS in .env = functions of $GPU" test "$IDS" = "$REAL_IDS"

check_lines "$VFIO_CONF" vfio_conf_lines
check_lines "$BL_CONF" bl_conf_lines
check_lines "$MOD_CONF" mod_conf_lines

step "Effective modprobe configuration (modprobe -c)"
EFFECTIVE=$(modprobe -c)
grep -E '^options vfio[-_]pci ' <<<"$EFFECTIVE" | sed 's/^/        /' || true
check "modprobe sees vfio-pci ids=$IDS" in_text "^options vfio[-_]pci .*ids=$IDS( |\$)" "$EFFECTIVE"
check "modprobe sees blacklist nouveau" in_text '^blacklist nouveau$' "$EFFECTIVE"

step "Conflicts"
conflicts=$(foreign_ids_lines)
if [[ -n $conflicts ]]; then
  printf '%s\n' "$conflicts" | sed 's/^/        /'
  fail "another vfio-pci ids= list exists (lines above) - only one is applied, merge them by hand"
else
  pass "no other vfio-pci ids= settings"
fi
if grep -rE '^\s*vfio_virqfd' /etc/modules /etc/modules-load.d/ 2>/dev/null; then
  warn "vfio_virqfd is listed above - it does not exist in kernels 6.2+, remove it (systemd-modules-load error)"
fi
if grep -rlE '^\s*blacklist\s+vfio' /etc/modprobe.d/ 2>/dev/null; then
  fail "a file above blacklists vfio modules"
fi

step "initramfs (all installed kernels)"
newest_conf=$(stat -c %Y "$VFIO_CONF" "$BL_CONF" "$MOD_CONF" 2>/dev/null | sort -n | tail -1)
shopt -s nullglob
initrds=(/boot/initrd.img-*)
((${#initrds[@]})) || fail "no /boot/initrd.img-* found"
for img in "${initrds[@]}"; do
  kv=${img#/boot/initrd.img-}
  listing=$(lsinitramfs "$img" 2>/dev/null || true)
  ok=1
  for f in etc/modprobe.d/vfio.conf etc/modprobe.d/blacklist-gpu.conf; do
    grep -x "$f" <<<"$listing" >/dev/null || { ok=0; info "$kv: missing $f"; }
  done
  [[ -n $newest_conf && $(stat -c %Y "$img") -ge $newest_conf ]] || { ok=0; info "$kv: initramfs older than the config files"; }
  if ((ok)); then pass "initramfs $kv up to date"; else fail "initramfs $kv - rerun: update-initramfs -u -k all"; fi
done

step "IOMMU for the next boot"
if compgen -G '/sys/class/iommu/*' >/dev/null; then
  pass "IOMMU active now"
elif [[ -f /etc/kernel/proxmox-boot-uuids ]]; then
  check "intel_iommu=on in /etc/kernel/cmdline" grep -qw intel_iommu=on /etc/kernel/cmdline
else
  check "intel_iommu=on in /boot/grub/grub.cfg" grep -qw intel_iommu=on /boot/grub/grub.cfg
fi

step "Current driver binding"
bound=1
for f in /sys/bus/pci/devices/"$GPU".*; do
  drv=none
  [[ -e $f/driver ]] && drv=$(basename "$(readlink -f "$f/driver")")
  info "${f##*/} -> $drv"
  [[ $drv == vfio-pci ]] || bound=0
done
if ((bound)); then
  pass "all functions already on vfio-pci"
  NEXT="host/05-mapping.sh (or host/04-verify-host.sh)"
else
  info "not on vfio-pci yet - expected before the reboot"
  NEXT="reboot, then host/04-verify-host.sh"
fi

summary "$NEXT"
