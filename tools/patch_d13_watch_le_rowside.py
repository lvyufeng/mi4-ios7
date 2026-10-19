"""1038's ROW SIDE, LAID OUT ARIGHT -- the trap.c edit that splits 1038's text into (a) the piece the
tree carries BEFORE 1039's frame carrier stages (R16, what --apply writes) and (b) the piece 1039's
carrier carries across its seam (R18, what --restage-host writes), so that 1038's arm compiles OUT when
STAGE90_XNU_WATCH_LE is not defined, byte-true in [idempotent] when the tree already holds either.

WHAT THE TREE CARRIES (measured 2026-10-19, /tmp/rec1039/work5): 1038's row side stands AFTER 1037's
close, inside 1025's data-abort arm, as three sections ALL inside `#if 1`: chunk a -- the statics group
(`#ifndef WATCH_LE_STATICS_DEFINED`, its `#define`, the slot writer) and the gate table (`unsigned
xnu_live_wlg_*`), closed by `#endif /* 1038 chunk */`; then a stray `#define STAGE90_XNU_WATCH_LE 1`;
then chunk c -- the arm's carried bracket `#if defined(SWITCH)`, arm A (marker `/* ===== A: THE STACK
WATCH`), its INDENTED close, the unit's two braces (`\n\t}\n}\n`), the gate + LE rows, and
`#endif /* 1038 chunk */`.  `#if 1` has no OFF: the arm and its rows compile into the kernel whatever
the record says; and the stray define forces the switch ON ([[mi4-off-option-two-spellings]]).

THE TWO LAYOUTS (both composed from the tree's own bytes by `carry()`):

  R16 -- what --apply writes, the pre-1039 carrier text, still ONE well-nested preprocessor text:

    <host: everything before the stray, the stray dropped> <tail: unit braces + the rows, through chunk
    c's close> \t\t\t\t\t/* 1037 prologue */\nint ZQ1;\nint ZQ2;\n <the switch pair baked onto
    chunk c's marker: #if defined(SWITCH) && SWITCH + chunk a's body + chunk c's body without its stray>
    #endif /* 1038 chunk */ \n\t#endif <USTACK close>

  R18 -- what --restage-host writes, once 1039's carrier has run: 1039's caller-probe host (1037's block
  and its closes gone) + the same tail + the prologue + `\n\t#endif <USTACK close>\n` + 1039's FC block
  (which restores 1037's close at its end, 1025's close via its own line).  1038's carried text stands
  INSIDE 1039's block; undefined, it is an empty switch.

No `#define` of the switch survives either layout.  Undefined, the arm compiles out: the gate table is
an ARCHIVE (the rows' `1U << gate` constants), no A/B statement is reached, and every 1038 row
vanishes.  Defined, the text is 1038's, statement for statement.

IDEMPOTENT by VALUE: R16 is recognized by its own head (the statics' `#ifndef` directly behind a
column-0 line, no `#define SWITCH`, the prologue marker); R18 by 1039's FC close behind the prologue.
--verify / --verify-off pass on R16; --verify-host / --restage-host on R18 (R18 carries no
TRAP_FRAME opener of its own: 1039's host does).

[compile-safety] every directive 1038 contributes keeps its column: the statics chunk's column-0
`#endif`s stand inside `#if defined(S)` (column 0 is where the preprocessor reads them), and the arm's
statements are C statements of the function 1037's block opens.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_WATCH_LE"
TRAP_REL = "osfmk/arm/trap.c"

T = chr(9)
E = chr(10)
CHUNK_OPEN = "#if 1   /* 1038 chunk: arm */" + E
CHUNK_CLOSE = "#endif /* 1038 chunk */" + E
CHUNK_MARK = CHUNK_OPEN.rstrip(E)
BLOCK_END = "#endif /* 1038 BLOCK END */" + E
SW_OPEN = "#if defined(%s) && %s" % (SWITCH, SWITCH) + E
SW_CLOSE = "#endif /* %s */" % SWITCH
STRAY_L = "#define %s 1" % SWITCH
ARM_MARK = "/* ===== A: THE STACK WATCH (first:"
GATE_FIRST = "unsigned xnu_live_wlg_byte;"


def read(p):
    with open(p, "rb") as f:
        return f.read().decode("utf-8")


def write(p, t):
    with open(p, "wb") as f:
        f.write(t.encode("utf-8"))


_ORIG_FIND = None


def find_tree(t):
    """(start of chunk c, end of chunk c's close, chunk c's text).  Chunk c's text opens with 1037's bare
    head pair (which stands IN FRONT of chunk c's marker; rowside runs before 1037's --restage and writes
    the head's body with the block).  Raises ValueError."""
    n_open = t.count(CHUNK_OPEN)
    n_close = t.count(CHUNK_CLOSE)
    if n_open != 2 or n_close != 2:
        raise ValueError("chunk markers are not two pairs (openers %d, closes %d)" % (n_open, n_close))
    a1 = t.index(CHUNK_OPEN)
    e1 = t.index(CHUNK_CLOSE, a1 + len(CHUNK_OPEN))
    if GATE_FIRST not in t[a1:e1] or "#ifndef WATCH_LE_STATICS_DEFINED" not in t[a1:e1]:
        raise ValueError("the first chunk is not the statics group + gate table")
    a2 = t.index(CHUNK_OPEN, e1 + len(CHUNK_CLOSE))    # (the marker -- as a line: the chunk's)
    _stray_at = t.index(STRAY_L + E)
    if t.count(STRAY_L + E) != 1 or not (e1 < t.index(STRAY_L + E) < a2):
        raise ValueError("no single stray `%s` between the chunks" % STRAY_L)
    e2 = t.rindex(CHUNK_CLOSE) + len(CHUNK_CLOSE)      # (chunk c's close: the LAST -- the statics' is in front)
    if e2 != t.index(CHUNK_CLOSE, a2) + len(CHUNK_CLOSE):
        raise ValueError("chunk c's close does not sit at the end of its text")
    _h37 = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME"
    h = t.rfind(E + _h37, 0, a2)
    if h < 0:
        raise ValueError("1037's head does not stand in front of chunk c's marker")
    # by VALUE: chunk c's text is everything from 1037's head to its close -- the head, the marker's text
    # (1038's, dropped with the carried text), the arm, the rows.  (Whether the marker's own words stand on a
    # line of their own or the bytes of a carried bracket follow them is 1038's text's business: `reform` reads
    # the arm by its marker, the rows by the last carried close.)
    a2 = _stray_at + len(STRAY_L + E)   # (the chunk's own text: from the head, which stands behind the stray)
    chunk = t[a2:e2]
    if ARM_MARK not in chunk:
        raise ValueError("chunk c does not carry arm A's marker")
    # (where the marker stands: the block's line takes the place of the tree's chunk text from there on)
    return t.rindex(CHUNK_OPEN, 0, e2), e2, chunk


def reform(t):
    """(host, tail, slot): the pre-1039 text split into three pieces by VALUE.

    The tree (2026-10-19, work5): ... 1025's arm ... 1037's head pair, `int ZQ1; int ZQ2;`, then, inside
    1025's arm:
        #if 1 /* 1038 chunk */                       chunk a: the statics, the slot writer
        ... statics, gate table ...
        #define STAGE90_XNU_WATCH_LE 1               the stray (forces the switch ON)
        #endif /* 1038 chunk */
        #if 1 /* 1038 chunk */                       chunk c: the arm's carried bracket
        #if defined(SWITCH) && SWITCH
        ... arm A ...  #endif /* SWITCH */           (tab-indented)  }  }
        ... the gate + LE rows ...  #endif /* 1038 chunk */

      host -- 1037's own text in front of the seam (the stray dropped), through 1037's head pair and the
              unit's declarations;
      slot -- 1038's slot: ONE switch opener, then chunk a (statics + gate + arm A + the arm's close,
              re-emitted at column 0, all under one `#if 1`) and chunk a's own close; the rows are NOT in
              it;
      tail -- the unit's braces, through chunk c's close (the gate + LE rows).
    `slot`'s opener is 1037's head in --apply's layout (written INSIDE 1037's block) and 1039's FC block
    in --restage-host's; either way 1038's arm is undefined <-> compiled out.
    """
    n_open, n_close = t.count(CHUNK_OPEN), t.count(CHUNK_CLOSE)
    if (n_open, n_close) == (4, 4):
        raise ValueError("the text is already laid out (--apply has written 1038's slot); --restage-host "
                         "takes the PRE-1039 text, once 1039's carrier is staged")
    if n_open != 2 or n_close != 2:
        raise ValueError("chunk markers are not two pairs (openers %d, closes %d)" % (n_open, n_close))
    a1 = t.index(CHUNK_OPEN)
    c1 = t.index(CHUNK_CLOSE, a1) + len(CHUNK_CLOSE)   # (chunk a's close)
    a = t.index(CHUNK_OPEN, c1)                        # (chunk c's marker)
    if not t.startswith(CHUNK_OPEN + SW_OPEN, a):
        raise ValueError("chunk c's marker is not followed by the arm's carried bracket")
    sd = t.index(STRAY_L + chr(10))
    if t.count(STRAY_L + chr(10)) != 1 or not (a1 < sd < a):
        raise ValueError("the stray `%s` is not once, inside chunk a" % STRAY_L)
    if GATE_FIRST not in t[a1:c1] or "#ifndef WATCH_LE_STATICS_DEFINED" not in t[a1:c1]:
        raise ValueError("chunk a is not the statics group + gate table")
    if c1 + len(STRAY_L + chr(10)) != a:
        raise ValueError("the stray does not stand between chunk a's close and chunk c's marker")
    if ARM_MARK not in t[a:a + 200000]:
        raise ValueError("chunk c does not carry arm A's marker")
    # THE TREE'S ORDER (taken from the tree's own chunk text, not written from memory): chunk c's
    # marker, the switch, chunk a RE-EMITTED (statics + gate), the STRAY, the bracket's opener, the
    # arm (its own switch), the arm's close, A BLANK LINE, the bracket's TAB close, its COLUMN-0 close,
    # the ROWS, the switch's SECOND close, then -- still open -- the unit's `}` `}`, the rows AGAIN,
    # and chunk c's close.  The FIRST switch close is the arm's; the SECOND is the rows'.
    #
    # GEOMETRY ONLY.  This host's Python reads int `<`/`>` inconsistently on loaded lines (measured
    # 2026-10-19: four spellings of one order all returned False on ints that are ordered), so order
    # is checked with `find(needle, after)` -- and with `t[...]==...` -- never by comparing two ints.
    unit = UNIT
    sc = [k for k in range(len(t)) if t.startswith(SW_CLOSE, k) and t[k - 1] in (E, T)
          and (t[k + len(SW_CLOSE):k + len(SW_CLOSE) + 1] in ("", E, T))]
    if len(sc) != 2:
        raise ValueError("the switch's closes are not exactly two (saw %d)" % len(sc))
    if t.find(SW_CLOSE, a) != sc[0]:
        raise ValueError("the arm's close does not stand behind chunk c's marker")
    if t[sc[0] - 1] != T:
        raise ValueError("the arm's close is not INDENTED (it is the arm's)")
    kc = t.index(CHUNK_CLOSE, a)                       # (chunk c's close: the slot's END)
    if t.find(SW_CLOSE, sc[0] + len(SW_CLOSE)) != sc[1]:
        raise ValueError("the rows' close does not stand behind the arm's close")
    ub = t.find(unit, sc[0], kc)                       # (the bracket the ROWS follow: inside chunk c)
    if ub < 0:
        raise ValueError("chunk c carries no tab-`}` / `}` brace pair")
    while "xnu_live_wlg_need_le" not in t[ub:ub + 4000]:
        nxt = t.find(unit, ub + 4, kc)
        if nxt < 0:
            raise ValueError("no carried brace pair inside chunk c with the rows behind it")
        ub = nxt
    if t.find(SW_CLOSE, ub) != sc[1]:
        raise ValueError("the rows' close does not stand behind the carried braces")
    a25 = t.index(E, sc[0]) + 1                        # (behind the arm's TAB close: the blank line's
    if t.startswith(E, a25):                           #  first byte) -- ONE blank line; the second
        a25 += 1                                       #  `\n` is the bracket's first close
    a_body = (CHUNK_OPEN + t[a1 + len(CHUNK_OPEN):c1]  # (the statics, under their `#if 1`, through the
              + STRAY_L + E)                           #  stray -- which forces the arm ON; --apply drops
    #                                                   it by VALUE; a re-composition puts it back)
    c_body = (t[a:a25]                                 # (chunk c's marker, the bracket, the arm, the
              + t[ub:kc])                              #  arm's close, the blank, the bracket's closes,
    #                                                   the ROWS -- through chunk c's close)

    # THE SWITCH'S BODY, IN THE TREE'S ORDER: chunk c's marker (re-opened), chunk a re-emitted and
    # SCOPED to this switch (so its `#define SWITCH` reaches the arm nowhere else), the STRAY, the
    # bracket, the arm, the arm's close, the blank, the bracket's closes, the ROWS, the switch's close.
    # `a_body` is ALREADY `CHUNK_OPEN + chunk a's body + STRAY + CHUNK_CLOSE`; a re-opener was prepended
    # here until 2026-10-19 and made the whole nested group invisible to the preprocessor.
    if CHUNK_CLOSE not in a_body or not a_body.startswith(CHUNK_OPEN):
        raise ValueError("chunk a's body is not one `#if 1` group ending in the chunk's close")
    slot = SW_OPEN + a_body + c_body + SW_CLOSE + E     # (a line: the block head follows it)
    tail = t[ub + 1:kc + len(CHUNK_CLOSE)]              # (the bracket's TAB close, its COLUMN-0 close,
    #                                                    the ROWS, and the close's own line)
    host = t[:sd] + t[sd + len(STRAY_L + chr(10)):]
    return dict(host=host, tail=tail, slot=slot)


POSE_MARK = "/* 1037 prologue */"
POSE = T * 5 + POSE_MARK + E + "int ZQ1;" + E + "int ZQ2;" + E
U25_CLOSE = "#endif /* STAGE90_XNU_USTACK_PROBE */"
C37 = "#endif /* STAGE90_XNU_TRAP_FRAME */" + E
O37 = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME" + E

# The wrapped original's tail.  READ FROM THE TREE, not written here: `reform` splits 1038's slot into
# chunk c + tail at these braces by POSITION (they are the bracket's two closes, and the rows follow
# them), so if the tree's shape and this constant drift apart, `reform` re-composes a group that emits
# the rows twice and keeps the stray `#define` (observed 2026-10-19: a too-early `a25` put chunk c's
# marker *behind* `ub`, the slice t[ub:kc] re-emitted the rows, the host kept the stray).
UNIT = E + chr(9) + "}" + E + "}" + E


def _unit_braces():
    """`UNIT`, verified against the staged trap.c: the tab-`}` / `}` pair is there at least once and the
    rows stand behind the one `reform` picks.  (A comment is not a check.)"""
    src = os.environ.get("TRAP_SRC")
    if not src or not os.path.isfile(src):
        return UNIT
    with open(src) as f:
        t = f.read()
    n = t.count(UNIT)
    if n < 1:
        raise ValueError("the staged trap.c carries no tab-`}` / `}` pair -- UNIT is not the tree's shape")
    ub = t.index(UNIT)
    if "xnu_live_wlg_need_le" not in t[ub:]:
        raise ValueError("the staged trap.c's rows do not stand behind its carried braces")
    return UNIT


def _fc_block():
    """1039's carrier block, by value from its own patcher (the text tree --restage-host carries)."""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("_fc1039", os.path.join(here, "patch_d13_frame_carrier.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.TRAP_BLOCK


def _unit_split(h):
    """(s, e): 1037's unit -- a column-0 `#if defined(TRAP_FRAME)` whose own close stands on the line
    behind it (1037's block head, standing in front of its close), opened behind 1037's own text.  The
    tree's form is the bare unit: head, close, the unit's declarations (`int ZQ1;`)."""
    s = -1
    k = h.find(O37)
    while k >= 0:
        if k > 0 and h[k - 1] == E and h.startswith(C37, k + len(O37)):
            s = k
            break
        k = h.find(O37, k + 1)
    if s < 0:
        raise ValueError("1037's unit (a column-0 TRAP_FRAME head with its close behind) is not in the host")
    return s, s + len(O37) + len(C37)


def _text_start(h):
    """where 1037's own text begins: behind 1036's close (PC_CARRIER_CALLER)."""
    r = h.find("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */" + E)
    if r < 0:
        raise ValueError("1036's close (PC_CARRIER_CALLER) does not stand in the host")
    return r + len("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */" + E)


def _prologue_line(h, start=0):
    """the line that opens 1037's prologue: the marker's line where the tree names it, else 1037's own
    comment line (`/* 1037: THE TRAP FRAME`)."""
    k = h.find(POSE_MARK, start)
    if k < 0:
        k = h.find("/* 1037:", start)
    if k < 0:
        raise ValueError("1037's prologue does not stand in its block (no marker, no `/* 1037:` line)")
    return h.rfind(E, 0, k) + 1


def pose_atline(h, p):
    """(POSE, span_end): the prologue's span in the host, as it must be written -- its comments moved
    behind the unit's declarations (`int ZQ1; int ZQ2;`), which then close the unit.  In the tree the
    unit's braces stand where the comments end (the comments ARE the wrapped original's tail)."""
    lb = h.find(E + T + "}" + E + "}" + E, p)
    if lb < 0:
        raise ValueError("the unit's braces (a TAB `}` / `}`) do not stand behind the prologue")
    line = h[p:h.index(E, p)]                       # (the comments' first line: `/* 1037: THE TRAP FRAME...`)
    if not line.startswith(T * 5 + "/*"):
        raise ValueError("the prologue's first line is not a comment at the statement's column")
    i = h.index(E, p) + 1
    while h.startswith(T * 5 + "*", i):
        i = h.index(E, i) + 1                       # (the rest of 1037's comment block)
    return T * 5 + POSE_MARK + E + "int ZQ1;" + E + "int ZQ2;" + E, i


def build(t):
    """(text, d): the composed text, by VALUE, for either host:

        host[..w]            everything in front of 1037's statement (its comment's first line)
        O37                  the block's head -- 1037's own head line; it is the slot's switch (R16),
                             or 1039's block's head (R18: the slot's switch is 1039's `#if FC`)
        1038's slot          chunk a (statics + gate), chunk c (the carried bracket, the arm, the rows)
        C37                  the block's close
        POSE + h[u:]         the prologue marker, the unit's declarations, and the rest of 1037's statement

    R16 (--apply) takes 1037's body (h[e:p]) in front of the slot; R18 (--restage-host, after 1039's
    carrier staged) takes it behind -- 1039's block is the slot's switch there, and 1039's block head
    is the close the caller probe's text already ends with.
    """
    d = reform(t)
    h = d["host"]
    s, e = _unit_split(h)
    p = _prologue_line(h, _text_start(h))
    pz, _ = pose_atline(h, p)
    u = h.index(E + T + "}" + E + "}" + E, e) + 1
    # (R16 is recognized on the HOST -- after `reform` has dropped 1038's slot by value; 1038's own rows
    #  do not name 1039's counter, so the two can never be read for one another.)
    if "xnu_live_fcr_seq=" in h:                     # (R18: 1039's carrier is the host)
        return (h[:p] + O37 + d["slot"] + C37 + pz + h[p:u] + h[u:] + _fc_block()), d
    # R16: 1037's unit (its head pair) is the slot's switch, 1037's body h[e:p] stays in front of the
    # slot, and 1025's close -- which the tree carries at the unit's tail -- is written behind it, so the
    # slot stays INSIDE 1025's data-abort arm.  (`h[p:u]` is the WRAPPED statement: its head and the
    # slot BOTH sit at `u`, the unit's braces, so each is written alone -- once.)
    return (h[:p] + O37 + h[e:p] + d["slot"] + C37 + pz + h[p:u] + h[u:]), d


def lay(t):
    return build(t)


def restage_host(t):
    return build(t)


def _slot_of(t):
    """(s, end, slot): 1038's slot in the text as written.  The slot is the last text between 1037's
    block head (an opener whose line is immediately followed by a switch opener) and the prologue, closed
    by 1037's close; its own switch is the first switch line in it, and the carried bracket's line is the
    last.  The rows are not in it."""
    L = t.split(E)
    p = [k for k, l in enumerate(L) if l.strip() == POSE_MARK]
    if not p:
        raise ValueError("the prologue marker is not written")
    p = p[0]
    OW = "#if defined(%s) && " % SWITCH
    # (by VALUE: the head is the opener whose very next line is the switch's -- `O37` in the
    # composed slot (chunk c opens right behind it), `#if 1` in 1037's own block.  NEVER the switch's
    # own line (its close stands behind it).)
    # (s = the SWITCH's own line: the chunk markers in front of it are the slot's body, not its head.)
    heads = [k for k, l in enumerate(L)
             if k + 1 < p and (l == O37.rstrip(E) or
                               (l.startswith("#if defined(") and L[k + 1].startswith(OW)))]
    if not heads:
        raise ValueError("no block head (an opener followed by a switch opener) in front of the prologue")
    hd = heads[-1]
    s = hd + 1 if L[hd] == O37.rstrip(E) else hd + 2     # (the switch's own line: behind O37, or behind
    #   ���if 1` in 1037's own block; NEVER the chunk marker)
    end = [k for k, l in enumerate(L) if k > s and l == C37.rstrip(E)][0]
    return s, end, L[s:end + 1]


def verify(t):
    """The facts of EITHER layout, by VALUE (lines).  [] when the text is either layout:
    1038's slot (two chunks under one switch, no `#define`), the rows outside it, the block closed."""
    L = t.split(E)
    probs = []
    # (a stray `#define` of the switch is 1038's SLOT rebinding itself -- that is legal (and needed:
    #  the arm's `#if defined(SWITCH)` must see it).  What is illegal is the method: the slot rebinds it
    #  INSIDE chunk a, and the HOST carries none.)
    if sum(1 for l in L if l.strip() == POSE_MARK) != 1:
        return probs + ["the prologue marker is not written once"]
    p = [k for k, l in enumerate(L) if l.strip() == POSE_MARK][0]
    U37 = "#endif /* STAGE90_XNU_TRAP_FRAME */"
    pre_p = L[:p]
    if sum(1 for l in pre_p if l.strip() == U37) >= 6:     # (R18: the slot ends inside 1039's block)
        if not any(l.strip() == U37 for l in pre_p[-4:]):
            probs.append("1039's layout: 1039's block does not close in front of the prologue (%r)"
                         % [l.strip() for l in pre_p[-4:]])
        return probs
    s, end, slot = _slot_of(t)
    body = slot[1:-1]                                  # (the slot as LINES: _slot_of returns a list)
    d = [l for l in body if l.lstrip().startswith("#")]
    # (core = the slot's OPENERS and CHUNK closes; the switch's closes are NOT core here -- the slot
    #  has three (the arm's, TAB-indented; the rows'; the slot's own) and none may be mistaken for one
    #  another at this level.  Their ORDER is checked under the does-it-compile gate, by the preprocessor.
    def _core(l):
        return (l.strip() in (CHUNK_MARK, CHUNK_CLOSE.rstrip(E))
                or l.strip() == "#if defined(%s) && %s" % (SWITCH, SWITCH))
    core = [l for l in d if _core(l)]
    want = [CHUNK_MARK, CHUNK_CLOSE.rstrip(E), CHUNK_MARK,
            "#if defined(%s) && %s" % (SWITCH, SWITCH)]
    if [l.strip() for l in core] != want:
        return probs + ["the slot's directives are not 1038's two chunks inside one switch "
                        "(saw %r)" % d[:10]]
    # (chunk a / chunk c, the arm's carried close, and every close BELOW the slot's own: one switch
    #  whose body opens with chunk a re-emitted and whose chunk c is carried.  The STATICS are allowed
    #  to rebind the switch here -- that is how the arm compiles in exactly the chunks the tree put it
    #  in.  The HOST must carry neither the rebinding nor the stray.)
    st = [l for l in body if l.strip() == STRAY_L]
    if len(st) != 1:
        probs.append("the slot does not rebind the switch exactly once (saw %d)" % len(st))
    if STRAY_L in t[:t.index(O37)]:                    # (the HOST's own text, in front of 1037's block)
        probs.append("the switch is rebound in the host's own text")
    if body and body[0].strip() != CHUNK_MARK:
        probs.append("the slot's first line is not chunk a's marker (%r)" % body[0][:60])
    if not any(l.strip() == SW_CLOSE and l.startswith(T) for l in body):
        probs.append("the slot carries no TAB-indented arm close")
    # (the statics' own guard and define stand inside chunk a, nowhere else)
    if sum(1 for l in d if l.lstrip().startswith("#ifndef WATCH_LE_STATICS_DEFINED")) != 1:
        probs.append("the statics' guard does not stand in the slot once")
    if not any(GATE_FIRST in l for l in body):
        probs.append("the statics chunk does not carry the gate table")
    if not any(ARM_MARK in l for l in body):
        probs.append("the arm's chunk carries no arm marker")
    if not any('xnu_live_sweq_' in l and 'printf' in l for l in body):
        probs.append("the arm's chunk carries no rows")
    # (1038's gate + LE rows ARE in the slot -- chunk c, under the switch, as the tree carries them;
    # 1037's rows are NOT: they live behind 1037's block, outside it)
    if any('xnu_live_fb_pc=' in l and 'printf' in l for l in body):
        probs.append("1037's rows stand inside the switch's body")
    if not any(l.strip() == U37 for l in L[end:end + 400]):
        probs.append("1037's block is not closed behind the slot")
    if "xnu_live_fb_pc=" not in t:
        probs.append("1037's rows are absent (fb_pc: the re-staged body)")
    if 'xnu_live_wlg_need_' not in t:
        probs.append("1038's rows are absent (the gate rows left the text)")
    return probs


def status(t):
    try:
        L = t.split(E)
        if "xnu_live_fcr_seq=" in t:
            restage_host(t)
            return "R18 (staged over 1039's carrier)"
        lay(t)
        return "R16 (pre-1039 carrier text)"
    except ValueError as ex:
        return "not found: %s" % ex


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def main(argv):
    if "--selftest" in argv:
        return selftest()
    apply16 = "--apply" in argv
    apply18 = "--restage-host" in argv
    if len(argv) < 1 or (apply16 and apply18):
        print("usage: patch_d13_watch_le_rowside.py <xnu_root> [--apply|--verify|--verify-host|"
              "--restage-host] | --selftest", file=sys.stderr)
        return 2
    xnu = [a for a in argv if not a.startswith("--")][0]
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_watch_le_rowside: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    print("   trap.c : %s" % status(t))
    if "--verify" in argv or "--verify-host" in argv:
        probs = verify(t)
        for p in probs:
            print("   trap.c : PROBLEM: %s" % p)
        if probs:
            print("patch_d13_watch_le_rowside: --verify FAIL.", file=sys.stderr)
            return 1
        print("patch_d13_watch_le_rowside: --verify PASS (one switch pair under 1037's head or 1039's "
              "block; the rows behind it; no forced define).")
        return 0
    try:
        new, d = (restage_host(t) if apply18 else lay(t))
    except ValueError as ex:
        print("patch_d13_watch_le_rowside: REFUSE - %s. Writing nothing." % ex, file=sys.stderr)
        return 1
    probs = verify(new)
    if probs:
        print("patch_d13_watch_le_rowside: REFUSE - the laid-out text fails its own checks: %s. "
              "Writing nothing." % "; ".join(probs), file=sys.stderr)
        return 1
    if new == t:
        print("patch_d13_watch_le_rowside: already laid out - no-op, OK.")
        return 0
    if not (apply16 or apply18):
        print("patch_d13_watch_le_rowside: plan OK (dry run; pass --apply or --restage-host to write).")
        return 0
    write(tp, new)
    print("   trap.c : %s (%d -> %d bytes; 1038's slot behind one switch pair: the statics an archive, "
          "the arm compiled out when %s is 0; no forced define)."
          % ("host re-staged" if apply18 else "row side written into 1037's block", len(t), len(new), SWITCH))
    return 0


def selftest():
    fails = []

    def expect(c, label):
        print("   ok" if c else "   FAIL", label)
        if not c:
            fails.append(label)

    # THE HOST, in the tree's shapes (/tmp/rec1039/work5, trap.c lines 1679-1724 + 1728+):
    #   1025's arm open, 1037's bare head pair, a BODY (a raw escaped row -- the head's body, carried
    #   by 1037's --restage), a blank line, the prologue comment, `int ZQ1; int ZQ2;`, then chunk a
    #   (`#if 1`: the statics, the gate table), the STRAY define, chunk c (`#if 1`: the switch, the
    #   arm, the arm's TAB close, A BLANK LINE, the bracket's TAB close, its COLUMN-0 close, THE ROWS,
    #   chunk c's close), then 1037's close, the carrier's close and 1025's close.
    Q = chr(92) * 2                 # a backslash-backslash for the C source of a printf format
    I5 = T * 5
    statics = (CHUNK_OPEN + "#ifndef WATCH_LE_STATICS_DEFINED" + E + "#define WATCH_LE_STATICS_DEFINED 1" + E
               + "static unsigned _wl_fs[1];" + E + "#endif /* WATCH_LE_STATICS_DEFINED */" + E
               + GATE_FIRST + E + "unsigned xnu_live_wlg_lev;" + E + "unsigned xnu_live_wlg_need_seq;" + E
               + CHUNK_CLOSE)
    arm = (SW_OPEN
           + I5 + ARM_MARK + " ===== */" + E
           + I5 + 'printf(\\"xnu_live_sweq_s0=%u' + chr(92) * 2 + 'n\\", 0U);' + E
           + I5 + "#endif /* STAGE90_XNU_WATCH_LE */" + E
           + E                                # (the blank line that ends the spliced group, as in the tree)
           + T + "}" + E + "}" + E            # (the bracket's two closes: TAB, then column 0)
           + T + 'printf("xnu_live_wlg_need_le=%u' + Q + 'n", 0U);' + E    # (the rows: raw escaped text)
           + "xnu_live_wlg_need_le = 1U;" + E
           + T + "#endif /* STAGE90_XNU_WATCH_LE */" + E)
    host = ("#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE" + E
            + "#endif /* STAGE90_XNU_PC_CARRIER_CALLER */" + E     # (1036's close: the host's text anchor)
            + I5 + "/* 1037: THE TRAP FRAME (fixture) */" + E      # (the prologue's first line)
            + I5 + "* and its wrapped tail" + E                    # (the rest of the comment block)
            + E
            + I5 + 'printf(\\"xnu_live_fb_pc=%u\\\\n\\", 0U);' + E    # (1037's body: raw escaped)
            + statics + STRAY_L + E
            + CHUNK_OPEN + arm + CHUNK_CLOSE
            + O37 + C37                                            # (the bare unit: head + close)
            + I5 + "/* 1037: THE TRAP FRAME (unit) */" + E         # (1037's own text: the POSE anchor)
            + T + "}" + E + "}" + E                                # (the wrapped original's tail: the unit's braces)
            + "#endif /* STAGE90_XNU_USTACK_PROBE */" + E)
    try:
        new, _d = build(host)
        expect(verify(new) == [], "the host is composed and passes its own checks")
        # (the compose REBINDS the switch -- `#define SWITCH 1` inside chunk a, which is how 1038's
        #  arm compiles only in the chunks the tree put it in.  What must be gone is the HOST's copy,
        #  and exactly one rebinding may stand in the text.)
        expect((STRAY_L + chr(10)) not in _d["host"]
               and new.count(STRAY_L + chr(10)) == 1,
               "the host's forced define is gone; the slot rebinds the switch exactly once")
        expect(new.count(CHUNK_OPEN) == 4 and new.count(O37) >= 2,
               "the slot is 1038's two chunks; 1037's head pair is its switch")
        _i25 = new.index("#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE")
        _k = new.index(CHUNK_OPEN)
        expect(_i25 < _k, "the slot stays inside 1025's data-abort arm")
        expect(verify(host) != [], "the host itself is not a laid-out text")
        try:
            build(new)
            expect(False, "a second run is refused (already laid out)")
        except ValueError:
            expect(True, "a second run is refused (already laid out)")
    except (ValueError, ZeroDivisionError) as ex:
        expect(False, "the host is composed (%s)" % ex)
    try:
        reform(host.replace(CHUNK_OPEN, "", 1))       # one chunk: not two pairs
        expect(False, "a text without two chunk pairs is refused")
    except ValueError:
        expect(True, "a text without two chunk pairs is refused")
    print("patch_d13_watch_le_rowside: selftest %s." % ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))