#!/usr/bin/env python3
"""t2-tbt-acpi-patch.py — cut the dead waits out of Apple's Thunderbolt resume.

Usage: t2-tbt-acpi-patch.py IN OUT

IN is Apple's "TbtOnPCH" SSDT as the kernel exposes it under
/sys/firmware/acpi/tables/.  OUT is a copy for the early-initrd table upgrade
(kernel/firmware/acpi/ in /boot/acpi_override.img) with two methods changed.

Linux answers _OSI("Darwin") on Apple hardware, so the firmware's OSDW() is
true and the Thunderbolt _PS0 methods run the macOS power-up sequence on every
S3 resume.  Measured on iMac20,2 with an AML method trace (2026-10-12), this
was 9.0 s of the 10.05 s noirq resume phase:

  \\_SB.PCI0.RP05.UPSB.CRMW   read-modify-write of a Thunderbolt router
      register through the upstream port's PCIe2CIO mailbox (config 0x530).
      The mailbox never completes under Linux: every CIOR polled its full
      10000 x Stall(25) (394 ms) and CRMW gave up after 5 tries and 5 x
      Sleep(100).  2.47 s per call, called 3 times per resume (UPSB._PS0 twice,
      NHI0._PS0 via CTBT once), 15 of 15 reads failed, no write was ever issued.
      Patched to return 1 (failure) at once — the value it returned anyway.

  \\_SB.PCI0.RP05.UPSB.DSB2.XHC2.PCED   waits up to 1 s for DSB2's link to
      report trained, then sleeps 150 ms.  Its reads of DSB2 never see the
      link-training bit clear, although lspci shows the link up at 2.5GT/s x4,
      so the wait always runs out (1.16 s per resume).  The deadline is set to
      zero: the method skips that wait and keeps its 150 ms settle.  Its later
      config-space check already found the deadline gone, so the end state is
      the same as before.

UPSB's own PCED (a 0.44 s link retrain that succeeds) is left alone.  None of
these devices runtime-suspend, so the methods run only on system resume.

The OEM revision is raised by one, which acpi_table_upgrade() requires to take
a table over the firmware's, and the checksum is recomputed.  A table this
script already patched is accepted as input and written back unchanged, so the
live table is valid input whether or not the override is active.

Exit status: 0 written, 1 usage or I/O error, 2 table not recognised (nothing
written — a firmware update may have changed it).
"""
import sys

OEM_ID = b"APPLE "
TABLE_ID = b"TbtOnPCH"
FIRMWARE_REV = 0x00001000
PATCHED_REV = FIRMWARE_REV + 1

# CRMW's first statement, Store (One, Local1) ...
CRMW_BODY = bytes.fromhex("70 01 61")
# ... becomes Return (One), padded to the same length with Noop.
CRMW_STUB = bytes.fromhex("a4 01 a3")
# First statement of XHC2's PCED, Store (One, \_SB.PCI0.RP05.GXCI); the other
# two PCED methods (UPSB, NHI0) start with GPCI and GNHI instead.
XHC2_PCED_BODY = bytes.fromhex("70 01 5c 2f 04") + b"_SB_PCI0RP05GXCI"
# Add (Timer, 0x00989680, Local5): Local5 = Timer + 1 s (Timer ticks are 100 ns)
DEADLINE_1S = bytes.fromhex("72 5b 33 0c 80 96 98 00 65")
DEADLINE_0 = bytes.fromhex("72 5b 33 0c 00 00 00 00 65")


class Unrecognised(Exception):
    pass


def pkg_length(buf, i):
    """Decode the AML PkgLength at buf[i]; return (value, encoded size)."""
    lead = buf[i]
    extra = lead >> 6
    if extra == 0:
        return lead & 0x3F, 1
    value = lead & 0x0F
    for k in range(extra):
        value |= buf[i + 1 + k] << (4 + 8 * k)
    return value, extra + 1


