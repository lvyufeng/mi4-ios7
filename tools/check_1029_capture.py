#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_1029_capture.py -- the 1029 press's capture reader (READ THE READER).

WHAT 1028 DECIDED (the premise this checker acts on)
====================================================
1028 (records/1028-press-read.txt) = FIX-NOOP, PAGE-EXACT.  The H2 headroom fix TOOK
(`xnu_live_ustack_rc=0`, the FIXED allocate succeeded) but the launchctl[2] data abort RECURRED
with its geometry MOVED by exactly one page:
    far - ustack = 0x1000          (the fault is one PAGE above the advertised stack top)
    far - sp     = 0x1F8C = 0xF8C + 0x1000   (every prior rung: 0xF8C, with far == ustack)
The block top and `sp` are unchanged (`ustack - sp = 0xF8C`).  So the failing write is NOT the
block's top word: the WRITER derives its store address FROM `p->user_stack` and writes one page
above it.  H2 (the block-top-flush mechanism) is REFUTED.

WHAT 1029 DOES -- AND WHAT THIS CHECKER READS
=============================================
1029 is a PROBE (report, do NOT re-fix): it publishes, in ONE row at the fault, the process's own
fields beside the fault VA (tools/patch_d13_reader_probe.py, behind STAGE90_XNU_READER_PROBE):
    xnu_live_rdr_far              dfar (page-aligned)          <- the faulting store's VA
    xnu_live_rdr_ustack           p->user_stack                <- the ADVERTISED top
    xnu_live_rdr_far_minus_ustack far - ustack                 <- the DERIVATION distance (want 0x1000)
    xnu_live_rdr_blk_hi           p->user_stack                <- the block's TOP bound
    xnu_live_rdr_blk_lo           user_stack - p_argslen       <- the block's LOW bound
    xnu_live_rdr_blk_bytes        p->p_argslen                 <- the block's recorded byte length
    xnu_live_rdr_argc             p->p_argc                    <- the recorded argc
    xnu_live_rdr_entry_at_hit     1 if far is INSIDE an entry   <- the READER-TOP tell
    xnu_live_rdr_entry_at_lo      covering entry of far, lo     (0/0 when far is unmapped)
    xnu_live_rdr_entry_at_hi      covering entry of far, hi

CELLS (pre-registered; docs/1029-design.md section 4)
=====================================================
  READER-NAMED     far_minus_ustack == 0x1000 AND entry_at_hit == 0 AND blk_hi == ustack
                   AND blk_bytes == (ustack - blk_lo) AND far == ustack + 0x1000.
                   BY VALUE: the store is one PAGE above the advertised top; the block's top bound
                   IS `p->user_stack` (so the block did NOT grow); `far` is covered by NO entry.
                   The writer's store address is a function of `p->user_stack` -> the derivation is
                   PROVEN.
  READER-UNKNOWN   any OTHER combination -> fail closed, and the missing conjunct is NAMED
                   (e.g. entry_at_hit == 1 names READER-BLOCK; far_minus_ustack != 0x1000 names the
                   fixed-VA hypothesis).  Do NOT pick a fix on READER-UNKNOWN.
  REGRESSION       launchd not reached, or trap24 rows vanish, or port_construct result=0 rows
                   vanish, or a panic appears -> WITHHOLD; the arm's switch set is wrong.
  G-CTL            no capture NEWER than the boot epoch, or no controls live at all -> WITHHOLD.
                   A resident rung that does not return keeps no /proc/last_kmsg of its own
                   ([[mi4-last-kmsg-reader-carrier]]); the press stamps its boot epoch and refuses
                   an older capture ([[mi4-stale-slot-impersonates-a-reading]]).

The 1025/1026/1027 re-reading (FAULT-NAMED / H2) is kept as the PARENT evidence: a 1029 row can
only be read if the fault it describes is the fault we know.

