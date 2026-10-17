#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_1024_capture.py -- the 1024 press's capture reader (the VM_MAX_ADDRESS split rung).

WHAT 1024 IS, AND WHAT THIS CHECKER IS FOR
==========================================
1023 (records/1023-press-read.txt) installed `mach_trap_table[24]` (`mach_port_construct`) and read
T24-FIRES: trap 24 dispatches (`IOS7LAB trap24 frame` x4), the row's body succeeds
(`IOS7LAB port_construct ... result=0` x4), the 1022 libxpc udf wall is gone, and the frontier MOVED
to a ~2^20-iteration DATA-ABORT LOOP at user pc `0x38241790` (= `_pthread_create+0xbc`, in
libsystem_pthread.dylib) on `far = 0x40083008`.

1024 changes ONE value: the task map's ceiling `VM_MAX_ADDRESS` from `0x80000000` to `0x40000000`,
so the map agrees with the hardware's 1 GiB TTBR0 split set by `set_mmu_ttbcr(2)` (TTBCR.N=2,
`arm_vm_init.c:475`).  Behind `STAGE90_XNU_VM_MAX_SPLIT=1` (docs/1024-design.md sections 1-2).  Above
the split (VA >= 0x40000000) the hardware walks the KERNEL's TTBR1 tree, finds nothing, `vm_fault`
"installs" into the user pmap's TTBR0-side tree which the hardware never consults, and every
re-execution faults again - an infinite loop, not a crash.  The fix is one value in the file that
already documents it.

THE HEADLINE CELL IS *ABSENCE OF THE STORM*, AND AN ABSENCE IS A READING ONLY IF A POSITIVE SIGNAL
FROM THE SAME RUN SAYS THE INSTRUMENT WAS LIVE ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).
So `STORM-GONE` is never taken on the storm's absence alone: it requires the prior rungs' POSITIVE
controls in the SAME capture.

THE WITNESSES
=============
  (i)  THE STORM -- the abort ladder's own rows.  The storm is DEFINED BY THE ROWS' OWN VALUES:
       a tail abort (`xnu_live_abt_pcn >= %(tail)s`) whose `xnu_live_abt_pcfar == 0x40083008` AND
       whose `xnu_live_abt_pc` is the 1023 pc (slide-corrected).  The storm is NOT "any abort above
       the split": `far >= 0x40000000` alone is neither necessary (the packet the storm's own
       `pc`/`far` pair travels with moves per run) nor sufficient (a one-off abort above the split is
       a different reading).  The classifier is `check_1015_capture.py`'s `aborts()`/
       `classify_storm()` REUSED BY IDENTITY (one file holds one definition of "the storm").
  (ii) THE PRIOR RUNGS' CONTROLS -- the 1023 marks, read by value from the SAME capture:
       `IOS7LAB trap24 frame` x4, `IOS7LAB port_construct ... result=0` x4, `xnu_live_undef_seq`
       present = 0, zero panics.  A REGRESSION in any of these is `PRIOR-RUNGS-REGRESSED` - the
       arm's switch set is wrong, not the fix (and it must be tested BEFORE `STORM-GONE`, or a
       capture whose console died would be read as a pass).

CELLS (pre-registered; docs/1024-design.md section 4)
====================================================
  G-CTL               neither the live channel nor any IOS7LAB line is live AND no panic/stop
                      => WITHHOLD (fail closed; never a pass)
  STORM-PERSISTS      the previous rung's storm recurs AT SCALE at the 1023 pc/far pair
                      => the patch did NOT reach the compiled image; read
                      `tools/check_vm_max_split.py <elf> --expect on` FIRST
  STORM-MOVED         a storm exists elsewhere; in particular any `abt_far >= 0x40000000` is itself
                      notable (something other than the map produces VAs there)
  STORM-GONE          the 1023 storm signature is ABSENT AND the prior rungs' positive controls all
                      hold => report the NEW frontier (last non-storm abt_pc slide-corrected, its
                      abt_far, the last user SVC record, the last stall pc)
  PRIOR-RUNGS-REGRESSED  one of the prior rungs' controls regressed
  NO-CELL             nothing in the pre-registered table fires (report what was present; never
                      fabricate a verdict)

⚠ THE ORDER OF THE CELLS IS THE READER'S MOST IMPORTANT PROPERTY.  `G-CTL` is first (an unsound
instrument cannot read an absence).  `PRIOR-RUNGS-REGRESSED` is tested BEFORE the storm cells: a
capture whose prior controls regressed is NOT a "storm gone" reading and must never be reported as
one.  Only then does the storm's own shape decide PERSISTS / MOVED / GONE.

The by-value build-side clause is `tools/check_vm_max_split.py <elf> --expect on|off`; it is NOT
re-run here (this is a CAPTURE reader).  But when this reader reads STORM-PERSISTS it NAMES that
clause, because a persisting storm means the compiled image is not what the fix blessed.

