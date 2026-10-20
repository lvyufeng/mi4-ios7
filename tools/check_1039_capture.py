#!/usr/bin/env python3
"""check_1039_capture.py -- adjudicate the capture of rung 1039 against its PRE-REGISTRATION.

Reads a recovered console capture (out/stage90/captures/recovered-*-last_kmsg.txt or a copy of it)
and prints ONE line per pre-registered cell, then an exit code:

    0  a cell fired
    1  the rows are present but no cell is decided (the capture says NO CELL)
    2  NO READING - STALE SLOT (the capture is not this rung's boot)

The adjudication rules are records/1039-read.txt section 2 (fixed BEFORE the press).  This file
implements them and nothing else; it never re-derives a cell from the rows' meaning.
Fields are parsed from the FIRST xnu_live_fcr_* / xnu_live_wlg_* / xnu_live_fb_* / xnu_live_sweq_*
series of pid 2 (launchctl) and the FIRST swb_* series.  An ABSENT row is absent: it is never a zero.

  usage: check_1039_capture.py <capture> [--after N] [--selftest] | --required-rows | --emitter-missing P
         --after N: the press's own boot epoch (scripts/press_1039.sh records it).  This kernel has no
         in-log epoch: the XNU console prints `[os-console-...]`/`[RTCLOCK]`, never `[<sec>.<frac>]`
         (measured on the 1037 capture), so the capture's boot is anchored by its FILE MTIME -- the
         moment recover_last_kmsg.sh read the last_kmsg of THIS boot (one Android boot after the press,
         so strictly newer than the press's boot).  An in-log `[<sec>.<frac>]` stamp, if one ever
         appears, wins over the mtime.  Older than N: STALE.
"""
import os
import re
import sys

# ---------------------------------------------------------------- rows this rung reads

FCR_ROWS = (
    "xnu_live_fcr_seq=", "xnu_live_fcr_uptime_s=", "xnu_live_fcr_time_abs=", "xnu_live_fcr_time_ns=",
    "xnu_live_fcr_uptime_ok=",
    "xnu_live_fcr_pid=", "xnu_live_fcr_tid=", "xnu_live_fcr_pc=", "xnu_live_fcr_lr=",
    "xnu_live_fcr_cpsr=", "xnu_live_fcr_uss_va=", "xnu_live_fcr_uss_via=",
    "xnu_live_fcr_uss_pc=", "xnu_live_fcr_uss_pc_ok=", "xnu_live_fcr_uss_sp=",
    "xnu_live_fcr_uss_sp_ok=", "xnu_live_fcr_uss_lr=", "xnu_live_fcr_uss_lr_ok=",
    "xnu_live_fcr_cont=", "xnu_live_fcr_cont_ok=", "xnu_live_fcr_spsr=",
    "xnu_live_fcr_spsr_ok=", "xnu_live_fcr_pc_odd=", "xnu_live_fcr_lr_odd=", "xnu_live_fcr_tbit=",
    # the iss words are NOT role rows: the block prints all 17 by VALUE (iss_w00 .. iss_w16, each with
    # _ok) and says how it got them (iss_via).  Which word is the saved pc is read from the static read
    # (records/1039-static-lr.txt), never from a name -- a name for a word is the 1037 tautology again.
)
# the iss words: enumerated at read time (w00 .. w16, each with _ok).  A required-PREFIX check.
ISS_ROW_RE = r"xnu_live_fcr_iss_w(?:0[0-9]|1[0-6])="

# the parents 1039 reads alongside (inherited; their absence is reported, never gated)
PARENT_ROWS = (
    "xnu_live_fb_seq=", "xnu_live_fb_pc=", "xnu_live_fb_lr=", "xnu_live_fb_slide=",
    "xnu_live_fb_uss_ok=", "xnu_live_fb_mask_kind=", "xnu_live_fb_ctx_diff=",
    "xnu_live_wlg_byte=", "xnu_live_wlg_lev=",
)

# 1037's observed values the pre-registration binds cells to (records/1037-read.txt RUNG READING)
FB_PC_1037 = 0x38492474
FB_LR_1037 = 0x3848A9AF
EXTRA_UPPER = 0x40000000


def num(v):
    v = v.strip()
    try:
        return int(v, 16) if v.lower().startswith("0x") else int(v)
    except ValueError:
        return None


