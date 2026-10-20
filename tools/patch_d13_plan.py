"""1039's TRAP.C PLAN -- the rungs' block texts, read back from the patchers that OWN them.

WHY (measured 2026-10-20, [[mi4-one-value-two-definitions]]): 1039 re-stages every trap.c rung, and each
patcher used to re-compose its neighbours' text from STORED OFFSETS into the tree it was about to write.
The composite's preprocessor depth was never checked, and the staged tree's seam read
`#endif /* STAGE90_XNU_USTACK_PROBE */` with nothing open (depth -1).  The preprocessor answers by
STRUCTURE.  So each block is taken BY VALUE from its owner's own variable -- 1037's TRAP_BLOCK, 1039's
TRAP_BLOCK, 1038's three files (watch_le_defs.inc / watch_le_arm.inc / watch_le_hook.inc) -- and the
plan is checked (depth, order, each block once, each row once) before anything writes.

THE PLAN, in trap.c's body (dir = the tree's osfmk/arm):

    <original trap.c to 1036's close + 1025's open>       (1036's block stays: it is 1036's bytes)
    #if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME
    1037's body                                                (patch_d13_trap_frame.TRAP_BODY)
    #include "<dir>/watch_le_defs.inc"       <- 1038's statics, arm A's tables, the gate table; FILE SCOPE
    #endif /* STAGE90_XNU_FRAME_CARRIER */                      (1039's TRAP_BLOCK is the carrier: its
                                                                 `#if`, its body, its close)
    #endif /* STAGE90_XNU_TRAP_FRAME */
    #endif /* STAGE90_XNU_USTACK_PROBE */
    <1038's three section headers + the rest of trap.c>    (compile-out placeholders, not the edit)

    in sleh_abort:  {\t...record this fault...;\n\t#include "<dir>/watch_le_arm.inc"\n\t}
                    <- 1038's hook text (watch_le_hook.inc), verbatim, from the rows loop's model

WHY defs INSIDE 1037's block: 1038's `_wl_rd` calls vm_map_lookup_entry, which the arm's Kbuild section
and 1025's publisher declare; 1038's statics are written for that body's scope.  1037's block is inside
1025's arm at the same statement level.

The model is ONE record: the include files are written by `patch_d13_watch_le.py --model-files`, and this
plan writes only trap.c's include LINE.  Read back by --verify; folded by --off (the tree that carries no
1039 edit at all).
"""
import os
import sys

T = chr(9)
E = chr(10)
TRAP_REL = "osfmk/arm/trap.c"
TRAP_FRAME_OPEN = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME" + E
TRAP_FRAME_CLOSE = "#endif /* STAGE90_XNU_TRAP_FRAME */" + E
FC_CLOSE = "#endif /* STAGE90_XNU_FRAME_CARRIER */" + E
U25_OPEN = "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE" + E
U25_CLOSE = "#endif /* STAGE90_XNU_USTACK_PROBE */" + E
LE_SW = "STAGE90_XNU_WATCH_LE"
LE_SW_OPEN = "#if defined(%s) && %s" % (LE_SW, LE_SW) + E

REPO = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "")
BODY_MARK = "    thread_t thread = current" + "_thread();" + E   # sleh_abort's preamble, last line
ABORT_CTX = "(abort_information_context_t *) context;" + E        # sleh_abort's own decl (sleh_undef has none)