NEVER A NEGATIVE.  A cell is decided ONLY by a value PRESENT in a capture.  The ABSENCE of a row is
NOT evidence except "the probe did not run" (G-CTL).  `entry_at_hit=0` with `entry_at_lo/hi == 0` is
a POSITIVE reading (far is unmapped), not a missing one -- the PRINTED zero counts, an absent line
does not ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).

USAGE
=====
  check_1029_capture.py <capture.txt> [--selftest]
"""
import argparse
import os
import re
import sys
import tempfile

STACK_LO = 0x2BD00000
STACK_HI = 0x2BE00000
FAR_MINUS_USTACK_WANT = 0x1000

# the 1029 reader discriminator keys, in publication order
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

# the 1028 discriminator keys (kept so the parent H2 re-reading still fires)
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


def group_row(lines, keys, require):
    """The LAST published row carrying `require`, grouped across blank-separated probe lines.

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
    full = [r for r in rows if r.get(require) is not None]
    return full[-1] if full else (rows[-1] if rows else {})


def reader_row(lines):
    return group_row(lines, RDR_KEYS, "xnu_live_rdr_far")


def abt_entry_row(lines):
    return group_row(lines, ENTRY_KEYS, "xnu_live_abt_lookup_far")


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


def vmfkrv_stack_rows(lines):
    out = []
    for r in fault_rows(lines):
        far = parse_int(r.get("far"))
        if far is not None and STACK_LO <= far < STACK_HI:
            out.append((far, r))
    return out


def hx(v):
    n = parse_int(v)
    return "None" if n is None else f"0x{n:08x}"


