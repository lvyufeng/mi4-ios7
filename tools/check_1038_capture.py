#!/usr/bin/env python3
"""1038 -- read a recovered last_kmsg for the 1038 rows (arm A = the stack watch, arm B = little endian at
the table, the gate rows) and print the PRE-REGISTERED cells of docs/1038-design.md 1-2.

The rung is INSTRUMENT ONLY.  The kernel publishes RAW rows; EVERY predicate is computed here, on the host.
A row that is absent is absent, never a negative.

THE PATCHER IS THE AUTHORITY FOR THE NAMES: tools/patch_d13_watch_le.py, ONE switch STAGE90_XNU_WATCH_LE,
two trap.c edits (arm A + arm B in 1025's failure arm; a one-shot hook in sleh_abort).  Arm B lives in the
KERNEL's failure arm (reason 4), so its rows describe the KERNEL's r3 and kernel sp -- not the user table.
  A  xnu_live_sweq_seq / _pid / _ssid / _sp / _usp / _k / _tdfar / _tdpc / _td_ok / _wpc / _wfp / _w_ok /
     _s0.._s15 (+ _s0_ok.. _s15_ok) / _bp0.._bp3 (+ _bp0_ok.._bp3_ok)
  B  xnu_live_ler_seq / _pid / _r3 / _cnt_w / _cnt_w_ok / _cnt_b / _cnt_b_ok / _al0 / _al0_ok /
     _mfp1 / _mfp1_ok / _mfp2 / _mfp2_ok / _ppc / _ppc_ok / _le / _le_ok
  gates  xnu_live_wlg_byte (1/0/2), xnu_live_wlg_lev (0/1/2), xnu_live_wlg_need_<row> (a bit mask)
  raw addresses  xnu_live_wlr_cnt / _mfp1 / _mfp2 / _ppc  (printed beside the ler word rows)
Block C (docs/1038-design.md 3, the first 64 KiB) is NOT in the patcher: the design's C1-C3 cannot fire on
this run.  The reader says so instead of inventing rows.

WHAT THE GATES MEAN (the patcher's GATES table; the reader uses them as CONFIRMING rows):
  wlg_byte=0  the task-map byte read at the walk's page returned EFAULT -> the walked page is NOT in the
              task map, so a task-map word read at pc-0x40 is not a reading: A1's far==*(pc-0x40) conjunct
              is WITHDRAWN (neither held nor refuted).  wlg_byte=2: not attempted (no map entry).
  wlg_byte=1  the read succeeded: al0 / cnt_b / le rows (gate 7=le, 2=al0) are readings.
  wlg_lev     found a `pop {pc}` boundary: >0 wpc is a reading (gate 5), 2 stronger (gate 9).
  xnu_live_wlg_need_<row> says which gate the kernel applied to that row (printed in the tray).

CELLS (docs/1038-design.md 1-2, conjuncts verbatim; the cells that cannot be decided here are SAID so):
  A1 WATCH-FATAL       bp rows fault AND far == *(pc-0x40) AND s3 == 0xffffffff
  A2 WATCH-ALIVE       bp readable AND the 32 bytes equal capture B2's 0x5d3bd7.. (given)
  A3 WATCH-READS-ZERO  bp readable and zero
  A4 WATCH-NO-STORE    bp readable with s3's source absent -> the copy hypothesis is DEAD
  B1 LE-CONFIRMED      _cnt_w == 0 AND _cnt_b != 0 AND _le_ok AND _le != _ppc
  B2 NOT-BE            either conjunct false -> the byte-swap model is DEAD
What the host does NOT pretend to do (each printed beside the cell, never used to pick one):
  * `far == *(pc-0x40)` needs the DEVICE's word at the walk's pc-0x40.  The host has no such row from the
    patcher unless it prints xnu_live_sweq_swb_far/_swb_pc (+_swb_ok).  When those rows are present AND
    swb_ok == 1 the device's own test held and A1 is adjudicated on it; absent, A1 cannot be adjudicated
    from far alone (far = 0x10 says only which address was read).
  * A2's "32 bytes" are not derivable from the 18 bytes records/1037-read.txt B2 gives for file 0x5d3bd7
    (B2 itself: "STRONG, NOT PROVEN ... check with a byte-exact dump").  The reader compares the 18 given
    bytes and treats the remaining bp bytes as zero PAD, and says so on every A2.
  * The A2 anchor is B2's pc.  H-SHORTNAME makes the source offset a function of the -1 immediate, so at a
    different swb_pc the reader does not match bp against the file at all.
  * A4's premise (`s3's source absent`) has no host-decidable row: with bp readable, "the copy is not there"
    and "the copy was not read" look the same.  A4 stays pre-registered and unread.

THE OTHER LANE'S ROWS: switch STAGE90_XNU_USTACK_VALIDATE prints `xnu_live_uvc_num=` / `xnu_live_uvc_pc=`.
This reader CHECKS they exist and prints them beside the cells.  They are NOT a conjunct of any cell.

STALENESS (identical to 1036/1037): the capture must carry the entry mark (else exit 2); an in-log
`[<sec>.<frac>]` stamp is the boot the log is OF and must not postdate the file's mtime; the
`-YYYYMMDD-HHMMSS-` name stamp is when the capture was TAKEN and is NEVER read as the boot.  --pre <copy>:
the capture must DIFFER from the pre-press copy (same bytes = the slot was never rewritten).  --after N:
the capture's boot epoch must be >= N (the press's own boot).

Usage: python3 -I tools/check_1038_capture.py <capture> [--pre <pre-press copy>] [--after <boot_epoch>]
       python3 -I tools/check_1038_capture.py --selftest | --required-rows
Exit 0 iff a cell printed; 1 if nothing fired (every block's rows or confirming conjuncts absent); 2 stale.
"""
import os
import re
import sys

ENTRY_MARK = "MI4IOS6_STAGE90 v1 entered"
U32 = 0xFFFFFFFF
# capture B2 of the 1036 run: the far the walk faulted on, and pc.
B2_FAR, B2_PC = 0x10, 0x399A1474

# records/1037-read.txt B2: file bytes at 0x5d3bd7 (18 bytes -- the copy that lands at sp-4..sp+0xd).
B2_SOURCE = bytes.fromhex("4507009b5e04300f0f330414505d27c00818")
B2_SOURCE_FILE_OFF = 0x5D3BD7
# A1's falsifier: `pc - 0x5d3bd7 + 0x38268000 - 8` under the review that named it (records/1037-read.txt B2).
PC_FILE_BASE = 0x37C26474

# The WATCH_LE patcher's two arms (tools/patch_d13_watch_le.py; SOLO_BASE is read from `xnu_live_<b>_seq`).
WATCH_LE_SWITCH = "STAGE90_XNU_WATCH_LE"
A_BASE, B_BASE = "xnu_live_sweq", "xnu_live_ler"
SOLO_BASE, SOLO_SWITCH, SOLO_PATCHER = "xnu_live_solo", "STAGE90_XNU_WATCH_LE_SOLO", "patch_d13_watch_le_solo.py"
SOLO_ROWS = ("seq", "pid", "swb_far", "swb_pc", "swb_ok", "pcx", "pcx_ok")

A_ROWS = ("seq", "pid", "ssid", "sp", "usp", "k", "tdfar", "tdpc", "td_ok", "wpc", "wfp", "w_ok",
          "swb_far", "swb_pc", "swb_ok") \
    + tuple("s%d" % i for i in range(16)) + tuple("s%d_ok" % i for i in range(16)) \
    + tuple("bp%d" % i for i in range(4)) + tuple("bp%d_ok" % i for i in range(4))
