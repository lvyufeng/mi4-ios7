#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_1030_capture.py -- the 1030 press's capture reader (PROBE THE WRITER'S DERIVATION).

WHAT 1029 DECIDED (the premise this checker acts on)
====================================================
1029 was a PROBE and it read **READER-NAMED / TOP-CONFIRMED BY VALUE** on 2026-10-17
(records/1029-press-read.txt, capture `recovered-unknown-arm-20261017-052951-last_kmsg.txt`):

    xnu_live_rdr_far               = 0x2bd39000
    xnu_live_rdr_ustack            = 0x2bd38000
    xnu_live_rdr_far_minus_ustack  = 0x00001000
    xnu_live_rdr_blk_hi            = 0x2bd38000   <- == ustack: the block did NOT grow
    xnu_live_rdr_blk_lo            = 0x2bd37f44
    xnu_live_rdr_blk_bytes         = 188
    xnu_live_rdr_entry_at_hit      = 0            <- far covered by NO entry
    xnu_live_ustack_rc             = 0            <- the FIXED allocate SUCCEEDED
    Controls: launchd_reached=True, trap24=8, port_construct(result=0)=8, abt_pc_live=12, panics=0.

`entry_at_hit == 0` (far unowned) + `far == the region's EXCLUSIVE TOP` (in EVERY measured run --
records/1030-audit.txt) => the fault is a **boundary write AT the region's moving top**.

WHAT 1030 IS -- AND WHY IT IS A PROBE, NOT A FIX
================================================
1030's FIRST shape (a base-move fix) was **REFUTED BEFORE BUILD** (docs/1030-design.md section 0b,
records/1030-audit.txt CHECK 1): base-down and extent-up CANCEL (`round_page(size + PAGE) == size +
PAGE`, so `top = (user_stack - size - PAGE) + (size + PAGE) = user_stack` -- the region's exclusive top
is UNCHANGED). And the population shows `far == the region's exclusive top` in all 61 far-rows, so NO
allocation-geometry change can help: raising the top raises `far` (1028 proved it, page-exact);
lowering it lowers `far`. The fix must be at the WRITER's derivation.

