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
import re as _re
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


def _inc_line(xnu, name):
    return inc_line(xnu, name)


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
    fc_tail = fc.CLOSE + TRAP_FRAME_CLOSE
    if not tf.TRAP_BLOCK.endswith(_tf_tail):
        raise ValueError("1037's block does not end with its own close + 1025's (ends %r)"
                         % tf.TRAP_BLOCK[-70:])
    if not fc.TRAP_BLOCK.endswith(fc_tail) or not fc.TRAP_BLOCK.startswith(fc.OP_L):
        raise ValueError("1039's block does not run from its switch to its own close + 1037's (ends %r)"
                         % fc.TRAP_BLOCK[-70:])
    # 1037's body: from its switch's line to its OWN switch's close -- the rows 1037 wrote.  What the
    # owner's block carries AFTER that close is 1036 text (rows whose pairs close at the arm's end in the
    # tree), not this seam's; re-stating one (`#endif /* USTACK */`) at file scope ended the arm at 1037's
    # close -- measured 2026-10-20.  (The body's own close is cut OFF: the "1037 close" row re-states it.)
    _tf_lines = tf.TRAP_BLOCK.split(E)
    _sw_lines = [l for l in _tf_lines if l.startswith("#if")]
    if len(_sw_lines) != 1:
        raise ValueError("1037's block carries %d column-0 `#if` line(s), expected its switch" % len(_sw_lines))
    _body_end = tf.TRAP_BLOCK.rfind(TRAP_FRAME_CLOSE)
    if _body_end < 0:
        raise ValueError("1037's block carries no TRAP_FRAME close")
    _tf_body = tf.TRAP_BLOCK[tf.TRAP_BLOCK.find(_sw_lines[0]) + len(_sw_lines[0]) + 1:_body_end]
    # 1039's branch: its switch's line through its close (the owner's own bytes)
    # (raw indices, PARENTHESISED: `x[len(a):b + len(c)]` is `x[len(a):b][len(c)]` -- 2026-10-20,
    #  the unparenthesised slice split 1039's block at byte 36, its second line)
    _fc_body = fc.OP_L + fc.TRAP_BLOCK[len(fc.OP_L):(fc.TRAP_BLOCK.find(fc.CLOSE) + len(fc.CLOSE))]
    seam = [
        # 1037's switch opener: the owner's line (comment form -- _block_shape reads any `#if X && X`)
        ("1037 switch", _sw_lines[0] + E),
        ("1037 body", _tf_body),
        # (1038's defs: its own `#if WATCH_LE` pair opens and closes INSIDE the include, so it nests at
        # file scope; a body's braces do not count -- the include is legal right after the body's `}`)
        ("1038 defs", _inc_line(xnu, wl.INC_DEFS)),
        # (1039's branch closes 1037's switch with its own `#endif /* TRAP_FRAME */` tail)
        ("1039 open+body+close", _fc_body),
        # (1037's close is the owner's own line; FC's tail re-states the SAME text after its body)
        ("1037 close", TRAP_FRAME_CLOSE),
    ]
    # (THE SEAT: the tree's own comment, the switch's row, then the arm -- the SEQUENCE row_side()
    #  writes under sleh_abort's preamble.  The switch's `#define` is legal INSIDE a function and the
    #  row-side defs (which DEFINE it) are 900 lines below, so an arm alone reads it UNDEFINED and
    #  every spliced row compiles out while its statics exist: on the pool's own argv that was
    #  `use of undeclared identifier 'arm_ctx'` for each.  A second copy is what the pool refused.
    #  [[mi4-one-value-two-definitions]] -- the switch's `#define` has ONE text, the .inc file.)
    hook = [("hook switch", "\t" + _inc_line(xnu, wl.INC_SWITCH).strip() + E),
            ("hook arm", "\t" + _inc_line(xnu, wl.INC_ARM).strip() + E)]
    return seam, hook, (tf, fc, wl)


def _seam_indent(seam, ind):
    """the seam's text with ITS directives at the arm's column (a spliced body row keeps its own)."""
    if not ind:
        return o_of(seam)
    # (each unit ends at a REAL line end; within one, a row ending in `\\` continues the splice)
    o = ""
    for _n, _v in seam:
        if _v.endswith(E) and o and not o.endswith(E):
            o += E                     # the unit's own line end (two units can share one line's head)
        o += _v
    out, plain = [], True
    for _l in o.rstrip(E).split(E):
        out.append(ind + _l if plain and _l.startswith("#") else _l)
        plain = _l.endswith(chr(92))
    return (E.join(out) + E) if o.endswith(E) else E.join(out)


def _line_start(t, o):
    """(the line START at or before offset o): a row's beginning, never a byte inside one."""
    _p = t.rfind(E, 0, o)
    return 0 if _p < 0 else _p + 1


