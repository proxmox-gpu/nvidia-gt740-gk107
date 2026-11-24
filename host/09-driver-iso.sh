#!/usr/bin/env bash
# 09-driver-iso.sh - download the pinned NVIDIA driver on the HOST, verify SHA256, pack it
# into an ISO and insert it into the VM CD drive (hot). Faster and independent of the
# guest network. NV_INSTALL_MODE=driver-only additionally extracts the package (7z) so that
# only the Display.Driver component can be installed.
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID ISO_STORAGE NV_FILE NV_URL NV_ISO NV_LABEL

ISO=$(iso_path "$NV_ISO")
MODE=${NV_INSTALL_MODE:-full}

if [[ -f $ISO ]]; then
  info "$ISO already exists - reusing (delete it to rebuild)"
  if [[ -z ${NV_SHA256:-} ]]; then
    # the ISO carries the hash computed at build time
    SUM=$(isoinfo -J -i "$ISO" -x "/$NV_FILE.sha256" 2>/dev/null | cut -d' ' -f1)
    [[ $SUM =~ ^[0-9a-f]{64}$ ]] || die "NV_SHA256 is empty and $ISO has no $NV_FILE.sha256 - delete the ISO and rerun"
    warn "NV_SHA256 was empty - pinned the hash stored in the existing ISO: $SUM"
    config_set NV_SHA256 "$SUM"
  fi
else
  WORK=$(mktemp -d /var/tmp/nvdrv.XXXXXX)
  trap 'rm -rf "$WORK"' EXIT
  info "work dir: $WORK (needs ~2 GB free)"

  step "Downloading $NV_FILE"
  curl -fL --retry 3 -o "$WORK/$NV_FILE" "$NV_URL"
  SUM=$(sha256sum "$WORK/$NV_FILE" | cut -d' ' -f1)
  info "sha256: $SUM"
  if [[ -z ${NV_SHA256:-} ]]; then
    # NVIDIA publishes no hashes; authenticity is checked in the guest (Authenticode, step 10)
    warn "NV_SHA256 was empty - pinned the downloaded hash in .env (trust on first use)"
    config_set NV_SHA256 "$SUM"
    NV_SHA256=$SUM
  fi
  [[ $SUM == "$NV_SHA256" ]] || die "SHA256 mismatch (expected $NV_SHA256)"
  pass "driver SHA256 matches the pinned value"
  printf '%s  %s\n' "$SUM" "$NV_FILE" >"$WORK/$NV_FILE.sha256"

  graft=("$NV_FILE=$WORK/$NV_FILE" "$NV_FILE.sha256=$WORK/$NV_FILE.sha256")
  if [[ $MODE == driver-only ]]; then
    pkg_installed 7zip || die "package 7zip is required for NV_INSTALL_MODE=driver-only (apt install 7zip)"
    step "Extracting the package (driver-only mode)"
    7z x -y -bd -o"$WORK/extracted" "$WORK/$NV_FILE" >/dev/null
    [[ -f $WORK/extracted/setup.exe ]] || die "setup.exe not found after extraction"
    graft+=("extracted=$WORK/extracted")
  fi

  step "Building $ISO (label $NV_LABEL)"
  genisoimage -quiet -J -joliet-long -R -V "$NV_LABEL" -graft-points -o "$ISO.part" "${graft[@]}"
  mv "$ISO.part" "$ISO"
fi
info "$(du -h "$ISO" | cut -f1)  $ISO"

step "Inserting the ISO into VM $VMID (ide2)"
qm set "$VMID" -ide2 "$ISO_STORAGE:iso/$NV_ISO,media=cdrom"
check "ide2 = $NV_ISO" bash -c "qm config $VMID | grep '^ide2: .*$NV_ISO' >/dev/null"

summary "host/10-install-driver.sh"
