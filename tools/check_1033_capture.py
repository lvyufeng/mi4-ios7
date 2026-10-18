#!/usr/bin/env python3
"""1033 reader -- THE EVAL FRAME: name the 1032 launchctl[2] abort BY VALUE.

The kernel publishes RAW values only (xnu_live_evf_* rows, tools/patch_d13_eval_frame.py); EVERY predicate
below is applied here.  Reason: the kernel cannot know which slide the user's pc belongs to without a card
assumption, and 1031's static address map was wrong for these bytes already (docs/1033-design.md §2.4).

The question: at the launchctl[2] abort, what is the RAW DFAR, what word does the frame's own sp+0x10 hold,
and is the frame's pc the target of a `bl` from the frame's caller?

    EVF-U1-TRUE     far_raw == 0x10 AND (walk_pc_ok == 1 OR lr_slot_ok == 1)
                    => the faulting access IS [0x10] (NULL+0x10 in launchctl[2]) and the frame carries a
                       call site decode: name the caller deref from slot10 / lr_slot next.
    EVF-U1-SUSPECT  far_raw == 0x10 AND NEITHER decode present
                    => the access is [0x10] but the pc is not shown to be an instruction. NO fix; next
                       rung = a static disassembly of the SLID pc window from the stage's own slide.
    EVF-U2-MISTAKE  far_raw not in {0x10, 0x0} AND far_raw is a user VA whose slide base is NOT the stage's
                    mapping-0 base (cache-file offset is a file-length-ish/negative value)
                    => the 1032 pc/far pair is inconsistent with any real faulting instruction. NO fix.
    EVF-U2-SLIDE0   far_raw not in {0x10, 0x0} AND far_raw - cachemap_slide is a cache-file offset
                    => the fault VA is image-relative: the 1032 "slide 0x3921000" does not describe this.
    EVF-FAR0        far_raw == 0x0  => the message's 0x10 is NOT the DFAR; the 1032 reading's premise is
                    refuted. NO fix; re-preregister.
    EVF-NOPLANE     no evf group at all but a cal group prints (the parent rows ran, the eval block did
                    not) OR read_src == 2 on the only burst (a guarded read failed)
                    => a build/probe defect, NOT a negative.
    EVF-MISSING     no evf group, no cal group, launchd not reached: fail closed, re-read.
    EVF-PANIC       a panic OR the 1023 storm OR launchd reached with no trap24/port_construct controls.
    G-CTL           nothing live at all: the instrument was not sound; WITHHOLD.

A cell is decided only by rows PRESENT in the capture; an ABSENT row is never a negative.

Usage:  python3 -I tools/check_1033_capture.py <capture.txt>       exit 0 cell fired, 1 withhold
        python3 -I tools/check_1033_capture.py --selftest
        python3 -I tools/check_1033_capture.py --predicted pc_minus_far=0x18,far_raw=0x10
                                                                  (print-only prediction table, §8)
"""
import re
import sys

CACHE_VA_BASE = 0x2C000000          # cache map0 base (patch_cache_libobjc_count.py asserts it)
CACHE_SIZE = 0x0C000000             # map0's extent (dyld_v1 armv7, iOS 7.1.2); a file offset lies in it
EVF_KEYS = (
    "xnu_live_evf_seq", "xnu_live_evf_pid", "xnu_live_evf_pc", "xnu_live_evf_lr", "xnu_live_evf_sp",
    "xnu_live_evf_cpsr", "xnu_live_evf_far_raw", "xnu_live_evf_far_trunc", "xnu_live_evf_far_is_0x10",
    "xnu_live_evf_far_is_0", "xnu_live_evf_dfsr_raw", "xnu_live_evf_fault_code",
    "xnu_live_evf_pc_minus_far", "xnu_live_evf_lr_minus_sp", "xnu_live_evf_caller_r0",
    "xnu_live_evf_caller_r1", "xnu_live_evf_caller_r2", "xnu_live_evf_caller_r3",
    "xnu_live_evf_caller_r7", "xnu_live_evf_caller_r4_minus_sp", "xnu_live_evf_slot10",
    "xnu_live_evf_slot10_ok", "xnu_live_evf_slot14", "xnu_live_evf_slot14_ok", "xnu_live_evf_slot18",
    "xnu_live_evf_slot18_ok", "xnu_live_evf_ptr_word", "xnu_live_evf_ptr_word_ok",
    "xnu_live_evf_lr_slot", "xnu_live_evf_lr_slot_ok", "xnu_live_evf_read_src", "xnu_live_evf_ustack",
)
CAL_KEYS = ("xnu_live_cal_r3", "xnu_live_cal_region_end_hit", "xnu_live_cal_region_end",
            "xnu_live_cal_pc")