def adjudicate(cap):
    lines = raw_lines(cap)
    ctl = prior_controls(lines)
    entry = abt_entry_row(lines)
    rdr = reader_row(lines)
    named = vmfkrv_stack_rows(lines)

    say("READ", os.path.basename(cap))
    say("CTL", f"launchd_reached={ctl['launchd']} trap24={ctl['trap24']} "
               f"port_construct(result=0)={ctl['port_construct0']} abt_pc_live={ctl['abt_pc_live']} "
               f"undef_seq={ctl['undef_seq']} panics={ctl['panics']}")
    say("INSTR", f"reader_row_keys={len(rdr)} abt_entry_keys={len(entry)} "
                 f"vmfkrv_stack_rows={len(named)}")

    # (1) G-CTL -- fail closed
    instrument_live = (ctl["launchd"] or ctl["trap24"] > 0 or ctl["abt_pc_live"] > 0)
    if not instrument_live and ctl["panics"] == 0:
        return verdict("G-CTL", "neither launchd-reached nor any prior control is live AND no panic "
                                "- the instrument was not sound; WITHHOLD (never a pass)")

    # (2) REGRESSION -- before reading anything about 1029
    if storm_present(lines):
        return verdict("REGRESSION", "the 1023 pthread storm signature is present (far=0x40083008 / "
                                     "abt_pcn>=0x8000) - the arm's switch set is wrong; this is NOT a "
                                     "1029 reading. Check STAGE90_XNU_VM_MAX_SPLIT=1 in the record.")
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        return verdict("REGRESSION", "launchd reached but NO trap24/port_construct marks - the "
                                     "1023/1024 controls regressed")

    # (3) the 1029 reader row -- 1029's OWN cell, read FIRST (the fault it describes must be the
    # known fault; the parent H2 re-reading below supplies that).
    if not rdr:
        # No 1029 row: fall through to the parent cells so a 1028-shaped capture reads as its own
        # H2/FIX-NOOP (the reader probe did not run on this arm: check STAGE90_XNU_READER_PROBE=1).
        return _parent_cells(lines, ctl, entry, named, rdr_absent=True)

    # A 1029 row is present.  Read it by value.
    far = parse_int(rdr.get("xnu_live_rdr_far"))
    ust = parse_int(rdr.get("xnu_live_rdr_ustack"))
    fmu = parse_int(rdr.get("xnu_live_rdr_far_minus_ustack"))
    bhi = parse_int(rdr.get("xnu_live_rdr_blk_hi"))
    blo = parse_int(rdr.get("xnu_live_rdr_blk_lo"))
    bby = parse_int(rdr.get("xnu_live_rdr_blk_bytes"))
    hoch = parse_int(rdr.get("xnu_live_rdr_entry_at_hit"))
    elo = parse_int(rdr.get("xnu_live_rdr_entry_at_lo"))
    ehi = parse_int(rdr.get("xnu_live_rdr_entry_at_hi"))

    shape = (f"far={hx(rdr.get('xnu_live_rdr_far'))} ustack={hx(rdr.get('xnu_live_rdr_ustack'))} "
             f"far-ustack={hx(rdr.get('xnu_live_rdr_far_minus_ustack'))} "
             f"blk=[{hx(rdr.get('xnu_live_rdr_blk_lo'))},{hx(rdr.get('xnu_live_rdr_blk_hi'))}) "
             f"blk_bytes={bby} argc={rdr.get('xnu_live_rdr_argc')} "
             f"entry_at_hit={hoch} entry_at=[{hx(rdr.get('xnu_live_rdr_entry_at_lo'))},"
             f"{hx(rdr.get('xnu_live_rdr_entry_at_hi'))})")

    # The instrument is only sound if the faulting process's fields were readable.
    if far is None or ust is None:
        return verdict("G-CTL", f"a 1029 reader row is present but far/ustack is unreadable: {shape} "
                                f"- WITHHOLD (never guess)")

    # verdict of the reader cells, checking the conjuncts IN ORDER and NAMING the first that fails
    if fmu is None or fmu != FAR_MINUS_USTACK_WANT:
        return verdict("READER-UNKNOWN",
                       f"far - ustack = {hx(rdr.get('xnu_live_rdr_far_minus_ustack'))} != "
                       f"0x{FAR_MINUS_USTACK_WANT:04x}: the store is NOT one page above the "
                       f"advertised top. This names the FIXED-VA-OR-OTHER-DERIVATION hypothesis (the "
                       f"reader is not +PAGE, or the fix's geometry changed again). Fail closed; do "
                       f"NOT pick a fix. {shape}")
    if hoch == 1:
        return verdict("READER-UNKNOWN",
                       f"entry_at_hit=1: the writer's store DID land INSIDE a mapped entry "
                       f"[{hx(rdr.get('xnu_live_rdr_entry_at_lo'))},"
                       f"{hx(rdr.get('xnu_live_rdr_entry_at_hi'))}). The off-the-end / "
                       f"derived-from-the-top framing is WRONG for this fault: this is the "
                       f"1013c/1015 'a mapped VA still failed the lookup' walker family. Fail "
                       f"closed; the NEXT rung instruments the walker (vm_map_lookup_locked, "
                       f"vm_map.c:8756), NOT the reader. {shape}")
    if bhi is None or bhi != ust:
        return verdict("READER-UNKNOWN",
                       f"blk_hi = {hx(rdr.get('xnu_live_rdr_blk_hi'))} != ustack = "
                       f"{hx(rdr.get('xnu_live_rdr_ustack'))}: the BLOCK's top bound is not "
                       f"p->user_stack, so the block-top reader is named (the block grew or moved). "
                       f"Fail closed. {shape}")
    if bby is None or blo is None or bby != (ust - blo):
        return verdict("READER-UNKNOWN",
                       f"blk_bytes = {bby} != ustack - blk_lo = "
                       f"{None if (ust is None or blo is None) else hex(ust - blo)}: the recorded "
                       f"argv/env block length does not match its span. Fail closed. {shape}")
    if far != ust + FAR_MINUS_USTACK_WANT:
        return verdict("READER-UNKNOWN",
                       f"far = {hx(rdr.get('xnu_live_rdr_far'))} != ustack + 0x"
                       f"{FAR_MINUS_USTACK_WANT:04x}: the two derivations disagree. Fail closed. {shape}")

    say("FAULT-NAMED",
        f"the 1029 reader row describes the known launchctl[2] fault: far=0x{far:08x} "
        f"(pid was the faulting exec; see the 1025 rows below)")
    return verdict("READER-NAMED",
                   f"READER NAMED BY VALUE: the store is exactly one PAGE above the advertised top "
                   f"(far - ustack = 0x{FAR_MINUS_USTACK_WANT:04x}), the block's TOP bound IS "
                   f"p->user_stack (blk_hi == ustack, so the block did NOT grow), and far is covered "
                   f"by NO entry (entry_at_hit=0). The writer's store address is a function of "
                   f"p->user_stack -> the derivation is PROVEN. {shape}"
                   f"\n            -> 1029 is a PROBE (report, do not re-fix). The NEXT rung must "
                   f"change the VALUE the writer derives from, or the reader itself -- NOT allocate "
                   f"another page (the fault would follow it again; 1028 proved this). See "
                   f"docs/1029-design.md s.8.")