B_ROWS = ("seq", "pid", "r3", "cnt_w", "cnt_w_ok", "cnt_b", "cnt_b_ok", "al0", "al0_ok",
          "mfp1", "mfp1_ok", "mfp2", "mfp2_ok", "ppc", "ppc_ok", "le", "le_ok")
# the gate rows the kernel prints: pair rows with their gate where the patcher prints one (cnt_w is
# unguarded, and the s/bp rows are on gate 1/4 via their _ok)
GATES_PRINTED = ("byte", "lev") + tuple("need_" + r for r in A_ROWS + B_ROWS if r in (
    "usp", "k", "wpc", "wfp", "w_ok", "bp0", "bp0_ok", "bp1", "bp1_ok", "bp2", "bp2_ok", "bp3", "bp3_ok", "s0", "s1", "s2", "s3",
    "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13", "s14", "s15", "al0", "al0_ok", "mfp1", "mfp1_ok", "mfp2", "mfp2_ok", "ppc", "ppc_ok", "le", "le_ok"))
GATE_ROWS = GATES_PRINTED

# The rows a cell or its falsifier reads (--required-rows; build/park/press gate on these).
# A1's own conjunct (design 1): the (far, pc) pair the kernel tested, far == *(pc-0x40).  Kept out of the
# core REQUIRED only so the build's row gate can name it separately; the patcher's --emitter-missing test,
# the park's P2 and the press's row gate all read --required-rows (core + these).
SLOT_ROWS = ("swb_far", "swb_pc", "swb_ok", "swb_m40", "swb_m40_ok", "swb_ge")
SWB_ROWS = tuple("xnu_live_sweq_" + r for r in SLOT_ROWS)
# A2/A3/A4's window: REQUIRED rows include s3, s3_ok and bp0..3 (+_ok).  They are also listed here so a
# gate can name the window separately; the emitter gate dedupes.
BP_ROWS = tuple("xnu_live_sweq_bp%d%s" % (i, s) for i in range(4) for s in ("", "_ok"))
# THE OTHER HALF: wpc + w_ok are read in SWB_ROWS's cells, and REQUIRED below lists them; a build that
# prints them only under a wlg gate (wlg_need_wpc) can omit them, so the emitter test would pass while A1
# could not bind the pair.  build/park/press gate on WPC_ROWS as well.
WPC_ROWS = ("xnu_live_sweq_wpc", "xnu_live_sweq_w_ok")
REQUIRED = ("xnu_live_sweq_seq", "xnu_live_sweq_pid", "xnu_live_sweq_s3", "xnu_live_sweq_s3_ok",
            "xnu_live_sweq_bp0", "xnu_live_sweq_bp0_ok", "xnu_live_sweq_bp1", "xnu_live_sweq_bp1_ok",
            "xnu_live_sweq_bp2", "xnu_live_sweq_bp2_ok", "xnu_live_sweq_bp3", "xnu_live_sweq_bp3_ok",
            "xnu_live_sweq_wpc", "xnu_live_sweq_w_ok", "xnu_live_wlg_byte", "xnu_live_wlg_lev",
            "xnu_live_ler_seq", "xnu_live_ler_cnt_w", "xnu_live_ler_cnt_b", "xnu_live_ler_cnt_b_ok",
            "xnu_live_ler_le", "xnu_live_ler_le_ok", "xnu_live_ler_ppc")
# presence-checked, never a conjunct: the other lane's switch
UVC_ROWS = ("xnu_live_uvc_num", "xnu_live_uvc_pc")


def num(s):
    try:
        return int(s.strip(), 0)
    except (ValueError, AttributeError):
        return None


def _rx(name):
    # a row ends at whitespace, an escape, or a `[` (a kernel log prefix), as in 1035/1036/1037's readers;
    # AND at `=` -- the emitter test's stem regexes see the patcher SOURCE, where a split `printf` leaves
    # `swb_far=0x%08x` and `swb_ge=%d` as text.  No decimal or hex row value contains `=`.
    return re.compile(re.escape(name) + r"=([^\s\x1b\[=]+)")


def first(text, name):
    m = _rx(name).search(text)
    return m.group(1) if m is not None else None


def parse_rows(text):
    """One dict per `xnu_live_sweq_seq` (arm A and arm B share the index and print A first)."""
    rows, cur = [], None
    seq_rx = _rx(A_BASE + "_seq")
    b_seq_rx = _rx(B_BASE + "_seq")
    # LONGEST NAME FIRST: `swb_m40` is a prefix of `swb_m40_ok`, so an unordered scan would read
    # `swb_m40_ok=1` as `swb_m40` = "1".  Sort by length, descending.
    _all = [A_BASE + "_" + r for r in A_ROWS] + [B_BASE + "_" + r for r in B_ROWS] \
        + [A_BASE + "_" + r for r in SLOT_ROWS] + [A_BASE + "_pcx" + r for r in ("", "_ok")]
    names = [(n, _rx(n)) for n in sorted(_all, key=len, reverse=True)]
    for ln in text.splitlines():
        if not any(k in ln for k in ("xnu_live_sweq_", "xnu_live_ler_", "xnu_live_wlg_")):
            continue
        if seq_rx.search(ln) is not None:
            if cur is not None:
                rows.append(cur)
            cur = {}
        elif b_seq_rx.search(ln) is not None and (cur is None or "b_seq" in cur):
            # a second arm-B publication (or arm B before any arm A) closes the dict as well
            if cur is not None:
                rows.append(cur)
            cur = {}
        if cur is None:
            continue
        for k, r in names:
            mm = r.search(ln)
            if mm is not None:
                cur[k.replace(A_BASE + "_", "a_").replace(B_BASE + "_", "b_")] = mm.group(1)
    if cur is not None:
        rows.append(cur)
    # the gate rows carry no index: they belong to the first (only) publication
    if rows:
        for g in GATES_PRINTED:
            mm = _rx("xnu_live_wlg_" + g).search(text)
            if mm is not None:
                rows[0]["a_wlg_" + g] = mm.group(1)
    return rows


