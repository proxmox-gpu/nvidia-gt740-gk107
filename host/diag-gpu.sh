#!/usr/bin/env bash
# diag-gpu.sh - read-only diagnostics for "the card is visible in the guest but does not start"
# (Code 43 CM_PROB_FAILED_POST_START, Code 10, Code 31). Collects in one log:
#   host:  VM config vs runbook defaults, QEMU command line for the card, PCI state
#          (driver, reset methods, link, BARs, ROM, MSI), IOMMU group, interrupt remapping,
#          kernel messages of the current boot;
#   guest: guest/diag-gpu.ps1 (problem code + status, driver package, events, setupapi).
# Nothing is changed on the host or in the VM.
#
#   ./host/diag-gpu.sh          # host + guest
#   ./host/diag-gpu.sh --rom    # additionally dump the card ROM and list its images
#                               # (only while no running VM holds the card)
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID GPU

DUMP_ROM=0
if [[ ${1:-} == --rom ]]; then DUMP_ROM=1; fi
DEV=/sys/bus/pci/devices/$GPU.0
BDF=${GPU#0000:}
[[ -e $DEV ]] || die "$DEV does not exist (GPU=$GPU in .env)"

# ------------------------------------------------------------- VM config ---
step "VM $VMID config"
vm_exists || die "VM $VMID does not exist"
info "status: $(vm_status)"
CONF=$(vm_config_current)
grep -E '^(machine|bios|cpu|ostype|hostpci[0-9]+|vga|args|balloon|memory|efidisk0):' <<<"$CONF" | sed 's/^/    /' || true

cfg() { awk -F': ' -v k="$1" '$1==k{print $2}' <<<"$CONF"; }
CPU=$(cfg cpu) MACHINE=$(cfg machine) BIOS=$(cfg bios) HOSTPCI=$(cfg hostpci0) ARGS=$(cfg args)

if [[ -n $HOSTPCI ]]; then pass "hostpci0 present"; else fail "hostpci0 missing - host/08-attach-gpu.sh"; fi
if [[ $HOSTPCI == *pcie=1* ]]; then pass "hostpci0 pcie=1"; else warn "hostpci0 without pcie=1 (runbook: mapping=$MAP,pcie=1)"; fi
if [[ $MACHINE == *q35* ]]; then pass "machine q35"; else warn "machine '${MACHINE:-i440fx}' - runbook needs q35"; fi
if [[ $BIOS == ovmf ]]; then pass "bios ovmf"; else warn "bios '${BIOS:-seabios}' - runbook uses ovmf"; fi
if [[ ${CPU%%,*} == host ]]; then
  pass "cpu host"
else
  warn "cpu '${CPU:-kvm64}' differs from the runbook (host/06-create-vm.sh uses --cpu host)"
fi
for opt in x-vga romfile rombar=0; do
  if [[ $HOSTPCI == *$opt* ]]; then warn "hostpci0 has '$opt' (not used by the runbook)"; fi
done
if [[ $CPU == *hidden=1* ]]; then warn "cpu has hidden=1 (not needed for driver >= 465)"; fi
if [[ -n $ARGS ]]; then warn "custom args: $ARGS"; fi

step "QEMU command line (card, CPU, Hyper-V flags)"
qm showcmd "$VMID" --pretty 2>/dev/null \
  | grep -E 'vfio-pci|-cpu |hv_|kvm=|-machine|romfile|x-vga|pcie-root-port|-device .*(ich9-pcie|pcie)' \
  | sed 's/^/    /' || warn "qm showcmd failed or printed nothing relevant"

step "Last VM start task (QEMU / vfio warnings)"
UPID=$(pvesh get "/nodes/$NODE/tasks" --vmid "$VMID" --typefilter qmstart --limit 1 --output-format json 2>/dev/null \
  | python3 -c 'import json,sys; t=json.load(sys.stdin); print(t[0]["upid"] if t else "")' || true)
if [[ -n $UPID ]]; then
  info "$UPID"
  pvesh get "/nodes/$NODE/tasks/$UPID/log" --output-format json 2>/dev/null \
    | python3 -c 'import json,sys; [print("    "+l.get("t","")) for l in json.load(sys.stdin)]' || true
else
  info "no qmstart task found"
fi

step "Mapping '$MAP'"
pvesh get "/cluster/mapping/pci/$MAP" --output-format json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("    "+m) for m in d.get("map",[])]' \
  || warn "mapping '$MAP' not found"