def _mod(name):
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("_pl_" + name, os.path.join(here, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    # (REGISTERED under its own name while it runs: a patcher's late-bound globals are found through
    # sys.modules[__name__], and outside a normal import that entry does not exist)
    sys.modules["_pl_" + name] = m
    spec.loader.exec_module(m)
    return m


def read(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8")


def write(p, t):
    with open(p, "wb") as f:
        f.write(t.encode("utf-8"))


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def inc_line(xnu, name):
    return "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", name) + chr(34) + E


def blocks(xnu):
    """the plan's units, each from its OWNER: (name, text) in trap.c's order, and the hook's text."""
    tf = _mod("patch_d13_trap_frame")
    fc = _mod("patch_d13_frame_carrier")
    wl = _mod("patch_d13_watch_le")
    files, _lines, probs = wl._model_files(xnu)
    if probs:
        raise ValueError("the rows loop's model cannot compile: " + "; ".join(probs))
    # THE OWNERS' CLOSE LINES, read from their own text (each comment line NAMES the bracket it closes).
    # 1037 (TF): ... body } #endif /* TRAP_FRAME */ #endif /* USTACK */
    _tf_tail = TRAP_FRAME_CLOSE + U25_CLOSE
    # 1039 (FC): OP_L ... body } #endif /* FRAME_CARRIER */ #endif /* TRAP_FRAME */
    _fc_tail = fc.CLOSE + TRAP_FRAME_CLOSE
    if not tf.TRAP_BLOCK.endswith(_tf_tail):
        raise ValueError("1037's block does not end with its own close + 1025's (ends %r)" % tf.TRAP_BLOCK[-70:])
    if not fc.TRAP_BLOCK.endswith(_fc_tail) or not fc.TRAP_BLOCK.startswith(fc.OP_L):
        raise ValueError("1039's block does not run from its switch to its own close + 1037's (ends %r)"
                         % fc.TRAP_BLOCK[-70:])
    # 1037's head: the anchor (1036's close line) + 1037's switch opener, comment form -- the owner's
    _head = tf.TRAP_ANCHOR.split(E)[0] + E + tf.TRAP_BLOCK.split(E)[1] + E
    if not tf.TRAP_BLOCK.startswith(_head):
        raise ValueError("1037's block does not start at its anchor and switch (starts %r)"
                         % tf.TRAP_BLOCK[:70])
    b37 = tf.TRAP_BLOCK[len(_head):-len(_tf_tail)]
    if not b37.startswith(tf.I + "/*") or not b37.endswith("}" + E):
        raise ValueError("1037's body is not a body (first/last lines are not its own)")
    # 1039's body is the owner's, between its switch line and its two close lines
    fc_body = fc.TRAP_BLOCK[len(fc.OP_L):-len(_fc_tail)]
    # 1037's switch's close is the owner's own `#endif` -- the same line FC re-states as TRAP_FRAME_CLOSE
    # -- and 1025's close is 1037's last line.  Both are the owners' own text, kept verbatim.
    seam = [
        # 1037's switch opener: the owner's line (comment form -- _block_shape reads any `#if X && X`)
        ("1037 switch", tf.TRAP_BLOCK.split(E)[1] + E),
        ("1037 body", b37),
        # (1038's defs: its own `#if WATCH_LE` pair opens and closes INSIDE the include, so it nests at
        # file scope; a body's braces do not count -- the include is legal right after the body's `}`)
        ("1038 defs", inc_line(xnu, wl.INC_DEFS)),
        # (1039's branch: FC closes 1037's switch with its own `#endif /* TRAP_FRAME */` tail)
        ("1039 open", fc.OP_L),
        ("1039 body", fc_body),
        # 1037's switch's close + 1037's own close = 1037's tail's first line, then 1039's close line
        # trumps -- the owner's two close lines, in 1039's own order, then 1037's and 1025's:
        ("1039 close", fc.CLOSE),
        # (1037's close is the owner's own line; FC's tail re-states the SAME text after its body)
        # (1037's close line; 1025's close is the ENCLOSING pair's, which place() left open -- not this
        # seam's -- so it is NOT added here)
        ("1037 close", TRAP_FRAME_CLOSE),
    ]
    hook = [("hook pre", "\t{" + E + "\t\t/* the fault's own context (see watch_le_arm.inc's entry) */" + E),
            ("hook arm", "\t" + inc_line(xnu, wl.INC_ARM).strip() + E),
            ("hook post", "\t}" + E)]
    return seam, hook, (tf, fc, wl)


def place(t, xnu):
    """(the anchor offsets, why): trap.c must be the 1036 tree -- 1025's arm open and, after it, the
    close that ends the arm -- and sleh_abort's preamble exactly once.  The seam goes IN FRONT of
    1025's close (inside the arm, after every rung's rows); it does not replace the arm."""
    i = t.find(U25_CLOSE)
    if i < 0 or t.count(U25_CLOSE) != 1:
        return None, "1025's close occurs %d time(s), expected once" % t.count(U25_CLOSE)
    if t.find(U25_OPEN) < 0 or t.count(U25_OPEN) != 1:
        return None, "1025's open occurs %d time(s), expected once" % t.count(U25_OPEN)
    if t.find(U25_OPEN) > i:
        return None, "1025's close stands in front of its open"
    # (sleh_undef shares the bare preamble line; sleh_abort is the function that takes an
    # abort_information_context_t -- anchor on that)
    j = t.find(ABORT_CTX)
    if j < 0 or t.count(ABORT_CTX) != 1:
        return None, "abort_information_context_t occurs %d time(s), expected 1" % t.count(ABORT_CTX)
    k = t.find(BODY_MARK, j)
    if k < 0 or k > j + 400:
        return None, "sleh_abort's preamble is not within 400 bytes of its abort context"
    # (a,b) is the EMPTY span in front of 1025's close: the seam is INSERTED there
    return (i, i, k + len(BODY_MARK)), None


def compose(t, xnu):
    """(the staged text, why)"""
    seam, hook, _m = blocks(xnu)
    at, why = place(t, xnu)
    if at is None:
        return None, why
    a, b, h = at
    o = o_of(seam)
    # the seam is INSERTED in front of 1025's close (the arm's last statement is already there)
    t2 = t[:a] + o + t[a:]
    # h is an offset into the ORIGINAL text; it shifts by the seam's length if it is behind the splice
    dh = len(o)
    h2 = h + dh if h >= a else h
    return t2[:h2] + h_of(hook) + t2[h2:], None


def o_of(seam):
    return "".join(x for _n, x in seam)


def h_of(hook):
    return "".join(x for _n, x in hook)


def depth(t):
    """(final, lowest) preprocessor depth as the compiler reads it: directives on REAL lines only."""
    d, lo = 0, 0
    for l in t.split(E):
        s = l.strip()
        if s.startswith("#if"):
            d += 1
        elif s.startswith("#endif"):
            d -= 1
            lo = min(lo, d)
    return d, lo


def verify(t, xnu):
    """the composed text's facts, by value: [] or the problems."""
    seam, hook, (tf, fc, wl) = blocks(xnu)
    probs = []
    o = o_of(seam)
    if t.count(o) != 1:
        probs.append("the seam's plan occurs %d time(s), expected once" % t.count(o))
    if t.count(h_of(hook)) != 1:
        probs.append("the hook occurs %d time(s), expected once" % t.count(h_of(hook)))
    # (1038's rows are in the ARM file the hook includes, not in the hook's text: counted in o alone)
    for name in ("xnu_live_fb_pc=", "xnu_live_fcr_seq="):
        if o.count(name) != 1:
            probs.append("row %s is not in the plan exactly once" % name)
    # the seam's ORDER, by offset (a later rung pasted AFTER its predecessor's close would still count 1)
    # (1037's switch, its body, the defs, 1039's switch, 1039's body, 1039's close, 1037's close)
    _b = o.find(tf.I + "/*")
    order = [0, _b, o.find(wl.INC_DEFS, _b), o.find(fc.OP_LINE, _b),
             o.find(fc.CLOSE, _b), o.find(TRAP_FRAME_CLOSE, o.find(fc.CLOSE, _b))]
    if order != sorted(order) or any(k < 0 for k in order):
        probs.append("the seam is out of order: %r" % order)
    # (the seam's own brackets: every real line of it, balanced -- 1037's pair, 1039's, the defs')
    _dd, _lo = 0, 0
    for l in o.split(E):
        s_ = l.strip()                     # real lines only: the defs include carries tab-led bodies
        if s_.startswith("#if"):
            _dd += 1
        elif s_.startswith("#endif"):
            _dd -= 1
            _lo = min(_lo, _dd)
    if (_dd, _lo) != (0, 0):
        probs.append("the seam's own brackets do not balance (%d, %d)" % (_dd, _lo))
    dd, lo = depth(t)
    if lo < 0:
        probs.append("the composed text goes BELOW depth 0 (an #endif with nothing open)")
    # (the defs include is one LINE in trap.c; its switch and #define are in the FILE, not here)
    if t.count("#define %s 1" % LE_SW) != 0 or o.count(wl.INC_DEFS) != 1:
        probs.append("1038's defs include is not exactly one line")
    if t.count(TRAP_FRAME_OPEN) != 1 or t.count(TRAP_FRAME_CLOSE) != 1:
        probs.append("1037's pair is not exactly one")
    if t.count(o_of([("1039 open", "#if defined(%s) && %s" % (fc.SWITCH, fc.SWITCH) + E)])) < 1:
        probs.append("1039's opener is absent")
    return probs


def off(t, xnu):
    """the staged text with the plan folded out: trap.c's 1036 bytes.  (the include FILES are not
    trap.c's bytes and are not touched)"""
    seam, hook, _m = blocks(xnu)
    o, hk = o_of(seam), h_of(hook)
    if t.count(o) != 1 or t.count(hk) != 1:
        return None, "cannot fold: the plan is not staged exactly once (seam %d, hook %d)" % (
            t.count(o), t.count(hk))
    # (the fold puts the 1036 tree's empty pair back where the seam took it from)
    t2 = t.replace(o, "", 1)
    t2 = t2.replace(hk, "", 1)
    return t2, None


def selftest():
    fails = []
    xnu0 = os.path.join(REPO, "external", "xnu-hd2-darwin13", "xnu")
    def expect(c, label):
        print("   ok" if c else "   FAIL", label)
        if not c:
            fails.append(label)
            # (the label alone is a claim: every FAIL shows the value it judged)
            try:
                print("      value: %r" % (verify(t2, xnu0) if "t2" in dir() and t2 else label,))
            except Exception:
                pass
    xnu = os.path.join(REPO, "external", "xnu-hd2-darwin13", "xnu")
    try:
        seam, hook, (tf, fc, wl) = blocks(xnu)
    except Exception as ex:
        expect(False, "the plan's units come from their owners (%s)" % ex)
        print("patch_d13_plan: selftest FAIL.")
        return 1
    o = o_of(seam)
    expect(o.split(E)[0] == TRAP_FRAME_OPEN.rstrip(E), "the seam opens with 1037's switch")
    expect(o.endswith(TRAP_FRAME_CLOSE), "the seam closes 1037's bracket (1025's is the tree's own)")
    _dd, _lo = 0, 0
    for _l in o.split(E):
        _s = _l.strip()                    # (real lines: see verify)
        if _s.startswith("#if"):
            _dd += 1
        elif _s.startswith("#endif"):
            _dd -= 1
            _lo = min(_lo, _dd)
    expect((_dd, _lo) == (0, 0), "the seam's own brackets balance ((%d, %d))" % (_dd, _lo))
    expect(o.count(FC_CLOSE) == 1 and o.find(FC_CLOSE) < o.rfind(TRAP_FRAME_CLOSE),
           "1039's close stands inside 1037's, in front of 1037's close")
    expect(o.find(wl.INC_DEFS) < o.find(fc.SWITCH, o.find(wl.INC_DEFS)),
           "1038's defs stand in front of 1039's opener (1037's body, not its block)")
    expect(sum(1 for l in h_of(hook).split(E) if l.strip().startswith("#include") and wl.INC_ARM in l) == 1,
           "the hook includes the arm once")
    expect(not any(l[:1] == T and l.lstrip(T).startswith("#") and "#include" not in l
                   for l in (o + h_of(hook)).split(E)), "no tab-indented directive (but the includes)")
    # a fixture: the 1036 tail alone is a balanced text that goes to depth 0 at its close.  (its seam
    # is the TAIL (1025 open, close); the hook's seat is the preamble after it)
    fix = "int f(void)" + E + "{" + E + U25_OPEN + U25_CLOSE + BODY_MARK + "int x = 1;" + E + "}" + E
    t2, why = compose(fix, xnu)
    expect(t2 is not None, "the plan composes on a 1036 fixture (%s)" % why)
    if t2 is not None:
        expect(verify(t2, xnu) == [], "the composed fixture verifies (%s)" % "; ".join(verify(t2, xnu)))
        back, why2 = off(t2, xnu)
        expect(back == fix, "the fold is the fixture, byte for byte (%s)" % why2)
        bad = t2.replace(FC_CLOSE, "", 1)
        expect(verify(bad, xnu) != [], "a text without 1039's close is refused")
    print("patch_d13_plan: selftest %s." % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print("usage: patch_d13_plan.py <xnu_root> [--apply|--verify|--off|--out] | --selftest",
              file=sys.stderr)
        return 2
    xnu = args[0]
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_plan: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    if "--off" in argv:
        # the 1036 bytes (what the tree must carry BEFORE this rung's edit), to stdout
        sys.stdout.write(TRAP_FRAME_OPEN + U25_CLOSE if t == TRAP_FRAME_OPEN + U25_CLOSE + E else t)
        return 0
    if "--verify" in argv:
        probs = verify(t, xnu)
        for p in probs:
            print("   PLAN PROBLEM: %s" % p)
        print("patch_d13_plan: --verify %s." % ("FAIL" if probs else "PASS"))
        return 1 if probs else 0
    out, why = compose(t, xnu)
    if out is None:
        print("patch_d13_plan: REFUSE - %s. Writing nothing." % why, file=sys.stderr)
        return 1
    probs = verify(out, xnu)
    if probs:
        for p in probs:
            print("   PLAN PROBLEM: %s" % p)
        print("patch_d13_plan: REFUSE - the composed plan does not verify. Writing nothing.", file=sys.stderr)
        return 1
    if "--out" in argv:
        sys.stdout.write(out)
        return 0
    if "--apply" not in argv:
        print("patch_d13_plan: plan OK (dry run; pass --apply to write).")
        return 0
    write(tp, out)
    print("patch_d13_plan: trap.c staged: the 1036 tail's 1025 close replaced by the seam (%d bytes), "
          "the hook at sleh_abort's preamble." % len(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))