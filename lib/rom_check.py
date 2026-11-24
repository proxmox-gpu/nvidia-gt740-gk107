#!/usr/bin/env python3
"""rom_check.py - inspect a PCI option ROM dump (e.g. an NVIDIA VBIOS).

Finds the start of the PCI expansion ROM (first 0x55AA header with a valid PCIR structure;
nvflash dumps may carry a vendor header in front of it), walks the image chain, checks the
length and the 8-bit checksum of every image, reports UEFI GOP presence, the NVIDIA VBIOS
version/name and the "Engineering Release" marker.
With --extract OUT the option ROM chain alone (start of the first image .. end of the image
flagged "last") is written to OUT - that is the form QEMU expects for hostpci romfile=.
The last lines are machine readable:
  ROM_OFFSET=0x...
  ROM_STATUS=COMPLETE|TRUNCATED|INVALID
  UEFI_GOP=1|0|unknown
Usage: rom_check.py FILE [--extract OUT]   (exit 0 = COMPLETE, 1 = otherwise)
"""
import re
import sys

TYPES = {0: 'x86 legacy BIOS', 1: 'Open Firmware', 2: 'PA-RISC', 3: 'UEFI (GOP)', 0x70: 'NVIDIA'}


def pcir_at(data, off):
    """offset of the PCIR structure of the image at off, or None"""
    if data[off:off + 2] != b'\x55\xaa' or off + 0x1a > len(data):
        return None
    p = off + int.from_bytes(data[off + 0x18:off + 0x1a], 'little')
    return p if data[p:p + 4] == b'PCIR' else None


def find_start(data):
    off = data.find(b'\x55\xaa')
    while off != -1:
        if pcir_at(data, off) is not None:
            return off
        off = data.find(b'\x55\xaa', off + 1)
    return None


def main():
    args = sys.argv[1:]
    extract = None
    if '--extract' in args:
        i = args.index('--extract')
        extract = args[i + 1]
        del args[i:i + 2]
    data = open(args[0], 'rb').read()

    start = find_start(data)
    status, uefi, end = 'COMPLETE', False, None
    if start is None:
        status = 'INVALID'
        print('    no 0x55AA header with a PCIR structure in the file')
    else:
        if start:
            print(f'    option ROM starts at 0x{start:x} (0x{start:x} bytes of vendor header before it)')
        off, n = start, 0
        while True:
            p = pcir_at(data, off)
            if p is None:
                status = 'TRUNCATED'
                print(f'    next image expected @0x{off:x}, dump ends/garbage there')
                break
            vid = int.from_bytes(data[p + 4:p + 6], 'little')
            did = int.from_bytes(data[p + 6:p + 8], 'little')
            length = int.from_bytes(data[p + 0x10:p + 0x12], 'little') * 512
            code, last = data[p + 0x14], data[p + 0x15] & 0x80
            uefi |= code == 3
            if off + length > len(data):
                csum = f'TRUNCATED (dump has {len(data) - off} of {length} bytes)'
                status = 'TRUNCATED'
            else:
                csum = 'ok' if sum(data[off:off + length]) % 256 == 0 else 'BAD'
                # the legacy x86 image must checksum to 0; vendor images may not
                if code == 0 and csum == 'BAD':
                    status = 'INVALID'
            print(f'    image {n} @0x{off:x}: {vid:04x}:{did:04x} type={code} '
                  f'({TYPES.get(code, "?")}) size={length} checksum={csum}{" last" if last else ""}')
            n += 1
            if status != 'COMPLETE' or length == 0:
                break
            off += length
            if last:
                end = off
                break

    head = data[start or 0:(start or 0) + 0x8000]
    m = re.search(rb'Version ([0-9A-F]{2}(?:\.[0-9A-F]{2}){4})', head)
    if m:
        print('    VBIOS version: ' + m.group(1).decode())
    m = re.search(rb'[ -~]{6,}VGA BIOS[ -~]*', head)
    if m:
        print('    VBIOS name   : ' + m.group(0).decode().strip())
    if b'Engineering Release' in bytes((~b) & 0xff for b in head) or b'Engineering Release' in head:
        print('    NOTE: VBIOS is marked "Engineering Release - Not For Production Use"')

    if extract and status == 'COMPLETE' and end:
        with open(extract, 'wb') as f:
            f.write(data[start:end])
        print(f'    extracted option ROM: {extract} ({end - start} bytes)')

    print(f'ROM_OFFSET=0x{(start or 0):x}')
    print('ROM_STATUS=' + status)
    print('UEFI_GOP=' + ('1' if uefi else ('unknown' if status != 'COMPLETE' else '0')))
    return 0 if status == 'COMPLETE' else 1


if __name__ == '__main__':
    sys.exit(main())