def emitter_names(text):
    """The row names a patcher's arms can print.  The patcher builds each printf as source pieces; the
    pieces are ADJACENT C string literals, so the joined text is one literal whose quotes are escaped
    (`printf(\"xnu_live_sweq_tdfar=0x%08x\\n\"`).  Names: every `xnu_live_<arm>_<name>=` in a joined
    piece, plus the names a `%s` generator prints (`xnu_live_sweq_%s=`), expanded by its loop
    (`enumerate("s%d" % k for k in range(16))`).  Presence only -- never a value."""
    global EMITTER_TUPLES
    TUPLES = set()
    names = set()
    # the patcher builds the literal name from pieces (`_r("sweq_", nm, ...)` -> '...xnu_live_' + pre + nm
    # + '='), so the name is not always a single literal in the text: take the pieces AND every
    # `"<name>"` / `"<name>_tail"` argument the row builders are given (measured 2026-10-19: a literal-only
    # scan saw zero names and the TRAY gate could not fail on a real typo).
    for m in re.finditer(r"xnu_live_(?:sweq|ler)_([A-Za-z][A-Za-z0-9_]*)=", text):
        names.add(m.group(1))
    for _stem, _tok in (("sweq_", r"sweq_"), ("ler_", r"ler_")):
        for m in re.finditer(r'(?:_r|_a_print)\(\s*"' + _tok + r'",\s*"([A-Za-z][A-Za-z0-9_]*)"', text):
            names.add(m.group(1))
        for m in re.finditer(r'"(xnu_live_' + _tok + r')"\s*\+\s*([A-Za-z_]\w*)', text):
            pass    # the runtime-built prefix: its names come from the tuple items below
    # a text piece whose tail is the row's NAME (the patcher splices `_r`'s literal this way):
    # 'printf("xnu_live_sweq_' + _nm + '=0x%08x'  ->  bp0..bp3 written out, never a %-built name
    for _m in re.finditer(r'"xnu_live_sweq_\"\s*\+\s*\w+\s*\+\s*"', text):
        for _n in ("bp0", "bp1", "bp2", "bp3"):
            names.add(_n); names.add(_n + "_ok")
    # tuple items of the row builders: ("name", "fmt\n", "value").  Rows built with a function name or
    # an expression in the name slot (`_r("ler_", "sv%d" % k, ...)`) are NOT tuples and are skipped.
    for m in re.finditer(r"\(" + r'"([A-Za-z][A-Za-z0-9_]*)",\s*"[^"]*\\n",', text):
        names.add(m.group(1)); TUPLES.add(m.group(1))
    for m in re.finditer(r'\("wlr_" if \w+ else "ler_", (\w+)\[3:\] if \1 else \w+,', text):
        names.add("lr_" + m.group(1))
    # a literal-headed indexed row: 'printf("xnu_live_sweq_s%d_ok=%d' % _k (the name IS a literal prefix
    # plus an index; the source carries it once, so this reads the SAME text the compiler does)
    for m in re.finditer(r'"xnu_live_(?:sweq|ler)_([A-Za-z][A-Za-z0-9_]*)%d[^"]*"\s*%\s*([A-Za-z_]\w*)', text):
        for _k in range(16):
            names.add("%s%d" % (m.group(1), _k))
    for m in re.finditer(r'enumerate\("([A-Za-z]+)%d" % \w+ for \w+ in range\((\d+)\)\)', text):
        stem, n = m.group(1), int(m.group(2))
        for k in range(n):
            names.add("%s%d" % (stem, k))
            names.add("%s%d_ok" % (stem, k))
    # gate rows are printed by `printf("xnu_live_wlg_byte=%u` and the need_%s generator
    for m in re.finditer(r"xnu_live_wlg_([a-z0-9]+)=%", text):
        names.add("wlg_" + m.group(1))
    EMITTER_TUPLES = TUPLES
    return names


EMITTER_TUPLES = set()


def _short(r):
    for pre in ("xnu_live_sweq_", "xnu_live_ler_"):
        if r.startswith(pre):
            return r[len(pre):]
    return r


def emitter_missing(text, rows):
    """The rows of `rows` (full names, e.g. xnu_live_sweq_bp0) that the patcher source cannot print."""
    have = emitter_names(text)
    # a gate row is named by its prefix alone (`printf("xnu_live_wlg_byte=%u`)
    return [r for r in rows if _short(r) not in have and not (r.startswith("xnu_live_wlg_")
                                                               and (r + "=") in text)]


def boot_epoch(text):
    """The boot the capture is OF: the first in-log `[<sec>.<frac>]` stamp, or None (never the name)."""
    m = re.search(r"\[\s*(\d{9,})\.\d+\]", text)
    return int(m.group(1)) if m else None


def named_epoch(path):
    """The `-YYYYMMDD-HHMMSS-` stamp in the name: when the capture was TAKEN (diagnostic print only)."""
    m = re.search(r"-(\d{8})-(\d{6})-", os.path.basename(path))
    if not m:
        return None
    d = m.group(1) + m.group(2)
    return "%s-%s-%s %s:%s:%sZ" % (d[0:4], d[4:6], d[6:8], d[8:10], d[10:12], d[12:14])


A4_SHORT = "A4 CANNOT fire as written (its premise has no host-decidable row); see `--help`."

A4_NOTE = ("A4 CANNOT fire as written: its conjunct needs bp READABLE, and under that conjunct its "
           "premise (`s3's source absent`) is not host-decidable - a copy that is not there and a copy "
           "the block did not read look the same on the host.  A4 stays pre-registered and unread.")


def _gates(r):
    return {"byte": num(r.get("a_wlg_byte")), "lev": num(r.get("a_wlg_lev")),
            "need": {g.replace("need_", ""): num(r.get("a_wlg_" + g)) for g in GATES_PRINTED if "need" in g}}


def _need_ok(gates, row, bits):
    """The kernel's own gate for `row`: the bit mask it printed must include one of `bits` (0 = no gate)."""
    m = gates["need"].get(row)
    if bits == 0:
        return True
    if m is None:
        return False
    return bool(m & bits)