def parse(text):
    """{(name): value} from the first series of each prefix; None where absent."""
    out = {}
    for line in text.splitlines():
        m = re.search(r"(xnu_live_[a-z0-9_]+)=(.*)$", line)
        if not m:
            continue
        k, v = m.group(1), m.group(2)
        out.setdefault(k, num(v))
    return out


def is_u8(w):
    return w is not None and 0 <= w < 0x100


def cel(name, verdict, why):
    print("  %-22s %s" % (name, verdict))
    print("      %s" % why)
    return verdict not in ("CELL", "REPORTED")


def adjudicate(t):
    missing = [r[:-1] for r in FCR_ROWS if r[:-1] not in t]
    base = [r[:-1] for r in PARENT_ROWS if r[:-1] in t]
    boot = t.get("xnu_live_fcr_uptime_s") if t.get("xnu_live_fcr_uptime_ok") == 1 else None
    print("  capture: %d fcr rows, %d/%d required present, %d parent rows"
          % (sum(1 for k in t if k.startswith("xnu_live_fcr_")), len(FCR_ROWS) - len(missing),
             len(FCR_ROWS), len(base)))
    if boot is not None:
        print("  in-log uptime (s): %d; raw count %s ns %s"
              % (boot, t.get("xnu_live_fcr_time_abs"), t.get("xnu_live_fcr_time_ns")))
    if missing:
        print("  ABSENT (not zero): %s" % ", ".join(missing))
    iss = [k[:-1] for k in t if re.fullmatch(r"xnu_live_fcr_iss_w[01][0-9]=|xnu_live_fcr_iss_w0[0-9]=", k)]
    iss_ok = sum(1 for k in iss if k + "_ok" in t)
    print("  iss words: %d/17 present (%d with _ok); via=%s (inferred: the uss's loader)"
          % (len(iss), iss_ok, t.get("xnu_live_fcr_iss_via")))
    return boot