The writer (records/1030-audit.txt, lead's disassembly) is
`/usr/lib/libobjc.dylib + 0x14756`, `str.w r2,[r4],#4` -- a post-increment cursor store, `r4 == far`,
inside a shared-cache / objc table REBASE (dyld slide fixup) writing into a CALLER-provided buffer.
`r4` is the CALLER's 4th argument (the function body does `mov r4, r3`), so the boundary decision is in
the CALLER. 1030 publishes, ON THE launchctl[2] USERMODE DATA-ABORT FAILURE ARM (inside 1025's publisher,
after 1026/1027/1029's blocks), the registers and process fields that separate the candidate
derivations (tools patch_d13_writer_probe.py, behind ONE new switch `STAGE90_XNU_WRITER_PROBE`):

    xnu_live_wrp_r4            the faulting cursor (r4 == far)
    xnu_live_wrp_sp            the faulting thread's sp
    xnu_live_wrp_r4_minus_sp   r4 - sp            <- the sp-relative tell (W-A)
    xnu_live_wrp_userstack     thread_userstack / p->user_stack   <- the region-top tell (W-B)
    xnu_live_wrp_pc            the faulting pc (slid)
    xnu_live_wrp_r3            r3 (the caller's OTHER output cursor arg)
    xnu_live_wrp_r6            r6 (the second output cursor)
    xnu_live_wrp_r12           r12 (the 16 KiB VLA/copy size observed at 1029)
    xnu_live_wrp_block_bytes   the argv/env block byte length

CELLS (pre-registered; docs/1030-design.md section 2)
=====================================================
  W-A-NAMED  `r4 - sp` is a SMALL CONSTANT frame offset (the store's base is the thread's own stack
             pointer) => the writer's frame sits past the advertised stack top; the initial stack
             handed to the thread is TOO SHALLOW. The fix (if any) is in the exec's initial-thread
             stack / frame size, NOT the region geometry.
  W-B-NAMED  `r4 == thread_userstack` (or the saved region top) => the writer deliberately stores AT
             the advertised stack top -- a stack-LIMIT / canary store; the fault is the intended limit
             check firing one page early.
  W-OTHER    `r4` is NEITHER sp-relative NOR the region top => name what it is; **do NOT pick a fix**
             (fail closed). records/1030-audit.txt section 6: the next step is to disassemble and
             single-step the writer frame by frame -- not another kernel-side guess.
  REGRESSION launchd not reached, or trap24/port_construct marks vanish, or a panic appears, or the
             1023 pthread storm signature is back -> WITHHOLD; the arm's switch set is wrong.
  G-CTL      no capture NEWER than the boot epoch, or no controls live at all -> WITHHOLD.
             A resident rung that does not return keeps no /proc/last_kmsg of its own
             ([[mi4-last-kmsg-reader-carrier]]); the press stamps its boot epoch and refuses an older
             capture ([[mi4-stale-slot-impersonates-a-reading]]).

NEVER A NEGATIVE.  A cell is decided ONLY by a value PRESENT in a capture.  The ABSENCE of an
`xnu_live_wrp_*` row means the probe did not RUN -- that is W-OTHER-missing (fail closed), never a
statement that some derivation "is not the writer's" ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).

WIRE-UP: the key list is `WRP_KEYS` below -- adjust in ONE place (the tool is kept easy to re-point).

USAGE
=====
  check_1030_capture.py <capture.txt> [--selftest]
"""
import argparse
import os
import re
import sys
import tempfile

STACK_LO = 0x2BD00000
STACK_HI = 0x2BE00000

# W-A's "small constant frame offset" ceiling: the observed value is `far - sp == 0x1F8C` (8076 B,
# records/1030-audit.txt), and the region is 1 MiB (= MAXSSIZ). A frame offset up to 64 KiB is
# "sp-relative frame"; anything larger is not a plausible single-frame offset and must not be named W-A.
FRAME_OFF_MAX = 0x10000

# --- THE PROBE'S ROW KEYS (adjust HERE if audit1030 finalises a different list) --------------------
WRP_KEYS = (
    "xnu_live_wrp_r4",
    "xnu_live_wrp_sp",
    "xnu_live_wrp_r4_minus_sp",
    "xnu_live_wrp_userstack",
    "xnu_live_wrp_pc",
    "xnu_live_wrp_r3",
    "xnu_live_wrp_r6",
    "xnu_live_wrp_r12",
    "xnu_live_wrp_block_bytes",
)

# the 1029 reader discriminator keys (kept so the PARENT re-reading still fires)
RDR_KEYS = (
    "xnu_live_rdr_far",
    "xnu_live_rdr_ustack",
    "xnu_live_rdr_far_minus_ustack",
    "xnu_live_rdr_blk_hi",
    "xnu_live_rdr_blk_lo",
    "xnu_live_rdr_blk_bytes",
    "xnu_live_rdr_argc",
    "xnu_live_rdr_entry_at_hit",
    "xnu_live_rdr_entry_at_lo",
    "xnu_live_rdr_entry_at_hi",
)

# the 1028/1027/1026/1025 discriminator keys (kept so the parent re-reading still fires)
ENTRY_KEYS = (
    "xnu_live_abt_lookup_far",
    "xnu_live_abt_entry_lo",
    "xnu_live_abt_entry_hi",
    "xnu_live_abt_e2_lo",
    "xnu_live_abt_e2_hi",
    "xnu_live_abt_far_in_map",
    "xnu_live_abt_map",
    "xnu_live_abt_taskmap",
    "xnu_live_abt_ustack",
)

KERN_NAMES = {
    1: "KERN_INVALID_ADDRESS",
    2: "KERN_PROTECTION_FAILURE",
    3: "KERN_NO_SPACE",
    5: "KERN_FAILURE",
    14: "KERN_MEMORY_ERROR",
}


def say(tag, msg=""):
    line = f"[{tag}]"
    if msg:
        line += " " + msg
    print(line)


def verdict(cell, msg):
    say(cell, msg)
    return cell


def raw_lines(cap):
    with open(cap, "r", errors="replace") as f:
        return f.readlines()


def kv_values(lines, key):
    out = []
    rx = re.compile(re.escape(key) + r"=([^\s\x1b\[]+)")
    for ln in lines:
        for m in rx.finditer(ln):
            out.append(m.group(1))
    return out


def kv_last(lines, key):
    vs = kv_values(lines, key)
    return vs[-1] if vs else None


def parse_int(v):
    if v is None:
        return None
    s = "".join(ch for ch in v if ch in "0123456789abcdefABCDEFxX-")
    if not s:
        return None
    try:
        return int(s, 0)
    except (ValueError, TypeError):
        try:
            return int(s, 16)
        except (ValueError, TypeError):
            return None


def group_rows(lines, keys, require):
    """EVERY published row carrying `require`, grouped across blank-separated probe lines.

    The console adds its OWN break after each kernel `printf(...\\n")`, so a BLANK line sits between
    every key and MUST NOT end the group (measured).  Only a line with CONTENT and none of `keys`
    ends the group.  Matching is by SUBSTRING (a console prefix / ANSI colour is harmless).
    """
    key_rx = [(k, re.compile(re.escape(k) + r"=([^\s\x1b\[]+)")) for k in keys]
    rows = []
    cur = {}
    for ln in lines:
        got = False
        for k, rx in key_rx:
            m = rx.search(ln)
            if m is not None:
                cur[k] = m.group(1)
                got = True
        if got:
            continue
        if ln.strip() == "":
            continue
        if cur:
            rows.append(cur)
            cur = {}
    if cur:
        rows.append(cur)
    return [r for r in rows if r.get(require) is not None]


def wrp_rows(lines):
    return group_rows(lines, WRP_KEYS, "xnu_live_wrp_r4")


def rdr_rows(lines):
    return group_rows(lines, RDR_KEYS, "xnu_live_rdr_far")


def abt_entry_rows(lines):
    return group_rows(lines, ENTRY_KEYS, "xnu_live_abt_lookup_far")


def fault_rows(lines):
    """Every 1025 failed-fault publisher row: dict with keys code/far/dfsr/prot/pc/sp/pid."""
    suffix_rx = re.compile(r"xnu_live_abt_vmfkrv_(\w+)=([^\s\x1b\[]+)")
    code_rx = re.compile(r"xnu_live_abt_vmfkrv=([^\s\x1b\[]+)")
    rows = []
    cur = None
    for ln in lines:
        m = code_rx.search(ln)
        if m is not None:
            if cur is not None:
                rows.append(cur)
            cur = {"code": m.group(1)}
            for sm in suffix_rx.finditer(ln):
                cur[sm.group(1)] = sm.group(2)
            continue
        if cur is not None:
            got_ext = False
            for sm in suffix_rx.finditer(ln):
                cur[sm.group(1)] = sm.group(2)
                got_ext = True
            if got_ext:
                continue
            if ln.strip() == "":
                continue
            rows.append(cur)
            cur = None
    if cur is not None:
        rows.append(cur)
    return rows


def launchd_reached(lines):
    return any("launchd[1] has started up" in ln for ln in lines)


def storm_present(lines):
    for ln in lines:
        if "0x40083008" in ln:
            return True
    for v in kv_values(lines, "xnu_live_abt_pcn"):
        n = parse_int(v)
        if n is not None and n >= 0x8000:
            return True
    return False


def prior_controls(lines):
    trap24 = sum(1 for ln in lines if "IOS7LAB trap24 frame" in ln)
    pc0 = kv_values(lines, "xnu_live_abt_pc")
    undef_seq = kv_last(lines, "xnu_live_undef_seq")
    panics = sum(1 for ln in lines if "panic" in ln.lower() and "no panic" not in ln.lower())
    launchd = launchd_reached(lines)
    pc_res = sum(1 for ln in lines if "port_construct" in ln and "result=0" in ln)
    return {
        "trap24": trap24,
        "port_construct0": pc_res,
        "abt_pc_live": len(pc0),
        "undef_seq": undef_seq,
        "panics": panics,
        "launchd": launchd,
    }


def hx(v):
    n = parse_int(v)
    return "None" if n is None else f"0x{n:08x}"


def adjudicate(cap):
    lines = raw_lines(cap)
    ctl = prior_controls(lines)
    wrps = wrp_rows(lines)
    rdrs = rdr_rows(lines)
    entry = abt_entry_rows(lines)
    named = fault_rows(lines)

    say("READ", os.path.basename(cap))
    say("CTL", f"launchd_reached={ctl['launchd']} trap24={ctl['trap24']} "
               f"port_construct(result=0)={ctl['port_construct0']} abt_pc_live={ctl['abt_pc_live']} "
               f"undef_seq={ctl['undef_seq']} panics={ctl['panics']}")
    say("INSTR", f"wrp_rows={len(wrps)} rdr_rows={len(rdrs)} abt_entry_keys={len(entry)} "
                 f"vmfkrv_rows={len(named)}")

    # (1) G-CTL -- fail closed: no control live at all
    instrument_live = (ctl["launchd"] or ctl["trap24"] > 0 or ctl["abt_pc_live"] > 0)
    if not instrument_live and ctl["panics"] == 0:
        return verdict("G-CTL", "neither launchd-reached nor any prior control is live AND no panic "
                                "- the instrument was not sound; WITHHOLD (never a pass)")

    # (2) REGRESSION -- before reading anything about the writer
    if storm_present(lines):
        return verdict("REGRESSION", "the 1023 pthread storm signature is present (far=0x40083008 / "
                                     "abt_pcn>=0x8000) - the arm's switch set is wrong "
                                     "(STAGE90_XNU_VM_MAX_SPLIT=1). This is NOT a 1030 reading")
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        return verdict("REGRESSION", "launchd reached but NO trap24 / port_construct marks - the "
                                     "1023/1024 controls regressed")

    # (3) The writer probe's rows.
    if not wrps:
        # NO writer-probe row at all: the probe did not run.  NOT a negative about any derivation.
        return verdict("W-OTHER", "NO xnu_live_wrp_* row was captured, so the writer's derivation was "
                                  "NOT ASKED on this run (W-OTHER-missing). This is NOT a statement "
                                  "that r4 is un-derived: the absence of a row means the probe did not "
                                  "RUN. Check STAGE90_XNU_WRITER_PROBE=1 in the record, the linked "
                                  "image's xnu_live_wrp_r4= string, and that the boot reached the "
                                  "usermode DATA-abort failure arm at all "
                                  "([[mi4-silence-is-a-reading-only-if-success-is-silent]])")

    row = wrps[-1]
    r4 = parse_int(row.get("xnu_live_wrp_r4"))
    sp = parse_int(row.get("xnu_live_wrp_sp"))
    dsp = parse_int(row.get("xnu_live_wrp_r4_minus_sp"))
    ust = parse_int(row.get("xnu_live_wrp_userstack"))
    pc = parse_int(row.get("xnu_live_wrp_pc"))
    bby = parse_int(row.get("xnu_live_wrp_block_bytes"))

    if r4 is None:
        return verdict("G-CTL", f"a xnu_live_wrp_* row is present but r4 is unreadable "
                                f"(xnu_live_wrp_r4={row.get('xnu_live_wrp_r4')}) - WITHHOLD")

    # Derive `r4 - sp` from its own row when published, else compute it (both are honest).
    delta = dsp
    if delta is None and sp is not None:
        delta = r4 - sp

    shape = (f"row[{len(wrps)}] r4={hx(row.get('xnu_live_wrp_r4'))} "
             f"sp={hx(row.get('xnu_live_wrp_sp'))} "
             f"r4-sp={hx(row.get('xnu_live_wrp_r4_minus_sp'))} "
             f"userstack={hx(row.get('xnu_live_wrp_userstack'))} "
             f"pc={hx(row.get('xnu_live_wrp_pc'))} r3={hx(row.get('xnu_live_wrp_r3'))} "
             f"r6={hx(row.get('xnu_live_wrp_r6'))} r12={hx(row.get('xnu_live_wrp_r12'))} "
             f"block_bytes={bby}")

    # (3a) W-B FIRST: r4 == the advertised stack top (a stack-limit / canary store).  This is the more
    # specific tell and is checked before the sp-relative one (r4 could be BOTH if sp==ustack... but
    # then it is the region top, which is the W-B reading).
    if ust is not None and r4 == ust:
        return verdict("W-B-NAMED",
                       f"r4 == user_stack == {hx(row.get('xnu_live_wrp_userstack'))}: the faulting store "
                       f"targets the ADVERTISED STACK TOP itself (thread_userstack / p->user_stack). "
                       f"Combined with 1029's `far == the region's exclusive top`, this is a "
                       f"STACK-LIMIT / canary store: the writer deliberately writes at the advertised "
                       f"top, and the fault is the intended limit check firing one page early "
                       f"(MAXSSIZ / LAB_USER_STACK off by a page). The fix is in the LIMIT accounting, "
                       f"NOT in the region geometry (records/1030-audit.txt: no allocation change can "
                       f"help while far == the moving region top). {shape}")

    # (3b) W-A: r4 is sp-relative by a SMALL CONSTANT frame offset.
    if delta is not None and 0 < delta <= FRAME_OFF_MAX:
        return verdict("W-A-NAMED",
                       f"r4 - sp == {hx(row.get('xnu_live_wrp_r4_minus_sp'))} (computed {hex(delta)}) "
                       f"-- a SMALL CONSTANT frame offset (<= 0x{FRAME_OFF_MAX:x}), i.e. the store's "
                       f"base is derived from the thread's OWN stack pointer. The writer's frame "
                       f"therefore sits PAST the advertised stack top because the INITIAL STACK handed "
                       f"to the thread is TOO SHALLOW (the block+frame chain is taller than the space "
                       f"the exec advertised). The fix (if any) is in the exec's initial-thread stack / "
                       f"frame size, NOT the region geometry. Note the region is 1 MiB (= MAXSSIZ) with "
                       f"~1016 KiB free BELOW sp (records/1030-audit.txt Q3), so this is NOT a "
                       f"stack-overflow into the guard: the cursor is laid out UPWARD from an "
                       f"sp-relative base. {shape}")

    # (3c) r4 == sp exactly (a zero-offset frame pointer) is also W-A (degenerate frame offset).
    if delta is not None and delta == 0:
        return verdict("W-A-NAMED",
                       f"r4 == sp exactly (r4 - sp == 0): the store's cursor IS the stack pointer -- "
                       f"the degenerate sp-relative frame. Same reading as W-A: the initial stack is "
                       f"too shallow for the writer's frame. {shape}")

    # (3d) W-OTHER -- neither sp-relative nor the region top.  Fail closed; name what IS there.
    if delta is None and ust is None:
        return verdict("W-OTHER",
                       f"a xnu_live_wrp_* row is present but NEITHER `r4 - sp` (sp absent) NOR "
                       f"`userstack` (absent) could be read, so neither W-A nor W-B is decidable. "
                       f"The missing conjunct is NAMED here: fail closed; do NOT pick a fix. {shape}")
    return verdict("W-OTHER",
                   f"r4 = {hx(row.get('xnu_live_wrp_r4'))} is NEITHER sp-relative "
                   f"(r4 - sp = {hx(row.get('xnu_live_wrp_r4_minus_sp'))}, "
                   f"{'absent' if delta is None else hex(delta)} > 0x{FRAME_OFF_MAX:x} or negative) "
                   f"NOR the advertised stack top (userstack = {hx(row.get('xnu_live_wrp_userstack'))}). "
                   f"So the writer's derivation is one we have NOT modelled. per "
                   f"records/1030-audit.txt section 6: the next step is to disassemble and single-step "
                   f"the writer (`/usr/lib/libobjc.dylib + 0x14756`, `str.w r2,[r4],#4`; the caller "
                   f"frame is at `lr`) frame by frame -- NOT another kernel-side guess. Do NOT pick a "
                   f"fix from this cell. {shape}")


# ---------------------------------------------------------------------------------------------------
def _mk(tmpdir, name, lines):
    p = os.path.join(tmpdir, name)
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    return p


def _blank_sep(pairs):
    out = []
    for ln in pairs:
        out.append(ln)
        out.append("")
    return out


def self_test():
    tmp = tempfile.mkdtemp(prefix="check1030-selftest-")
    fails = []

    def expect(cell, cap, label):
        got = adjudicate(cap)
        if got != cell:
            fails.append(f"{label}: got {got}, want {cell}")

    # the 1029 controls (all live) -- present in every non-GCTL fixture
    ctl = [
        "IOS7LAB trap24 frame",
        "IOS7LAB port_construct result=0",
        "*** launchd[1] has started up. ***",
    ]
    # 1028/1027/1026 parent entry row + 1025 parent row (the arm the probe rows ride on)
    vm = [
        "xnu_live_abt_vmfkrv=1",
        "xnu_live_abt_vmfkrv_far=0x2bd39000",
        "xnu_live_abt_vmfkrv_dfsr=0x807",
        "xnu_live_abt_vmfkrv_prot=write",
        "xnu_live_abt_vmfkrv_sp=0x2bd37074",
    ]
    entry = [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_e2_lo=0x2bc39000",
        "xnu_live_abt_e2_hi=0x2bd39000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd38000",
    ]

    # W-A-NAMED: r4 - sp == 0x1F8C (the observed 1029 frame offset), r4 != userstack.
    wrp_wa = [
        "xnu_live_wrp_r4=0x2bd39000",
        "xnu_live_wrp_sp=0x2bd37074",
        "xnu_live_wrp_r4_minus_sp=0x00001f8c",
        "xnu_live_wrp_userstack=0x2bd38000",
        "xnu_live_wrp_pc=0x3b71c756",
        "xnu_live_wrp_r3=0x2bd39999",
        "xnu_live_wrp_r6=0x00000000",
        "xnu_live_wrp_r12=0x00004000",
        "xnu_live_wrp_block_bytes=188",
    ]
    expect("W-A-NAMED", _mk(tmp, "wa.txt", ctl + vm + entry + wrp_wa), "W-A-NAMED")

    # W-A-NAMED (degenerate): r4 == sp exactly (zero frame offset)
    wrp_wa0 = list(wrp_wa)
    wrp_wa0[0] = "xnu_live_wrp_r4=0x2bd37074"
    wrp_wa0[2] = "xnu_live_wrp_r4_minus_sp=0x00000000"
    expect("W-A-NAMED", _mk(tmp, "wa0.txt", ctl + vm + entry + wrp_wa0), "W-A-NAMED-zero-offset")

    # W-B-NAMED: r4 == userstack
    wrp_wb = list(wrp_wa)
    wrp_wb[0] = "xnu_live_wrp_r4=0x2bd38000"
    wrp_wb[2] = "xnu_live_wrp_r4_minus_sp=0x00000f8c"
    expect("W-B-NAMED", _mk(tmp, "wb.txt", ctl + vm + entry + wrp_wb), "W-B-NAMED")

    # W-OTHER: r4 neither sp-relative (delta > FRAME_OFF_MAX) nor userstack
    wrp_wo = list(wrp_wa)
    wrp_wo[0] = "xnu_live_wrp_r4=0x2bd90000"
    wrp_wo[2] = "xnu_live_wrp_r4_minus_sp=0x00058f8c"
    expect("W-OTHER", _mk(tmp, "wo.txt", ctl + vm + entry + wrp_wo), "W-OTHER-far-offset")

    # W-OTHER: NO probe row at all -- the probe did not run. NEVER a negative.
    expect("W-OTHER", _mk(tmp, "norow.txt", ctl + vm + entry), "W-OTHER-no-probe-row")

    # REGRESSION: the 1023 storm is back
    expect("REGRESSION", _mk(tmp, "storm.txt", ctl + [
        "xnu_live_abt_far=0x40083008",
        "xnu_live_abt_pcn=0x00100000",
    ]), "REGRESSION-storm")

    # REGRESSION: launchd reached but no trap24/port_construct marks
    expect("REGRESSION", _mk(tmp, "reg.txt", [
        "*** launchd[1] has started up. ***",
    ] + vm + entry + wrp_wa), "REGRESSION-controls")

    # G-CTL: a dead console (no control live, no panic)
    expect("G-CTL", _mk(tmp, "dead.txt", [
        "bsd_init: done",
        "IOS7LAB shared region 0x2c000000..0x40000000",
    ]), "G-CTL-dead")

    # BLANK-SEPARATED keys (the measured console shape) must still group into ONE row.
    expect("W-A-NAMED", _mk(tmp, "blank.txt", _blank_sep(ctl + vm + entry + wrp_wa)),
           "blank-separated")

    # ANSI/console prefix on the values must not corrupt them
    ansi = ["\x1b[0m launchctl[2]: " + ln for ln in wrp_wa]
    expect("W-A-NAMED", _mk(tmp, "ansi.txt", ctl + vm + entry + ansi), "ansi-prefixed")

    # `r4 - sp` omitted from the capture: the checker must DERIVE it from r4/sp (both honest).
    wrp_nodelta = [ln for ln in wrp_wa if "xnu_live_wrp_r4_minus_sp" not in ln]
    expect("W-A-NAMED", _mk(tmp, "nodelta.txt", ctl + vm + entry + wrp_nodelta),
           "r4-sp-derived-from-keys")

    if fails:
        print("SELFTEST FAILED:")
        for f in fails:
            print("  " + f)
        return 1
    print("selftest PASS (11/11 cells)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="1030 writer-probe capture reader")
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv[1:])
    if args.selftest:
        return self_test()
    if not args.capture:
        ap.error("a capture path is required (or --selftest)")
    cell = adjudicate(args.capture)
    return 0 if cell not in ("G-CTL",) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))