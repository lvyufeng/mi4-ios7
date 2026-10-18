#!/usr/bin/env python3
"""1032 reader -- DID THE COUNT CLAMP HOLD?

The arm is 1031's own (armed-d13-49031dcb): the same probes and switches.  The ONLY change is 10 bytes in
libobjc, inside the dyld shared cache the card holds.  1031's rows therefore become the INSTRUMENT of
whether the fault still happens:

    fault still happens  -> the SAME cal group prints (1031's CAL-CALLER-OTHER frame)      => FIX-NOOP
    fault removed        -> the cal group CANNOT print (it lives on the fault path),
                            launchd still comes up and the trap24 / port_construct controls
                            are still live (the instrument was sound)                        => FIX-HOLDS
    nothing else         -> fail closed                                                       => G-CTL/WITHHOLD

**ABSENCE IS ONLY A READING IF THE INSTRUMENT WAS SOUND.**  A missing cal group with no positive evidence
that the boot got past the fault point is WITHHOLD, never FIX-HOLDS ([[mi4-silence-is-a-reading-only-if-
success-is-silent]]).

    FIX-HOLDS        the fault-path rows are absent AND launchd reached AND trap24/port_construct live
    FIX-NOOP         the cal group prints, with 1031's frame by value
    FIX-PARTIAL      the cal group prints but the frame changed (name it; do not pick another fix blind)
    REGRESSION       a panic, the 1023 storm, or launchd reached with no controls
    G-CTL / WITHHOLD no positive evidence at all (fail closed)

Usage:  python3 -I tools/check_1032_capture.py <capture.txt>     exit 0 cell fired, 1 withhold
        python3 -I tools/check_1032_capture.py --selftest
"""
import re
import sys

# Every row the 1031 patcher emits (the checker's group parity depends on this list -- see
# check_1031_capture.py CAL_KEYS; TOO FEW keys SPLITS the group, which is the 1030 defect).
CAL_KEYS = (
    "xnu_live_cal_r0", "xnu_live_cal_r1", "xnu_live_cal_r2", "xnu_live_cal_r3",
    "xnu_live_cal_r9", "xnu_live_cal_r10", "xnu_live_cal_r12", "xnu_live_cal_r7",
    "xnu_live_cal_r7_minus_sp", "xnu_live_cal_lr", "xnu_live_cal_pc",
    "xnu_live_cal_far", "xnu_live_cal_ustack", "xnu_live_cal_far_minus_ustack",
    "xnu_live_cal_region_end_hit", "xnu_live_cal_region_end", "xnu_live_cal_r3_minus_region_end",
)

# 1031's repeated frame (the two byte-identical reads, records/1031-press-read.txt).  Used to decide
# FIX-NOOP vs FIX-PARTIAL: if the frame is reproduced, the patch did nothing; if the frame differs, the
# patch changed something and the new frame needs naming.
FRAME_1031 = {
    "xnu_live_cal_r0": 0xFFFFF820,
    "xnu_live_cal_r1": 0x389A7F18,
    "xnu_live_cal_r2": 0x3896DC00,
    "xnu_live_cal_r3": 0xFFFFFFFF,
    "xnu_live_cal_far": 0x2BDD0000,
    "xnu_live_cal_region_end": 0x2BDD0000,
    "xnu_live_cal_region_end_hit": 1,
    "xnu_live_cal_far_minus_ustack": 0x1000,
    "xnu_live_cal_r7_minus_sp": 0xC,
    "xnu_live_cal_lr": 0x388199AF,
    "xnu_live_cal_pc": 0x38821756,
}


def parse_int(s):
    s = s.strip()
    if not s:
        return None
    try:
        return int(s, 0)
    except ValueError:
        return None


def group_rows(lines, keys, require):
    key_rx = [(k, re.compile(re.escape(k) + r"=([^\s\x1b\[]+)")) for k in keys]
    rows, cur = [], {}
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


def storm_present(lines):
    for ln in lines:
        if "0x40083008" in ln:
            return True
        m = re.search(r"xnu_live_abt_pcn=(\S+)", ln)
        if m:
            n = parse_int(m.group(1))
            if n is not None and n >= 0x8000:
                return True
    return False