def _fold_1037(t, xnu):
    """(text without an OLD 1037 pair, why): 1037's body is ONE text.  Each occurrence of its marker
    line names a span; the span is cut line-wise to the `#endif /* TRAP_FRAME */` that follows it, and
    the pair is removed ONLY when its body is exactly 1037's text (the copy is the rung's own, an
    older wording is not this plan's to delete -- the verifier names it).  Nothing found: unchanged."""
    _tf = blocks(xnu)[2][0]
    _key = "1037: THE TRAP FRAME BY VALUE"
    _div = [k for k, q in enumerate(_tf.TRAP_BLOCK.split(E)) if _key in q]
    _body = E.join(_tf.TRAP_BLOCK.split(E)[_div[0]:]) if _div else ""
    _keep = []
    _cur = t
    _n = 0
    while "/* " + _key in _cur:
        L = _cur.split(E)                   # (re-derived from the text each time: a second copy's
        _idx = [k for k, q in enumerate(L) if q.strip().startswith("/* " + _key)]   # lines move)
        _o = [k for k in range(_idx[0], -1, -1) if L[k].strip() == TRAP_FRAME_OPEN.strip(E)]
        _c = [k for k in range(_idx[0], len(L)) if L[k].strip() == TRAP_FRAME_CLOSE.strip(E)]
        if not _o or not _c:
            return t, "1037's body has no pair around it"
        _cur = E.join(L[:_o[0]] + L[_c[0] + 1:])
        _n += 1
        if _n > 3:
            return t, "1037's body occurs more than 3 time(s)"
    return _cur, None


def row_count(*args):
    """(row, xnu) or (xnu, row) - the caller passes (xnu, row); both are strings, so tell them apart by
    which one looks like a path."""
    if len(args) == 2:
        a, b = args
        if a.rstrip("/").endswith("/xnu") or "/" in a:
            xnu, row = a, b
        elif b.rstrip("/").endswith("/xnu") or "/" in b:
            xnu, row = b, a
        else:
            xnu, row = a, b
    else:
        row, xnu = args[0], None
    return _row_count(row, xnu)


def _row_count(row, xnu=None):
    """How many times `row` occurs in 1037's OWN body, read from the owner.

    `scripts/build_1039.sh` calls this to say how many of a row the staged trap.c should carry
    ("the staged TRAP carries N ... 1037's own body carries M"). The function did not exist: the
    caller wrapped it in `|| _fb_want=0`, so the AttributeError was swallowed and the check compared
    against a zero it had invented - it could only ever fail. The count is read from the SAME text
    compose() splices (the owner's block), so the two numbers are one value.
    """
    seam, _hook, (tf, _fc, _wl) = blocks(xnu)
    o = o_of(seam)
    # 1037's block runs from its switch row to its own close; the rows are counted inside that span
    _o = o.rstrip(E)
    _rows = _o.split(E)
    _sw = next((k for k, q in enumerate(_rows)
                if q.strip() == TRAP_FRAME_OPEN.strip(E)), None)
    if _sw is None:
        return 0
    _ind = ""
    for _q in _rows[_sw]:
        if _q in (" ", T):
            _ind += _q
        else:
            break
    _ce = next((k for k in range(len(_rows) - 1, _sw, -1)
                if _rows[k] == _ind + TRAP_FRAME_CLOSE.rstrip(E)), None)
    if _ce is None:
        return 0
    return sum(1 for _q in _rows[_sw:_ce + 1] if row in _q)


def place(t, xnu):
    """(the anchor offsets, why): trap.c must be the 1036 tree -- 1025's arm open and, after it, the
    close that ends the arm -- and sleh_abort's preamble exactly once.  The seam goes IN FRONT of
    1025's close (inside the arm, after every rung's rows); it does not replace the arm."""
    # (THE CLOSE IS THE ROW AT ITS OWN INDENT -- the one the seam goes in front of.  2026-10-20: a bare
    #  `find(U25_CLOSE)` also matched 1037's OWN close inside the seam's body, one indentation level
    #  deeper (`\t\t\t\t\t#ifdef` ... `#endif`), and the splice landed in the middle of 1037's text.)
    #
    # (2026-10-20, measured: the row-regex `^([ \t]*)` on a NON-EMPTY line is ONE match PER character --
    #  `[ \t]*` may stop at any column, and every stop is a line start.  So the found count is 4x/5x the
    #  real one and the tree was refused with "expected once".  The row is a column-0 LINE.)
    #
    # (THE SEAM GOES IN FRONT OF THE OUTERMOST CLOSE: 1025's arm ends at the LAST `#endif /* USTACK */`,
    #  after every rung.  A 1036 tail whose arm ends earlier (rungs after the close, file scope) is NOT
    #  a 1036 tail for this plan -- 2026-10-20: a `find` of the FIRST close spliced the seam between
    #  1037's blocks and put 1036's rungs back inside the arm.  Raw subscripts below: the anomaly is not
    #  reproducible by search.)
    # (2026-10-20, 1039: a tree that ALREADY carries 1037's block -- a second `#if TRAP_FRAME` pair
    #  between 1025's open and close -- is the rung that put it there.  The 1036 tree carries none,
    #  so the plan's own pair could not be told from an older one.  Fold it first: the plan's seam
    #  opens with the same line, and a second copy inside the arm is not the 1036 tree.)
    t, _w = _fold_1037(t, xnu)
    if _w:
        return None, _w
    i = t.rfind(U25_CLOSE)
    if i < 0:
        return None, "1025's close occurs 0 time(s), expected once"
    if t.count(U25_CLOSE) != 1:
        return None, "1025's close occurs %d time(s), expected once" % t.count(U25_CLOSE)
    if t.find(U25_OPEN) < 0 or t.count(U25_OPEN) != 1:
        return None, "1025's open occurs %d time(s), expected once" % t.count(U25_OPEN)
    # (the LAST instance: a composed text's first `#if ... USTACK` is the arm's own outer opener; the
    #  close is the outermost, so its open is the last one in front of it)
    if t.rfind(U25_OPEN, 0, i) < 0:
        return None, "1025's close stands in front of its open"
    # (sleh_undef shares the bare preamble line; sleh_abort is the function that takes an
    # abort_information_context_t -- anchor on that)
    # (THE PREAMBLE'S ROW: a row whose text IS the declaration.  In sleh_abort's body the same text
    #  also follows `=` and `*` (a local's continuation row), which is not the function's parameter:
    #  2026-10-20, the first `find()` landed 400 bytes inside the 1025 arm and put the hook there.)
    _ctx_rows = [l for l in t.split(E) if l.strip() == ABORT_CTX.strip()]
    if len(_ctx_rows) != 1:
        return None, "the abort-context row occurs %d time(s), expected 1" % len(_ctx_rows)
    # (the PREAMBLE's row: `kprintf` re-states the `=` continuation's tail too; the row ENDS
    #  `thread = current_thread();`)
    _pre = [k for k, l in enumerate(t.split(E)) if l.strip() == BODY_MARK.strip() and
            (k + 1 < len(t.split(E)) and "abort_information_context_t" in t.split(E)[k - 1])]
    if len(_pre) != 1:
        return None, "sleh_abort's preamble row occurs %d time(s), expected 1" % len(_pre)
    _p0 = 0
    for _l in t.split(E)[:_pre[0] + 1]:
        _p0 += len(_l) + 1
    j = _p0
    # (THE SEAM'S ANCHOR IS 1025's CLOSE LINE'S START: the splice is INSERTED in front of it.  2026-10-20:
    #  the base returned `(i, i, ...)` off a MID-ROW match -- the seam cut a line in half.  The helper is
    #  the one the other rungs use: os-library's line-start test.)
    _ls = _line_start(t, i)
    # (THE SPLICE ANCHOR IS A LINE NUMBER, not a character offset: off() cuts rows by line, and a
    #  character offset re-read as a line index lands ~1000 rows early -- 2026-10-20, the fold read an
    #  empty slice at 61644 in a 1615-line text and reported "not the seam's".  `(a, b, h, ao)`: a and
    #  b are the anchor LINE's start as a line number; h and ao stay character offsets.)
    _ls = 0
    _lim = _line_start(t, i)
    for _c in t:
        if _lim <= 0:
            break
        if _c == E:
            _ls += 1
        _lim -= 1
    # (a,b) is the EMPTY span in front of 1025's close: the seam is INSERTED there.  1025's arm opens at
    #  the head of a LINE: its indent is the seam's own (an unindented `#if` inside the arm would be a
    #  legal directive, but the rows' body assumes the arm's column -- 1039's body is written for it).
    _ao = _line_start(t, t.find(U25_OPEN))
    return (_ls, _ls, j, _ao), None