step "Other VMs referencing the card"
holders=0
for conf in /etc/pve/qemu-server/*.conf; do
  id=$(basename "$conf" .conf)
  [[ $id == "$VMID" ]] && continue
  if vm_config_current "$id" | grep -E "^hostpci[0-9]+:.*(mapping=$MAP([,]|\$)|$BDF)" >/dev/null; then
    st=$(qm status "$id" | awk '{print $2}')
    info "VM $id (status: $st)"
    [[ $st == running ]] && holders=$((holders + 1))
  fi
done
if ((holders)); then fail "another running VM holds the card"; else pass "no other running VM holds the card"; fi

# --------------------------------------------------------------- PCI state ---
step "PCI functions of $GPU"
lspci -nnk -s "$BDF" | sed 's/^/    /'
for f in /sys/bus/pci/devices/"$GPU".*; do
  rm_=$(cat "$f/reset_method" 2>/dev/null || true)
  info "$(basename "$f"): reset_method='${rm_}'  power_state=$(cat "$f/power_state" 2>/dev/null || echo ?)  d3cold_allowed=$(cat "$f/d3cold_allowed" 2>/dev/null || echo ?)"
done
RESET=$(cat "$DEV/reset_method" 2>/dev/null || true)
if [[ -z $RESET ]]; then
  warn "no reset method for $GPU.0: the card is handed to the VM in whatever state the previous"
  warn "guest left it. After a driver has run once, a cold host power cycle is the only clean reset."
elif [[ $RESET == *flr* ]]; then
  pass "reset methods: $RESET"
else
  info "reset methods without FLR: $RESET (normal for Kepler)"
fi
UPSTREAM=$(basename "$(dirname "$(readlink -f "$DEV")")")
info "upstream bridge: $UPSTREAM  ($(lspci -s "${UPSTREAM#0000:}" 2>/dev/null | cut -d' ' -f2- || echo ?))"
behind=()
for d in /sys/bus/pci/devices/"$UPSTREAM"/0000:*; do [[ -e $d ]] && behind+=("$(basename "$d")"); done
info "devices behind the bridge: ${behind[*]:-?}"

step "lspci -vvv $BDF.0 (link, BARs, ROM, MSI)"
lspci -vvv -s "$BDF.0" 2>/dev/null \
  | grep -E 'Region|Expansion ROM|LnkCap:|LnkSta:|MSI:|Kernel driver|Status:|DevSta:|UESta:|CESta:' \
  | sed 's/^\s*/    /' || true

