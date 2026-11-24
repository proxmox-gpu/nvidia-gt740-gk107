#!/usr/bin/env bash
# Shared helpers for host-side scripts. Source it, do not execute:
#   source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_DIR/.env"
LOG_DIR="$REPO_DIR/logs"
GUEST_PS_DIR="$REPO_DIR/guest"
SCRIPT_NAME="$(basename "$0" .sh)"

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_BLU=$'\e[1;34m' C_OFF=$'\e[0m'
else
  C_RED='' C_GRN='' C_YEL='' C_BLU='' C_OFF=''
fi

step() { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%s[ERR ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '%s[PASS]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; }

# check "description" command [args...]  -> PASS/FAIL, never aborts the script
check() {
  local desc=$1; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# summary [next-step hint] -> prints totals, exits 1 if anything failed
summary() {
  printf '\n%s---- %s: %d passed, %d failed ----%s\n' "$C_BLU" "$SCRIPT_NAME" "$PASS_COUNT" "$FAIL_COUNT" "$C_OFF"
  [[ -n ${LOG_FILE:-} ]] && info "log: $LOG_FILE"
  if ((FAIL_COUNT > 0)); then
    printf '%sRESULT: FAIL%s\n' "$C_RED" "$C_OFF"
    exit 1
  fi
  printf '%sRESULT: PASS%s\n' "$C_GRN" "$C_OFF"
  [[ -n ${1:-} ]] && info "next: $1"
  return 0
}

# confirm "question" -> 0 on yes. ASSUME_YES=1 answers yes automatically.
confirm() {
  [[ ${ASSUME_YES:-0} == 1 ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

# ----------------------------------------------------------------- setup ---
require_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

require_pve() {
  if ! command -v qm >/dev/null || ! command -v pvesh >/dev/null; then
    die "this is not a Proxmox VE host (qm/pvesh not found)"
  fi
}

load_config() {
  [[ -f $CONFIG ]] || die "no $CONFIG - run: cp .env.example .env && edit it"
  source "$CONFIG"
  NODE="${NODE:-$(hostname -s)}"
  GUEST_ENCODING="${GUEST_ENCODING:-auto}"
  export GUEST_ENCODING
}

# require_vars VAR... -> dies if any is empty
require_vars() {
  local v
  for v in "$@"; do
    [[ -n ${!v:-} ]] || die "$v is empty in .env"
  done
}

# config_set KEY VALUE -> updates (or appends) KEY=VALUE in .env
config_set() {
  local key=$1 value=$2
  if grep -q "^${key}=" "$CONFIG"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG"
  else
    printf '%s=%s\n' "$key" "$value" >>"$CONFIG"
  fi
}

# start_log -> duplicates stdout/stderr into logs/<script>-<timestamp>.log
start_log() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "$(date -Is) $SCRIPT_NAME on $(hostname -f 2>/dev/null || hostname)"
}

# init -> standard preamble for every host script
init() {
  require_root
  require_pve
  load_config
  start_log
}

# ------------------------------------------------------------------- VM ---
vm_exists() { qm status "$VMID" >/dev/null 2>&1; }
vm_status() { qm status "$VMID" 2>/dev/null | awk '{print $2}'; }
vm_running() { [[ $(vm_status) == running ]]; }

# vm_config_current -> config of the VM without snapshot sections
vm_config_current() { awk '/^\[/{exit} {print}' "/etc/pve/qemu-server/${1:-$VMID}.conf"; }

snapshot_exists() { qm listsnapshot "$VMID" 2>/dev/null | grep -w -- "$1" >/dev/null; }

# snapshot NAME "description" -> creates a disk-only snapshot unless it exists
snapshot() {
  local name=$1 desc=${2:-}
  if snapshot_exists "$name"; then
    info "snapshot '$name' already exists - skipped"
    return 0
  fi
  step "Snapshot '$name'"
  qm snapshot "$VMID" "$name" --description "$desc"
}

# shutdown_vm [timeout] -> clean shutdown, waits until stopped
shutdown_vm() {
  local timeout=${1:-300}
  vm_running || return 0
  step "Shutting down VM $VMID (timeout ${timeout}s)"
  qm shutdown "$VMID" --timeout "$timeout" || die "VM $VMID did not shut down in ${timeout}s"
}

# wait_agent [timeout] -> waits until the guest agent answers
wait_agent() {
  local timeout=${1:-300} t=0
  info "waiting for guest agent (up to ${timeout}s)..."
  until qm guest cmd "$VMID" ping >/dev/null 2>&1; do
    sleep 3
    t=$((t + 3))
    ((t < timeout)) || return 1
  done
  info "guest agent is up after ~${t}s"
}

# guest_ip -> first IPv4 of the guest (not loopback, not APIPA)
guest_ip() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json, sys
for iface in json.load(sys.stdin):
    for a in iface.get("ip-addresses", []):
        ip = a.get("ip-address", "")
        if a.get("ip-address-type") == "ipv4" and not ip.startswith(("127.", "169.254.")):
            print(ip); sys.exit(0)
'
}

# ---------------------------------------------------------- guest agent ---
# gx [--timeout N] -- program args...
#   Runs a program in the guest via the agent and prints its output decoded to
#   UTF-8 (CP866/UTF-8 autodetect per line, see lib/gx_decode.py).
#   Returns the guest exit code. Every in-guest call in this repo goes through gx.
gx() {
  local timeout=60 json
  if [[ ${1:-} == --timeout ]]; then timeout=$2; shift 2; fi
  [[ ${1:-} == -- ]] && shift
  json=$(qm guest exec "$VMID" --timeout "$timeout" -- "$@") || {
    err "qm guest exec failed: $*"
    return 255
  }
  printf '%s' "$json" | python3 "$REPO_DIR/lib/gx_decode.py"
}

# gx_detach -- program args...  -> starts a guest process without waiting, prints pid
gx_detach() {
  [[ ${1:-} == -- ]] && shift
  qm guest exec "$VMID" --timeout 0 -- "$@" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pid",""))'
}

guest_mkdir() {
  gx -- cmd.exe /c if not exist "$1\\" mkdir "$1" >/dev/null
}

# guest_push LOCAL_FILE GUEST_PATH -> writes an ASCII file into the guest
guest_push() {
  local src=$1 dst=$2
  [[ -f $src ]] || die "no such file: $src"
  if LC_ALL=C grep -qP '[^\x00-\x7F]' "$src"; then
    die "$src contains non-ASCII characters: agent file-write accepts ASCII only"
  fi
  pvesh create "/nodes/$NODE/qemu/$VMID/agent/file-write" --file "$dst" --content "$(cat "$src")" >/dev/null
}

# guest_ps [--timeout N] SCRIPT.ps1 [args...]
#   Copies guest/SCRIPT.ps1 to GUEST_DIR and runs it with Windows PowerShell.
guest_ps() {
  local timeout=120
  if [[ ${1:-} == --timeout ]]; then timeout=$2; shift 2; fi
  local name=$1; shift
  local dst="$GUEST_DIR\\$name"
  guest_mkdir "$GUEST_DIR"
  guest_push "$GUEST_PS_DIR/$name" "$dst"
  gx --timeout "$timeout" -- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$dst" "$@"
}

# require_agent -> VM must be running and the agent must answer
require_agent() {
  vm_exists || die "VM $VMID does not exist"
  vm_running || die "VM $VMID is not running (qm start $VMID)"
  wait_agent "${1:-120}" || die "guest agent of VM $VMID does not answer"
}

# iso_path FILE -> absolute path of FILE in ISO_STORAGE
iso_path() { pvesm path "$ISO_STORAGE:iso/$1"; }

# apply_msi_and_policies -> MSI on all NVIDIA functions + RDP policies + driver start=3
apply_msi_and_policies() {
  step "Enabling MSI on all NVIDIA functions"
  check "MSISupported=1 on all present NVIDIA functions" guest_ps enable-msi.ps1
  step "RDP hardware acceleration policies"
  check "RDP policies set" guest_ps rdp-policies.ps1
  step "NVIDIA display driver service start type -> 3 (demand)"
  check "nvlddmkm Start=3" set_nvlddmkm_start 3
}

set_nvlddmkm_start() {
  gx -- reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' >/dev/null 2>&1 || {
    info "nvlddmkm service not present (driver not installed yet) - skipped"
    return 0
  }
  gx -- reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm' /v Start /t REG_DWORD /d "$1" /f
}

# ------------------------------------------------------- config files ---
# Host config files are never rewritten: missing lines are appended to the end,
# lines that are already there are left alone. A backup is made before any change.

# append_lines FILE <<LINES -> appends every line of LINES that FILE does not contain yet
append_lines() {
  local path=$1 line added=0 bak=""
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    if [[ -f $path ]] && grep -qxF -- "$line" "$path"; then
      continue
    fi
    if [[ -z $bak && -f $path ]]; then
      bak="$path.bak-$(date +%Y%m%d%H%M%S)"
      cp -a "$path" "$bak"
      info "backup: $bak"
    fi
    # make sure the file ends with a newline before appending
    if [[ -s $path && -n $(tail -c1 "$path") ]]; then echo >>"$path"; fi
    printf '%s\n' "$line" >>"$path"
    info "appended to $path: $line"
    added=$((added + 1))
  done
  ((added)) || info "unchanged: $path (all lines already present)"
  return 0
}

# remove_lines FILE <<LINES -> deletes exactly these lines from FILE (other lines kept);
#   deletes FILE if nothing but blank lines/comments is left
remove_lines() {
  local path=$1 tmp
  [[ -f $path ]] || return 0
  tmp=$(mktemp)
  grep -vxF -f /dev/stdin "$path" >"$tmp" || true
  if cmp -s "$tmp" "$path"; then
    info "unchanged: $path"
    rm -f "$tmp"
    return 0
  fi
  cp -a "$path" "$path.bak-$(date +%Y%m%d%H%M%S)"
  if grep -vE '^[[:space:]]*(#|$)' "$tmp" >/dev/null; then
    cat "$tmp" >"$path"
    info "lines removed from $path, other content kept"
  else
    rm -f "$path"
    info "removed: $path (nothing else was left)"
  fi
  rm -f "$tmp"
}

# Lines this project needs in the host config files (used by 03-vfio, 03-vfio-check, rollback)
VFIO_CONF=/etc/modprobe.d/vfio.conf
BL_CONF=/etc/modprobe.d/blacklist-gpu.conf
MOD_CONF=/etc/modules-load.d/vfio.conf
IDS_RE='^[[:space:]]*options[[:space:]]+vfio[-_]pci[[:space:]].*ids='

vfio_conf_lines() {
  printf '%s\n' \
    "options vfio-pci ids=$IDS" \
    "softdep nouveau pre: vfio-pci" \
    "softdep nvidiafb pre: vfio-pci" \
    "softdep snd_hda_intel pre: vfio-pci"
}
bl_conf_lines() {
  printf '%s\n' "blacklist nouveau" "blacklist nvidiafb" "options nouveau modeset=0"
}
# vfio_virqfd is not listed: merged into vfio since kernel 6.2
mod_conf_lines() {
  printf '%s\n' vfio vfio_iommu_type1 vfio_pci
}

# foreign_ids_lines -> prints "file: line" for every vfio-pci ids= setting that differs
#   from ours (two ids= lists conflict - only one is applied)
foreign_ids_lines() {
  local f
  for f in /etc/modprobe.d/*.conf /lib/modprobe.d/*.conf; do
    [[ -f $f ]] || continue
    grep -E "$IDS_RE" "$f" | grep -vxF "options vfio-pci ids=$IDS" | sed "s|^|$f: |" || true
  done
}
