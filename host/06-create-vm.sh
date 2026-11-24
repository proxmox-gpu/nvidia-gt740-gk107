#!/usr/bin/env bash
# 06-create-vm.sh - download the pinned virtio-win ISO (if missing) and create the VM:
# q35 + OVMF (Secure Boot keys pre-enrolled), host CPU, no ballooning, virtio-scsi-single
# with iothread, virtio NIC, virtio display (fallback noVNC console), guest agent enabled.
# The GPU is NOT attached yet - Windows is installed first (host/08 attaches it).
# Refs: https://pve.proxmox.com/wiki/Windows_2022_guest_best_practices
#       https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID VM_NAME STORAGE BRIDGE ISO_STORAGE WIN_ISO VIRTIO_ISO VIRTIO_URL CORES MEMORY DISK_SIZE

vm_exists && die "VM $VMID already exists - change VMID in .env or remove the VM"

step "Windows ISO"
WIN_PATH=$(iso_path "$WIN_ISO")
[[ -f $WIN_PATH ]] || die "$WIN_PATH not found - upload the Windows Server ISO to $ISO_STORAGE (GUI: storage -> ISO Images -> Upload)"
pass "$WIN_PATH ($(du -h "$WIN_PATH" | cut -f1))"

step "virtio-win $VIRTIO_VERSION"
VIRTIO_PATH=$(iso_path "$VIRTIO_ISO")
if [[ ! -f $VIRTIO_PATH ]]; then
  info "downloading $VIRTIO_URL"
  curl -fL --retry 3 -o "$VIRTIO_PATH.part" "$VIRTIO_URL"
  mv "$VIRTIO_PATH.part" "$VIRTIO_PATH"
fi
SUM=$(sha256sum "$VIRTIO_PATH" | cut -d' ' -f1)
info "sha256: $SUM"
if [[ -z ${VIRTIO_SHA256:-} ]]; then
  warn "VIRTIO_SHA256 is empty in .env. Compare the hash above with the one published next to the ISO,"
  warn "then pin it: VIRTIO_SHA256=$SUM"
elif [[ $SUM == "$VIRTIO_SHA256" ]]; then
  pass "virtio-win sha256 matches VIRTIO_SHA256"
else
  die "virtio-win sha256 mismatch (expected $VIRTIO_SHA256) - delete $VIRTIO_PATH and retry"
fi

VIOSCSI=2k25
if isoinfo -J -f -i "$VIRTIO_PATH" 2>/dev/null | grep -i '^/vioscsi/2k25/amd64/' >/dev/null; then
  pass "virtio-win has vioscsi\\2k25\\amd64 (Windows Server 2025)"
else
  VIOSCSI=2k22
  warn "no vioscsi\\2k25 in this virtio-win - use vioscsi\\2k22\\amd64 during setup"
fi

step "Creating VM $VMID ($VM_NAME)"
fmt=${DISK_FORMAT:+,format=$DISK_FORMAT}
args=(
  --name "$VM_NAME" --ostype win11
  --machine q35 --bios ovmf
  --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=1$fmt"
  --cpu host --sockets 1 --cores "$CORES" --numa 0
  --memory "$MEMORY" --balloon 0
  --scsihw virtio-scsi-single --scsi0 "$STORAGE:$DISK_SIZE,iothread=1,discard=on$fmt"
  --net0 "virtio,bridge=$BRIDGE"
  --vga virtio
  --agent enabled=1
  --ide2 "$ISO_STORAGE:iso/$WIN_ISO,media=cdrom"
  --ide0 "$ISO_STORAGE:iso/$VIRTIO_ISO,media=cdrom"
  --boot "order=scsi0;ide2"
)
if [[ ${TPM:-0} == 1 ]]; then args+=(--tpmstate0 "$STORAGE:1,version=v2.0"); fi
info "qm create $VMID ${args[*]}"
qm create "$VMID" "${args[@]}"

step "VM config"
qm config "$VMID" | sed 's/^/    /'
check "machine q35" bash -c "qm config $VMID | grep -E '^machine: .*q35' >/dev/null"
check "bios ovmf" bash -c "qm config $VMID | grep '^bios: ovmf' >/dev/null"
check "agent enabled" bash -c "qm config $VMID | grep -E '^agent: (1|enabled=1)' >/dev/null"

cat <<EOF

  MANUAL STEP - install Windows (PVE GUI -> VM $VMID -> Console):
   1. Start the VM and press any key at "Press any key to boot from CD or DVD" (~5 s; missed -> Reset).
   2. Windows Server (Desktop Experience) -> Custom. Disk list is empty:
      Load driver -> CD virtio-win -> vioscsi\\$VIOSCSI\\amd64
   3. After the first logon run virtio-win-guest-tools.exe from the virtio-win CD
      (virtio drivers + QEMU Guest Agent).
   4. Then: host/07-guest-baseline.sh  (RDP is enabled by the script)
EOF
summary "install Windows in the console, then host/07-guest-baseline.sh"
