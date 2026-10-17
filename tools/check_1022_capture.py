#!/usr/bin/env python3
"""Mechanical reader for a **1022** press capture - DID INSTALLING `mach_trap_table[15]`
(`ios7lab_mach_vm_map_trap`) RETIRE pid 1's `__os_alloc_slow+0x108` undefined instruction?

WHAT 1022 IS.  `docs/1022-mach-trap-15-design.md` §7, adjudicated in
`records/1022-trap15-adjudication.txt`.  1021d's press read A-RETIRED
(`records/1021d-press-read.txt`): `-msoft-float` removed the kernel-mode NEON undef at
`0x8047b0ac`, and the frontier MOVED to pid 1's USER-MODE undefined instruction - the `udf #254`
inside `libsystem_platform.dylib`'s `__os_alloc_slow`, reached from BOTH of that function's
`_mach_vm_map` failure branches.  The arithmetic is
`0x39e38a54 - slide 0x1bfe000 == 0x3823aa54 == __os_alloc_slow + 0x108`, the SAME library FILE
OFFSET as 1020b's `0x39605a54 - slide 0x13cb000`.  ⚠ **The slide VARIES per run; the raw pc is NOT
comparable across runs and this reader never compares it as one.**  The invariant is the FILE OFFSET
(`pc - slide`), and the slide is read from the capture's OWN `map_slide pid=1` line.

WHY THE WALL EXISTS (the premise, by value): the client's fast-trap stub `0x381c5960` is
`mov ip,sp; push {r4,r5,r6,r8}; ldm ip,{r4,r5,r6,r8}; mvn ip,#14; svc #0x80`, so `ip = -15` = table
index 15 - and in the linked image `mach_trap_table[15].fn == mach_trap_table[0].fn == kern_invalid`
(`records/1022-trap15-wire.txt` §2).  1022 installs the row (`syscall_sw.c:126`), opens its body's
file gate (`mach_kernelrpc.c:59`) and its runtime selector (`mach_kernelrpc.c:217`).

THE ONE QUESTION:

    With the row installed and the selector answering 1, does pid 1's `mach_vm_map` get dispatched
    and succeed - i.e. does the row get USED, does the adapter's view of the frame match the frame
    libsystem sent, and does the allocator stop failing?

------------------------------------------------------------------------------
WHAT THIS READER READS BY VALUE, AND WHAT IT REFUSES TO ASSUME
------------------------------------------------------------------------------
  * **THE TWO WITNESSES, AND WHY `G-CTL` ASKS FOR BOTH.**  (i) the live undef witness
    (`xnu_live_undef_seq`, `entry_trace.c:5584`) - the DIRECT, cap-exempt channel when
    `STAGE90_XNU_UNDEF_DIRECT=1`, the capped channel otherwise (`ENTRY_LIVE_CAP 24576u`,
    `entry_stubs.c:4254`); (ii) the row's OWN printf `IOS7LAB vm_map64 ...` (`mach_kernelrpc.c:238`),
    a plain kernel `printf`, unbounded.  **If NEITHER appears anywhere, the run is
    INSTRUMENT_UNSOUND and nothing below is a reading** - the 1018 lesson
    (`records/1018-recon.txt`), which is why this reader withholds rather than concluding.
  * **THE ROW'S OWN PRINT IS THE ONLY UN-INFERRED PROOF THE ROW RAN.**  `records/1022-trap15-
    adjudication.txt` §4.2 measured the 1020b capture: ZERO `IOS7LAB vm_*64` lines against 11
    `IOS7LAB cache/commpage/vecl2` boot lines, even though the three sibling lab traps are compiled
    and linked.  An `IOS7LAB vm_map64` line is therefore a FIRST execution of a first-run instruction
    stream, and its presence is unambiguous.
  * **THE FRAME DUMP HAS TWO POSSIBLE SPELLINGS, AND BOTH ARE ACCEPTED - SAYING WHICH WAS FOUND.**
    §6.2 of the design proposed a KV key on the **udf frame** (`xnu_live_undef_frame0`, the word at
    the top of the trapping thread's saved `sp`); the build agent instead added a **printf on the
    row's own wire frame** at the adapter's prologue.  Both are read, the producer is named in every
    message, and - because they are DIFFERENT MEASUREMENTS (below) - they are never silently averaged.
      - MEASURED IN THE TREE: `tools/patch_d13_mach_trap15.py:140` carries, verbatim,
        `IOS7LAB trap15 frame r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r6=%08x r8=%08x`
        (guarded by its own `frame_logged < 12` counter), positioned AFTER the selector early-out -
        so it prints ONLY when the selector answered 1.
      - NOT IN THE TREE YET: `xnu_live_undef_frame0` appears only in the design doc.  Accepted
        anyway (an adapter may add it), and the message says which producer carried the value.
  * **⚠ THE TWO FRAME PRODUCERS DO NOT MEASURE THE SAME WORD, AND THE CELLS SAY SO.**  The design's
    `xnu_live_undef_frame0` reads the UDF's saved frame - the word at the top of the saved `sp`,
    which the shim's fast leg sets to the userspace address pointer (`str.w sl,[sp,#40]`) and whose
    SLOW leg overwrites with the guard's third field (the value **7**).  The printf's `r0` is the
    adapter's `regs[0]` = the WIRE's slot 0, which `records/1022-trap15-wire.txt` §4 measures as the
    **task port name**, NOT the shim's frame word.  So a `7` in the printf's `r0` is a WIRE fact and
    a `7` in `xnu_live_undef_frame0` is the GUARD'S LEG.  This reader applies the SLOW/FAST test it
    was told to apply and prints this caveat verbatim whenever the printf producer is the only one.
  * **A CELL IS A PREDICATE OVER THE CAPTURE, NEVER A REMEMBERED NUMBER.**  Every value the cells use
    is read from the capture under test (the slide from its own `map_slide` line; the results and
    addresses from the row's own printf).  Where a value is ABSENT the reader says "absent" and
    refuses to conclude from it - `[[mi4-silence-is-a-reading-only-if-success-is-silent]]`.
  * **A CAPTURE IS NEVER ITS OWN BASELINE.**  The `--baseline` section refuses that identity
    explicitly: a comparison a file makes with itself cannot fail
    (`[[mi4-a-claim-in-a-comment-is-not-a-check]]`).
  * **`G-CTL` AND `T15-SENTINEL` ARE KEYED ON THE ABSENCE OF *BOTH* NEW WITNESSES.**  This is the
    design's own reading, and it is stated so it is not softened: the selector's early return
    (`mach_kernelrpc.c:217`) sits BEFORE both the frame dump and the `done:` printf, so on a
    selector-0 run the capture carries NO new evidence at all - in the new witnesses it is
    byte-identical to a run where the row was never installed.  **The capture cannot separate those
    two cases, and this reader says so in the cell's own text**; the BY-VALUE build clause (design
    §3, `nm` on the two pool objects + `mach_trap_table[15].fn`) is what separates them.
    ⚠ `docs/1022-mach-trap-15-design.md` §0.2 is self-contradictory about the sentinel's
    consequence (it says both that the adapter returns the sentinel AND that the shim treats a
    non-sentinel as "the fast trap ran") - so this reader does NOT derive the sentinel's observable
    from that prose; it keys on the witness absence plus a stop, and names the dispute.

------------------------------------------------------------------------------
THE CELLS (most-severe first), AND THE ORDER THEY ARE EVALUATED IN
------------------------------------------------------------------------------
    G-CTL            neither `xnu_live_undef_seq` NOR any `IOS7LAB vm_map64` line anywhere
                     => WITHHOLD (INSTRUMENT_UNSOUND), naming which witness is missing
    T15-PANICS       panic evidence (a `swi_mach_error`-shaped string, a non-zero
                     `xnu_entry_panic_entered`/`_str`, or a `p` epilogue reason)
                     => STALE POOL - NOT A BEHAVIOUR READING
    T15-REFUSED      a `vm_map64 ... result=4` (KERN_INVALID_ARGUMENT), no panic
                     => ROW USED; THE WIRE IS REFUSED  (the offending frame words are printed)
    T15-FIRES        a `vm_map64 ... result=0` with a NONZERO `address`, AND the boot moved past the
                     wall => ROW INSTALLED, USED, SUCCESSFUL - THE WALL MOVED
    T15-UNEXERCISED  no row firing, and a frame dump reads the SLOW shape (the word 7)
                     => THE GUARD FAILED - residue (i)
    T15-OTHER-CALL   no row firing, and a frame dump reads the FAST shape (a userspace pointer)
                     => residue (ii)
    T15-SENTINEL     no row firing, no panic, and the run still stops
                     => REGRESSION - ROW INSTALLED, SELECTOR STILL 0
    NO-CELL          none of the above: the keys present and the predicates that failed are named,
                     and NO verdict is fabricated.

The brief lists `T15-FIRES`/`T15-REFUSED` before `T15-PANICS`, but it also writes "no panic" INTO
both, so a panic must be tested first or the later cell would be unreachable - a pre-registered cell
nothing can reach is a dead cell (`[[mi4-measurement-defects]]`).  The panic test is therefore moved
up, and this deviation is stated here rather than hidden.

MECHANICAL ONLY.  This reader does NOT claim iOS 7 userspace launched, it does NOT read the build's
own by-value cell (`tools/check_1022_trap15.py`, design §3 - a property of the objects, not of a
capture), and when the frame dump is absent it does NOT decide which residue, (i) or (ii), obtains.
------------------------------------------------------------------------------
"""