def methods(buf, name, flags):
    """(body start, end) of each Method definition with this NameSeg and flags.

    A call site has the same NameSeg but is not preceded by MethodOp (0x14)
    and a PkgLength that encodes in exactly the bytes between them.
    """
    found = []
    key = name + bytes([flags])
    i = buf.find(key)
    while i >= 0:
        for size in range(1, 5):
            op = i - size - 1
            if op < 36 or buf[op] != 0x14:
                continue
            value, n = pkg_length(buf, op + 1)
            if n == size and op + 1 + value <= len(buf):
                found.append((i + len(key), op + 1 + value))
                break
        i = buf.find(key, i + 1)
    return found


def find_all(buf, needle, start, end):
    hits = []
    i = buf.find(needle, start, end)
    while i >= 0:
        hits.append(i)
        i = buf.find(needle, i + 1, end)
    return hits


def patch(buf):
    """Patch buf in place.  Return True if it changed, False if already patched."""
    if len(buf) < 36 or buf[0:4] != b"SSDT":
        raise Unrecognised("not an SSDT")
    if buf[10:16] != OEM_ID or buf[16:24] != TABLE_ID:
        raise Unrecognised(f"OEM {bytes(buf[10:16])!r} table {bytes(buf[16:24])!r}, "
                           f"want {OEM_ID!r} {TABLE_ID!r}")
    if int.from_bytes(buf[4:8], "little") != len(buf):
        raise Unrecognised("header length does not match the file")
    if sum(buf) & 0xFF:
        raise Unrecognised("bad checksum")
    rev = int.from_bytes(buf[24:28], "little")

    crmw = methods(buf, b"CRMW", 0x0D)          # 5 args, Serialized
    if len(crmw) != 1:
        raise Unrecognised(f"expected one CRMW method, found {len(crmw)}")
    crmw_at = crmw[0][0]
    crmw_cur = bytes(buf[crmw_at:crmw_at + len(CRMW_BODY)])

    pced = [m for m in methods(buf, b"PCED", 0x08)  # 0 args, Serialized
            if buf[m[0]:m[0] + len(XHC2_PCED_BODY)] == XHC2_PCED_BODY]
    if len(pced) != 1:
        raise Unrecognised(f"expected one XHC2 PCED method, found {len(pced)}")
    body, end = pced[0]
    long_waits = find_all(buf, DEADLINE_1S, body, end)
    zero_waits = find_all(buf, DEADLINE_0, body, end)

    # The first 1 s deadline bounds the config-space check; the second one,
    # inside If (DSB2.PRSR), is the link wait.
    if (rev == FIRMWARE_REV and crmw_cur == CRMW_BODY
            and len(long_waits) == 2 and not zero_waits):
        buf[crmw_at:crmw_at + len(CRMW_STUB)] = CRMW_STUB
        link_wait = long_waits[1]
        buf[link_wait:link_wait + len(DEADLINE_0)] = DEADLINE_0
        buf[24:28] = PATCHED_REV.to_bytes(4, "little")
        buf[9] = 0
        buf[9] = -sum(buf) & 0xFF
        return True
    if (rev == PATCHED_REV and crmw_cur == CRMW_STUB
            and len(long_waits) == 1 and len(zero_waits) == 1
            and zero_waits[0] > long_waits[0]):
        return False
    raise Unrecognised(f"OEM revision {rev:#x} with method bodies that match "
                       f"neither Apple's table nor this script's output")


def main(argv):
    if len(argv) != 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 1
    try:
        with open(argv[1], "rb") as f:
            buf = bytearray(f.read())
    except OSError as e:
        print(f"t2-tbt-acpi-patch: {e}", file=sys.stderr)
        return 1
    try:
        changed = patch(buf)
    except Unrecognised as e:
        print(f"t2-tbt-acpi-patch: {argv[1]}: {e}", file=sys.stderr)
        return 2
    try:
        with open(argv[2], "wb") as f:
            f.write(buf)
    except OSError as e:
        print(f"t2-tbt-acpi-patch: {e}", file=sys.stderr)
        return 1
    if changed:
        print("patched: CRMW returns at once, XHC2.PCED link wait cut, "
              f"OEM revision {FIRMWARE_REV:#x} -> {PATCHED_REV:#x}")
    else:
        print("already patched: written unchanged")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
