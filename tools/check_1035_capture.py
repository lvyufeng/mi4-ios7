#!/usr/bin/env python3
"""1035 -- read a recovered last_kmsg for the PC-CARRIER rows and print one PRE-REGISTERED cell.

The rung (records/1035-carrier-by-pc-read.txt) answers ONE question: which bytes did launchctl[2]
execute at its faulting pc 0x3819d474?  The kernel publishes RAW values only (xnu_live_pcc_* rows,
tools/patch_d13_pc_carrier.py); EVERY predicate is computed here, on the host, against the words the
kernel printed.  The checker never guesses a row: a row that is absent is absent ("no P cell"), never
a negative.

CELLS (records/1035-carrier-by-pc-read.txt 3; all pre-registered before the press):
  P1  first row's xor_walk  == 0  => the device ran the walk (file VA 0x37C26474); fix = count class
  P2  first row's xor_table == 0  => pc is data in the host's image; frontier = why the branch went there
  P3  both nonzero AND near2_ok == 1 => the device's page matches NEITHER host candidate: a different
      cache was served
  P4  near2_ok == 0               => the pc page is not readable in the task map

ROW NAMES (tools/patch_d13_pc_carrier.py, the authority):
  xnu_live_pcc_seq / _pid / _pc / _lr / _r1 / _r2 / _r5 / _r7
  xnu_live_pcc_near{0..5} / _near{0..5}_ok     slots: pc-0x20, pc-0x08, pc, pc+0x08, pc+0x20, lr
  xnu_live_pcc_xor_walk / _xor_table / _xor_m08 / _xor_p08 / _xor_p20 / _xor_lr / _slide

STALENESS (the 1024-1027 hole): the capture must carry the entry mark AND be newer than the boot it
stamps; otherwise "NO READING - STALE SLOT", exit 2.  Usage: python3 -I tools/check_1035_capture.py
<capture>.  Exit 0 iff a P cell printed; 1 if no pcc rows; 2 if stale.
"""
import os
import re
import sys

ENTRY_MARK = "MI4IOS6_STAGE90 v1 entered"

SCALARS = ("xnu_live_pcc_seq", "xnu_live_pcc_pid", "xnu_live_pcc_pc", "xnu_live_pcc_lr",
           "xnu_live_pcc_r1", "xnu_live_pcc_r2", "xnu_live_pcc_r5", "xnu_live_pcc_r7",
           "xnu_live_pcc_xor_walk", "xnu_live_pcc_xor_table", "xnu_live_pcc_xor_m08",
           "xnu_live_pcc_xor_p08", "xnu_live_pcc_xor_p20", "xnu_live_pcc_xor_lr",
           "xnu_live_pcc_slide")
NEAR = tuple("xnu_live_pcc_near%d" % i for i in range(6))
NEAR_OK = tuple("xnu_live_pcc_near%d_ok" % i for i in range(6))


def num(s):
    try:
        return int(s.strip(), 0)
    except (ValueError, AttributeError):
        return None


def parse_rows(text):
    """One dict per `seq`: the file's rows are one key=value per line; a dict closes when the next
    xnu_live_pcc_seq appears (or at EOF)."""
    rows, cur = [], None
    keys = SCALARS + NEAR + NEAR_OK
    rx = {k: re.compile(re.escape(k) + r"=([^\s\x1b\[]+)") for k in keys}
    for ln in text.splitlines():
        if "xnu_live_pcc_" not in ln:
            continue
        m = re.search(r"xnu_live_pcc_seq=(\d+)", ln)
        if m is not None:
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


def boot_epoch(text, path):
    m = re.search(r"\[\s*(\d{9,})\.\d+\]", text)
    if m:
        return int(m.group(1))
    m = re.search(r"-(\d{8})-(\d{6})-", os.path.basename(path))
    if m:
        import calendar
        d = m.group(1) + m.group(2)
        return calendar.timegm((int(d[0:4]), int(d[4:6]), int(d[6:8]), int(d[8:10]),
                                int(d[10:12]), int(d[12:14]), 0, 0, 0))
    return None


