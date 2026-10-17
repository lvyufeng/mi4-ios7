#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_1026_capture.py -- the 1026 press's capture reader (the abt-entry discriminator).

WHAT 1026 IS, AND WHAT THIS CHECKER IS FOR
==========================================
1025 NAMED the cause of the launchctl[2] stack abort: the discarded `vm_fault` return is
`code=1` = KERN_INVALID_ADDRESS on `far=0x2bd35000`, which by source
(`vm_map_lookup_locked` -> `vm_map_lookup_entry` FALSE -> `return KERN_INVALID_ADDRESS`,
osfmk/vm/vm_map.c:8761ff) means NO vm_map entry covered the VA when the walk ran.

1026 does not re-name the cause; it DISCRIMINATES between the two upstream shapes that both
produce "no entry":
  (H1) WRONG MAP   - the entry exists but in a DIFFERENT map than the one the walk used
                     (create_unix_stack allocated into get_task_map(task); the abort walks
                     thread->map, trap.c:822).
  (H2) OFF-THE-END - the region genuinely ENDS at `far` (the 1025 probe measured launchctl's
                     region as [0x2bc35000,0x2bd35000) = exactly the exclusive top), and the
                     argv/env block / initial `sp` sits one legal word below.  Userspace is
                     correct; the fix is kernel-side (headroom).

THE INSTRUMENT (tools/patch_d13_abt_entry_probe.py, behind STAGE90_XNU_ABT_ENTRY_PROBE)
publishes, for the FAILING fault only, seven plain ram-console keys (non-ringed, like 1025):
    xnu_live_abt_lookup_far   vm_map_lookup_entry(map, dfar, &e)            -> 1/0
    xnu_live_abt_entry_lo     e->vme_start   (when found)
    xnu_live_abt_entry_hi     e->vme_end
    xnu_live_abt_far_in_map   vm_map_lookup_entry(map, dfar-4, &e2)         -> 1/0
    xnu_live_abt_map          `map` (thread->map)
    xnu_live_abt_taskmap      get_task_map(thread->task)
    xnu_live_abt_ustack       p->user_stack (0 if no bsd_info)

CELLS (pre-registered; docs/1026-design.md section 4)
=====================================================
  H1 (wrong map)     lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack == far
                     -> the entry lives in taskmap; fix = walk taskmap (or make the two equal
                        at this point in exec).
  H2 (off-the-end)   lookup_far=0 AND far_in_map=1 AND entry_hi == far AND map == taskmap
                     -> the region ends exactly at far; a legal word sits just below.
                        fix = give the initial argv/env block / sp a word of headroom.
  H-OTHER            any other combination -> report the values and pick NO fix (fail closed).

PLUS the re-readings that must still hold from 1025, and the 1024 controls:
  G-CTL              no controls and no panic -> WITHHOLD (fail closed; an unsound instrument
                     cannot read an absence)
  REGRESSION         the 1023 pthread storm returns (far==0x40083008 or abt_pcn>=0x8000), or
                     launchd reached with no trap24/port_construct marks
  FAULT-NAMED        `xnu_live_abt_vmfkrv=1` with a `_far` inside the stack window
                     [0x2BD00000,0x2BE00000) -> the 1025 re-reading still fires (this capture is a
                     1026 arm only if this holds)
  NO-CELL            nothing in the table fired; report what was present (never fabricate)

ORDER MATTERS: G-CTL, then REGRESSION, then FAULT-NAMED (the 1025 re-reading), then the H cells.
A capture with no 1026 keys at all (e.g. the 1025 press capture) MUST fall through to the 1025
re-reading or NO-CELL -- never a false H cell.

PARSE/GROUPING NOTES (both inherited from check_1025_capture.py, both measured)
==============================================================================
  * `parse_int` keeps only the leading hex/number run, so an ANSI colour or a `launchctl[2]: `
    console prefix glued to a token does not corrupt the value.
  * The RAM console inserts its OWN line break after the kernel's `printf(...\\n")`, so the
    capture has a BLANK line between EVERY probe key.  The key grouper therefore must NOT let a
    blank line end a group.

USAGE
=====
  check_1026_capture.py <capture.txt> [--selftest]