def cell_a(r):
    """Arm A.  Rows are keyed a_<name>."""
    # the slot rows are stored bare (a_swb_far...), as parse_rows keys them
    v_s = lambda k: num(r.get("a_swb_" + k))
    v = lambda k: num(r.get("a_" + k))
    notes = []
    # parse_rows returns (rows, notes); the value call sites pass the rows alone
    if isinstance(r, tuple):
        r = r[0]
    g = _gates(r)
    s3 = v("s3")
    # swb_pc is taken AS PRINTED.  (2026-10-19, wire1038: the slot is 16 x 19 words, word 15 = pc; its pc is
    # NOT derivable from far, and this reader does not derive it.  If the patcher's swb_pc is far-0x40, the
    # pc-rejection below can REJECT A1 at another pc but can never CONFIRM B2's pair; see F8.)
    far, pc = v("swb_far"), v("swb_pc")
    if far is None or pc is None:
        notes.append("  A falsifier: the (far, pc) pair is absent (swb_far=%s swb_pc=%s) - A1's "
                     "`far == *(pc-0x40)` cannot be tested; A1 must not fire."
                     % (r.get("a_swb_far", "(absent)"), r.get("a_swb_pc", "(absent)")))
    if s3 is None:
        return None, ["  NO A CELL (s3): xnu_live_sweq_s3 is absent from the first sweq row."]
    if s3 == 0:
        return None, ["  A falsifier: s3 == 0 - the block never ran (no reading)."]
    if v("s3_ok") != 1:
        return None, ["  NO A CELL: s3_ok=%s - the s3 read missed, so s3 = 0x%x is not a value."
                      % (r.get("a_s3_ok", "(absent)"), s3)]
    if s3 == U32:
        notes.append("  NOTE: s3 == 0xffffffff reproduces 1036's value BY DESIGN - in A1 it is not "
                     "evidence; A1's force is the bp fault AND far == *(pc-0x40).")
    wpc, w_ok = v("wpc"), v("w_ok")
    # THE PAIR'S OWN PC (2026-10-19, wire1038's correction): `far == *(pc-0x40)` was tested by the DEVICE
    # only at swb_pc, and only if that pc is the walk's pc as this arm's own row gives it.  The two pc
    # rows come from different producers (wpc = wlg saved-r11 chain, swb_pc = the fault pair), so agreement
    # is a conjunct, not an identity: a pair stated at any other pc is a test of another instruction.
    pair_pc = None
    if pc is not None and w_ok == 1 and wpc is not None:
        if wpc == pc:
            pair_pc = pc
        else:
            notes.append("  A falsifier: the fault pair's pc 0x%x is not the walk's pc 0x%x (the arm's own "
                         "wpc row) - `far == *(pc-0x40)` was tested for another instruction.  A1 unread."
                         % (pc, wpc))
    if pc is not None and w_ok == 1 and wpc is not None and wpc != pc:
        # the walk's pc, through the saved-r11 chain: the pc-0x40 the conjunct is about is THIS one
        notes.append("  A window: the walk's pc (wlg chain) is 0x%x, not the arm's own pc 0x%x - the copy's "
                     "site is wpc-0x40; the bp rows are read at s3 regardless." % (wpc, pc))
        pc = wpc
    bp = [(i, v("bp%d" % i), v("bp%d_ok" % i)) for i in range(4)]
    present = [b for b in bp if b[1] is not None and b[2] is not None]
    if len(present) != 4:
        # A bp row gone is not a smaller window: no bp conjunct can be stated (an absent row is never
        # a readable or a faulted one), so no A cell at all.
        miss = [k for i in range(4) for k in ("bp%d" % i, "bp%d_ok" % i) if v(k) is None]
        return None, notes + ["  NO A CELL (bp): the bp rows are INCOMPLETE - %s absent - so neither A1's "
                              "fault nor A2/A3's readable can be stated.  " % ", ".join(miss) + A4_SHORT]
        return None, notes + ["  NO A CELL (bp): no bp row is printed with its _ok - the bp conjuncts are "
                              "absent (an absent row is never a negative).  " + A4_SHORT + "\n  " + A4_NOTE]
    readable = [b for b in bp if b[2] == 1]
    faulted = [b for b in bp if b[2] != 1]

    # ---- A1: the bp rows fault; far == *(pc-0x40) must come from a DEVICE row ----------------------------
    # A1's SOUNDNESS (2026-10-19, wire1038's slot semantics): the signal is xnu_live_sweq_swb_ge -- the
    # slot's own `word at far-0x40 == far` test -- and it is a reading only when swb_ok=1 (the tag is this
    # thread's and the re-reads agree), swb_m40_ok=1 (the word WAS read), and swb_far != 0 (the 7-arg
    # arm_ctx->far can be 0; the slot then has a tag but a `pc = far - 0x40` underflow).  A1 is WITHHELD
    # (neither held nor refuted) when a row is absent, or when far != 0 but m40 was not read -- the kernel
    # is expected to have read it on this path.
    m40, m40_ok, ge = v_s("m40"), v_s("m40_ok"), v_s("ge")
    a1_withheld = None
    if v_s("ok") == 1 and far is not None:
        if far == 0:
            a1_withheld = ("swb_ok=1 with swb_far=0: the 7-argument arm_ctx->far was 0 at the slot write, so "
                           "swb_pc = far - 0x40 UNDERFLOWS and the slot's word is not the walk's table read.  "
                           "A1's conjunct is not stated on this run")
        elif ge is None or m40_ok is None or m40 is None:
            a1_withheld = ("swb_ok=1 but the slot's own conjunct rows are absent (swb_m40=%s swb_ge=%s swb_m40_ok=%s) - "
                           "the host cannot state `far == *(far-0x40)`"
                           % (r.get("a_swb_m40", "(absent)"), r.get("a_swb_ge", "(absent)"),
                              r.get("a_swb_m40_ok", "(absent)")))
        elif m40_ok != 1:
            a1_withheld = ("swb_ok=1 at far=0x%x but swb_m40_ok=%s: the word at far-0x40 was NOT read, so the "
                           "kernel's `far == *(far-0x40)` is not a reading (swb_ge is computed from a 0)."
                           % (far, r.get("a_swb_m40_ok")))
    if len(faulted) == 4 and s3 == U32:
        swb_ok = v("swb_ok")
        if g["byte"] == 0:
            return None, notes + [
                "  NO A CELL: the bp rows fault and s3 == -1, but wlg_byte=0 - the walk's page is NOT in "
                "the task map, so the kernel's own pc-0x40 read was a miss too and A1's "
                "`far == *(pc-0x40)` conjunct is WITHDRAWN (not refuted).  A1 unread."]
        # swb_ok=1 is the DEVICE's claim that far == *(pc-0x40) held AT ITS OWN (far, pc).  It is not the
        # pre-registered conjunct unless those ARE B2's pair: a "held" at another address is a different
        # test and REJECTS A1 (records/1038-read.txt 1, first falsifier).
        if swb_ok == 1 and far is not None and far != B2_FAR:
            return None, notes + [
                "  NO A CELL: the bp rows fault, but swb_ok=1 was stated at far=0x%x, not B2's 0x%x - the "
                "faulting instruction is not the one B3 names.  A1 unread (the slot's far is not the walk's "
                "0x10, so this run's fault is not the one A1 is about; an absent conjunct is not a refutation)."
                % (far, B2_FAR)]
        if swb_ok == 1 and pc is not None and pc != B2_PC:
            return None, notes + [
                "  NO A CELL: the bp rows fault, but swb_ok=1 was stated at pc=0x%x, not B2's 0x%x - the "
                "copy's site under H-SHORTNAME is not the one A2's basis names.  A1 unread." % (pc, B2_PC)]
        if swb_ok == 1 and pair_pc is None:
            return None, notes + [
                "  NO A CELL: the bp rows fault and swb_ok=1 at B2's pair, but the pair is not BOUND to this "
                "arm: wpc=%s w_ok=%s swb_pc=0x%08x.  A held conjunct is a reading only at the pc A's own row "
                "gives (the press_1038/build gates require xnu_live_sweq_wpc/_w_ok)." % (
                    r.get("a_wpc", "(absent)"), r.get("a_w_ok", "(absent)"), pc)]
        if swb_ok == 1:
            if a1_withheld is not None:
                return None, notes + ["  NO A CELL: the bp rows fault and s3 == -1, but A1's conjunct is WITHHELD - "
                                      + a1_withheld + ".  A1 unread."]
            if ge != 1:
                # F8: only a reading when a pc the slot recorded says far-0x40.  Without swb_pcw the test may
                # have been taken at far-0x40 itself (far-0x40 == far-0x80 then: never held) -> WITHHELD.
                kind = ("REJECTED" if (pc is not None and pc == B2_PC) else "WITHHELD")
                return None, notes + [
                    "  NO A CELL: the bp rows fault, but the slot's own conjunct did not hold: swb_ge=0 "
                    "(swb_m40=0x%08x swb_far=0x%x, swb_pc=0x%x) - A1 " % (m40, far or 0, pc or 0) + kind +
                    ".  swb_ge tests far-0x40 only when swb_pc is the recorded pc; without a slot-pc row "
                    "the miss cannot be told from a test taken at the wrong address."]
            return "A1", notes + [
                "A1 WATCH-FATAL: every bp row FAULTS (s3 points at the copy and the copy is not mapped), s3 "
                "== 0xffffffff, and the slot's own row says far == *(far-0x40) HELD (swb_ge=1, swb_far=0x%x "
                "swb_m40=0x%x, swb_pc=0x%x)." % (far, m40, pc)]
        far_note = ""
        if far is not None and pc is not None and pc != B2_PC:
            far_note = ("  A1 falsifier: pc reads 0x%x, not B2's 0x%x - under H-SHORTNAME the copy lands "
                        "0x5d3bd7 + (pc - 0x%x) in the file, not at far's source.  %s"
                        % (pc, B2_PC, PC_FILE_BASE,
                           "A miss on the file word there REJECTS A1." if g["byte"] == 1
                           else "wlg_byte=%s: the file word there was not read." % g["byte"]))
        elif far is not None and far != B2_FAR:
            far_note = ("  A1 falsifier: far=0x%x is not B2's 0x%x - the faulting instruction is not the "
                        "one B3 names." % (far, B2_FAR))
        return None, notes + [
            "  NO A CELL: the bp rows fault and s3 == -1, but swb_ok=%s - the device's `far == *(pc-0x40)` "
            "conjunct is not stated (the host cannot read *(pc-0x40)).  A1 unread." % r.get("a_swb_ok", "(absent)"),
            far_note or "  A1's third conjunct: far=0x%x is the right ADDRESS and nothing more." % (far or 0)]
    if readable and faulted:
        return None, notes + ["  NO A CELL: bp is PARTLY readable (readable bp%s, faulted bp%s) and faulted "
                              "rows never count as readable - A2/A3/A4 cannot be stated.  "
                              % ([i for i, _, _ in readable], [i for i, _, _ in faulted]) + A4_SHORT + "\n  " + A4_NOTE]

    # ---- A2/A3/A4: bp readable ---------------------------------------------------------------------
    def bp_bytes():
        return b"".join(v("bp%d" % i).to_bytes(4, "little") for i, _, _ in readable)

    got = bp_bytes()
    if all(b[1] == 0 for b in readable):
        return "A3", notes + ["A3 WATCH-READS-ZERO: bp readable and every word zero."]
    if (pc is not None and pc != B2_PC) or pc is None:
        # (swb_pc as printed; swb_ok=0 / swb_far=0 leave it 0 in the patcher as it stands.)
        return None, notes + [
            "  NO A CELL: bp readable and not zero, but swb_pc=%s is NOT 1036's 0x%08x - under H-SHORTNAME the "
            "copy's source offset is a function of the immediate, so the bp bytes cannot be matched against "
            "file 0x%x here.  A2 cannot be stated (nor can its absence).  " % (pc, B2_PC, B2_SOURCE_FILE_OFF)
            + A4_SHORT + "\n  " + A4_NOTE]
    start = 0
    want = B2_SOURCE[start:start + len(got)]
    eq = (got == want or (len(got) > len(want) and got[:len(want)] == want and not any(got[len(want):])))
    if eq:
        return "A2", notes + [
            "A2 WATCH-ALIVE: bp readable and the %d byte(s) equal the given copy at file 0x%x.  (The given "
            "copy is %d bytes, not 32: the remaining bp bytes are zero pad and are NOT a conjunct of A2.)"
            % (len(want), B2_SOURCE_FILE_OFF, len(B2_SOURCE))]
    return None, notes + [
        "  NO A CELL: bp readable but neither equal to the given 0x%x copy (bp=0x%s) nor zero - the tray is "
        "for the lead.  " % (B2_SOURCE_FILE_OFF, got.hex()) + A4_SHORT + "\n  " + A4_NOTE]