def cells(t):
    undecided = 0
    seq = t.get("xnu_live_fcr_seq")
    if seq is None and t.get("xnu_live_fcr_pid") is None:
        return False, False  # nothing ran

    # ---- L: which lr/pc did the trap SAVE?  (the carrier)
    lr = t.get("xnu_live_fcr_lr")
    pc = t.get("xnu_live_fcr_pc")
    lr_odd = t.get("xnu_live_fcr_lr_odd")
    pc_odd = t.get("xnu_live_fcr_pc_odd")
    if lr is None or pc is None or lr_odd is None or pc_odd is None:
        undecided += cel("L", "NO-CELL", "fcr_lr/pc or _odd absent - absent is not zero")
    elif lr_odd == 0 and pc_odd == 0:
        undecided += cel("L0 EVEN-REPRODUCED", "REPORTED",
                         "pc=0x%08x lr=0x%08x are EVEN and are NOT 1037's pair (0x%08x/0x%08x): the odd "
                         "registers 1037 read were not reproduced; nothing about 1039's question is "
                         "decided by this run" % (pc, lr, FB_PC_1037, FB_LR_1037))
    elif lr_odd == 1 and pc_odd == 1:
        undecided += cel("L1 BOTH-ODD", "CELL",
                         "pc=0x%08x lr=0x%08x both odd: the carrier is systematic, not one register. "
                         "Ask what writes bit0 into BOTH saved words (T-bit? a relocator pass? a "
                         "thread_set_state writer)." % (pc, lr))
    elif lr_odd == 1:
        undecided += cel("L2 LR-ODD-ONLY", "CELL",
                         "pc=0x%08x (even) lr=0x%08x (odd): ONE user word is odd and the pc is not. "
                         "If fcr_tbit==1 and fcr_uss_lr_ok==1 with fcr_uss_lr==fcr_lr, the odd lr is the "
                         "USER's save and the user really ran the blx; if fcr_tbit==0, a kernel-side "
                         "writer set it. tbit=%s uss_lr=%s" % (pc, lr, t.get("xnu_live_fcr_tbit"),
                                                              t.get("xnu_live_fcr_uss_lr")))
    else:
        undecided += cel("L3 PC-ODD-ONLY", "CELL",
                         "pc=0x%08x (odd) lr=0x%08x (even): the pc carrier is the odd one" % (pc, lr))

    # ---- U: is the trap-saved uss THE record that went to userspace?  (two independent VAs)
    va = t.get("xnu_live_fcr_uss_va")
    upc = t.get("xnu_live_fcr_uss_pc")
    upc_ok = t.get("xnu_live_fcr_uss_pc_ok")
    ulr = t.get("xnu_live_fcr_uss_lr")
    ulr_ok = t.get("xnu_live_fcr_uss_lr_ok")
    if va is None or upc_ok is None or ulr_ok is None:
        undecided += cel("U", "NO-CELL", "uss_va / uss pc/lr _ok absent")
    elif upc_ok == 1 and ulr_ok == 1 and upc == pc and ulr == lr:
        undecided += cel("U1 USARMCTX-AGREES", "REPORTED",
                         "the uss AT thread->machine.uss reads pc=0x%08x lr=0x%08x, the arm_ctx words: the "
                         "carrier hands the SAME words on both sides (the frame 1037 read is the one "
                         "saved); the disagreement is with the FILE, not between kernel views" % (upc, ulr))
    elif upc_ok == 1 and ulr_ok == 1:
        undecided += cel("U2 TWO-VIEWS-DISAGREE", "CELL",
                         "uss@0x%08x says pc=0x%08x lr=0x%08x; arm_ctx says pc=0x%08x lr=0x%08x: the two "
                         "kernel views of the user context differ - name the writer between them"
                         % (va or 0, upc, ulr, pc, lr))
    else:
        undecided += cel("U3 USS-UNREADABLE", "REPORTED",
                         "uss pc/lr not readable through thread->machine.uss (pc_ok=%s lr_ok=%s): the "
                         "record at 0x%08x is not in the task map (an overlay / an unmapped uss)"
                         % (upc_ok, ulr_ok, va or 0))

    # ---- I: thread->continuation - is a CONTINUATION entry (r0=0 from machine_load_context) reachable?
    #      (the iss block itself is NOT read: it is a register walk, not an arm_saved_state_t; the static
    #      walk is records/1039-static-lr.txt (iii) and only cont is decideable from the kernel here.)
    cont = t.get("xnu_live_fcr_cont")
    if cont is None:
        undecided += cel("I", "NO-CELL", "cont absent")
    elif cont != 0:
        undecided += cel("I3 CONTINUATION-SET", "CELL",
                         "thread->continuation=0x%08x: the next switch is a CONTINUATION entry - r0=0 "
                         "from machine_load_context is reachable (records/1039-static-lr.txt (a))" % cont)
    else:
        undecided += cel("I4 NO-CONTINUATION", "REPORTED",
                         "thread->continuation=0: the next switch from this thread is not a continuation "
                         "entry, so machine_load_context's r0=0 is not reachable on it (the k=0 argument "
                         "of records/1039-static-lr.txt (a))")

    # ---- S: the saved spsr (the bank and its T bit)
    # ---- ctrl: did the block run, on launchctl, with the continuation row readable?
    ctrl_ok = (t.get("xnu_live_fcr_seq") is not None and t.get("xnu_live_fcr_pid") == 2
               and t.get("xnu_live_fcr_cont_ok") == 1)
    undecided += cel("ctrl", "PASS" if ctrl_ok else "FAIL",
                     "seq/pid==2/cont_ok: seq=%s pid=%s cont_ok=%s"
                     % (t.get("xnu_live_fcr_seq"), t.get("xnu_live_fcr_pid"),
                        t.get("xnu_live_fcr_cont_ok")))
    spsr = t.get("xnu_live_fcr_spsr")
    spsr_ok = t.get("xnu_live_fcr_spsr_ok")
    tbit = t.get("xnu_live_fcr_tbit")
    if spsr_ok != 1:
        undecided += cel("S", "REPORTED", "spsr not readable at the uss save (spsr_ok=%s)" % spsr_ok)
    else:
        mode = spsr & 0x1F if spsr is not None else None
        undecided += cel("S1 SPSR" if mode == 0x10 else "S1 SPSR-BANK-NOT-USER", "REPORTED",
                         "spsr=0x%08x (mode 0x%x%s, T=%d); pc bit5 (tbit)=%s"
                         % (spsr or 0, mode or 0, "" if mode == 0x10 else " NOT user (0x10)", 
                            1 if (spsr or 0) & 0x20 else 0, tbit))

    # ---- E: the 1038 parent family (A/B) on THIS run
    ge = t.get("xnu_live_sweq_swb_ge")
    gok = t.get("xnu_live_sweq_swb_ok")
    m40 = t.get("xnu_live_sweq_swb_m40_ok")
    far = t.get("xnu_live_sweq_swb_far")
    if "xnu_live_sweq_swb_ge" not in t:
        undecided += cel("E", "REPORTED", "1038's swb rows absent (the WATCH_LE arm did not publish here)")
    elif gok == 1 and m40 == 1 and far:
        undecided += cel("E1 PAIR-HELD" if ge == 1 else "E2 PAIR-BROKEN", "REPORTED",
                         "swb_far=0x%08x *(far-0x40)==far: %s" % (far, ge))
    else:
        undecided += cel("E", "REPORTED", "swb gates not complete (swb_ok=%s m40_ok=%s far=%s)"
                         % (gok, m40, far))
    return True, undecided