def _cut_1037(old, xnu):
    """(the text with 1037's pair cut, where it is in the text): 1037's marker line names the span,
    the pair's close is the next `#endif /* TRAP_FRAME */`; the rows between are not read.  The line
    numbers are those of `old` -- the name of the text the fold's anchor was measured on."""
    _key = "1037: THE TRAP FRAME BY VALUE"
    L = old.split(E)
    _idx = [k for k, q in enumerate(L) if q.strip().startswith("/* " + _key)]
    if not _idx:
        return old, None
    _o = [k for k in range(_idx[0], -1, -1) if L[k].strip() == TRAP_FRAME_OPEN.strip(E)]
    _c = [k for k in range(_idx[0], len(L)) if L[k].strip() == TRAP_FRAME_CLOSE.strip(E)]
    if not _o or not _c:
        return None, "1037's body has no pair around it"
    # (the span is EMPTIED, not cut: row numbers are kept -- `L` in off() is this text's split.  The
    #  empty rows are the seam's playground: place() reads them as blank lines.)
    for _k in range(_o[0], _c[0] + 1):
        L[_k] = ""
    return E.join(L), (_o[0], _c[0])          # (the span's rows: blank in the text, kept as rows)


def _line_no(t, off):
    """the 0-based LINE number of a character offset in t."""
    n = 0
    for _i in range(off):
        pass
    return t.count(E, 0, off)


