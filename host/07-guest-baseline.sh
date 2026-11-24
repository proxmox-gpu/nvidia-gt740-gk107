#!/usr/bin/env bash
# 07-guest-baseline.sh - after the manual Windows install: check the guest agent,
# enable RDP (language independent), small crash dumps for the debugging period,
# check RDP from the host, snapshot "clean-os".
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID GUEST_DIR

vm_exists || die "VM $VMID does not exist (host/06-create-vm.sh)"
if ! vm_running; then
  step "Starting VM $VMID"
  qm start "$VMID"
fi
wait_agent 600 || die "guest agent does not answer: install virtio-win-guest-tools.exe in the guest (virtio-win CD)"

step "Guest OS (agent)"
qm guest cmd "$VMID" get-osinfo | python3 -c 'import json,sys; d=json.load(sys.stdin); print("    %s | %s | %s" % (d.get("pretty-name"), d.get("version"), d.get("kernel-release")))'

step "Baseline configuration in the guest"
check "RDP enabled and listening on 3389" guest_ps baseline.ps1 -CrashDump 3

step "RDP reachability from the host"
IP=$(guest_ip || true)
if [[ -z $IP ]]; then
  fail "guest has no IPv4 address (DHCP on $BRIDGE? configure the address in the console)"
else
  info "guest IPv4: $IP"
  check "TCP $IP:3389 reachable" timeout 3 bash -c "</dev/tcp/$IP/3389"
fi

step "Cyrillic/OEM output decoding"
gx -- cmd.exe /c ver || true

if ((FAIL_COUNT == 0)); then
  snapshot clean-os "Windows installed, virtio + agent, RDP on (before GPU)"
fi
summary "log in via RDP once to make sure it works, then host/08-attach-gpu.sh"