def selftest():
    ok = True

    def expect(c, name):
        nonlocal ok
        print("   %s %s" % ("ok" if c else "FAIL", name))
        ok = ok and c

    full = dict(
        xnu_live_fcr_seq=1, xnu_live_fcr_uptime_s=97, xnu_live_fcr_time_abs=487000000,
        xnu_live_fcr_time_ns=487000000000, xnu_live_fcr_uptime_ok=1,
        xnu_live_fcr_pid=2, xnu_live_fcr_tid=0x80000000, xnu_live_fcr_pc=FB_PC_1037,
        xnu_live_fcr_lr=FB_LR_1037, xnu_live_fcr_cpsr=0x30, xnu_live_fcr_uss_va=0x2bd4c088,
        xnu_live_fcr_uss_via=1, xnu_live_fcr_uss_pc=FB_PC_1037, xnu_live_fcr_uss_pc_ok=1,
        xnu_live_fcr_uss_sp=0x2bd4c088, xnu_live_fcr_uss_sp_ok=1, xnu_live_fcr_uss_lr=FB_LR_1037,
        xnu_live_fcr_uss_lr_ok=1, xnu_live_fcr_cont=0, xnu_live_fcr_cont_ok=1,
        xnu_live_fcr_spsr=0x30, xnu_live_fcr_spsr_ok=1, xnu_live_fcr_pc_odd=0,
        xnu_live_fcr_lr_odd=1, xnu_live_fcr_tbit=0,
    )

    import io
    import contextlib

    def run(rows):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            cells(rows)
        return buf.getvalue()

    out = run(dict(full))
    expect("L2 LR-ODD-ONLY" in out, "lr odd alone -> L2")
    out = run(dict(full, xnu_live_fcr_lr_odd=0))
    expect("L0 EVEN-REPRODUCED" in out, "even pair -> L0, no cell")
    # an ABSENT row is absent: no _odd rows -> NO-CELL, not L0
    d = dict(full)
    del d["xnu_live_fcr_pc_odd"]
    out = run(d)
    expect("NO-CELL" in out and "L0" not in out, "absent _odd is NO-CELL, never a zero")
    out = run(dict(full, xnu_live_fcr_uss_lr=0x1234))
    expect("U2 TWO-VIEWS-DISAGREE" in out, "two views differ -> U2")
    out = run(dict(full, xnu_live_fcr_uss_pc_ok=0))
    expect("U3 USS-UNREADABLE" in out, "uss unreadable -> U3, never a '0' pc match")
    d = dict(full)
    del d["xnu_live_fcr_cont"]
    out = run(d)
    expect("NO-CELL" in out and "I4" not in out, "absent continuation is NO-CELL, never I4")
    out = run(dict(full, xnu_live_fcr_cont=0x80123456))
    expect("I3 CONTINUATION-SET" in out, "continuation -> I3")
    out = run(dict(full, xnu_live_fcr_pc=FB_PC_1037 + 1, xnu_live_fcr_pc_odd=1))
    expect("L1 BOTH-ODD" in out, "both odd -> L1")

    # parsing: hex/decimal, first series wins, unrelated lines ignored
    txt = ("[  0.1] xnu_live_fcr_pc=0x38492474\nxnu_live_fcr_pid=2\nnoise=x\nxnu_live_fcr_pc=0x1\n")
    p = parse(txt)
    expect(p.get("xnu_live_fcr_pc") == FB_PC_1037, "parse: first series wins, hex read")
    expect(p.get("xnu_live_fcr_pid") == 2, "parse: decimal read")
    print("SELFTEST " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


ENTRY_MARK = "MI4IOS6_STAGE90 v1 entered"


def boot_epoch(text):
    """The boot the capture is OF: the first console `[<sec>.<frac>]` stamp (the console's own clock),
    or None.  NEVER the `-YYYYMMDD-HHMMSS-` name stamp, which is when the capture was TAKEN."""
    m = re.search(r"\[\s*(\d{9,})\.\d+\]", text)
    return int(m.group(1)) if m else None


def emitter_missing(src):
    """Rows FCR_ROWS that `src` (a patcher's python source) cannot print: every row is a printf literal."""
    return [r for r in FCR_ROWS if ("\"%s" % r) not in src]


# 1038's rows as a COMPANION: measured, reported, never a conjunct of any 1039 cell.
COMPANION = "check_1038_capture.py"   # beside this file


def companion_missing(src):
    """1038's gated rows the same patcher source could not print, via 1038's OWN emitter gate (one
    definition, one place).  ANOTHER lane's rule is read, never restated."""
    cpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), COMPANION)
    ns = {"__name__": "check_1038_capture"}
    with open(cpath, "r", errors="replace") as f:
        exec(compile(f.read(), cpath, "exec"), ns)
    gated = ns["SWB_ROWS"] + ns["WPC_ROWS"] + ns["REQUIRED"]
    return ns["emitter_missing"](src, gated)