def cell_b(r):
    # Arm B.  Rows are keyed b_<name>; the gates are the kernel's own rows.
    v = lambda k: num(r.get("b_" + k))
    g = _gates(r)
    need = ("cnt_w", "cnt_w_ok", "cnt_b", "cnt_b_ok", "le", "le_ok", "ppc")
    miss = [k for k in need if v(k) is None]
    if miss:
        return None, ["  NO B CELL: the ler row lacks %s - its confirming conjuncts are absent (an absent "
                      "row is never a negative)." % "/".join(miss)]
    cw, cwok, cb, cbok, le, leok, ppc = (v(k) for k in need)
    notes = []
    if g["byte"] != 1:
        notes.append("  B gates: wlg_byte=%s - cnt_b and le were NOT read as bytes through the task map; "
                     "cnt_b_ok=%d le_ok=%d say whether a loader (kernel ldrb/literal) supplied them." %
                     (g["byte"], cbok, leok))
    if not _need_ok(g, "le", 0x80):
        notes.append("  B gate: the kernel's wlg_need_le mask does not include the byte gate (bit 7) - the "
                     "le row was not taken under its gate.")
    # THE POINT (docs/1038-design.md 2): one word equal under both views says nothing; the cell needs the
    # KERNEL's view to differ from the BYTE view ON THE SAME FOUR BYTES -- so cnt_w must be a reading.
    if cwok != 1:
        return None, notes + ["  NO B CELL: cnt_w_ok=0 - the kernel's own word read of [r3+0xc] missed "
                              "(the patcher: cnt_w is 0 / _ok=0 BY CONSTRUCTION on the kernel arm).  "
                              "cnt_b=0x%x against a MISSED control is not a second view of the same four "
                              "bytes; B1/B2 cannot be stated." % cb]
    if cbok != 1 or leok != 1:
        return None, notes + ["  NO B CELL: cnt_b_ok=%d le_ok=%d - a byte read that missed is not a byte "
                              "value." % (cbok, leok)]
    if cw == 0 and cb != 0 and le != ppc:
        return "B1", notes + ["B1 LE-CONFIRMED: cnt_w == 0 AND cnt_b=0x%x != 0 AND le_ok AND le=0x%08x != "
                              "ppc=0x%08x -> the KERNEL's word view and the BYTE view differ on the same four "
                              "bytes." % (cb, le, ppc)]
    return "B2", notes + ["B2 NOT-BE: the conjuncts fail (cnt_w=0x%x, cnt_b=0x%x, le=0x%08x, ppc=0x%08x) -> "
                          "the byte-swap model is DEAD." % (cw, cb, le, ppc)]


def solo_cell(r):
    # The SOLO sweep patch (STAGE90_XNU_WATCH_LE_SOLO): the SWB row the coupled patcher cannot place.
    v = lambda k: num(r.get(k))
    need = ("swb_far", "swb_pc", "swb_ok", "pcx", "pcx_ok")
    miss = [k for k in need if v(k) is None]
    if miss:
        return None, ["  NO SOLO CELL: the first solo row lacks %s." % "/".join(miss)]
    far, pc, ok, pcx, pcxok = (v(k) for k in need)
    if ok == 1:
        return "SWB", ["SWB CODE-USER: the user-port sweep's fault was a READ of (pc-0x40) == 0x%08x "
                       "(far=0x%x) -> far == *(pc-0x40) HELD on a user-mode fault (far=0x%x)."
                       % (pcx, far, far)]
    if pcxok == 1 and far != 0 and pcxok == 1 and far >= 0x4000000:
        return None, ["  SOLO: far=0x%x is not the pcx value 0x%08x (the register read and the code read "
                      "differ) - the SOLO sweep's own gate, see records/1038-read.txt." % (far, pcx)]
    return None, ["  SOLO: swb_ok=%s pcx_ok=%s far=0x%x pc=0x%08x - far != *(pc-0x40)." % (ok, pcxok, far, pc)]


