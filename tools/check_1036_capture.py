#!/usr/bin/env python3
"""1036 -- read a recovered last_kmsg for the PC-CARRIER'S CALLER rows and print one PRE-REGISTERED cell.

The rung (records/1036-pc-carrier-caller.txt) answers ONE question: WHO entered the walk that 1035 put the
carrier on (xnu_live_pcc_xor_walk=0)?  The kernel publishes RAW values only (xnu_live_pcc2_* rows,
tools/patch_d13_pc_carrier_caller.py); EVERY predicate is computed here, on the host, against the words
the kernel printed.  The checker never guesses a row: a row that is absent is absent ("no C cell"), never
a negative.

CELLS (records/1036-pc-carrier-caller.txt 3; pre-registered before the press):
  C1  first row's lr_m4_ok == 1 AND lr_m8_ok == 1 AND lr_m4 != 0
      -> CALLER-BL-TO-WALK: the walk was entered by a Thumb `bl` whose pc is lr-4 (decoding the
         instruction's imm host-side is NOT done here; lr_m4/lr_m8 are printed raw for the lead).
  C2  tbl_used_ok == 1 AND tbl_used == 0xffffffff
      -> TABLE-MINUS1: the count came from the optimised-class table's -1 field; fix = the table reader.
  C3  NEITHER: tray printed for the lead; no fix is licensed by this rung.

ROW NAMES (tools/patch_d13_pc_carrier_caller.py, the authority):
  xnu_live_pcc2_seq / _lr_m4 / _lr_m4_ok / _lr_m8 / _lr_m8_ok / _tbl_used / _tbl_used_ok

STALENESS (the 1024-1027 hole): the capture must carry the entry mark (else exit 2).  An in-log
`[<sec>.<frac>]` stamp, when present, is the boot the log is OF and must not postdate the file's mtime;
the `-YYYYMMDD-HHMMSS-` name stamp is when the capture was TAKEN and is NEVER read as the boot (1035's
defect: a capture taken hours after the boot was misjudged stale by it).  Without an in-log stamp,
the entry mark AND the rung's own content markers are the evidence it is this rung's boot.

Also prints the 1035 pcc rows (read-only context: pcc is the parent the pcc2 rows are read BESIDE).

Usage: python3 -I tools/check_1036_capture.py <capture>.
Exit 0 iff a C cell printed; 1 if no pcc2 rows; 2 if stale.
"""
import os
import re
import sys

ENTRY_MARK = "MI4IOS6_STAGE90 v1 entered"
PREFIX = "xnu_live_pcc2_"

MARKERS = ("xnu_live_pcc2_seq=", "xnu_live_pcc2_lr_m4=")   # required before any C cell

SCALARS = ("lr_m4", "lr_m4_ok", "lr_m8", "lr_m8_ok", "tbl_used", "tbl_used_ok")
# 1035's rows printed as context only; none of them decides a cell here.
CONTEXT = ("xnu_live_pcc_pc", "xnu_live_pcc_lr", "xnu_live_pcc_xor_walk", "xnu_live_pcc_xor_table")

U32 = 0xFFFFFFFF


def num(s):
    try:
        return int(s.strip(), 0)
    except (ValueError, AttributeError):
        return None


def _rx(name):
    # a row ends at whitespace, an escape, or a `[` (a kernel log prefix), as in 1035's reader
    return re.compile(re.escape(name) + r"=([^\s\x1b\[]+)")


def parse_rows(text):
    """One dict per `seq`: rows are one key=value per line; a dict closes when the next
    xnu_live_pcc2_seq appears (or at EOF)."""
    rows, cur = [], None
    rx = {k: _rx(PREFIX + k) for k in SCALARS}
    for ln in text.splitlines():
        if PREFIX not in ln:
            continue
        if _rx(PREFIX + "seq").search(ln) is not None:
            if cur is not None:
                rows.append(cur)
            cur = {}
        if cur is None:
            continue
        for k, r in rx.items():
            mm = r.search(ln)
            if mm is not None:
                cur[k] = mm.group(1)
    if cur is not None:
        rows.append(cur)
    return rows


def boot_epoch(text):
    """The boot the capture is OF: the first in-log `[<sec>.<frac>]` stamp, or None.  The name stamp is
    deliberately NOT a fallback (it is when the capture was TAKEN)."""
    m = re.search(r"\[\s*(\d{9,})\.\d+\]", text)
    if m:
        return int(m.group(1))
    return None


def named_epoch(path):
    """The `-YYYYMMDD-HHMMSS-` stamp in the name: when the capture was TAKEN (diagnostic print only)."""
    m = re.search(r"-(\d{8})-(\d{6})-", os.path.basename(path))
    if not m:
        return None
    d = m.group(1) + m.group(2)
    return "%s-%s-%s %s:%s:%sZ" % (d[0:4], d[4:6], d[6:8], d[8:10], d[10:12], d[12:14])


def first(text, name):
    m = _rx(name).search(text)
    return m.group(1) if m is not None else None