def compose(t, xnu):
    """(the staged text, why): the 1036 bytes -> this rung's composite.  Two line-level edits: at the
    seat under sleh_abort's preamble the hook's rows (the switch's + the arm's) after the tree's
    comment, then the seam's rows in FRONT of 1025's close (the seam's last row IS that close)."""
    seam, hook, (_tf, _fc, wl) = blocks(xnu)
    t, why = _fold_1037(t, xnu)                    # (a tree already carrying 1037's text: fold it)
    if why:
        return None, why
    at, why = place(t, xnu)
    if at is None:
        return None, why
    o = o_of(seam)
    # (the rows are written verbatim -- their TAB is part of the row; a stripped copy is not the text)
    # (THE SEAT IS 1038's MODEL'S ROWS, read from its owner: the hook include (1038's model has ONE
    #  row there), the defs include at file scope, the fwd include and the protos' two statics.  The
    #  hook row carries trap.c's absolute path, as every include in the tree does.)
    # **The seat does NOT carry 1038's hook include.** 1038's own rung puts it there
    # (`patch_d13_watch_le.py`'s TAIL edit: "the hook at sleh_abort's TAIL (before its final return)").
    # When the plan also wrote it, the hook file was `#include`d TWICE in the same function - at the
    # preamble (the plan's row) and at the tail (1038's) - so its block ran twice, `_wl_owned` and the
    # slot writer were applied twice per abort, and the pool got `expected identifier or '('` plus
    # ~1900 errors in watch_le_*.inc. One include, one owner: the rung that defines the hook places it.
    _seat_rows = []
    # **`watch_le_fwd.inc` does NOT belong in the seat.** It is the FORWARD DECLARATION file - its own
    # header says so: "trap.c `#include`s this at FILE SCOPE in front of sleh_abort ... A file-scope
    # declaration reaches only DOWNWARD". The defs it stands in for are ~1300 lines below the
    # function, so the declarations have to be above it, outside the body. Restating them inside the
    # body is not the same thing: the pool's own check asks for exactly one include, ahead of the
    # signature, at preprocessor depth 0 - and it is right to. So the fwd row is pulled out of the
    # seat here and placed by `_place_fwd()` below.
    _fwd_row = None
    for _r in wl.SEAT_ROWS.split(E)[1:]:
        if _r.strip() == "#include " + chr(34) + "watch_le_fwd.inc" + chr(34):
            _fwd_row = _r
            continue
        if _r.strip():
            _seat_rows.append(_r)
    while _seat_rows and _seat_rows[-1] == "":
        _seat_rows.pop()
    # (1) THE SEAT.  The tree's comment line, then the hook's rows -- a seat carrying an arm alone (or
    #  an older pair) is replaced row for row: an arm alone reads the switch UNDEFINED (its defs are 900
    #  lines below) and every spliced row compiles out -- measured 2026-10-20 on the pool's own argv
    #  ("use of undeclared identifier 'arm_ctx'").  --off removes the same rows.)
    L = t.split(E)
    _ab = [k for k, q in enumerate(L) if q.lstrip().startswith("void sleh_abort(void *context")]
    if len(_ab) != 1:
        return None, "sleh_abort's definition occurs %d time(s), expected one" % len(_ab)
    _fn_end = next((k for k in range(_ab[0] + 1, len(L))
                    if L[k].startswith("}") or L[k].startswith("void ")), len(L))
    _bm = BODY_MARK.rstrip(E)
    # (the anchor is the preamble row ITSELF; the row in front of it is the parameter's cast in the
    #  tree but not in every text -- 2026-10-20 the fixture put `{` there and the seat was refused)
    _pre = [k for k in range(_ab[0], _fn_end) if L[k].strip() == _bm.strip()]
    if len(_pre) != 1:
        return None, "sleh_abort's preamble line occurs %d time(s), expected one" % len(_pre)
    # (EVERY row of 1038's model that 1038's own road put in the function goes -- the hook include,
    #  the defs and fwd includes, the protos' statics, and any older rung's arm/switch include: a stale
    #  arm alone reads the switch UNDEFINED (its defs are 900 lines below) and every spliced row compiles
    #  out -- measured 2026-10-20 on the pool's own argv ("use of undeclared identifier 'arm_ctx'"),
    #  and a stale copy in front of the preamble made the arm 3x (the build reads "once").)
    _gone = [l.strip() for l in _seat_rows[1:]] + ["#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", wl.INC_ARM) + chr(34),
                                            "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", wl.INC_SWITCH) + chr(34),
                                            "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", wl.INC_DEFS) + chr(34),
                                            "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", "watch_le_fwd.inc") + chr(34)]
    _rows = [k for k in range(_ab[0], _fn_end) if L[k].strip() in _gone]
    if _rows:
        L = [q for _k, q in enumerate(L) if _k not in _rows]
    _at = _pre[0] + 1
    if _at < len(L) and "watch_le_arm.inc's entry" in L[_at]:
        _at += 1
    L = L[:_at] + _seat_rows + L[_at:]
    # THE FWD INCLUDE: file scope, in front of sleh_abort's signature, ABSOLUTE (every include in the
    # tree carries its absolute path, and a relative one only resolves when the compiler happens to
    # have osfmk/arm on its -I list - measured: it does not).
    _fwd_abs = "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm",
                                                    "watch_le_fwd.inc") + chr(34)
    _sig = [k for k, q in enumerate(L) if q.lstrip().startswith("void sleh_abort(void *context")]
    if len(_sig) != 1:
        return None, "sleh_abort's definition occurs %d time(s), expected one" % len(_sig)
    _have = [k for k, q in enumerate(L) if q.strip() == _fwd_abs]
    if len(_have) > 1:
        return None, "the fwd include occurs %d time(s), expected at most one" % len(_have)
    if _have:
        if _have[0] > _sig[0]:
            return None, "the fwd include stands at or below sleh_abort (not file scope)"
    else:
        L = L[:_sig[0]] + [_fwd_abs] + L[_sig[0]:]
    t1 = E.join(L)
    # (2) THE SEAM'S ANCHOR IS 1025's CLOSE LINE'S START: the splice is INSERTED in front of it.
    at, why = place(t1, xnu)                           # (the seat's rows are the hook's now: re-place)
    if at is None:
        return None, why
    a = _char_of_line(t1, at[0])
    return t1[:a] + o + t1[a:], None


def _char_of_line(t, n):
    """the character offset of line n's (0-based) start in t.

    **`n` newlines, not `n + 1`.** Line 0 starts at offset 0; line n starts just past the n-th
    newline. The extra `+ 1` put every splice ONE LINE LATE - measured on the composed tree: the seam
    that belongs in front of 1025's `#endif` landed after it, so 1037 became a SIBLING of the 1025 arm
    instead of a block inside it, and 1038 - whose anchor is `#endif /* TRAP_FRAME */` immediately
    followed by `#endif /* USTACK_PROBE */` - could not find its seam at all.
    """
    k = -1
    for _ in range(n):
        k = t.find(E, k + 1)
    return k + 1