⚠ TWO PARSERS, TWO KEYS: this reader keys on BOTH the `IOS7LAB` printf marks and the live-channel
(`xnu_live_*`) witnesses, read via `raw_kv` because `C15.Capture`'s KV regex is
`xnu_live_[a-z0-9_]+` by construction.
"""

import argparse
import contextlib
import importlib.util
import io
import os
import re
import sys

# The capture parser is REUSED BY IDENTITY, not cloned ([[mi4-one-value-two-definitions]]).
_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("check_1015_capture",
                                              os.path.join(_HERE, "check_1015_capture.py"))
C15 = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(C15)


def say(tag, msg=""):
    print("[1024] %-9s %s" % (tag, msg))


def verdict(cell, msg):
    print("[1024] %-16s %s" % (cell, msg))
    return cell


# ===================================================================================================
# THE 1023 STORM'S IDENTITY (slide-invariant FILE OFFSET, NOT a linked VA: pid 1's pc is in the dyld
# shared cache and its runtime pc moves with the slide EVERY RUN).  Both are also read from the 1023
# record below - the constants are the RECORD'S values, printed for the arithmetic cross-check.
# ===================================================================================================
REF_PC_OFFSET = 0x38241790          # libsystem_pthread.dylib +0x2790 = `_pthread_create+0xbc`
REF_PC_NAME = "_pthread_create+0xbc (libsystem_pthread.dylib)"
REF_FAR = 0x40083008                # r5 + 8, with r5 = 0x40083000 (the returned stack/struct)
REF_1023_PC = 0x39DED790            # the 1023 capture's RAW pc (recorded for the arithmetic check)
REF_1023_SLIDE = 0x01BAC000

# The hardware split this rung is about: TTBR0 owns [0, 0x40000000), TTBR1 the rest.
SPLIT = 0x40000000
# The 1022 wall's own udf (libxpc `__xpc_mach_port_allocate+0x5a`), read for CORROBORATION only - the
# 1023 capture has it x0 and 1024 must not resurrect it.
REF_WALL_OFFSET = 0x3824E022
REF_WALL_NAME = "__xpc_mach_port_allocate+0x5a (libxpc)"

# The scale threshold for "a storm".  MEASURED, not guessed: the 1023 capture carries exactly
# 10 storm rows out of 37 published aborts (0x80080000, 0x40000 and 0x100000 have NONE in it),
# and a storm IS a recurrence.
STORM_MIN_ROWS = 3

# `xnu_live_abt_pcn` - the abort ORDINAL, the key the 1015 storm classifier's tail is defined on.
ABT_PCN_KEY = "xnu_live_abt_pcn"
# The storm ordinal threshold, READ FROM 1015 rather than re-spelled here.
TAIL_MIN_N = getattr(C15, "TAIL_MIN_N", 0x400)

# The slide is published by the shreg wire, e.g.
# `IOS7SHREG map_slide pid=1 fd=0 count=4 mappings=0x2bdd2848 slide=0x1bac000 ...`.
MAP_SLIDE_MARK = "map_slide"
MAP_SLIDE_RE = re.compile(r"\bmap_slide\b.*?\bpid=(\d+)\b.*?\bslide=(0x[0-9A-Fa-f]+)\b")

# ---- the live undef witness (`entry_trace.c`, `__wrap_sleh_undef`) --------------------------------
UNDEF_SEQ_KEY = "xnu_live_undef_seq"
UNDEF_PC_KEY = "xnu_live_undef_pc"

# ---- the frontier report's keys, verbatim from the recorder ---------------------------------------
STALL_PC_KEY = "xnu_live_stall_pc"
STALL_LR_KEY = "xnu_live_stall_lr"
STALL_SP_KEY = "xnu_live_stall_sp"
STALL_T_KEY = "xnu_live_stall_t"
USVC_NUM_KEY = "xnu_live_usvc_num"
USVC_PC_KEY = "xnu_live_usvc_pc"
USVC_PID_KEY = "xnu_live_usvc_pid"
USVC_LR_KEY = "xnu_live_usvc_lr"
USVC_N_KEY = "xnu_live_usvc_n"

# ---- the row's own two prints, VERBATIM from the staged body (1023's marks, unchanged) -----------
DISPATCH_MARK = "IOS7LAB trap24 frame"
DISPATCH_RE = re.compile(
    r"IOS7LAB trap24 frame r0=([0-9A-Fa-f]{8}) r1=([0-9A-Fa-f]{8}) r2=([0-9A-Fa-f]{8}) "
    r"r3=([0-9A-Fa-f]{8}) r4=([0-9A-Fa-f]{8}) r5=([0-9A-Fa-f]{8}) r8=([0-9A-Fa-f]{8})")

BODY_MARK = "IOS7LAB port_construct"
BODY_RE = re.compile(
    r"IOS7LAB port_construct flags=([0-9A-Fa-f]+) qlimit=(-?\d+) context=([0-9A-Fa-f]{8}):"
    r"([0-9A-Fa-f]{8}) result=(-?\d+) name=([0-9A-Fa-f]+) bypass_hints=([0-9A-Fa-f]+)")

DISPATCH_WANT = 4                   # 1023's measured count - the prior control's own value
BODY_WANT = 4

# ---- panic evidence (the same argv as check_1023_capture.py) --------------------------------------
PANIC_ENTERED_KEY = "xnu_entry_panic_entered"
VEC_PANIC_MARK = "fleh_vectors: exception in exception vectors"
VEC_PANIC_CODE_RE = re.compile(r"exception in exception vectors,\s*0x([0-9A-Fa-f]+)")
SWI_MACH_ERROR_CODE = 0x81          # `traps_lo.s:261`
PANIC_TEXT_RE = re.compile(r"\bpanic\b[:(]")

# Residency.
WDT_PETS_KEY = "xnu_live_wdt_pets"
MEMSIZE_KEY = "xnu_entry_args_memSize"

TRUNC_MARKER = "No errors detected"     # the recovered last_kmsg's terminal line

# The 1023 recovery, used as the `--baseline` DEFAULT.
DEFAULT_BASELINE = os.path.join(os.path.dirname(_HERE), "out", "stage90", "captures",
                                "recovered-unknown-arm-20261016-083000-last_kmsg.txt")

# The cells, in the brief's order.  `NO-CELL` is the else-arm and is NOT a verdict.
CELLS = ("G-CTL", "STORM-PERSISTS", "STORM-MOVED", "STORM-GONE", "PRIOR-RUNGS-REGRESSED",
         "NO-CELL")

DISPLAY = {
    "G-CTL": "WITHHOLD (INSTRUMENT_UNSOUND)",
    "STORM-PERSISTS": "STORM-PERSISTS (THE FIX DID NOT REACH THE COMPILED IMAGE)",
    "STORM-MOVED": "STORM-MOVED (A STORM EXISTS ELSEWHERE)",
    "STORM-GONE": "STORM-GONE (the 1023 signature is ABSENT - the frontier MOVED)",
    "PRIOR-RUNGS-REGRESSED": "PRIOR-RUNGS-REGRESSED (the arm's switch set is wrong, not the fix)",
    "NO-CELL": "NO-CELL (no pre-registered cell fires - nothing is concluded)",
}


# ===================================================================================================
# THE RAW-TEXT READER (the `xnu_entry_*` keys are invisible to `C15.Capture.toks`).
# ===================================================================================================
def raw_kv(cap, key):
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


# ===================================================================================================
# THE READINGS
# ===================================================================================================
def slide_of(cap, pid=1):
    hit = (None, None)
    for i, line in enumerate(cap.lines, 1):
        if MAP_SLIDE_MARK not in line:
            continue
        m = MAP_SLIDE_RE.search(line)
        if m is not None and C15.to_int(m.group(1)) == pid:
            hit = (C15.to_int(m.group(2)), i)
    return hit


def dispatch_events(cap):
    """`(rows, malformed)`: the row's own frame dump, parsed.  `malformed` are `(line, text)` for
    lines carrying the MARK that the field regex could NOT parse - a line the reader cannot parse is
    still evidence the row RAN, so it counts at `G-CTL`."""
    rows, malformed = [], []
    for i, line in enumerate(cap.lines, 1):
        if DISPATCH_MARK not in line:
            continue
        m = DISPATCH_RE.search(line)
        if m is None:
            malformed.append((i, line.strip()[:200]))
            continue
        rows.append({"line": i,
                     "r0": C15.to_int("0x" + m.group(1)),
                     "r1": C15.to_int("0x" + m.group(2)),
                     "r2": C15.to_int("0x" + m.group(3)),
                     "r3": C15.to_int("0x" + m.group(4)),
                     "r4": C15.to_int("0x" + m.group(5)),
                     "r5": C15.to_int("0x" + m.group(6)),
                     "r8": C15.to_int("0x" + m.group(7)),
                     "raw": line.strip()[:200]})
    return rows, malformed


def body_events(cap):
    """`(rows, malformed)`: the row's `done:` printf, parsed."""
    rows, malformed = [], []
    for i, line in enumerate(cap.lines, 1):
        if BODY_MARK not in line:
            continue
        m = BODY_RE.search(line)
        if m is None:
            malformed.append((i, line.strip()[:200]))
            continue
        rows.append({"line": i,
                     "flags": C15.to_int("0x" + m.group(1)),
                     "qlimit": int(m.group(2), 10),
                     "context_hi": C15.to_int("0x" + m.group(3)),
                     "context_lo": C15.to_int("0x" + m.group(4)),
                     "result": int(m.group(5), 10),
                     "name": C15.to_int("0x" + m.group(6)),
                     "bypass_hints": C15.to_int("0x" + m.group(7)),
                     "raw": line.strip()[:200]})
    return rows, malformed


def panic_reading(cap):
    """The panic evidence, by value.  `evidence` is the boolean the cells key on."""
    d = {}
    pe = raw_last(cap, PANIC_ENTERED_KEY)
    d["panic_entered"], d["panic_entered_line"] = (pe[1] if pe else None), (pe[0] if pe else None)
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
    d["evidence"] = bool(d["vec_panic"] or d["panic_text"])
    d["stopped"] = bool(d["panic_entered"] not in (0, None))
    return d


def panic_why(d):
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
    return "; ".join(out) if out else "(none)"