def selftest():
    """Synthetic captures in a private temp dir.  Each cell must print; a capture without the markers
    must NOT be read as a cell; a capture without the entry mark is stale."""
    import tempfile
    import time
    boot = 1792378199
    hdr = "[    %d.000000] MI4IOS6_STAGE90 v1 entered\n" % boot
    pcc = ("xnu_live_pcc_seq=0\nxnu_live_pcc_pc=0x3819d474\nxnu_live_pcc_lr=0x381959af\n"
           "xnu_live_pcc_xor_walk=0x00000000\nxnu_live_pcc_xor_table=0x030b131b\n")

    def capture(m4, ok4, m8, ok8, tbl, okt):
        return hdr + pcc + "".join("xnu_live_pcc2_%s\n" % r for r in (
            "seq=0", "lr_m4=0x%08x" % m4, "lr_m4_ok=%d" % ok4, "lr_m8=0x%08x" % m8,
            "lr_m8_ok=%d" % ok8, "tbl_used=0x%08x" % tbl, "tbl_used_ok=%d" % okt))

    cases = [("C1", capture(0xf856d20b, 1, 0xf856d20b, 1, 0x00000007, 1), 0),
             ("C2", capture(0, 0, 0, 0, U32, 1), 0),
             ("C3", capture(0xf856d20b, 1, 0x00000000, 0, 0x00000007, 1), 0),
             ("NOROW", hdr + pcc + "nothing\n", 1),
             ("STALE", "xnu_live_pcc2_seq=0\nxnu_live_pcc2_lr_m4=0xf856d20b\n"
                       "xnu_live_pcc2_lr_m4_ok=1\nxnu_live_pcc2_tbl_used=0xffffffff\n"
                       "xnu_live_pcc2_tbl_used_ok=1\n", 2)]
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        for name, text, want in cases:
            p = os.path.join(d, "recovered-20261019-024959-cap-%s-last_kmsg.txt" % name)
            with open(p, "w") as fh:
                fh.write(text)
            if name != "STALE":
                t = time.time() + 10
                os.utime(p, (t, t))
            rc = main(["x", p])
            cond = rc == want
            print("   %s %s -> exit %d (want %d)" % (name, "ok" if cond else "FAIL", rc, want))
            fails += 0 if cond else 1
    print("SELFTEST %s" % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) != 2:
        print("usage: check_1036_capture.py <capture>")
        return 2
    path = argv[1]
    with open(path, "r", errors="replace") as fh:
        text = fh.read()
    if ENTRY_MARK not in text:
        print("NO READING - STALE SLOT: no `%s` in the capture" % ENTRY_MARK)
        return 2
    boot = boot_epoch(text)
    mtime = os.stat(path).st_mtime_ns // 1000000000
    if boot is not None and mtime < boot:
        print("NO READING - STALE SLOT: mtime %d older than the in-log boot stamp %d" % (mtime, boot))
        return 2
    print("capture: %s (name stamp %s -- when it was TAKEN, not the boot)"
          % (os.path.basename(path), named_epoch(path) or "(none)"))
    missing = [m for m in MARKERS if m not in text]
    if missing:
        print("NO PCC2 ROWS: the capture lacks %s -- the 1036 probe did not run this boot (or was not "
              "compiled in). NOT a reading; withhold." % ", ".join(missing))
        return 1
    rows = parse_rows(text)
    if not rows:
        print("NO PCC2 ROWS: the capture carries the pcc2 markers but no parseable seq row. NOT a reading.")
        return 1
    r = rows[0]
    print("pcc2 rows=%d (reading the first)" % len(rows))
    for k in SCALARS:
        print("  %s=%s" % (k, r.get(k, "(absent)")))
    print("  1035 context (read-only): " + " ".join(
        "%s=%s" % (k.replace("xnu_live_pcc_", ""), first(text, k) or "(absent)") for k in CONTEXT))
    m4, ok4 = num(r.get("lr_m4")), num(r.get("lr_m4_ok"))
    m8, ok8 = num(r.get("lr_m8")), num(r.get("lr_m8_ok"))
    tbl, okt = num(r.get("tbl_used")), num(r.get("tbl_used_ok"))
    if None in (m4, ok4, m8, ok8) or None in (tbl, okt):
        print("NO C CELL: the first pcc2 row lacks one of lr_m4/lr_m4_ok/lr_m8/lr_m8_ok/tbl_used/tbl_used_ok "
              "-- its confirming conjuncts are absent (an absent row is never a negative).")
        return 1
    if ok4 == 1 and ok8 == 1 and m4 != 0:
        print("C1 CALLER-BL-TO-WALK: lr_m4_ok=1, lr_m8_ok=1, lr_m4=0x%08x != 0 -> the walk was entered by a "
              "Thumb `bl` (pc=lr-4).  lr_m4/lr_m8 are printed raw; this reader does not decode "
              "the instruction -- the lead adjudicates." % m4)
    elif okt == 1 and tbl == U32:
        print("C2 TABLE-MINUS1: tbl_used_ok=1 and tbl_used=0xffffffff -> the count came from the "
              "optimised-class table's -1 field; FIX = the table reader.")
    else:
        print("C3 NEITHER: the tray above is for the lead; this rung licenses no fix.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))