import argparse
import contextlib
import importlib.util
import io
import os
import re
import sys

# The capture parser is REUSED BY IDENTITY, not cloned ([[mi4-one-value-two-definitions]]: two copies
# of one definition can drift).  Its filename is not a legal identifier, so it is imported by path;
# its `if __name__ == "__main__"` guard means importing it does not run its reader.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("check_1015_capture",
                                              os.path.join(_HERE, "check_1015_capture.py"))
C15 = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(C15)

# ---------------------------------------------------------------------------------------------------
# THE WALL'S IDENTITY.  These are LIBRARY FILE OFFSETS (slide-invariant) - NOT linked VAs: pid 1's
# `udf` is in the dyld shared cache and its runtime pc moves with the slide EVERY RUN.
# ---------------------------------------------------------------------------------------------------
REF_WALL_OFFSET = 0x3823AA54        # __os_alloc_slow+0x108, libsystem_platform.dylib (the `udf #254`)
REF_WALL_NAME = "__os_alloc_slow+0x108"
# The two records' numbers, cited so the arithmetic is checkable and DELIBERATELY NOT USED as a
# comparison key (the slide differs per run; `records/1021d-press-read.txt` Part 2).
REF_1021D_PC = 0x39E38A54
REF_1021D_SLIDE = 0x001BFE000
REF_1020B_PC = 0x39605A54
REF_1020B_SLIDE = 0x0013CB000

# The slide is published by the shreg wire on a line of this shape (measured on the 1021d capture,
# line 4104): `IOS7SHREG map_slide pid=1 fd=0 count=4 mappings=0x2bdd2848 slide=0x1bfe000 ...`.
MAP_SLIDE_MARK = "map_slide"
MAP_SLIDE_RE = re.compile(r"\bmap_slide\b.*?\bpid=(\d+)\b.*?\bslide=(0x[0-9A-Fa-f]+)\b")

# ---- the live undef witness (`entry_trace.c:5578-5605`, `__wrap_sleh_undef`) ----------------------
UNDEF_SEQ_KEY = "xnu_live_undef_seq"
UNDEF_USER_SEQ_KEY = "xnu_live_undef_user_seq"
UNDEF_PC_KEY = "xnu_live_undef_pc"
UNDEF_LR_KEY = "xnu_live_undef_lr"
UNDEF_SPSR_KEY = "xnu_live_undef_spsr"
UNDEF_USER_KEY = "xnu_live_undef_user"

# The handler's own kernel printf (`osfmk/arm/trap.c`) - raw console text, cap-exempt, and the
# POSITIVE signal that the raise path was taken (the 1021d record's anchor: x233).
PRINTF_MARK = "usermode undefined instruction"
PRINTF_PC_RE = re.compile(r"EXC_BAD_INSTRUCTION at (0x[0-9A-Fa-f]+)")

# ---- the row's own two prints --------------------------------------------------------------------
VM_MAP_MARK = "IOS7LAB vm_map64"
# VERBATIM, `mach_kernelrpc.c:238`: `size=%08x:%08x mask=%08x:%08x flags=%x prot=%x result=%d
# address=%08x` with args `regs[3], regs[2], regs[5], regs[4], regs[6], regs[8], rv, address32`.
VM_MAP_RE = re.compile(
    r"IOS7LAB vm_map64 size=([0-9A-Fa-f]+):([0-9A-Fa-f]+) mask=([0-9A-Fa-f]+):([0-9A-Fa-f]+)"
    r" flags=([0-9A-Fa-f]+) prot=([0-9A-Fa-f]+) result=(-?\d+) address=([0-9A-Fa-f]+)")
# The frame dump's TWO accepted spellings.  The printf one is IN THE TREE (measured:
# `tools/patch_d13_mach_trap15.py:140`); the KV one is the design §6.2 proposal and is NOT.
FRAME_PRINTF_MARK = "IOS7LAB trap15 frame"
FRAME_PRINTF_R0_RE = re.compile(r"IOS7LAB trap15 frame r0=([0-9A-Fa-f]{8})\b")
FRAME_KV_KEYS = ("xnu_live_undef_frame0", "xnu_live_undef_r0")

KERN_INVALID_ARGUMENT = 4           # `osfmk/mach/kern_return.h`
# The SLOW/FAST shapes the design §6.2 names, by value: the shim's slow leg overwrites the frame's
# top word with the guard's third field (the word `7`), the fast leg leaves a userspace pointer.
SLOW_WORD = 7
USER_PTR_LO = 0x00001000            # below this is not a userspace page address
# VM_MAX_ADDRESS of the kernel that produced THIS capture: the 1022 run was built with
# STAGE90_XNU_VM_MAX_SPLIT=0, so vm_param.h:63 compiles the tree's `#else` (0x80000000).  Rung 1024
# adds the switch that drops it to 0x40000000 on CANCRO; THIS checker reads a historical artifact and
# must keep its own kernel's value - a capture reader is bound to the build that made it, not to the
# current tree.  (The 1024 reader carries the tri-class: [0x40000000, 0x80000000) is its own
# ABOVE-SPLIT shape, never "fast".)
USER_PTR_HI = 0x80000000

# ---- panic evidence ------------------------------------------------------------------------------
PANIC_ENTERED_KEY = "xnu_entry_panic_entered"
PANIC_STR_KEY = "xnu_entry_panic_str"
WHY_KEY = "xnu_entry_why"
WHY_BYTE_KEY = "xnu_entry_why_byte"
TRAP_RECORD_MARK = "trap record:"
ENTRY_UNDEF_PC_KEY = "xnu_entry_undef_pc"
# The design §7's named walk.  ⚠ This literal is 1020b-era: 1021d's own self-test carries it as its
# NORMAL exception why, so it is REPORTED as a corroborator and never used alone.
REF_WHY_WALK = 0x804A851C
# `entry_stubs.c:10421`: `entry_epilogue("panic() - XNU rejected something; ...")`.
PANIC_BYTE = 0x70                   # 'p'
# `traps_lo.s:665`'s `vecPanicString`, reached by `irqvec_panic` - and `swi_mach_error`
# (`traps_lo.s:261`) is one of its seven callers, with `r0 = 0x81`.  This is the literal
# "swi_mach_error-shaped panic string" the design's cell names.
VEC_PANIC_MARK = "fleh_vectors: exception in exception vectors"
VEC_PANIC_CODE_RE = re.compile(r"exception in exception vectors,\s*0x([0-9A-Fa-f]+)")
SWI_MACH_ERROR_CODE = 0x81
# A generic panic, keyed to the console text and NOT to this image's own `xnu_entry_panic_*` slots
# (`[[mi4-one-value-two-definitions]]`: `\bpanic\b[:(]` cannot match `xnu_entry_panic_str=`).
PANIC_TEXT_RE = re.compile(r"\bpanic\b[:(]")

# The sampled usvc witness - REPORTED, never gated (its window is exhausted at `n = 0x40`,
# `entry_stubs.c:7313`, so its silence after that point is the instrument; design §9.5).
USVC_NUM_KEY = "xnu_live_usvc_num"
SVC_MINUS_15 = 0xFFFFFFF1

# Residency.
WDT_PETS_KEY = "xnu_live_wdt_pets"
MEMSIZE_KEY = "xnu_entry_args_memSize"

# The 1021d recovery, used as the `--baseline` DEFAULT.  It is a default, not an assumption: when it
# is absent the section is skipped cleanly (and no cell depends on it).
DEFAULT_BASELINE = os.path.join(os.path.dirname(_HERE), "out", "stage90", "captures",
                                "recovered-unknown-arm-20261016-042713-last_kmsg.txt")

# The cells, in the brief's order.  `NO-CELL` is the else-arm and is NOT a verdict.
CELLS = ("G-CTL", "T15-FIRES", "T15-REFUSED", "T15-SENTINEL", "T15-PANICS", "T15-UNEXERCISED",
         "T15-OTHER-CALL", "NO-CELL")

DISPLAY = {
    "G-CTL": "WITHHOLD (INSTRUMENT_UNSOUND)",
    "T15-FIRES": "T15-FIRES (ROW INSTALLED, USED, SUCCESSFUL - THE WALL MOVED)",
    "T15-REFUSED": "T15-REFUSED (ROW USED; THE WIRE IS REFUSED)",
    "T15-SENTINEL": "T15-SENTINEL (REGRESSION - ROW INSTALLED, SELECTOR STILL 0)",
    "T15-PANICS": "T15-PANICS (STALE POOL - NOT A BEHAVIOUR READING)",
    "T15-UNEXERCISED": "T15-UNEXERCISED (THE GUARD FAILED - residue (i))",
    "T15-OTHER-CALL": "T15-OTHER-CALL (residue (ii))",
    "NO-CELL": "NO-CELL (no pre-registered cell fires - nothing is concluded)",
}