def storm_reading(cap):
    """THE STORM, BY VALUE, on this capture.  Returns a dict every cell reads.

    The classifier is `check_1015_capture.py`'s `aborts()` + `classify_storm()` REUSED BY IDENTITY:
    one file holds one definition of "the storm" ([[mi4-one-value-two-definitions]]).  1015 defines
    the storm as the TAIL fault that RECURS (the most rows at `pcn >= TAIL_MIN_N`), which is the
    right definition here for a documented reason: 1015's VOICE is the one that already had to cope
    with a storm VA that MOVES per run, and it computes the VA by value rather than from a literal.

    ON TOP of that by-value population this reader takes the 1023-SPECIFIC reading the rung's cells
    are pre-registered on: the rows whose OWN `pc` is the 1023 pc (slide-corrected) AND whose own
    `far` is `0x40083008`.  Both are reported so the reader can be audited: `tail_va` (1015's by-value
    answer), `storm_rows` (the 1023-keyed rows) and `far_above_split` (ANY tail row above the split).

    ⚠ `pc == None` and `far == None` are NOT `far == 0x40083008` - an abort whose own fields were
    never published must never be counted into a storm (a status is a verdict only if its producer
    delivered one)."""
    abt_rows = C15.aborts(cap)
    cls = C15.classify_storm(abt_rows, TAIL_MIN_N)

    max_pcn = max([r["pcn"] for r in abt_rows if r["pcn"] is not None] or [None]) \
        if abt_rows else None
    max_pcn_gaps = []
    prev = None
    for i, line in enumerate(cap.lines, 1):
        if ABT_PCN_KEY not in line:
            continue
        m = re.search(re.escape(ABT_PCN_KEY) + r"=(0x[0-9A-Fa-f]+)", line)
        if m is None:
            continue
        cur = C15.to_int(m.group(1))
        if prev is not None and cur is not None and cur < prev:
            max_pcn_gaps.append(i)
        prev = cur

    # THE SLIDE — all three readings of it, so a missing one is VISIBLE rather than silently fatal.
    slide, slide_line = slide_of(cap)
    usvc_pcs = [t[3] for t in cap.all(USVC_PC_KEY) if t[3] is not None]
    # ⚠ 0x2BE00000 IS THE TEXT BASE, NOT A SLIDE.  `xnu_live_usvc_pc` names a mapping's TEXT offset,
    # so a USVC pc alone cannot recover the slide - what it can do is place the pc's own 1 MiB slot in
    # a KNOWN image region, which is enough to say "the slide is within this slot" and no more.  That
    # is nowhere near the 0x20000 the identity needs (a difference of 1 in the slide moves the
    # corrected pc by 1), so this is NOT used to compute `storm_pc`.  It is reported as a CROSS-CHECK
    # of a slide that was actually published, and its absence changes no cell.
    slot_hint = (min(usvc_pcs) & 0xFFF00000) if usvc_pcs else None
    slide_hint = False

    return {
        "abt_rows": abt_rows,
        "n_aborts": len(abt_rows),
        "max_pcn": max_pcn,
        "pcn_regressions": max_pcn_gaps,
        "tail": cls["tail"],
        "tail_va": cls["va"],
        "tail_storm_rows": cls["storm_tail"],
        "tail_storm_high": cls["storm_high"],
        "tail_other_high": cls["other_high"],
        "tail_reached": cls["reached"],
        "slide": slide,
        "slide_line": slide_line,
        "slide_hint": slide_hint,
        "slot_hint": slot_hint,
        "storm_pc": (REF_PC_OFFSET + slide) if slide is not None else None,
        "storm_rows": [r for r in cls["tail"] if r["far"] == REF_FAR
                       and slide is not None and r["pc"] == REF_PC_OFFSET + slide],
        # ⚠ THE 1023 PAIR IS EXCLUDED BY VALUE.  The design's guard is "any `abt_far >= 0x40000000`
        # means the map was NOT the only producer" - but the storm's OWN rows carry such a `far`
        # (`0x40083008` IS at/above the split: that is the whole defect), so a guard that did not
        # exclude them would fire on every capture that has the signature at all, and STORM-PERSISTS
        # vs STORM-MOVED would become a coin toss.  Only a row that is NOT the 1023 pair is
        # "something other than the map".  Without a slide the pair cannot be identified, so every
        # above-split row counts - the CONSERVATIVE direction.
        "far_above_split": [r for r in cls["tail"] if r["far"] is not None and r["far"] >= SPLIT
                            and not (r["far"] == REF_FAR and slide is not None
                                     and r["pc"] == REF_PC_OFFSET + slide)],
        "pc_above_split": [r for r in cls["tail"] if r["pc"] is not None and r["pc"] >= SPLIT],
    }


def prior_controls(cap, disp, disp_lines, body, pan, rows):
    """The prior rungs' POSITIVE controls, each an OBSERVED value (never inferred from an absence).
    `ok` is the cell's predicate; `fails` names each one that regressed - a cell must be able to
    SAY what regressed, or the reader is a status whose producer did not deliver one."""
    results = {}
    for r in body:
        results[r["result"]] = results.get(r["result"], 0) + 1
    n_ok = results.get(0, 0)
    checks = [
        ("the row's dispatch witness `%s`" % DISPATCH_MARK,
         len(disp_lines) >= DISPATCH_WANT,
         "x%d (the 1023 control reads x%d)" % (len(disp_lines), DISPATCH_WANT)),
        ("the row's body witness `%s`" % BODY_MARK,
         len(body) >= BODY_WANT,
         "parsed x%d of x%d line(s) (the 1023 control reads x%d)"
         % (len(body), len(raw_lines_with(cap, BODY_MARK)), BODY_WANT)),
        ("the body's `result=0`", n_ok >= BODY_WANT,
         "result=0 x%d (the 1023 control reads x%d)" % (n_ok, BODY_WANT)),
        ("`%s` = 0" % UNDEF_SEQ_KEY, not rows,
         "x%d live undef row(s) (the 1023 control reads x0)" % len(rows)),
        ("zero panics", not pan["evidence"], panic_why(pan)),
    ]
    fails = ["%s %s" % (name, obs) for name, ok, obs in checks if not ok]
    return {"checks": checks, "fails": fails, "ok": not fails,
            "n_ok": n_ok, "results": results, "n_body_lines": len(raw_lines_with(cap, BODY_MARK))}


def new_frontier(cap, storm, pan):
    """The NEW frontier, as docs/1024-design.md section 4 defines it: the last NON-STORM `abt_pc`
    (slide-corrected), its `abt_far`, the last user SVC record, the last stall pc.

    A "non-storm" row is an abort row that is NOT one of the 1023 storm rows BY VALUE (a row with no
    `far` is not a storm row).  The slide-corrected file offsets are computed for the user-space rows
    (a pc in the kernel window is NOT slide-corrected - the kernel is not slid that way) and BOTH the
    raw and the corrected value are printed, so no consumer can mistake one for the other."""
    slide = storm["slide"]
    non_storm = [r for r in storm["abt_rows"] if r not in storm["storm_rows"]]
    last = non_storm[-1] if non_storm else None
    last_pc = last["pc"] if last else None
    last_off = None
    if last_pc is not None and slide is not None and last_pc < SPLIT:
        last_off = last_pc - slide
    usvc = None
    for key in (USVC_NUM_KEY, USVC_PC_KEY, USVC_LR_KEY, USVC_PID_KEY):
        v = raw_last(cap, key)
        if v is None:
            usvc = None
            break
        usvc = dict(usvc or {})
        usvc[key] = v[1]
        usvc[key + "_line"] = v[0]
    stall = None
    for key in (STALL_PC_KEY, STALL_LR_KEY, STALL_SP_KEY):
        v = raw_last(cap, key)
        if v is None:
            stall = None
            break
        stall = dict(stall or {})
        stall[key] = v[1]
        stall[key + "_line"] = v[0]
    stall_t = raw_last(cap, STALL_T_KEY)
    return {"last_named": None, "last_pc": last_pc, "last_pc_offset": last_off, "last_far":
            (last["far"] if last else None), "last_pcn": (last["pcn"] if last else None),
            "last_line": (last["ln"] if last else None), "n_non_storm": len(non_storm),
            "usvc": usvc, "stall": stall, "stall_t": (stall_t[1] if stall_t else None)}


