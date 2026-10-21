#!/usr/bin/env python3
"""1037 -- read a recovered last_kmsg for the TRAP-FRAME rows and print the PRE-REGISTERED cells.

The rung (docs/1037-design.md; cells in records/1037-read.txt 2) answers ONE question: WHICH REGISTERS
does the trap entry save at the WRONG OFFSET?  1036 read an lr (0x399999af) and an r10 with bit0 set on a
path whose every function is ARM, so some register is stored at the wrong offset.  1037 compares the trap
entry's own `stmea {r0-lr}^` uss copy (read through the TASK MAP) with the C-side `arm_ctx`, and derives
the slide from lr alone.  The kernel publishes RAW values only (xnu_live_fb_* rows,
tools/patch_d13_trap_frame.py); EVERY predicate is computed here, on the host.  The checker never
guesses a row: a row that is absent is absent, never a negative.

CELLS (records/1037-read.txt 2, word-for-word):
  ctrl : fb_dbg_off_ok AND fb_dbg_off < debug_buf_size     (the rows reached the log)
  D1   SAVE-MISPLACED   ctrl AND fb_ctx_diff != 0  -> the trap entry's save and the C view differ; the
        mask names the offsets; 1038 fixes the SAVE.
  D2   SAVE-AGREES      ctrl AND fb_ctx_diff == 0 AND fb_mask_kind == 0  -> arm_ctx IS the saved frame;
        odd lr/r10 are real; 1038 re-derives the fault from the SPSR/CPSR path, not from the save.
        D2-EMPTY (NO CELL)  ctrl AND fb_ctx_diff == 0 AND fb_mask_kind == 1 (or uss_ptr_eq/ctx_diff_self
        == 1, or mask_kind absent): the mask compared arm_ctx with itself, or did not read the uss
        record in full, so ctx_diff == 0 proves nothing.  That is exactly what the 1037 device run was
        (records/1037-read.txt RUNG READING 1).  D2-EMPTY is the reported form of it: exit 2 (no
        reading), not 1, and never D2.  D1 needs no mask_kind: a nonzero mask proves a comparison
        happened.
  D3   NO-BLOCK         ctrl AND the rows are absent -> the block did not run; NOT a cell.
  L1   (reported but never instead of D1/D2)  lr_xor4 == 0 OR lr_xor8 == 0 -> the slide derived from lr
        is measured, and pc IS the walk (file VA 0x37C26474).

ROW NAMES (tools/patch_d13_trap_frame.py, the authority):
  xnu_live_fb_seq / _pc / _lr / _sp_tr / _uss / _ctx_diff / _slide / _lr_xor4 / _lr_xor8 /
  _ldrh / _ok (and _uss_* / _dbg_off / _dbg_off_ok).  EVERY raw fb row is printed first (the tray).

DEBUG_BUF_SIZE: the kernel gates a log flush on `debug_buf_size` (debug.c: `DEBUG_BUF_SIZE = PAGE_SIZE`
under CONFIG_EMBEDDED, else 3*PAGE_SIZE, `debug_buf_size = sizeof(debug_buf)`; debug.h declares ONLY
`extern unsigned int debug_buf_size`).  The ONE-TRUE definition under the D13 pool's config
(CONFIG_EMBEDDED) is 0x1000.  The constants below are taken from that file; the value used is printed on
every run.

STALENESS: the capture must carry the entry mark (else exit 2).  An in-log `[<sec>.<frac>]` stamp, when
present, is the boot the log is OF and must not postdate the file's mtime; the `-YYYYMMDD-HHMMSS-` name
stamp is when the capture was TAKEN and is NEVER read as the boot.

Usage: python3 -I tools/check_1037_capture.py <capture>.
Exit 0 iff a D cell printed; 1 if no fb rows or ctrl absent; 2 if stale.
"""
import os
import re
import sys

ENTRY_MARK = "MI4IOS6_STAGE90 v1 entered"
PREFIX = "xnu_live_fb_"

# the two rows a cell needs, besides seq; a capture without them did not run the block
MARKERS = ("xnu_live_fb_seq=", "xnu_live_fb_ctx_diff=")