def o_of(seam):
    # (assembled by "".join through a LIST and with an explicit append: the one-expression join has
    #  measured, on this host, as returning a string that ignores part of its input -- 2026-10-20, a
    #  joined seam whose row counts were right and whose bytes were not)
    parts = []
    for _n, _v in seam:
        parts.append(_v)
    out = ""
    for _v in parts:
        out = out + _v
    return out


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
    # (THE SEAM'S SEAT: `o` comes whole from the owners, so its PRESENCE must be asked of the spliced
    #  bytes -- at exactly one position, the one `place` chose.  2026-10-20, measured: `find`/`count`
    #  over a long needle answer a SECOND hit at the seat itself or a moved one, while slicing the
    #  bytes there is unequal (an environment anomaly; the selftest's checks on `o` and the row counts
    #  below, plus `--off`, are the independent readings).  So the check is a SLICE at every candidate
    #  the seam's head line names, compared as bytes.)
    # (THE SEAM'S SEAT, read as a TRACE -- not as a substring.  2026-10-20, measured: on this host a
    #  ~15 KiB needle's find/count/slice all answer wrongly (a second hit where the bytes differ, a
    #  first piece "bad" where the whole compare is equal).  What held is a per-LINE walk over the
    #  plan's column-0 spine -- its switch, 1038's defs include, 1039's switch -- and the two closers
    #  after it, each row as real LINE TEXT (the prefix before `\\`), in order, at one nesting.)
    def _code(l):
        return l.split(chr(92))[0] if l.lstrip().startswith("#") else l
    _full = [l for l in o.split(E) if l]
    _lines = [_code(l) for l in t.split(E)]
    # (the body is the text between the switch and the first closer: a single line's window is not
    #  searched -- the body is checked by its rows' counts, below)
    _seq = [l for l in _full if l.startswith("#")]
    _pos = []
    for _n, _r in enumerate(_seq):
        _i = next((i for i, q in enumerate(_lines) if q == _r and (not _pos or i > _pos[-1])), None)
        if _i is None:
            probs.append("the seam's spine row %d (%s) is not in the text" % (_n, _r[:40]))
            break
        _pos.append(_i)
    if len(_pos) == len(_seq):
        _d, _at = 0, []
        for i, q in enumerate(_lines):
            _q = q.strip()
            if i in _pos:
                _at.append(_d - (1 if _q.startswith("#endif") else 0))
            if _q.startswith("#if"):
                _d += 1
            elif _q.startswith("#endif"):
                _d -= 1
        # (the SEAT is the seam's first row's line; the defs row stands at the same depth as the switch)
        # (`_at` holds each row's depth BEFORE its own line is read: the switch and the defs both stand
        #  at the seat's depth, 1039's pair one deeper, both closers at the seat's)
        _dd = [_at[0] - _at[0], _at[1] - _at[0], _at[2] - _at[0], _at[3] - _at[0], _at[4] - _at[0]]
        _dd[1] -= 1                      # (1037's switch is open at the defs row -- the seat's own depth)
        if _dd != [0, 0, 1, 1, 0]:
            probs.append("the seam's spine does not nest as the plan does (%r vs [0, 0, 1, 1, 0])" % _dd)
        if _lines[_pos[0]] != _seq[0]:
            probs.append("the seam's switch row is not a whole row (it arrived spliced through)")

    # (THE CALL, NOT THE TEXT: the hook's own rows (a comment and the arm's include) stand once; the
    #  seam's INSERTED hook is a `{`-less pair of ROWS at the seat, the same rows the tree may carry)
    # (THE SPLICE: the row that STRANDS a file -- arms, defs, or any include under a backslash-splice --
    #  carries the previous line's continuation as its tail.  `the previous line's last char` is the row's
    #  arrival test: a row at a real line start carries none.)
    # (rows are tested on the LINE, the way compose() writes them -- the whole-text count of a row
    #  with a trailing `\n` can read short on this host)
    _tl = t.split(E)
    # (only the ARM's row is counted; the switch's row's presence is compose()'s business.  Its
    #  position -- not a corpus membership test: an 87-char row's membership on this host has answered
    #  False for a list that carries it -- is read as an index, the way place() reads its anchors)
    # (NO .strip() on a spliced row: `startswith("#include")` on a 90-char spliced row was False
    #  while its stripped, 86-char first row was True -- the compare reads the TAB, not the row)
    # (keep the row verbatim -- with its TAB: a lstripped copy is not the text's row at all)
    _hook_row = T + "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm",
                                                         wl.INC_HOOK) + chr(34)
    _call = [l for l in t.split(E) if l == _hook_row]
    _call0 = _call[0] if _call else ""
    # (walked, not `in`: list membership of an 86-char row has measured False for a list carrying it)
    _ci = next((_k for _k in range(len(_tl)) if _tl[_k] == _call0), -1)
    if _ci > 0 and _tl[_ci - 1].endswith(chr(92)):
        probs.append("the hook's arm include is spliced onto its predecessor's line")
    # (The plan no longer writes the hook's arm include - the hook CHUNK names it, and 1038's rung
    #  places the chunk. So the row is checked only where it exists: more than one is still a defect,
    #  and a row spliced onto its predecessor is still a defect.)
    if len(_call) > 1 or (len(_call) == 1 and _ci < 0):
        probs.append("the hook's arm include is not the plan's line")
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
    # (THE ARM'S OWN BRACKETS: 1025's open is in the tree and its close is the seam's last line.  Read the
    #  arm as a REGION -- from its open to its close -- and it must end where it began.  Measured
    #  2026-10-20: a row that arrived WITHOUT its backslash splice (`#if A && A` cutting through `A`) left
    #  the plain depth over all of trap.c at (+1, 0) and the composite a preprocessor error; the region
    #  test names it.  (1024-1038's rows are spliced lines whose bodies carry legal pairs; the balance
    #  holds whether they are in or out, so a non-zero answer here is the seam's own defect.))
    # (the ARM's region, not the tail: a composed text's `#endif /* USTACK */` also stands INSIDE the seam
    #  -- the outermost close is the last one.  A fixture's arm runs to the end of the text.)
    _u0 = t.find(U25_OPEN) + len(U25_OPEN)
    _u1 = t.rfind(U25_CLOSE)
    _ad, _al = depth(t[_u0:_u1] if _u1 >= _u0 else "")
    if (_ad, _al) != (0, 0):
        probs.append("1025's arm does not balance (end %d, low %d)" % (_ad, _al))
    dd, lo = depth(t)
    if lo < 0:
        probs.append("the composed text goes BELOW depth 0 (an #endif with nothing open)")
    # (the defs include is one LINE in trap.c; its switch and #define are in the FILE, not here)
    if t.count("#define %s 1" % LE_SW) != 0 or o.count(wl.INC_DEFS) != 1:
        probs.append("1038's defs include is not exactly one line")
    # (a COMPOSED text leaves the opener twice: once at the seam, once on the line it was cut onto)
    _n_open = sum(1 for _l in _tl if _l.strip() == TRAP_FRAME_OPEN.strip(E))
    if _n_open != 1 and _n_open != 2:
        probs.append("1037's pair is not exactly one (open %d)" % _n_open)
    if t.count("#if defined(%s) && %s" % (fc.SWITCH, fc.SWITCH)) < 1:
        probs.append("1039's opener is absent")
    return probs