def baseline_section(cap, base, base_path, storm):
    """The `--baseline` side-by-side (REPORT-ONLY; no cell reads it).

    ⚠ THE RAW PC IS NOT COMPARABLE ACROSS RUNS: pid 1's pc is POST-slide and the slide varies per
    run.  The invariant is the FILE OFFSET (`pc - slide`); both are printed."""
    if base is None:
        say("BASE", "no baseline - the side-by-side is SKIPPED (no cell depends on it)")
        return None
    cpself = os.path.realpath(getattr(cap, "path", "") or "")
    bpath = os.path.realpath(base_path or "")
    if cpself and cpself == bpath:
        say("BASE", "REFUSING the baseline: it IS this capture (a comparison a file makes with "
                    "itself cannot fail - [[mi4-a-claim-in-a-comment-is-not-a-check]])")
        return None
    bstorm = storm_reading(base)
    bpan = panic_reading(base)
    bdisp = raw_lines_with(base, DISPATCH_MARK)
    bbody = raw_lines_with(base, BODY_MARK)
    bstrm = len(bstorm["storm_rows"])
    name = os.path.basename(base_path or "(given)")
    say("BASE", "%s: slide=%s (:%s); aborts x%d; the 1023 storm rows x%d at far=%s; `%s` x%d; "
                "`%s` x%d; panic %s"
        % (name, C15.fmt(bstorm["slide"]), bstorm["slide_line"], bstorm["n_aborts"], bstrm,
           C15.fmt(REF_FAR), DISPATCH_MARK, len(bdisp), BODY_MARK, len(bbody),
           "YES" if bpan["evidence"] else "no"))
    if bstorm["storm_rows"]:
        p = bstorm["storm_rows"][-1]["pc"]
        say("BASE", "  its last storm pc %s -> FILE OFFSET %s (want %s)  [raw pc %s, slide %s]"
            % (C15.fmt(p), C15.fmt(p - bstorm["slide"]), C15.fmt(REF_PC_OFFSET), C15.fmt(p),
               C15.fmt(bstorm["slide"])))
    # The negative control: the SAME reader on the 1023 capture.  Both directions are printed.
    say("BASE", "  the storm ON THE BASELINE reads %s; on THIS capture x%d"
        % ("PERSISTS" if bstrm >= STORM_MIN_ROWS else "absent", len(storm["storm_rows"])))
    ours = {r["pc"] for r in storm["abt_rows"] if r["pc"] is not None}
    for r in bstorm["storm_rows"][:1]:
        if r["pc"] is not None:
            say("BASE", "  raw pc %s in THIS capture: x%d row(s); the same FILE OFFSET in THIS "
                        "capture: x%d row(s)"
                % (C15.fmt(r["pc"]), sum(1 for q in ours if q == r["pc"]),
                   sum(1 for q in ours if storm["slide"] is not None
                       and q - storm["slide"] == REF_PC_OFFSET)))
    return {"base_slide": bstorm["slide"], "base_storm_rows": bstrm, "base_name": name}


