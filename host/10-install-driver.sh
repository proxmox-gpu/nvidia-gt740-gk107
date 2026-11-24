#!/usr/bin/env bash
# 10-install-driver.sh - install the NVIDIA driver in the guest WITHOUT a reboot, then
# enable MSI on all NVIDIA functions + RDP policies, and only then reboot the guest.
# Order matters: rebooting before MSI is enabled ends in an endless BSOD 0x116 loop.
#
#   1. snapshot pre-driver (disk only)
#   2. copy installer from the ISO, verify SHA256 + Authenticode (auto-add Entrust 2048 root)
#   3. pre-create MSI keys, run the installer detached (-s -noreboot), poll its exit code
#   4. re-apply MSI (installer may delete it), RDP policies, nvlddmkm Start=3
#   5. reboot the VM -> host/11-verify-gpu.sh
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID NV_FILE NV_SHA256 NV_LABEL GUEST_DIR

MODE=${NV_INSTALL_MODE:-full}
DRV_DIR="$GUEST_DIR\\driver"
ENTRUST_SHA1=503006091D97D4F5AE39F7CBE7927D7D652D3431
ENTRUST_URL="http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/$ENTRUST_SHA1.crt"
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-1200}

require_agent
vm_config_current | grep '^hostpci0:' >/dev/null || die "hostpci0 is not set - run host/08-attach-gpu.sh first"

step "Snapshot before the driver"
snapshot pre-driver "GPU attached, before NVIDIA $NV_VERSION"

# add_entrust_root -> downloads the root on the host, checks its SHA1, imports it in the guest
add_entrust_root() {
  local tmp pem fp
  tmp=$(mktemp -d)
  curl -fsS -o "$tmp/root.crt" "$ENTRUST_URL" || { rm -rf "$tmp"; return 1; }
  fp=$(openssl x509 -inform der -in "$tmp/root.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)
  info "downloaded root SHA1: $fp"
  [[ ${fp^^} == "$ENTRUST_SHA1" ]] || { rm -rf "$tmp"; err "unexpected certificate fingerprint"; return 1; }
  pem="$tmp/entrust2048.pem"
  openssl x509 -inform der -in "$tmp/root.crt" -out "$pem"
  guest_push "$pem" "$GUEST_DIR\\entrust2048.pem"
  rm -rf "$tmp"
  gx -- certutil.exe -addstore Root "$GUEST_DIR\\entrust2048.pem"
}

step "Preparing the installer in the guest ($MODE)"
guest_mkdir "$GUEST_DIR"
rc=0
guest_ps --timeout 300 prepare-driver.ps1 -Label "$NV_LABEL" -FileName "$NV_FILE" -Sha256 "$NV_SHA256" -Dest "$DRV_DIR" -Mode "$MODE" || rc=$?
if ((rc == 3)); then
  warn "installer signature cannot be validated: Entrust.net (2048) timestamping root is missing in the guest"
  info "adding it to LocalMachine\\Root ($ENTRUST_URL)"
  add_entrust_root || die "could not add the Entrust root"
  rc=0
  guest_ps --timeout 300 prepare-driver.ps1 -Label "$NV_LABEL" -FileName "$NV_FILE" -Sha256 "$NV_SHA256" -Dest "$DRV_DIR" -Mode "$MODE" || rc=$?
fi
((rc == 0)) || die "prepare-driver.ps1 failed (exit $rc) - see output above"
pass "installer copied, hash and signature valid"

step "Pre-creating MSI keys (before the installer touches the device)"
guest_ps enable-msi.ps1 || warn "enable-msi returned non-zero (re-applied after install)"

step "Running the installer detached (silent, -noreboot) - ~5 min"
guest_push "$GUEST_PS_DIR/run-installer.ps1" "$GUEST_DIR\\run-installer.ps1"
pid=$(gx_detach -- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "$GUEST_DIR\\run-installer.ps1" -Dir "$DRV_DIR" -FileName "$NV_FILE" -Mode "$MODE")
info "guest pid: ${pid:-?}"

t=0 code=""
while ((t < INSTALL_TIMEOUT)); do
  sleep 30
  t=$((t + 30))
  if ! qm guest cmd "$VMID" ping >/dev/null 2>&1; then
    err "guest agent stopped answering at ${t}s - the guest may have crashed (BSOD)."
    err "run host/rescue-bsod-loop.sh, or: qm stop $VMID && qm rollback $VMID pre-driver"
    exit 1
  fi
  code=$(gx -- cmd.exe /c type "$DRV_DIR\\install-rc.txt" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -n $code ]]; then break; fi
  info "installing... ${t}s"
done
[[ -n $code ]] || die "installer did not finish in ${INSTALL_TIMEOUT}s"
info "installer exit code: $code"
case $code in
  0) pass "installer finished (0)" ;;
  1) pass "installer finished (1 = reboot pending)" ;;
  -2146869243) die "TRUST_E_TIME_STAMP (0x80096005): signature check failed - see README troubleshooting" ;;
  *) die "installer failed with $code - see README troubleshooting" ;;
esac

step "Device state after install (expect NVIDIA GeForce GT 740: Error / CM_PROB_NEED_RESTART)"
guest_ps gpu-status.ps1 || true

apply_msi_and_policies

if ((FAIL_COUNT > 0)); then
  err "MSI/policies are NOT confirmed - do NOT reboot the guest. Fix and rerun host/fix-msi.sh"
  summary
fi

step "Rebooting VM $VMID (MSI is enabled - safe now)"
if confirm "Reboot VM $VMID now?"; then
  qm reboot "$VMID"
  info "rebooted"
else
  warn "reboot it yourself before host/11-verify-gpu.sh"
fi
summary "host/11-verify-gpu.sh"