"""
import argparse
import os
import re
import sys
import tempfile

STACK_LO = 0x2BD00000
STACK_HI = 0x2BE00000

# the discriminator keys, in publication order (the 1027 amendment adds the far-4 entry's bounds,
# which are the ONLY readable source of the H2 conjunct when lookup_far=0 suppresses entry_*/)
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
    """All values of `key=<v>` across the capture.

    The value is captured up to a whitespace/ANSI/`[`-boundary so a console prefix or a colour
    reset around the token does not corrupt it.  `parse_int` then keeps the numeric run.
    """
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
    # Tolerate an ANSI escape or a console prefix glued to the value (the kernel's printf output
    # can carry `launchctl[2]: ` and colour codes around a token).  Keep the leading hex run.
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


def abt_entry_row(lines):
    """The LAST published 1026 discriminator row, grouped across blank-separated probe lines.

    The publisher prints ONE key per line, in ENTRY_KEYS order.  The console adds its own break
    after each, so a BLANK line sits between every key and MUST NOT end the group (measured: the
    1025 capture's own rows read `key=` / blank / `key=` / blank / ...).  Only a line with CONTENT
    that carries none of the seven keys ends the group -- the same rule as check_1025_capture.py's
    `fault_rows`.  Matching is by SUBSTRING so a console prefix or ANSI colour is harmless.

    The LAST complete group wins: the probe fires once per failing abort, and the launchctl fault is
    the last thing the boot does.
    """
    key_rx = [(k, re.compile(re.escape(k) + r"=([^\s\x1b\[]+)")) for k in ENTRY_KEYS]
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
        if ln.strip() == "":       # the console's own added break, NOT a group terminator
            continue
        if cur:                    # a line with CONTENT and no entry key ends the group
            rows.append(cur)
            cur = {}
    if cur:
        rows.append(cur)
    # keep only groups that actually carry the discriminator (not a stray single key)
    full = [r for r in rows if r.get("xnu_live_abt_lookup_far") is not None]
    return full[-1] if full else (rows[-1] if rows else {})


def fault_rows(lines):
    """Every 1025 failed-fault publisher row: dict with keys code/far/dfsr/prot/pc/sp/pid.

    A line carrying `xnu_live_abt_vmfkrv=` (the BARE code key) STARTS a row; subsequent lines
    carrying `xnu_live_abt_vmfkrv_<suffix>=` extend it; a line with CONTENT and neither ends it.
    A BLANK line does NOT end a row (the console's added break).
    """
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
            for sm in suffix_rx.finditer(ln):   # a line may carry both
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
    """1023's pthread storm signature: far == 0x40083008 (the pthread stack out-param VA), OR an
    abt_pcn massive enough to be the storm's own 1M ordinal.  abt_pcn == 0x400 is only the ladder's
    SAMPLE CAP (both a quiet run and the storm reach it), so it is NOT a storm signal by itself."""
    for ln in lines:
        if "0x40083008" in ln:
            return True
    for v in kv_values(lines, "xnu_live_abt_pcn"):
        n = parse_int(v)
        if n is not None and n >= 0x8000:
            return True
    return False


def prior_controls(lines):
    """The 1024 controls read by value from the SAME capture."""
    trap24 = sum(1 for ln in lines if "IOS7LAB trap24 frame" in ln)
    pc0 = kv_values(lines, "xnu_live_abt_pc")  # positive control that the abt instrument was live
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
    """The 1025 re-reading: vmfkrv rows whose `far` lies in the stack window."""
    out = []
    for r in fault_rows(lines):
        far = parse_int(r.get("far"))
        if far is not None and STACK_LO <= far < STACK_HI:
            out.append((far, r))
    return out


def named_row(lines):
    """The LAST vmfkrv row (any far), for reporting alongside a 1026 cell."""
    rows = fault_rows(lines)
    return rows[-1] if rows else None


def hx(v):
    n = parse_int(v)
    return "None" if n is None else f"0x{n:08x}"


def adjudicate(cap):
    lines = raw_lines(cap)
    ctl = prior_controls(lines)
    entry = abt_entry_row(lines)
    named = vmfkrv_stack_rows(lines)
    last = named_row(lines)

    say("READ", os.path.basename(cap))
    say("CTL", f"launchd_reached={ctl['launchd']} trap24={ctl['trap24']} "
               f"port_construct(result=0)={ctl['port_construct0']} abt_pc_live={ctl['abt_pc_live']} "
               f"undef_seq={ctl['undef_seq']} panics={ctl['panics']}")
    say("INSTR", f"entry_row_keys={len(entry)} vmfkrv_stack_rows={len(named)}")

    # (1) G-CTL -- fail closed
    instrument_live = (ctl["launchd"] or ctl["trap24"] > 0 or ctl["abt_pc_live"] > 0)
    if not instrument_live and ctl["panics"] == 0:
        return verdict("G-CTL", "neither launchd-reached nor any prior control is live AND no panic "
                                "- the instrument was not sound; WITHHOLD (never a pass)")

    # (2) REGRESSION -- before reading anything about 1026
    if storm_present(lines):
        return verdict("REGRESSION", "the 1023 pthread storm signature is present (far=0x40083008 / "
                                     "abt_pcn>=0x8000) - the arm's switch set is wrong; this is NOT a "
                                     "1026 reading. Check STAGE90_XNU_VM_MAX_SPLIT=1 in the record.")
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        return verdict("REGRESSION", "launchd reached but NO trap24/port_construct marks - the "
                                     "1023/1024 controls regressed")

    # (3) FAULT-NAMED -- the 1025 re-reading MUST still fire for a 1026 arm to be readable
    if not named:
        if entry:
            return verdict("NO-CELL", "a 1026 entry row is present but NO 1025 vmfkrv row has a far "
                                      "in the stack window - the 1025 re-reading DID NOT reproduce, "
                                      "so the H cells cannot be read on this capture. Report and "
                                      "re-aim")
        return verdict("NO-CELL", "no 1026 entry row and no 1025 stack-window vmfkrv row - this is "
                                  "not a 1026 arm (or the probe did not reach the object: check "
                                  "STAGE90_XNU_ABT_ENTRY_PROBE=1 in the record and the linked image)")

    far, row = named[-1]
    code = parse_int(row.get("code"))
    say("FAULT-NAMED",
        f"the 1025 re-reading HOLDS: far=0x{far:08x} code={row.get('code')}"
        f"({KERN_NAMES.get(code, '?')}) dfsr={row.get('dfsr')} prot={row.get('prot')} "
        f"pc={row.get('pc')} pid={row.get('pid')}")

    # (4) the H cells -- only after FAULT-NAMED holds
    lk = parse_int(entry.get("xnu_live_abt_lookup_far"))
    fim = parse_int(entry.get("xnu_live_abt_far_in_map"))
    ehi = parse_int(entry.get("xnu_live_abt_entry_hi"))
    elo = parse_int(entry.get("xnu_live_abt_entry_lo"))
    # 1027: the far-4 entry's OWN bounds.  In the H2 case (lookup_far=0) the covering entry is the
    # far-4 lookup's (_abt_e2), NOT _abt_e -- so `entry_hi` is 0/suppressed there and the H2 cell's
    # `entry_hi == far` conjunct was UNREADABLE BY CONSTRUCTION in 1026 (a probe defect, not a third
    # hypothesis).  Prefer the e2 row when present; fall back to entry_hi for pre-1027 captures.
    e2hi = parse_int(entry.get("xnu_live_abt_e2_hi"))
    e2lo = parse_int(entry.get("xnu_live_abt_e2_lo"))
    # The bounds that name the entry COVERING far-4: e2 row if the probe published one, else the
    # e row (for a capture built before the 1027 amendment).
    cover_hi = e2hi if e2hi is not None else ehi
    cover_lo = e2lo if e2lo is not None else elo
    mp = parse_int(entry.get("xnu_live_abt_map"))
    tmap = parse_int(entry.get("xnu_live_abt_taskmap"))
    ustk = parse_int(entry.get("xnu_live_abt_ustack"))

    shape = (f"lookup_far={lk} far_in_map={fim} entry=[{hx(entry.get('xnu_live_abt_entry_lo'))},"
             f"{hx(entry.get('xnu_live_abt_entry_hi'))}) "
             f"e2=[{hx(entry.get('xnu_live_abt_e2_lo'))},{hx(entry.get('xnu_live_abt_e2_hi'))}) "
             f"map={hx(entry.get('xnu_live_abt_map'))} "
             f"taskmap={hx(entry.get('xnu_live_abt_taskmap'))} "
             f"ustack={hx(entry.get('xnu_live_abt_ustack'))}")

    if lk is None:
        # a vmfkrv row fired but the 1026 publisher did not -> fail closed, never guess
        return verdict("H-OTHER", f"the 1025 row fired but NO 1026 entry row was captured (the "
                                  f"publisher did not run, or it did not reach the object on this "
                                  f"fault): {shape} - report; pick NO fix")

    h1 = (lk == 0 and fim == 0 and mp is not None and tmap is not None and mp != tmap
          and ustk is not None and far is not None and ustk == far)
    h2 = (lk == 0 and fim == 1 and cover_hi is not None and far is not None and cover_hi == far
          and mp is not None and tmap is not None and mp == tmap)

    if h1:
        return verdict("H1", f"WRONG MAP: the walk used map={hx(entry.get('xnu_live_abt_map'))} but the "
                             f"task's map is taskmap={hx(entry.get('xnu_live_abt_taskmap'))}; the "
                             f"entry is invisible to the walk although far=0x{far:08x} == "
                             f"p->user_stack (the requested region top). {shape}"
                             f"\n            -> fix = walk the task's map (or make the two equal at "
                             f"this point in exec). See docs/1026-design.md s.7 (exec_mach_imgact:948 "
                             f"vm_map_switch window)")
    if h2:
        return verdict("H2", f"OFF-THE-END: the region ends exactly at far (covering entry "
                             f"[0x{cover_lo:08x},0x{cover_hi:08x}) == far) and map == taskmap; the "
                             f"word just below (far-4) IS in the map. "
                             f"{shape}"
                             f"\n            -> this is upstream: the initial argv/env block / sp is "
                             f"one word too high. fix = give the block a word of headroom "
                             f"(kernel-side; userspace is behaving). See docs/1026-design.md s.2")
    # H-OTHER: fail closed, pick NO fix
    return verdict("H-OTHER", f"the published combination matches NEITHER H1 nor H2 (fail closed): "
                              f"{shape}; far=0x{far:08x}"
                              f"\n            -> pick NO fix; 1027 instruments whatever this names")


# ---------------------------------------------------------------------------------------------------
def _mk(tmpdir, name, lines):
    p = os.path.join(tmpdir, name)
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    return p


def _blank_sep(pairs):
    """Emit key lines with the console's own BLANK line between every one (the measured shape)."""
    out = []
    for ln in pairs:
        out.append(ln)
        out.append("")
    return out


def self_test():
    tmp = tempfile.mkdtemp(prefix="check1026-selftest-")
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
        "xnu_live_abt_vmfkrv_far=0x2bd35000",
        "xnu_live_abt_vmfkrv_dfsr=0x807",
        "xnu_live_abt_vmfkrv_prot=write",
        "xnu_live_abt_vmfkrv_pc=0x3b4ce756",
        "xnu_live_abt_vmfkrv_sp=0x2bd34074",
        "xnu_live_abt_vmfkrv_pid=2",
    ]
    # H1 row: lookup 0, far_in_map 0, map != taskmap, ustack == far
    h1_row = [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_entry_lo=0x00000000",
        "xnu_live_abt_entry_hi=0x00000000",
        "xnu_live_abt_far_in_map=0",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0ba3b28",
        "xnu_live_abt_ustack=0x2bd35000",
    ]
    # H2 row: lookup 0, far_in_map 1, entry_hi == far, map == taskmap
    h2_row = [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_entry_lo=0x2bc35000",
        "xnu_live_abt_entry_hi=0x2bd35000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd35000",
    ]
    # H2 row, 1027 SHAPE: lookup_far=0 SUPPRESSES entry_lo/entry_hi (both 0) -- the covering entry is
    # the far-4 lookup's, published as e2_lo/e2_hi.  This is EXACTLY the shape the 1026 press produced
    # (entry suppressed) and for which the old cell could never fire.  e2_hi == far => H2.
    h2_e2_row = [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_entry_lo=0x00000000",
        "xnu_live_abt_entry_hi=0x00000000",
        "xnu_live_abt_e2_lo=0x2bc35000",
        "xnu_live_abt_e2_hi=0x2bd35000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd35000",
    ]
    # same shape but e2_hi is NOT far (the region ends BELOW far) => H-OTHER (fail closed), proving
    # the e2 conjunct is really tested and not merely accepting any far_in_map=1.
    h2_e2_short_row = [
        "xnu_live_abt_lookup_far=0",
        "xnu_live_abt_entry_lo=0x00000000",
        "xnu_live_abt_entry_hi=0x00000000",
        "xnu_live_abt_e2_lo=0x2bc25000",
        "xnu_live_abt_e2_hi=0x2bd34000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd35000",
    ]

    # (1) H1 -- wrong map
    expect("H1", _mk(tmp, "h1.txt", ctl + vm + h1_row), "H1")

    # (2) H2 -- off the end
    expect("H2", _mk(tmp, "h2.txt", ctl + vm + h2_row), "H2")

    # (2b) H2 in the 1027 SHAPE: entry suppressed (lookup_far=0), e2_hi == far.  This is the cell
    #     1026's press could NOT reach; it is the whole point of the amendment.
    expect("H2", _mk(tmp, "h2e2.txt", ctl + vm + h2_e2_row), "H2-e2")

    # (2c) 1027 shape with e2_hi != far -> H-OTHER, never a false H2 off a bare far_in_map=1.
    expect("H-OTHER", _mk(tmp, "h2e2s.txt", ctl + vm + h2_e2_short_row), "H-OTHER-e2-short")

    # (3) H-OTHER -- a combination matching neither
    other = [
        "xnu_live_abt_lookup_far=1",
        "xnu_live_abt_entry_lo=0x2bd34000",
        "xnu_live_abt_entry_hi=0x2be00000",
        "xnu_live_abt_far_in_map=1",
        "xnu_live_abt_map=0xc0005688",
        "xnu_live_abt_taskmap=0xc0005688",
        "xnu_live_abt_ustack=0x2bd35000",
    ]
    expect("H-OTHER", _mk(tmp, "other.txt", ctl + vm + other), "H-OTHER")

    # (4) FAULT-NAMED fires (the 1025 re-reading) but the 1026 publisher did not run: the 1025
    #     row is present with NO 1026 entry row -> H-OTHER by the fail-closed rule (never a guess).
    expect("H-OTHER", _mk(tmp, "no1026.txt", ctl + vm), "no-1026-row")

    # (5) REGRESSION -- the storm returns
    expect("REGRESSION", _mk(tmp, "storm.txt", ctl + [
        "xnu_live_abt_far=0x40083008",
        "xnu_live_abt_pcn=0x00100000",
    ]), "REGRESSION")

    # (6) G-CTL -- a dead console, no controls, no panic
    expect("G-CTL", _mk(tmp, "dead.txt", [
        "bsd_init: done",
        "IOS7LAB shared region 0x2c000000..0x40000000",
    ]), "G-CTL")

    # (7) BLANK-SEPARATED keys -- the measured console shape must still group into ONE row.
    #     If the grouper splits on the blank, lookup_far becomes None -> H-OTHER, so this cell
    #     is the check that the blank rule holds.
    expect("H1", _mk(tmp, "blank.txt",
                     _blank_sep(ctl + vm + h1_row)), "blank-separated")

    # (8) ANSI/console prefix on the values must not corrupt them
    ansi = [
        "\x1b[0m launchctl[2]: xnu_live_abt_lookup_far=0",
        "\x1b[0m launchctl[2]: xnu_live_abt_entry_lo=0x00000000",
        "\x1b[0m launchctl[2]: xnu_live_abt_entry_hi=0x00000000",
        "\x1b[0m launchctl[2]: xnu_live_abt_far_in_map=0",
        "\x1b[0m launchctl[2]: xnu_live_abt_map=0xc0005688",
        "\x1b[0m launchctl[2]: xnu_live_abt_taskmap=0xc0ba3b28",
        "\x1b[0m launchctl[2]: xnu_live_abt_ustack=0x2bd35000",
    ]
    expect("H1", _mk(tmp, "ansi.txt", ctl + vm + ansi), "ansi-prefixed")

    if fails:
        print("SELFTEST FAILED:")
        for f in fails:
            print("  " + f)
        return 1
    print("selftest PASS (10/10 cells)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="1026 abt-entry discriminator capture reader")
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