# ===================================================================================================
# THE ADJUDICATION
# ===================================================================================================
def adjudicate(cap, baseline=None, baseline_path=None):
    disp, disp_bad = dispatch_events(cap)
    body, body_bad = body_events(cap)
    rows = undef_rows(cap)
    pan = panic_reading(cap)
    storm = storm_reading(cap)
    disp_lines = raw_lines_with(cap, DISPATCH_MARK)
    body_lines = raw_lines_with(cap, BODY_MARK)

    say("CAPTURE", "%d bytes, %d lines, %d live tokens" % (cap.nbytes, len(cap.lines), len(cap.toks)))
    baseline_section(cap, baseline, baseline_path, storm)

    # ---- THE SLIDE and the 1023 STORM'S IDENTITY -------------------------------------------------
    if storm["slide"] is None:
        say("SLIDE", "NO `%s` line for pid 1 - the slide is NOT PUBLISHED, so the 1023 pc CANNOT be "
                     "computed (never hard-coded: the slide varies per run).  `%s` x%d is NOT a "
                     "substitute: a USVC pc names a mapping's TEXT offset, not a slide, and the "
                     "identity needs the slide exactly%s"
            % (MAP_SLIDE_MARK, USVC_PC_KEY, len(raw_kv(cap, USVC_PC_KEY)),
               (" (its slot hint is %s, honest to +-1 MiB - not enough)"
                % C15.fmt(storm["slot_hint"])) if storm["slot_hint"] is not None else ""))
    else:
        say("SLIDE", "`%s` pid=1 at :%s reads slide=%s => this run's 1023 storm pc = %s (%s)%s"
            % (MAP_SLIDE_MARK, storm["slide_line"], C15.fmt(storm["slide"]),
               C15.fmt(storm["storm_pc"]), REF_PC_NAME,
               ("  ⚠ INFERRED, NOT published" if storm["slide_hint"] else "")))
        say("SLIDE", "cross-check vs the 1023 record: %s - %s = %s (want %s)"
            % (C15.fmt(REF_1023_PC), C15.fmt(REF_1023_SLIDE),
               C15.fmt(REF_1023_PC - REF_1023_SLIDE), C15.fmt(REF_PC_OFFSET)))

    we_are_the_baseline = (os.path.realpath(getattr(cap, "path", "") or "") ==
                           os.path.realpath(DEFAULT_BASELINE))
    if we_are_the_baseline:
        say("STORM", "⚠ THIS CAPTURE IS THE 1023 RECOVERY ITSELF - it is the NEGATIVE CONTROL this "
                     "reader's STORM cells are certified against.  Reading STORM-PERSISTS here is "
                     "EXPECTED and is NOT a 1024 outcome.")

    say("STORM", "abort ordinal(s) published x%d (max pcn=%s); TAIL at %s x%d; 1015's by-value storm "
                 "va=%s x%d tail row(s), %d at/above %s; OTHER tail fars={%s}"
        % (storm["n_aborts"], C15.fmt(storm["max_pcn"]), C15.fmt(TAIL_MIN_N), len(storm["tail"]),
           C15.fmt(storm["tail_va"]), len(storm["tail_storm_rows"]),
           len(storm["tail_storm_high"]), C15.fmt(getattr(C15, "STORM_MIN_ORD", 0x4000)),
           ", ".join(C15.fmt(f) for f in sorted({r["far"] for r in storm["tail"]
                                                 if r["far"] != storm["tail_va"]})) or "(none)"))
    say("STORM", "THE 1023-KEYED SIGNATURE (pc %s at far %s): x%d row(s) in the tail%s"
        % (C15.fmt(storm["storm_pc"]), C15.fmt(REF_FAR), len(storm["storm_rows"]),
           ("; LAST at :%d pcn=%s" % (storm["storm_rows"][-1]["ln"],
                                      C15.fmt(storm["storm_rows"][-1]["pcn"])))
           if storm["storm_rows"] else ""))
    above = storm["far_above_split"]
    say("SPLIT", "ANY tail abort with `far >= %s` AND NOT the 1023 pair: x%d%s"
        % (C15.fmt(SPLIT), len(above),
           ("  <- %s" % ", ".join("%s at pc %s (: %d)"
                                  % (C15.fmt(r["far"]), C15.fmt(r["pc"]), r["ln"])
                                  for r in above[:6])) if above else ""))
    say("SPLIT", "(⚠ THE 1023 PAIR IS EXCLUDED: the storm's OWN rows sit at `far=%s`, which IS "
                 "at/above the split - that is the defect itself - so a guard that counted them "
                 "would fire on every capture carrying the signature.  `far` alone is NOT the "
                 "storm's identity; the pc/far PAIR is.  This line is the SPLIT-MOVED evidence.)"
        % C15.fmt(REF_FAR))

    # ---- THE TWO WITNESSES ----------------------------------------------------------------------
    seql = raw_lines_with(cap, UNDEF_SEQ_KEY)
    say("LIVE", "witness (i, liveness) `%s`: x%d row(s); witness (ii, PRIOR CONTROL) `%s`: x%d "
                "printf line(s) (of which parsed x%d); the body's `%s`: x%d line(s) (parsed x%d)"
        % (UNDEF_SEQ_KEY, len(rows), DISPATCH_MARK, len(disp_lines), len(disp), BODY_MARK,
           len(body_lines), len(body)))
    for i, txt in disp_bad[:4]:
        say("LIVE", "  ⚠ UNPARSED `%s` line at :%d - the row RAN but this reader cannot read its "
                    "slots: %s" % (DISPATCH_MARK, i, txt))
    for i, txt in body_bad[:4]:
        say("LIVE", "  ⚠ UNPARSED `%s` line at :%d: %s" % (BODY_MARK, i, txt))
    if body:
        say("LIVE", "the body's own results: %s"
            % ", ".join("result=%d x%d" % (k, v) for k, v in sorted(body_results(body).items())))
    say("LIVE", "`%s` max=%s; `%s`=%s; last `%s`=%s"
        % (WDT_PETS_KEY, C15.fmt(max_key(cap, WDT_PETS_KEY)), MEMSIZE_KEY,
           (raw_last(cap, MEMSIZE_KEY)[2] if raw_last(cap, MEMSIZE_KEY) else "absent"),
           TRUNC_MARKER, "PRESENT" if TRUNC_MARKER in cap.text else "ABSENT"))
    if storm["pcn_regressions"]:
        say("LIVE", "  ⚠ `%s` REGRESSED at line(s) %s - the abort ladder restarted (a second boot in "
                    "the same slot?); the tail is still taken by ORDINAL, never by position"
            % (ABT_PCN_KEY, storm["pcn_regressions"][:6]))

    # ---- PANIC ----------------------------------------------------------------------------------
    if pan["evidence"]:
        say("PANIC", "evidence: %s" % panic_why(pan))
    elif pan["stopped"]:
        say("PANIC", "NO design panic evidence, but the run STOPPED IN THE KERNEL: `%s`=%s (:%s)"
            % (PANIC_ENTERED_KEY, C15.fmt(pan["panic_entered"]), pan["panic_entered_line"]))
    else:
        say("PANIC", "no panic evidence and no kernel stop: vector-panic x%d, panic text x%d, "
                     "`%s`=%s" % (len(pan["vec_panic"]), len(pan["panic_text"]), PANIC_ENTERED_KEY,
                                  C15.fmt(pan["panic_entered"])))

    ctl = prior_controls(cap, disp, disp_lines, body, pan, rows)

    # =============================================================================================
    # 1. G-CTL - THE CONTROL, AND THE MANDATORY-FIRST CELL.
    #    With NEITHER a live channel NOR any IOS7LAB line, an ABSENCE of the storm is not a reading
    #    ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).  Two carve-outs, both POSITIVE
    #    observations that do not depend on any absence: (a) a PANIC, (b) a kernel-stop record.
    # =============================================================================================
    if not cap.toks and not disp_lines and not body_lines \
            and not pan["evidence"] and not pan["stopped"]:
        return verdict("G-CTL", "WITHHOLD (INSTRUMENT_UNSOUND).  The capture carries NO live-channel "
                                "token at all (`xnu_live_*` x0 - so neither the abort ladder nor the "
                                "`%s` liveness witness printed), NO `%s` line, and NO `%s` line.  "
                                "With NO channel live, the absence of the 1023 storm cannot be read "
                                "as STORM-GONE - a dead instrument produces exactly the same silence "
                                "(the 1018 defect read forward).  Fix the instrument (rebuild with "
                                "the split switch + the live witness armed) before adjudicating "
                                "anything.  This is a REFUSAL, never a pass."
                      % (UNDEF_SEQ_KEY, DISPATCH_MARK, BODY_MARK))

    # =============================================================================================
    # 2. PRIOR-RUNGS-REGRESSED - tested BEFORE the storm cells, and the reason is the whole rung.
    #    STORM-GONE is an ABSENCE claim.  An absence is only readable when a positive signal from the
    #    SAME run says the instrument was live.  Every one of the 1023 controls is such a signal, so
    #    a capture whose controls regressed has NO standing to report the storm as gone: it reports
    #    the regression, and NAMES it (a cell the reader cannot state is a status whose producer did
    #    not deliver one).
    # =============================================================================================
    if not ctl["ok"]:
        never_reached = (not disp_lines and not body_lines)
        return verdict("PRIOR-RUNGS-REGRESSED", "THE ARM'S SWITCH SET IS WRONG, NOT THE FIX.  The "
                                                "1023 controls do NOT all hold in this capture: %s.  "
                                                "So this capture CANNOT report the storm as gone "
                                                "(an absence with a dead control is not a reading) "
                                                "and it is NOT a STORM-PERSISTS reading either - "
                                                "PRIOR-RUNGS-REGRESSED dominates both.  Check "
                                                "`out/stage90/xnu_arm_entry-config.txt` for the FULL "
                                                "previous switch set plus `STAGE90_XNU_VM_MAX_SPLIT=1`."
                      "%s"
                      % ("; ".join(ctl["fails"]),
                         "  ⚠ BOTH of the row's own marks are ABSENT (not merely wrong), and that has "
                         "a SECOND possible cause this cell cannot separate from a regression: with "
                         "the ceiling moved, pid 1 may take a different path and never REACH the "
                         "`mach_port_construct` call at all.  Read WHICH control is missing before "
                         "believing the switch set - and note the live channel IS live here (its "
                         "tokens parsed), so the absence is not a dead console."
                         if never_reached else ""))

    # =============================================================================================
    # 3. STORM-PERSISTS - the 1023 signature recurs AT SCALE.  The patch did NOT reach the linked
    #    image (or the arm's switch set was not the fix's): the compiled ceiling is still
    #    0x80000000 and the same above-the-split pthread stack fault loops for ever.
    # =============================================================================================
    n_storm = len(storm["storm_rows"])
    if n_storm >= STORM_MIN_ROWS:
        r = storm["storm_rows"][-1]
        return verdict("STORM-PERSISTS", "THE FIX DID NOT REACH THE COMPILED IMAGE.  The 1023 storm "
                                         "signature is PRESENT at scale: %d tail abort row(s) whose "
                                         "OWN `pc` is %s (= the slide-corrected %s) AND whose own "
                                         "`far` is %s; last at :%d pcn=%s.  %s is a value the "
                                         "compiler folds into ONE call site, so a stale or "
                                         "half-rebuilt POOL shows up exactly here while every "
                                         "source-level check passes (records/1020-build-defect.txt).  "
                                         "READ `tools/check_vm_max_split.py <elf> --expect on` FIRST "
                                         "- the `mov r2,#-2147483648` at `task_create_internal` must "
                                         "have become `mov r2,#0x40000000` (or a `movw`+`movt` "
                                         "pair); a MISSING symbol or an undecodable immediate is a "
                                         "REFUSAL, never a pass.  Residency: `%s` max=%s."
                      % (n_storm, C15.fmt(storm["storm_pc"]), C15.fmt(REF_PC_OFFSET),
                         C15.fmt(REF_FAR), r["ln"], C15.fmt(r["pcn"]), REF_PC_NAME, WDT_PETS_KEY,
                         C15.fmt(max_key(cap, WDT_PETS_KEY))))

    # =============================================================================================
    # 4. STORM-MOVED - a storm exists ELSEWHERE.  The design's own guard: also fired when the
    #    1015-classified tail storm is NOT the 1023 pair (a different VA recurs at scale), or when
    #    any `abt_far >= 0x40000000` appears at all.  The design says of the latter: "any
    #    `abt_far >= 0x40000000` is itself notable (something other than the map produces VAs
    #    there)".
    # =============================================================================================
    other_va_scale = len(storm["tail_storm_rows"]) >= STORM_MIN_ROWS and storm["tail_va"] != REF_FAR
    if other_va_scale or storm["far_above_split"]:
        details = []
        if other_va_scale:
            details.append("1015's by-value tail storm recurs at `far=%s` x%d row(s), NOT the 1023 "
                           "pair (%s at %s)"
                           % (C15.fmt(storm["tail_va"]), len(storm["tail_storm_rows"]),
                              C15.fmt(REF_FAR), C15.fmt(storm["storm_pc"])))
        if storm["far_above_split"]:
            details.append("tail abort(s) with `far >= %s`: %s"
                           % (C15.fmt(SPLIT),
                              ", ".join("%s at pc %s (:%d pcn=%s)" % (
                                  C15.fmt(r["far"]), C15.fmt(r["pc"]), r["ln"], C15.fmt(r["pcn"]))
                                  for r in storm["far_above_split"][:8])))
        return verdict("STORM-MOVED", "A STORM EXISTS ELSEWHERE - NOT THE 1023 SIGNATURE.  %s.  The "
                                      "1023 pair (%s at %s) is NOT a storm here (x%d row(s)), so the "
                                      "fix is not contradicted - but the map was NOT the only "
                                      "producer of VAs at/above the split, and 1024-W's (U) "
                                      "registry is what NAMES the culprit.  Read the pc/far pairs "
                                      "above BEFORE re-pressing."
                      % ("; ".join(details), C15.fmt(REF_FAR), C15.fmt(storm["storm_pc"]), n_storm))

    # =============================================================================================
    # 5. STORM-GONE - the 1023 signature is ABSENT and the controls SAY THE CONSOLE WAS LIVE.
    #    Report the NEW frontier: the last non-storm abt_pc (slide-corrected), its abt_far, the last
    #    user SVC record, the last stall pc.
    # =============================================================================================
    if n_storm == 0 and (storm["slide"] is not None or not storm["abt_rows"]) \
            and TRUNC_MARKER in cap.text:
        fr = new_frontier(cap, storm, pan)
        lines = []
        if fr["last_pc"] is not None:
            lines.append("the LAST NON-STORM abort: pc=%s%s at far=%s (:%d at pcn=%s)"
                         % (C15.fmt(fr["last_pc"]),
                            ("  <- FILE OFFSET %s" % C15.fmt(fr["last_pc_offset"]))
                            if fr["last_pc_offset"] is not None else
                            "  (a KERNEL pc - not slide-corrected)",
                            C15.fmt(fr["last_far"]), fr["last_line"], C15.fmt(fr["last_pcn"])))
        else:
            lines.append("the LAST NON-STORM abort: NONE - this capture carries ZERO abort rows; "
                         "the NEW frontier is BELOW the abort ladder's first rung (read the user SVC "
                         "and stall records instead)")
        if fr["usvc"] is not None:
            lines.append("the LAST USER SVC: `%s`=%s at :%s, `%s`=%s, `%s`=%s, `%s`=%s"
                         % (USVC_NUM_KEY, C15.fmt(fr["usvc"].get(USVC_NUM_KEY)),
                            fr["usvc"].get(USVC_NUM_KEY + "_line"),
                            USVC_PC_KEY, C15.fmt(fr["usvc"].get(USVC_PC_KEY)),
                            USVC_LR_KEY, C15.fmt(fr["usvc"].get(USVC_LR_KEY)),
                            USVC_PID_KEY, C15.fmt(fr["usvc"].get(USVC_PID_KEY))))
        else:
            lines.append("the LAST USER SVC: NOT PUBLISHED in this capture")
        if fr["stall"] is not None:
            spc = fr["stall"].get(STALL_PC_KEY)
            soff = (spc - storm["slide"]) if (spc is not None and storm["slide"] is not None
                                              and spc < SPLIT) else None
            lines.append("the LAST stall: pc=%s%s (:%s), lr=%s, sp=%s"
                         % (C15.fmt(spc),
                            ("  <- FILE OFFSET %s" % C15.fmt(soff)) if soff is not None
                            else "  (a KERNEL pc - not slide-corrected)",
                            fr["stall"].get(STALL_PC_KEY + "_line"),
                            C15.fmt(fr["stall"].get(STALL_LR_KEY)),
                            C15.fmt(fr["stall"].get(STALL_SP_KEY))))
        else:
            lines.append("the LAST stall: NOT PUBLISHED in this capture")
        ev = " and ".join(name for name, _ok, _obs in ctl["checks"])
        return verdict("STORM-GONE", "THE 1023 STORM SIGNATURE IS ABSENT AND THE CONSOLE WAS LIVE.  "
                                     "The 1023-keyed signature (%s at %s) appears x0 in the tail - "
                                     "no cluster of `abt_far == %s`, and the prior rungs' POSITIVE controls all "
                                     "hold in the SAME capture (%s).  Aborts published: x%d (max "
                                     "pcn=%s).  THE NEW FRONTIER:\n    %s\n    %s\n    %s\n  This "
                                     "reader makes NO claim about the new frontier beyond reporting "
                                     "it, and it does NOT pick the next rung.  Residency: `%s` "
                                     "max=%s."
                      % (C15.fmt(storm["storm_pc"]), C15.fmt(REF_FAR), C15.fmt(REF_FAR), ev,
                         storm["n_aborts"], C15.fmt(storm["max_pcn"]), lines[0], lines[1], lines[2],
                         WDT_PETS_KEY, C15.fmt(max_key(cap, WDT_PETS_KEY))))

    # =============================================================================================
    # 6. NO-CELL - the signature is present but BELOW the scale threshold, or the storm is
    #    unreadable (no slide => no identity).  NAME what was present; NEVER fabricate a verdict.
    # =============================================================================================
    failed = []
    if storm["slide"] is None and storm["abt_rows"]:
        failed.append("the slide is UNREADABLE (no `%s` for pid 1 and no `%s` to infer one) while "
                      "abort row(s) WERE published - the 1023 pc cannot be computed, so the "
                      "signature cannot be counted and an absent storm is not a reading; this is "
                      "1015's V-G5 (MEASUREMENT LOST) read the right way round"
                      % (MAP_SLIDE_MARK, USVC_PC_KEY))
    if TRUNC_MARKER not in cap.text:
        failed.append("the terminal `%s` marker is ABSENT - the log was CUT, and a cut log is "
                      "exactly what would impersonate a stopped storm (the 1015b discipline: a "
                      "missing terminal marker WITHHOLDS the absence cell)"
                      % TRUNC_MARKER)
    if 0 < n_storm < STORM_MIN_ROWS:
        failed.append("the 1023-keyed signature x%d row(s) - PRESENT but BELOW the x%d scale "
                      "threshold: neither a storm (STORM-PERSISTS) nor an absence (STORM-GONE)"
                      % (n_storm, STORM_MIN_ROWS))
    return verdict("NO-CELL", "NO PRE-REGISTERED CELL FIRES - nothing is concluded.  PRESENT: `%s` "
                              "x%d, `%s` x%d, `%s` x%d, 1023-keyed signature x%d, tail x%d.  "
                              "PREDICATES THAT FAILED: %s.  Do NOT read this as a pass: it means "
                              "this capture is outside the pre-registered table, so the rung must "
                              "be described in a new cell BEFORE its data is interpreted "
                              "([[mi4-measurement-defects]])."
                  % (ABT_PCN_KEY, storm["n_aborts"], DISPATCH_MARK, len(disp_lines), UNDEF_SEQ_KEY,
                     len(rows), n_storm, len(storm["tail"]),
                     "; ".join(failed) if failed else "(none - a reader defect)"))