def selftest():
    """Synthetic captures, written to a private temp dir. Each cell must print; a missing row must NOT
    be read as a cell (an absent row is never a negative); a stale capture must be refused."""
    import tempfile
    import time
    boot = 1792217325
    hdr = "[    %d.000000] MI4IOS6_STAGE90 v1 entered\n" % boot

    def capture(walk, table, ok2):
        rows = ["xnu_live_pcc_seq=0", "xnu_live_pcc_pid=2", "xnu_live_pcc_pc=0x3819d474",
                "xnu_live_pcc_xor_walk=0x%08x" % walk, "xnu_live_pcc_xor_table=0x%08x" % table,
                "xnu_live_pcc_near2_ok=%d" % ok2]
        return hdr + "\n".join(rows) + "\n"

    cases = [("P1", capture(0, 0x030b131b, 1), 0),
             ("P2", capture(0x29007c09, 0, 1), 0),
             ("P3", capture(0x11111111, 0x22222222, 1), 0),
             ("P4", capture(0x11111111, 0x22222222, 0), 0),
             ("NOROW", hdr + "nothing\n", 1),
             ("STALE", "xnu_live_pcc_seq=0\nxnu_live_pcc_xor_walk=0\nxnu_live_pcc_xor_table=1\n"
                       "xnu_live_pcc_near2_ok=1\n", 2)]
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        for name, text, want in cases:
            p = os.path.join(d, "cap-%s.log" % name)
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
        print("usage: check_1035_capture.py <capture>")
        return 2
    path = argv[1]
    with open(path, "r", errors="replace") as fh:
        text = fh.read()
    if ENTRY_MARK not in text:
        print("NO READING - STALE SLOT: no `%s` in the capture" % ENTRY_MARK)
        return 2
    boot = boot_epoch(text, path)
    mtime = os.stat(path).st_mtime_ns // 1000000000
    if boot is not None and mtime < boot:
        print("NO READING - STALE SLOT: mtime %d older than the boot it stamps %d" % (mtime, boot))
        return 2
    rows = parse_rows(text)
    if not rows:
        print("NO PCC ROWS: the capture carries no xnu_live_pcc_seq row -- the fault path did not run "
              "this boot or the probe was not compiled in. NOT a reading; withhold.")
        return 1
    r = rows[0]
    print("rows=%d (first of %d)" % (len(rows), len(rows)))
    for k in ("xnu_live_pcc_pid", "xnu_live_pcc_pc", "xnu_live_pcc_lr", "xnu_live_pcc_r1",
              "xnu_live_pcc_r2", "xnu_live_pcc_r5", "xnu_live_pcc_r7"):
        print("  %s=%s" % (k.split("_")[-1], r.get(k, "(absent)")))
    for i in range(6):
        print("  near[%d]=%s ok[%d]=%s" % (i, r.get(NEAR[i], "(absent)"),
                                           i, r.get(NEAR_OK[i], "(absent)")))
    for k in ("xnu_live_pcc_xor_walk", "xnu_live_pcc_xor_table", "xnu_live_pcc_xor_m08",
              "xnu_live_pcc_xor_p08", "xnu_live_pcc_xor_p20", "xnu_live_pcc_xor_lr"):
        print("  %s=%s" % (k, r.get(k, "(absent)")))
    walk = num(r.get("xnu_live_pcc_xor_walk"))
    table = num(r.get("xnu_live_pcc_xor_table"))
    ok2 = num(r.get(NEAR_OK[2]))
    if walk is None or table is None:
        print("NO XOR ROW: the first pcc row lacks xor_walk or xor_table -- its confirming conjuncts "
              "are absent; no P cell (an absent row is never a negative).")
        return 1
    if walk == 0:
        print("P1: the device ran the walk (file VA 0x37C26474); fix = count class")
    elif table == 0:
        print("P2: pc is data in the host's image; frontier = why the branch went there")
    elif ok2 == 1:
        print("P3: the device's page matches NEITHER host candidate: a different cache was served")
    elif ok2 == 0:
        print("P4: the pc page is not readable in the task map")
    else:
        print("NO OK ROW: near2_ok absent; the page-read conjunct cannot be stated -- no P cell.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))