PAGE_SIZE = 0x1000
# external/xnu-hd2-darwin13/xnu/osfmk/kern/debug.c:113-120 (see the module docstring)
DEBUG_BUF_SIZE_EMBEDDED = PAGE_SIZE
DEBUG_BUF_SIZE_GENERAL = 3 * PAGE_SIZE
DEBUG_BUF_SIZE = DEBUG_BUF_SIZE_EMBEDDED     # CONFIG_EMBEDDED: the D13 pool's config

# The words compared: uss_r0..r12, uss_sp, uss_lr, uss_pc = 16; a mask of 17 bits leaves bit 16 free.
CTX_DIFF_MASK = 0x1FFFF

# The tray: every raw fb row tools/patch_d13_trap_frame.py prints (its FB_ROWS, verbatim): each
# prefix CONTENT in ITS order; the block prints `uss_<reg>`, `uss_<reg>_ok` pairs for the 16 stmea words.
TRAY_SCALARS = ("seq", "pid", "pc", "lr", "sp_tr", "sp", "uss", "uss_ok", "uss_armctx_diff", "ctx_diff",
                "slide", "lr_xor4", "lr_xor4_ok", "lr_xor8", "lr_xor8_ok", "ldrh", "ldrh_ok",
                "dbg_off", "dbg_off_ok",
                # 1039: the second witness's own discriminator (the mask's kind) and the uss address check
                "uss_ptr_eq", "ctx_diff_self", "mask_kind") + (
    ("uss_r0", "uss_r0_ok", "uss_r1", "uss_r1_ok", "uss_r2", "uss_r2_ok", "uss_r3", "uss_r3_ok",
     "uss_r4", "uss_r4_ok", "uss_r5", "uss_r5_ok", "uss_r6", "uss_r6_ok", "uss_r7", "uss_r7_ok",
     "uss_r8", "uss_r8_ok", "uss_r9", "uss_r9_ok", "uss_r10", "uss_r10_ok", "uss_r11", "uss_r11_ok",
     "uss_r12", "uss_r12_ok", "uss_sp", "uss_sp_ok", "uss_lr", "uss_lr_ok", "uss_pc", "uss_pc_ok"))
assert len(set(TRAY_SCALARS)) == len(TRAY_SCALARS), "TRAY_SCALARS lists a row twice"
# 1037's own rows: a D cell reads ctx_diff + the ctrl pair; the falsifiers read sp_tr / lr_xor4 / lr_xor8 /
# ldrh / uss; D3 needs the block's OTHER rows present while ctx_diff is absent -- so `pc` is required too.
# build_1037.sh step 4/5 and park_1037.sh's row gates read THIS tuple (the names in the source are
# printed as `xnu_live_fb_<name>=`, so the gates hold the two spellings equal in one place).
REQUIRED_ROWS = ("seq", "pc", "ctx_diff", "uss", "sp_tr", "lr_xor4", "lr_xor8", "ldrh", "dbg_off",
                 "dbg_off_ok", "mask_kind")     # 1039: D2 is withdrawn without it
assert set(REQUIRED_ROWS) <= set(TRAY_SCALARS), "a required row is not in the tray"
# 1036's pcc2 sp: the falsifier "if fb_sp_tr == 0x2bd8d088 the trap-frame sp read is the same narrowed row".
PCC2_SP = 0x2BD8D088


def num(s):
    try:
        return int(s.strip(), 0)
    except (ValueError, AttributeError):
        return None


def _rx(name):
    # a row ends at whitespace, an escape, or a `[` (a kernel log prefix), as in 1035/1036's readers
    return re.compile(re.escape(name) + r"=([^\s\x1b\[]+)")


def parse_rows(text):
    """One dict per `seq`: rows are one key=value per line; a dict closes when the next
    xnu_live_fb_seq appears (or at EOF)."""
    rows, cur = [], None
    seq_rx = _rx(PREFIX + "seq")
    rxs = [(k, _rx(PREFIX + k)) for k in TRAY_SCALARS]
    for ln in text.splitlines():
        if PREFIX not in ln:
            continue
        if seq_rx.search(ln) is not None:
            if cur is not None:
                rows.append(cur)
            cur = {}
        if cur is None:
            continue
        for k, r in rxs:
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


