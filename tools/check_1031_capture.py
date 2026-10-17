#!/usr/bin/env python3
"""1031 caller-probe capture reader.

Reads a recovered `/proc/last_kmsg` capture and adjudicates ONE cell naming how the
caller of the writer (`/usr/lib/libobjc.dylib +0x14756`) derived the 4th argument
`r3` that landed on the region's exclusive top.

The 1030 reading (W-B-NAMED) established, BY VALUE, that the faulting store target
IS the region's exclusive top: `r4 == far == user_stack + 0x1000` (post-H2). What
1030 did NOT establish is how the caller PRODUCED that address.

The prior disassembly claim -- the caller derives r3 as `sub.w rN, sp, r#N, lsl #2`
(a DOWNWARD alloca off sp) -- is REFUTED by the raw 1030 frame: with
`sp = 0x2bdac074` and `r4 = sp + 0x1F8C`, r4 lies ABOVE sp, so a sub-off-sp cannot
produce it. The caller's derivation is UNRESOLVED; 1031 is the instrument that
measures it.

The 1031 probe (Site A, trap.c, in the data-abort path) republishes the caller's
register frame plus a region-end lookup:

    xnu_live_cal_r0/r1/r2/r3/r9/r10/r12/r7/r7_minus_sp/lr/pc/far/ustack/
    far_minus_ustack/region_end_hit/region_end/r3_minus_region_end

`region_end` = `vm_map_lookup_entry(map, vm_map_trunc_page(far) - 4, &e); e->vme_end`
-- i.e. the exclusive top of the region CONTAINING `far - 1`. When `far` is the
region's exclusive top this returns `far` itself (region_end_hit == 1).

Cells (see `docs/1031-design.md` §2), fail-closed, NEVER a negative for an absent row:

    CAL-CALLER-TOP    the caller derived r3 == region's exclusive top; r2 == r3
    CAL-CALLER-SIZE   the caller produced the address as a base+size expression
    CAL-CALLER-OTHER  the caller produced it some other way (still named)
    CAL-MISSING       the probe did not run / is incomplete (fail-closed)
    REGRESSION        a prior control broke
    G-CTL             negative control (dead console); expected to STAY dead

The KEY LIST MUST INCLUDE EVERY EMITTED `cal_*` ROW. This is the 1030
`[[mi4-one-value-two-definitions]]` defect: `WRP_KEYS` in the 1030 checker listed
9 of 14 emitted rows, and `group_rows` SPLIT the group, producing W-OTHER on an
otherwise complete capture. Every row the patcher emits is listed here; the
`--selftest` group-split guard asserts the cell is UNCHANGED when emitted-but-unread
rows are stripped.
"""

import argparse
import re
import sys


# ---------------------------------------------------------------------------
# Every row the patcher emits. ORDER = the patcher's emission order.
# r5 is deliberately absent: the writer's prologue clobbers it and the caller
# frame is captured at the CALL SITE (r5 is not a caller argument). Do NOT add a
# key here that the patcher does not emit -- `group_rows` would then never find
# it and split the group (the mirror-image of the 1030 defect).
# ---------------------------------------------------------------------------
CAL_KEYS = (
    "xnu_live_cal_r0",
    "xnu_live_cal_r1",
    "xnu_live_cal_r2",
    "xnu_live_cal_r3",
    "xnu_live_cal_r9",
    "xnu_live_cal_r10",
    "xnu_live_cal_r12",
    "xnu_live_cal_r7",
    "xnu_live_cal_r7_minus_sp",
    "xnu_live_cal_lr",
    "xnu_live_cal_pc",
    "xnu_live_cal_far",
    "xnu_live_cal_ustack",
    "xnu_live_cal_far_minus_ustack",
    "xnu_live_cal_region_end_hit",
    "xnu_live_cal_region_end",
    "xnu_live_cal_r3_minus_region_end",
)

# The writer's prologue: `push {r4,r5,r6,r7,lr}; add r7,sp,#12`. So at the call
# site `r7 == sp + 12`. This is the loud shape of the caller frame.
R7_MINUS_SP_C = 0x0000000C

# The 1030-measured frame delta (r4 - sp). Used only as a secondary size tell.
FRAME_OFF_1030 = 0x00001F8C


def launchd_reached(lines):
    return any("launchd[1] has started up" in ln for ln in lines)