def say(tag, msg=""):
    print("[1022] %-9s %s" % (tag, msg))


def verdict(cell, msg):
    print("[1022] %-16s %s" % (cell, msg))
    return cell


# ---------------------------------------------------------------------------------------------------
# THE RAW-TEXT READER.  `C15.Capture`'s KV regex is `xnu_live_[a-z0-9_]+` by construction, so EVERY
# `xnu_entry_*` key is invisible to `cap.toks`.  A check that looked for them there would be blind
# and would ALWAYS withhold - the defect `check_1020_capture.py` documents for its boot self-test row
# ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).  So they are read off the raw lines.
# ---------------------------------------------------------------------------------------------------
def raw_kv(cap, key):
    """Every occurrence of `key=value` in the raw text, in log order: [(line_no, int_or_None, raw)]."""
    out = []
    pat = re.compile(re.escape(key) + r"=([0-9A-Za-z_.+-]+)")
    for i, line in enumerate(cap.lines, 1):
        for m in pat.finditer(line):
            out.append((i, C15.to_int(m.group(1)), m.group(1)))
    return out


def raw_last(cap, key):
    rows = raw_kv(cap, key)
    return rows[-1] if rows else None


def raw_lines_with(cap, mark):
    return [i for i, line in enumerate(cap.lines, 1) if mark in line]


def max_key(cap, key):
    vals = [t[3] for t in cap.all(key) if t[3] is not None]
    return max(vals) if vals else None


# ---------------------------------------------------------------------------------------------------
# THE READINGS
# ---------------------------------------------------------------------------------------------------
def slide_of(cap, pid=1):
    """`(slide, line_no)` from the capture's OWN `map_slide` line for `pid`; `(None, None)` if absent.

    ⚠ NEVER hard-coded: the slide varies per run, and every wall comparison here is `pc - slide`.
    The LAST matching line wins (a wire that publishes per-fd rows must have its final word read)."""
    hit = (None, None)
    for i, line in enumerate(cap.lines, 1):
        if MAP_SLIDE_MARK not in line:
            continue
        m = MAP_SLIDE_RE.search(line)
        if m is not None and C15.to_int(m.group(1)) == pid:
            hit = (C15.to_int(m.group(2)), i)
    return hit


def undef_rows(cap):
    """One dict per live undef entry, bound to `__wrap_sleh_undef`'s ONE write order.

    `_seq` OPENS a row; `_user_seq`, then (within `UNDEF_LIVE_MAX` only) `_pc`/`_lr`/`_spsr`/`_user`
    follow it.  A `_seq` with no `_pc` is a REAL reading - an entry PAST `UNDEF_LIVE_MAX`, where only
    the count advances - and that is exactly the reading a late-wall run depends on."""
    rows, cur = [], None
    field = {UNDEF_PC_KEY: "pc", UNDEF_LR_KEY: "lr", UNDEF_SPSR_KEY: "spsr", UNDEF_USER_KEY: "user"}
    for line_no, key, _raw, val in cap.toks:
        if key == UNDEF_SEQ_KEY:
            cur = {"line": line_no, "seq": val, "pc": None, "lr": None, "spsr": None, "user": None}
            rows.append(cur)
        elif cur is not None and key in field:
            cur[field[key]] = val
    return rows


def printf_events(cap):
    """`[(line_no, pc_or_None)]` for every `usermode undefined instruction` kernel printf."""
    out = []
    for i, line in enumerate(cap.lines, 1):
        if PRINTF_MARK in line:
            m = PRINTF_PC_RE.search(line)
            out.append((i, C15.to_int(m.group(1)) if m else None))
    return out


def vm_map_lines(cap):
    """`(rows, malformed)`: the row's own printf, parsed.

    `malformed` are `(line, text)` for lines carrying the MARK that the field regex could NOT parse.
    The distinction matters at `G-CTL`, which counts the MARK (a line the reader cannot parse is
    still evidence the row RAN) and must never turn an unparsed firing into an absent one."""
    rows, malformed = [], []
    for i, line in enumerate(cap.lines, 1):
        if VM_MAP_MARK not in line:
            continue
        m = VM_MAP_RE.search(line)
        if m is None:
            malformed.append((i, line.strip()[:200]))
            continue
        rows.append({"line": i,
                     "size_hi": C15.to_int("0x" + m.group(1)),
                     "size_lo": C15.to_int("0x" + m.group(2)),
                     "mask_hi": C15.to_int("0x" + m.group(3)),
                     "mask_lo": C15.to_int("0x" + m.group(4)),
                     "flags": C15.to_int("0x" + m.group(5)),
                     "prot": C15.to_int("0x" + m.group(6)),
                     "result": int(m.group(7), 10),
                     "address": C15.to_int("0x" + m.group(8)),
                     "raw": line.strip()[:200]})
    return rows, malformed


def frame_events(cap):
    """`[(line_no, producer, value_or_None, raw)]` for BOTH accepted frame-dump spellings.

    The printf spelling is the one the build agent wrote (`IOS7LAB trap15 frame r0=...`); the KV
    spelling is the design §6.2 proposal.  The producer is carried so every message names WHICH
    measurement it is - the two do NOT measure the same word (see the module docstring)."""
    out = []
    for i, line in enumerate(cap.lines, 1):
        if FRAME_PRINTF_MARK in line:
            m = FRAME_PRINTF_R0_RE.search(line)
            # ⚠ `to_int` needs the prefix: the printf writes `%08x`, and a bare `2bdd2848` would be
            # read as DECIMAL and fail to `None` - turning a FAST frame into an absent one.
            out.append((i, "printf", C15.to_int("0x" + m.group(1)) if m else None,
                        line.strip()[:200]))
    for key in FRAME_KV_KEYS:
        for ln, val, raw in raw_kv(cap, key):
            out.append((ln, "kv:" + key, val, key + "=" + raw))
    out.sort(key=lambda t: t[0])
    return out


def panic_reading(cap):
    """The panic evidence, by value.  `evidence` is the boolean the cells key on."""
    d = {}
    pe = raw_last(cap, PANIC_ENTERED_KEY)
    d["panic_entered"], d["panic_entered_line"] = (pe[1] if pe else None), (pe[0] if pe else None)
    ps = raw_last(cap, PANIC_STR_KEY)
    d["panic_str"], d["panic_str_line"] = (ps[1] if ps else None), (ps[0] if ps else None)
    wh = raw_last(cap, WHY_KEY)
    d["why"], d["why_line"] = (wh[1] if wh else None), (wh[0] if wh else None)
    wb = raw_last(cap, WHY_BYTE_KEY)
    d["why_byte"], d["why_byte_line"] = (wb[1] if wb else None), (wb[0] if wb else None)
    d["why_is_named_walk"] = (d["why"] == REF_WHY_WALK)
    d["record_lines"] = raw_lines_with(cap, TRAP_RECORD_MARK)
    d["record"] = bool(d["record_lines"])
    ep = raw_last(cap, ENTRY_UNDEF_PC_KEY)
    d["entry_undef_pc"] = ep[1] if ep else None
    d["vec_panic"] = [(i, line.strip()[:200]) for i, line in enumerate(cap.lines, 1)
                      if VEC_PANIC_MARK in line]
    d["panic_text"] = [(i, line.strip()[:200]) for i, line in enumerate(cap.lines, 1)
                       if PANIC_TEXT_RE.search(line)]
    codes = []
    for i, line in enumerate(cap.lines, 1):
        for m in VEC_PANIC_CODE_RE.finditer(line):
            codes.append((i, C15.to_int("0x" + m.group(1))))
    d["vec_codes"] = codes
    d["swi_mach_shaped"] = any(c == SWI_MACH_ERROR_CODE for _i, c in codes)
    # TWO DIFFERENT READINGS, deliberately NOT one.  `evidence` is the design §7 cell EXACTLY as
    # written ("a panic whose string is `swi_mach_error`-shaped, OR the panic walk reached from
    # 0x804a851c with a mach-trap frame"), so it does NOT include "a trap record exists".
    # [[mi4-one-value-two-definitions]]: one key must not carry both meanings.
    d["evidence"] = bool(d["vec_panic"] or d["panic_text"]
                         or d["why_byte"] == PANIC_BYTE or d["why_is_named_walk"])
    # ... and `stopped` is the weaker, AFFIRMATIVE "the run ended in the kernel, not at pid 1's
    # handler printfs".  The trap record is `g_panic_buf`, published only when
    # `g_panic_entered != 0` (`entry_stubs.c:6382`), so its presence is a positive too - it is the
    # SENTINEL cell's evidence and G-CTL's second carve-out, never the PANICS cell's.
    d["stopped"] = bool(d["record"] or d["panic_entered"] not in (0, None)
                        or d["panic_str"] not in (0, None) or d["entry_undef_pc"] is not None)
    return d