def selftest():
    """Synthetic captures in a private temp dir.  Each cell must print; a capture without ctrl must not
    print a D cell; a capture without the entry mark is stale."""
    import tempfile
    import time
    boot = 1792394337
    hdr = "[    %d.000000] MI4IOS6_STAGE90 v1 entered\n" % boot

    def fb(**kw):
        pre = dict(seq=0, pc=0x39999990, lr=0x399999af, sp_tr=0x2bd8d084, uss=0x2bd8d000,
                   ctx_diff=0x22, slide=0x228e0000, lr_xor4=0x1234, lr_xor4_ok=1, lr_xor8=0x5678,
                   lr_xor8_ok=1, ldrh=0x7c09, ldrh_ok=1, dbg_off=0x100, dbg_off_ok=1)
        pre.setdefault("mask_kind", 1 if kw.get("ctx_diff", 0x22) == 0 else 0)
        pre.update(kw)
        return "".join("xnu_live_fb_%s=%s\n" % (k, v if isinstance(v, str) else hex(v))
                       if not isinstance(v, str) or v != "ABSENT" else ""
                       for k, v in pre.items())

    cases = [
        ("D1", hdr + fb(), 0, ("D1 SAVE-MISPLACED",)),
        # D2 requires mask_kind == 0: a content comparison against a distinct uss VA
        ("D2", hdr + fb(ctx_diff=0, mask_kind=0, uss_ptr_eq=0, ctx_diff_self=0), 0, ("D2 SAVE-AGREES",)),
        # 1039: the device run's shape (self-comparison) -- D2 is WITHDRAWN, no cell, exit 2
        ("D2-EMPTY-self", hdr + fb(ctx_diff=0, mask_kind=1, uss_ptr_eq=1, ctx_diff_self=1), 2,
         ("D2-EMPTY",)),
        # 1039: distinct VA but not every uss word read -- the mask is not a content comparison either
        ("D2-EMPTY-partial", hdr + fb(ctx_diff=0, mask_kind=1, uss_ptr_eq=0, ctx_diff_self=1), 2, ("D2-EMPTY",)),
        # 1039: an absent mask_kind is not "0" -- D2 is withdrawn, never printed
        ("D2-EMPTY-absent", hdr + fb(ctx_diff=0, mask_kind="ABSENT", uss_ptr_eq=0, ctx_diff_self=0), 2,
         ("D2-EMPTY", "fb_mask_kind is absent")),
        # the block's OTHER rows are present, so D3 is reached: the context_mask is the one row absent
        ("D3", hdr + "xnu_live_fb_seq=0\nxnu_live_fb_pc=0x39999990\nxnu_live_fb_dbg_off=0x100\n"
                     "xnu_live_fb_dbg_off_ok=1\n", 1, ()),
        ("CTRL-ABSENT", hdr + fb(ctx_diff=0x22, dbg_off_ok=0), 1, ()),
        ("CTRL-OFF-END", hdr + fb(ctx_diff=0x22, dbg_off=0x4000), 1, ()),
        ("L1-ADDITION", hdr + fb(ctx_diff=0x22, lr_xor4=0), 0, ("D1 SAVE-MISPLACED", "L1")),
        ("STALE", fb(lr_xor4=0), 2, ()),
    ]
    fails = 0
    # TRAY-COMPLETE: the parser's key table is the emitter's FB_ROWS (an independent read of the patcher
    # source; a typo in either is a row the tray would print as "(absent)").  A not-a-capture check.
    patcher = os.path.join(os.path.dirname(os.path.abspath(__file__)), "patch_d13_trap_frame.py")
    if os.path.isfile(patcher):
        with open(patcher, "r", errors="replace") as fh:
            ptxt = fh.read()
        # literal format strings (`printf("xnu_live_fb_x=%d\n"`, `_x=0x%08x`), plus the generator that
        # prints `uss_<reg>` / `uss_<reg>_ok` per _USS_ROWS through a `%s` name.
        emitted = set(re.findall(r"xnu_live_fb_([a-z0-9]+)=", ptxt))
        if "_USS_ROWS = " in ptxt:
            emitted |= set("uss_%s%s" % (n, "_ok" if ok else "")
                           for n in "r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc".split()
                           for ok in (False, True))
        cond = emitted <= set(TRAY_SCALARS)
        print("   TRAY-COMPLETE %s -> %d emitted row name(s), %d not in TRAY_SCALARS%s"
              % ("ok" if cond else "FAIL", len(emitted), len(emitted - set(TRAY_SCALARS)),
                 "" if cond else ": " + " ".join(sorted(emitted - set(TRAY_SCALARS)))))
        fails += 0 if cond else 1
    with tempfile.TemporaryDirectory() as d:
        for name, text, want, must in cases:
            p = os.path.join(d, "recovered-20261019-023959-cap-%s-last_kmsg.txt" % name)
            with open(p, "w") as fh:
                fh.write(text)
            if name != "STALE":
                t = time.time() + 10
                os.utime(p, (t, t))
            import io
            import contextlib
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = main(["x", p])
            out = buf.getvalue()
            cond = rc == want and all(s in out for s in must)
            if name == "L1-ADDITION":
                l1 = [ln for ln in out.splitlines() if ln.startswith("L1")]
                cond = cond and len(l1) == 1
            if want == 2:   # a withdrawn mask prints a NO CELL line, never "D2 SAVE-AGREES"
                cond = cond and "D2 SAVE-AGREES" not in out
            print("   %s %s -> exit %d (want %d)%s" % (name, "ok" if cond else "FAIL", rc, want,
                                                      "" if cond else "\n----\n" + out + "----"))
            fails += 0 if cond else 1
    print("DEBUG_BUF_SIZE used = 0x%x (external/xnu-hd2-darwin13/xnu/osfmk/kern/debug.c:113-120)"
          % DEBUG_BUF_SIZE)
    print("SELFTEST %s" % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) == 2 and argv[1] == "--required-rows":
        # the rows the cells and their falsifiers read -- build/park/press gate on THIS list
        print("\n".join(REQUIRED_ROWS))
        return 0
    if len(argv) != 2:
        print("usage: check_1037_capture.py <capture> | --selftest | --required-rows")
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
    print("ctrl: fb_dbg_off < DEBUG_BUF_SIZE (0x%x, external/xnu-hd2-darwin13/xnu/osfmk/kern/debug.c:"
          " DEBUG_BUF_SIZE = PAGE_SIZE under CONFIG_EMBEDDED)" % DEBUG_BUF_SIZE)
    missing = [m for m in MARKERS if m not in text]
    if missing:
        print("NO FB ROWS: the capture lacks %s -- the 1037 block did not run this boot (or was not "
              "compiled in). NOT a reading; withhold." % ", ".join(missing))
        return 1
    rows = parse_rows(text)
    if not rows:
        print("NO FB ROWS: the capture carries the fb markers but no parseable seq row. NOT a reading.")
        return 1
    print("fb rows=%d (every raw row printed; the cell reads the first)" % len(rows))
    for i, r in enumerate(rows):
        print("  [%d] " % i + " ".join("%s=%s" % (k, r.get(k, "(absent)")) for k in TRAY_SCALARS))
    r = rows[0]

    def v(k):
        return num(r.get(k))

    ctrl_ok, dbg_off = v("dbg_off_ok"), v("dbg_off")
    ctx = v("ctx_diff")
    xor4, xor8 = v("lr_xor4"), v("lr_xor8")
    # FALSIFIERS recorded in records/1037-read.txt 2 -- printed, never used to pick a cell.
    if ctx is None:
        print("  WARNING (falsifier): fb_ctx_diff is NOT printed while other fb rows are - the mask "
              "itself is the defective row. Do NOT read it as 0.")
    elif ctx is not None and ctx & ~CTX_DIFF_MASK:
        print("  WARNING (falsifier): fb_ctx_diff=0x%x has bits above 16 set, which no word comparison "
              "can produce - the mask row is defective." % ctx)
    if v("sp_tr") == PCC2_SP:
        print("  WARNING (falsifier): fb_sp_tr == 0x%x (1036's pcc2 sp) - the 'trap frame' read is the "
              "same narrowed row, not a second witness." % PCC2_SP)
    lh = v("ldrh")
    if lh is not None and lh != 0x7C09:
        print("  NOTE (falsifier): fb_ldrh=0x%04x != 0x7C09 - the walk's site is not the file's (or the "
              "slide is not the walk's)." % lh)

    # An lr_xor of 0 is only L1's conjunct when BOTH device words were read: the block prints `_ok=0`
    # (and a 0 xor) when a file read missed -- an unread site is not "the file word equal", never a 0.
    if (xor4 == 0 and v("lr_xor4_ok") != 1) or (xor8 == 0 and v("lr_xor8_ok") != 1):
        print("  NOTE (L1 not taken): lr_xor4_ok=%s lr_xor8_ok=%s -- a 0 xor on a missed read is not a "
              "measured slide." % (r.get("lr_xor4_ok", "(absent)"), r.get("lr_xor8_ok", "(absent)")))
    # L1 is reported ALONGSIDE D1/D2, never instead of them: print it whenever its conjunct holds.
    if xor4 is not None and xor8 is not None and v("lr_xor4_ok") == 1 and v("lr_xor8_ok") == 1 \
            and (xor4 == 0 or xor8 == 0):
        print("L1 SLIDE-FROM-LR: lr_xor4=0x%x lr_xor8=0x%x -> the slide derived from lr is measured and pc "
              "IS the walk (file VA 0x37C26474). Reported alongside D1/D2, never instead of them."
              % (xor4, xor8))

    if ctrl_ok != 1 or dbg_off is None or not (0 <= dbg_off < DEBUG_BUF_SIZE):
        print("NO D CELL - ctrl ABSENT: fb_dbg_off_ok=%s and fb_dbg_off=%s (need _ok=1 and "
              "0 <= dbg_off < 0x%x) -- the rows did not reach the log; presence is a reading and it is "
              "not there." % (r.get("dbg_off_ok", "(absent)"), r.get("dbg_off", "(absent)"), DEBUG_BUF_SIZE))
        return 1
    if ctx is None:
        print("NO D CELL: fb_ctx_diff is absent from the first fb row -- an absent row is never a "
              "negative (records/1037-read.txt 2, falsifier 1).")
        return 1
    if ctx & ~CTX_DIFF_MASK:
        print("NO D CELL: fb_ctx_diff=0x%x is not a mask of the 17 compared words -- the mask row is "
              "defective." % ctx)
        return 1
    if ctx != 0:
        print("D1 SAVE-MISPLACED: ctrl holds and fb_ctx_diff=0x%x != 0 -> the trap entry's uss copy and the "
              "C-side arm_ctx DIFFER. The mask names the offsets (bit i = the i-th compared word); 1038 "
              "fixes the SAVE. H-SHORTNAME is moot (r1 = 0 may itself be a misplacement)." % ctx)
        return 0
    # ctx == 0: D2 is a cell ONLY if the mask compared a DISTINCT uss VA with arm_ctx, every word read.
    kind, peq, self_ = v("mask_kind"), v("uss_ptr_eq"), v("ctx_diff_self")
    if kind is None:
        print("D2-EMPTY (NO CELL): ctrl holds and fb_ctx_diff=0, but fb_mask_kind is absent -- a capture "
              "from a build before 1039. An absent discriminator is not 0: this ctx_diff==0 may be the "
              "self-comparison the 1037 device run made (records/1037-read.txt RUNG READING 1). Withhold.")
        return 2
    if kind != 0 or peq == 1 or self_ == 1:
        why = ("fb_mask_kind=%d (1 = self-comparison)" % kind if kind != 0 else
               "fb_uss_ptr_eq=1: arm_ctx IS thread->machine.uss" if peq == 1 else
               "fb_ctx_diff_self=1: not all 16 uss words were read at a distinct VA")
        print("D2-EMPTY (NO CELL): ctrl holds and fb_ctx_diff=0, but %s -- the mask compared a VA with "
              "itself (or read nothing), so ctx_diff==0 proves nothing. This is the 1037 run's defect "
              "(RUNG READING 1). Withhold; the mask becomes a reading only with mask_kind=0." % why)
        return 2
    print("D2 SAVE-AGREES: ctrl holds and fb_ctx_diff=0 with fb_mask_kind=0 (the uss side was read at a "
          "distinct VA through thread->task's map, all 16 words) -> arm_ctx IS the trap entry's uss copy. "
          "Odd lr/r10 are then real register values; 1038 re-derives the fault from the SPSR/CPSR path, "
          "not from the save.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))