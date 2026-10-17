#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_1025_capture.py -- the 1025 press's capture reader (the FAILED-FAULT / stack-shape probe).

WHAT 1025 IS, AND WHAT THIS CHECKER IS FOR
==========================================
The 1024 boot (records/1024b-frontier-launchctl-crash.txt; arm identity settled in
records/1025-globalfix-carrier.txt section 6) reached `*** launchd[1] has started up ***`, spawned
pid 2 `launchctl`, and died in a USERSPACE DATA ABORT on a STACK VA:

    launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 in map 0xc0005688
                  (pmap 0xc0ba3b28) (Translation fault on page)
    r4=r6=0x2bdbe000  r7=r11=0x2bdbd080  sp=0x2bdbd074  lr=0x3adbc9af  pc=0x3adc4756
    cpsr=0xa0000030   (T=1 Thumb, mode=USR)

0x2bdbe000 is INSIDE the fixed stack window [0x2BD00000, 0x2BE00000) `create_unix_stack` allocates;
`sp=0x2bdbd074` shows the FIXED allocation SUCCEEDED (no ANYWHERE fallback; by value:
records/1025-source-trace.txt sections 3-4).  So a page that should be mapped is TRANSLATION-faulting.
In osfmk/arm/trap.c the usermode data-abort path CALLS `vm_fault` and, on a non-SUCCESS return,
delivers EXC_BAD_ACCESS; the ONE assignment of the return code (`code`) sits inside
`#if BOARD_CONFIG_QSD8250_LEO`, so on CANCRO **the value that NAMES the cause is DISCARDED**.

1025 compiles in two publishers (tools/patch_d13_ustack_probe.py, behind STAGE90_XNU_USTACK_PROBE):
  * trap.c       -> `xnu_live_abt_vmfkrv=<code>` and `_far=/_dfsr=/_prot=/_pc=/_sp=/_pid=` (the
                    discarded vm_fault return for EVERY failed usermode data abort)
  * kern_exec.c  -> `xnu_live_ustack_req/size/fixed_addr/rc/final/prot_addr/prot_size` (once per exec)

THE INSTRUMENT IS NON-RINGED, WHICH IS THE WHOLE POINT
=====================================================
In the 1024 capture the `xnu_live_abt_*` RING capped at n=0x400 on the shared-cache fault before the
launchctl abort, so the launchctl fault left no ring row.  The 1025 publishers are plain `printf`
lines on the ram console, NOT the capped ring, so the launchctl fault IS captured even after the
ring filled - that is why this reader looks for the NEW keys and not the old ring.

CELLS (pre-registered)
======================
  G-CTL                 neither launchd-reached nor any trap24/port_construct control is live AND no
                        panic  => WITHHOLD (fail closed; an unsound instrument cannot read an absence)
  FAULT-NAMED           `xnu_live_abt_vmfkrv_far` ~ 0x2bdbe000 (or, more generally, a vmfkrv row whose
                        `_far` is inside the stack window [0x2BD00000,0x2BE00000)) with a `_vmfkrv`
                        return that NAMES the cause  => report the cause (this is the 1025 goal)
  FAULT-NOT-RUN         launchctl was reached but NO `xnu_live_abt_vmfkrv=` row is present
                        => the abort is NOT this (data) path (re-read: a PREFETCH abort? then
                           instrument THAT arm too; docs/1025-design.md section 7)
  STACK-SHAPE           `xnu_live_ustack_*` present with `_rc=0` and no ANYWHERE fallback
                        => confirms records/1025-source-trace.txt's by-value claim independently
  REGRESSION            the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /
                        port_construct results vanish)  => the arm's switch set is wrong
  NO-CELL               nothing in the table fires (report what was present; never fabricate)

ORDER MATTERS: G-CTL first, REGRESSION before FAULT-NAMED (a capture whose prior controls regressed
is not a 1025 reading), FAULT-NOT-RUN distinguished from FAULT-NAMED by the presence of ANY vmfkrv row.

USAGE
=====
  check_1025_capture.py <capture.txt> [--baseline <older-capture.txt>] [--json]
  check_1025_capture.py --selftest