def panic_why(d):
    """The listed reasons, for a cell's message."""
    out = []
    if d["vec_panic"]:
        out.append("a vector-panic string at :%d%s" % (
            d["vec_panic"][0][0],
            " reading 0x%02x = swi_mach_error's own code (traps_lo.s:261)" % SWI_MACH_ERROR_CODE
            if d["swi_mach_shaped"] else ""))
    if d["panic_text"]:
        out.append("panic console text at :%d (%r)" % (d["panic_text"][0][0], d["panic_text"][0][1]))
    if d["panic_entered"] not in (0, None):
        out.append("`%s=%s` (:%s)" % (PANIC_ENTERED_KEY, C15.fmt(d["panic_entered"]),
                                      d["panic_entered_line"]))
    if d["why_is_named_walk"]:
        out.append("`%s=%s` (:%s) == the design §7's named walk" % (WHY_KEY, C15.fmt(d["why"]),
                                                                     d["why_line"]))
    if d["why_byte"] == PANIC_BYTE:
        out.append("`%s=0x70` ('p' = \"panic() - XNU rejected something\", entry_stubs.c:10421, "
                   ":%s)" % (WHY_BYTE_KEY, d["why_byte_line"]))
    return "; ".join(out) if out else "(none)"


def usvc_reading(cap):
    """The sampled usvc witness: whether a `-15` was ever sampled, and how many rows were seen.
    REPORTED only - the window is capped at `n = 0x40` (design §9.5)."""
    vals = [t[3] for t in cap.all(USVC_NUM_KEY) if t[3] is not None]
    return {"rows": len(vals), "minus15": [v for v in vals if v == SVC_MINUS_15]}


def wall_shape(cap, slide, rows):
    """Where the run's user-mode undefs are, RELATIVE TO THE WALL.  Every field is `None` when the
    slide is unknown - never guessed from a raw pc (`[[mi4-measurement-defects]]`)."""
    wall_pc = (REF_WALL_OFFSET + slide) if slide is not None else None
    ev = printf_events(cap)
    user_rows = [r for r in rows if r["pc"] is not None and r["user"] == 1]
    kern_rows = [r for r in rows if r["pc"] is not None and r["user"] != 1]
    wall_rows = [r for r in user_rows if wall_pc is not None and r["pc"] == wall_pc]
    wall_printf = [(i, p) for i, p in ev if wall_pc is not None and p == wall_pc]
    nonwall_printf = [(i, p) for i, p in ev if wall_pc is None or p != wall_pc]
    other_user = sorted({r["pc"] for r in user_rows if wall_pc is None or r["pc"] != wall_pc}
                        | {p for _i, p in nonwall_printf if p is not None})
    other_lines = sorted([r["line"] for r in user_rows if wall_pc is None or r["pc"] != wall_pc]
                         + [i for i, _p in nonwall_printf])
    wall_lines = [r["line"] for r in wall_rows] + [i for i, _p in wall_printf]
    if slide is None:
        present = None                      # unreadable: the wall's pc cannot be computed
    else:
        present = bool(wall_rows or wall_printf)
    return {"wall_pc": wall_pc, "present": present, "wall_rows": wall_rows,
            "wall_printf": wall_printf, "wall_last": (max(wall_lines) if wall_lines else None),
            "other_user": other_user, "other_lines": other_lines,
            "kernel_pcs": sorted({r["pc"] for r in kern_rows}),
            "pcs_seen": sorted({r["pc"] for r in rows if r["pc"] is not None}),
            "printf_pcs": sorted({p for _i, p in ev if p is not None}),
            "printf_count": len(ev)}


def frontier_moved(wall, vm_rows):
    """THE PROGRESS TEST - did the run get PAST the wall?

    Two ways, both by value; the second is the one the brief names ("the udf `_seq` is present but
    the boot visibly proceeds past it"):

      * the wall undef is ABSENT (`wall["present"] is False`) - the absence reading, taken only when
        the slide was readable;
      * the wall undef is PRESENT **and** a SUCCESSFUL row firing (`result=0`, nonzero address)
        appears AFTER the last wall event - progress measured by a POSITIVE, not by a silence.

    Returns `(moved_or_None, why)`.  `None` means UNREADABLE and `T15-FIRES` will not be concluded
    from it (the 1018 lesson: an absence read off an exhausted channel is the instrument)."""
    ok = [r for r in vm_rows if r["result"] == 0 and r["address"]]
    if wall["present"] is False:
        return True, ("the wall undef is ABSENT (its pc %s never appears among %d live row(s) and %d "
                      "handler printf(s))" % (C15.fmt(wall["wall_pc"]), len(wall["wall_rows"]),
                                              len(wall["wall_printf"])))
    if wall["present"] is True:
        later = [r for r in ok if wall["wall_last"] is not None and r["line"] > wall["wall_last"]]
        if later:
            return True, ("the wall undef IS present (last at :%d) and a SUCCESSFUL row firing "
                          "follows it at :%d - the boot proceeded PAST the wall"
                          % (wall["wall_last"], later[0]["line"]))
        return False, ("the wall undef is present (last at :%s) and NO successful row firing follows "
                       "it" % wall["wall_last"])
    if not wall["printf_pcs"] and not wall["pcs_seen"]:
        return True, ("no user-mode undef ANYWHERE and the capture published no slide - the wall's "
                      "absence is read in its WEAKEST form (no undef at all), NOT as a "
                      "slide-corrected comparison")
    return None, ("the capture published NO `%s` line for pid 1, so the wall's pc cannot be computed "
                  "and the absence of a user undef at it is UNREADABLE ([[mi4-measurement-defects]]: "
                  "the tool's own comparison must not be the artifact)" % MAP_SLIDE_MARK)


def baseline_section(cap, base, base_path, slide, rows):
    """The `--baseline` side-by-side: does the BASELINE's udf pc still appear, and at what count.

    ⚠ THE RAW PC IS NOT COMPARABLE ACROSS RUNS.  The live undef pc is POST-slide and the slide varies
    per run, so raw-pc equality is a coincidence test.  The invariant is the FILE OFFSET
    (`pc - slide`); BOTH are printed so the coincidence is visible rather than hidden."""
    if base is None:
        say("BASE", "no baseline - the side-by-side is SKIPPED (no cell depends on it)")
        return None
    cpself = os.path.realpath(getattr(cap, "path", "") or "")
    bpath = os.path.realpath(base_path or "")
    if cpself and cpself == bpath:
        say("BASE", "REFUSING the baseline: it IS this capture (a comparison a file makes with "
                    "itself cannot fail - [[mi4-a-claim-in-a-comment-is-not-a-check]])")
        return None
    bslide, bline = slide_of(base)
    brows = undef_rows(base)
    bev = printf_events(base)
    bset = sorted({r["pc"] for r in brows if r["pc"] is not None}
                  | {p for _i, p in bev if p is not None})
    name = os.path.basename(base_path or "(given)")
    say("BASE", "%s: slide=%s (:%s); its undef pc(s): %s"
        % (name, C15.fmt(bslide), bline,
           ("{%s}" % ", ".join(C15.fmt(p) for p in bset)) if bset else "(none published)"))
    if bset and bslide is not None:
        ex = [p - bslide for p in bset]
        say("BASE", "its FILE OFFSET(s): %s%s"
            % (", ".join(C15.fmt(o) for o in ex),
               "  <- == %s == the wall" % C15.fmt(REF_WALL_OFFSET)
               if REF_WALL_OFFSET in ex else "  <- NOT the wall %s" % C15.fmt(REF_WALL_OFFSET)))
    ours_pcs = [r["pc"] for r in rows if r["pc"] is not None]
    out = {"base_pcs": bset, "base_slide": bslide, "base_name": name}
    for p in bset:
        say("BASE", "  raw pc %s in THIS capture: x%d row(s)"
            % (C15.fmt(p), sum(1 for q in ours_pcs if q == p)))
    if bslide is not None and slide is not None:
        boffs = {p - bslide for p in bset}
        n_off = sum(1 for q in ours_pcs if (q - slide) in boffs)
        out["same_offset_rows"] = n_off
        say("BASE", "  the SAME FILE OFFSET(s) in THIS capture: x%d row(s)%s"
            % (n_off, (" (the pcs are post-slide; raw equality would be a coincidence test, the "
                       "slide differs: %s vs %s)" % (C15.fmt(bslide), C15.fmt(slide)))
               if bslide != slide else " (same slide this run)"))
    else:
        say("BASE", "  FILE-OFFSET comparison NOT available - one of the two slides is unreadable")
    return out


def frame_shape(value):
    """`"slow"` / `"fast"` / `None` for one frame-dump value, by the design §6.2 predicate."""
    if value is None:
        return None
    if value == SLOW_WORD:
        return "slow"
    if USER_PTR_LO <= value < USER_PTR_HI:
        return "fast"
    return None