# 1032's published frame, at the slide the 1032 stage printed (records/1032-reading.txt §3).
FRAME_1032 = {
    "xnu_live_evf_pc": 0x3B547474,
    "xnu_live_evf_lr": 0x3B53F9AF,
    "xnu_live_evf_sp": 0x2BDCF088,
    "xnu_live_evf_cpsr": 0x30,
    "xnu_live_evf_pc_minus_far": 0x18,       # for far 0x10: the +8-offset-applied-to-0x10 number
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
        "panics": sum(1 for ln in lines if "panic" in ln.lower() and "no panic" not in ln.lower()),
        "slide": mapping0(lines),
    }


def mapping0(lines):
    """The stage's OWN mapping-0 slide: `IOS7LAB cache mapping 0 nav=2f921000` -> 0x2f921000.  Reads the
    nav of mapping index 0 only; any other index is a different row and is not this value."""
    for ln in reversed(lines):
        m = re.search(r"IOS7LAB cache mapping 0 nav=([0-9a-fA-F]+)", ln)
        if m:
            n = parse_int("0x" + m.group(1))
            if n is not None:
                return n
    return None


def verdict(cell, msg):
    print("%s: %s" % (cell, msg))
    return cell


def is_file_offset(x):
    return 0 <= x < CACHE_SIZE