step "IOMMU group"
GRP=$(basename "$(readlink -f "$DEV/iommu_group")")
info "group $GRP:"
for d in /sys/kernel/iommu_groups/"$GRP"/devices/*; do
  info "  $(lspci -nns "$(basename "$d" | sed 's/^0000://')")"
done
others=()
for d in /sys/kernel/iommu_groups/"$GRP"/devices/*; do
  [[ $(basename "$d") == "$GPU".* ]] || others+=("$(basename "$d")")
done
if ((${#others[@]} == 0)); then pass "IOMMU group holds only the card functions"; else warn "IOMMU group also holds: ${others[*]}"; fi

step "Interrupt remapping"
# dmesg may have rotated; /proc/interrupts shows IR-* chips only when remapping is active
if grep -qE 'IR-(PCI-MSI|IO-APIC)' /proc/interrupts; then
  pass "interrupt remapping active (IR-* in /proc/interrupts)"
else
  warn "no IR-* entries in /proc/interrupts - interrupt remapping looks inactive"
fi
grep -rH . /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts 2>/dev/null | sed 's/^/    /' || true

step "Kernel messages of the current boot (card, vfio, DMAR, AER) - last 60"
journalctl -k -b --no-pager -o short-iso 2>/dev/null \
  | grep -E "$BDF|vfio|DMAR|AER|BAR [0-9]| ROM | rom " | tail -60 | sed 's/^/    /' || true

# ---------------------------------------------------------------- ROM ---
rom_images() { python3 "$REPO_DIR/lib/rom_check.py" "$1" || true; }

if ((DUMP_ROM)); then
  step "Card ROM"
  if vm_running && [[ $HOSTPCI == *"$MAP"* || $HOSTPCI == *"$BDF"* ]] || ((holders)); then
    warn "a running VM holds the card - ROM dump skipped (stop the VM and rerun with --rom)"
  else
    ROM="$LOG_DIR/vbios-$BDF-$(date +%Y%m%d-%H%M%S).rom"
    # vfio-pci puts an unused device into D3hot (kernel param vfio-pci.disable_idle_d3);
    # in D3hot the ROM BAR reads as 0xffff. Bring it to D0 via PMCSR for the read, then restore.
    PS_BEFORE=$(cat "$DEV/power_state" 2>/dev/null || echo unknown)
    PMCSR=""
    if [[ $PS_BEFORE != D0 ]]; then
      PMCSR=$(setpci -s "$BDF.0" CAP_PM+4.w)
      info "power state $PS_BEFORE (PMCSR=0x$PMCSR) -> D0 for the ROM read"
      setpci -s "$BDF.0" CAP_PM+4.w=0000:0003
      sleep 0.1
    fi
    # read three times: an unstable ROM BAR gives different or truncated dumps
    sums=()
    for try in 1 2 3; do
      echo 1 >"$DEV/rom"
      if cat "$DEV/rom" >"$ROM.$try" 2>/dev/null; then :; else warn "read $try: $DEV/rom returned an I/O error after $(stat -c %s "$ROM.$try") bytes"; fi
      echo 0 >"$DEV/rom"
      sums+=("$(stat -c %s "$ROM.$try"):$(sha256sum "$ROM.$try" | cut -c1-16)")
    done
    info "reads (bytes:sha256): ${sums[*]}"
    if [[ ${sums[0]} == "${sums[1]}" && ${sums[1]} == "${sums[2]}" ]]; then
      pass "three ROM reads are identical"
    else
      warn "ROM reads differ - the ROM BAR is not read reliably"
    fi
    mv "$ROM.1" "$ROM"; rm -f "$ROM.2" "$ROM.3"
    if [[ -n $PMCSR ]]; then
      setpci -s "$BDF.0" CAP_PM+4.w="$PMCSR":0003
      info "power state restored: $(cat "$DEV/power_state" 2>/dev/null || echo ?)"
    fi
    journalctl -k --since -1min --no-pager 2>/dev/null | grep -E "$BDF.*ROM" | sed 's/^/    /' || true
    if [[ -s $ROM ]]; then
      info "saved: $ROM ($(stat -c %s "$ROM") bytes, sha256 $(sha256sum "$ROM" | cut -c1-16)...)"
      out=$(rom_images "$ROM")
      grep -vE '^(UEFI_GOP|ROM_STATUS)=' <<<"$out"
      case $(sed -n 's/^ROM_STATUS=//p' <<<"$out") in
        COMPLETE) pass "ROM dump complete, checksums ok" ;;
        TRUNCATED) warn "ROM dump is TRUNCATED - the ROM BAR does not return the whole image."
                   warn "QEMU passes the same ROM BAR to the guest; get a full dump (nvflash/GPU-Z on bare metal)." ;;
        *) warn "ROM dump is INVALID (bad header or checksum)" ;;
      esac
      case $(sed -n 's/^UEFI_GOP=//p' <<<"$out") in
        1) pass "ROM contains a UEFI GOP image (OVMF can initialise the card)" ;;
        0) warn "ROM has no UEFI GOP image: OVMF does not initialise the card. Use a GOP-capable ROM"
           warn "(vendor UEFI VBIOS) via hostpci0 romfile=, or a SeaBIOS VM." ;;
        *) warn "UEFI GOP presence unknown (dump incomplete)" ;;
      esac
    else
      rm -f "$ROM"
    fi
  fi
else
  info "ROM not checked (run with --rom while the VM is stopped)"
fi

# --------------------------------------------------------------- guest ---
if vm_running && wait_agent 30; then
  step "Guest diagnostics (guest/diag-gpu.ps1)"
  guest_ps --timeout 180 diag-gpu.ps1 || true
else
  warn "VM not running or guest agent not reachable - guest part skipped"
fi

step "Reading the result"
info "Code 43 = the driver loaded but the card failed to initialise. Typical causes, in order:"
info "  1. dirty card: empty reset_method and the VM was restarted after the driver had run"
info "     -> cold host power cycle, then qm start (not a guest reboot);"
info "  2. VM differs from the runbook (cpu/machine/bios/hostpci warnings above);"
info "  3. no UEFI GOP image in the card ROM (--rom) -> GOP-capable romfile=."
info "Kernel-PnP 411 and nvlddmkm events in the guest section show the status code of the failure."
summary