# ---------------------------------------------------------------------------------------------------
# THE ADJUDICATION - the brief's cells, in an order the observations force (panic moved up).
# ---------------------------------------------------------------------------------------------------
def adjudicate(cap, baseline=None, baseline_path=None):
    slide, slide_line = slide_of(cap)
    rows = undef_rows(cap)
    vm_rows, vm_bad = vm_map_lines(cap)
    frames = frame_events(cap)
    pan = panic_reading(cap)
    wall = wall_shape(cap, slide, rows)
    usvc = usvc_reading(cap)
    moved, moved_why = frontier_moved(wall, vm_rows)
    vm_mark_lines = raw_lines_with(cap, VM_MAP_MARK)
    seqs = [r["seq"] for r in rows if r["seq"] is not None]
    max_seq = max(seqs) if seqs else 0
    vals = [(ln, prod, v) for ln, prod, v, _r in frames if v is not None]
    shapes = [(ln, prod, v, frame_shape(v)) for ln, prod, v in vals]
    slow = [s for s in shapes if s[3] == "slow"]
    fast = [s for s in shapes if s[3] == "fast"]

    say("CAPTURE", "%d bytes, %d lines, %d live tokens" % (cap.nbytes, len(cap.lines), len(cap.toks)))
    # The baseline side-by-side is REPORT-ONLY (no cell reads it), and it lives here so the
    # self-test exercises the self-baseline REFUSAL through the same path an operator uses.
    baseline_section(cap, baseline, baseline_path, slide, rows)
    if not vm_mark_lines and not rows:
        say("CTL", "NEITHER witness is armed: `%s` x0 AND `%s` x0" % (UNDEF_SEQ_KEY, VM_MAP_MARK))

    # ---- SLIDE and THE WALL --------------------------------------------------------------------
    if slide is None:
        say("SLIDE", "NO `%s` line for pid 1 - the wall's pc CANNOT be computed from this capture "
                     "(it is never hard-coded: the slide varies per run)" % MAP_SLIDE_MARK)
    else:
        say("SLIDE", "`%s` pid=1 at :%d reads slide=%s => this run's wall pc = %s (%s)"
            % (MAP_SLIDE_MARK, slide_line, C15.fmt(slide),
               C15.fmt(REF_WALL_OFFSET + slide), REF_WALL_NAME))
        say("SLIDE", "cross-check vs the two records: 1021d %s - %s = %s ; 1020b %s - %s = %s"
            % (C15.fmt(REF_1021D_PC), C15.fmt(REF_1021D_SLIDE),
               C15.fmt(REF_1021D_PC - REF_1021D_SLIDE), C15.fmt(REF_1020B_PC),
               C15.fmt(REF_1020B_SLIDE), C15.fmt(REF_1020B_PC - REF_1020B_SLIDE)))
    if slide is not None:
        say("WALL", "%s - %d live row(s) at %s, %d handler printf(s) at it (last :%s); OTHER user "
                    "undef pcs: %s; KERNEL-mode undef pcs: %s"
            % ("PRESENT" if wall["present"] else "ABSENT", len(wall["wall_rows"]),
               C15.fmt(wall["wall_pc"]), len(wall["wall_printf"]), wall["wall_last"],
               ("{%s}" % ", ".join(C15.fmt(p) for p in wall["other_user"]))
               if wall["other_user"] else "(none)",
               ("{%s}" % ", ".join(C15.fmt(p) for p in wall["kernel_pcs"]))
               if wall["kernel_pcs"] else "(none)"))
    say("WALL", "PROGRESS test: %s - %s"
        % ("MOVED" if moved else ("NOT MOVED" if moved is False else "UNREADABLE"), moved_why))

    # ---- THE TWO WITNESSES ---------------------------------------------------------------------
    say("LIVE", "witness (i) `%s`: x%d row(s), max `_seq`=%d, `%s` printf x%d; witness (ii) `%s`: "
                "x%d line(s) (last at :%s), of which the field regex parsed x%d"
        % (UNDEF_SEQ_KEY, len(rows), max_seq, PRINTF_MARK, wall["printf_count"], VM_MAP_MARK,
           len(vm_mark_lines), vm_mark_lines[-1] if vm_mark_lines else "n/a", len(vm_rows)))
    for i, txt in vm_bad[:4]:
        say("LIVE", "  ⚠ UNPARSED `%s` line at :%d - the row RAN but this reader cannot read its "
                    "fields: %s" % (VM_MAP_MARK, i, txt))
    if vm_rows:
        results = {}
        for r in vm_rows:
            results[r["result"]] = results.get(r["result"], 0) + 1
        say("LIVE", "the row's own results: %s"
            % ", ".join("result=%d x%d" % (k, v) for k, v in sorted(results.items())))
    say("LIVE", "`%s` max=%s; `%s`=%s; usvc sampled rows x%d%s"
        % (WDT_PETS_KEY, C15.fmt(max_key(cap, WDT_PETS_KEY)), MEMSIZE_KEY,
           (raw_last(cap, MEMSIZE_KEY)[2] if raw_last(cap, MEMSIZE_KEY) else "absent"),
           usvc["rows"],
           (" - a `-15` WAS sampled x%d (!)" % len(usvc["minus15"])) if usvc["minus15"]
           else " - no `-15` sampled (REPORTED, never gated: the window is capped at n=0x40)"))

    # ---- THE FRAME DUMP(S) ---------------------------------------------------------------------
    if not frames:
        say("FRAME", "NO frame dump in either accepted spelling (`%s` printf, or a KV %s) - the "
                     "SLOW/FAST cells cannot be decided from this capture"
            % (FRAME_PRINTF_MARK, " / ".join(FRAME_KV_KEYS)))
    else:
        say("FRAME", "x%d dump line(s); values: %s"
            % (len(frames), ", ".join("%s@:%d=%s" % (prod, ln, C15.fmt(v))
                                      for ln, prod, v in vals) or "(none carrying a value)"))
        prodset = {p for _l, p, _v, _r in frames}
        if prodset == {"printf"}:
            say("FRAME", "⚠ CAVEAT, by value: only the PRINTF producer is present, and its `r0` is "
                         "the adapter's `regs[0]` = the WIRE's slot 0 - measured as the TASK PORT "
                         "name (records/1022-trap15-wire.txt §4), NOT the shim frame word the design "
                         "§6.2 reads.  The SLOW/FAST cells below are applied as specified; read the "
                         "result with that substitution in mind.")
        for ln, prod, v, sh in shapes:
            say("FRAME", "  :%d %s = %s => %s shape"
                % (ln, prod, C15.fmt(v), sh if sh else "NEITHER (not 7, not a userspace pointer)"))

    # ---- PANIC ---------------------------------------------------------------------------------
    if pan["evidence"]:
        say("PANIC", "evidence: %s" % panic_why(pan))
        if pan["why_is_named_walk"]:
            say("PANIC", "⚠ the `%s` literal 0x804a851c is 1020b-era and 1021d's own self-test also "
                         "carries it as a NORMAL exception why, so on its own it is weak - it is "
                         "read here because the design §7's cell names it explicitly."
                % WHY_KEY)
    elif pan["stopped"]:
        say("PANIC", "NO design §7 panic evidence, but the run STOPPED IN THE KERNEL: `%s`=%s, `%s`="
                     "`%s`, trap record x%d, `%s`=%s"
            % (PANIC_ENTERED_KEY, C15.fmt(pan["panic_entered"]), WHY_BYTE_KEY,
               C15.fmt(pan["why_byte"]), len(pan["record_lines"]), ENTRY_UNDEF_PC_KEY,
               C15.fmt(pan["entry_undef_pc"])))
    else:
        say("PANIC", "no panic evidence and no kernel stop: `%s`=%s, `%s`=%s, `%s`=%s, vector-panic "
                     "x%d, panic text x%d" % (PANIC_ENTERED_KEY, C15.fmt(pan["panic_entered"]),
                                              PANIC_STR_KEY, C15.fmt(pan["panic_str"]), WHY_BYTE_KEY,
                                              C15.fmt(pan["why_byte"]), len(pan["vec_panic"]),
                                              len(pan["panic_text"])))

    # ---- the keys every NO-CELL message names --------------------------------------------------
    present_keys = []
    if rows:
        present_keys.append("`%s` x%d" % (UNDEF_SEQ_KEY, len(rows)))
    if wall["printf_count"]:
        present_keys.append("`%s` x%d" % (PRINTF_MARK, wall["printf_count"]))
    if vm_mark_lines:
        present_keys.append("`%s` x%d" % (VM_MAP_MARK, len(vm_mark_lines)))
    if frames:
        present_keys.append("a frame dump x%d" % len(frames))
    if slide is not None:
        present_keys.append("`%s` pid=1" % MAP_SLIDE_MARK)
    present_txt = ", ".join(present_keys) if present_keys else "(none)"

    # =============================================================================================
    # 1. G-CTL - THE CONTROL, AND THE MANDATORY-FIRST CELL.
    # =============================================================================================
    if not rows and not vm_mark_lines:
        # ---- THE TWO CARVE-OUTS, AND WHY THEY ARE NOT A SOFTENING OF THE CONTROL. ----
        # The control exists so that an ABSENCE - of the wall, of a row firing - is never read as
        # evidence when the channel that would have carried it was dead
        # ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).  Two stops do not depend on any
        # absence, so withholding them would make the table's most severe cell unreachable and buy
        # nothing:
        #   (a) A PANIC is a POSITIVE, console-text observation.  It is produced by XNU's own
        #       `printf`, not by this image's witness; a dead witness cannot have caused it.  (It can
        #       also silence witness (i): this image's own `__wrap_sleh_undef` runs only for a user
        #       `udf`, and a kernel-mode `udf`/a `swi_mach_error` panic never reaches it.)
        #   (b) A TRAP RECORD IS PRESENT (`trap record:` / a non-zero `xnu_entry_panic_entered`).
        #       The record is the `g_panic_buf` channel, published only when `g_panic_entered != 0`
        #       (`entry_stubs.c:6382`) - i.e. the run stopped in the kernel, which is the affirmative
        #       "did not pass the wall" the SENTINEL cell needs.  A dead LIVE witness says nothing
        #       about a buffer of a different kind.
        # Both are NAMED in the verdict that consumes them, and each verdict still says the live
        # witness was absent.
        if not pan["evidence"] and not pan["stopped"]:
            missing = []
            if not rows:
                missing.append("witness (i) `%s` (the live undef witness - DIRECT only when "
                               "STAGE90_XNU_UNDEF_DIRECT=1, otherwise it dies at ENTRY_LIVE_CAP "
                               "24576u)" % UNDEF_SEQ_KEY)
            if not vm_mark_lines:
                missing.append("witness (ii) `%s` (the row's own unbounded kernel printf)"
                               % VM_MAP_MARK)
            return verdict("G-CTL", "WITHHOLD (INSTRUMENT_UNSOUND).  MISSING: %s.  With NEITHER "
                                    "witness the instrument was not live, and NOTHING in this "
                                    "capture is a reading - not the wall's absence, not the row's, "
                                    "and not the run's stop.  This is the 1018 defect read forward "
                                    "(records/1018-recon.txt): an ABSENCE is a reading only if the "
                                    "channel that would have carried it was delivering.  Fix the "
                                    "instrument (rebuild with the witness armed) before "
                                    "adjudicating anything." % "; ".join(missing))

    # =============================================================================================
    # 2. T15-PANICS - tested before REFUSED/FIRES because both of those REQUIRE "no panic".
    # =============================================================================================
    if pan["evidence"]:
        swi = ("\n    NOTE: the vector-panic code reads 0x%02x, which is EXACTLY r0 at "
               "`swi_mach_error` (traps_lo.s:261, `mov r0,#0x81; b irqvec_panic`) - the "
               "`swi_mach_error`-shaped panic the design's cell names." % SWI_MACH_ERROR_CODE
               if pan["swi_mach_shaped"] else "")
        return verdict("T15-PANICS", "STALE POOL - NOT A BEHAVIOUR READING.  Panic evidence: %s.%s  "
                                     "Per §7 this means the `-D` did not reach one of the two pool "
                                     "objects (osfmk_kern_syscall_sw.o, "
                                     "osfmk_ipc_mach_kernelrpc.o) or a stale object was linked.  "
                                     "READ `nm` ON THE OBJECTS (design §3.5) AND ON THE LINKED "
                                     "IMAGE, not the env - records/1020-build-defect.txt is the "
                                     "precedent for a record-derived switch quietly dropping.  "
                                     "Nothing about the wire question is learned from this run."
                     % (panic_why(pan), swi))

    # =============================================================================================
    # 3. T15-REFUSED - the row RAN and the adapter's own guard rejected the frame.
    # =============================================================================================
    refused = [r for r in vm_rows if r["result"] == KERN_INVALID_ARGUMENT]
    if refused:
        r = refused[0]
        return verdict("T15-REFUSED", "ROW USED; THE WIRE IS REFUSED.  %d firing(s) read "
                                      "`result=%d` = KERN_INVALID_ARGUMENT, which is the adapter's "
                                      "own `regs[3] || regs[5] || (address64 >> 32)` guard "
                                      "(mach_kernelrpc.c:224) - the row dispatched, the selector "
                                      "answered 1, and the FRAME is what failed.  THE OFFENDING "
                                      "FRAME WORDS (the design's own ask - §7: \"they are the "
                                      "wire's own numbers, and one of them is where §4.1's frame "
                                      "derivation is wrong\"):\n"
                                      "    size_hi:size_lo = %s:%s\n"
                                      "    mask_hi:mask_lo = %s:%s\n"
                                      "    flags=%s prot=%s address=%s result=%d\n"
                                      "    :%d  %s\n"
                                      "  The non-zero word above NAMES the defect: records/"
                                      "1022-trap15-wire.txt §5 predicts `size_hi` (the 8-byte "
                                      "copyin at a 32-bit `regs[1]` swallows slot 2 = size) and §4 "
                                      "predicts `regs[8]`-as-protection.  This is the design's "
                                      "declared falsification-as-stated: RE-DERIVE the frame from "
                                      "these printed words; do NOT re-press the same arm."
                      % (len(refused), KERN_INVALID_ARGUMENT, C15.fmt(r["size_hi"]),
                         C15.fmt(r["size_lo"]), C15.fmt(r["mask_hi"]), C15.fmt(r["mask_lo"]),
                         C15.fmt(r["flags"]), C15.fmt(r["prot"]), C15.fmt(r["address"]),
                         r["result"], r["line"], r["raw"]))

    # =============================================================================================
    # 4. T15-FIRES - a SUCCESSFUL firing AND the boot visibly past the wall.
    # =============================================================================================
    ok = [r for r in vm_rows if r["result"] == 0 and r["address"]]
    if ok and moved is True:
        r = ok[0]
        return verdict("T15-FIRES", "ROW INSTALLED, USED, SUCCESSFUL - THE WALL MOVED.  %d firing(s) "
                                    "read `result=0` with a NONZERO `address` (first at :%d: "
                                    "address=%s), and the PROGRESS test holds: %s.  So the row "
                                    "dispatched (`svc #0x80` r12=-15 -> mach_trap_table[15]), the "
                                    "selector answered 1, the adapter's frame validation PASSED "
                                    "(`regs[3]=%s regs[5]=%s`), `mach_vm_map` returned "
                                    "KERN_SUCCESS, and the allocator's failing call did NOT go on "
                                    "to trap.  The frontier is now DOWNSTREAM: read WHAT the next "
                                    "stop is, in the 1015b/1016a style - and note this reader makes "
                                    "NO claim about it.  Residency for the record: `%s` max=%s, "
                                    "`%s`=%s."
                      % (len(ok), r["line"], C15.fmt(r["address"]), moved_why, C15.fmt(r["size_hi"]),
                         C15.fmt(r["mask_hi"]), WDT_PETS_KEY, C15.fmt(max_key(cap, WDT_PETS_KEY)),
                         MEMSIZE_KEY,
                         (raw_last(cap, MEMSIZE_KEY)[2] if raw_last(cap, MEMSIZE_KEY) else "absent")))

    # =============================================================================================
    # 5. T15-UNEXERCISED / T15-OTHER-CALL - the frame dump, when the row itself did not run.
    # =============================================================================================
    if not vm_rows and not vm_mark_lines and slow:
        ln, prod, v, _sh = slow[0]
        return verdict("T15-UNEXERCISED", "THE GUARD FAILED - residue (i).  The frame dump at :%d "
                                          "(producer %s) reads %s = the SLOW shape (the word `7`, "
                                          "the shim's guard third field written over the frame's "
                                          "top slot on its slow leg; design §6.2).  So the failing "
                                          "call did NOT issue `-15` and the row is INERT for this "
                                          "path: the missing object is on the MIG SLOW leg "
                                          "(`bl 0x381c7f74`), i.e. docs/1019-design.md's "
                                          "`--wrap=mach_vm_map` rung - NOT a further table rung and "
                                          "NOT a wider gate.  This is the design's own falsifier, "
                                          "stated as a predicate; with a green §3 clause it "
                                          "falsifies the design AS CONCEIVED."
                      % (ln, prod, C15.fmt(v)))
    if not vm_rows and not vm_mark_lines and fast:
        ln, prod, v, _sh = fast[0]
        return verdict("T15-OTHER-CALL", "residue (ii).  The frame dump at :%d (producer %s) reads "
                                         "%s = a USERSPACE POINTER, the FAST shape - so the shim "
                                         "that ran fast (and mapped successfully) is NOT the call "
                                         "that died, and the `udf`'s failing call is another one.  "
                                         "PER §6.2'S CAVEAT: the printf producer's `r0` is the "
                                         "WIRE's slot 0 (the task port, records/1022-trap15-wire.txt "
                                         "§4), so a FAST-looking `r0` under that producer is NOT the "
                                         "same measurement as the design's on-frame "
                                         "`xnu_live_undef_frame0`.  Where BOTH producers are "
                                         "present they must AGREE or the hook is reading a "
                                         "different frame ([[mi4-a-status-is-a-verdict-only-if-its-"
                                         "producer-delivered-one]]); here the producer was `%s`."
                      % (ln, prod, C15.fmt(v), prod))

    # =============================================================================================
    # 6. T15-SENTINEL - no row evidence, no panic, and the run still STOPS.
    # =============================================================================================
    stop_ev = []
    if wall["present"] is True:
        stop_ev.append("the wall undef IS present (pc %s at :%s)"
                       % (C15.fmt(wall["wall_pc"]), wall["wall_last"]))
    if wall["other_user"]:
        stop_ev.append("other user-mode undef pc(s) %s at :%s"
                       % ("{%s}" % ", ".join(C15.fmt(p) for p in wall["other_user"]),
                          wall["other_lines"][0] if wall["other_lines"] else "?"))
    if wall["kernel_pcs"]:
        stop_ev.append("a KERNEL-mode undef pc(s) %s" % "{%s}" % ", ".join(
            C15.fmt(p) for p in wall["kernel_pcs"]))
    if pan["record"]:
        stop_ev.append("a `%s` block at :%d" % (TRAP_RECORD_MARK, pan["record_lines"][0]))
    if pan["panic_entered"] not in (0, None):
        stop_ev.append("`%s=%s` (:%s) - the undefined-instruction handler RAN in the kernel"
                       % (PANIC_ENTERED_KEY, C15.fmt(pan["panic_entered"]),
                          pan["panic_entered_line"]))
    if pan["panic_str"] not in (0, None):
        stop_ev.append("`%s=%s` (:%s)" % (PANIC_STR_KEY, C15.fmt(pan["panic_str"]),
                                          pan["panic_str_line"]))
    if pan["entry_undef_pc"] is not None:
        stop_ev.append("`%s=%s`" % (ENTRY_UNDEF_PC_KEY, C15.fmt(pan["entry_undef_pc"])))
    if not pan["evidence"] and not vm_mark_lines and stop_ev:
        # ⚠ `not pan["evidence"]` is not decoration: with the control's panic carve-out, a panic
        # capture can reach this line, and a panic is NEVER a SENTINEL reading.
        return verdict("T15-SENTINEL", "REGRESSION - ROW INSTALLED, SELECTOR STILL 0?  The ROW's own "
                                       "witness is SILENT (`%s` x0) and no panic, yet the run STILL "
                                       "STOPS: %s.  (The live undef witness was present x%d row(s); "
                                       "the absence that matters here is the ROW's, not the live "
                                       "channel's.)  Per §7 this "
                                       "is the one cell that is a defect OF THIS RUNG.  ⚠ NAMED "
                                       "AMBIGUITY: this capture cannot separate the two cases its "
                                       "own prose mixes - (a) `ios7lab_mach_vm_map_trap`'s early "
                                       "return at mach_kernelrpc.c:217 evaluated FALSE (the selector "
                                       "gate did not land), or (b) it evaluated TRUE, returned the "
                                       "sentinel, and the object is the row itself.  THE CAPTURE "
                                       "CARRIES NO NEW EVIDENCE EITHER WAY, because the selector "
                                       "return sits BEFORE both the frame dump and the `done:` "
                                       "printf - a selector-0 run is, in the new witnesses, "
                                       "indistinguishable from a run that never installed the row.  "
                                       "The by-value clause (design §3) is what separates them: read "
                                       "`mach_trap_table[15].fn` and `nm` on the two pool objects "
                                       "BEFORE re-pressing.  Also reported: this run's `%s` max=%s."
                      % (VM_MAP_MARK, "; ".join(stop_ev), len(rows), WDT_PETS_KEY,
                         C15.fmt(max_key(cap, WDT_PETS_KEY))))

    # =============================================================================================
    # 7. NO-CELL - no pre-registered cell fires.  NAME what was present and what failed; NEVER
    #    fabricate a verdict (`[[mi4-a-claim-in-a-comment-is-not-a-check]]` runs both ways).
    # =============================================================================================
    failed = []
    if not vm_mark_lines:
        failed.append("`%s` x0 (no `result=0`/`result=4` to classify)" % VM_MAP_MARK)
    if not frames:
        failed.append("no frame dump, so the SLOW/FAST predicate has no input")
    if wall["present"] is None:
        failed.append("the wall was UNREADABLE (no `%s` for pid 1)" % MAP_SLIDE_MARK)
    elif wall["present"] is False:
        failed.append("the wall undef is ABSENT and no successful row firing follows - the run "
                      "would have to have moved, but nothing says the row did it")
    if moved is None:
        failed.append("the progress test is UNREADABLE (%s)" % moved_why)
    return verdict("NO-CELL", "NO PRE-REGISTERED CELL FIRES - nothing is concluded.  KEYS PRESENT: "
                              "%s.  PREDICATES THAT FAILED: %s.  Do NOT read this as a pass: it "
                              "means this capture is outside the pre-registered table, so the rung "
                              "must be described in a new cell BEFORE its data is interpreted "
                              "([[mi4-measurement-defects]]: a table that cannot say what a run "
                              "was is not yet a reading)."
                  % (present_txt, "; ".join(failed) if failed else "(none - a reader defect)"))


