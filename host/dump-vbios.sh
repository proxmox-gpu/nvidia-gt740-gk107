#!/usr/bin/env bash
# dump-vbios.sh - save the full VBIOS of the card from inside the running guest with NVIDIA
# nvflash (read only: only "--list" and "--save" are run, the card is never flashed).
# Use it when the host-side ROM read (host/diag-gpu.sh --rom) is truncated or invalid.
#
# nvflash is not published by NVIDIA as a direct download; get "NVFlash for Windows" (zip)
# e.g. from https://www.techpowerup.com/download/nvidia-nvflash/ and put it at
# NVFLASH_ZIP (.env, default tools/nvflash.zip; tools/ is git-ignored). Pin NVFLASH_SHA256.
#
# Flow: verify zip SHA256 -> pack nvflash64.exe into an ISO -> insert it into an existing
# VM CD drive (hot, previous media restored afterwards) -> guest/dump-vbios.ps1 ->
# fetch the ROM via agent file-read (base64) -> verify SHA256 -> lib/rom_check.py.
# Result: logs/vbios-nvflash-<timestamp>.rom
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID ISO_STORAGE GUEST_DIR

NVFLASH_ZIP=${NVFLASH_ZIP:-tools/nvflash.zip}
[[ $NVFLASH_ZIP == /* ]] || NVFLASH_ZIP="$REPO_DIR/$NVFLASH_ZIP"
NVFLASH_ISO=${NVFLASH_ISO:-nvflash-tools.iso}
NVFLASH_LABEL=${NVFLASH_LABEL:-NVFLASH}
TS=$(date +%Y%m%d-%H%M%S)
OUT="vbios-nvflash-$TS.rom"

require_agent

step "nvflash package"
[[ -f $NVFLASH_ZIP ]] || die "no $NVFLASH_ZIP - download 'NVFlash for Windows' (zip) and put it there (see header)"
SUM=$(sha256sum "$NVFLASH_ZIP" | cut -d' ' -f1)
info "$NVFLASH_ZIP"
info "sha256: $SUM"
if [[ -z ${NVFLASH_SHA256:-} ]]; then
  warn "NVFLASH_SHA256 is empty in .env. Compare the hash above with the one on the download page,"
  warn "then pin it: NVFLASH_SHA256=$SUM"
elif [[ $SUM == "$NVFLASH_SHA256" ]]; then
  pass "nvflash zip sha256 matches NVFLASH_SHA256"
else
  die "nvflash zip sha256 mismatch (expected $NVFLASH_SHA256)"
fi

WORK=$(mktemp -d /var/tmp/nvflash.XXXXXX)
CD_SLOT="" CD_PREV=""
cleanup() {
  if [[ -n $CD_SLOT ]]; then
    if qm set "$VMID" "-$CD_SLOT" "$CD_PREV" >/dev/null 2>&1; then
      info "$CD_SLOT restored: $CD_PREV"
    else
      warn "could not restore $CD_SLOT to '$CD_PREV'"
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# nvflash64.exe (and its kernel driver files, if any) from the zip, flattened to the ISO root
python3 - "$NVFLASH_ZIP" "$WORK/iso" <<'PY'
import os, sys, zipfile
zf, dst = zipfile.ZipFile(sys.argv[1]), sys.argv[2]
os.makedirs(dst, exist_ok=True)
names = [n for n in zf.namelist() if not n.endswith('/')]
exe = [n for n in names if os.path.basename(n).lower() == 'nvflash64.exe']
if not exe:
    sys.exit('nvflash64.exe not found in the zip')
base = os.path.dirname(exe[0])
for n in names:
    if os.path.dirname(n) == base:
        with open(os.path.join(dst, os.path.basename(n)), 'wb') as f:
            f.write(zf.read(n))
        print('    packed: ' + os.path.basename(n))
PY

ISO=$(iso_path "$NVFLASH_ISO")
genisoimage -quiet -J -joliet-long -R -V "$NVFLASH_LABEL" -o "$ISO.part" "$WORK/iso"
mv "$ISO.part" "$ISO"
info "$(du -h "$ISO" | cut -f1)  $ISO"

step "Inserting the ISO into an existing CD drive of VM $VMID"
# media change on an existing drive is hot; adding a new IDE drive would need a VM restart
CONF=$(vm_config_current)
for slot in ide0 ide2 ide1 ide3; do
  line=$(awk -F': ' -v k="$slot" '$1==k{print $2}' <<<"$CONF")
  [[ $line == *media=cdrom* ]] || continue
  if [[ $line == none,* || $line == *"$NVFLASH_ISO"* ]]; then CD_SLOT=$slot CD_PREV="none,media=cdrom"; break; fi
  [[ -z $CD_SLOT ]] && CD_SLOT=$slot CD_PREV=$line
done
[[ -n $CD_SLOT ]] || die "VM $VMID has no CD drive (ide0-ide3, media=cdrom)"
info "using $CD_SLOT (current: $CD_PREV)"
qm set "$VMID" "-$CD_SLOT" "$ISO_STORAGE:iso/$NVFLASH_ISO,media=cdrom"
sleep 5   # let Windows mount the new media

step "Saving the VBIOS in the guest (guest/dump-vbios.ps1)"
ps_args=(-Label "$NVFLASH_LABEL" -Dest "$GUEST_DIR" -Out "$OUT")
[[ ${NVFLASH_ALLOW_UNSIGNED:-0} == 1 ]] && ps_args+=(-AllowUnsigned)
set +e
out=$(guest_ps --timeout 300 dump-vbios.ps1 "${ps_args[@]}")
rc=$?
set -e
printf '%s\n' "$out" | sed 's/^/    /'
case $rc in
  0) pass "nvflash saved the VBIOS in the guest" ;;
  3) die "nvflash64.exe is not validly signed by NVIDIA (set NVFLASH_ALLOW_UNSIGNED=1 only if you trust the file)" ;;
  *) die "guest/dump-vbios.ps1 failed (exit $rc) - see the output above" ;;
esac
GUEST_SHA=$(sed -n 's/^ROM SHA256 *: *//p' <<<"$out" | tr 'A-F' 'a-f' | tr -d '\r')

step "Fetching the ROM to the host"
LOCAL="$LOG_DIR/$OUT"
pvesh get "/nodes/$NODE/qemu/$VMID/agent/file-read" --file "$GUEST_DIR\\$OUT.b64" --output-format json \
  | python3 -c '
import base64, json, sys
d = json.load(sys.stdin)
if d.get("truncated"):
    sys.exit("agent file-read truncated the file")
open(sys.argv[1], "wb").write(base64.b64decode(d["content"].strip()))
' "$LOCAL"
LOCAL_SHA=$(sha256sum "$LOCAL" | cut -d' ' -f1)
info "$LOCAL ($(stat -c %s "$LOCAL") bytes)"
info "sha256 host: $LOCAL_SHA"
info "sha256 guest: ${GUEST_SHA:-?}"
check "ROM copied intact (sha256 host == guest)" test "$LOCAL_SHA" == "$GUEST_SHA"

step "ROM check (lib/rom_check.py)"
set +e
python3 "$REPO_DIR/lib/rom_check.py" "$LOCAL" | tee "$WORK/check"
set -e
case $(sed -n 's/^ROM_STATUS=//p' "$WORK/check") in
  COMPLETE) pass "ROM complete, checksums ok" ;;
  *) fail "ROM is not complete/valid" ;;
esac
case $(sed -n 's/^UEFI_GOP=//p' "$WORK/check") in
  1) pass "ROM contains a UEFI GOP image" ;;
  0) warn "ROM has no UEFI GOP image - OVMF will not initialise the card from it" ;;
  *) warn "UEFI GOP presence unknown" ;;
esac

info "to pass this ROM to the guest (not done by this script):"
info "  cp '$LOCAL' /usr/share/kvm/gt740.rom"
info "  qm set $VMID -hostpci0 mapping=$MAP,pcie=1,romfile=gt740.rom"
summary