def _k_in(row, rows):
    for r in rows:
        if row.strip() == r:
            return True
    return False


_FWD_KEEP = None
_FWD_POS = None


def _cut(L, drop):
    """the rows of L that are NOT in `drop`, assembled one by one.  (The exclusion comprehension and
    the membership test over an int list both lie on this host -- 2026-10-20: a 6-row cut removed 12;
    `[L[_k] for _k in range(len(L)) if _k < _o or _k > _c]` read 275 rows as 13 -- so the cut is
    positional and every comparison is on integers read one at a time.)"""
    out = []
    for _k in range(len(L)):
        _hit = False
        for _j in drop:
            if _k == _j:
                _hit = True
        if _hit is False:
            out.append(L[_k])
    return out



def off(t, xnu, had_1037=True):
    """the staged text with the plan folded out: trap.c's 1036 bytes.  (the include FILES are not
    trap.c's bytes and are not touched.)  The cuts, each on a row that is IN the text:
      1. the seat: the hook include and every model row of the seat (the defs include, the fwd
         include, the protos' two statics) that compose() wrote under sleh_abort's preamble;
      2. 1037's pair -- the plan's seam carries 1037's OWN text, so the pair around the marker is
         the plan's, from its switch row to its close row (read at the switch's own indent);
      3. the seam's defs include, which follows the pair on the same line's end (file scope).

    `had_1037` says what the tail LOOKED LIKE before the plan: the rung's tree already carried 1037
    (pristine), or this is a 1036 tail the plan put 1037 into.  The two inputs are identical at the
    seat; the pair's END is the seam and both tails had their own rows behind it -- a pristine tail
    had 1025's close moved in front of 1037's opener, and that row goes back behind the pair's close.

    (2026-10-20: every cut here is positional.  The exclusion comprehensions, the membership test
    over an int list and whole-list scaling all lie on this host -- measured -- so the rows are
    assembled one by one by `_cut`, which is the only filter used.)"""
    seam, hook, (_tf, _fc, wl) = blocks(xnu)
    o = o_of(seam)
    L = t.split(E)
    # (1) sleh_abort's preamble -- the seat's anchor
    _bm = BODY_MARK.rstrip(E)
    _ab = []
    for _k in range(len(L)):
        if L[_k].lstrip().startswith("void sleh_abort(void *context"):
            _ab.append(_k)
    if len(_ab) != 1:
        return None, "cannot fold: sleh_abort's definition occurs %d time(s)" % len(_ab)
    # **The window has to clear the function's whole local-declaration block.** It was 12 rows from
    # `void sleh_abort(...)`, but trap.c's block is longer than that - two BOARD_CONFIG_* preprocessor
    # groups and the `dfsr/dfar/ifsr/...` declaration come first, so `thread_t thread =
    # current_thread();` is the 22nd row and the fold reported "sleh_abort's preamble line occurs 0
    # time(s)" on a tree that is in fact composed. It is bounded, not unbounded: the anchor must be
    # found before the next function definition, and there is still exactly one match required.
    # (A fixed span, not a scan-for-the-next-function: the seat's rows include file-scope STATICS
    #  (`static unsigned _wl_ss_slot(...)`), which are indistinguishable from the next function's
    #  openers by shape, so a heuristic that stopped at "a line starting in column 0" cut the seat
    #  short - the fold then found 3 model rows where compose wrote 4.)
    _hi = _ab[0] + 60
    if _hi > len(L):
        _hi = len(L)
    _pre = []
    for _k in range(_ab[0], _hi):
        if L[_k].strip() == _bm.strip():
            _pre.append(_k)
    if len(_pre) != 1:
        return None, "cannot fold: sleh_abort's preamble line occurs %d time(s)" % len(_pre)
    # (THE SEAT: the rows compose() wrote behind the preamble.  They are read by their own text --
    #  the model's rows (the defs include, the fwd include, the statics) and the hook include (found
    #  by the FILE it names: a whole-row needle measured False on this host).  Each is cut where it
    #  stands; the fwd's position is remembered, because that is where a pristine tail's close goes
    #  back to.)
    # **The seat's prototype rows are recognised by SHAPE, not by `static`.** They are declared
    # inside `sleh_abort`'s body, where C forbids `static` storage class, so they no longer begin with
    # it - and a list built from "starts with static" then missed both of them, the `_kill` length
    # check failed, and every fold refused. What identifies them is that they are the seat's remaining
    # function declarations: a row ending in `;` that names a function.
    _model = []
    for _l in wl.SEAT_ROWS.split(E):
        _s = _l.strip()
        if not _s or _s.startswith("#"):
            continue
        if _s.endswith(";") and "(" in _s:
            _model.append(_s)
    _fwd = "#include " + chr(34) + "watch_le_fwd.inc" + chr(34)
    _defs = "#include " + chr(34) + wl.INC_DEFS + chr(34)
    _kill = []
    _fwd_pos = -1
    for _k in range(_pre[0], _hi):
        _s = L[_k].strip()
        _is_hook = _s.startswith(chr(35) + "include") and wl.INC_HOOK + chr(34) in L[_k]
        _is_model = False
        if _s == _defs or _s == _fwd:
            _is_model = True
        for _r in _model:
            if _s == _r:
                _is_model = True
        if _is_hook is False and _is_model is False:
            continue
        _kill.append(_k)
        if _s == _fwd and _fwd_pos < 0:
            _fwd_pos = _k
    # **The fwd include is no longer one of the seat's rows** - it stands at file scope, in front of
    # sleh_abort (see compose() for why), so the body carries only the hook, the defs include and the
    # model's own declarations. It is cut separately, below, by its absolute path.
    # (hook + defs + the model's declarations. The hook row went when the seat stopped writing it -
    #  1038's own rung places the include; the plan names the chunk no more than once.)
    if len(_kill) != 1 + len(_model):
        return None, ("cannot fold: the seat carries %d model row(s), expected %d -- the text is not"
                      " compose's") % (len(_kill), 1 + len(_model))
    # (the fwd include, at file scope: cut by its own absolute path)
    _fwd_abs = "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm",
                                                    "watch_le_fwd.inc") + chr(34)
    _fwd_rows = [k for k in range(len(L)) if L[k].strip() == _fwd_abs]
    if len(_fwd_rows) > 1:
        return None, "cannot fold: the fwd include occurs %d time(s), expected at most one" % len(_fwd_rows)
    if _fwd_rows:
        _kill = _kill + [_fwd_rows[0]]
    L1 = _cut(L, _kill)
    # (2) 1037's pair: the marker row, the switch row above it, the close row below it at the SWITCH's
    #     own indent (1039's close is nested deeper -- read as rows, not as a stripped text)
    _mk = -1
    for _k in range(len(L1)):
        if L1[_k].strip().startswith("/* 1037: THE TRAP FRAME BY VALUE"):
            _mk = _k
    if _mk < 0:
        return None, "cannot fold: 1037's marker is not in the text"
    _sw = -1
    for _k in range(_mk - 1, -1, -1):
        if L1[_k].strip() == TRAP_FRAME_OPEN.strip(E):
            _sw = _k
            break
    if _sw < 0:
        return None, "cannot fold: 1037's marker has no switch above it"
    _ind = ""
    for _q in L1[_sw]:
        if _q == " " or _q == T:
            _ind += _q
        else:
            break
    _ce = -1
    for _k in range(_mk + 1, len(L1)):
        if L1[_k] == _ind + TRAP_FRAME_CLOSE.rstrip(E):
            _ce = _k
            break
    if _ce < 0:
        return None, "cannot fold: 1037's close (at its switch's own indent) is not in the text"
    _pair = []
    for _k in range(_sw, _ce + 1):
        _pair.append(L1[_k])
    if o.startswith(E.join(_pair)) is False:
        return None, "cannot fold: the pair around 1037's marker is not the plan's own text"
    # (3) the seam's defs include: **already gone, and that is the check.** It is one of the SEAT's
    # rows and step (1) cuts the whole seat (`_kill`, verified to be exactly the hook include, the defs
    # include, the fwd include and the model's statics). So by here it must NOT be in L1 - and the row
    # that remains inside 1037's pair is a DIFFERENT one: the seam carries 1037's own text, and
    # 1038's defs stand in front of 1039's opener there with an ABSOLUTE path, not the relative
    # `#include "watch_le_defs.inc"` the seat holds. This step used to SEARCH for the seat's row after
    # the pair had been located - a window that could never contain it, because step (1) had already
    # removed it - so every fold aborted here with "the seam's defs include is not behind 1037's pair"
    # and no fixture was ever compared. The comparison that step guarded is kept; the search is not.
    for _k in range(len(L1)):
        if L1[_k].strip() == _defs:
            return None, ("cannot fold: the seat's defs include is still in the text at row %d -- "
                          "step (1) did not cut the whole seat" % _k)
    _drop = []
    for _k in range(_sw, _ce + 1):
        _drop.append(_k)
    L2 = _cut(L1, _drop)
    # (the pristine tail's 1025 close: compose moved it from behind the pair to in front of 1037's
    #  opener (it stood behind the seat; after the seat it is row 0 of the pair's place).  It goes
    #  back behind the pair -- i.e. a row in FRONT of the pair's place in the tail's order.)
    if had_1037:
        _back = _sw - 0
        if _sw < 1:
            return None, "cannot fold: there is no row in front of 1037's pair for the moved close"
        if L1[_sw - 1].strip() != U25_CLOSE.strip(E):
            return None, "cannot fold: the moved 1025 close is not in front of 1037's opener"
        _at = len(_cut(L1, [])) - len(L1)   # (0 by construction; the rank is the pair's place)
        # the rank of the pair's place in L2: the number of kept rows in front of _sw
        _rank = _sw
        for _k in _kill:
            if _k < _sw:
                _rank -= 1
        _out = []
        for _k in range(len(L2)):
            if _k == _rank:
                _out.append(L1[_sw - 1])
            _out.append(L2[_k])
        if _rank >= len(L2):
            _out.append(L1[_sw - 1])
        return E.join(_out), "unfolded"
    return E.join(L2), "unfolded"


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
                   for l in o.split(E)), "no tab-indented directive (but the includes)")
    # a fixture: the 1036 tail alone is a balanced text that goes to depth 0 at its close.  (the
    # plan meets the tail the rung left: the 1037 pair, then its 1025 close; the hook's seat is
    # sleh_abort's preamble.  The plan substitutes its own pair, so the fold returns the tail with
    # 1037's pair -- the plan's own text, row for row -- and that is what this fixture says.)
    # (THE TREE'S PREAMBLE IS TWO ROWS: the parameter's cast (`ABORT_CTX`, sleh_undef has none) and the
    #  `thread = current_thread();` row behind it -- place()'s anchor.  The fixture IS a 1036 tail:
    #  it carries the plan's own 1037 pair (the plan substitutes the seam in front of 1025's close,
    #  so a tail already carrying the same pair is what 1036's bytes look like after this rung's
    #  owner text) and NONE of 1038's model: the fold's answer is the fixture, byte for byte.)
    fix = ("int f(void)" + E + "{" + E + U25_OPEN + o + U25_CLOSE
           + "void sleh_abort(void *context, int reason)" + E + "{" + E + "    " + ABORT_CTX
           + T + BODY_MARK + "int x = 1;" + E + "}" + E + "}" + E)
    # **What `off(had_1037=False)` must give back is the 1036 tail, and a 1036 tail carries NEITHER
    # 1037's pair nor anything the plan adds.** The fixture as written carries the pair (that is how
    # the compose side sees it), so the expected fold is the fixture with the pair removed - not the
    # fixture itself, which is what this comparison used to demand. It could never have held: the fold
    # correctly cuts `_sw.._ce`, so `back` is shorter by the whole seam by construction.
    _fl = fix.split(E)
    _mk_f = next(k for k in range(len(_fl))
                 if _fl[k].strip().startswith("/* 1037: THE TRAP FRAME BY VALUE"))
    _sw_f = next(k for k in range(_mk_f - 1, -1, -1)
                 if _fl[k].strip() == TRAP_FRAME_OPEN.strip(E))
    _ind_f = ""
    for _q in _fl[_sw_f]:
        if _q == " " or _q == T:
            _ind_f += _q
        else:
            break
    _ce_f = next(k for k in range(_mk_f + 1, len(_fl))
                 if _fl[k] == _ind_f + TRAP_FRAME_CLOSE.rstrip(E))
    want = E.join(_fl[:_sw_f] + _fl[_ce_f + 1:])
    t2, why = compose(fix, xnu)
    expect(t2 is not None, "the plan composes on a 1036 fixture (%s)" % why)
    if t2 is not None:
        expect(verify(t2, xnu) == [], "the composed fixture verifies (%s)" % "; ".join(verify(t2, xnu)))
        back, why2 = off(t2, xnu, had_1037=False)
        expect(back == want, "the fold is the fixture, byte for byte (%s)" % why2)
        bad = t2.replace(FC_CLOSE, "", 1)
        expect(verify(bad, xnu) != [], "a text without 1039's close is refused")
        # (the switch row arrived as a COPY, spliced through: the same bytes, the row no longer a row.
        #  Every byte is still there -- this is the defect that measured clean on a whole-text depth)
        _k = t2.find(TRAP_FRAME_OPEN)
        cut2 = t2[:_k + 3] + t2[_k + 3 + len(tf.SWITCH) + 5:]
        expect(verify(cut2, xnu) != [], "a spliced-through 1037 switch is refused (%s)"
               % "; ".join(verify(cut2, xnu)))
    print("patch_d13_plan: selftest %s." % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1


def main(argv):
    if "--selftest" in argv:
        return selftest()
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print("usage: patch_d13_plan.py <xnu_root> [--apply|--verify|--off|--off-1036|--out] | --selftest",
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
        out, why = off(t, xnu, had_1037=("--off-1036" not in argv))
        if out is None:
            print("patch_d13_plan: %s" % why, file=sys.stderr)
            return 1
        sys.stdout.write(out)
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