# ---------------------------------------------------------------------------------------------------
# THE SELF-TEST.  Every fixture is SYNTHETIC, generated in a fresh tempfile.mkdtemp(), and NEVER
# written into the repo and never derived from a real capture by hand-editing (a fixture cut from the
# real thing inherits whatever the real thing got wrong - and the whole point is that the reader can
# FAIL: [[mi4-a-claim-in-a-comment-is-not-a-check]]).
# ---------------------------------------------------------------------------------------------------
def _mk(tmpdir, name, lines):
    path = os.path.join(tmpdir, name)
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def self_test():
    import tempfile
    ok = True
    tmpdir = tempfile.mkdtemp(prefix="check1022-selftest-")
    cases = []

    def cell_of(lines, base_lines, tag):
        p = _mk(tmpdir, tag + ".txt", lines)
        cap = C15.Capture(p)
        cap.path = p
        base, bpath = None, None
        if base_lines is not None:
            bpath = _mk(tmpdir, tag + "-base.txt", base_lines)
            base = C15.Capture(bpath)
            base.path = bpath
        with contextlib.redirect_stdout(io.StringIO()):
            return adjudicate(cap, base, bpath)

    def want(name, lines, expected, base_lines=None):
        nonlocal ok
        got = cell_of(lines, base_lines, name)
        cases.append((name, got, expected))
        if got != expected:
            say("SELFTEST-FAIL", "%s: expected %s, got %s" % (name, expected, got))
            ok = False

    # ---- THE FIXTURE VOCABULARY, written the way the real recorders write it. ----
    SLIDE = 0x001BFE000
    WALL_PC = REF_WALL_OFFSET + SLIDE            # 0x39e38a54 - the 1021d run's own pc
    SLIDE_LINE = ("IOS7SHREG map_slide pid=1 fd=0 count=4 mappings=0x2bdd2848 slide=0x%x "
                  "slide_start=0x3ddaa000 size=0x00089000" % SLIDE)
    MEM = "MI4IOS6_STAGE90_XNU xnu_entry_args_memSize=0x1e400000"
    # The live undef witness: `_seq` OPENS a row, the detail keys follow in the recorder's order.
    UNDEF_AT_WALL = [" xnu_live_undef_seq=0x00000001",
                     " xnu_live_undef_user_seq=0x00000001",
                     " xnu_live_undef_pc=0x%08x" % WALL_PC,
                     " xnu_live_undef_lr=0x00000007",
                     " xnu_live_undef_spsr=0x20000030",
                     " xnu_live_undef_user=0x00000001"]
    PRINTF_AT_WALL = ("launchd[1]: usermode undefined instruction, EXC_BAD_INSTRUCTION at 0x%08x "
                      "in map 0xc00057b8 (pmap 0xc0ba3cc0)" % WALL_PC)
    # The row's own printf, VERBATIM in shape (mach_kernelrpc.c:238).
    def vmline(result, address, size_hi=0, size_lo=0x1000, mask_hi=0, mask_lo=0, flags=0, prot=0):
        return ("IOS7LAB vm_map64 size=%08x:%08x mask=%08x:%08x flags=%x prot=%x result=%d "
                "address=%08x" % (size_hi, size_lo, mask_hi, mask_lo, flags, prot, result, address))
    # The frame dump, printf spelling (IN THE TREE) and KV spelling (design §6.2).
    def framep(v):
        return ("IOS7LAB trap15 frame r0=%08x r1=0x2bdd2848 r2=0x00001000 r3=0x00000000 "
                "r4=0x00000000 r5=0x00000000 r6=0x00000000 r8=0x00000000" % v)

    # ================= G-CTL =================
    want("G-CTL-empty", [], "G-CTL")
    want("G-CTL-no-witnesses", ["MI4IOS6_STAGE90_XNU booting", MEM], "G-CTL")
    # One witness is enough to pass the control.
    want("G-CTL-one-witness-live", [" " + UNDEF_SEQ_KEY + "=0x00000001"], "NO-CELL")
    want("G-CTL-one-witness-row", [vmline(4, 0)], "T15-REFUSED")

    # ================= T15-FIRES =================
    f1 = [SLIDE_LINE, MEM] + UNDEF_AT_WALL + [PRINTF_AT_WALL, vmline(0, 0x00001000)]
    want("FIRES-wall-absent-then-row", [SLIDE_LINE, MEM, vmline(0, 0x00001000)], "T15-FIRES")
    want("FIRES-wall-present-but-row-after", f1, "T15-FIRES")
    # The row fired but the wall came AFTER it, so nothing shows the boot moved past it.
    want("FIRES-NOT-row-before-wall",
         [SLIDE_LINE, MEM, vmline(0, 0x00001000)] + UNDEF_AT_WALL + [PRINTF_AT_WALL], "NO-CELL")
    # `result=0` with a ZERO address is not a success (address is an in/out pointer).
    want("FIRES-NOT-zero-address", [SLIDE_LINE, MEM, vmline(0, 0x00000000)], "NO-CELL")

    # ================= T15-REFUSED =================
    r1 = [SLIDE_LINE, MEM] + UNDEF_AT_WALL + [PRINTF_AT_WALL,
                                              vmline(4, 0x00000000, size_hi=0x1000)]
    want("REFUSED", r1, "T15-REFUSED")
    # A refusal dominates a success (most-severe first), and does so even with no wall evidence.
    want("REFUSED-over-FIRES", [SLIDE_LINE, vmline(4, 0), vmline(0, 0x1000)], "T15-REFUSED")

    # ================= T15-PANICS =================
    want("PANICS-vec-81",
         [SLIDE_LINE, "panic: fleh_vectors: exception in exception vectors, 0x00000081"], "T15-PANICS")
    want("PANICS-panic-text", [SLIDE_LINE, "panic(\"sleh_undef: current thread is NULL\")"],
         "T15-PANICS")
    # A non-zero `xnu_entry_panic_entered` alone is NOT the design's panic cell - it is the SENTINEL
    # cell's kernel-stop evidence (it rides `g_panic_buf`, entry_stubs.c:6382).
    want("SENTINEL-panic-entered-only", [SLIDE_LINE, " xnu_entry_panic_entered=0x00000001"],
         "T15-SENTINEL")
    want("PANICS-why-p", [SLIDE_LINE, " xnu_entry_why_byte=0x00000070"], "T15-PANICS")
    # ⚠ A panic dominates even when the row SUCCEEDED: the design calls the cell "NOT A BEHAVIOUR
    #   READING", so it is not softened by a success line.
    want("PANICS-over-FIRES", [SLIDE_LINE, vmline(0, 0x1000), "panic: x"], "T15-PANICS")
    # ... and this image's OWN record slots are NOT panic text ([[mi4-one-value-two-definitions]]).
    want("PANICS-NOT-record-slots",
         [SLIDE_LINE, " xnu_entry_panic_str=0x00000000", " xnu_entry_panic_entered=0x00000000",
          vmline(4, 0)], "T15-REFUSED")

    # ================= T15-UNEXERCISED / T15-OTHER-CALL =================
    want("UNEXERCISED-printf", [SLIDE_LINE] + UNDEF_AT_WALL + [framep(SLOW_WORD)], "T15-UNEXERCISED")
    want("UNEXERCISED-kv", [SLIDE_LINE] + UNDEF_AT_WALL + [" xnu_live_undef_frame0=0x00000007"],
         "T15-UNEXERCISED")
    want("OTHER-CALL-printf", [SLIDE_LINE] + UNDEF_AT_WALL + [framep(0x2bdd2848)], "T15-OTHER-CALL")
    want("OTHER-CALL-kv", [SLIDE_LINE] + UNDEF_AT_WALL + [" xnu_live_undef_frame0=0x3ddaa000"],
         "T15-OTHER-CALL")
    # A value that is NEITHER shape is not a cell - and the message says so.
    want("FRAME-ambiguous", [SLIDE_LINE] + UNDEF_AT_WALL + [framep(0x00000100)], "T15-SENTINEL")
    # A frame dump with NO row firing is never FIRES/REFUSED, even alongside a success line...
    want("UNEXERCISED-over-FIRES-shape",
         [SLIDE_LINE, framep(SLOW_WORD), vmline(0, 0x1000)], "T15-FIRES")

    # ================= T15-SENTINEL =================
    # A panic with NO witness at all is still the panic cell (see the module docstring and the two
    # carve-outs at the control): panic evidence is a POSITIVE, produced by XNU's own printf.
    want("PANICS-no-witness", ["panic: fleh_vectors: exception in exception vectors, 0x00000081"],
         "T15-PANICS")
    want("SENTINEL-wall-present", [SLIDE_LINE, MEM] + UNDEF_AT_WALL + [PRINTF_AT_WALL], "T15-SENTINEL")
    want("SENTINEL-trap-record",
         [SLIDE_LINE, MEM, "MI4IOS6_STAGE90_XNU trap record:",
          " xnu_entry_panic_str=0x80601111"], "T15-SENTINEL")

    # ================= NO-CELL =================
    # The witness is live, but nothing is left to classify: no row, no frame dump, no stop.
    want("NO-CELL-no-stop", [SLIDE_LINE, MEM, " " + UNDEF_SEQ_KEY + "=0x00000001"], "NO-CELL")
    # The row RAN with a `result` that is neither SUCCESS nor KERN_INVALID_ARGUMENT.  Not FIRES, not
    # REFUSED, and NOT SENTINEL either (the row's witness is not silent) - the honest outcome is
    # NO-CELL, naming the value, rather than bending a cell to fit.
    want("NO-CELL-other-result", [SLIDE_LINE, vmline(2, 0x00001000)], "NO-CELL")
    # The row's MARK is present but the line is UNPARSEABLE: it still counts as witness (ii) at the
    # control (the row RAN), and it still cannot be classified - NO-CELL, with the warning printed.
    want("NO-CELL-unparsed-row", [SLIDE_LINE, "IOS7LAB vm_map64 (truncated",
                                  " " + UNDEF_SEQ_KEY + "=0x00000001"], "NO-CELL")

    # ================= the BASELINE section (never a cell) =================
    # It must REFUSE a capture given as its own baseline, and must not change the cell.
    p = _mk(tmpdir, "selfbase.txt", [SLIDE_LINE, MEM] + UNDEF_AT_WALL + [PRINTF_AT_WALL])
    cap = C15.Capture(p)
    cap.path = p
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        got = adjudicate(cap, cap, p)
    cases.append(("BASELINE-refuses-self", got, "T15-SENTINEL"))
    if "REFUSING the baseline" not in buf.getvalue():
        say("SELFTEST-FAIL", "BASELINE-refuses-self: the reader did not refuse a self-baseline")
        ok = False
    if got != "T15-SENTINEL":
        say("SELFTEST-FAIL", "BASELINE-refuses-self: cell moved to %s" % got)
        ok = False

    print("\n  == SELF-TEST ==")
    bad = [(n, g, e) for n, g, e in cases if g != e]
    print("  %d case(s), %d failed" % (len(cases), len(bad)))
    for n, g, e in bad:
        print("    FAIL: %s (got %s, want %s)" % (n, g, e))
    # Every cell must be REACHED by at least one fixture - a pre-registered cell nothing can reach is
    # a dead cell ([[mi4-measurement-defects]]: the table must be able to fire).
    got_cells = {g for _n, g, _e in cases}
    missing = [c for c in CELLS if c not in got_cells]
    if missing:
        print("    FAIL: no fixture reached %s" % ", ".join(missing))
        bad.append(("coverage", None, missing))
    print("  SELF-TEST: %s" % ("PASS" if not bad else "FAIL"))
    return 0 if not bad else 1