def storm_present(lines):
    """The 1023 storm: far=0x40083008, or a wall of abt rows at one pc (pcn>=0x8000)."""
    for ln in lines:
        if "0x40083008" in ln:
            return True
    for ln in lines:
        m = re.search(r"xnu_live_abt_pcn=(\S+)", ln)
        if m:
            n = parse_int(m.group(1))
            if n is not None and n >= 0x8000:
                return True
    return False


def parse_int(s):
    s = s.strip()
    if not s:
        return None
    try:
        return int(s, 0)
    except ValueError:
        return None


def group_rows(lines, keys, require):
    """Rows carrying `require` (the group SENTINEL), grouped across blank-separated lines.

    The console adds its OWN break after each kernel `printf(...\\n")`, so a BLANK line
    sits between every key and MUST NOT end the group (measured). Only a line with
    CONTENT and none of `keys` ends the group. Matching is by SUBSTRING (a console
    prefix / ANSI colour is harmless).

    `require` is the one row whose presence proves the group exists. EVERY emitted
    row must still be LISTED in `keys` -- an emitted-but-unlisted row makes the group
    SPLIT silently (the 1030 `[[mi4-one-value-two-definitions]]` defect), which the
    `--selftest` group-split guard catches.
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


def cal_rows(lines):
    """The cal group, keyed by the sentinel `xnu_live_cal_r3`."""
    return group_rows(lines, CAL_KEYS, "xnu_live_cal_r3")


def prior_controls(lines):
    """The controls earlier rungs established, read from the REAL console marks.

    These are the exact marks the 1030 checker reads (`IOS7LAB trap24 frame`,
    `port_construct ... result=0`, `*** launchd[1] has started up. ***`) -- not
    invented `xnu_live_*` keys. A control that is read from a key nobody emits is
    a captured-but-unread control (`[[mi4-one-value-two-definitions]]`).
    """
    trap24 = sum(1 for ln in lines if "IOS7LAB trap24 frame" in ln)
    port_construct0 = sum(1 for ln in lines if "port_construct" in ln and "result=0" in ln)
    abt_pc_live = sum(1 for ln in lines if ln.strip().startswith("xnu_live_abt_pc="))
    launchd = launchd_reached(lines)
    panics = sum(1 for ln in lines if "panic" in ln.lower() and "no panic" not in ln.lower())
    return {
        "trap24": trap24,
        "port_construct0": port_construct0,
        "abt_pc_live": abt_pc_live,
        "launchd": launchd,
        "panics": panics,
    }


def verdict(cell, msg):
    print("%s: %s" % (cell, msg))
    return cell


def adjudicate(path):
    try:
        with open(path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        return verdict("CAL-MISSING", "cannot read capture: %s" % e)

    lines = text.splitlines()
    ctl = prior_controls(lines)

    # (1) G-CTL -- fail closed: no control live at all.
    instrument_live = (ctl["launchd"] or ctl["trap24"] > 0 or ctl["abt_pc_live"] > 0)
    if not instrument_live and ctl["panics"] == 0:
        return verdict(
            "G-CTL",
            "neither launchd-reached nor any prior control is live AND no panic -- the "
            "instrument was not sound; WITHHOLD (never a pass)",
        )

    # (2) REGRESSION -- before reading anything about the caller.
    if storm_present(lines):
        return verdict(
            "REGRESSION",
            "the 1023 abort storm signature is present -- the arm's switch set is wrong. "
            "This is NOT a 1031 reading",
        )
    if ctl["panics"]:
        return verdict("REGRESSION", "a panic is present in the capture (%d)" % ctl["panics"])
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        return verdict(
            "REGRESSION",
            "launchd reached but NO trap24 / port_construct marks -- the 1023/1024 controls "
            "regressed",
        )

    cal = cal_rows(lines)
    if not cal:
        return verdict(
            "CAL-MISSING",
            "no cal group carrying the sentinel `xnu_live_cal_r3` -- the probe did not run. "
            "Fail-closed: this is NOT a negative reading.",
        )
    cal = {k: parse_int(v) for k, v in cal[0].items()}

    r3 = cal.get("xnu_live_cal_r3")
    r2 = cal.get("xnu_live_cal_r2")
    far = cal.get("xnu_live_cal_far")
    re_hit = cal.get("xnu_live_cal_region_end_hit")
    re_end = cal.get("xnu_live_cal_region_end")
    r7ms = cal.get("xnu_live_cal_r7_minus_sp")
    r3mre = cal.get("xnu_live_cal_r3_minus_region_end")

    # The group is only trustworthy if the rows the cells READ are present. An
    # emitted-but-UNLISTED row would have split the group ([[mi4-one-value-two-definitions]]);
    # a MISSING required operand is fail-closed.
    if r3 is None or r2 is None or far is None or re_hit is None or re_end is None:
        return verdict(
            "CAL-MISSING",
            "the cal group closed but a required operand is absent "
            "(r3=%s r2=%s far=%s region_end_hit=%s region_end=%s): the probe is incomplete. "
            "Fail-closed: NOT a negative reading."
            % (r3, r2, far, re_hit, re_end),
        )

    # Derive r3_minus_region_end when the emitter omitted it (both operands honest).
    if r3mre is None:
        r3mre = (r3 - re_end) & 0xFFFFFFFF

    # ---- CAL-CALLER-TOP: the caller derived r3 == the region's exclusive top.
    # The specific tell: the region-end lookup HIT (region_end_hit == 1), the
    # looked-up end IS far, and the caller's r3 (and its copy r2) equal it too.
    if (re_hit == 1 and re_end is not None and far is not None
            and re_end == far and r3 == far and r2 == far):
        # The loud frame shape (writer prologue: r7 == sp + 12) confirms we read
        # the RIGHT call site, not a lookalike.
        shape = "r7-sp=%#x" % (r7ms if r7ms is not None else -1)
        if r7ms != R7_MINUS_SP_C:
            return verdict(
                "CAL-CALLER-OTHER",
                "r3 == far == region top, but the frame shape is wrong (%s != %#x): "
                "early return before the call. NOT CAL-CALLER-TOP." % (shape, R7_MINUS_SP_C),
            )
        return verdict(
            "CAL-CALLER-TOP",
            "r3 == r2 == far == region_end == %#x (region_end_hit=1, r7-sp=%#x): the caller "
            "derived the WRITE ADDRESS as the stack region's exclusive top. The address is "
            "the region's END, not a base+size the caller computed." % (far, r7ms),
        )

    # ---- CAL-CALLER-SIZE: the caller produced the address as a base+size
    # expression -- r3 is NOT the region end but sits at a fixed, small distance
    # from a stack base, and r2 == r3 (the caller passed the same value twice).
    if (re_hit == 1 and r3 is not None and re_end is not None
            and r3 != re_end and r3mre is not None and 0 < r3mre <= 0x1000
            and r2 == r3):
        return verdict(
            "CAL-CALLER-SIZE",
            "r3 == r2 == %#x, region_end == %#x (delta %#x <= 0x1000): the caller produced the "
            "address as a base+size expression one page short of the region end."
            % (r3, re_end, r3mre),
        )

    # ---- CAL-CALLER-OTHER: a complete frame, but it names neither shape.
    return verdict(
        "CAL-CALLER-OTHER",
        "a complete caller frame but it matches neither shape: r0=%s r1=%s r2=%s r3=%s "
        "far=%s region_end=%s( hit=%s ) r7-sp=%s lr=%s pc=%s"
        % (cal.get("xnu_live_cal_r0"), cal.get("xnu_live_cal_r1"), r2, r3, far, re_end, re_hit,
           r7ms, cal.get("xnu_live_cal_lr"), cal.get("xnu_live_cal_pc")),
    )


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------
def self_test():
    import os
    import re as _re
    import tempfile

    fails = []
    tmp = tempfile.mkdtemp(prefix="chk1031-")

    # **PARITY IS A CHECK, NOT A CLAIM** ([[mi4-a-claim-in-a-comment-is-not-a-check]]): the patcher
    # and this checker are two definitions of ONE key set. An emitted-but-UNLISTED row SPLITS the
    # group silently (the 1030 defect). Assert the parity against the REAL patcher source.
    _here = os.path.dirname(os.path.abspath(__file__))
    _pat = os.path.join(_here, "patch_d13_caller_probe.py")
    try:
        with open(_pat) as _fh:
            _src = _fh.read()
    except OSError:
        fails.append("parity: cannot read %s" % _pat)
    else:
        _emit = set(_re.findall(r"xnu_live_cal_[a-z0-9_]+(?==)", _src))
        # Only the console ROWS (a trailing `=` in the printf), not the function names.
        _emit = set(_re.findall(r"xnu_live_cal_[a-z0-9_]+=", _src))
        _emit = {e[:-1] for e in _emit}
        _listed = set(CAL_KEYS)
        if _emit - _listed:
            fails.append("parity: emitted-but-UNLISTED rows would SPLIT the group: %s"
                         % sorted(_emit - _listed))
        if _listed - _emit:
            fails.append("parity: listed-but-unemitted rows: %s" % sorted(_listed - _emit))

    def _mk(d, name, lines):
        p = os.path.join(d, name)
        with open(p, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        return p

    def _blank_sep(lines):
        out = []
        for ln in lines:
            out.append(ln)
            out.append("")
        return out

    def expect(cell, path, label):
        got = adjudicate(path)
        if got != cell:
            fails.append("%s: expected %s, got %s" % (label, cell, got))

    # A live console: the REAL control marks (exactly what the 1030 capture shows)
    # plus a COMPLETE cal group, in the patcher's REAL emission order.
    ctl = [
        "*** launchd[1] has started up. ***",
        "IOS7LAB trap24 frame r0=00000103 r1=2bd66350 r2=14543610 r3=00000000",
        "IOS7LAB port_construct flags=12 qlimit=6 context=00000000:14543610 result=0 name=707",
        "xnu_live_abt_pc=0x38b52756",
        "xnu_live_abt_seq=1",
    ]
    entry = [
        "xnu_live_abt_ustack=0x2bdad000",
    ]

    # CAL-CALLER-TOP: r3 == r2 == far == region_end, region_end_hit == 1, r7-sp == 0xC.
    cal_top = [
        "xnu_live_cal_r0=0x37c0f000",
        "xnu_live_cal_r1=0x00000014",
        "xnu_live_cal_r2=0x2bdae000",
        "xnu_live_cal_r3=0x2bdae000",
        "xnu_live_cal_r9=0x37c0f100",
        "xnu_live_cal_r10=0x2bdac100",
        "xnu_live_cal_r12=0x00000003",
        "xnu_live_cal_r7=0x2bdac080",
        "xnu_live_cal_r7_minus_sp=0x0000000c",
        "xnu_live_cal_lr=0x38b4a9af",
        "xnu_live_cal_pc=0x38b52756",
        "xnu_live_cal_far=0x2bdae000",
        "xnu_live_cal_ustack=0x2bdad000",
        "xnu_live_cal_far_minus_ustack=0x00001000",
        "xnu_live_cal_region_end_hit=1",
        "xnu_live_cal_region_end=0x2bdae000",
        "xnu_live_cal_r3_minus_region_end=0x00000000",
    ]
    expect("CAL-CALLER-TOP", _mk(tmp, "top.txt", ctl + entry + cal_top), "CAL-CALLER-TOP")

    # CAL-CALLER-SIZE: r3 == r2, one page short of the region end.
    cal_size = list(cal_top)
    for _i, _ln in enumerate(cal_size):
        if _ln.startswith("xnu_live_cal_r2="):
            cal_size[_i] = "xnu_live_cal_r2=0x2bdad000"
        if _ln.startswith("xnu_live_cal_r3="):
            cal_size[_i] = "xnu_live_cal_r3=0x2bdad000"
        if _ln.startswith("xnu_live_cal_r3_minus_region_end="):
            cal_size[_i] = "xnu_live_cal_r3_minus_region_end=0x00001000"
    expect("CAL-CALLER-SIZE", _mk(tmp, "size.txt", ctl + entry + cal_size), "CAL-CALLER-SIZE")

    # CAL-CALLER-OTHER: a complete frame naming neither shape (r2 != r3).
    cal_other = list(cal_top)
    for _i, _ln in enumerate(cal_other):
        if _ln.startswith("xnu_live_cal_r2="):
            cal_other[_i] = "xnu_live_cal_r2=0x2bd90000"
        if _ln.startswith("xnu_live_cal_r3="):
            cal_other[_i] = "xnu_live_cal_r3=0x2bd90000"
        if _ln.startswith("xnu_live_cal_r3_minus_region_end="):
            cal_other[_i] = "xnu_live_cal_r3_minus_region_end=0x00056000"
    expect("CAL-CALLER-OTHER", _mk(tmp, "other.txt", ctl + entry + cal_other), "CAL-CALLER-OTHER")

    # CAL-CALLER-OTHER (degenerate): r3 == far == region_end but the FRAME SHAPE is
    # wrong (r7 != sp + 12) -- an early return before the call. The TOP tell is the
    # specific one; a lookalike frame must NOT win it.
    cal_shape = list(cal_top)
    for _i, _ln in enumerate(cal_shape):
        if _ln.startswith("xnu_live_cal_r7_minus_sp="):
            cal_shape[_i] = "xnu_live_cal_r7_minus_sp=0x00000000"
    expect("CAL-CALLER-OTHER", _mk(tmp, "shape.txt", ctl + entry + cal_shape),
           "CAL-CALLER-OTHER-wrong-frame-shape")

    # CAL-MISSING: NO cal row at all -- the probe did not run. NEVER a negative.
    expect("CAL-MISSING", _mk(tmp, "norow.txt", ctl + entry), "CAL-MISSING-no-probe-row")

    # CAL-MISSING: an INCOMPLETE group (a READ operand absent, sentinel still present) -- fail-closed.
    cal_partial = [ln for ln in cal_top if not ln.startswith("xnu_live_cal_region_end=")]
    expect("CAL-MISSING", _mk(tmp, "partial.txt", ctl + entry + cal_partial),
           "CAL-MISSING-incomplete-group")

    # REGRESSION: the 1023 storm is back.
    expect("REGRESSION", _mk(tmp, "storm.txt", ctl + [
        "xnu_live_abt_far=0x40083008",
        "xnu_live_abt_pcn=0x00100000",
    ]), "REGRESSION-storm")

    # REGRESSION: a panic is present.
    expect("REGRESSION", _mk(tmp, "panic.txt", ctl + entry + cal_top + [
        "Kernel panic - not syncing: something",
    ]), "REGRESSION-panic")

    # REGRESSION: launchd reached but BOTH trap24 and port_construct marks are gone.
    ctl_not24 = [ln for ln in ctl
                 if "trap24 frame" not in ln and "port_construct" not in ln]
    expect("REGRESSION", _mk(tmp, "not24.txt", ctl_not24 + entry + cal_top),
           "REGRESSION-controls")

    # G-CTL: a dead console (no control live, no panic).
    expect("G-CTL", _mk(tmp, "dead.txt", [
        "bsd_init: done",
        "IOS7LAB shared region 0x2c000000..0x40000000",
    ]), "G-CTL-dead")

    # **THE GROUP-SPLIT GUARD.** The same CAL-CALLER-TOP capture with the
    # emitted-but-UNREAD rows (`r0`, `r1`, `r9`, `r10`, `r12`, both `lr`/`pc`) REMOVED
    # must give the SAME cell: if dropping an emitted row changes the verdict, CAL_KEYS
    # is missing that row and the real capture's group will split -- exactly the 1030
    # defect (`WRP_KEYS` listed 9 of 14). Only purely decorative rows are stripped.
    cal_stripped = [ln for ln in cal_top if not any(
        ln.startswith("xnu_live_cal_%s=" % k)
        for k in ("r0", "r1", "r9", "r10", "r12", "lr", "pc", "far_minus_ustack"))]
    expect("CAL-CALLER-TOP", _mk(tmp, "stripped.txt", ctl + entry + cal_stripped),
           "CAL-CALLER-TOP-with-emitted-rows-stripped (group-split guard)")

    # BLANK-SEPARATED keys (the measured console shape) must still group into ONE row.
    expect("CAL-CALLER-TOP", _mk(tmp, "blank.txt", _blank_sep(ctl + entry + cal_top)),
           "blank-separated")

    # ANSI/console prefix on the values must not corrupt them.
    ansi = ["\x1b[0m launchctl[2]: " + ln for ln in ctl + entry + cal_top]
    expect("CAL-CALLER-TOP", _mk(tmp, "ansi.txt", ansi), "ansi-prefixed")

    # `r3 - region_end` omitted from the capture: the checker must DERIVE it from
    # r3/region_end (both honest).
    cal_nodelta = [ln for ln in cal_top if "r3_minus_region_end" not in ln]
    expect("CAL-CALLER-TOP", _mk(tmp, "nodelta.txt", ctl + entry + cal_nodelta),
           "r3-region_end-derived-from-keys")

    if fails:
        print("SELFTEST FAILED:")
        for f in fails:
            print("  " + f)
        return 1
    print("selftest PASS (14 cases)")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="1031 caller-probe capture reader")
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