def read_capture(path):
    with open(path, "rb") as fh:
        return fh.read()


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) == 2 and argv[1] == "--core-rows":
        for r in REQUIRED:
            print(r)
        return 0
    if len(argv) == 2 and argv[1] == "--required-rows":
        for r in REQUIRED + SWB_ROWS + tuple(r for r in WPC_ROWS if r not in REQUIRED):
            print(r)
        return 0
    if len(argv) == 3 and argv[1] == "--emitter-missing":
        # rows REQUIRED that the given patcher source cannot print (park/build gate on a NON-EMPTY output)
        with open(argv[2], "r", errors="replace") as fh:
            src = fh.read()
        gated = SWB_ROWS + WPC_ROWS + REQUIRED          # REQUIRED already carries BP_ROWS
        m = emitter_missing(src, gated)
        if m:
            print(" ".join(m))
            return 1
        print("all %d gated rows are printable by %s" % (
            len(set(gated)), os.path.basename(argv[2])))
        return 0
    if len(argv) == 2 and argv[1] == "--companion-rows":
        # ANOTHER lane's switch (STAGE90_XNU_USTACK_VALIDATE): checked for PRESENCE and reported, never a
        # conjunct of any 1038 cell -- so the build must NOT gate the image on them.
        for r in UVC_ROWS:
            print(r)
        return 0
    args = argv[1:]
    path, pre, after = None, None, None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--pre" and i + 1 < len(args):
            pre = args[i + 1]; i += 2
        elif a == "--after" and i + 1 < len(args):
            after = num(args[i + 1]); i += 2
        elif a.startswith("--") or path is not None:
            print("usage: check_1038_capture.py <capture> [--pre <copy>] [--after <boot_epoch>]")
            return 2
        else:
            path = a; i += 1
    if path is None:
        print("usage: check_1038_capture.py <capture> [--pre <copy>] [--after <boot_epoch>] | --selftest | "
              "--required-rows")
        return 2
    raw = read_capture(path)
    text = raw.decode("utf-8", "replace")
    if ENTRY_MARK not in text:
        print("NO READING - STALE SLOT: no `%s` in the capture" % ENTRY_MARK)
        return 2
    boot = boot_epoch(text)
    mtime = os.stat(path).st_mtime_ns // 1000000000
    if boot is not None and mtime < boot:
        print("NO READING - STALE SLOT: mtime %d older than the in-log boot stamp %d" % (mtime, boot))
        return 2
    if after is not None and (boot is None or boot < after):
        print("NO READING - STALE SLOT: the capture's boot epoch %s is not >= the press's boot %d"
              % (boot if boot is not None else "(absent)", after))
        return 2
    if pre is not None:
        with open(pre, "rb") as fh:
            if fh.read() == raw:
                print("NO READING - STALE SLOT: the capture is the same bytes as the pre-press copy %s - "
                      "the RAM-console slot was never rewritten" % os.path.basename(pre))
                return 2
        print("pre-press copy differs: %s" % os.path.basename(pre))
    print("capture: %s (name stamp %s -- when it was TAKEN, not the boot; in-log boot %s)"
          % (os.path.basename(path), named_epoch(path) or "(none)",
             boot if boot is not None else "UNKNOWN"))
    print("switch: %s (tools/patch_d13_watch_le.py).  Block C is NOT in that patcher - no C cell this run."
          % WATCH_LE_SWITCH)
    fired, held = [], []

    # One row dict PER ARM: a second block of arm A (the hook's own statics) must not blank arm B --
    # parse_rows closes a dict on ANY seq, so arm B is parsed on its own `ler_seq` as well.
    arows = [x for x in parse_rows(text) if "a_seq" in x]
    if not arows:
        if A_BASE + "_seq=" not in text:
            print("NO A ROWS: the capture carries no xnu_live_sweq_seq -- the WATCH_LE block (arm A) did not "
                  "run this boot (or was not compiled in). NOT a reading; withhold.")
        held.append("A")
    else:
        r = arows[0]
        print("A rows=%d (one index per arm; reading the first)" % len(arows))
        tray = [("A", A_ROWS), ("A", SLOT_ROWS + ("pcx", "pcx_ok"))]
        for arm, names in tray:
            print("  %s: " % arm + " ".join("%s=%s" % (k, r.get("a_" + k, "(absent)")) for k in names))
        print("  gates: " + " ".join("%s=%s" % (k, r.get("a_wlg_" + k, "(absent)")) for k in GATE_ROWS[:2]))
        a_cell, a_lines = cell_a(r)
        for ln in a_lines:
            print(ln)
        if a_cell:
            fired.append(a_cell)
        elif any(ln.strip().startswith(("NO A", "A falsifier")) for ln in a_lines):
            held.append("A")
    brows = [x for x in parse_rows(text) if "b_seq" in x]
    if not brows:
        if B_BASE + "_seq=" not in text:
            print("NO B ROWS: the capture carries no xnu_live_ler_seq -- arm B did not run this boot.")
        held.append("B")
    else:
        br = brows[0]
        print("  B: " + " ".join("%s=%s" % (k, br.get("b_" + k, "(absent)")) for k in B_ROWS))
        b_cell, b_lines = cell_b(br)
        for ln in b_lines:
            print(ln)
        if b_cell:
            fired.append(b_cell)
        else:
            held.append("B")
    if not arows and not brows and A_BASE + "_seq=" not in text and B_BASE + "_seq=" not in text:
        print("NO WATCH_LE ROWS: neither arm is in this capture. NOT a reading; withhold.")
    if SOLO_BASE + "_seq=" in text:
        srow = {k: first(text, SOLO_BASE + "_" + k) for k in SOLO_ROWS}
        c, lines = solo_cell(srow)
        for ln in lines:
            print(ln)
        if c:
            fired.append(c)
    else:
        print("  solo: STAGE90_XNU_WATCH_LE_SOLO rows absent (the solo sweep patch did not run or is not "
              "staged) - no code-user cell.")
    miss = [u for u in UVC_ROWS if first(text, u) is None]
    if miss:
        print("  NOTE: STAGE90_XNU_USTACK_VALIDATE does NOT print %s in this capture - the uvc rows are from "
              "a DIFFERENT lane's switch and are NOT used by any 1038 cell." % ", ".join(miss))
    else:
        print("  uvc (drive-by, another lane's STAGE90_XNU_USTACK_VALIDATE): "
              + " ".join("%s=%s" % (u, first(text, u)) for u in UVC_ROWS))
    print("CELLS: %s" % (" ".join(fired) if fired else "NONE"))
    if held:
        print("HOLD: %s -- these blocks printed no cell with a confirming row absent; the cells above are "
              "still readings, the held blocks state nothing." % ",".join(held))
    return 0 if fired else 1


# ===================================================================================================
def _rows(base, kw):
    out = ""
    for k, v in kw.items():
        if isinstance(v, bytes):
            out += "%s_%s=0x%08x\n" % (base, k, int.from_bytes(v[:4], "little") & U32)
        elif isinstance(v, str):
            out += "%s_%s=%s\n" % (base, k, v)
        else:
            out += "%s_%s=0x%08x\n" % (base, k, v & U32)
    return out


SRC = B2_SOURCE + bytes(16)             # the copy's 18 given bytes + zero pad to the 32-byte bp window


def _capture(use_a=True, use_b=True, uvc=True, solo=None, **a):
    # A synthetic 1038 capture.  `a` overrides arm A rows (s3, s3_ok, swb_far, swb_pc, swb_ok, wpc,
    # w_ok, byte, lev, bp0..bp3 (int|bytes), bp0_ok..bp3_ok, cnt_w_ok); `drop` names A rows to leave out.
    drop = a.pop("drop", ())
    byte, lev = a.pop("byte", 1), a.pop("lev", 2)
    out = "[    1792394337.000000] MI4IOS6_STAGE90 v1 entered\n"
    if use_a:
        kw = dict(seq=0, pid=2, ssid=0x2BD8D088, sp=0x2BD8D088, usp=0x2BD8D088, k=0, tdpc=0, td_ok=0,
                  swb_far=0x10, swb_pc=B2_PC, swb_ok=1, swb_m40=0x10, swb_m40_ok=1, swb_ge=1,
                  wpc=B2_PC, wfp=0x2BD8D0AC, w_ok=1)
        # NOT `kw.update(seq of pairs)`: a one-argument dict.update of 2-tuples sets keys <class int>, not
        # "s%d" -- the 2026-10-19 fixture defect that made every A case read the DEFAULT bp rows.
        for i in range(16):
            kw["s%d" % i] = U32 if i == 3 else i
        for i in range(16):
            kw["s%d_ok" % i] = 1
        # the ARM A READS: this fixture drives arm A only, so s3 is the slot the arm names (the less
        # mapped block is B3's fix requirement, not a value the reader can demand of the device)
        kw["s3"] = U32
        # caller overrides FIRST (they may replace the whole bp window), then the default bp bytes
        kw.update({k: v for k, v in a.items() if (k in A_ROWS or k in SLOT_ROWS) and k not in drop})
        for i in range(4):
            if "bp%d" % i not in drop:
                kw.setdefault("bp%d" % i, SRC[4 * i:4 * i + 4])
            if "bp%d_ok" % i not in drop:
                kw.setdefault("bp%d_ok" % i, 1)
        out += _rows(A_BASE, kw)
    # arm B and the gate rows are INDEPENDENT of arm A: A0-ABSENT must still read B
    if use_b:
        bw = dict(seq=0, pid=2, r3=0x39B04020, cnt_w=0, cnt_w_ok=1, cnt_b=0x1234, cnt_b_ok=1,
                  al0=0xE12FFF14, al0_ok=1, mfp1=0, mfp1_ok=1, mfp2=0, mfp2_ok=1, ppc=0xE12FFF14,
                  ppc_ok=1, le=0x2C5D, le_ok=1)
        bw.update({k: v for k, v in a.items() if k in B_ROWS})
        out += _rows(B_BASE, bw)
    # the gate rows carry no seq: they are read straight from the capture (first occurrence)
    out += "xnu_live_wlg_byte=%d\nxnu_live_wlg_lev=%d\n" % (byte, lev)
    for g in GATES_PRINTED:
        if not g.startswith("need"):
            continue
        bit = {"le": 7, "al0": 2, "wpc": 5, "wfp": 5, "w_ok": 5, "cnt_b": 7, "mfp1": 3,
               "mfp2": 3}.get(g[len("need_"):], 0)
        out += "xnu_live_wlg_%s=0x%08x\n" % (g, 1 << bit if bit else 1)
    if solo is not None:
        out += _rows(SOLO_BASE, solo)
    if uvc:
        out += "xnu_live_uvc_num=0x00000002\nxnu_live_uvc_pc=0x399a1474\n"
    return out