# ---------------------------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="1022 mach trap-15 row / __os_alloc_slow udf capture "
                                             "reader")
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--baseline", help="a capture to compare against (the 1021d capture measures the "
                                       "wall itself; default: the 1021d recovery, when on disk)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(self_test())
    if not args.capture:
        ap.error("a capture path is required (or --selftest)")
    try:
        cap = C15.Capture(args.capture)
    except (OSError, IOError) as exc:
        print("CANNOT READ %s: %s" % (args.capture, exc))
        sys.exit(1)
    cap.path = args.capture

    base, bpath = None, None
    cand = args.baseline
    if cand is None and os.path.isfile(DEFAULT_BASELINE):
        cand = DEFAULT_BASELINE
        say("BASE", "no --baseline given; using the 1021d recovery on disk (%s)" % cand)
    if cand is not None:
        if not os.path.isfile(cand):
            say("BASE", "the named baseline does not exist (%s) - the side-by-side is SKIPPED" % cand)
        else:
            try:
                base = C15.Capture(cand)
                base.path = cand
                bpath = cand
            except (OSError, IOError) as exc:
                say("BASE", "cannot read the baseline (%s): %s" % (cand, exc))

    cell = adjudicate(cap, base, bpath)
    print("\n[1022] VERDICT: %s" % DISPLAY.get(cell, cell))
    return 0


if __name__ == "__main__":
    sys.exit(main())