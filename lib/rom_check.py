#!/usr/bin/env python3
"""rom_check.py - inspect a PCI option ROM dump (e.g. an NVIDIA VBIOS).

Walks the image chain (0x55AA header -> PCIR structure), checks the length and the
8-bit checksum of every image, reports UEFI GOP presence, the NVIDIA VBIOS version/name
and the "Engineering Release" marker. The last two lines are machine readable:
  ROM_STATUS=COMPLETE|TRUNCATED|INVALID
  UEFI_GOP=1|0|unknown
Usage: rom_check.py FILE   (exit 0 = COMPLETE, 1 = otherwise)
"""
import re, sys
data = open(sys.argv[1], 'rb').read()
types = {0: 'x86 legacy BIOS', 1: 'Open Firmware', 2: 'PA-RISC', 3: 'UEFI (GOP)', 0x70: 'NVIDIA'}
off, n, uefi, status = 0, 0, False, 'COMPLETE'
while True:
    if off + 0x1a > len(data) or data[off:off + 2] != b'\x55\xaa':
        if n == 0:
            status = 'INVALID'; print('    no 0x55AA ROM signature at offset 0')
        else:
            status = 'TRUNCATED'; print(f'    next image expected @0x{off:x}, dump ends/garbage there')
        break
    p = off + int.from_bytes(data[off + 0x18:off + 0x1a], 'little')
    if data[p:p + 4] != b'PCIR':
        status = 'INVALID'; print(f'    image {n} @0x{off:x}: no PCIR structure'); break
    vid = int.from_bytes(data[p + 4:p + 6], 'little'); did = int.from_bytes(data[p + 6:p + 8], 'little')
    length = int.from_bytes(data[p + 0x10:p + 0x12], 'little') * 512
    code = data[p + 0x14]; last = data[p + 0x15] & 0x80
    uefi |= code == 3
    if off + length > len(data):
        csum = f'TRUNCATED (dump has {len(data) - off} of {length} bytes)'; status = 'TRUNCATED'
    else:
        csum = 'ok' if sum(data[off:off + length]) % 256 == 0 else 'BAD'
        if code == 0 and csum == 'BAD': status = 'INVALID'
    print(f'    image {n} @0x{off:x}: {vid:04x}:{did:04x} type={code} ({types.get(code, "?")}) size={length} checksum={csum}')
    n += 1
    if last or length == 0 or status != 'COMPLETE': break
    off += length
head = data[:0x8000]
m = re.search(rb'Version ([0-9A-F]{2}(?:\.[0-9A-F]{2}){4})', head)
if m: print('    VBIOS version: ' + m.group(1).decode())
m = re.search(rb'[ -~]{6,}VGA BIOS[ -~]*', head)
if m: print('    VBIOS name   : ' + m.group(0).decode().strip())
if b'Engineering Release' in bytes((~b) & 0xff for b in head) or b'Engineering Release' in head:
    print('    NOTE: VBIOS is marked "Engineering Release - Not For Production Use"')
print('ROM_STATUS=' + status)
print('UEFI_GOP=' + ('1' if uefi else ('unknown' if status != 'COMPLETE' else '0')))
sys.exit(0 if status == 'COMPLETE' else 1)