def _parent_cells(lines, ctl, entry, named, rdr_absent):
    """The 1025/1026/1027 re-reading + the 1028 H cells, for a capture with NO 1029 row."""
    note = ("(no xnu_live_rdr_* row: the 1029 reader probe did not run on this arm -- check "
            "STAGE90_XNU_READER_PROBE=1 in the record and the linked image) ")
    if not named:
        if entry:
            if ctl["launchd"]:
                return verdict("FIX-HOLDS", note +
                               "the launchctl[2] stack fault is GONE (no vmfkrv=1 row in the stack "
                               "window) while launchd started - but the reader probe did not fire, "
                               "so this is a 1028-shaped reading, not a 1029 one. Read the NEXT "
                               "frontier; do not re-fix.")
            return verdict("G-CTL", note + "no stack-window fault AND launchd not reached; WITHHOLD")
        return verdict("NO-CELL", note + "no 1029 reader row, no 1028 entry row, and no 1025 "
                                         "stack-window vmfkrv row - not a 1028/1029 arm")
    far, row = named[-1]
    code = parse_int(row.get("code"))
    say("FAULT-NAMED",
        f"the 1025 re-reading HOLDS: far=0x{far:08x} code={row.get('code')}"
        f"({KERN_NAMES.get(code, '?')}) dfsr={row.get('dfsr')} prot={row.get('prot')} "
        f"pc={row.get('pc')} pid={row.get('pid')}")
    if entry:
        lk0 = parse_int(entry.get("xnu_live_abt_lookup_far"))
        e2hi0 = parse_int(entry.get("xnu_live_abt_e2_hi"))
        ehi0 = parse_int(entry.get("xnu_live_abt_entry_hi"))
        us0 = parse_int(entry.get("xnu_live_abt_ustack"))
        cover0 = e2hi0 if e2hi0 is not None else ehi0
        if lk0 == 0 and us0 == far and cover0 == far:
            return verdict("FIX-NOOP", note +
                           f"the H2 fault RECURS unchanged (far=0x{far:08x} == ustack == the covering "
                           f"entry top, lookup_far=0). This is a 1028-shaped reading.")
    lk = parse_int(entry.get("xnu_live_abt_lookup_far")) if entry else None
    fim = parse_int(entry.get("xnu_live_abt_far_in_map")) if entry else None
    e2hi = parse_int(entry.get("xnu_live_abt_e2_hi")) if entry else None
    e2lo = parse_int(entry.get("xnu_live_abt_e2_lo")) if entry else None
    ehi = parse_int(entry.get("xnu_live_abt_entry_hi")) if entry else None
    elo = parse_int(entry.get("xnu_live_abt_entry_lo")) if entry else None
    cover_hi = e2hi if e2hi is not None else ehi
    cover_lo = e2lo if e2lo is not None else elo
    mp = parse_int(entry.get("xnu_live_abt_map")) if entry else None
    tmap = parse_int(entry.get("xnu_live_abt_taskmap")) if entry else None
    ustk = parse_int(entry.get("xnu_live_abt_ustack")) if entry else None
    shape = (f"lookup_far={lk} far_in_map={fim} "
             f"e2=[{hx(entry.get('xnu_live_abt_e2_lo') if entry else None)},"
             f"{hx(entry.get('xnu_live_abt_e2_hi') if entry else None)}) "
             f"map={hx(entry.get('xnu_live_abt_map') if entry else None)} "
             f"taskmap={hx(entry.get('xnu_live_abt_taskmap') if entry else None)} "
             f"ustack={hx(entry.get('xnu_live_abt_ustack') if entry else None)}")
    if lk is None:
        return verdict("H-OTHER", note + f"a 1025 row fired but NO 1028 entry row was captured: "
                                         f"{shape} - report; pick NO fix")
    h1 = (lk == 0 and fim == 0 and mp is not None and tmap is not None and mp != tmap
          and ustk is not None and ustk == far)
    h2 = (lk == 0 and fim == 1 and cover_hi is not None and cover_hi == far
          and mp is not None and tmap is not None and mp == tmap)
    if h1:
        return verdict("H1", f"WRONG MAP: walk map={hx(entry.get('xnu_live_abt_map'))} != taskmap="
                             f"{hx(entry.get('xnu_live_abt_taskmap'))}; far=0x{far:08x}. {shape}")
    if h2:
        return verdict("H2", f"OFF-THE-END: the region ends exactly at far (covering entry "
                             f"[0x{cover_lo:08x},0x{cover_hi:08x}) == far), map == taskmap. {shape}")
    return verdict("H-OTHER", f"neither H1 nor H2 (fail closed): {shape}; far=0x{far:08x}")


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
    tmp = tempfile.mkdtemp(prefix="check1029-selftest-")
    fails = []

    def expect(cell, cap, label):
        got = adjudicate(cap)
        if got != cell:
            fails.append(f"{label}: got {got}, want {cell}")

    ctl = [
        "IOS7LAB trap24 frame",
        "IOS7LAB port_construct result=0",
        "*** launchd[1] has started up. ***",
    ]
    vm = [
        "xnu_live_abt_vmfkrv=1",
        "xnu_live_abt_vmfkrv_far=0x2bd0e000",
        "xnu_live_abt_vmfkrv_dfsr=0x807",
        "xnu_live_abt_vmfkrv_prot=write",
        "xnu_live_abt_vmfkrv_pc=0x388f4756",
        "xnu_live_abt_vmfkrv_sp=0x2bd0c074",
        "xnu_live_abt_vmfkrv_pid=2",
    ]
    entry_h2 = [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_entry_lo=0x00000000",
        "xnu_live_abt_entry_hi=0x00000000",
        "xnu_live_abt_e2_lo=0x2bc0e000",
        "xnu_live_abt_e2_hi=0x2bd0e000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd0d000",
    ]

    # The MEASURED 1028 shape (this is what the 1029 arm will also produce at the fault):
    #   far=0x2bd0e000, ustack=0x2bd0d000, far-ustack=0x1000, blk=[0x2bd0c074+..], entry unmapped.
    # blk_lo = ustack - p_argslen.  Take p_argslen = 0xF8C so blk_lo = 0x2bd0c074 (== sp).
    #   0x2bd0d000 - 0xF8C = 0x2bd0c074  ->  p_argslen = 0xF8C = 3980,  blk_bytes == ustack - blk_lo.
    rdr_named = [
        "xnu_live_rdr_far=0x2bd0e000",
        "xnu_live_rdr_ustack=0x2bd0d000",
        "xnu_live_rdr_far_minus_ustack=0x00001000",
        "xnu_live_rdr_blk_hi=0x2bd0d000",
        "xnu_live_rdr_blk_lo=0x2bd0c074",
        "xnu_live_rdr_blk_bytes=3980",        # 0xF8C = ustack - blk_lo
        "xnu_live_rdr_argc=1",
        "xnu_live_rdr_entry_at_hit=0",
        "xnu_live_rdr_entry_at_lo=0x00000000",
        "xnu_live_rdr_entry_at_hi=0x00000000",
    ]
    expect("READER-NAMED", _mk(tmp, "named.txt", ctl + vm + entry_h2 + rdr_named), "READER-NAMED")

    # entry_at_hit=1 -> READER-UNKNOWN naming the block-top conjunct (READER-BLOCK)
    rdr_hit = list(rdr_named)
    rdr_hit[7] = "xnu_live_rdr_entry_at_hit=1"
    rdr_hit[8] = "xnu_live_rdr_entry_at_lo=0x2bd0d000"
    rdr_hit[9] = "xnu_live_rdr_entry_at_hi=0x2bd20000"
    expect("READER-UNKNOWN", _mk(tmp, "hit.txt", ctl + vm + entry_h2 + rdr_hit),
           "READER-UNKNOWN-entry-hit")

    # far-ustack != 0x1000 -> READER-UNKNOWN (fixed-VA hypothesis)
    rdr_off = list(rdr_named)
    rdr_off[2] = "xnu_live_rdr_far_minus_ustack=0x00000f8c"
    rdr_off[0] = "xnu_live_rdr_far=0x2bd0df8c"
    expect("READER-UNKNOWN", _mk(tmp, "off.txt", ctl + vm + entry_h2 + rdr_off),
           "READER-UNKNOWN-far-ustack")

    # blk_hi != ustack -> READER-UNKNOWN (block-top reader)
    rdr_bhi = list(rdr_named)
    rdr_bhi[3] = "xnu_live_rdr_blk_hi=0x2bd0e000"
    expect("READER-UNKNOWN", _mk(tmp, "bhi.txt", ctl + vm + entry_h2 + rdr_bhi),
           "READER-UNKNOWN-blk-hi")

    # NO 1029 row -> parent cells.  The 1028 measured shape (far==ustack==e2_hi) -> FIX-NOOP.
    expect("FIX-NOOP", _mk(tmp, "norow.txt", ctl + vm + [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_e2_lo=0x2bd0e000",
        "xnu_live_abt_e2_hi=0x2bd0e000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd0e000",
    ]), "no-1029-row -> FIX-NOOP")

    # REGRESSION -- the storm returns
    expect("REGRESSION", _mk(tmp, "storm.txt", ctl + [
        "xnu_live_abt_far=0x40083008",
        "xnu_live_abt_pcn=0x00100000",
    ]), "REGRESSION")

    # G-CTL -- a dead console
    expect("G-CTL", _mk(tmp, "dead.txt", [
        "bsd_init: done",
        "IOS7LAB shared region 0x2c000000..0x40000000",
    ]), "G-CTL")

    # BLANK-SEPARATED keys (the measured console shape) must still group into ONE row.
    expect("READER-NAMED", _mk(tmp, "blank.txt",
                               _blank_sep(ctl + vm + entry_h2 + rdr_named)), "blank-separated")

    # ANSI/console prefix on the values must not corrupt them
    ansi = ["\x1b[0m launchctl[2]: " + ln for ln in (rdr_named)]
    expect("READER-NAMED", _mk(tmp, "ansi.txt", ctl + vm + entry_h2 + ansi), "ansi-prefixed")

    if fails:
        print("SELFTEST FAILED:")
        for f in fails:
            print("  " + f)
        return 1
    print("selftest PASS (9/9 cells)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="1029 reader probe capture reader")
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