def controls(lines):
    return {
        "trap24": sum(1 for ln in lines if "IOS7LAB trap24 frame" in ln),
        "port_construct0": sum(1 for ln in lines if "port_construct" in ln and "result=0" in ln),
        "launchd": any("launchd[1] has started up" in ln for ln in lines),
        "abt_pc_live": sum(1 for ln in lines if ln.strip().startswith("xnu_live_abt_pc=")),
        "panics": sum(1 for ln in lines if "panic" in ln.lower() and "no panic" not in ln.lower()),
    }


def verdict(cell, msg):
    print("%s: %s" % (cell, msg))
    return cell


def frame_matches_1031(cal):
    got = {k: parse_int(v) for k, v in cal.items()}
    diffs = []
    for k, want in FRAME_1031.items():
        have = got.get(k)
        if have is not None and have != want:
            diffs.append("%s=%#x (was %#x)" % (k, have, want))
    return not diffs, diffs


def adjudicate(path):
    try:
        with open(path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        return verdict("G-CTL", "cannot read capture: %s" % e)
    lines = text.splitlines()
    ctl = controls(lines)

    instrument_live = (ctl["launchd"] or ctl["trap24"] > 0 or ctl["port_construct0"] > 0
                       or ctl["abt_pc_live"] > 0)
    if not instrument_live and ctl["panics"] == 0:
        return verdict("G-CTL", "no launchd, no control live, no panic -- the instrument was not sound; "
                                "WITHHOLD (never a pass)")

    if storm_present(lines):
        return verdict("REGRESSION", "the 1023 abort storm is present -- the arm's switch set is wrong")
    if ctl["panics"]:
        return verdict("REGRESSION", "a panic is present (%d)" % ctl["panics"])
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        return verdict("REGRESSION", "launchd reached but NO trap24 / port_construct marks -- the "
                                     "1023/1024 controls regressed")

    cal = group_rows(lines, CAL_KEYS, "xnu_live_cal_r3")
    if cal:
        same, diffs = frame_matches_1031(cal[0])
        if same:
            c = {k: parse_int(v) for k, v in cal[0].items()}
            return verdict("FIX-NOOP", "the SAME 1031 frame now: r3=%#x far=%#x region_end=%#x "
                                       "r7-sp=%#x pc=%#x -- the writer still runs away, the clamp did "
                                       "not remove this fault"
                           % (c["xnu_live_cal_r3"], c["xnu_live_cal_far"],
                              c["xnu_live_cal_region_end"], c["xnu_live_cal_r7_minus_sp"],
                              c["xnu_live_cal_pc"]))
        return verdict("FIX-PARTIAL", "the cal frame changed: " + "; ".join(diffs)
                       + " -- the patch altered the failing path; name the new frame, do not pick "
                         "another fix blind")

    # No cal group.  That is FIX-HOLDS ONLY if the boot demonstrably got past where the fault used to
    # fire: launchd up, and the controls that live PAST the fault still present.
    if ctl["launchd"] and ctl["trap24"] > 0 and ctl["port_construct0"] > 0:
        return verdict("FIX-HOLDS", "no cal group (the fault-path probe never ran) AND launchd reached "
                                   "with the trap24/port_construct controls live -- the writer no longer "
                                   "runs away off the stack end")
    if not ctl["launchd"]:
        return verdict("WITHHOLD", "no cal group, but launchd was NOT reached either -- the fault-path "
                                   "probe prints only on a fault, so silence alone does not prove the "
                                   "fault is gone. NO READING: this is the fault's ABSENCE OR an earlier "
                                   "stop; the boot did not get far enough to tell")
    return verdict("WITHHOLD", "no cal group and incomplete positive evidence (launchd=%s trap24=%d "
                               "port_construct0=%d) -- fail closed"
                   % (ctl["launchd"], ctl["trap24"], ctl["port_construct0"]))


# ---------------------------------------------------------------------------
def self_test():
    import tempfile, os

    def mk(name, lines):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write("\n".join(lines) + "\n")
        return p

    fails = []
    tmp = tempfile.mkdtemp(prefix="chk1032-")

    def expect(cell, path, label):
        got = adjudicate(path)
        if got != cell:
            fails.append("%s: got %s want %s" % (label, got, cell))
        print("   ok" if got == cell else "   FAIL", label, "->", got)

    def _base(mark):
        return ["   [%s] kernel: a b c" % mark, "", "*** launchd[1] has started up. ***",
                "", "   [x] kernel: IOS7LAB trap24 frame", "",
                "   [x] kernel: port_construct ok result=0", ""]

    no_cal = _base("ctl")
    expect("FIX-HOLDS", mk("holds.txt", no_cal), "controls live, no cal group")

    # a 1031-shaped cal group -> FIX-NOOP
    cal_lines = no_cal + [
        "   [x] kernel: xnu_live_cal_r0=0xfffff820", "",
        "   [x] kernel: xnu_live_cal_r1=0x389a7f18", "",
        "   [x] kernel: xnu_live_cal_r2=0x3896dc00", "",
        "   [x] kernel: xnu_live_cal_r3=0xffffffff", "",
        "   [x] kernel: xnu_live_cal_far=0x2bdd0000", "",
        "   [x] kernel: xnu_live_cal_ustack=0x2bdcf000", "",
        "   [x] kernel: xnu_live_cal_far_minus_ustack=0x1000", "",
        "   [x] kernel: xnu_live_cal_region_end_hit=1", "",
        "   [x] kernel: xnu_live_cal_region_end=0x2bdd0000", "",
        "   [x] kernel: xnu_live_cal_r7_minus_sp=0xc", "",
        "   [x] kernel: xnu_live_cal_lr=0x388199af", "",
        "   [x] kernel: xnu_live_cal_pc=0x38821756", "",
    ]
    expect("FIX-NOOP", mk("noop.txt", cal_lines), "the 1031 frame reproduces")

    partial = list(cal_lines)
    for i, ln in enumerate(partial):
        if "xnu_live_cal_r3=" in ln:
            partial[i] = ln.replace("0xffffffff", "0x00000000")
    expect("FIX-PARTIAL", mk("partial.txt", partial), "the cal frame changed")

    storm = _base("ctl") + ["   [x] kernel: xnu_live_abt_pcn=0x9000", ""]
    expect("REGRESSION", mk("storm.txt", storm), "the 1023 storm is back")

    pan = _base("ctl") + ["   [x] kernel: panic: boom", ""]
    expect("REGRESSION", mk("panic.txt", pan), "a panic")

    expect("G-CTL", mk("dead.txt", ["", "   [x] kernel: nothing here", ""]), "dead console")

    la = ["*** launchd[1] has started up. ***", "", "   [x] kernel: IOS7LAB trap24 frame", ""]
    expect("WITHHOLD", mk("withhold.txt", la), "launchd but no port_construct control")

    # fault fired but launchd not reached: cal present but launchd absent -> still NOOP (the frame IS the
    # fault; the boot's reach does not change that).
    nolaunch = [ln for ln in cal_lines if "launchd" not in ln]
    expect("FIX-NOOP", mk("nolaunch.txt", nolaunch), "cal present, launchd absent (still NOOP)")

    # NO cal group, NO launchd, but a control IS live (so G-CTL does not swallow it): silence alone must
    # NOT read as FIX-HOLDS -- this is the fault's absence OR an earlier stop, and nothing tells them
    # apart ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).
    nocall_no_launchd = ["   [x] kernel: IOS7LAB trap24 frame", "",
                         "   [x] kernel: port_construct ok result=0", ""]
    expect("WITHHOLD", mk("silent_early.txt", nocall_no_launchd),
           "no cal, no launchd, controls live -> fail closed (NOT FIX-HOLDS)")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (%d fixtures, all cells fire)" % 9)
    return 0


def main(argv):
    if "--selftest" in argv:
        return self_test()
    if len(argv) != 1:
        print(__doc__.split("Usage:")[0], file=sys.stderr)
        return 1
    cell = adjudicate(argv[0])
    return 0 if cell.startswith(("FIX-", "CAL-")) else 1


if __name__ == "__main__":
    # THE PARK NAMES THIS COPY check_1032_capture.py (records/revert-set.txt: a `file=` may carry no
    # path separator and a copy under the ORIGINAL name would tell verify_revert_set.sh the live tree
    # must carry it), and the park copy names the tool it was derived from.  A copy that cannot RUN is
    # not a pinned definition; the usage error has exit 2, so this cannot fail a real invocation.
    import os
    me = os.path.abspath(__file__)
    if os.path.basename(me) != "check_1032_capture.py":
        print("check_1032_capture: this is the park's copy (%s); the live tool is tools/check_1032_capture.py"
              % os.path.basename(me), file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))