def body_results(body):
    """The body's own `result=` values, counted (the row's VERDICT histogram)."""
    out = {}
    for r in body:
        out[r["result"]] = out.get(r["result"], 0) + 1
    return out


def undef_rows(cap):
    """The live undef witness's rows, one per `xnu_live_undef_seq`."""
    rows, cur = [], None
    for line_no, key, _raw, val in cap.toks:
        if key == UNDEF_SEQ_KEY:
            cur = {"line": line_no, "seq": val, "pc": None}
            rows.append(cur)
        elif cur is not None and key == UNDEF_PC_KEY:
            cur["pc"] = val
    return rows


# ===================================================================================================
# THE SELF-TEST.  Every fixture is SYNTHETIC, generated in a fresh tempfile.mkdtemp().
# ---------------------------------------------------------------------------------------------------
# ⚠ A SELFTEST THAT CANNOT FAIL IS WORTHLESS (the m1015b lesson), so this one is built to be able to
# fail in BOTH directions: every cell gets a fixture that MUST reach it, and the negative fixtures
# (the truncated capture, the dead channel, the regressed control) MUST NOT reach STORM-GONE.  The
# 1023 baseline is ALSO run through `adjudicate()` end to end and MUST read STORM-PERSISTS.
# ===================================================================================================
def _mk(tmpdir, name, lines):
    path = os.path.join(tmpdir, name)
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def self_test():
    import tempfile
    ok = True
    tmpdir = tempfile.mkdtemp(prefix="check1024-selftest-")
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
            print("  [1024] SELFTEST-FAIL %s: expected %s, got %s" % (name, expected, got))
            ok = False

    SLIDE = 0x01BAC000
    STORM_PC = 0x39DED790          # the 1023 capture's OWN raw pc, typed from the record
    STORM_FAR = 0x40083008         # the 1023 capture's OWN `far`, typed from the record
    # ⚠ THE FIXTURE'S OWN ARITHMETIC CHECK, AND IT IS THE POINT OF THE WHOLE BLOCK: a fixture that
    # DERIVES its expectation from the constant it is testing cannot detect that constant being
    # wrong (MEASURED: mutating `REF_FAR` by one byte passed every cell before this check existed -
    # the m1015b lesson, "a selftest that cannot fail is worthless").  So the identity is stated
    # TWICE, independently: once as the module's slide-invariant OFFSET, once as the record's OWN
    # raw numbers, and their arithmetic must agree before any cell is read.
    for _what, _lhs, _rhs in (("REF_PC_OFFSET + SLIDE == the 1023 raw pc",
                               REF_PC_OFFSET + SLIDE, STORM_PC),
                              ("REF_1023_PC - REF_1023_SLIDE == REF_PC_OFFSET",
                               REF_1023_PC - REF_1023_SLIDE, REF_PC_OFFSET),
                              ("REF_1023_PC == the 1023 raw pc", REF_1023_PC, STORM_PC),
                              ("REF_1023_SLIDE == the fixture's slide", REF_1023_SLIDE, SLIDE),
                              ("REF_FAR == the 1023 `far`", REF_FAR, STORM_FAR)):
        if _lhs != _rhs:
            print("  [1024] SELFTEST-FAIL IDENTITY: %s is FALSE (0x%08x != 0x%08x)"
                  % (_what, _lhs, _rhs))
            ok = False
    SLIDE_LINE = ("IOS7SHREG map_slide pid=1 fd=0 count=4 mappings=0x2bdd2848 slide=0x%x "
                  "slide_start=0x3ddaa000 size=0x00089000" % SLIDE)
    MEM = "MI4IOS6_STAGE90_XNU xnu_entry_args_memSize=0x1e400000"
    END = "No errors detected"

    def disp(i=0):
        return ("IOS7LAB trap24 frame r0=00000007 r1=00800000 r2=00000000 r3=00000003 "
                "r4=00800100 r5=00000000 r8=00000000")

    def body(result, name=0x00800100):
        return ("IOS7LAB port_construct flags=12 qlimit=6 context=00000000:15d32030 result=%d "
                "name=%x bypass_hints=0" % (result, name))

    def prior(n_disp=4, n_body=4, undef=False, panic=False):
        out = [SLIDE_LINE, MEM]
        for _ in range(n_disp):
            out.append(disp())
        for _ in range(n_body):
            out.append(body(0))
        if undef:
            out.append(" xnu_live_undef_seq=0x00000001")
        if panic:
            out.append("panic: fleh_vectors: exception in exception vectors, 0x00000081")
        return out

    def abt(pcn, far, pc, fsr=0x00000007):
        """ONE abort row, in the recorder's OWN key order (`_pcn` then `_pcfar`/`_pc`/`_fsr`)."""
        return ["xnu_live_abt_pcn=0x%08x" % pcn,
                "xnu_live_abt_pcfar=0x%08x" % far,
                "xnu_live_abt_far=0x%08x" % far,
                "xnu_live_abt_pc=0x%08x" % pc,
                "xnu_live_abt_fsr=0x%08x" % fsr]

    def storm_rows(n, first=0x800, last=None):
        """`n` storm rows walking the ordinal ladder like the real capture does."""
        out = []
        for k in range(n):
            out += abt(first + k, STORM_FAR, STORM_PC)
        return out

    USVC = ["xnu_live_usvc_num=0x00000152", "xnu_live_usvc_pc=0x2beb9328",
            "xnu_live_usvc_lr=0x2bea8c9f", "xnu_live_usvc_pid=0x00000001"]
    STALL = ["xnu_live_stall_pc=0x8001cc2d", "xnu_live_stall_lr=0x804671d0",
             "xnu_live_stall_sp=0xcfdb3ef0"]

    # ================= G-CTL =================
    want("G-CTL-empty", [], "G-CTL")
    want("G-CTL-no-channel", ["MI4IOS6_STAGE90_XNU booting", MEM], "G-CTL")
    # A capture that ENDED early (its own terminal line, then nothing): a truncated log.  No live
    # channel at all AND no IOS7LAB line - the fail-closed case.  NEVER a pass.
    want("G-CTL-truncated", [SLIDE_LINE, MEM, END], "G-CTL")
    # ⚠ The SAME truncation plus ONE live-channel token: the channel IS live, so the absence of the
    # 1023 controls is a READING - the regression cell, not the withhold.
    want("G-CTL-live-but-no-control", [SLIDE_LINE, MEM, " xnu_live_wdt_pets=0x00000001"],
         "PRIOR-RUNGS-REGRESSED")
    # A capture carrying ONLY the live abort ladder and no prior control: the channel is live, the
    # controls regressed (the 1018 defect read forward - a live instrument with a dead row).
    want("REGRESSED-storm-only-no-control", storm_rows(5), "PRIOR-RUNGS-REGRESSED")

    # ================= PRIOR-RUNGS-REGRESSED =================
    # The dispatch witness regressed (x2, not x4) while NO storm is present: dominated by the
    # regression - never read as STORM-GONE.
    want("REGRESSED-fewer-dispatch", prior(n_disp=2) + abt(0x800, 0x2bee8004, 0x2beb7fe4),
         "PRIOR-RUNGS-REGRESSED")
    # The body regressed (result=4, not 0) - the wire was refused again.
    want("REGRESSED-body-refused",
         [SLIDE_LINE, MEM] + [disp()] * 4 + [body(4)] * 4 + abt(0x800, 0x2bee8004, 0x2beb7fe4),
         "PRIOR-RUNGS-REGRESSED")
    # THE UNDEF WITNESS CAME BACK (>0): a user udf storm is live again - the 1023 controls failed.
    want("REGRESSED-undef-returned", prior(undef=True) + abt(0x800, 0x2bee8004, 0x2beb7fe4),
         "PRIOR-RUNGS-REGRESSED")
    # A PANIC: the prior control "zero panics" regressed.
    want("REGRESSED-panic", prior(panic=True), "PRIOR-RUNGS-REGRESSED")

    # ================= STORM-PERSISTS =================
    want("PERSISTS-1023-pair", prior() + storm_rows(10, first=0x800), "STORM-PERSISTS")
    # The storm ALSO being the 1015-classified tail does not change the cell.
    want("PERSISTS-with-pcn-tail",
         prior() + storm_rows(10, first=0x800) + abt(0x400, STORM_FAR, STORM_PC),
         "STORM-PERSISTS")
    # A storm at a DIFFERENT far with the same pc: still not the 1023 pair -> below threshold for
    # PERSISTS, but it IS a storm elsewhere.
    want("PERSISTS-needs-both-fields",
         prior() + [r for k in range(5) for r in abt(0x800 + k, 0x40100000, STORM_PC)],
         "STORM-MOVED")

    # ================= STORM-MOVED =================
    # A storm EXISTS ELSEWHERE: the 1015 by-value tail storm recurs at a NON-1023 far, while the
    # 1023 pair is x0.
    want("MOVED-other-va-storm",
         prior() + [r for k in range(8) for r in abt(0x800 + k, 0x3A1141E8, 0x2BED61A0)],
         "STORM-MOVED")
    # ANY `far >= 0x40000000` is itself notable, even a single row.
    want("MOVED-one-above-split",
         prior() + abt(0x800, STORM_FAR, 0x2beb7fe4), "STORM-MOVED")
    want("MOVED-one-above-split-kernel-far",
         prior() + abt(0x800, 0xCFDBD000, 0x80490F30, fsr=0x00000805), "STORM-MOVED")

    # ================= STORM-GONE =================
    # The decisive fixture: the 1023 pair x0, aborts present BELOW the split, all prior controls live.
    want("GONE-clean", prior() + abt(0x800, 0x2bee8004, 0x2beb7fe4) + USVC + STALL + [END],
         "STORM-GONE")
    want("GONE-no-aborts-at-all", prior() + USVC + STALL + [END], "STORM-GONE")
    # ⚠ The MAP HAS NOTHING TO DO WITH THE OFFSET: a different, unrelated abort at a far below the
    # split is a GONE reading (the design keys on the ABSENCE of a storm above the split, never on a
    # re-used absolute address).
    want("GONE-other-far-below-split",
         prior() + abt(0x800, 0x397D3F86, 0x39DE5FE4) + abt(0x900, 0x1000, 0x80490F30) + [END],
         "STORM-GONE")
    # ⚠ THE LADDER'S REACH IS NOT THE GATE, AND THIS FIXTURE IS THE REASON.  A working fix means the
    # abort ordinal NEVER climbs to the storm's own band (in 1023 the storm alone drove it to
    # 0x100000); requiring a tail row here would make the PASS UNREACHABLE in exactly the run the
    # fix is for.  The gate that replaces it is the terminal marker (the log ENDED, not was cut).
    want("GONE-shallow-ladder", prior() + abt(0x10, 0x2bee8004, 0x2beb7fe4) + [END], "STORM-GONE")

    # ================= NO-CELL =================
    # The signature present but BELOW the scale threshold: neither a storm nor an absence.
    want("NO-CELL-below-threshold", prior() + abt(0x800, STORM_FAR, STORM_PC)
         + abt(0x801, STORM_FAR, STORM_PC), "NO-CELL")
    # The slide is unreadable => the identity cannot be computed at all.
    want("NO-CELL-no-slide",
         [MEM] + [disp()] * 4 + [body(0)] * 4 + abt(0x800, 0x2bee8004, 0x2beb7fe4), "NO-CELL")
    # ⚠ THE LOG WAS CUT (its terminal marker is gone) while the controls are live.  An absent storm
    # in a CUT log is not a reading - this is the fixture that would impersonate STORM-GONE if the
    # marker were not required.
    want("NO-CELL-log-cut", prior() + abt(0x800, 0x2bee8004, 0x2beb7fe4), "NO-CELL")

    # ================= the BASELINE section (never a cell) =================
    base_lines = prior() + storm_rows(10, first=0x800)
    p = _mk(tmpdir, "selfbase.txt", base_lines)
    cap = C15.Capture(p)
    cap.path = p
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        got = adjudicate(cap, cap, p)
    cases.append(("BASELINE-refuses-self", got, "STORM-PERSISTS"))
    if "REFUSING the baseline" not in buf.getvalue():
        print("  [1024] SELFTEST-FAIL BASELINE-refuses-self: the reader did not refuse a "
              "self-baseline")
        ok = False
    if got != "STORM-PERSISTS":
        print("  [1024] SELFTEST-FAIL BASELINE-refuses-self: cell moved to %s" % got)
        ok = False

    # ================= THE REAL 1023 CAPTURE, end to end =================
    # The rung's own negative control, and the ONLY fixture here that is not synthetic.  If it is on
    # disk it MUST read STORM-PERSISTS; if it is not, the check is SKIPPED and SAID SO (never
    # silently passed).
    real = DEFAULT_BASELINE
    print("\n  == SELF-TEST ==")
    if os.path.isfile(real):
        cap = C15.Capture(real)
        cap.path = real
        with contextlib.redirect_stdout(io.StringIO()):
            got = adjudicate(cap, None, None)
        cases.append(("REAL-1023-capture", got, "STORM-PERSISTS"))
        if got != "STORM-PERSISTS":
            print("  [1024] SELFTEST-FAIL REAL-1023-capture: expected STORM-PERSISTS, got %s" % got)
            ok = False
    else:
        print("  NOTE: the real 1023 capture is NOT on disk (%s) - the end-to-end control is "
              "SKIPPED, not passed" % real)

    bad = [(n, g, e) for n, g, e in cases if g != e]
    print("  %d case(s), %d failed" % (len(cases), len(bad)))
    for n, g, e in bad:
        print("    FAIL: %s (got %s, want %s)" % (n, g, e))
    got_cells = {g for _n, g, _e in cases}
    missing = [c for c in CELLS if c not in got_cells]
    if missing:
        print("    FAIL: no fixture reached %s" % ", ".join(missing))
    # ⚠ THE TALLY MUST BE LOAD-BEARING ON EVERY FAILURE PATH, NOT ONLY ON THE CASE TABLE.  The
    # identity guard and the baseline-refusal check fail OUTSIDE `cases`, and a verdict that ignored
    # them would make those guards decorative - a selftest that cannot fail (the m1015b lesson, one
    # level up).  MEASURED: with `REF_1023_SLIDE` mutated by 1, the reader printed its IDENTITY-FAIL
    # lines and still exited 0, because the verdict read `bad` alone.
    good = ok and not bad and not missing
    print("  SELF-TEST: %s" % ("PASS" if good else "FAIL"))
    return 0 if good else 1


# ===================================================================================================
def main():
    ap = argparse.ArgumentParser(description="1024 VM_MAX_ADDRESS/TTBR0-split capture reader")
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--baseline", help="a capture to compare against (default: the 1023 recovery, "
                                       "when on disk)")
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
        say("BASE", "no --baseline given; using the 1023 recovery on disk (%s)" % cand)
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
    print("\n[1024] VERDICT: %s" % DISPLAY.get(cell, cell))
    return 0


if __name__ == "__main__":
    sys.exit(main())