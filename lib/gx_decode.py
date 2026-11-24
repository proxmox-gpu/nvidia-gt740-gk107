#!/usr/bin/env python3
"""Decode the JSON printed by `qm guest exec` into readable UTF-8 text.

The guest agent returns raw bytes of the guest process output; PVE stores them
in JSON as latin-1 code points. A Russian Windows writes native tool output
(cmd, reg, pnputil, certutil) in the OEM code page CP866, while our PowerShell
scripts switch to UTF-8. Both can appear in one stream, so decoding is done
line by line: strict UTF-8 first, CP866 as a fallback (mode "auto").

stdin : JSON from `qm guest exec`
stdout: decoded out-data; stderr: decoded err-data + exit code note
exit  : guest exit code (0..255), 1 for other non-zero codes,
        124 if the process is still running (timeout), 2 on bad input
"""
import json
import os
import sys

MODE = os.environ.get("GUEST_ENCODING", "auto").strip().lower() or "auto"


def raw_bytes(text):
    try:
        return text.encode("latin-1")
    except UnicodeEncodeError:
        # Already proper Unicode (newer PVE versions) - keep as is.
        return None


def decode_line(line):
    if MODE in ("utf-8", "utf8"):
        return line.decode("utf-8", "replace")
    if MODE == "cp866":
        return line.decode("cp866", "replace")
    try:
        return line.decode("utf-8")
    except UnicodeDecodeError:
        return line.decode("cp866", "replace")


def decode(text):
    data = raw_bytes(text)
    if data is None:
        out = text
    else:
        if data.startswith(b"\xef\xbb\xbf"):
            data = data[3:]
        out = "\n".join(decode_line(l) for l in data.split(b"\n"))
    return out.replace("\r", "")


def main():
    try:
        doc = json.load(sys.stdin)
    except ValueError as exc:
        print("gx: cannot parse qm guest exec output: %s" % exc, file=sys.stderr)
        return 2

    if doc.get("out-data"):
        sys.stdout.write(decode(doc["out-data"]))
        if not doc["out-data"].endswith("\n"):
            sys.stdout.write("\n")
    if doc.get("err-data"):
        sys.stderr.write(decode(doc["err-data"]))
        if not doc["err-data"].endswith("\n"):
            sys.stderr.write("\n")
    if doc.get("out-truncated") or doc.get("err-truncated"):
        print("gx: output truncated by the guest agent", file=sys.stderr)

    if "exitcode" not in doc:
        print("gx: guest process still running (pid %s)" % doc.get("pid", "?"), file=sys.stderr)
        return 124
    code = int(doc["exitcode"])
    if code != 0:
        print("[guest exitcode %d]" % code, file=sys.stderr)
    return code if 0 <= code <= 255 else 1


if __name__ == "__main__":
    sys.exit(main())
