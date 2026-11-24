#!/usr/bin/env bash
# gx-test.sh - checks that guest output is readable on the host console, including
# Cyrillic text from a Russian Windows: native tools answer in CP866 (OEM code page),
# PowerShell scripts in UTF-8; gx decodes both line by line (lib/gx_decode.py).
# Override with GUEST_ENCODING=cp866|utf-8 in .env if autodetect guesses wrong.
source "$(dirname "$0")/../lib/common.sh"
init
require_vars VMID

require_agent

step "cmd.exe (OEM code page, CP866 on Russian Windows)"
gx -- cmd.exe /c chcp || true
gx -- cmd.exe /c ver || true
gx -- cmd.exe /c dir /-c C:\\ || true

step "reg.exe"
gx -- reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\Nls\Language' /v InstallLanguage || true

step "PowerShell (UTF-8)"
check "PowerShell script output decoded" guest_ps encoding-test.ps1

info "decoding mode: GUEST_ENCODING=$GUEST_ENCODING"
info "if Cyrillic above is unreadable, set GUEST_ENCODING=cp866 (or utf-8) in .env and rerun"
summary