"""
import argparse
import os
import re
import sys
import tempfile

STACK_LO = 0x2BD00000
STACK_HI = 0x2BE00000
CRASH_FAR = 0x2bdbe000

# the four vm_fault returns that name a cause
KERN_NAMES = {
    0: "KERN_SUCCESS",
    1: "KERN_INVALID_ADDRESS",
    2: "KERN_PROTECTION_FAILURE",
    3: "KERN_NO_SPACE",
    4: "KERN_INVALID_ARGUMENT",
    5: "KERN_FAILURE",
    6: "KERN_RESOURCE_SHORTAGE",
    7: "KERN_NOT_RECEIVER",
    # 0xe = 14
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

    The value is captured up to a whitespace/ANSI/`[`-boundary so a console prefix or a colour reset
    around the token does not corrupt it.  `parse_int` then keeps the numeric run.
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
    # Tolerate an ANSI escape or a console prefix glued to the value (the kernel's printf output can
    # carry `launchctl[2]: ` and colour codes around a token).  Keep only the leading hex/number run.
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


def fault_rows(lines):
    """Every failed-fault publisher row: dict with keys code/far/dfsr/prot/pc/sp/pid.

    The publisher prints ONE key per line.  A line carrying `xnu_live_abt_vmfkrv=` (the BARE code key)
    STARTS a row; subsequent lines carrying `xnu_live_abt_vmfkrv_<suffix>=` extend it; a line carrying
    neither (or another BARE vmfkrv=) ends the row.  Matching is by SUBSTRING so a console prefix or
    ANSI colour around the token does not break grouping.

    **A BLANK/WHITESPACE-ONLY LINE DOES NOT END A ROW.**  The kernel prints each key with `printf("...\
    n")` and the RAM console adds its OWN line break, so the capture has a blank line between EVERY
    probe line (measured: the 1025 capture's row reads `vmfkrv=1` / blank / `vmfkrv_far=...` / blank /
    ...).  Treating a blank as a terminator split each key into its own one-field row, so the `_far`
    never joined its `code` and the reader saw `far=None` on a capture where the far WAS printed.  Only
    a line with actual non-vmfkrv CONTENT ends a row.  (The earlier selftests passed because they fed
    the keys as ADJACENT lines - see `self_test`, which now also exercises the blank-separated shape.)
    """
    rows = []
    cur = None
    # `xnu_live_abt_vmfkrv=` (bare) and `xnu_live_abt_vmfkrv_far=` (suffixed) are DISTINGUISHABLE by
    # the substring itself -- the suffixed form has `_`, so the bare `...vmfkrv=` does not match it.
    suffix_rx = re.compile(r"xnu_live_abt_vmfkrv_(\w+)=([^\s\x1b\[]+)")
    code_rx = re.compile(r"xnu_live_abt_vmfkrv=([^\s\x1b\[]+)")
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
            # A blank / whitespace-only line is the console's own added break, NOT a row terminator:
            # keep the row open so the next suffixed key still joins it.
            if ln.strip() == "":
                continue
            rows.append(cur)   # a line with CONTENT and no vmfkrv key ends the row
            cur = None
    if cur is not None:
        rows.append(cur)
    return rows


def launchd_reached(lines):
    return any("launchd[1] has started up" in ln for ln in lines)


def storm_present(lines):
    """1023's pthread storm signature: far == 0x40083008 (the pthread stack out-param VA), OR an
    abt_pcn massive enough to be the storm's own 1M ordinal.  NOTE: abt_pcn == 0x400 is only the
    ladder's SAMPLE CAP (both a quiet run and the storm reach it), so it is NOT a storm signal by
    itself - the 1024 crash capture tops out at 0x400 and is NOT a storm."""
    for ln in lines:
        if "0x40083008" in ln:
            return True
    for v in kv_values(lines, "xnu_live_abt_pcn"):
        n = parse_int(v)
        if n is not None and n >= 0x8000:   # well above the 0x400 sample cap; the storm runs to 0x100000
            return True
    return False


def prior_controls(lines):
    """The 1024 controls read by value from the SAME capture."""
    trap24 = sum(1 for ln in lines if "IOS7LAB trap24 frame" in ln)
    pc0 = kv_values(lines, "xnu_live_abt_pc")  # positive control that the abt instrument was live
    undef_seq = kv_last(lines, "xnu_live_undef_seq")
    panics = sum(1 for ln in lines if "panic" in ln.lower() and "no panic" not in ln.lower())
    launchd = launchd_reached(lines)
    # port_construct result=0 x4 (the 1023 mark)
    pc_res = sum(1 for ln in lines if "port_construct" in ln and "result=0" in ln)
    return {
        "trap24": trap24,
        "port_construct0": pc_res,
        "abt_pc_live": len(pc0),
        "undef_seq": undef_seq,
        "panics": panics,
        "launchd": launchd,
    }


def stack_rows(lines):
    rows = []
    for ln in lines:
        if "xnu_live_ustack_req=" in ln:
            rows.append({
                "req": kv_last([ln], "xnu_live_ustack_req"),
            })
    # simpler: collect the last value of each key
    return {
        "req": kv_last(lines, "xnu_live_ustack_req"),
        "size": kv_last(lines, "xnu_live_ustack_size"),
        "fixed_addr": kv_last(lines, "xnu_live_ustack_fixed_addr"),
        "rc": kv_last(lines, "xnu_live_ustack_rc"),
        "final": kv_last(lines, "xnu_live_ustack_final"),
        "prot_addr": kv_last(lines, "xnu_live_ustack_prot_addr"),
        "prot_size": kv_last(lines, "xnu_live_ustack_prot_size"),
        "n": len(kv_values(lines, "xnu_live_ustack_req")),
    }


def adjudicate(cap):
    lines = raw_lines(cap)
    ctl = prior_controls(lines)
    rows = fault_rows(lines)
    stk = stack_rows(lines)

    say("READ", os.path.basename(cap))
    say("CTL", f"launchd_reached={ctl['launchd']} trap24={ctl['trap24']} "
               f"port_construct(result=0)={ctl['port_construct0']} abt_pc_live={ctl['abt_pc_live']} "
               f"undef_seq={ctl['undef_seq']} panics={ctl['panics']}")
    say("INSTR", f"vmfkrv_rows={len(rows)} ustack_rows={stk['n']}")

    # (1) G-CTL -- fail closed
    instrument_live = (ctl["launchd"] or ctl["trap24"] > 0 or ctl["abt_pc_live"] > 0)
    if not instrument_live and ctl["panics"] == 0:
        return verdict("G-CTL", "neither launchd-reached nor any prior control is live AND no panic "
                                "- the instrument was not sound; WITHHOLD (never a pass)")

    # (2) REGRESSION -- before reading anything about 1025
    if storm_present(lines):
        return verdict("REGRESSION", "the 1023 pthread storm signature is present (far=0x40083008 / "
                                     "abt_pcn>=0x400) - the arm's switch set is wrong; this is NOT a "
                                     "1025 reading. Check STAGE90_XNU_VM_MAX_SPLIT=1 in the record.")
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        # launchd reached in the 1024 capture WITHOUT trap24 marks -> a real regression of 1023/1024
        return verdict("REGRESSION", "launchd reached but NO trap24/port_construct marks - the "
                                     "1023/1024 controls regressed")

    # (3) STACK-SHAPE -- the publisher ran (so the probe IS in the image) but no fault row was
    # captured: the stack placement is confirmed, the fault side is not.  Tested BEFORE FAULT-NOT-RUN
    # because a live ustack row proves the probe reached the object, so "no fault row" means the abort
    # never took the data path - a sharper reading than a bare absence.
    if stk["req"] is not None:
        rc = parse_int(stk["rc"])
        if rc == 0 and len(rows) == 0:
            return verdict("STACK-SHAPE", f"xnu_live_ustack_* present with rc=0 (the FIXED alloc "
                                          f"succeeded) - confirms records/1025-source-trace.txt, but "
                                          f"NO failed-fault row was captured (the abort did not take "
                                          f"the data path, or it did not recur): "
                                          f"req={stk['req']} size={stk['size']} "
                                          f"fixed_addr={stk['fixed_addr']} final={stk['final']}")

    # (4) FAULT-NOT-RUN -- launchd reached, no vmfkrv row AND no ustack row either
    if ctl["launchd"] and len(rows) == 0:
        return verdict("FAULT-NOT-RUN", "launchd reached but NO xnu_live_abt_vmfkrv= row - the abort "
                                        "is not this (data) path, OR the probe did not reach the "
                                        "object (check the record's STAGE90_XNU_USTACK_PROBE=1 and "
                                        "rebuild the pool). If the press shows a PREFETCH abort at the "
                                        "same VA, instrument that arm too (docs/1025-design.md s.7)")

    # (4) FAULT-NAMED -- a vmfkrv row whose far is in the stack window
    named = []
    for r in rows:
        far = parse_int(r.get("far"))
        if far is not None and STACK_LO <= far < STACK_HI:
            named.append((far, r))
    if named:
        details = "; ".join(
            f"far=0x{far:08x} code={r.get('code')}"
            f"({KERN_NAMES.get(parse_int(r.get('code')), '?')})"
            f" dfsr={r.get('dfsr')} prot={r.get('prot')} pc={r.get('pc')} pid={r.get('pid')}"
            for far, r in named)
        # STACK-SHAPE as a co-reading
        shape = ""
        if stk["req"] is not None:
            rc = parse_int(stk["rc"])
            shape = (f" | ustack req={stk['req']} size={stk['size']} fixed_addr={stk['fixed_addr']} "
                     f"rc={stk['rc']}({'OK' if rc == 0 else '?'}) final={stk['final']} "
                     f"guard=[{stk['prot_addr']},+{stk['prot_size']})")
        return verdict("FAULT-NAMED",
                       f"the discarded vm_fault return for the STACK fault is PUBLISHED: {details}{shape}"
                       f"\n            -> the next rung fixes the named cause "
                       f"(KERN_MEMORY_ERROR=anon object, KERN_PROTECTION_FAILURE=perm/exec-refusal, "
                       f"KERN_INVALID_ADDRESS=no vm_map entry when the walk ran)")

    # (5) a vmfkrv row exists but none in the stack window -- the shared-cache fault, not the stack
    if rows:
        details = "; ".join(f"far={r.get('far')} code={r.get('code')}" for r in rows[:4])
        return verdict("NO-CELL", f"vmfkrv rows present but NONE has a far in the stack window "
                                  f"[0x{STACK_LO:08x},0x{STACK_HI:08x}): {details} - the probe "
                                  f"captured a DIFFERENT failed fault; report and re-aim")

    return verdict("NO-CELL", "nothing in the pre-registered table fired; report what was present "
                              "(never fabricate a verdict)")


# ---------------------------------------------------------------------------------------------------
def _mk(tmpdir, name, lines):
    p = os.path.join(tmpdir, name)
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    return p


def self_test():
    tmp = tempfile.mkdtemp(prefix="check1025-selftest-")
    fails = []

    def expect(cell, cap, label):
        got = adjudicate(cap)
        if got != cell:
            fails.append(f"{label}: got {got}, want {cell}")

    # (1) FAULT-NAMED -- the goal: a vmfkrv row with far in the stack window
    expect("FAULT-NAMED", _mk(tmp, "named.txt", [
        "IOS7LAB trap24 frame",
        "IOS7LAB port_construct result=0",
        "*** launchd[1] has started up. ***",
        "launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000",
        "xnu_live_abt_vmfkrv=14",
        "xnu_live_abt_vmfkrv_far=0x2bdbe000",
        "xnu_live_abt_vmfkrv_dfsr=0x807",
        "xnu_live_abt_vmfkrv_prot=write",
        "xnu_live_abt_vmfkrv_pc=0x3adc4756",
        "xnu_live_abt_vmfkrv_pid=2",
        "xnu_live_ustack_req=0x2be00000",
        "xnu_live_ustack_rc=0",
        "xnu_live_ustack_final=0x2be00000",
    ]), "FAULT-NAMED")

    # (2) FAULT-NOT-RUN -- launchd reached, no vmfkrv
    expect("FAULT-NOT-RUN", _mk(tmp, "notrun.txt", [
        "IOS7LAB trap24 frame",
        "*** launchd[1] has started up. ***",
        "launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000",
    ]), "FAULT-NOT-RUN")

    # (3) REGRESSION -- the storm returns
    expect("REGRESSION", _mk(tmp, "storm.txt", [
        "IOS7LAB trap24 frame",
        "*** launchd[1] has started up. ***",
        "xnu_live_abt_far=0x40083008",
        "xnu_live_abt_pcn=0x00100000",
    ]), "REGRESSION")

    # (4) G-CTL -- a dead console, no controls, no panic
    expect("G-CTL", _mk(tmp, "dead.txt", [
        "bsd_init: done",
        "IOS7LAB shared region 0x2c000000..0x40000000",
    ]), "G-CTL")

    # (5) STACK-SHAPE -- ustack but no fault row, launchd reached
    expect("STACK-SHAPE", _mk(tmp, "shape.txt", [
        "IOS7LAB trap24 frame",
        "*** launchd[1] has started up. ***",
        "xnu_live_ustack_req=0x2be00000",
        "xnu_live_ustack_rc=0",
    ]), "STACK-SHAPE")

    # (6) NO-CELL -- a vmfkrv row NOT in the stack window
    expect("NO-CELL", _mk(tmp, "other.txt", [
        "IOS7LAB trap24 frame",
        "*** launchd[1] has started up. ***",
        "xnu_live_abt_vmfkrv=2",
        "xnu_live_abt_vmfkrv_far=0x3adc6031",
    ]), "NO-CELL")

    if fails:
        print("SELFTEST FAILED:")
        for f in fails:
            print("  " + f)
        return 1
    print("selftest PASS (6/6 cells)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="1025 failed-fault / stack-shape capture reader")
    ap.add_argument("capture", nargs="?")
    ap.add_argument("--baseline")
    ap.add_argument("--json", action="store_true")
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