def adjudicate(path):
    try:
        with open(path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        return verdict("G-CTL", "cannot read capture: %s" % e)
    lines = text.splitlines()
    ctl = controls(lines)

    live = ctl["launchd"] or ctl["trap24"] > 0 or ctl["port_construct0"] > 0
    if not live and ctl["panics"] == 0:
        return verdict("G-CTL", "no launchd, no control live, no panic -- the instrument was not sound; "
                                "WITHHOLD (never a pass)")

    if storm_present(lines):
        return verdict("EVF-PANIC", "the 1023 abort storm is present -- the arm's switch set is wrong")
    if ctl["panics"]:
        return verdict("EVF-PANIC", "a panic is present (%d) -- the eval block or its guarded reads are "
                                    "implicated" % ctl["panics"])
    if ctl["launchd"] and ctl["trap24"] == 0 and ctl["port_construct0"] == 0:
        return verdict("EVF-PANIC", "launchd reached but NO trap24 / port_construct marks -- the "
                                    "1023/1024 controls regressed")

    groups = group_rows(lines, EVF_KEYS, "xnu_live_evf_seq")
    if not groups:
        cal = group_rows(lines, CAL_KEYS, "xnu_live_cal_r3")
        if cal:
            return verdict("EVF-NOPLANE", "a cal group prints but NO evf group -- the parent rows ran and "
                                          "the eval block did not (a build defect: EVAL_FRAME not in the "
                                          "pool). NO READING.")
        if not ctl["launchd"]:
            return verdict("EVF-MISSING", "no evf group and launchd not reached -- fail closed; re-read, "
                                          "do not judge")
        return verdict("EVF-MISSING", "no evf group, no cal group, launchd reached -- the fault path did "
                                      "not run this boot. NOT a pass, NOT a negative: re-preregister.")

    g = groups[0]
    v = {k: parse_int(val) for k, val in g.items()}
    summary = "pc=%s lr=%s sp=%s far=%s pc-far=%s dfsr=%s slot10=%s/%s lr_slot_ok=%s seq=%s" % (
        g.get("xnu_live_evf_pc"), g.get("xnu_live_evf_lr"), g.get("xnu_live_evf_sp"),
        g.get("xnu_live_evf_far_raw"), g.get("xnu_live_evf_pc_minus_far"),
        g.get("xnu_live_evf_dfsr_raw"), g.get("xnu_live_evf_slot10"), g.get("xnu_live_evf_slot10_ok"),
        g.get("xnu_live_evf_lr_slot_ok"), g.get("xnu_live_evf_seq"))

    far = v.get("xnu_live_evf_far_raw")
    if far is None:
        return verdict("EVF-MISSING", "the evf group has no far_raw row (%s) -- the group's confirming "
                                      "value is absent; re-read" % summary)
    if v.get("xnu_live_evf_read_src") == 2 and v.get("xnu_live_evf_slot10_ok") == 0:
        return verdict("EVF-NOPLANE", "read_src=2 and slot10_ok=0 on the first burst (%s) -- the guarded "
                                      "userspace read failed; fall back to the uss-only variant" % summary)
    if far == 0x0:
        return verdict("EVF-FAR0", "far_raw == 0x0 (%s): the message's 0x10 is NOT the DFAR -- 1032's "
                                   "premise is refuted by value. NO fix; re-preregister" % summary)
    if far == 0x10:
        lr_slot_ok = v.get("xnu_live_evf_lr_slot_ok")
        walk_ok = v.get("xnu_live_evf_walk_pc_ok")     # absent on this arm: never a negative
        if walk_ok == 1 or lr_slot_ok == 1:
            return verdict("EVF-U1-TRUE", "[0x10] is the faulting access (%s); lr_slot_ok=%s walk_pc_ok=%s "
                                          "-- the NULL+0x10 carrier is named by slot10 / lr_slot; next rung "
                                          "= the caller deref" % (summary, lr_slot_ok, walk_ok))
        return verdict("EVF-U1-SUSPECT", "[0x10] is the faulting access (%s) but NEITHER the lr_slot call "
                                         "decode NOR a caller walk confirms the pc is an instruction. NO "
                                         "fix; next rung = a static disassembly of the SLID pc window"
                       % summary)
    slide = ctl["slide"]
    if slide is not None:
        rel = (far - slide) & 0xFFFFFFFF
        if is_file_offset(rel):
            return verdict("EVF-U2-SLIDE0", "far_raw=%#x is image-relative: far - mapping0 (%#x) = %#x is a "
                                            "cache-file offset (%s). The 1032 slide does not describe this "
                                            "fault" % (far, slide, rel, summary))
        return verdict("EVF-U2-MISTAKE", "far_raw=%#x is a user VA whose mapping-0 base (%#x) is NOT this "
                                         "image's slide: far - slide = %#x is neither a cache-file offset "
                                         "nor 0x10 (%s). the 1032 pc/far pair is inconsistent with any "
                                         "real faulting instruction. NO fix" % (far, slide, rel, summary))
    return verdict("EVF-MISSING", "far_raw=%#x is neither 0x10 nor 0x0, and no `IOS7LAB cache mapping 0 "
                                  "nav=` row is present to place it (%s) -- re-read" % (far, summary))


# ---------------------------------------------------------------------------
def predicted(argv):
    """Print-only: the §8 table's row 1-2 expectations side by side with values the caller supplies."""
    want = {"far_raw": 0x10, "pc_minus_far": 0x18}
    for a in argv:
        if "=" in a:
            k, val = a.split("=", 1)
            n = parse_int(val)
            if n is None:
                print("predicted: cannot parse %s" % a, file=sys.stderr)
                return 2
            want[k] = n
    print("PREDICTED (docs/1033-design.md 8) vs GIVEN:")
    for k, u1 in (("far_raw", 0x10), ("pc_minus_far", 0x18), ("dfsr_raw", 0x7), ("slot10_ok", None)):
        if k in want:
            print("  %-13s given=%#x   U1 expects=%s   U3 expects=%s"
                  % (k, want[k], "0x%x" % u1 if u1 is not None else "read, never assumed",
                     "!= 0x10 / != 0x18"))
    return 0


def self_test():
    import os
    import tempfile

    tmp = tempfile.mkdtemp(prefix="chk1033-")
    fails = []

    def mk(name, lines):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write("\n".join(lines) + "\n")
        return p

    def expect(cell, path, label):
        got = adjudicate(path)
        if got != cell:
            fails.append("%s: got %s want %s" % (label, got, cell))
        print("   ok" if got == cell else "   FAIL", label, "->", got)

    def _base(mark="x"):
        return ["   [%s] kernel: a b c" % mark, "", "*** launchd[1] has started up. ***",
                "   [x] kernel: IOS7LAB trap24 frame", "",
                "   [x] kernel: port_construct ok result=0", "",
                "   [x] kernel: IOS7LAB cache mapping 0 nav=2f921000", ""]

    def _evf(**over):
        # The patcher's REAL row order (tools/patch_d13_eval_frame.py TRAP_BLOCK), one row per line.
        rows = {
            "seq": "1", "pid": "2", "pc": "0x3b547474", "lr": "0x3b53f9af", "sp": "0x2bdcf088",
            "cpsr": "0x00000030", "far_raw": "0x00000010", "far_trunc": "0x00000000",
            "far_is_0x10": "1", "far_is_0": "0", "dfsr_raw": "0x00000007", "fault_code": "1",
            "pc_minus_far": "0x00000018", "lr_minus_sp": "0x00001f27",
            "caller_r0": "0x00000001", "caller_r1": "0x00000000", "caller_r2": "0xffffffff",
            "caller_r3": "0x3b6aa020", "caller_r7": "0x2bdcf0ac", "caller_r4_minus_sp": "0xfffffffc",
            "slot10": "0x37c26468", "slot10_ok": "1", "slot14": "0x37c26554", "slot14_ok": "1",
            "slot18": "0x2bdcf0c0", "slot18_ok": "1", "ptr_word": "0x00000000", "ptr_word_ok": "0",
            "lr_slot": "0xf000e8ff", "lr_slot_ok": "1", "read_src": "0", "ustack": "0x2bdcf000",
        }
        rows.update(over)
        return ["   [x] kernel: xnu_live_evf_%s=%s" % (k, rows[k]) for k in rows]

    def _cal():
        return ["   [x] kernel: xnu_live_cal_r3=0x3b6aa020", "",
                "   [x] kernel: xnu_live_cal_region_end_hit=0", "",
                "   [x] kernel: xnu_live_cal_region_end=0x00000000", "",
                "   [x] kernel: xnu_live_cal_pc=0x3b547474", ""]

    u1 = _base() + _evf()
    expect("EVF-U1-TRUE", mk("u1.txt", u1), "a complete U1 burst (far 0x10 + lr_slot_ok)")

    # U1 far, but neither decode present -> SUSPECT, never TRUE
    sus = _base() + _evf(lr_slot_ok="0", slot10_ok="0")
    expect("EVF-U1-SUSPECT", mk("sus.txt", sus), "far 0x10 with no call-site decode -> SUSPECT")

    # the 1032 frame verbatim: far rows ABSENT -> must not fire U1 (missing far_raw is not 0x10)
    _b = _evf()
    _b = [ln for ln in _b if "far_raw" not in ln and "read_src=" not in ln]
    expect("EVF-MISSING", mk("frames1032.txt", _base() + _b), "a burst with no far_raw -> MISSING, not U1")

    # far 0 (the truncated value the 1025 row prints) -> the premise is refuted
    expect("EVF-FAR0", mk("far0.txt", _base() + _evf(far_raw="0x00000000", far_is_0x10="0",
                                                     far_is_0="1", pc_minus_far="0x3b547474")),
           "far_raw 0x0 -> FAR0")

    # far image-relative to mapping0 -> U2-SLIDE0
    expect("EVF-U2-SLIDE0", mk("u2s0.txt", _base() + _evf(far_raw="0x37c26474", far_is_0x10="0",
                                                           pc_minus_far="0x00000000")),
           "far - nav is a cache-file offset -> U2-SLIDE0")

    # far a user VA with slide 0 printed (so far - 0 is not a cache offset, and far != 0x10)
    zero = [ln.replace("nav=2f921000", "nav=0") for ln in _base()]
    expect("EVF-U2-MISTAKE", mk("u2m.txt", zero + _evf(far_raw="0x2bdcf0b4", far_is_0x10="0")),
           "far on a VA that map0 does not slide -> U2-MISTAKE")

    # the eval block did not run: parent rows present, no evf group
    expect("EVF-NOPLANE", mk("noplane.txt", _base() + _cal()), "cal group, no evf group -> NOPLANE")

    # guarded read failed on the only burst
    expect("EVF-NOPLANE", mk("rd2.txt", _base() + _evf(read_src="2", slot10_ok="0")),
           "read_src=2 + slot10_ok=0 -> NOPLANE")

    # panic / storm / controls
    expect("EVF-PANIC", mk("panic.txt", _base() + _evf() + ["   [x] kernel: panic: boom", ""]),
           "a panic -> PANIC")
    expect("EVF-PANIC", mk("storm.txt", _base() + ["   [x] kernel: xnu_live_abt_pcn=0x9000", ""]),
           "the 1023 storm -> PANIC")
    la_only = [ln for ln in _base() if "trap24" not in ln and "port_construct" not in ln]
    expect("EVF-PANIC", mk("noctl.txt", la_only + _evf()), "launchd with no controls -> PANIC")

    # fail closed paths
    expect("G-CTL", mk("dead.txt", ["", "   [x] kernel: nothing here", ""]),
           "dead console (nothing live) -> G-CTL, withhold")
    expect("EVF-MISSING", mk("early.txt", ["   [x] kernel: IOS7LAB trap24 frame", ""]),
           "a control live but no launchd, no evf, no cal -> MISSING (fail closed)")
    expect("EVF-MISSING", mk("la.png", _base()), "launchd, controls, no evf, no cal -> MISSING")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (13 fixtures, every cell fires)")
    return 0


def main(argv):
    if not argv:
        print(__doc__.split("Usage:")[0], file=sys.stderr)
        return 2
    if argv[0] == "--selftest":
        return self_test()
    if argv[0] == "--predicted":
        return predicted(argv[1:])
    cell = adjudicate(argv[0])
    return 0 if cell.startswith("EVF-") and cell not in ("EVF-MISSING", "EVF-NOPLANE") else 1


if __name__ == "__main__":
    # The PARK names THIS copy check_1033_capture.py; a copy under another name is not a pinned definition.
    import os
    me = os.path.abspath(__file__)
    if os.path.basename(me) != "check_1033_capture.py":
        print("check_1033_capture: this is a COPY (%s); the live tool is tools/check_1033_capture.py"
              % os.path.basename(me), file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))