def selftest():
    import contextlib
    import io
    import tempfile
    import time
    fails = 0
    here = os.path.dirname(os.path.abspath(__file__))

    # TRAY-COMPLETE: a patcher on disk must emit ONLY names this reader knows (a typo in either is a row
    # the reader would print as absent).  A patcher not yet on disk is a note, never a pass or a fail.
    # Every name the kernel PRINTS must fall in a namespace this reader parses: the sweq names (A_ROWS,
    # SLOT_ROWS, wpc/wfp/w_ok), the ler names (B_ROWS, the stack sums), the wlg gate rows, and the
    # wlr *_wln rows (parsed as `lr_<x>` via `prefix.replace("wlr_", "lr_")`).
    # **The model's rows the hand-written tables predate.** `patch_d13_watch_le.py`'s rows loop emits
    # these from `printf("xnu_live_sweq_<name>=...")`; they are compiled OUT of a build whose
    # STAGE90_XNU_WATCH_LE is 0, so `strings trap.o` legitimately shows none of them - but they are
    # names this reader must be able to parse when the switch is on.
    MODEL_ROWS = {
        "bands", "bands2", "cnt", "cnt_ok", "ir", "pc", "pc4", "pc8", "pc_ok", "s3_acc", "seqeq",
        "st", "st_ok", "w15", "w", "sp", "s0", "so_n", "bo_n", "gl", "w_n", "le_addr", "le_ok_n",
        "lr_cnt", "lr_mfp1", "lr_mfp2", "lr_ppc", "wlg_canary", "wlg_lev", "wlg_byte", "pcx", "pcx_ok",
        "swb_slot", "swb_far", "swb_pc", "swb_pd", "swb_ok", "swb_tag", "swb_m40", "swb_m40_ok",
        "swb_m40b", "swb_m40b_ok", "swb_ge", "wpc", "wfp", "w_ok",
    }
    known = set(A_ROWS) | set(B_ROWS) | set(GATE_ROWS) | MODEL_ROWS | {"wlg_byte", "wlg_lev",
                                                         "wlg_canary", "pcx", "pcx_ok"} \
        | {"swb_slot", "swb_far", "swb_pc", "swb_pd", "swb_ok", "swb_tag", "swb_m40", "swb_m40_ok",
           "swb_m40b", "swb_m40b_ok", "swb_ge", "wpc", "wfp", "w_ok"} \
        | set(tuple("sv%d" % k for k in range(16)) + tuple("b%d" % k for k in range(4))
              + tuple("sv%d_ok" % k for k in range(16)) + tuple("b%d_ok" % k for k in range(4))
              + ("so_n", "bo_n", "gl", "w_n", "le_addr", "le_ok_n")) \
        | set("lr_" + x for x in ("cnt", "mfp1", "mfp2", "ppc"))
    for base, sw, patcher in ((A_BASE, WATCH_LE_SWITCH, "patch_d13_watch_le.py"),
                              (SOLO_BASE, SOLO_SWITCH, SOLO_PATCHER)):
        p = os.path.join(here, patcher)
        if not os.path.isfile(p):
            print("   TRAY-COMPLETE %s: %s not on disk - names are the design's (no patcher; not gated)"
                  % (base, patcher))
            continue
        with open(p, "r", errors="replace") as fh:
            ptxt = fh.read()
        # ONE SPELLING with --emitter-missing: the SAME parser (it knows the piece-built and generator names;
        # a literal-only scan here saw zero names on 2026-10-19 and could not fail).
        emitted = set(n for n in emitter_names(ptxt) if base == A_BASE or True)
        unknown = emitted - known
        # THE MUTANT: renaming a name the reader knows must be SEEN (else this gate is inert).
        _mut = ptxt.replace('"swb_ge"', '"swb_gee"')
        mutant_seen = (_mut != ptxt) and bool(emitter_names(_mut) - known)
        ok = bool(emitted) and not unknown and mutant_seen
        print("   TRAY-COMPLETE %s %s -> %d literal name(s)%s" % (
            base, "ok" if ok else "FAIL", len(emitted),
            "" if ok else ": not in this reader's rows: " + " ".join(sorted(unknown)) +
            ("" if mutant_seen else " (MUTANT NOT SEEN: this gate cannot fail)")))
        fails += 0 if ok else 1

    fault = {"bp%d_ok" % i: 0 for i in range(4)}
    cases = [  # name, text, argv-extra, want_exit (None = 0 or 1), must-print, must-NOT-print
        ("E2E", _capture(), (), 0, ("CELLS: A2 B1", "A2 WATCH-ALIVE", "B1 LE-CONFIRMED"), ("A1 WATCH", "A3 ", "A4 "),),
        ("A1", _capture(**fault), (), 0, ("A1 WATCH-FATAL",), ("A2 WATCH", "A3 ", "A4 ")),
        # the same fault without the device's own conjunct row: A1 is NOT adjudicated (and the falsifier
        # is said: far=0x10 is the right address, nothing more)
        ("A1-NO-SWB-OK", _capture(swb_ok=0, **fault), (), 0, ("NO A CELL: the bp rows fault", "right ADDRESS"),
         ("A1 WATCH",)),
        # wlg_byte=0 withdraws the conjunct: the page is not in the task map, neither held nor refuted
        ("A1-BYTE0", _capture(byte=0, **fault), (), 0, ("WITHDRAWN", "CELLS: B1"), ("A1 WATCH",)),
        # the slot's own soundness (wire1038 2026-10-19): a tag at far=0, an unread word, or the slot's
        # conjunct FALSE -- each leaves A1 withheld or rejected, never fired.
        ("A1-FAR0", _capture(swb_far=0, swb_pc=0, swb_m40=0, swb_ge=1, **fault), (), 0,
         ("swb_far=0", "A1 unread"), ("A1 WATCH",)),
        ("A1-M40-MISS", _capture(swb_m40=0, swb_m40_ok=0, swb_ge=0, **fault), (), 0,
         ("swb_m40_ok=0x00000000", "A1 unread"), ("A1 WATCH",)),
        # swb_ge=0 is a REFUTATION only when swb_pc is the pre-registered pc; at any other pc it is WITHHELD
        ("A1-GE0", _capture(swb_m40=0x14, swb_ge=0, **fault), (), 0, ("swb_ge=0", "A1 REJECTED"), ("A1 WATCH",)),
        ("A1-GE0-OTHERPC", _capture(swb_m40=0x14, swb_ge=0, swb_pc=B2_PC + 4, wpc=B2_PC + 4, **fault), (), 0,
         # the pc != B2_PC branch precedes the ge branch: a slot at another pc is a test of another
         # instruction, so A1 is unread there whatever its ge says.
         ("A1 unread",), ("A1 WATCH", "A1 REJECTED")),
        ("A1-FAR-OTHER", _capture(swb_far=0x14, swb_pc=B2_PC + 4, wpc=B2_PC + 4, **fault), (), 0,
         ("A1 unread",), ("A1 WATCH",)),
        ("A1-FAR", _capture(swb_far=0x14, **fault), (), 0, ("swb_ok=1 was stated at far=0x14, not B2's 0x10",),
         ("A1 WATCH",)),
        # wire1038 2026-10-19: the held conjunct is a reading only at the pc A's own row gives.  A pair at
        # B2's place with a wpc that moved is not bound; no w_ok row at all is not bound either.
        ("A1-UNBOUND-WPC", _capture(wpc=B2_PC + 4, w_ok=1, **fault), (), 0,
         ("is not the walk's pc", "tested for another instruction"), ("A1 WATCH", "A held conjunct")),
        ("A1-UNBOUND-NOWOK", _capture(w_ok=0, **fault), (), 0, ("not BOUND",), ("A1 WATCH",)),
        ("A3", _capture(bp0=0, bp1=0, bp2=0, bp3=0), (), 0, ("A3 WATCH-READS-ZERO",),
         ("A1 WATCH", "A2 WATCH", "A4 WATCH")),
        ("A-NOT-COPY", _capture(bp0=0xDEADBEEF), (), 0, ("NO A CELL: bp readable", "A4 CANNOT fire"),
         ("A1 WATCH", "A2 WATCH", "A3 ", "A4 WATCH")),
        ("A-PARTLY-READABLE", _capture(bp1_ok=0), (), 0, ("bp is PARTLY readable", "A4 CANNOT fire"),
         ("A1 WATCH", "A2 WATCH", "A3 ", "A4 WATCH-STORE")),
        # arm A absent but arm B present: A holds, B still reads (rc 0)
        ("A0-ABSENT", _capture(use_a=False), (), 0, ("NO A ROWS", "CELLS: B1", "HOLD: A"), ("A2 WATCH", "A3 ")),
        ("A-BP-ABSENT", _capture(drop=("bp0", "bp0_ok")), (), 0, ("NO A CELL (bp)", "bp0, bp0_ok absent", "HOLD: A"),
         ("A1 WATCH", "A2 WATCH", "A3 ", "A4 WATCH")),
        ("S3-ZERO", _capture(s3=0), (), 0, ("A falsifier: s3 == 0", "CELLS: B1"), ("A1 WATCH", "A2 WATCH", "A3 ")),
        ("A2-PC-OTHER", _capture(wpc=B2_PC + 4, swb_pc=B2_PC + 4), (), 0, ("NO A CELL: bp readable", "H-SHORTNAME"),
         ("A2 WATCH",)),
        # arm B: the control missed -> no B cell (the byte view against a MISSED control is not "the same
        # four bytes")
        ("B-NO-CONTROL", _capture(cnt_w_ok=0), (), 0, ("cnt_w_ok=0", "CELLS: A2"), ("B1 LE-CONFIRMED", "B2 NOT-BE")),
        ("B2", _capture(le=0xE12FFF14), (), 0, ("B2 NOT-BE", "CELLS: A2 B2"), ("B1 LE-CONFIRMED",)),
        ("B-NOLE", _capture(le_ok=0), (), 0, ("NO B CELL",), ("B1 LE-CONFIRMED", "B2 NOT-BE")),
        ("B-BYTE0", _capture(byte=0), (), 0, ("B gates: wlg_byte=0",), ()),
        ("NOROW", "[    1792394337.000000] MI4IOS6_STAGE90 v1 entered\nnothing\n", (), 1, ("NO WATCH_LE ROWS",),
         ("A1", "B1")),
        ("STALE", "xnu_live_sweq_seq=0\nxnu_live_sweq_s3=0xffffffff\n", (), 2, ("STALE SLOT",), ()),
        # the solo sweep patch's SWB row (solo=dict(...): the solo rows are a POSITIONAL fixture arg)
        ("SOLO-SWB", _capture(solo=dict(seq=0, pid=2, swb_far=0x10, swb_pc=B2_PC, swb_ok=1, pcx=0x14, pcx_ok=1)),
         (), 0, ("SWB CODE-USER",), ()),
        ("SOLO-ABSENT", _capture(), (), 0, ("solo: STAGE90_XNU_WATCH_LE_SOLO rows absent",), ("SWB",)),
    ]
    with tempfile.TemporaryDirectory() as d:
        def run(p, extra):
            """main() under a stdout capture; an exception is a FAILED case, never a silent rc."""
            buf = io.StringIO()
            try:
                with contextlib.redirect_stdout(buf):
                    rc = main(["x", p] + list(extra))
            except Exception as e:            # noqa: BLE001 -- reported, and counted as a fail
                return None, "%s: %s" % (type(e).__name__, e)
            return rc, buf.getvalue()

        def judge(name, rc, out, want, must, mustnot):
            nonlocal fails
            rc_ok = rc in (0, 1) if want is None else rc == want
            bad = [s for s in must if s not in out] + ["NOT " + s for s in mustnot if s in out]
            ok = rc_ok and not bad
            why = "" if rc_ok else " (rc mismatch)"
            if bad:
                why += "  bad expectations: " + ", ".join(bad)
            print("   %s %s -> exit %s (want %s)%s%s" % (name, "ok" if ok else "FAIL",
                                                        "None" if rc is None else rc,
                                                        "0|1" if want is None else want, why,
                                                        "" if ok else "\n----\n" + out + "\n----"))
            fails += 0 if ok else 1

        for name, text, extra, want, must, mustnot in cases:
            p = os.path.join(d, "recovered-20261019-090000-cap-%s-last_kmsg.txt" % name)
            with open(p, "w") as fh:
                fh.write(text)
            if name != "STALE":
                t = time.time() + 10
                os.utime(p, (t, t))
            rc, out = run(p, extra)
            judge(name, rc, out, want, must, mustnot)
        # the staleness rules that need a second file / a boot epoch
        p = os.path.join(d, "recovered-20261019-090000-cap-CUR-last_kmsg.txt")
        with open(p, "w") as fh:
            fh.write(_capture())
        t = time.time() + 10
        os.utime(p, (t, t))
        q = os.path.join(d, "pre-copy.txt")
        with open(q, "w") as fh:
            fh.write(_capture())
        rc, out = run(p, ["--pre", q])
        judge("PRE-SAME", rc, out, 2, ("same bytes as the pre-press copy",), ())
        with open(q, "w") as fh:
            fh.write(_capture(s3=0))
        rc, out = run(p, ["--pre", q])
        judge("PRE-DIFF", rc, out, 0, ("pre-press copy differs",), ())
        rc, out = run(p, ["--after", "1792400000"])
        judge("AFTER-OLD", rc, out, 2, ("not >= the press's boot",), ())
        rc, out = run(p, ["--after", "1792390000"])
        judge("AFTER-NEW", rc, out, 0, ("A2 WATCH-ALIVE",), ())
        # the mtime rule on its own: a capture whose file mtime is BEFORE its in-log boot is stale (exit 2)
        # even when --after is satisfied -- a re-copied older slot is not this press's log.
        r = os.path.join(d, "recovered-20261019-090000-cap-OLDMTIME-last_kmsg.txt")
        with open(r, "w") as fh:
            fh.write(_capture())
        late = time.time() + 10
        os.utime(r, (late, late))
        rc, out = run(r, ["--after", "1792390000"])
        judge("MTIME-OK", rc, out, 0, ("A2 WATCH-ALIVE",), ())
        boot_in_log = 1792394337
        old_t = boot_in_log - 3600
        os.utime(r, (old_t, old_t))
        rc, out = run(r, ["--after", "1792390000"])
        judge("MTIME-OLD", rc, out, 2, ("mtime", "older than the in-log boot"), ())
        rc, out = run("x", ["--bogus"])
        judge("BAD-ARG", rc, out, 2, ("usage:",), ())
    print("SELFTEST %s" % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))