def main(argv):
    if len(argv) == 1 and argv[0] == "--selftest":
        return selftest()
    if len(argv) == 1 and argv[0] == "--required-rows":
        for r in FCR_ROWS:
            print(r)
        return 0
    if len(argv) == 2 and argv[0] == "--emitter-missing":
        with open(argv[1], "r", errors="replace") as f:
            src = f.read()
        m = emitter_missing(src)
        comp = companion_missing(src)
        if comp:
            print("COMPANION (1038 rows, not this rung's gate): %s" % " ".join(comp))
        if m:
            print(" ".join(m))
            return 1
        print("all %d required rows are printable by %s" % (len(FCR_ROWS), os.path.basename(argv[1])))
        return 0
    path, press_epoch = None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--after" and i + 1 < len(argv):
            press_epoch = int(argv[i + 1]); i += 2
        elif a.startswith("--") or path is not None:
            print(__doc__, file=sys.stderr)
            return 2
        else:
            path = a; i += 1
    if path is None:
        print(__doc__, file=sys.stderr)
        return 2
    with open(path, "r", errors="replace") as f:
        text = f.read()
    if ENTRY_MARK not in text:
        print("NO READING - STALE SLOT: the capture carries no `%s` line - not this kernel's boot."
              % ENTRY_MARK)
        return 2
    if "xnu_live_fcr_seq=" not in text:
        print("NO READING - the capture carries no xnu_live_fcr_* rows: the 1039 block did not run on "
              "this boot (boot nothing else before re-reading last_kmsg).")
        return 2
    t = parse(text)
    mtime = os.stat(path).st_mtime_ns // 1000000000
    print("capture: %s (mtime %d)" % (path, mtime))
    boot = boot_epoch(text)
    if boot is None:
        print("  in-log boot stamp: ABSENT (this console prints no [<sec>.<frac>]) - the capture mtime "
              "(%d) is the anchor" % mtime)
        boot = mtime
    else:
        print("  in-log boot epoch: %d" % boot)
    if press_epoch is not None and boot < press_epoch:
        print("NO READING - STALE SLOT: the capture's boot %d is older than the press's boot %d."
              % (boot, press_epoch))
        return 2
    if mtime < boot:
        print("NO READING - STALE SLOT: capture mtime %d older than its in-log boot %d." % (mtime, boot))
        return 2
    adjudicate(t)
    pid = t.get("xnu_live_fcr_pid")
    if pid is not None and pid != 2:
        print("NO READING - the fcr rows are pid %d, not launchctl (2)." % pid)
        return 2
    print("cells:")
    ran, undecided = cells(t)
    if not ran:
        print("NO CELL - the block published no pid/seq")
        return 1
    return 0 if undecided == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))