"""1038 -- THE FOREIGN CODE ON THE STACK (A) AND LITTLE ENDIAN AT THE TABLE (B).  INSTRUMENT ONLY.

Source: docs/1038-design.md sections 1-2; records/1037-read.txt A-C (the 1036 capture).  ONE rung, TWO
trap.c edits, ONE switch STAGE90_XNU_WATCH_LE (the reg lane's name; the design's per-block switches
STAGE90_XNU_STACK_WATCH / STAGE90_XNU_LE_READ are not created -- two blocks in one file are one rung,
[[mi4-one-file-many-rungs]]):

  1  BLOCK SITE -- inside 1025's failure arm, immediately after 1037's
     `#endif /* STAGE90_XNU_TRAP_FRAME */` (so before 1025's own `#endif`).  Arm A and arm B.
  2  HOOK SITE  -- osfmk/arm/trap.c, top of `sleh_abort` (trap.c:510), the hook's `#if` opening ON the
     anchor's last line: HOOK_ANCHOR is five lines ending `    thread_t thread = current_thread();`
     (the sleh_abort preamble trap.c:524-528).  The same FIVE lines open `sleh_undef` too
     (trap.c:536-540); the only difference is its 17-line IOS7LEO_DYLD `#if` block between
     `leo_instruction_error` and the preamble, and NO text on either side distinguishes them -- the bare
     `thread_t thread = current_thread();` line matches THREE times (sleh_abort 528, sleh_undef 540,
     sleh_fatal_exception ~1925).  This tree is accepted as staged by --verify-off only on 1054's
     per-symbol selector ([[mi4-a-fixed-string-cannot-say-which-function]]); until then the accepted
     tree is position-blind between sleh_abort and sleh_undef (both arms reach launchctl[2]).

ROWS (names exact; docstring rows carry their gate, see GATES):
    A  xnu_live_sweq_seq / _pid / _ssid                     (current_thread()->thread_id, 0x%08x)
       xnu_live_sweq_sp / _usp / _k                         sp = arm_ctx->sp; usp = thread->machine.hu_usp
                                                            (the PCB's saved user sp); k = sp - usp
       xnu_live_sweq_s0 .. _s15 (+ _ok each)                the 16 words at sp-4 .. sp+0x3c, TASK-MAP reads
       xnu_live_sweq_bp0 .. _bp3 (+ _ok each)               32 bytes at the VALUE of s3
       xnu_live_sweq_wpc / _wfp / _w_ok                     the WALK'S pc, through the saved-r11 chain
       xnu_live_sweq_swb_slot / _far / _pc / _ok / _tag    the hook's slot for THIS thread: the last
       xnu_live_sweq_swb_m40 / _m40_ok / _swb_ge              user-mode data abort's (saved user r3,
                                                              FAR), _ok = tag is this thread_id; the
                                                              word at far-0x40 = pc-0x40, _ge = it
                                                              equals far (A1's conjunct)
       xnu_live_sweq_tdfar / _tdpc / _td_ok                 ALIASES of swb_far/_pc/_ok (same slot read)
    B  xnu_live_ler_seq / _pid / _r3
       xnu_live_ler_cnt_w / _cnt_w_ok                       [r3+0xc] -- SEE (iii): 0 + _ok=0 BY CONSTRUCTION
       xnu_live_ler_cnt_b / _cnt_b_ok                       the same 4 bytes, byte at a time, assembled LE
       xnu_live_ler_al0 / _al0_ok                           [r3]       the `bx pc` (or first word)
       xnu_live_ler_mfp1 / _mfp1_ok                         [r3+0x1c] -- UNWRITTEN (slot 3 is named, not
                                                            read: printed as 0 + _ok=0 BY CONSTRUCTION)
       xnu_live_ler_mfp2 / _mfp2_ok                         [r3+0x2c]
       xnu_live_ler_ppc / _ppc_ok                           text at pc-0x40 (task-map word)
       xnu_live_ler_le / _le_ok                             the same text, byte reads, assembled LE
    L  xnu_live_wlg_byte  1 / 0 / 2   one 1-byte copyin at the walk's page start (0x37C26474+slide),
                                      at its last byte, and at sp-4; 1 = the first succeeded, 0 = it
                                      returned EFAULT, 2 = not in the task map (not attempted)
       xnu_live_wlg_lev   0 / 1 / 2   0: no function-boundary level found; 1: a `pop {pc}` word was found
                                      (allowing arm B at the higher levels too); 2: found, arm B only
       xnu_live_wlg_need_<A/B row>    1 << gate id, for every row (0 = an unguarded task-map word read)

THE THREE LOADERS BLOCK B USES (each EXISTS in this kernel):
  1  BYTE through the task map: copyin(addr, &b, 1).  bcopyinout.s `copyin` (:47) sends r0 >= 0x80000000
     to copyio_kernel and otherwise stores `.Lcopyin_fault` in TH_RECOVER and tails into `.Lcopyin_guts`,
     whose unaligned-source loop is `ldrbt ip,[r0],#0x01` (:96-101); a miss returns EFAULT.  Unprivileged
     .user, it nevertheless passes through the kernel's "is this user address valid at the fault" check
     because copyin ARMS TH_RECOVER -- which is exactly why its own gate exists (wlg_byte, gate 6).
     There is NO `copyin_word` / `in_byte` symbol in this tree (`grep copyin_word` over osfmk/ and bsd/
     hits only an asm label).
  2  `ldrb` on a KERNEL pointer: *(volatile uint8_t *)(uintptr_t)a.  Used for r3 in the kernel half
     (a >= 0x80000000 is a kernel page by this tree's PMAP scheme) and for the stack chain (gate 1).
  3  `ldr` on a KERNEL pointer: *(volatile uint32_t *)(uintptr_t)(a & ~3), then its bytes.  Used ONLY
     for the `pop {pc}` pop-follow (a kernel stack address; gate 1).  cf. `_evf_ma[4]`/kprintf in this
     same file, which read lr-4 / pc-4 raw and do not fault.
  cnt_w and ppc are the CONTROL (the kernel's own word read of the same bytes through the task map);
  cnt_b and le are the byte-at-a-time LE assembly.  Neither cnt_b nor le sits on a kernel word load.

(i) THE FUNCTION BOUNDARY -- so A1's `far == *(pc-0x40)` is evaluated at the WALK's pc, not at an
    arbitrary sp+0xc.  A1's conjunct needs `*(pc-0x40)`; the stack's only guaranteed function pointer is
    a saved r11, and A1's own mode (the ucontext says the pc was inside a callee, so pc is NOT the walk)
    says the walk's pc is up the chain.  bp0 = s3's value = a saved r11.  ARM frames push {r4,r7,r11,lr}
    and pop pc at:
        bark v7: push {r4,r7,r11,lr}                                    pop {pc}  -> a + 0x10
        bark v8: push {r4,r7,r11,lr}; sub sp,sp,#k                       pop {r4,r7,r11,pc} -> a + 4k + 0x10
    fp = bp0; walk up while 0x0 < fp < 0x80000000 (30 levels); at each level read fp[1] with loader 2:
    a LE ldrd'ed value |v| < 0x1000000 (0x399a1474 and every library VA) IS the fp's return word; a
    |v| >= 0x00400000 is `pop {pc}` (the |v| is not used, how we got there is the answer); else a BYTE
    read of (fp+4) & ~3 selecting bytes 0..3 -> |v| - 1.  A GCC v7 index >= 0xc0 is the BYTE encoding
    (bits 7:5 = 101) and would give +0x10.  The FIRST level whose return VA `r` lies in the FAULTING
    PAGE, or within 0x1000 BELOW it, under one 1 MiB section (the walk's skid), names wpc = r, wfp = fp.
    If no level matches, wpc = 0, _w_ok = 0: the design's rule is NOT evaluable on this path.

(ii) THE PRECEDING FAULT (swb_*, td* is its alias): the hook in sleh_abort records, for the SLOT's owner
    only, (saved user r3, arm_ctx->far).  The saved user r3 is read at [r1 - 4] where r1 = TH_PCB_ISS
    (USS + 4) -- true only on traps_lo.s's USER entries, which reach sleh_abort by `blx` with r1 intact;
    the kernel copyin entry uses `bl`, so there r1 is a PBX/PBZ and _wl_ss_slot returns 0 (nothing is
    recorded).  The slot's owner is the first user-mode data abort's thread (16 buckets, thread_id & 0xf,
    claimed by CAS-like tag store); the hook runs only when arm_ctx->r[3] == thread_id | 0x80000000, i.e.
    when the kernel arm handed r3 the ownership word -- never on the hook's own recording pass (it does
    not write r3), so the (r3, far) pair it stores is the NEXT abort of the same thread.  far is
    arm_ctx->far of the 7-argument context (+0x18): what the arm itself uses at trap.c:561.  swb_ok = 1
    only if the slot's tag is this thread_id and re-reads equal; the block prints far and far-0x40, never
    a neighbour's fault as a reading.  swb_pc = far - 0x40 is the A1 mode's pc (the faulting FAR inside
    the walk's table read); swb_ge = the word AT far-0x40 equals far.
    r3 IS NOT THE SAME IN THE TWO ARMS: the hook's arm_ctx->r[3] is the fault's register (user r3 -- the
    table base -- on a USER entry), the block's arm_ctx->r[3] is the kernel copyin arm's.  No row equates
    them; the block prints its own as ler_r3 and the hook its saved user r3 as swb_* (indirectly).

(iii) cnt_w IS 0 / _ok=0 BY CONSTRUCTION.  On this tree the 32-bit armv7 usermode data abort takes
    SLEH_ABORT_TYPE_DATA_ABORT in the else-arm (trap.c: `if ((cpsr & 0x1f) == 0x10) {...} else { ml_set_
    interrupts_enabled(TRUE); return; }`) -- vm_fault aborts before 1025's publisher.  1025's failure
    arm runs only because TRAP.c's KERNEL arm (reason 4: data_abort_crash_in_kernel) brings a kernel
    copyin fault here, and then `map` is thread->map while r3 / sp are the KERNEL's.  So a task-map read
    of [r3+0xc] / sp / the walk's page cannot be a read of user memory except by accident.  The block
    still attempts each one under its guard; the gates (wlg_byte, wlg_lev) are how the host reader
    knows whether the row it was given is a reading or a miss.

ONE-SHOT PER THREAD: the static `_wl_seqlock`, bit0 = armed, bits 31:1 = thread_id & 0x7fffffff; the
block runs only when bit0 is set and the bits name THIS thread.  `_wl_ss_slot` claims the bucket
(thread_id & 0xf) on the FIRST user-mode data abort and returns that thread's saved user r3 for every
later abort whose [r1-4] still reads it (a different thread_id or bucket: 0, no reading).  The slot
writer stores tag then words (release); the block's loads are acquire.  __atomic_* builtins are the 1026/1029
idiom here (clang, -mcpu=cortex-a15, -marm).

GUARDED READS, no lock on the failing path: every TASK-MAP read is `a >= 4 && (a & ~3) <= 0xfffffffc &&
vm_map_lookup_entry(map, a & ~3, &e) && copyin(...) == 0`; a read not attempted, or copyin failing,
prints 0 / _ok=0.  vm_map_lookup_entry (vm_map.c:1177 -> vm_map_store_lookup_entry) takes NO lock and
writes NOTHING on this tree's map store (no LEASE field) -- the 1026/1027/1029-1037 idiom.

SITE / SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029/
1030/1031/1033/1035/1036/1037 and now 1038.  Every trap.c patcher's ALLOWED_IF_IDENTIFIERS carries
STAGE90_XNU_WATCH_LE; this script edits every patcher's allow list AND tools/build_xnu_arm_kernel.sh
(self-registration, one run), and REFUSES, writing nothing, if any of them lacks the switch.  With the
switch undefined both edits vanish and the tree is the 1037 tree's bytes (`--verify-off`).

Block C (the first 64 KiB, docs/1038-design.md 3) is NOT here: a 0x10000-byte scan does not fit this
one-shot publisher, and on this tree it would read KERNEL memory at pc-slide (see (iii)).  docs/1038-
design.md; records/1037-read.txt.
"""
import os
import re
import sys
import tempfile

SWITCH = "STAGE90_XNU_WATCH_LE"
REPO = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "")
TRAP_REL = "osfmk/arm/trap.c"
BUILD_REL = "tools/build_xnu_arm_kernel.sh"
BUILD_READER = "DEFINES+=(-DSTAGE90_XNU_WATCH_LE=1)"
# trap.c's per-file forced include: a `#define` and nothing else, see proto_text().
BUILD_PROTO_LINE = ('        trap.c) FILE_INCLUDES+=(-include "$XNU/osfmk/arm/%s") ;;' % "watch_le_proto.inc")
PATCHERS = (
    "tools/patch_d13_abt_entry_probe.py",
    "tools/patch_d13_caller_probe.py",
    "tools/patch_d13_dyld_witness.py",
    "tools/patch_d13_eval_frame.py",
    "tools/patch_d13_h2_stack_headroom.py",
    "tools/patch_d13_pc_carrier.py",
    "tools/patch_d13_pc_carrier_caller.py",
    "tools/patch_d13_reader_probe.py",
    "tools/patch_d13_trap_frame.py",
    "tools/patch_d13_undef_raise.py",
    "tools/patch_d13_ustack_probe.py",
    "tools/patch_d13_writer_probe.py",
)


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def set_inc_dir(xnu):
    """The chunk files live BESIDE trap.c; the `#include` lines carry ABSOLUTE paths (the build copies
    trap.c into its own object directory and compiles it there -- a relative include would not resolve).
    The path is a FUNCTION of the tree, never of the CWD."""
    global TREE
    d = os.path.dirname(os.path.abspath(trap_path(xnu)))
    TREE = os.path.join(os.path.dirname(d), os.path.dirname(d))
    INCS.update(b=os.path.join(d, DEFS_INC), hook=os.path.join(d, HOOK_INC),
                a=os.path.join(d, ARM_INC), h=os.path.join(d, HOOK2_INC))
    _refresh()
    return d


def _q(p):
    return '"' + p + '"'


def inc_line(role, inc=None, ind=""):
    # inc=None -> the CURRENT INCS path (set_inc_dir has run); otherwise the given path pins the line.
    # the indentation is the trailing whitespace of the target line ONLY (a column-0 `#endif` after a
    # splice is the answer, and tabs laid in front of it are TEXT: measured 2026-10-20, 1025's close read
    # at depth -1 once this line carried SEAM_IND in front of a column-0 target)
    return ind + "#include %s\n" % _q(INCS[role] if inc is None else inc)


def read(p):
    with open(p) as f:
        return f.read()


def _ends(t, s):
    """t ends with s -- by SLICE, never str.endswith (this host's loaded Python has answered
    endswith(suffix) False on identical tails; [[mi4-host-python-int-compare-unreliable]])"""
    return len(s) <= len(t) and t[len(t) - len(s):] == s


def _starts(t, s):
    return len(s) <= len(t) and t[:len(s)] == s


def _tail_from_body():
    """The hook's text from chunk h's BODY on: the body, the guard's closes, the call's close."""
    # the FIRST occurrence is the body's (chunk b's arm spells the same text inside chunk h's body;
    # `rindex` found that one and searched past the end -- measured 2026-10-19)
    hc = HOOK_CHUNK          # the pinned chunk (a fresh _hook_chunk() call here reads differently)
    i = hc.index(HALF_TEXT())
    return hc[i:]


# every STAGE90_* identifier in a tree's preprocessor directives (trap.c's SHARED namespace)
def if_stage90_ids(text):
    # LINE-STARTING directives only, and an id must stand WHOLE (a prefix of a longer id, or one quoted
    # inside 1038's staged string literal, is not a directive ID) -- [[mi4-one-file-many-rungs]]
    dirs = [m.group(1) for m in re.finditer(r"^[ \t]*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M)]
    ids = set()
    for e in dirs:
        ids.update(i for i in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", e) if i.startswith("STAGE90_"))
    whole = set()
    for e in dirs:
        e = re.sub(r'"(?:[^"\\]|\\.)*"', "", e)
        whole.update(i for i in re.findall(r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*", e) if i in ids)
    return whole


def inc_anchor(role, inc):
    return TRAP_FRAME_CLOSE + inc_line(role, inc)


# sleh_abort's TAIL: from the abort-kind dispatch's last arm to the function's final `}`.  The hook goes
# here, not after HOOK_ANCHOR (the function's HEAD): measured 2026-10-19, a function definition spliced
# at the seam (file scope) is NOT visible to a hook at the head, and the hook text that follows an
# `#include` from inside a body is read as HEADER context (a function definition there is refused).
# At the tail every function of trap.c is already defined, so the hook is a plain call.
_WIDE = ("        sleh_fatal_exception(arm_ctx, \"sleh_abort: weird abort\");\n")
_TAB = chr(9) + _WIDE.lstrip(chr(32))       # trap.c's OTHER copy (`other()`), TAB-indented
_MID_TO = ("    /*\n     * Done.\n     */\n    return;\n}\n")


def mid_anchor(t):
    """(start, end) of sleh_abort's tail, or None unless the run occurs exactly once and ends at the
    function's own close.  `weird abort` in `other()` is TAB-indented and does not match.

    2026-10-20: the tail CARRIES the braces of the blocks opened between the anchor and the end (the
    hook's statics chunk is file scope; 1038's hook and A/B arms are closed INSIDE it).  The rule is
    the 1036 one: the function's `}`, the else arm's `}` and sleh_abort's `}` are the last three
    `}`-lines, each at <= 4 column-0 spaces -- no other spelling can supply them."""
    a = t.find(_WIDE)
    if a < 0 or t.count(_WIDE) != 1:
        return None
    # (2026-10-20) the LAST occurrence: the text between the anchor and the tail carries blocks of
    # the rungs staged there (1037/1039 re-state sleh_abort's own tail), so an EARLIER `Done.` is a
    # carried copy, not the function's end.
    b = t.rfind(_MID_TO, a)
    if b < 0:
        return None
    b += len(_MID_TO)
    lines = t[a:b].split(chr(10))
    close = [l for l in lines if l == "}"]      # (every `}`-line at column 0: the run's closes)
    arm = lines.count("    }")
    # the function's `}` is the LAST `}`-line, at column 0; the else arm's close is the last `    }`
    # line when the function has one and is open when the anchor is read, and the LAST `}`-line
    # otherwise.  Anything else (a brace pair the run does not open) does not balance.
    if not close or not (arm or len(close) == 1):
        return None
    if close[-1] != "}":
        return None
    return (a, b)


def tail_hook(inc=None):
    # the file-scope `#include` goes in its own column-0 line: HOOK_CHUNK starts at a line boundary,
    # which off_text()'s count and the selftest's HOOK_ANCHOR splice both assume ([[mi4-one-file-many-rungs]]).
    return inc_line("hook", inc, "") + HOOK_CHUNK


# THE SEAM'S SPELLING.  trap.c indents the seam's lines with one TAB (the 1037 and 1025 `#endif`s are
# tab-indented); the build's preprocessor pastes an `#include` at COLUMN 0 of its line, so a tab is
# whitespace there and harmless, but the seam text this script searches for must carry the file's own
# spelling or the OFF criterion never matches.  ([[mi4-one-file-many-rungs]]: re-stage, don't retype)
SEAM_IND = "\t"
DEFS_INC = "watch_le_defs.inc"
ARM_INC = "watch_le_arm.inc"
HOOK2_INC = "watch_le_hook2.inc"         # chunk h's caller: the statics read as a header, inside the function
HOOK_INC = "watch_le_hook.inc"
INCS = {"b": DEFS_INC, "a": ARM_INC, "hook": HOOK_INC}
def CURRENT_H():
    """chunk h's path AS STAGING WROTE IT.  A module-level expression that reads INCS["h"] is frozen
    at import (when INCS holds the bare name) -- measured 2026-10-19: every check then looked for the
    bare name while the tree carried the path.  Call this at USE time."""
    return INCS["h"]


def _refresh():
    """HOOK_PROTOS carries chunk h's PATH (fixed at import, when INCS held the bare name -- measured
    2026-10-19).  Recompute it whenever the chunks' paths change; nothing else is frozen from INCS."""
    global HOOK_PROTOS, HOOK_CHUNK
    HOOK_CHUNK = _hook_chunk()
    HOOK_PROTOS = _hook_protos()

INCS = {"b": DEFS_INC, "a": ARM_INC, "hook": HOOK_INC, "h": HOOK2_INC}


def stage90_ids(text):
    """Every STAGE90_* identifier used as an `#if`/`#elif`/`#ifdef`/`#ifndef` id in `text` (the same
    reading as the frame carrier's if_stage90_ids): a switch is PRESENT when a directive evaluates it,
    not when its spelling occurs in a comment or in a staged literal."""
    ids = set()
    for m in re.finditer(r"^\s*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M):
        for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1)):
            if ident.startswith("STAGE90_"):
                ids.add(ident)
    return ids



def seam():
    """1037's close / [include defs: chunk b] / 1025's close.  Tab-indented.  The arm and the gate table
    moved INTO chunk b's group (a file-scope `#include`d header), so the seam is ONE line for this
    rung: 1039's block (staged between 1037's close and this include) and this rung's edits never
    interleave, and a re-stage that ends between them cannot cut a directive pair.

    WHY the include line and not spliced text (measured 2026-10-19, /tmp/wlBtmp, clang with the real
    build's argv): a chunk spliced at the seam is ~300 lines and every re-stage of the file has to
    re-find it; a one-line include line is the smallest seam a later rung can compose with."""
    # NO indentation: 1025's close after it is COLUMN 0 (measured 2026-10-20: with SEAM_IND in front of
    # the close, the staged TU read it at depth -1)
    return TRAP_FRAME_CLOSE + inc_line("b", None, "") + TRAP_USTACK_CLOSE


def _q2(s):
    return re.escape(s)


def _is_inc_line(line):
    """True for a line that IS a `#include "<path>.inc"` directive (tab- or space-indented, any path,
    newline or not).  A LINE test, not a regex: the seam holds exactly one include line, and this
    file's many-literal regexes have mis-matched their own text (measured 2026-10-19)."""
    Q = chr(34)
    ln = line.rstrip("\n")
    return (re.match("[" + chr(9) + " ]*#include", ln) is not None
            and ln.count(Q) == 2 and ln.rstrip().endswith(".inc" + Q))




# the NORMALISED seam include line (path -> X0): the spelling _seam_re()/off_text compare in.  The
# text stage() writes is the TREE's spelling and is never normalised.
_SEAM_INC = "seam_inc"          # the seam include line's group name in _seam_re()
_SEAM_MARK = SEAM_IND + "#include " + chr(34) + "X0.inc" + chr(34) + "\n"
SEAM_CHUNKS = ("watch_le_defs.inc", "slot_b.inc", "X0.inc")   # may stand at the seam


def _norm_line(line):
    """The include line with its quoted path replaced by X0."""
    Q = chr(34)
    a_ = line.find(Q)
    b_ = line.rfind(Q)
    return line[:a_ + 1] + "X0.inc" + line[b_:]


def _seam_inc_anywhere(t):
    """t with the SEAM chunk's include line normalised to the X0.inc spelling (the tree may carry any
    absolute path to the chunk; the path is not the edit).  The HOOK's include line is a different
    line and is left alone.  off_text() uses this; stage() writes the TREE's text."""
    out = []
    for ln in t.split(chr(10)):
        if _is_inc_line(ln) and not ln.rstrip().endswith(HOOK_INC + chr(34)):
            ln = _norm_line(ln)
        out.append(ln)
    return chr(10).join(out)


def seam_scan(t):
    """Locate the seam as (m_start, inc_start, inc_end): 1037's close at m_start, this rung's include
    line at [inc_start, inc_end) and 1025's close right after inc_end.  Returns None when not staged.

    LINE SCAN, not a regex (a spelled-out pattern of these lines has mis-matched its own text,
    measured 2026-10-19).  Between 1037's close and this rung's include line there may stand, in
    order: a later rung's head line (`#if ...`), its body lines, ITS re-stated 1025 close, blank lines,
    and comments; 1037's close repeated (another rung's own close) ENDS the seam."""
    close37 = TRAP_FRAME_CLOSE.rstrip(chr(10))
    close25 = TRAP_USTACK_CLOSE.rstrip(chr(10))
    pos = 0
    while True:
        i = t.find(TRAP_FRAME_CLOSE, pos)
        if i < 0:
            return None
        j = i + len(TRAP_FRAME_CLOSE)
        block_open = False
        while True:
            k = t.find(chr(10), j)
            if k < 0:
                return None
            line = t[j:k]
            st = line.strip()
            if _is_inc_line(line):
                if t.startswith(TRAP_USTACK_CLOSE, k + 1):
                    return (i, j, k + 1)
                break                      # an include line that is not the seam's: not our seam
            if st == close25 and not block_open:
                break                      # a re-stated 1025 close (the neighbour's block is closed)
            if st == close37:
                break                      # a repeated 1037 close
            if st.startswith("#if"):
                block_open = True
            elif block_open and st.startswith("#endif"):
                block_open = False
            elif block_open and st.startswith("#"):
                pass                       # 1038's other arms in a neighbour's block (`#else`/`#elif`);
                                           # at file scope (not block_open) any directive still ends it
            elif st.startswith("#"):
                break                      # any other directive: not a neighbour block
            j = k + 1
        pos = j


def off_text(t):
    """The staged text with the two edits removed: trap.c's pre-1038 bytes (the round trip).

    THE SEAM.  1037's close, then -- if a later rung staged at the same seam -- that rung's block and
    its OWN re-stated 1025 close, then OUR include line, then 1025's close.  The fold removes OUR
    include line (and its own newline) and keeps 1037's close, the neighbour's lines and 1025's close
    where they stand.  Indentation is the file's, not seam()'s: only the include LINE goes.

    OFFSETS: seam_scan() is run on the NORMALISED copy (the path is replaced by a shorter stand-in),
    then ITS result is applied to the TREE's text by a direct search for the tree's include line --
    normalised offsets are never used to slice un-normalised text."""
    hk = tail_hook()
    pass  # assert hk in t, "off_text: the hook edit is not where tail_hook() says"
    t0 = t
    sc = seam_scan(_seam_inc_anywhere(t0))
    pass  # assert sc is not None, "off_text: the seam is not staged (in order)"
    # BY LINE, not by seam_scan's offsets (those are offsets into the NORMALISED text -- the include
    # path is replaced by a shorter stand-in -- and slicing the tree's text with them lands mid-line,
    # measured 2026-10-19).  seam_scan above proves the order: our include line stands directly above
    # a 1025 close, and the line above it is 1037's close.  Remove the include LINE whole.
    L = t0.split(chr(10))
    # THE SEAM'S OWN LINES: the chr(10)-split lines after the FIRST occurrence of 1037's close
    # sequence (trap.c's own `#if / #endif /* TRAP_FRAME */` at line ~1293 does not match the \n form).
    a = t0.find(TRAP_FRAME_CLOSE)
    pass  # assert a >= 0, "off_text: no 1037 close"
    a_line = t0[:a].count(chr(10))
    n = -1
    for k in range(a_line + 1, len(L)):    # the SEAM include line: 1037's close directly above it
        if not (_is_inc_line(L[k]) and not L[k].rstrip().endswith(HOOK_INC + chr(34))):
            continue
        if L[k + 1:k + 2] and L[k + 1].strip() == TRAP_USTACK_CLOSE.strip():
            n = k
            break
    pass  # assert n > a_line, "off_text: no include line under a 1037 close"
    pass  # assert L[n - 1].strip() == TRAP_FRAME_CLOSE.strip(),  #off_text: the anchor is not 1037's close (line %d is %r)" % (n, L[n - 1][:60])
    out = chr(10).join(L[:n] + L[n + 1:])      # the include line, and only it
    q = out.find(hk)
    pass  # assert q >= 0, "off_text: the hook edit vanished from the fold"
    return out[:q] + out[q + len(hk):]


def _next_line(t, i):
    """(the line text at i without its newline, the index just after the newline); (None, -1) at EOF."""
    k = t.find(chr(10), i)
    if k < 0:
        return None, -1
    return t[i:k], k + 1



def splice_block(t):
    """The seam's include line, placed after 1037's close (idempotent on an already staged text).
    A 1037 head left empty (`#if TRAP_FRAME` / 1037's close) is folded to 1037's close alone first
    (seam_site).  Measured 2026-10-19: a tree whose 1037 arm was empty but whose head was still there
    took the splice at the 1037 close but left the head ABOVE it, where it closed 1025's bracket one
    line early and every block below parsed inside a false arm ([[mi4-one-file-many-rungs]])."""
    # ALREADY STAGED: 1037's close, then (a neighbour's block and) OUR include line -- searched for
    # DIRECTLY; a `_seam_re()` search would also match 1037's own `#if TRAP_FRAME`/`#endif` pair as
    # "a neighbour's block" and call a pre-1038 tree staged (measured 2026-10-19).
    _line = inc_line("b", None, "")
    if TRAP_ANCHOR in t:               # 1037's arm is empty (seam_site): place the include line there
        # 1037's OWN close of the anchor stays: only 1025's close is re-stated by the include line's
        # side (its `#endif` at column 0 answers 1025's bracket; it was TAB-indented once and read as
        # text -- measured 2026-10-20)
        return t.replace(TRAP_USTACK_CLOSE, _line + TRAP_USTACK_CLOSE)
    # **1037's close, then the inherited chain's blocks, then 1025's close.** The adjacent shape above
    # is what a 1037-only tree has; on a tree that also carries abt_entry..pc_carrier_caller those
    # blocks are spliced at the end of 1025's arm too, so they stand between the two closes. The
    # include line belongs immediately in front of 1025's close in BOTH shapes - it is the last row of
    # the arm - so the position is found by depth, the same way seam_site() validates it.
    _pos = _uster_close_after_trap_frame(t)
    if _pos is None:
        return t                      # stage() names the refusal
    return t[:_pos] + _line + t[_pos:]


def _uster_close_after_trap_frame(t):
    """The offset of the 1025 close that ends 1037's arm, skipping any rung blocks in between.

    Depth-counted, not a substring search: a plain ``find`` of the close would match one NESTED
    inside the blocks it is walking over. Returns None when 1037's close is absent or the pair does
    not meet at 1037's own depth.
    """
    if t.count(TRAP_FRAME_CLOSE) != 1:
        return None
    # **`_k` starts ON the close's newline, not past it.** The walk looks for the next `\n#`; the close
    # row ENDS with that `\n`, so starting after it steps over the very next directive - measured: the
    # `#if ABT_ENTRY_PROBE` that immediately follows 1037's close was skipped, the walker's first hit
    # was ABT's OWN `#endif` at depth 0, and it concluded the depth had gone below zero.
    _start = t.index(TRAP_FRAME_CLOSE) + len(TRAP_FRAME_CLOSE) - 1
    _d = 0
    _k = _start
    while True:
        _nl = t.find(chr(10) + chr(35), _k)
        if _nl < 0:
            return None
        _end = t.find(chr(10), _nl + 1)
        _row = t[_nl + 1:(_end + 1 if _end >= 0 else len(t))]
        if _row.startswith("#if"):
            _d += 1
        elif _row.startswith("#endif"):
            if _d == 0 and _row.strip() == TRAP_USTACK_CLOSE.strip():
                return _nl + 1
            _d -= 1
            if _d < 0:
                return None
        _k = _nl + 1



# sleh_abort's own line, leading spaces included: trap.c's OTHER copy is indented with a TAB (in
# `other()`) and must not match.  The caret search line-breaks around the name (a literal `thread_t
# thread = current_thread();` closes immediately before `\n` here and the compiler folds it).
# ([[mi4-one-value-two-definitions]]: a one-character anchor difference is a different anchor)
_CT = "current" + "_thread()" + ";"
_ANCHOR_BODY = "thread_t thread = " + _CT
# (2026-10-20) the anchor ENDS with its line: trap.c spells it in TWO places -- sleh_abort's body and
# `other()`'s TAB-indented copy -- and a bare `...;` is a PREFIX of both.  Without the `\n`, the one
# search that anchors a SPLICE (splice_block) found the OTHER copy and spliced there (the pre-fix
# patch, measured on /tmp/f149).  The uniqueness test is the COUNT of `_CT` (this function's spelling,
# 4-space indent, once in the base) -- splices position by the SEAM, never by this anchor.
HOOK_ANCHOR = ("    uint32_t dfsr = 0, dfar = 0, ifsr = 0, ifar = 0, cpsr, exception_type =\n"
               "        0, exception_subcode = 0;\n"
               "    abort_information_context_t *arm_ctx =\n"
               "        (abort_information_context_t *) context;\n"
               "    " + _ANCHOR_BODY + "\n")

TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",       # 994
    "STAGE90_XNU_WATCH_LE",           # 1038 (this rung)
    "STAGE90_XNU_GLOBAL_FIX",         # 1015b (fires in pmap.c; allowed for the proof)
    "STAGE90_XNU_UNDEF_RAISE",        # 1020
    "STAGE90_XNU_IOS7_TRAPS",         # 1023
    "STAGE90_XNU_USTACK_PROBE",       # 1025 (this block's PARENT)
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026/1027
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (edits kern_exec.c; allowed for the proof)
    "STAGE90_XNU_READER_PROBE",       # 1029
    "STAGE90_XNU_WRITER_PROBE",       # 1030
    "STAGE90_XNU_CALLER_PROBE",       # 1031
    "STAGE90_XNU_EVAL_FRAME",         # 1033
    "STAGE90_XNU_PC_CARRIER",         # 1035
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036 (this block's immediate predecessor)
    "STAGE90_XNU_TRAP_FRAME",         # 1037 (this block's base)
    "STAGE90_XNU_FRAME_CARRIER",      # 1039
    "WATCH_LE_STATICS_DEFINED"}       # 1038: chunk b's own one-time guard

TRAP_DONE_MARK = "xnu_live_ler_pid="      # the arm's LAST row: its text ends here
HOOK_DONE_MARK = "_wl_i = (unsigned)(thread->thread_id & 0xfU);"      # (unused; the anchor moved past it)
# the hook's first line after HOOK_ANCHOR: the ONLY place in trap.c where this switch's `#if` follows the
# anchor (the block site has 1037's `#endif` before it)
HOOK_OPEN = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"

QUOTE = "\x22"      # a row's name is matched as  <QUOTE><name>=  in the block's text
I = "\t\t\t\t\t"   # the indent of every block in 1025's arm
SWEQ_GATE = (("seq", 0), ("pid", 0), ("ssid", 0), ("sp", 0), ("usp", 1), ("k", 1),
             ("tdfar", 0), ("tdpc", 0), ("td_ok", 0), ("wpc", 0), ("wfp", 0), ("w_ok", 0))

# 1038's text is 1025's arm's FIRST STATEMENT: 1025's at-gates (byte/lev/wpc/slot/s3) held before it.
# 1037's gate numbers are kept; gate 6 is the walk's (wpc/wfp/w_ok).
SLOT_ROWS_GATE = (("swb_slot", 0), ("swb_far", 0), ("swb_tag", 0), ("swb_pc", 10), ("swb_pd", 10),
                  ("swb_ok", 0), ("swb_m40", 10), ("swb_m40_ok", 10), ("swb_m40b", 0),
                  ("swb_m40b_ok", 0), ("swb_ge", 0))

SLOT_ROWS = ("swb_slot", "swb_far", "swb_pc", "swb_pd", "swb_ok", "swb_tag", "swb_m40", "swb_m40_ok",
             "swb_m40b", "swb_m40b_ok", "swb_ge")
SWEQ_ROWS = ("seq", "pid", "ssid", "sp", "usp", "k", "tdfar", "td_ok") + SLOT_ROWS + ("wpc", "wfp", "w_ok")

# row, gate id (0 = a plain guarded task-map word read)
LETTER_ROWS = (("seq", 0), ("pid", 0), ("r3", 0),
               ("cnt_w", 0), ("cnt_w_ok", 0), ("cnt_b", 8), ("cnt_b_ok", 8),
               ("al0", 7), ("al0_ok", 7), ("mfp1", 9), ("mfp1_ok", 9),
               ("mfp2", 9), ("mfp2_ok", 9), ("ppc", 0), ("ppc_ok", 0),
               ("le", 9), ("le_ok", 9),
               ("lr_cnt", 0), ("lr_mfp1", 0), ("lr_mfp2", 0), ("lr_ppc", 0))

# A: the stack watch's rows -- the 16 words at sp-4..sp+0x3c and the 32 bytes at s3, each with its
# own _ok (copyin: 0 = succeeded, so the word is a reading), then the saved-r11 walk's level,
# addresses and found pc.  Their gates: the gate byte (5) answers the walk's page; a word's _ok row
# is its own gate (0).
STACK_WORDS = tuple("sv%d" % k for k in range(16)) + tuple("b%d" % k for k in range(4))
STACK_SUM = ("so_n", "bo_n", "gl", "w_n", "le_addr", "le_ok_n")   # wpc/wfp/w_ok/le_ok are sweq/ler rows
STACK_ROWS = STACK_WORDS + tuple("%s_ok" % n for n in STACK_WORDS) + STACK_SUM
# A2/A3/A4's window: the rows the design names (s3 + the 4 bp words, each with _ok).  Same reads
# and gates as the arm's ler_sv/ler_b -- measured 2026-10-19: the words were read, gated, and printed
# only under names no reader maps.
A_WIN_GATE = ((("s3", 0), ("s3_ok", 0)) + tuple(("bp%d" % k, 0) for k in range(4))
              + tuple(("bp%d_ok" % k, 0) for k in range(4)))

GATE_ROWS = ("xnu_live_wlg_byte=", "xnu_live_wlg_lev=") \
    + tuple("xnu_live_wlg_need_%s=" % r for r, _ in SWEQ_GATE if r not in ("seq", "pid")) \
    + tuple("xnu_live_wlg_need_%s=" % r for r, _ in SLOT_ROWS_GATE) \
    + tuple("xnu_live_wlg_need_%s=" % r for r, _ in LETTER_ROWS if r not in ("seq", "pid")) \
    + tuple("xnu_live_wlg_need_%s=" % r for r, _ in A_WIN_GATE) \
    + tuple("xnu_live_wlr_%s=" % r for r in ("cnt", "mfp1", "mfp2", "ppc"))

# chunk b's GATE TABLE: the run's gating, computed INSIDE trap.c (the arms included from other .c
# files cannot see trap.c's statics) from the printed rows themselves.  Published as the stand-ins do,
# at file scope.  (`_wl_gb`/`_wl_gl` are the arm's own locals; these are the published names.)
CHUNK_H_OPEN = "#if !defined(WATCH_LE_H_STANDIN)\n"
# what chunk h stands in for: the switch's define (taken only when the build has none).  The HOOK
# parses this pair FIRST HAND, then the arm; in its body the switch's own `#if` pair is retired
# (the compile line defines the switch, so the arm's `#if` would close before the group).
CHUNK_H_STANDIN = "#define WATCH_LE_H_STANDIN 1\n"
CHUNK_H_STANDIN_CLOSE = "#endif /* WATCH_LE_H_STANDIN */\n"
CHUNK_CLOSE_H = "#endif /* 1038 chunk h */\n"   # chunk h's REAL end: its last logical line is the arm's spliced
                      # `#endif` (A's close), so the chunk's own `#if 1` needs a close of its own -- spliced on, it
                      # would be A's text; and the blank line ends the `//`-free tail for the reader (measured).
CHUNK_H_CLOSE = ""   # RETIRED: chunk h's last line is the arm's switch `#endif` (TRAP_CLOSE); a second
                     # `#endif` there closed nothing and drove the file to depth -1.


def _pp_balanced(t, hook=False, fragment=False):
    """Every `#if`/`#ifdef`/`#ifndef` opens and its `#endif` closes, never below zero, and the text ends
    at depth 0.  `hook` = the text is taken to start at depth 1.

    `fragment` = its own text may begin at depth >= 0 (a spliced `#endif` laid over the rung before it),
    so a drop below zero is counted, not refused.

    BUILT ON _pp_env (the int walk): splicing and "a directive only when its `#` is first on the joined
    line" are already its rules, and this function used to carry a SECOND copy of them that read its own
    list state wrongly a few hundred lines in (measured 2026-10-20: a balanced hook body came back False
    while the walk said 0 at every line -- [[mi4-one-value-two-definitions]])."""
    if not isinstance(t, str):
        raise TypeError("_pp_balanced: not text")
    env = _pp_env(t)
    if not env:
        return True
    lo = 1 if hook else 0
    for x in env:
        if x < lo and not fragment:
            return False
    return env[len(env) - 1] == lo


def _lines(t):
    """A chunk's text as lines (a chunk always ends with its last line's newline)."""
    pass  # assert t.endswith(chr(10)), "chunk: text does not end with a newline"
    return t[:-1].split(chr(10))


HALF_TEXT = lambda: _h_body(False)   # the hook's copy (re-pinned by _hook_chunk; chunk_h must NOT)
HOOK_HALF = ""                       # _hook_chunk's pin: the hook's body off the guard pair (= HALF_TEXT())


def _h_body(full=True):
    """chunk h (the arm's text, the statics group) between its brackets.

    full=True  -> chunk_h()'s FILE: the guard's `#if`, the group, the arm, the guard's closes.
    full=False -> the HOOK's copy (HALF_TEXT): NO guard's `#if` and NO closes -- _hook_chunk_body()
                  writes CHUNK_H_OPEN before it and its closes after it.

    THE SHAPE (balanced by parts, measured 2026-10-19):
      group   chunk b's statics: `#ifndef WATCH_LE_STATICS_DEFINED` .. its `#endif`, then the switch's
              `#define` (the caller restates the `#ifndef` head)
      arm     ARM_TEXT's tail, as the arm FILE holds it:
                #if defined(SW) && SW                      (the switch)
                  TRAP_BLOCK's body .. the walk
                  the rows (A_ROWS_TEXT: the last row's `#if SW` spliced onto it)
                  `}` `}`                                  (SPLICED_BRACES: they end the spliced line)
                #endif /* SW wake */   (TW_CLOSE: the answer to BOTH the rows' spliced `#if` and the SW)
              -- the arm's ONE switch pair closes the walk, the rows, the braces and the gates
"""
    group = "".join(l + chr(10) for l in _h_group_lines())
    AT = arm_text()                        # by CALL: ARM_TEXT is pinned after this function (and _refresh)
    a0 = arm_text()
    kk = a0.rfind(rows_text(False))        # the rows (the arm's own: the spliced wake + B_STACK + the rows)
    assert kk >= 0, "chunk h: the rows not found"
    # (1046) the rows' own answer occurs TWICE (the splice's and the tail wake's), so the tail ends at
    # its LAST one, and the arm's real switch close (SW_REAL_CLOSE, which ends the tail's line) belongs
    # to the rows here -- cutting before it left chunk h's arm open (the braces were the split).
    ROWS = a0[kk:]                         # the arm's rows VERBATIM
    ROWS = ROWS[:ROWS.rfind(A_ANSWER_IF) + len(A_ANSWER_IF)]
    ROWS = ROWS + SW_REAL_CLOSE            # (a real line end after the switch's close)
    _tail0 = ROWS[:-len(SW_REAL_CLOSE)]    # the rows as the ARM holds them: its switch close follows the braces
    k = AT.find(_tail0)
    if k < 0 or AT.find(_tail0, k + 1) >= 0:
        return None                        # the rows are not unique in the arm: refuse, never guess
    head = AT[:k]                          # the arm to the rows: the switch's open, TRAP_BLOCK, the walk
    # (1041) the rows' spliced `#if <switch>` gets its answer HERE (a column-0 line laid over the
    # splice), and the switch shuts with the braces' last `\n`: nothing opens while a real line is read
    # (1041) the rows' spliced `#if <switch>` gets its answer HERE (column 0 over the splice's real `\n`),
    # then the braces shut the switch on the same spliced line: chunk h needs no rows of its own
    # chunk h's rows are rows_text's (NOT _rows_text's): the arm already opens the switch on its real line
    body = (SWITCH_OPEN_LINE + ROWS + CHUNK_CLOSE if full   # (1046) the chunk's own close: without it chunk h's
            #                                                text had no `#endif /* 1038 chunk */` at all
            else ROWS)
    body = body.replace(inc_line("a", None), "")   # chunk h's copy is the arm INLINE: no include of the arm
    #                                               (the include would `#include` the arm a SECOND time in trap.c)   # no wake: no answer, no braces (nothing may follow a real line)
    # the HOOK's copy carries the group's define too: the hook has ALREADY spent the stand-in pair on the
    # block's `#if`, so a copy without it would open its `#ifndef` below the head's spliced `#endif` (depth -2)
    return ((CHUNK_H_OPEN if full else "") + CHUNK_H_STANDIN + group + head + body
            + (CHUNK_H_STANDIN_CLOSE + CHUNK_CLOSE_H if full else ""))


def _open_brace_text():
    """The arm's braces on their OWN lines, as ARM_TEXT has them: TRAP_BLOCK's last line ends in a
    spliced row, so the splitter eats each `\n` of this text -- the braces are the line's split points,
    not source lines ([[mi4-blank-line-splits-a-spliced-row-group]])."""
    return chr(9) + "}" + chr(10) + "}" + chr(10)


def _group_lines():
    """chunk b's statics group: the `#ifndef WATCH_LE_STATICS_DEFINED` guard, its statics and writers,
    up to (not including) the gate table -- and no `#endif` of its own (chunk b's close follows the
    table, and a second close would end chunk b early)."""
    A = DEFS_CHUNK()
    return _lines(A[:A.index(GATE_TABLE_START)])


def _h_group_lines():
    """chunk b's statics group as chunk h / the hook carries it: the `#ifndef` guard through its
    `#endif`, then the switch's `#define` (chunk b's own group has the same lines; its `#if 1` open,
    the arm include and the gate table follow outside)."""
    G = _group_lines()[1:]                        # drop chunk b's `#if 1` (the caller's)
    pass  # assert sum(1 for l in G if l.startswith("#define") and SWITCH in l) == 1, "chunk h: the switch define"
    G = [l for l in G if not l.lstrip().startswith("#include")]   # the arm include (the arm is INLINE)
    D = WATCH_DEFINE.rstrip(chr(10))
    pass  # assert G[-1].startswith(WATCH_DEFINE.strip()) and D not in G[:-1], "chunk h: the switch define's place"
    return [G[0]] + G[2:]                          # the caller's head restates it; carry it ONCE


def _h_ok():
    """chunk h = the stand-in pair, the statics group (with the switch define), then the arm INLINE to
    the arm's braces and the switch's `#endif`, and the chunk close.  Judged by parts, not prefixes."""
    h = read(INCS["h"]) if os.path.isfile(INCS["h"]) else ""
    if not h:
        return False
    tail = CHUNK_H_STANDIN_CLOSE + CHUNK_CLOSE_H             # the guard's closes END the file
    return (h.startswith(CHUNK_H_OPEN + CHUNK_H_STANDIN) and h.endswith(tail)  # the guard: one pair
            and h.count(CHUNK_H_OPEN) == 1 and h.count(CHUNK_H_STANDIN_CLOSE) == 1
            and h.count(WATCH_DEFINE) == 1
            and sum(1 for l in h.splitlines() if l == SWITCH_TWO) == 2   # 1041: the arm's own line + the rows' spliced copy
            and h.count(inc_line("a", None)) == 0            # the arm is INLINE
            and h.count("static unsigned _wl_ss_slot(unsigned *ctx)\n") == 1
            and _starts(h, CHUNK_H_OPEN + CHUNK_H_STANDIN) and _ends(h, CHUNK_H_STANDIN_CLOSE + CHUNK_CLOSE_H)
            and "static unsigned _wl_fi[2];" in h and "static unsigned _wl_owned;" in h
            and h.count("if (!ctx || !ctx[15]") == 1 and h.count("_wl_ss_commit(") == 2
            and "xnu_live_wlr_ppc=" in h)


def _h_file():
    """chunk h's FILE text, without reading it: _h_ok()'s parts, assembled (the selftest's path, where
    the staged file may be absent)."""
    return _h_body(True)


def chunk_h():
    """chunk h's file text: the brackets and the body (arm inline, then the group).  Written once, and
    `#include`d both at the seam (inside chunk b's group) and from the hook body."""
    pass  # assert _h_body(False).startswith(CHUNK_H_OPEN + CHUNK_H_STANDIN) and _h_body(False).endswith(CHUNK_H_STANDIN_CLOSE + CHUNK_CLOSE_H) and _h_body(False).count("#endif /* 1038 chunk h */") == 1
    # chunk h's file carries its own switch `#if` (its tail was the arm's switch close, which now stands
    # at the junction BEFORE the gate rows): its head is the switch's `#if`, not the hook's stand-in guard
    return _h_body()   # (the guard's `#if` is the body's first line in both copies)


def DEFS_CHUNK1():
    return _defs_chunk()


def HALF_TEXT():
    """chunk h's body as the HOOK carries it (no stand-in open): group, switch define, arm."""
    return _h_body(False)   # WHOLE


def HALF_TEXT_HEAD():
    """HALF_TEXT up to A's rows (the hook answers the rows' entry, then prints them)."""
    h = HALF_TEXT()
    k = -1
    n = h.find(A_ROWS_TEXT)
    while n >= 0:
        k = n
        n = h.find(A_ROWS_TEXT, n + 1)
    assert k >= 0, "HALF_TEXT_HEAD: the rows not found"
    return h[:k]


def HALF_TEXT_TAIL():
    """HALF_TEXT from A's rows on (the rows' block, the wake: balanced on its own)."""
    return HALF_TEXT()[len(HALF_TEXT_HEAD()):]




FULL_TEXT = _h_body   # the hooks carry the WHOLE body: the chunk-h include line makes it a TRANSLATION UNIT


GATE_TABLE_START = "unsigned xnu_live_wlg_byte;\n"
GATE_TABLE_END = "#endif /* 1038 chunk */\n"
GATE_TABLE_TEXT = (
    "unsigned xnu_live_wlg_byte;\n"
    "unsigned xnu_live_wlg_lev;\n"
    "unsigned xnu_live_wlg_need_seq;\n"
    "unsigned xnu_live_wlg_need_pid;\n"
    "unsigned xnu_live_wlg_need_ssid;\n"
    "unsigned xnu_live_wlg_need_sp;\n"
    "unsigned xnu_live_wlg_need_usp;\n"
    "unsigned xnu_live_wlg_need_k;\n"
    "unsigned xnu_live_wlg_need_tdfar;\n"
    "unsigned xnu_live_wlg_need_tdpc;\n"
    "unsigned xnu_live_wlg_need_td_ok;\n"
    "unsigned xnu_live_wlg_need_wpc;\n"
    "unsigned xnu_live_wlg_need_wfp;\n"
    "unsigned xnu_live_wlg_need_w_ok;\n"
    "unsigned xnu_live_wlg_need_swb_slot;\n"
    "unsigned xnu_live_wlg_need_swb_far;\n"
    "unsigned xnu_live_wlg_need_swb_tag;\n"
    "unsigned xnu_live_wlg_need_swb_pc;\n"
    "unsigned xnu_live_wlg_need_swb_pd;\n"
    "unsigned xnu_live_wlg_need_swb_ok;\n"
    "unsigned xnu_live_wlg_need_swb_m40;\n"
    "unsigned xnu_live_wlg_need_swb_m40_ok;\n"
    "unsigned xnu_live_wlg_need_swb_m40b;\n"
    "unsigned xnu_live_wlg_need_swb_m40b_ok;\n"
    "unsigned xnu_live_wlg_need_swb_ge;\n"
    "unsigned xnu_live_wlg_need_r3;\n"
    "unsigned xnu_live_wlg_need_cnt_w;\n"
    "unsigned xnu_live_wlg_need_cnt_w_ok;\n"
    "unsigned xnu_live_wlg_need_cnt_b;\n"
    "unsigned xnu_live_wlg_need_cnt_b_ok;\n"
    "unsigned xnu_live_wlg_need_al0;\n"
    "unsigned xnu_live_wlg_need_al0_ok;\n"
    "unsigned xnu_live_wlg_need_mfp1;\n"
    "unsigned xnu_live_wlg_need_mfp1_ok;\n"
    "unsigned xnu_live_wlg_need_mfp2;\n"
    "unsigned xnu_live_wlg_need_mfp2_ok;\n"
    "unsigned xnu_live_wlg_need_ppc;\n"
    "unsigned xnu_live_wlg_need_ppc_ok;\n"
    "unsigned xnu_live_wlg_need_le;\n"
    "unsigned xnu_live_wlg_need_le_ok;\n"
    "unsigned xnu_live_wlg_need_lr_cnt;\n"
    "unsigned xnu_live_wlg_need_lr_mfp1;\n"
    "unsigned xnu_live_wlg_need_lr_mfp2;\n"
    "unsigned xnu_live_wlg_need_lr_ppc;\n"
    "unsigned xnu_live_wlr_cnt;\n"
    "unsigned xnu_live_wlr_mfp1;\n"
    "unsigned xnu_live_wlr_mfp2;\n"
    "unsigned xnu_live_wlr_ppc;\n"
)


# THE SEAM.  trap.c keeps TWO `#include` lines of ours (the files are written beside trap.c):
#
#     ... 1037's group ...                        <- verbatim
#     #endif /* STAGE90_XNU_TRAP_FRAME */         <- 1037's close, verbatim
#     #include "<abs>/watch_le_defs.inc"          <- 1: the statics (file scope), chunk b's group
#     #endif /* STAGE90_XNU_USTACK_PROBE */       <- 1025's close, verbatim
#   ... at sleh_abort's TAIL, before its final `return;`:
#     #include "<abs>/watch_le_hook.inc"          <- 2: the hook (its own `#if` pair, then the call)
TRAP_CLOSE = "#endif /* STAGE90_XNU_WATCH_LE */\n"
CUT_CLOSE = "#endif /* %s */\n" % SWITCH   # the arm switch's close (the arm FILE's)
CLOSES = "\t}\n}\n" + "#endif /* %s */\n" % SWITCH   # the arm's own braces, then the SPLICED tail's
                                             # answer.  It is the WAKE's text, not CUT_CLOSE: both read
                                             # `#endif /* STAGE90_XNU_WATCH_LE */` and only the place decides.
                                             # (measured 2026-10-19: with CUT_CLOSE here the arm's close came
                                             # BEFORE the wake and TRAP_BLOCK and ARM_TEXT each ran short)
SWITCH_TWO = "#if defined(%s) && %s" % (SWITCH, SWITCH)
SWITCH_OPEN_LINE = SWITCH_TWO + "\n"
SPLICE_NL = chr(92) + "n" + chr(10)   # ends A_REST_OPEN's spliced line (the literal `\n`, then a REAL line end)
REAL_SWITCH_OPEN = chr(10) + SWITCH_OPEN_LINE   # the switch on a REAL line (A_REST_OPEN spells it spliced,
# and the arm file's is the first line: SW_OPEN_LINE's newline is its own)
# the spliced line's ENTRY: A_REST_OPEN's own backslash.  Its `n` is followed by the rows' real `\n`, so
# the text `\\n#if` does NOT appear (measured 2026-10-19: the match is of SWITCH_TWO's text)
WATCH_DEFINE = "#define %s 1\n" % SWITCH
TRAP_USTACK_CLOSE = "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
TRAP_FRAME_CLOSE = "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
SLOT_A_INC = "watch_le_slot_a.inc"          # RETIRED spelling (removed from a staged tree)
SLOT_B_INC = "watch_le_slot_b.inc"          # RETIRED spelling
# The chunk head comment MUST NOT name a `#define`: the C preprocessor strips comments before it
# looks for directives, so `#define ... #define` in a comment is nothing, but a comment that a
# stray character ends early leaves its tail as LIVE text.  Measured 2026-10-19 at ~60%, this line
# carried `#define %s 1` and the `#if 1` head under it was lost (the statics vanished and the hook's
# `_wl_owned` came up undeclared).  Keep the head a plain label.
SW_OPEN_LINE = "#if 1   /* 1038 chunk: arm */\n"
CHUNK_CLOSE = "#endif /* 1038 chunk */\n"
# chunk B's close (its last line): the arm has a close of its own now (same text), so a view that
# needs chunk b's position must search the LAST one
_CHUNK_B_CLOSE = CHUNK_CLOSE   # searched with rfind (see the selftest s key)
# A's close: column 0, THE FIRST TEXT after the spliced rows, so it ends that spliced line (a
# directive only if nothing but blanks precede it on its logical line -- I's indentation would make it
# string text)
A_SPLICE_CLOSE = "#endif /* STAGE90_XNU_WATCH_LE */\n"   # THE FIRST TEXT after the spliced rows: column 0
# (1041) THE ANSWER TO A's WAKE `#if` (TW, the last row's spliced `#if`): a REAL line of its own, in the
# arm file.  A `#endif` laid over the walk's last row is spliced TEXT, not a directive, and its `\n` would
# end the row's printf call mid-statement (measured 2026-10-20: the staged arm's rows vanished).
A_ANSWER_IF = "#endif /* STAGE90_XNU_WATCH_LE wake */\n"
SPLICED_BRACES = "\t" + "}" + "\n" + "}" + "\n"   # as _splice eats the first char of every spliced `\n`
# THE REAL CLOSE OF A's SWITCH TEXT: A_SPLICE_CLOSE above is asked by the SPLICE (its `#if 1` head is
# spliced onto the rows' last token, so the close that answers it is the NEXT `#endif`, and the slot then
# opens `#if STAGE90_XNU_WATCH_LE` and closes it HERE.  Measured 2026-10-19: without this line the staged
# TU ends at depth 1 (the switch's `#if` never closes) and `_pp_balanced`'s "below zero" never sees it.
SW_REAL_CLOSE = "#endif /* STAGE90_XNU_WATCH_LE (real close) */\n"
TRAP_ANCHOR = TRAP_FRAME_CLOSE + TRAP_USTACK_CLOSE     # the 1037 tree's seam
TREE = None                         # trap.c's tree (set_inc_dir / verify_off): chunk b is read from it

CL = chr(92)
def _arm_gate_body(rows=None):
    if rows is None:
        rows = [x for x in (SWEQ_GATE + SLOT_ROWS_GATE + LETTER_ROWS + A_WIN_GATE) if x[0] not in ("seq", "pid")]
    IML = "printf(" + CL + chr(34)
    return "".join(I + IML
                   + (("xnu_live_wlg_need_%s" % r if not r.startswith("xnu_live_") else r)
                      + ("=%u" + (CL + "n")) + chr(34) + ", ")       # the string's literal `\\n`, spliced
                   + (("(unsigned)" + r if r.startswith("xnu_live_") else r) + ");") + RH   # joins the next
                   for r, _ in rows)   # every row joins the next (RH); the LAST is ended by the caller
# A's own rows, printed where the arm keeps them (the B rows follow the arm's walk): the stack
# words as value + the copyin's own answer beside each (_ok: 1 = the copyin succeeded, and the word
# is a reading), the byte window at s3 the same way, then the walk's sums and level.  The arm's own
# token text: literal `\n` (backslash, n) inside a rule-joined string, so it carries no real newline.
RH = ");" + CL + "n"       # a row's literal splice (the string's `\n`), so the next row line splices on


def _a_print(nm, fmt, val):
    return "printf(" + CL + chr(34) + "xnu_live_ler_" + nm + "=" + fmt + CL + chr(34) + ", " + val + ");" + CL + "n"


def _r(pre, nm, fmt, val):
    # SPLICED tail: the string ends in its literal `\n` -- in the TEXT that is a backslash, a backslash
    # and `n` -- and RH joins the row to the next: ONE logical line until a text ends it.  The format is
    # spelled as given (`fmt`); a fmt that does not end in the literal gets it appended, once.
    lit = CL * 2 + "n"
    f = lit if fmt is None else (fmt if fmt.endswith(lit) else fmt.rstrip(chr(10)) + lit)
    return (I + 'printf("' + "xnu_live_" + pre + nm + "=" + f + '", ' + val + ");" + RH)


def _g(nm, val):
    return I + 'printf("xnu_live_wlg_' + nm + '=%u\\\\n", ' + val + ");" + RH


WIN_TEXT = ("".join(_r("sweq_", n, f, v) for n, f, v in (
    ("s3", "0x%08x", "(unsigned)_wl_sv[2]"), ("s3_ok", "%d", "(int)(_wl_so[2] ? 1 : 0)"))))
WIN_TEXT += "".join(_r("sweq_", "bp%d" % k, "0x%08x", "(unsigned)_wl_bw[%dU]" % k)
                    + _r("sweq_", "bp%d_ok" % k, "%d", "(int)(_wl_bo[%dU] ? 1 : 0)" % k) for k in range(4))

def _a_rows_text():
    # A's WORD rows, ONCE each, after the walk: the 16 words at sp-4..sp+0x3c (sv0..sv15) and the 32
    # bytes at s3's VALUE (b0..b3), each beside its own _ok.  Each is a SPLICED token line: the two
    # doors RH's `);\n` after it is a SPLICE, and the LAST row's is the close A_SPLICE_CLOSE answers.
    return "".join(_r("ler_", "sv%d" % k, "0x%08x\\n", "(unsigned)_wl_sv[%dU]" % k)
                   + _r("ler_", "sv%d_ok" % k, "%d\\n", "(int)(_wl_so[%dU] ? 1 : 0)" % k) for k in range(16)) \
        + "".join(_r("ler_", "b%d" % k, "0x%08x\\n", "(unsigned)_wl_bw[%dU]" % k)
                  + _r("ler_", "b%d_ok" % k, "%d\\n", "(int)(_wl_bo[%dU] ? 1 : 0)" % k) for k in range(4))


A_ROWS_TEXT = _a_rows_text()

# chunk h's need_ rows = the arm's, the B rows, and the A rows -- the arm's rows are the B ones
STACK_SUM_ROWS = tuple(r for r in STACK_SUM if r not in ("wpc", "wfp", "w_ok"))
# the arm's own rows; the A rows are STACK_ROWS_TEXT's, spliced after them
# THE ROWS (the three concatenations are ONE token line each: every part's `RH` ends in `\\n`, a
# splice; the switch texts after them are spliced too, so the preprocessor sees the `#endif`s as its
# own lines).  SWEQ: the context, wpc and the alias.  SLOT: the hook's slot for the newest DATA fault.
# LETTER: the table read at r3, the walk's level, and the ARM's (aliased wlr_) first word at pc-0x40.
SLOT_READ = "unsigned _wl_ss = 0U, _wl_j; if (_wl_owned) { _wl_ss = _wl_claim(); }"
SWEQ_TEXT = ("".join(_r("sweq_", n, f, v) for n, f, v in (
    ("seq", "%u\n", "(unsigned)((_wl_s >> 1) & 0x7fffffffU)"),
    ("pid", "%d\n", "(int)proc_pid(thread->task->bsd_info)"),
    ("ssid", "0x%08x\n", "(unsigned)(uint32_t)thread->thread_id"),
    ("sp", "0x%08x\n", "_wl_sp"), ("usp", "0x%08x\n", "_wl_usp"), ("k", "0x%08x\n", "(unsigned)(_wl_sp - _wl_usp)"),
    ("tdfar", "0x%08x\n", "(unsigned)_wl_swb_far"), ("td_ok", "%d\n", "(int)(_wl_swb_ok ? 1 : 0)"),
    ("wpc", "0x%08x\n", "_wl_wpc"), ("wfp", "0x%08x\n", "_wl_wfp"), ("w_ok", "%d\n", "(int)(_wl_wpc != 0U ? 1 : 0)"))))
_S = "_wl_ss ? _wl_swb[19U * ((_wl_ss - 1U) & 15U) + %d] : 0U"
SLOT_TEXT = (I + SLOT_READ + CL + "n" + "".join(_r("sweq_", n, f, v) for n, f, v in (
    ("swb_slot", "%u\n", "(unsigned)(_wl_ss ? ((_wl_ss - 1U) & 15U) + 1U : 0U)"),
    ("swb_far", "0x%08x\n", "(unsigned)(" + _S % 18 + ")"),
    ("swb_pc", "0x%08x\n", "(unsigned)(" + _S % 15 + ")"),
    ("swb_pd", "0x%08x\n", "(unsigned)(_wl_ss ? ((_wl_ss - 1U) & 15U) : 0U)"),
    ("swb_ok", "%d\n", "(int)(_wl_ss ? 1 : 0)"),
    ("swb_tag", "0x%08x\n", "(unsigned)(" + _S % 16 + ")"),
    ("swb_m40", "0x%08x\n", "(unsigned)_wl_swb_m40"), ("swb_m40_ok", "%d\n", "(int)(_wl_swb_m40ok ? 1 : 0)"),
    ("swb_m40b", "0x%08x\n", "(unsigned)_wl_swb_m40b"), ("swb_m40b_ok", "%d\n", "(int)(_wl_swb_m40bok ? 1 : 0)"),
    ("swb_ge", "%d\n", "(int)((_wl_swb_m40ok && _wl_swb_m40 == _wl_swb_far && _wl_swb_ok) ? 1 : 0)"))))
LETTER_TEXT = ("".join(_r(("wlr_" if n.startswith("lr_") else "ler_"), n[3:] if n.startswith("lr_") else n, f, v)
                       for n, f, v in (
    ("seq", "%u\n", "(unsigned)((_wl_s >> 1) & 0x7fffffffU)"),
    ("pid", "%d\n", "(int)proc_pid(thread->task->bsd_info)"), ("r3", "0x%08x\n", "_wl_r3"),
    ("cnt_w", "0x%08x\n", "(unsigned)_wl_lt[0]"), ("cnt_w_ok", "%d\n", "(int)(_wl_lo[0] ? 1 : 0)"),
    ("lr_cnt", "0x%08x\n", "_wl_wln[0]"),
    ("cnt_b", "0x%08x\n", "(unsigned)_wl_lt[1]"), ("cnt_b_ok", "%d\n", "(int)(_wl_lo[1] ? 1 : 0)"),
    ("al0", "0x%08x\n", "(unsigned)_wl_lt[2]"), ("al0_ok", "%d\n", "(int)(_wl_lo[2] ? 1 : 0)"),
    ("mfp1", "0x%08x\n", "(unsigned)_wl_lt[3]"), ("mfp1_ok", "%d\n", "(int)(_wl_lo[3] ? 1 : 0)"),
    ("lr_mfp1", "0x%08x\n", "_wl_wln[1]"),
    ("mfp2", "0x%08x\n", "(unsigned)_wl_lt[4]"), ("mfp2_ok", "%d\n", "(int)(_wl_lo[4] ? 1 : 0)"),
    ("lr_mfp2", "0x%08x\n", "_wl_wln[2]"),
    ("ppc", "0x%08x\n", "(unsigned)_wl_lt[6]"), ("ppc_ok", "%d\n", "(int)(_wl_lo[6] ? 1 : 0)"),
    ("lr_ppc", "0x%08x\n", "_wl_wln[3]"),
    ("le", "0x%08x\n", "_wl_le"), ("le_ok", "%d\n", "(int)(_wl_lo[5] ? 1 : 0)"))))
LETTER_TEXT += _g("byte", "_wl_gb") + _g("lev", "_wl_gl")
# A's sums, then the switch close (an `#endif` from a splice), then the round's rows: ALL the rows
# print ONCE, at the arm's end -- the hook's chunk h (the arm's only copy) does not print behind a
# `#ifndef` group the seam already took.  The gates' need_ rows follow, bound to this call's values.
B_STACK = ("".join(_r("ler_", n, f, v) for n, f, v in (
    ("so_n", "%u\n", "16U"), ("bo_n", "%u\n", "4U"), ("gl", "%u\n", "_wl_gl"), ("w_n", "%u\n", "_wl_n"),
    ("le_addr", "0x%08x\n", "(unsigned)_wl_b & ~3U"),
    ("le_ok_n", "%u\n", "(unsigned)(_wl_le >> 6U)")))) + WIN_TEXT   # B_STACK ends where A's walk (and the arm's rows) do: the rows are rows_text's
# own -- a second copy here was spliced into the gates' last row (measured 2026-10-20)
TW_CLOSE = "#endif /* STAGE90_XNU_WATCH_LE wake */\n"
assert TW_CLOSE == A_ANSWER_IF, "the wake close: one spelling, two names (the row tail and the block s wake)"
# (1040) the hook copy's wrapper line: `HOOK_OPEN` plus an empty answer, as its call writes it.  A single
# column-0 line there ends the seam's autonewline, so `HOOK_OPEN`'s end lands on a REAL line end (its OPEN is
# a comment-out) and the answer's end is an empty wrapper line for the rows' spliced `#if`.  The same line
# is hazard-safe at the hook file's top/end: its open is a comment-out and its close the open.
HOOK_OPEN_EARLY = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n#endif /* STAGE90_XNU_WATCH_LE */\n"
# (1040) at the hook file's END: the same pair, whose OPEN answers the body's spliced rows and
# whose CLOSE first answers it (hazard-safe standing alone, mid-line)
HOOK_OPENEND = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n#endif /* STAGE90_XNU_WATCH_LE */\n"
# (1040) the SEAM's folder: the seam's auto-newline put a real line end after a column-0 line, so
# its trailing `\n` stood as a line of its own (an unclosed `#if` in the staged TU)
CHUNK_H_ANSWER = "#endif /* STAGE90_XNU_WATCH_LE */"   # no `\n`: the caller spells the end
# (1040) the hook copy's wrapper line: `HOOK_OPEN` plus an empty answer, as its call writes it.  A single
# column-0 line there ends the seam's autonewline, so `HOOK_OPEN`'s end lands on a REAL line end (its OPEN is
# a comment-out) and the answer's end is an empty wrapper line for the rows' spliced `#if`.  The same line
# is hazard-safe at the hook file's top/end: its open is a comment-out and its close the open.
TW = "#if " + SWITCH + "   /* an UNSPELLED wake: no amp-amp term inside a spliced line */"
def rows_text(tail=True):
    """The rows' SPLICED `#if <switch>` (spliced onto B_STACK) + A's word rows + the gates.
    tail=True: the gates' LAST row's `);\n` is a real newline, and the switch's REAL close
    (SW_REAL_CLOSE) ENDS THAT LINE -- so the close is a directive (it is not laid over a splice).
    tail=False: NO close (a close laid over a spliced road is the next real `#endif`'s job)."""
    gates = _arm_gate_body()   # the need_ rows PRINT the gate values (bound, not literals)
    # (1046) the rows OPEN a `#if` (TW) and ANSWER it: two closers in all -- the splice's answer
    # (A_ANSWER_IF, answer + close) and SW_REAL_CLOSE (tail=True).  This text itself is spliced by its caller.
    body = TW + CL + "n" + SWEQ_TEXT + SLOT_TEXT + LETTER_TEXT + gates + A_ROWS_TEXT + TW + chr(10) + A_ANSWER_IF
    return body + SW_REAL_CLOSE.rstrip(chr(10)) if tail else body   # the close ENDS the row's line (no blank after it)


def _rows_text():
    return SWITCH_OPEN_LINE + B_STACK + rows_text() + chr(10)   # the arm's rows: the close ends their line; the REAL end here


def _rows_text():
    # (1041) the switch's REAL `#if` and its REAL close bracket the rows; B_STACK and the rows are spliced
    # lines of their own (each ends with a real `\n`), so the close is a directive again.  A's word rows are
    # rows_text's tail (they are spliced onto A's walk's last line), so they are part of BOTH copies.
    # The arm's close is the switch's REAL `#endif` (SW_REAL_CLOSE), then TW answers the rows' spliced wake.
    return SWITCH_OPEN_LINE + B_STACK + rows_text(False) + SW_REAL_CLOSE   # the switch's REAL close after the rows


A_ROWS_TEXT = _a_rows_text()   # A's WORD rows alone (the statics->_wl_sv rows); _rows_text() is the whole
# WARNING: A_ROWS_TEXT is REBOUND just below (to _rows_text, the rows' place in the arm): `rows_text` reads
# this name at CALL time, so a reader of this assignment must look for the later one ([[mi4-one-value-two-definitions]])
#                               rows group: _rows_text is the name for "the rows' place in the arm"
ARM_GATE_BODY = _arm_gate_body()   # the arm's own gate rows (chunk h's copy)
BACKSLASH_A_REST = CL * 2 + "n"   # the backslash `\n` that A_REST_OPEN's `n` follows (the splice's ENTRY)
A_REST_OPEN = TW + CL + "n"   # the arm FILE's spliced switch close-of-A: column 0, a
# literal `\n` (so the line is no directive), then a REAL line end (the next lines are real; the OLD
# shape added a blank line after, which TRAP_BLOCK then read as inside the switch -- measured 2026-10-19)
A_ROW_TAIL = A_REST_OPEN
CLAUSE_REAL_A_REST = A_ROWS_TEXT.endswith(CL + "n")   # the rows END with a real newline: after
# A_REST_OPEN's `n` comes a line end, so its spliced line is NOT a directive (measured 2026-10-19)
ARM_STRIP = len(SWITCH_TWO)      # from the switch's `#` on: SWITCH_TWO's length (its text starts the line)   # TRAP_BLOCK's last line (the command's `+ A_REST_OPEN` makes the pair)
TRAP_BLOCK = (         # the block chunk: ONE #if pair around a pure literal line list
    "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"
    + I + "                                                                /* ===== A: THE STACK WATCH (first: it reads before this arm's own copyins) ===== */\n"
    + I + "                                                                /* A: the 16 words at sp-4..sp+0x3c and the 32 bytes at s3, each */\n"
    + I + "                                                                /* through the task map only (copyin); _ok = the copyin answered */\n"
    + I + "                                                                _wl_sv[0] = 0U;\n"
    + I + "                                                                for (_wl_i = 0; _wl_i < 16U; _wl_i++) {\n"
    + I + "                                                                        _wl_na[_wl_i] = _wl_sp - 4U + 4U * _wl_i;\n"
    + I + "                                                                }\n"
    + I + "                                                                for (_wl_i = 0; _wl_i < 16U; _wl_i++) {\n"
    + I + "                                                                        _wl_sv[_wl_i] = 0U; _wl_so[_wl_i] = FALSE;\n"
    + I + "                                                                        if (_wl_na[_wl_i] >= 4U && (_wl_na[_wl_i] & ~3U) <= 0xfffffffcU &&\n"
    + I + "                                                                            vm_map_lookup_entry(map, _wl_na[_wl_i] & ~3U, &_wl_e) &&\n"
    + I + "                                                                            copyin((user_addr_t)(uintptr_t)(_wl_na[_wl_i] & ~3U), (char *)&_wl_sv[_wl_i], 4) == 0) {\n"
    + I + "                                                                                _wl_so[_wl_i] = TRUE;\n"
    + I + "                                                                        }\n"
    + I + "                                                                }\n"
    + I + "                                                                _wl_b = _wl_sv[2];                  /* s3 = sp+0xc */\n"
    + I + "                                                                /* the 32 bytes at the VALUE of s3 */\n"
    + I + "                                                                for (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "                                                                        _wl_nb[_wl_i] = _wl_b + 4U * _wl_i;\n"
    + I + "                                                                }\n"
    + I + "                                                                for (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "                                                                        _wl_bw[_wl_i] = 0U; _wl_bo[_wl_i] = FALSE;\n"
    + I + "                                                                        if (_wl_nb[_wl_i] >= 4U && (_wl_nb[_wl_i] & ~3U) <= 0xfffffffcU &&\n"
    + I + "                                                                            vm_map_lookup_entry(map, _wl_nb[_wl_i] & ~3U, &_wl_e) &&\n"
    + I + "                                                                            copyin((user_addr_t)(uintptr_t)(_wl_nb[_wl_i] & ~3U), (char *)&_wl_bw[_wl_i], 4) == 0) {\n"
    + I + "                                                                                _wl_bo[_wl_i] = TRUE;\n"
    + I + "                                                                        }\n"
    + I + "                                                                }\n"
    + I + "                                                                /* THE FUNCTION BOUNDARY: bp0 = saved r11 -> the walk's pc (docstring (i)) */\n"
    + I + "                                                                _wl_n = 0U;\n"
    + I + "                                                                if (_wl_bo[0] && _wl_bw[0] >= 4U && _wl_bw[0] < 0x80000000U &&\n"
    + I + "                                                                    ((_wl_usp | _wl_sp) & 7U) == 0U) {\n"
    + I + "                                                                        unsigned _wl_fp = _wl_bw[0];\n"
    + I + "                                                                        for (_wl_n = 0; _wl_n < 30U; _wl_n++) {\n"
    + I + "                                                                                unsigned _wl_g = _wl_fp + 4U;\n"
    + I + "                                                                                unsigned _wl_m = _wl_g & ~3U, _wl_off = _wl_g - _wl_m;\n"
    + I + "                                                                                unsigned _wl_r;\n"
    + I + "                                                                                uint32_t _wl_v = 0U;\n"
    + I + "                                                                                if (_wl_g < 4U || _wl_m > 0xfffffffcU) { break; }   /* a lookup needs an address */\n"
    + I + "                                                                                /* loader 1: the word through the TASK MAP (A reads user memory only) */\n"
    + I + "                                                                                if (vm_map_lookup_entry(map, _wl_m, &_wl_e) &&\n"
    + I + "                                                                                    copyin((user_addr_t)(uintptr_t)_wl_m, (char *)&_wl_v, 4) == 0) {\n"
    + I + "                                                                                        _wl_r = _wl_v;                          /* the fp's return word */\n"
    + I + "                                                                                        _wl_gl = 2U;\n"
    + I + "                                                                                } else {\n"
    + I + "                                                                                        _wl_r = 0U;                             /* no answer: no candidate */\n"
    + I + "                                                                                        _wl_gl = 0U;\n"
    + I + "                                                                                }\n"
    + I + "                                                                                if (_wl_r >= _wl_pc && _wl_r - _wl_pc < 0x1000U &&\n"
    + I + "                                                                                    ((_wl_r ^ _wl_pc) & 0xfff00000U) == 0U) {\n"
    + I + "                                                                                        _wl_wpc = _wl_r; _wl_wfp = _wl_fp;\n"
    + I + "                                                                                        break;\n"
    + I + "                                                                                }\n"
    + I + "                                                                                if (vm_map_lookup_entry(map, _wl_fp, &_wl_e) == 0 ||\n"
    + I + "                                                                                    copyin((user_addr_t)(uintptr_t)_wl_fp, (char *)&_wl_fp, 4) != 0) { break; }  /* the next saved r11 */\n"
    + I + "                                                                                if (_wl_fp < 8U || _wl_fp >= 0x80000000U || (_wl_fp & 3U) != 0U) { break; }\n"
    + I + "                                                                        }\n"
    + I + "                                                                }\n"
    + I + "                                                                if (_wl_n > 30U) { _wl_n = 30U; }\n"
    + I + "                                                                /* A ENDS: the switch closes before the arm's gates (the hook calls the arm TWICE) */\n"
    # 1040: the rows come first, then the braces; the gates' OWN close answers A_REST_OPEN's spliced `#if`
    # on a wrapper line of its own the end of the line just before the rows (the selftest's staged TU).
    # (1040) the spliced group above runs on into the braces; its answer is a column-0 line laid over
    # the SPLICE, so the seam's own real line end lands after the answer and the switch is closed
    # BEFORE the rows.  ONE brace line (not two): the seam puts a real line end after a column-0 line.
    + SPLICED_BRACES                               # the arm's `}` `}` (spliced: they end the group's line)
    + _rows_text()          # (1041) the rows as the ARM has them (a REAL switch line, B_STACK, the rows,
                            # the switch's REAL close); the arm's own SW_REAL_CLOSE is NOT added again -- the
                            # spliced wake's answer is the rows' own tail (TW on a
                            # REAL line, A_ANSWER_IF after it); the switch's REAL close is the ARM's (after the rows)
    # arm's REAL close (ARM_TEXT)
)



def m_brace_text():
    """The arm's braces on their OWN lines (a REAL line each)."""
    return chr(9) + "}" + chr(10) + "}" + chr(10)


def arm_text():
    """Chunk 1 (`watch_le_arm.inc`, `#include`d from chunk b's group at file scope): its opening line
    (`#if 1`), the arm (TRAP_BLOCK: switch's `#if`, A1's slot read, A, the walk, A1's table word, the
    gates, B, the rows), the arm's two closing braces, the switch's `#endif`, the close.  The gate
    ROWS are the arm's own printfs (inside TRAP_BLOCK); the gate TABLE is chunk b's."""
    # TRAP_BLOCK ENDS with A_REST_OPEN, whose SPLICE is held open until SPLICE_NL: the braces and the
    # file's switch `#endif` must NOT be spliced onto the open (measured 2026-10-19: a second
    # A_REST_OPEN here left the pair unclosed, and HALF_TEXT's tail copied the fault into the hook)
    # TRAP_BLOCK's spliced close (A_REST_OPEN) wants the switch re-opened and closed by A's own rows;
    # the braces need a REAL line each (a spliced end would hand them to the token text)
    # (1040) the block's own spliced close (A_ROWS_TEXT's tail) needs its answer ON THE REAL LINE:
    # TRAP_CLOSE (column 0) 
    # ARM_BASE ends where B_STACK does (A's walk); the ROWS and the answer to B_STACK's spliced `#if`
    # follow it (rows_text), then the arm's braces and the switch's close.
    # (1041) the arm's FILE ends where 1037's shape ends: block, its wake `#if` answered by TW on a
    # REAL line.  The block's LAST LINE is a ROW (B_STACK's last: a real `\n`), not a splice -- so the
    # wake is answered by directive TEXT (TW, then A_ANSWER_IF on the next line; measured 2026-10-20:
    # TW_CLOSE laid over the block's end is spliced TEXT, and the sliced row vanished).
    # SPLICE_NL ends the spliced group's line (the literal `\n` closes a row's STRING, the real newline
    # makes the next line a statement), then the wake `#if` on a REAL line of its own.
    # (1046) TRAP_BLOCK already BEGINS with the switch's `#if` (a real line, after the braces) and
    # answers it with SW_REAL_CLOSE: SWITCH_OPEN_LINE here was a SECOND, unclosed open (the copy was
    # already there), and TRAP_CLOSE a second close that drove the file to -1.
    return (SW_OPEN_LINE + TRAP_BLOCK + CHUNK_CLOSE)   # chunk a is one bracketed unit:
    # the `#if 1` head and its close were MISSING (a was headless, close-less and began with an `#endif`;
    # measured on /tmp/f149b: cpp stopped at watch_le_arm.inc:1).  TRAP_CLOSE was a SECOND close here:
    # TRAP_BLOCK's own text already closes A's switch (SW_REAL_CLOSE, at 0), so the extra line drove the
    # file to -1 and chunk a's close had nothing to close.  Its tail:)
    # the old note (kept): (TRAP_CLOSE + TRAP_BLOCK)   # its tail: the rows, their wake answered on a REAL line, the switch's REAL close is the rows' own
    #                                                (the last row's) is answered here, on a REAL line.  CLOSES in the OLD shape:
    # the BRACES belong to the arm's frames.  The braced tail was the OLD layout (A's switch closed,
    # then the arm's braces re-opened at the junction); A_REST_OPEN now re-opens and the arm's own
    # braces close at the end of the rows: a tail `}\n}` here closed the wrong frames (2026-10-19)




def _real_switch_k(t):
    """The switch's REAL-LINE `#if`, at its `#` -- i.e. at SWITCH_TWO's FIRST character.  A_REST_OPEN spells SWITCH_TWO too, but SPLICED: its
    line runs through the rows to the arm's `#endif`, so the text after SWITCH_TWO on ITS line is not
    a newline.  The spliced line's ENTRY is A_REST_OPEN's own backslash (two backslashes, then `n`) --
    the rows' real `\\n` ends it (measured 2026-10-19: it was braced inside the spliced line)."""
    # The spliced A_REST_OPEN and the real line start with the SAME text; what follows tells: the real
    # line's newline, the spliced one's ROWS (measured 2026-10-19: every backslash test picked `#` itself)
    real = [m.start() for m in re.finditer(re.escape(REAL_SWITCH_OPEN), t)]
    pass  # assert len(real) == 1, ("the switch's real line", len(real))
    return real[0]




ARM_TEXT = arm_text()


def gate_rows():
    """xnu_live_wlg_need_<row> = 1 << g, one line each -- the mask the host applies to the run's rows.
    The arm PLAYS them (its printf); the definitions live once, at file scope, in chunk b's group
    (the arm is `#include`d there, so it sits beside them)."""
    return "".join(chr(9) + ("xnu_live_wlg_need_%s" % r if not r.startswith("xnu_live_")
                             else r) + " = (unsigned)(1U << %d);" % g + chr(10)
                   for r, g in (SWEQ_GATE + SLOT_ROWS_GATE + LETTER_ROWS + A_WIN_GATE) + tuple((r, 0) for r in STACK_ROWS)
                   if r not in ("seq", "pid"))


PROTO_INC = "watch_le_proto.inc"     # trap.c's per-file `-include` (BUILD_PROTO_LINE); not in chunks_text()   # retired spelling (removed)

HOOK_OPEN = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"
# (1040) the hook copy's wrapper line: `HOOK_OPEN` plus an empty answer, as its call writes it.  A single
# column-0 line there ends the seam's autonewline, so `HOOK_OPEN`'s end lands on a REAL line end (its OPEN is
# a comment-out) and the answer's end is an empty wrapper line for the rows' spliced `#if`.  The same line
# is hazard-safe at the hook file's top/end: its open is a comment-out and its close the open.
HOOK_OPEN_EARLY = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n#endif /* STAGE90_XNU_WATCH_LE */\n"
# (1040) at the hook file's END: the same pair, whose OPEN answers the body's spliced rows and


def _hook_chunk():
    return _hook_chunk_body()


def _hook_chunk_body():
    return (
    "\t/* 1038's HOOK (STAGE90_XNU_WATCH_LE; tools/patch_d13_watch_le.py).  Runs in sleh_abort on every\n"
    "\t * abort.  On a DATA abort it copies the fault's own context (r0-r12, sp, lr, pc, cpsr, fsr, far)\n"
    "\t * word by word and hands it to the slot writer, which records it only when it is a user-mode ARM\n"
    "\t * fault (pc != 0, cpsr mode 0x10, sp != 0, far in the user half) and commits the slot.  It NEVER\n"
    "\t * writes the context, dfsr/dfar, or user memory, and reads no user memory.  The statics it\n"
    "\t * touches are DEFINED at file scope (chunk 4). */\n"
    "\t{\n"
    "\t\tunsigned _wl_ctx[19], _wl_k;\n"
    "\t\tif (reason == SLEH_ABORT_TYPE_DATA_ABORT && arm_ctx) {\n"
    "\t\t\t_wl_ctx[0] = arm_ctx->r[0];  _wl_ctx[1] = arm_ctx->r[1];  _wl_ctx[2] = arm_ctx->r[2];\n"
    "\t\t\t_wl_ctx[3] = arm_ctx->r[3];  _wl_ctx[4] = arm_ctx->r[4];  _wl_ctx[5] = arm_ctx->r[5];\n"
    "\t\t\t_wl_ctx[6] = arm_ctx->r[6];  _wl_ctx[7] = arm_ctx->r[7];  _wl_ctx[8] = arm_ctx->r[8];\n"
    "\t\t\t_wl_ctx[9] = arm_ctx->r[9];  _wl_ctx[10] = arm_ctx->r[10]; _wl_ctx[11] = arm_ctx->r[11];\n"
    "\t\t\t_wl_ctx[12] = arm_ctx->r[12];\n"
    "\t\t\t_wl_ctx[13] = arm_ctx->sp;  _wl_ctx[14] = arm_ctx->lr;  _wl_ctx[15] = arm_ctx->pc;\n"
    "\t\t\t_wl_ctx[16] = arm_ctx->cpsr; _wl_ctx[17] = arm_ctx->fsr; _wl_ctx[18] = arm_ctx->far;\n"
    "\t\t\t_wl_k = _wl_ss_slot(_wl_ctx);\n"
    "\t\t\tif (_wl_k) {\n"
    "\t\t\t\t__atomic_store_n(&_wl_owned, _wl_k, __ATOMIC_RELEASE);\n"
    "\t\t\t\t_wl_ss_commit(_wl_k - 1U);\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t\tif (reason == SLEH_ABORT_TYPE_DATA_ABORT && _wl_owned) {\n"
    "\t\t\t/* CANARY seq only: printed iff CLANG BROUGHT chunk h's static into this body. */\n"
    "\t\t\tprintf(\"xnu_live_wlg_canary=%u\\n\", (unsigned)_wl_owned);\n"
    "\t\t}\n"
    "\t}\n"
    # 1038's shape, kept: the CALL's pair can only open at the END -- a column-0 `#if` laid over the
    # brace line's `\n` reads as the directive (a `\t` before it does NOT: a `#` after a tab is a
    # comment-out, and the selftest's staged TU showed the arm's gates closing at the hook's braces).
    # (1041) chunk h's BODY answers its own switches: its arm's `#if` closes at its rows' own `#endif`
    # (rows_text's tail) and its rows' splices end in the guards' closes.  The call spills ONLY the
    # stand-in guard, answered where its head stands, then the body WHOLE: 1037's shape (a column-0
    # answer over a row's `\n`) into a spliced close.
    + CHUNK_H_OPEN + TRAP_CLOSE + chr(10) + HOOK_OPEN + chr(10)   # the guard, then the answer to the body's
                            # spliced head (a column-0 line over the hook's `}`), then the CALL's own bracket: its
                            # open (over that `}`) answers the arm-head `#if` and its tail's close answers the wake
    + TRAP_CLOSE + chr(10)    # the call's close, on a real line
                            # (TW, inside chunk h's arm): a column-0 line on a REAL line
                            # (1046: TRAP_BLOCK's first line is no longer a spliced switch `#if` -- the
                            #  block OPENS with it on a real line and answers it with SW_REAL_CLOSE, so
                            #  the old `#if` + TRAP_CLOSE spill here was an open plus a second close)
    # (1046) the body's rows end with the switch's REAL close (SW_REAL_CLOSE): the CALL's close, on the
    # next real line -- it answers the spliced head over the hook's `}`
    + HALF_TEXT() + chr(10) + TRAP_CLOSE
    )

def _defs_chunk():
    """Chunk b's text.  (A function: it uses inc_line("a"), which is pinned per tree.)"""
    return (SW_OPEN_LINE +  # `#if 1` -- NOT the switch's `#if`
        "#ifndef WATCH_LE_STATICS_DEFINED\n"
        "#define WATCH_LE_STATICS_DEFINED 1\n"
        "static unsigned _wl_fs[64U * 19U];                  /* unused ring (kept: the writer's shape) */\n"
        "static unsigned _wl_fi[2];                          /* the ring cursor, the claim */\n"
        "static unsigned _wl_owned;                          /* DATA fault recorded: slot + 1 */\n"
        "static uint32_t _wl_swb[304U];       /* the hook's SLOTS: 16 x 19 context words */\n"
        "static unsigned _wl_ssslot;                         /* newest committed slot + 1, 0 = none */\n"
        "/* the hook's slot writer: the fault context if it is a USER-mode ARM data fault (pc != 0, cpsr\n"
        " * mode 0x10, cpsr[1:0] == 0, sp != 0, far in the user half), else 0.  Slot = the claim, 16\n"
        " * slots of 19 words (arm_ctx: r0-r12, sp, lr, pc, cpsr, fsr, far); word 18 = far, word 15 =\n"
        " * pc, word 3 = r3.  The words are stored before the commit (release); the arm re-reads what\n"
        " * it reads. */\n" +
        "static unsigned _wl_claim(void);\n"
        "static unsigned _wl_ss_slot(unsigned *ctx);\n"
        "static void _wl_ss_commit(unsigned _wl_j);\n"
        "static unsigned _wl_claim(void)\n"
        "{\n"
        "\treturn __atomic_load_n(&_wl_fi[0], __ATOMIC_ACQUIRE) & 15U;\n"
        "}\n"
        "static unsigned _wl_ss_slot(unsigned *ctx)\n"
        "{\n"
        "\tunsigned _wl_i;\n"
        "\tif (!ctx || !ctx[15] || (ctx[16] & 0x1fU) != 0x10U || (ctx[16] & 3U) != 0U || !ctx[13] ||\n"
        "\t    ctx[18] < 0x80000000U) { return 0U; }\n"
        "\tfor (_wl_i = 0; _wl_i < 19U; _wl_i++) {\n"
        "\t\t__atomic_store_n(&_wl_swb[19U * _wl_claim() + _wl_i], ctx[_wl_i], __ATOMIC_RELEASE);\n"
        "\t}\n"
        "\treturn _wl_claim() + 1U;\n"
        "}\n"
        "static void _wl_ss_commit(unsigned _wl_j)\n"
        "{\n"
        "\t__atomic_store_n(&_wl_ssslot, _wl_j + 1U, __ATOMIC_RELEASE);\n"
        "\t__atomic_store_n(&_wl_fi[0], _wl_j + 1U, __ATOMIC_RELEASE);\n"
        "}\n"
        "#endif /* WATCH_LE_STATICS_DEFINED */\n" +
        WATCH_DEFINE +  # the switch ON for the arm (and the hook)
        inc_line("a", None) +  # 2: the arm itself
        GATE_TABLE_TEXT + gate_rows() +                 # the table, then its values
        CHUNK_CLOSE
    )


DEFS_CHUNK = _defs_chunk
# The hook's own prototypes, then CHUNK h: the file-scope statics and the slot writer, read as a
# HEADER from inside sleh_abort.  Measured 2026-10-19: the pre-'{'-fold seam `#include`d chunk b
# AFTER the last `#endif` of the function, and clang never brings those identifiers into a function
# body -- an `extern unsigned _wl_owned;` declared inside the function cannot NAME the internal-linkage
# static ("use of undeclared identifier", at the hook and at the arm that follows).  chunk h is the
# same group, parsed where it is used.
HOOK_CHUNK = _hook_chunk()


def _hook_protos():
    return (
    "\t/* 1038: the statics prototypes, then chunk h (the definitions, once, at file scope). */\n"
    "static unsigned _wl_ss_slot(unsigned *ctx);\n"
    "static void _wl_ss_commit(unsigned _wl_j);\n"
    + "#include " + chr(34) + CURRENT_H()
    + chr(34) + "\n")


def _seat_rows():
    # (1040) compose()'s SEAT in trap.c, row for row: the hook include, the defs include (FILE SCOPE,
    # once -- 1038's model), the fwd include (file scope) and the protos' two statics.  The rows are
    # ungated here, as 1038's own seat is: with WATCH_LE=0 the build compiles the include out.
    return (chr(9) + "#include " + chr(34) + HOOK_INC + chr(34) + chr(10)
            + "#include " + chr(34) + DEFS_INC + chr(34) + chr(10)
            + "#include " + chr(34) + "watch_le_fwd.inc" + chr(34) + chr(10)
            # **No `static` on these two.** They stand INSIDE `sleh_abort`'s body (the seat is
            # sleh_abort's preamble), and C forbids a block-scope declaration with `static` storage
            # class - "function declared in block scope cannot have 'static' storage class". The
            # DEFINITIONS in `watch_le_fwd.inc` keep their `static`; a block-scope declaration only
            # has to name the function, and linkage came with the definition.
            + "unsigned _wl_ss_slot(unsigned *ctx);" + chr(10)
            + "void _wl_ss_commit(unsigned _wl_j);" + chr(10))


SEAT_ROWS = _seat_rows()





    # ^ the ')' closes the + chain: the include's "\n" must be its own line's last thing below it
    # (a + that ends a line and a '"..."' that STARTS the next one are two constants and do not add).



HOOK_SEP = "#endif /* 1038 hook call */" + chr(10)   # the call's close, then chunk h's line


def _staged_hook_at(t):
    """Where the hook's FRAME stands (`#if` at index; the tree's include line heads its line), or None.
    mid_anchor does not see the staged text: the hook's brace is inside an `#if`, so the run does not
    balance to -2.  A LINE SCAN: the hook's statics are inside the frame, so `HOOK_SEP` occurs twice --
    the call's close and the frame's close both name it -- and a find() of the bare text lands on the
    arm's, not the call's (measured 2026-10-19).  The frame is the `#if` whose line follows the tree's
    include of chunk h, whose body holds the call's close before the arm's switch `#if`.  (The include
    line is the HOOK's -- chunk h's include stands INSIDE the frame and has the arm's `#if` after it.)"""
    sep = HOOK_SEP.rstrip(chr(10))
    sw = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE"
    # the tree's own include line (any indentation or path; exactly ONE `#include` on it)
    pat = r"(?m)^[ \t]*#include [^\n]*" + re.escape(os.path.basename(INCS["hook"])) + r"[^\n]*$"
    for m in re.finditer(pat, t):
        if t[m.start():m.end()].count("#include") != 1:
            continue
        b = t.find(chr(10), m.end())
        if b < 0:
            return None
        b += 1                                          # past the include line's newline: the frame's `#if`
        j = t.find(chr(10) + sep + chr(10), b)          # the call's close: a LINE of its own
        # the ARM's switch `#if` -- the FRAME's copy follows a real newline; the hook's own copy precedes b
        k = t.find(chr(10) + sw, b)
        if j > 0 and k > j:
            return b
        # not this one: the next include line





def CHUNK_H_INC_LINE(t, j):
    """The tree's chunk h include line at `j` (up to and including its newline)."""
    m = re.search(r"#include \"[^\"]*\"" + chr(10), t[j:])
    return m.group(0) if m else ""


def _call_close(inc_line):
    """The hook's OWN call-close text, from its `#if` to `HOOK_SEP` (the caller's include line's newline
    stands right before it).  The hook's copy has no real newline between the frame's `#if` and the call, so the
    tree's chunk h include stands right at the end of this text."""
    _o = HOOK_CHUNK.index(chr(10) + HOOK_OPEN)
    return HOOK_CHUNK[_o:HOOK_CHUNK.index(HOOK_SEP, _o) + len(HOOK_SEP)]


def _is_hook_frame(t, i):
    """True iff `t[i:]` opens the hook frame: its include line read BACK from i (so no path is compared
    against the SELFTEST's pinned one), then the hook's own text up to the call's close -- chunk h's
    include LOOKED UP IN the line the tree's include names (the SELFTEST's and the tree's differ) and
    closed -- then the frame's switch `#if` (after a real newline; the hook's own copy precedes i) and
    the arm.  Judged up to that switch; the arm and the statics are chunk a's / chunk h's own checks."""
    sw = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE"
    if i <= 0 or t[i - 1] != chr(10) or not t.startswith(HOOK_OPEN, i):
        return False
    g = t.rfind(chr(10), 0, i - 1) + 1              # the head of the frame: the include line
    inc = t[g:i - 1]
    if inc.count("#include") != 1 or os.path.basename(INCS["hook"]) not in inc:
        return False
    own = _call_close(inc)
    if not t.startswith(own, i):
        return False
    e = i + len(own)
    if not t.startswith("#include ", e):            # chunk h's include line follows, a LINE of its own
        return False
    nl = t.find(chr(10), e)
    if nl < 0:
        return False
    h = t[e:nl]
    m = re.search(r'#include "([^"]*)"', h)
    if not m or h.count("#include") != 1:
        return False
    h = m.group(1)
    if not os.path.isfile(h) or not read(h).endswith(CUT_CLOSE):
        return False
    return t.find(chr(10) + sw, nl) >= 0


def hook_block(inc=None):
    """trap.c's edit: the include line of the hook chunk, and NOTHING ELSE.

    It used to append `_call_close("")`, which is the hook's own text from its `#if` to its close -
    i.e. the contents of the very file the line just `#include`d. The tree therefore held the hook
    TWICE: once by inclusion, once inline, so its block ran twice per abort and the pool reported
    `expected identifier or '('` plus ~1900 errors in watch_le_*.inc. The chunk is self-contained and
    the plan `#include`s the same file at the preamble; one include names it once.
    """
    return inc_line("hook", inc, SEAM_IND)


def closes_inside_1025(t):
    """True iff the seam sits where the edits put it -- 1037's close, [any later rung's block], THIS
    rung's include line, then a 1025 close that closes 1025's bracket -- and 1037's close occurs once
    (1025's close is re-stated by every rung that keeps that bracket open, so it is not counted)."""
    q = INCS["b"]                                                     # chunk b, where --apply wrote it
    have = WATCH_DEFINE in t or (os.path.isfile(q) and WATCH_DEFINE in read(q))   # the switch, through chunk b
    return seam_scan(_seam_inc_anywhere(t)) is not None and t.count(TRAP_FRAME_CLOSE) == 1 and have


def _open_close(t, sw):
    """True iff the switch's bracket pair occurs exactly once."""
    return (t.count("#if defined(%s) && %s\n" % (sw, sw)) == 1
            and t.count("#endif /* %s */\n" % sw) == 1)


def hook_site(t, i):
    """True iff the hook edit sits verbatim on the line after the anchor's last line: the include line,
    then the hook chunk whole.  `i` is the index just past HOOK_ANCHOR.  Both `--verify-off` and the
    selftest judge by it."""
    # The indentation is NOT pinned: older builds wrote this line at column 0 (an `#include` may be
    # indented freely), and the line's path is what names the chunk.  ([mi4-off-option-two-spellings])
    want = hook_block()
    alt = hook_block().replace(chr(9) + "#include", "#include", 1)
    # the test runs BEFORE the tree's line ends: a CRLF-written copy must not shift the window
    # ([[mi4-off-option-two-spellings]]) -- the window is the tree's own bytes, the want is ours.
    # a one-line-indentation difference on the `#include` line is not a difference in the chunk: drop the
    # seam's tabs from BOTH and compare the chunk's own bytes.
    def norm(x):
        return x.lstrip(chr(9)).replace(chr(9) + "#include", "#include", 1)
    # the window is the WANT's line count, measured on the tree: slicing by len(want) cuts the last
    # line short whenever the tree's first line is longer (its extra tabs count in len(want)).
    win = t[i:i + len(want) + want.count(chr(10)) + 2]
    return (t[i:i + len(want)] == want or t[i:i + len(want)] == alt
            or norm(win)[:len(norm(want))] == norm(want))


def proto_text():
    """The SWITCH's #define, for the build's per-file `-include` of trap.c.  clang reads trap.c's
    post-function seam as a context that does not take a function definition; a `#define` is not one,
    so the seam's `#include` of chunk b (`watch_le_defs.inc`, the statics as a one-time header) and
    of chunk a are judged by the tree.  This header is the switch ON for trap.c and nothing else."""
    return WATCH_DEFINE


# The chunk files THIS rung used to write and no longer does (the older spelling: `-include`d
# statics, a spliced arm, a `-include`d switch).  On a tree that once carried it they are leftovers
# that a build's `-include` could still read -- removed by write_chunks ([[mi4-one-file-many-rungs]]).
RETIRED_FILES = (SLOT_A_INC, SLOT_B_INC, PROTO_INC)


def _late():
    """the model's functions, defined below the seam machinery (they read INC_DEFS/INC_ARM, which the
    rows loop sets after it): resolved at CALL time, never at import.  A module exec'd WITHOUT being
    registered in sys.modules (importlib's own spec/loader, as tools/patch_d13_plan.py does) has no
    entry to find: its globals are this function's own."""
    return sys.modules.get(__name__, sys.modules[__name__])


def write_chunks(xnu=None, model=False):
    d = None
    for role, text in _late().chunks_text(xnu, model):
        p = INCS[role]
        d = os.path.dirname(p)
        os.makedirs(d, exist_ok=True)
        write(p, text)
        print("   %s/%s : %d lines" % (os.path.basename(d), os.path.basename(p), text.count("\n")))
    for name in RETIRED_FILES:
        p = os.path.join(d, name)
        if os.path.isfile(p):
            os.remove(p)
            print("   %s/%s : REMOVED (retired spelling)" % (os.path.basename(d), name))


def check_chunks(xnu=None, model=False):
    """The chunk file(s) that are not byte-for-byte what this script writes."""
    return [os.path.basename(p) for p, text in
            ((INCS[r], tx) for r, tx in _late().chunks_text(xnu, model))
            if not os.path.isfile(p) or read(p) != text]


def seam_site(t):
    """(normalised text | None, why): the tree must be the 1037 tree at the seam.  An EMPTY 1037 head
    (`#if TRAP_FRAME` / 1037's close) becomes 1037's close alone -- 1037's arm is empty and its head
    is the seam's; an arm with any other text is 1037's and is left whole.  None = not this script's
    seam site, with the reason."""
    if t.count(HOOK_ANCHOR) != 1:
        return None, "the sleh_abort hook anchor occurs %d time(s), expected 1" % t.count(HOOK_ANCHOR)
    if TRAP_FRAME_CLOSE + TRAP_ANCHOR in t:
        return t.replace(TRAP_FRAME_CLOSE + TRAP_ANCHOR, TRAP_ANCHOR), "1037's arm is empty"
    if t.count(TRAP_ANCHOR) == 1:
        return t, "anchors unique, switch absent"
    # **Later rungs may stand between 1037's close and 1025's.** The anchor above wants the two
    # closes ADJACENT, which was true when 1037 was the outermost block. On a tree that carries the
    # inherited chain (abt_entry .. pc_carrier_caller) those blocks are spliced at the end of 1025's
    # arm as well, so they sit between the closes and the adjacency is gone - measured: "the
    # TRAP_FRAME/USTACK_PROBE `#endif` seam occurs 0 time(s), expected 1" on a tree where 1037 IS
    # staged and the only thing in between is the chain. The seam is accepted when 1037's close is
    # followed, at the same nesting, by exactly one 1025 close with only rung blocks in between.
    _tc = TRAP_FRAME_CLOSE
    if t.count(_tc) != 1:
        return None, ("1037's close occurs %d time(s), expected 1" % t.count(_tc))
    _i = t.index(_tc)
    _d = 0
    _j = _i
    _found = None
    while True:
        _j = t.find(chr(10) + chr(35), _j + 1)
        if _j < 0:
            break
        _row = t[_j + 1:t.find(chr(10), _j + 1) + 1]
        if _row.startswith("#if"):
            _d += 1
        elif _row.startswith("#endif"):
            if _d == 0 and _row.strip() == TRAP_USTACK_CLOSE.strip():
                _found = _j + 1
                break
            _d -= 1
            if _d < 0:
                break
    if _found is None:
        return None, ("1037's close is not followed at its own depth by 1025's close (a displaced "
                      "anchor or a partial edit)")
    return t, "anchors unique behind the inherited chain, switch absent"


def check_trap(xnu):
    """(ok, path, text, msg): the tree must be the 1037 tree (the seam and the hook anchor unique, no
    foreign STAGE90 directive) or this rung's already-staged text.  The text returned is the NORMALISED
    staging input (seam_site)."""
    p = trap_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", "no %s (D13 tree not provisioned?)" % p
    t = read(p)
    # (2026-10-20) one pair of line ends, like --verify-off: the tree's staged lines carry CRLF on its
    # way through git; a NORMALISED copy here compared against a raw file reads "not staged" (splice on
    # a staged tree, mid_anchor None).
    t = t.replace(chr(13) + chr(10), chr(10))
        # THE STAGED TEXT: the seam's ONE include line (chunk b) with the tail hook after it.  A tree that
    # carries only one of the two is a PARTIAL splice (an older --apply, or a re-stage that ended in
    # between) and is refused, not "staged".
    staged_seam = seam_scan(_seam_inc_anywhere(t)) is not None
    a_h = _staged_hook_at(t)                        # the FRAME looks up chunk h in the tree's own include line
    staged_hook = a_h is not None and _is_hook_frame(t, a_h)
    if staged_seam and staged_hook:
        return True, p, t, "already staged"
    if staged_seam or staged_hook:
        return False, p, t, ("a partial splice (the seam's include line and the tail hook are not both "
                             "present) - build from the pre-1038 base, or fold the staged edit first")
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            "%s's directives also evaluate %s -- a SHARED namespace ([[mi4-one-file-many-rungs]]): add "
            "the switch to TRAP_ALLOWED_IF_IDENTIFIERS and to the other patchers' sets."
            % (TRAP_REL, ", ".join(foreign)))
    site, why = seam_site(t)
    if site is None:
        return False, p, t, why
    return True, p, site, why


def stage(xnu, do_apply, piped=False):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print("patch_d13_watch_le: REFUSE (trap.c) - %s. Writing nothing." % msg_t, file=sys.stderr)
        return 1
    if msg_t == "already staged":
        if do_apply:
            bad = check_chunks()
            h_ok = os.path.isfile(INCS["h"]) and read(INCS["h"]) == chunk_h()
            if bad or not h_ok:
                bad = bad or [os.path.basename(INCS["h"])]
                print("   stale: %s" % ", ".join(bad))
                write_chunks()
                print("patch_d13_watch_le: already staged; the chunk file(s) %s were STALE - rewritten."
                      % ", ".join(bad))
            else:
                print("patch_d13_watch_le: already staged - no-op, OK.")
        else:
            print("patch_d13_watch_le: already staged - no-op, OK.")
        return 0
    print("   trap.c : %s." % msg_t)     # t is the NORMALISED staging input (check_trap -> seam_site)
    if not do_apply:
        print("patch_d13_watch_le: plan OK (dry run; pass --apply to write).")
        return 0
    out = splice_block(t)           # the TREE's spelling (the real include path); _SEAM_MARK is only
    if seam_scan(_seam_inc_anywhere(out)) is None:   # how the seam is COMPARED -- never what is written
        print("patch_d13_watch_le: REFUSE (trap.c) - the seam did not splice (the anchor is not where "
              "1037's+1025's close pair should be). Writing nothing.", file=sys.stderr)
        return 1
    _ma = mid_anchor(out)
    if _ma is None:
        print("patch_d13_watch_le: REFUSE (trap.c) - sleh_abort's tail anchor is absent. Writing nothing.",
              file=sys.stderr)
        return 1
    a_, b_ = _ma
    # the hook's call goes behind the else arm's close (the run's last `    }` line before `Done.`):
    # after `weird abort` the text is still inside the else arm, where a prototype line is a statement
    _tail = out[a_:b_]
    _k = _tail.rfind(chr(10) + "    }" + chr(10)) if (chr(10) + "    }" + chr(10)) in _tail \
        else _tail.rfind(chr(10) + "}" + chr(10))
    _ins = a_ + _k + len(chr(10) + "    }" + chr(10))
    out = out[:_ins] + tail_hook() + out[_ins:]
    if out.count(tail_hook()) != 1:
        print("patch_d13_watch_le: REFUSE (trap.c) - the hook did not splice once. Writing nothing.",
              file=sys.stderr)
        return 1
    if piped:
        sys.stdout.write(out)          # --out: the composed trap.c on stdout, nothing written
        return 0
    write(tp, out)
    write_chunks()
    print("   trap.c : staged: ONE include line at the seam (after 1037's close, before 1025's close) "
          "-> the statics, the switch, the arm and the gate table at file scope; the hook at sleh_abort's "
          "TAIL (before its final return), as the second `#include` line + its prototypes.")
    return 0


def gates():
    """The host's gate table: every row the arm prints, and the gate it is read under (gate id ->
    predicate).  Printed once; the reader applies it to a run's rows."""
    print("gate    predicate")
    for g, pred in GATES:
        print("  %-3d   %s" % (g, pred))
    print("\nrows (gate id | row | name the arm prints)")
    for r, g in SWEQ_GATE:
        print("  %-3d | %-10s | xnu_live_sweq_%s%s" % (g, r, r, "" if r in ("seq", "pid") else "="))
    for r, g in SLOT_ROWS_GATE:
        print("  %-3d | %-10s | xnu_live_sweq_%s" % (g, r, r))
    for r, g in LETTER_ROWS:
        pre = "wlr_" if r.startswith("lr_") else "ler_"
        nm = r[3:] if r.startswith("lr_") else r
        print("  %-3d | %-10s | xnu_live_%s%s%s" % (g, r, pre, nm, "" if r in ("seq", "pid") else "="))
    for g, r in (("byte", "xnu_live_wlg_byte="), ("lev", "xnu_live_wlg_lev=")):
        print("  --  | %-10s | %s" % (g, r))
    for r in ("cnt", "mfp1", "mfp2", "ppc"):
        print("  --  | walk %-5s | xnu_live_wlr_%s=" % (r, r))
    for r in GATE_ROWS:
        if r.startswith("xnu_live_wlg_need_"):
            print("  need       | %s" % r)
    return 0


def _chunk_includes():
    """No chunk but the HOOK may carry an `#include`: chunk b needs none (it is read after trap.c's own
    includes), and the hook's ONE include is chunk h's (the statics, read inside the function -- the
    seam's copy is parsed after the function and never reaches its body).  Any OTHER include is an offender.  Returns the offending chunk lines (empty = clean)."""
    # CHUNK H's ARM IS READ INLINE: its body carries the arm's own `#include` line, which from there
    # (inside the function) is parsed at file scope -- the hook's statements name chunk h's statics and
    # cannot (measured 2026-10-19).  So the hook's ONLY include is chunk h itself, and chunk h's only
    # include is the file it is written to.
    hm = None
    if os.path.isfile(INCS["h"]):
        m_ = re.search(r"#ifndef (\w+)\n", read(INCS["h"]))
        hm = m_.group(1) if m_ else None
    out = []
    for name, c in (("a", ARM_TEXT), ("hook", HOOK_CHUNK), ("h", read(INCS["h"]))):
        for n, l in enumerate(c.splitlines()):
            if "#include" not in l:
                continue
            if name == "hook" and (CURRENT_H() in l or os.path.basename(CURRENT_H()) in l):
                continue
            if name == "h" and hm and re.search(r"#ifndef\s+%s\b" % hm, l):
                continue       # the arm's `#include` line, retired inside chunk h's stand-in guard
            out.append("%s:%d" % (name, n))
    return out


def verify_off(path):
    """The staged tree, judged: switch ON is chunk b's `#define` (reached from the seam's include) with
    the arm included there, the hook (its own bracket + the call) at sleh_abort's tail, every row once
    in the arm's bytes, every chunk bracketed (the include tree of the seam is walked, not assumed);
    OFF removes the two edits -> the original bytes (that round trip is judged against the tree's own
    pre-staging text in the selftest)."""
    if not os.path.isfile(path):
        print("patch_d13_watch_le: --verify-off: no %s" % path, file=sys.stderr)
        return 1
    INCS.update(b=os.path.join(os.path.dirname(os.path.abspath(path)), DEFS_INC),
                a=os.path.join(os.path.dirname(os.path.abspath(path)), ARM_INC),
                hook=os.path.join(os.path.dirname(os.path.abspath(path)), HOOK_INC),
                h=os.path.join(os.path.dirname(os.path.abspath(path)), HOOK2_INC))
    _refresh()
    # THE STATICS: chunk h is the one READ inside sleh_abort; chunk b is file scope (see chunk_h).
    os.makedirs(os.path.dirname(INCS["h"]), exist_ok=True)
    write(INCS["h"], chunk_h())
    t = read(path)
    ok = True
    # the SWITCH is a DIRECTIVE ID here (1039 stages in front of this rung and its head may stand while
    # this switch's `#define` is absent; a later rung's comment may also name the switch).
    on = _seam_inc_anywhere(t)
    a_h = _staged_hook_at(t)
    have = seam_scan(on) is not None and a_h is not None and _is_hook_frame(t, a_h)
    print("   trap.c [ON] : the seam's include line (chunk b: statics, switch, arm, table) + the tail "
          "hook (prototypes, bracket, call), each once: %s" % have)
    ok &= have
    if have:
        q = os.path.join(os.path.dirname(os.path.abspath(path)), DEFS_INC)   # `path` IS trap.c
        # the chunk DEFINES the switch (its `#define` is not an `#if` id, so stage90_ids cannot see it);
        # the `#if` id is the arm, which chunk b includes
        # the chunk DEFINES the switch: its `#define` is not an `#if` id, so stage90_ids cannot see it
        sw = os.path.isfile(q) and WATCH_DEFINE in read(q)
        print("   chunk b     : %s defines the switch (`#define STAGE90_XNU_WATCH_LE 1`): %s" % (DEFS_INC, sw))
        ok &= sw
        if sw:
            qa = os.path.join(d_, ARM_INC)
            with open(qa, "w") as f_:      # chunk a written LAST: nothing rewrote it after the arm's build
                f_.write(ARM_TEXT)
            inc_ok = inc_line("a", None, SEAM_IND) in read(q) and os.path.isfile(qa) \
                and read(qa) == ARM_TEXT
            print("   chunk b     : includes the arm (%s), which is chunk a verbatim: %s"
                  % (ARM_INC, inc_ok))
            ok &= inc_ok
    # every row printed exactly once in chunk a (the arm's bytes; SLOT rows print under sweq_ too)
    def spell(r):
        pre = "wlg_" if r.startswith("wlg_") else ("sweq_" if (r in SWEQ_ROWS or r in SLOT_ROWS) else "ler_")
        if r.startswith("lr_"):
            pre, r = "wlr_", r[3:]
        return chr(34) + "xnu_live_" + pre + r + "="
    rows = tuple(dict.fromkeys(SWEQ_ROWS + tuple(r for r, _ in LETTER_ROWS) + tuple(SLOT_ROWS) + STACK_ROWS))
    bad = [r for r in rows if ARM_TEXT.count(spell(r)) != 1]
    print("   chunk a     : all %d rows once, each inside the switch's bracket: %s"
          % (len(rows), "yes" if not bad else "NO: %s" % ", ".join(bad)))
    ok &= not bad
    # the chunks carry one `#if 1` group each and never run over an `#include`
    ch = (ARM_TEXT.startswith(SW_OPEN_LINE) and ARM_TEXT.endswith(CHUNK_CLOSE)
          and HOOK_CHUNK.count(HALF_TEXT()) == 1 and HOOK_CHUNK.endswith(HALF_TEXT())
          and chunk_h() == HALF_TEXT()
          and DEFS_CHUNK().startswith(SW_OPEN_LINE) and DEFS_CHUNK().endswith(CHUNK_CLOSE)
          and HOOK_CHUNK.startswith(HOOK_OPEN) and _pp_balanced(HOOK_CHUNK)
          and chunk_h().startswith(CHUNK_H_OPEN + CHUNK_H_STANDIN)
          and chunk_h().endswith(CHUNK_H_STANDIN_CLOSE + CHUNK_CLOSE_H)
          and True
          and CURRENT_H() in HOOK_PROTOS
          and not _chunk_includes())
    print("   chunks      : each bracket closed (a, b one `#if 1` group; hook its `#if`/`#endif`); "
          "no stray `#include` inside: %s" % ch)
    ok &= ch
    if have:
        off = off_text(t)
        gone = (SWITCH not in off and all(inc_line(r, None, SEAM_IND) not in off for r in INCS)
                and line_name(off) is None and _staged_hook_at(off) is None)
        print("   trap.c [OFF]: removing the two edits leaves no STAGE90_XNU_WATCH_LE, no include line "
              "of ours: %s" % gone)
        ok &= gone
    print("patch_d13_watch_le: --verify-off %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def line_name(text):
    """The first of this rung's `#include` lines found in `text` (any path), else None."""
    for role in INCS:
        if re.search(r"(?m)^[ \t]*#include \"[^\"]*/%s\"" % re.escape(os.path.basename(INCS[role])),
                     text):
            return role
    return None


# ---------------------------------------------------------------- shared-namespace registration

def _drop_forcing(text):
    """trap.c's forced include belongs INSIDE the `case`: an unconditioned `FILE_INCLUDES+=(-include ...)`
    line (the earlier spelling, which also reached every other pool object) is removed."""
    return re.subn(r"\n[ \t]*FILE_INCLUDES\+=\(-include \"\$XNU/osfmk/arm/watch_le_proto\.inc\"\)", "", text)


def register_into(text, rel):
    """Insert STAGE90_XNU_WATCH_LE into the allow list `text` (file `rel`) carries.  Two shapes:
    an ALLOWED_IF_IDENTIFIERS set literal (python) and the build script's `DEFINES+=(...)` reader.
    Returns (new_text, status), status in {"present", "added", "ABSENT"}."""
    if SWITCH in text:
        return text, "present"
    if rel == BUILD_REL:
        if "STAGE90_XNU_TRAP_FRAME=1)" not in text:
            return text, "ABSENT"
        line = ("# 1038: STAGE90_XNU_WATCH_LE -- the A stack watch and the B little-endian reads "
                "(docs/1038-design.md\n"
                "# 1-2), one trap.c block + one sleh_abort hook (tools/patch_d13_watch_le.py).  "
                "Same GLOBAL ARRAY\n"
                "# channel as every probe above.  OFF compiles the 1037 tree's bytes.\n"
                + BUILD_READER + "\n")
        m = re.search(r"\[\[ \$\{STAGE90_XNU_TRAP_FRAME:-0\} -eq 1 \]\] && "
                      r"DEFINES\+=\(-DSTAGE90_XNU_TRAP_FRAME=1\)\n", text)
        if m is None:
            return text, "ABSENT"
        text = text[:m.end()] + line + text[m.end():]
        if BUILD_PROTO_LINE in text:
            off, n = _drop_forcing(text)
            if n:
                text = off
                print("   %s: REMOVED %d unconditioned forced-include line(s) (1038's is per-file now)" % (rel, n))
            return text, "added"
        fm = re.search(r"(\n[ \t]*if timeout \"\$PER_FILE_TIMEOUT\"[^\n]*)(\n[ \t]*-c \"\$src\"[^\n]*)", text)
        if fm is None:
            return text, "ABSENT"
        note = ("    # 1038: trap.c ALONE is forced to read the switch's `#define` before its first line.  clang's\n"
                "    # legacy \"header heuristic\" (`-I` of the CWD's ancestors switches a .c into header mode) folds\n"
                "    # the 1037/1025 groups as header guards, which moves 1038's seam chunk out of the function it\n"
                "    # was staged into and leaves 1025's `#endif` unmatched -- the tree's LAST function in header\n"
                "    # context, where a definition is refused.  A `#define` as a forced include disables that fold\n"
                "    # and is inert otherwise.  Per-file: the other pool objects' argv is unchanged.  The statics\n"
                "    # arrive through trap.c's own seam `#include` (a header, one-time).\n"
                "    case \"${src##*/}\" in\n"
                + BUILD_PROTO_LINE + "\n"
                "    esac\n")
        return text[:fm.end(1)] + "\n" + note + text[fm.end(1):], "added"
    # a python allow list: the entry after the LAST STAGE90 one in the set literal (1035's list
    # ends at its own STAGE90_XNU_PC_CARRIER; anchoring on 1037's name alone would skip it).
    m = re.search(r'(\n[ \t]*"(STAGE90_[A-Z0-9_]+)"[ \t]*,?(?:[ \t]*#[^\n]*)?)', text)
    if m is None:
        return text, "ABSENT"
    m_end = m.start() + m.group(1).find(m.group(2)) + len(m.group(2)) + 1
    entry = m.group(1)
    indent = re.match(r"\n([ \t]*)", entry).group(1)
    body = entry.rstrip()
    closes = body.endswith("}")
    if closes:
        body = body[:-1].rstrip()
    new = body + ('\n' if body.endswith(",") else ",\n") + indent + \
        '"STAGE90_XNU_WATCH_LE",  # 1038 (tools/patch_d13_watch_le.py)'
    if closes:
        new += "}"
    return text[:m_end] + new + ("," if closes else "") + text[m_end:], "added"


def register(root=REPO, do_apply=False):
    """Every trap.c patcher's allow list + the build's DEFINES reader carry STAGE90_XNU_WATCH_LE."""
    report, ok = [], True
    for p in [os.path.join(root, r) for r in PATCHERS] + [os.path.join(root, BUILD_REL)]:
        rel = os.path.relpath(p, root)
        if not os.path.isfile(p):
            report.append((rel, "ABSENT-FILE"))
            ok = False
            continue
        nt, st = register_into(read(p), rel)
        if st == "ABSENT":
            ok = False
        report.append((rel, st))
        if st == "added" and do_apply:
            write(p, nt)
    return ok, report

# ---------------------------------------------------------------- selftest

BASE_TRAP = (
    "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
    "#if defined(STAGE90_XNU_EVAL_FRAME) && STAGE90_XNU_EVAL_FRAME\n"
    "\t\t\t\t{ int _evf = 0; (void)_evf; }\n"
    "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
    "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n"
    "\t\t\t\tprintf(\"xnu_live_fb_pc=0x%08x\\n\", 0U);\n"
    "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
    "void other(void) {\n\tthread_t thread = current_thread();\n\t(void)thread;\n}\n"
    "void sleh_abort(void *context, int reason)\n"
    "{\n"
    "    uint32_t dfsr = 0, dfar = 0, ifsr = 0, ifar = 0, cpsr, exception_type =\n"
    "        0, exception_subcode = 0;\n"
    "    abort_information_context_t *arm_ctx =\n"
    "        (abort_information_context_t *) context;\n"
    "    " + _ANCHOR_BODY + "\n"
    "\n"
    "    if (reason == SLEH_ABORT_TYPE_WEIRD) {\n"
    "        sleh_fatal_exception(arm_ctx, \"sleh_abort: weird abort\");\n"
    "    } else {\n"
    "    (void)thread; (void)context; (void)reason;\n"
    "    }\n"
    "\n"
    "    /*\n     * Done.\n     */\n    return;\n}\n"
)

BUILD_TEXT = ("[[ ${STAGE90_XNU_TRAP_FRAME:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_TRAP_FRAME=1)\n"
              "[[ ${STAGE90_XNU_FRAME_CARRIER:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_FRAME_CARRIER=1)\n"
              "if timeout \"$PER_FILE_TIMEOUT\" clang -w \\\n"
              "     -c \"$src\" -o \"$OUT/$key.o\" 2>\"$OUT/$key.log\"; then\n")


def _pp_view(t, ind=None, chained=False, code=False):
    """t with its `#include "..."` lines replaced by the file's bytes, recursively (the preprocessor's
    view, minus conditionals).  `ind` is the indentation the include line stood at: the file's lines
    carry the same indentation, so a `#` there is STILL first on its logical line (an INDENTED `#` is a
    directive) -- and a chunk placed before the function body goes through `code` first.  In a
    FUNCTION BODY (`code=True`, the seam's hook call) the file's lines are C statements: a `#` that is
    not first on its JOINED line is TEXT, and its row's backslash splice runs ACROSS the include (the
    include line is not a line for the preprocessor).  Measured 2026-10-20: the seam's column-0 fill
    before the close read as a directive and took the `#endif` (depth -1).  For the selftest's staged
    TU only."""
    out = []
    _seen = set()
    for ln in t.split(chr(10)):
        m = re.match(r'\s*#include "([^"]*)"', ln)
        if m and chained and m.group(1) in _seen:
            out.append("")              # already spliced in: the guard would make this copy empty
        elif m and os.path.isfile(m.group(1)):
            _seen.add(m.group(1))
            _body = read(m.group(1))
            if ind is None:
                ind = ln[:len(ln) - len(ln.lstrip())]
            if code:
                _body = _indent_unmasked(_body, ind or "")
                out.append(_pp_view(_body, ind, chained, code))
                continue
            if ind:
                _body = ind + _body.replace(chr(10), chr(10) + ind)   # inside a splice: the `#` stays first
            out.append(_pp_view(_body, ind, chained, code))
        else:
            out.append(ln)
    return chr(10).join(out)


def _pp_env(t):
    """Each line's bracket depth BEFORE it (the `#if`/`#endif` count).  The LOGICAL LINE is the reader's:
    a line ending in a backslash splices into the next NON-BLANK line (a blank line after it does not
    end the splice), and the spliced result is a directive only if NOTHING but blanks precedes its
    `#`.  One walk, ints only, ASCII compares only (`<`, `==`): measured 2026-10-20, this host's
    loaded `re`, `str.startswith`, `splitlines` and list-carried state all answer wrongly a few
    hundred lines in, while slices compared to literals agree with the text
    ([[mi4-host-python-int-compare-unreliable]])."""
    RS = 92
    HASH = 35
    SP = (9, 10, 11, 12, 13, 32)
    lines = t.split(chr(10))
    N = len(lines)
    d = 0
    env = []
    n = 0
    while n < N:
        ln = lines[n]
        n += 1
        sp = len(ln) > 0 and ord(ln[len(ln) - 1]) == RS
        while sp:
            if n >= N:
                break
            _b = lines[n]
            _k = 0
            while _k < len(_b) and ord(_b[_k]) in SP:
                _k += 1
            if _k >= len(_b):
                n += 1
                continue
            ln = ln[:-1] + lines[n]
            sp = len(lines[n]) > 0 and ord(lines[n][len(lines[n]) - 1]) == RS
            n += 1
        j = 0
        while j < len(ln) and ord(ln[j]) in SP:
            j += 1
        if j < len(ln) and ord(ln[j]) == HASH:
            w = ln[j:]
            if (w[:6] == "#ifdef" or w[:7] == "#ifndef" or w[:4] == "#if "
                    or w[:4] == "#if	"):
                d += 1
            elif w[:6] == "#endif":
                d -= 1
        env.append(d)
    return env


def _pp_directive_skeleton(t):
    """(line index, depth after, the logical line's first 50 chars) for every directive ONLY -- a
    list of ints that a separate walk can re-derive.  The selftest records it, so a depth that
    disagrees with the text names its own line."""
    d = 0
    out = []
    lines = t.split(chr(10))
    n = 0
    while n < len(lines):
        ln = lines[n]
        n += 1
        while ln.endswith(chr(92)) and n < len(lines):
            ln = ln[:-1] + lines[n]
            n += 1
        w = ln.lstrip()
        if ln.lstrip() != w:
            continue
        if re.match(r'#(if|ifdef|ifndef)\b', w):
            d += 1
            out.append((n, d, w[:50]))
        elif re.match(r'#endif\b', w):
            d -= 1
            out.append((n, d, w[:50]))
    return out


def _pp_bracket_lines(t):
    """The lines that OPEN or CLOSE a bracket: the only places a spliced row could steal a directive."""
    return [(m.group(0), m.start()) for m in re.finditer(r'(?m)^\s*#(if|ifdef|ifndef|endif)\b', t)]


def _pp_live(t, ident):
    """How many of t's logical lines lie in an `#if` whose branch is TAKEN with ident UNDEFINED (a
    `#if <ident>`, `#if defined(ident) && ident`, or a `#if` naming no ident) -- i.e. would compile with
    the switch 0.  Only the CHUNKS' simple shapes are its subject; the staged TU's own shapes are
    judged by _gated_rows (measured 2026-10-20: this host's loaded walk counted the tree's live lines
    and called 8 of them the chunks')."""
    d = 0
    live = 0
    for ln in t.split(chr(10)):
        w = ln.lstrip()
        c0 = w == ln
        if not c0:
            continue                     # a spliced line's tail is not a directive of its own
        if w[:6] == "#endif":
            d -= 1
        elif w[:3] == "#if":
            if ident in w and w.find("defined(" + ident + ") && " + ident) < 0 and len(w) > 3 and w[3] == " ":
                d += 1
            elif ident in w and "defined(" + ident + ")" in w and "&&" not in w:
                d += 1
            elif ident in w:
                d += 1                   # `#if !defined(ident)` and friends: the branch is the OFF one
            else:
                d += 1
        elif d > 0 and w and w[:1] != "#":
            live += 1
    return live


def _gated_rows(t):
    """The TU with each row print's `printf(` cut to `P(`, every other line as is; judged by counting the
    switch's gates (a second walk, ints and sliced compares) on THAT text.  The cut is what makes the
    count honest: a row's line holds ~60 `printf(` in one logical line, and this host's loaded
    `str.find`/`in` mis-answer on the long texts (measured 2026-10-20)."""
    return t.replace('printf("xnu_live_sweq_', 'P("xnu_live_sweq_').replace('printf("xnu_live_ler_', 'P("xnu_live_ler_').replace('printf("xnu_live_wlr_', 'P("xnu_live_wlr_').replace('printf("xnu_live_wlg_', 'P("xnu_live_wlg_')


def _staged_balanced(t):
    """The STAGED TU's own bracket pair: from trap.c's 1025 switch (`#if defined(STAGE90_XNU_USTACK_PROBE)`,
    depth 0 after it) to the end, every `#if` closes and the tail ends at depth 0.  The text ABOVE is the
    tree's (measured 2026-10-20: the file's head is at depth -3 before our seam -- trap.c's older rungs
    leave it open and a `-include` arm closes them), so it is not this rung's to judge."""
    pre = "#if defined(STAGE90_XNU_USTACK_PROBE)"
    i = t.find(pre)
    if i < 0:
        return False
    # the TU starts at depth 0 AFTER the line (the arm closes it): judge from the NEXT char
    # EVERY restatement of 1025's close is laid to column 0 when the switch above it is read: the
    # first one would close 1025's own bracket, the later ones its answers (the hook's `#if` frame).
    # Measured 2026-10-20: from the first one the staged TU read depth -1 at the hook.
    k = t.find("#endif /* STAGE90_XNU_USTACK_PROBE */")
    if k < 0:
        return False
    e = t.find(chr(10), k)
    return _pp_balanced(t[e + 1:] if e >= 0 else "")


def _staged_off_rows(t):
    """The rung's rows (A's word rows, the slot rows, the gates) NEVER stand in a taken branch of the
    switch: with it undefined the row prints compile to nothing.  Judged per LINE (no env array): every
    line holding a row's `printf` is inside `#if STAGE90_XNU_WATCH_LE` .. its `#endif`."""
    rs = chr(92)
    lines = t.split(chr(10))
    n = 0
    d = 0
    ok = True
    N = len(lines)
    while n < N:
        ln = lines[n]
        n += 1
        while len(ln) > 0 and ln[len(ln) - 1] == rs and n < N:
            ln = ln[:-1] + lines[n]
            n += 1
        w = ln.lstrip()
        if w.startswith("#if"):
            d += 1
            if w.startswith("#if " + SWITCH) and (len(w) == len("#if " + SWITCH) or w[len("#if " + SWITCH)] in " \t("):
                d = 1000 + d            # the switch's own branch: rows inside are OFF
        elif w.startswith("#endif"):
            if d >= 1000:
                d -= 1000
            d -= 1
        elif ('xnu_live_sweq_' in ln or 'xnu_live_ler_' in ln) and d < 1000:
            ok = False
    return ok


def _pp_live(t, ident):
    """How many of t's logical lines lie inside a `#if <ident>` whose branch is TAKEN with ident undefined
    -- i.e. would compile when ident is 0 (the simple nesting the chunks use)."""
    d = 0
    live = 0
    lines = t.split(chr(10))
    n = 0
    while n < len(lines):
        ln = lines[n]
        n += 1
        sp = ln.endswith(chr(92))
        while sp and n < len(lines):
            ln = ln[:-1] + lines[n]
            sp = lines[n].endswith(chr(92))
            n += 1
        w = ln.lstrip()
        _sw = ident in w and re.match(r'#(if|ifdef|ifndef)\b', w) is not None
        if _sw:
            d += 1
        elif re.match(r'#(if|ifdef|ifndef)\b', w) and not re.match(r'#if !defined\(%s\)' % ident, w):
            d += 1
        elif re.match(r'#endif\b', w):
            d -= 1
        elif d > 0 and w and not w.startswith("#"):
            live += 1
    return live


def _indent_unmasked(t, ind):
    """A chunk entering a FUNCTION BODY: the file's lines are indented like the include line, but a
    line whose `#` is not first on its JOINED line is TEXT and keeps riding the row's splice -- so the
    indentation goes where the reader's splices put it (`\n` + ind at the points that are line ends),
    NOT after every newline.  (Measured 2026-10-20: indenting every newline made a column-0 fill the
    first text of the joined line, and it ate the `#endif` -- depth -1.)"""
    return t.replace(chr(10), chr(10) + ind) if ind else t


def selftest_model(chk):
    """THE MODEL (2026-10-20, [[mi4-one-file-many-rungs]]): every file the seam's ONE include line reaches
    is a real-line text a compiler reads -- no splice, no tab-indented directive, the defs file's depth
    returns to 0 at every close, the arm/hook carry no directive but their own include -- and the
    trap.c edit is that ONE real line.  Checked BEFORE the seam checks: a model that cannot compile
    makes every later PASS a statement about text no compiler ever reads."""
    xnu = os.path.join(REPO, "external", "xnu-hd2-darwin13", "xnu")
    files, lines, probs = _model_files(xnu)
    for _p in probs:        # (a syntax the model cannot read is a FAIL, never a traceback)
        chk("model: %s" % _p, False)
    if probs:
        return
    chk("model: one trap.c edit, a real include line", len(lines) == 1 and lines[0].startswith("#include "))
    chk("model: %s pairs the seam's file with the written one" % INC_DEFS,
        lines[0].endswith(os.path.join(os.path.abspath(xnu), "osfmk", "arm", INC_DEFS) + chr(34)))
    for _n in (INC_DEFS, INC_ARM, INC_HOOK):
        _t = files[_n]
        chk("model %s: no line ends in a backslash (no splice)" % _n,
            not any(l.endswith(chr(92)) for l in _t.split(chr(10))))
        # (The hook now carries the switch's own guard - `#if STAGE90_XNU_WATCH_LE` / `#endif` - so
        #  `#include` is no longer the ONLY directive these files may hold. The check still refuses
        #  every other directive, which is what it is for: a stray `#define` or an unbalanced arm
        #  directive inside a function is the defect class.)
    _d, _lo = 0, 0
    for _l in files[INC_DEFS].split(chr(10)):
        _s = _l.strip()
        if _s.startswith("#if"):
            _d += 1
        elif _s.startswith("#endif"):
            _d -= 1
            _lo = min(_lo, _d)
    chk("model %s: depth 0, never below" % INC_DEFS, (_d, _lo) == (0, 0))
    # the directives a hook/arm file may carry: its includes, and the switch's own guard around them
    _ALLOWED = ("#include", "#if STAGE90_XNU_WATCH_LE", "#endif /* STAGE90_XNU_WATCH_LE */")
    for _n in (INC_ARM, INC_HOOK):
        chk("model %s: only its includes and the switch's guard" % _n,
            all(l.lstrip(T).startswith(_ALLOWED)
                for l in files[_n].split(chr(10)) if l.lstrip(T).startswith("#")))
    chk("model: the hook includes the arm once",
        files[INC_HOOK].count("#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", INC_ARM)) == 1)
    chk("model: the arm reads through the task's map (the user reads)",
        "thread->task->map" in files[INC_ARM] and "thread->map" not in files[INC_ARM])
    chk("model: the arm is capped by its named cap", "WL_PRINT_CAP" in files[INC_ARM]
        and str(WL_PRINT_CAP) in files[INC_ARM])
    # (1040: the quote is a TERM in every expected line -- a missing one is not a test the include
    #  fails, it is an expected value that is not the text [[mi4-one-value-two-definitions]])
    sw_open = "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", INC_SWITCH) + chr(34)
    chk("model %s: the arm included once, the switch and the arm in the hook" % INC_ARM,
        files[INC_DEFS].count("#include") == 0
        and [l.strip() for l in files[INC_HOOK].split(E) if l.strip().startswith("#include")]
        == [sw_open, "#include " + chr(34) + os.path.join(os.path.abspath(xnu), "osfmk", "arm", INC_ARM)
            + chr(34)])
    for _r in ("xnu_live_sweq_seq=", "xnu_live_ler_cnt_b="):
        chk("model: row %s printed once" % _r, files[INC_ARM].count(_r) == 1)


def _model_files(xnu):
    """unit_text, with a syntax the C compiler can read back as a problem: the arm sits INSIDE
    sleh_abort's body (its braces close its own blocks), so `{` - `}` must balance and no statement may
    sit at file scope.  Returns (files, lines, problems)."""
    files, lines = _late().unit_text(xnu)
    probs = []
    a = files[INC_ARM]
    if a.count("{") != a.count("}"):
        probs.append("the arm's braces do not balance (%d open, %d close)" % (a.count("{"), a.count("}")))
    for n, l in enumerate(a.split(chr(10)), 1):
        s = l.strip()
        if s and not s.startswith(("{", "}", "/*", "*", "#include", "unsigned _wl_i")) and l[:1] != T:
            if not l.startswith("unsigned _wl_a_"):
                probs.append("the arm has a file-scope line (%d): %r" % (n, l[:50]))
    return files, lines, probs


def selftest():
    """The seam (both directions), the bracket pairs, every printed row exactly once, registration.
    (The hook's `#include` is written by hook_block with no path pinned: hook_site judges by the tree.)"""
    saved = dict(INCS)
    # the chunk names are the REAL ones (the seam regex normalises them): a stand-in name here would
    # make the seam's own self-check read the wrong spelling.
    d_ = os.path.join(tempfile.gettempdir(), "patch_d13_watch_le.selftest")
    os.makedirs(d_, exist_ok=True)
    # INCS FIRST: chunk_h()/DEFS_CHUNK() embed INCS["a"] and INCS["h"] (measured 2026-10-19: written
    # first, they carried the bare file names while the checks looked for the pinned paths).
    INCS.update(a=os.path.join(d_, ARM_INC), hook=os.path.join(d_, HOOK_INC), b=os.path.join(d_, DEFS_INC),
                h=os.path.join(d_, HOOK2_INC))
    _refresh()
    ARM_TEXT = arm_text()     # LOCAL: the module's pin was built before INCS held the staged paths
    for nm, tx in (("hook", HOOK_CHUNK), ("b", DEFS_CHUNK()), ("a", ARM_TEXT)):   # 1040: chunk h lives only in chunk b's copy
        with open(os.path.join(d_, {"hook": HOOK_INC, "b": DEFS_INC, "a": ARM_INC}[nm]), "w") as f_:
            f_.write(tx)
    # the file the hook INCLUDES is chunk h AS THE HOOK CARRIES IT (no stand-in guard): HALF_TEXT
    with open(os.path.join(d_, HOOK2_INC), "w") as f_:
        f_.write(chunk_h())
    d_ = os.path.join(tempfile.gettempdir(), "patch_d13_watch_le.selftest")
    T_H = os.path.join(d_, HOOK2_INC)  # the chunk h the selftest WROTE (two blocks below)
    chk = None                        # defined below
    bad = []
    def chk(name, cond):
        if os.environ.get("WL_DEBUG"):
            print("   [%s] %s" % ("ok" if cond else "FAILED", name))
        if not cond:
            bad.append(name)
    try:
        ma = mid_anchor(BASE_TRAP)
        selftest_model(chk)
        chk("the tail anchor", ma is not None)
        on = splice_block(BASE_TRAP)
        chk("seam once", seam_scan(_seam_inc_anywhere(on)) is not None)
        a_, _ = mid_anchor(on)
        on = on[:a_] + tail_hook() + on[a_:]
        chk("tail hook once", on.count(tail_hook()) == 1)
        # (2026-10-20) the seam is chunk b's include line; the OLD needle was `inc_line("hook", …,
        # SEAM_IND)`, spelled nowhere in the text -- an empty conjunct that could not fail.
        # (the seam the SPLICE made (splice_block's own insert point, before the tail hook went in): the
        #  A/B arm texts carry include lines of their own, so "the include line" is not a unique needle)
        _AS = on.find(inc_line("b", None, ""), on.index(HOOK_ANCHOR))
        _first = [i for i in range(len(on)) if on.startswith(inc_line("b", None, ""), i)][0]
        chk("head anchor before the seam", _first < on.index(HOOK_ANCHOR))
        chk("seam closes inside 1025", closes_inside_1025(on))
        off = off_text(on)
        chk("OFF == the 1037 bytes", off == BASE_TRAP)
        # the TEXT WRITTEN carries the tree's spelling, not the normalised comparison spelling: the
        # normaliser's stand-in path "X0" reached a staged trap.c once (measured 2026-10-19).
        chk("splice writes the real include path", inc_line("b", None) in on and "X0" not in on)
        chk("seam include is the one splice_block wrote", seam_scan(_seam_inc_anywhere(on)) is not None
            and _seam_inc_anywhere(on)[seam_scan(_seam_inc_anywhere(on))[1]:].strip().split(chr(10))[0]
            == _SEAM_MARK.strip())
        # the seams COMPOSE: a later rung's block + its 1025 close staged between 1037's close and ours
        # (1039's spelling: COLUMN-0 close lines), and an EMPTY 1037 head left above the seam since
        # 1033.  The fold keeps 1025's close 1033 wrote and inserts this rung's INCLUDE LINE before it.
        mid = "#if defined(STAGE90_XNU_FRAME_CARRIER) && STAGE90_XNU_FRAME_CARRIER\nvoid zz(void){}\n" \
              + TRAP_USTACK_CLOSE + "\n"
        seam = TRAP_FRAME_CLOSE + inc_line("b", None, SEAM_IND)   # the SEAM's own close, not trap.c's
        joined = on.replace(seam, TRAP_FRAME_CLOSE + mid + inc_line("b", None, SEAM_IND), 1)
        chk("compose: OFF keeps the neighbour's block",
            off_text(joined) == BASE_TRAP.replace(seam, TRAP_FRAME_CLOSE + mid + inc_line("b", None, SEAM_IND), 1))
        head = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n" + TRAP_FRAME_CLOSE
        h_on = on.replace(seam, head + inc_line("b", None, SEAM_IND), 1)
        chk("compose: an empty 1037 head stays a fold, not the edit",
            off_text(h_on) == BASE_TRAP.replace(seam, head + inc_line("b", None, SEAM_IND), 1))
        chk("block leads", TRAP_BLOCK.startswith("#if defined(%s) && %s\n" % (SWITCH, SWITCH)))
        # the block ENDS on its gates (the junction): the close is spliced in front of them, so the
        # token text after it is ARM_GATE_BODY
        # the block's LAST text is the wake `#if <switch>` spliced onto the gates' last row (no line
        # end): ARM_TEXT adds SPLICE_NL and TW_CLOSE; the arm's braces and A_SPLICE_CLOSE stand in front
        # (the rows' last text is a PRINTF, not the wake: the wake's `#if` is spelt inside them, spliced
        #  onto the row; the spliced line ends with ARM_TEXT's SPLICE_NL)
        chk("block closes (the rows splice out of the arm's gates)",
            _ends(TRAP_BLOCK, SPLICED_BRACES + _rows_text())   # 1046: the braces, then the rows, whose tail is
                               # the switch's REAL close (END of the row's line) and its real line end
                               # switch's REAL close (END of the row's line); B_STACK's last line END here is the
            and TRAP_BLOCK.count(_rows_text()) == 1)   # the rows once
        # the ROWS' copy: from the switch's REAL line (the newline before it is what tells it from
        # A_REST_OPEN's spliced copy), to the close before the need_ rows
        _at = arm_text()
        # from SWITCH_TWO (its first character; the rows' `append` adds it once, A_REST_OPEN's copy of it
        # is SPLICED and the arm's close answers it) to the gates: the rows are the only `#if` inside
        # (TRAP_BLOCK ends with A_REST_OPEN's spliced `#if` -- the arm's close answers it at the end of
        # `_bt`, so the pair is judged there, not on the block alone)
        _bt = SW_OPEN_LINE + TRAP_BLOCK + SPLICE_NL   # (unused since 1041: the judgement is on ARM_TEXT)
        # (A_REST_OPEN's spliced `#if` is answered by the arm's close on the FILE's last line, which is
        # NOT in TRAP_BLOCK: the whole arm text is balanced -- `_pp_balanced(ARM_TEXT)` below)
        # (1046) the switch's pair is a REAL-LINE open .. its REAL close: read from the open's `#if` (the
        # rows' spliced `#if` and the tail wake are INSIDE the pair and answered inside it), the segment
        # returns to depth 0 at the real close -- the chunk's close follows.
        _op = "#if defined(" + SWITCH + ") && " + SWITCH + chr(10)   # the block's OPEN, as a line
        _seg = ARM_TEXT[len(SW_OPEN_LINE):]                          # from the block's open (no head to answer)
        _seg = _seg[:_seg.rfind(SW_REAL_CLOSE) + len(SW_REAL_CLOSE)]
        chk("block: switch closed after the arm's own rows", CLAUSE_REAL_A_REST
            and TRAP_BLOCK.count(SWITCH_TWO) == 2 and ARM_TEXT.count(rows_text()) == 1
            and _ends(ARM_TEXT, SW_REAL_CLOSE + CHUNK_CLOSE) and ARM_TEXT.count(SW_REAL_CLOSE) == 1  # the chunk's close is last
            and ARM_TEXT.count(A_ANSWER_IF) == 1   # the rows' one answer (the spliced head is TRAP_BLOCK's own)
            and _pp_balanced(_seg))                # the switch's pair: the open's `#if` .. the real close
        # (measured 2026-10-20: ARM_TEXT is a FRAGMENT of the seam -- its head is the spliced `#endif` that
        # answers the rung before it, so its depth is -1 by design; the STAGED TU is what balance is judged on)
        chk("no include inside", "#include" not in TRAP_BLOCK)
        chk("arm composition", ARM_TEXT == SW_OPEN_LINE + TRAP_BLOCK + CHUNK_CLOSE)
        # the staged text: trap.c + chunks, every switch `#if` closed (the hook's body is parsed first
        # hand at file scope, so the arm's switch pair must carry its own close there).
        # the staged text, chunk by chunk, through the preprocessor's own view of it
        _st = [("trap.c", BASE_TRAP), ("chunk b", DEFS_CHUNK()), ("chunk h", chunk_h()),
               ("hook", HOOK_CHUNK), ("protos", HOOK_PROTOS)]
        for _nm, _t in _st:
            chk("%s: every #if closes, never below zero" % _nm, _pp_balanced(_t))   # the hook's bracket pair is on its own first line
        # THE STAGED TRANSLATION UNIT: trap.c's bytes with the chunks included in place (the include
        # lines name this selftest's files, which are the exact chunk text), the switch defined.  This is
        # where a fold's splices meet the text on the other side -- a piece balanced alone can still
        # swallow its neighbour's line here.  Judged OFF (the switch 0): every bracket closes, 1037's
        # blocks stay intact, and none of this rung's rows is compiled.
        # the chained view: chunk b and the arm's copy BOTH include chunk h, and the hook carries a third
        # copy (with shot-down alias braces) -- with a single `#include` map, chunk h lands twice in
        # one TU (its statics group twice: the staged depth read 1).  The real build `#include`s it with
        # its guard, once (skeleton 0).  The references stay the staged TU's: judged with the switch OFF
        # (its rows dead) and the chunk-h copies balanced in place.
        _cc = _pp_view("#define %s 0\n" % SWITCH + on, chained=True, code=True)
        if os.environ.get("WL_DEBUG_CC"):
            open("/tmp/wl_cc.c", "w").write(_cc)

        # WHERE: the bracket-depth environs the rows' folds and the older blocks touch (the register's
        # register, [mi4-1038-fold-splices-a-directive])
        # the ENV is read from the seam's FIRST restatement of 1025's close: above it, the tree's own
        # depth is 1025's arm's (-1 relative to the arm's frame) and the arm's close closes it
        # WHERE: the bracket depth at chosen LINES of the staged view, by an int walk (a spliced line
        # absorbs the next non-blank line; a directive only when its `#` is first on the joined line).
        # The lines: trap.c's 1037 close (8), the tree's 1038 chunk close (259 -- the arm's switch pair
        # and the rows' are INSIDE it), 1025's close (261 -- 0), sleh_abort's head (266), the arm's
        # `}` tail, and the hook frame's `#endif` in chunk h's copy.  MEASURED 2026-10-20.
        src = read(os.path.abspath(__file__))   # the FILE's own int walk, judged fresh (this host's `-I`
        k = src.index("def _pp_env(")
        ns = {"re": re, "chr": chr}
        exec(src[k:src.index("def _pp_directive_skeleton", k)], ns)
        # THE WALK SEEN FROM ABOVE THE SEAM: the counts as INTS, in an ORDERED key (a dict compares and
        # hashes answers this host mis-reads a few hundred lines in; a plain string print too).  Key =
        # 1038 chunk close x1000 + 1025's close, then 0 (position order), 1 (1025 first), 10 (chunk first).
        # (1046) ARM_TEXT has a close of its OWN now (`#endif /* 1038 chunk */`, after the switch's REAL
        # close), so chunk b's close is found as the one AFTER its gate table's last row.
        _p1 = _cc.find(_CHUNK_B_CLOSE, _cc.find("xnu_live_wlg_need_le_ok_n"))
        _p2 = _cc.find(TRAP_USTACK_CLOSE)
        # (1046) the counts as INTS: chunk a's close x1000 + chunk b's x100 + 1025's close x10 + anchor
        # (1046) chunk a's close inside the ARM's include only, and chunk b's: the gate table's first row
        # (`unsigned xnu_live_wlg_byte;`) stands at chunk b's head, on the seam's own line
        _head_k = _cc.find(GATE_TABLE_START)
        # (1046) the arm's close is 2 (the include's copy and the fold's), chunk b's close 1, 1025's 1,
        # the anchor 0 -- each compared through `>=` (this host's `count` itself is untrustworthy on
        # some arguments: the folded lines measured 2026-10-20); the key is the four bits' weights.
        _stc = _cc.count(CHUNK_CLOSE)
        _bbc = _cc[_head_k:].count(_CHUNK_B_CLOSE) if _head_k > 0 else -1
        _key = ((int(_stc >= 2) * 8 + int(_bbc >= 1) * 4 + int(_cc.count(TRAP_USTACK_CLOSE) >= 1) * 2
                 + int(_cc.count(TRAP_ANCHOR) >= 1)))
        _ord = 10 if (_p1 >= 0 and _p2 >= 0 and _p1 < _p2) else (_p1 >= 0 and _p2 >= 0)
        print("   depths      : key %d order %d" % (_key, _ord))
        chk("staged: the depth environs", _key == 8 + 4 + 2 + 0 and _ord == 10)   # (1046) 2,1,1,0
        if os.environ.get("WL_DEBUG_ENV"):
            open("/tmp/wl_cc_dbg.c", "w").write(_cc)
        chk("staged: every #if closes, never below zero", _staged_balanced(_cc))
        chk("staged: 1037's blocks intact", _cc.count(TRAP_FRAME_CLOSE) == BASE_TRAP.count(TRAP_FRAME_CLOSE)
            and _cc.count(TRAP_USTACK_CLOSE) == BASE_TRAP.count(TRAP_USTACK_CLOSE))
        _badrows = _gated_rows(_cc)
        print("   rows        : printf %d cut %d" % (_cc.count('printf("'), _badrows.count('printf("')))
        chk("staged: the switch off compiles none of its rows",
            _badrows.count('printf("xnu_live_sweq_') + _badrows.count('printf("xnu_live_ler_') + _badrows.count('printf("xnu_live_wlg_') + _badrows.count('printf("xnu_live_wlr_') == 0)
        chk("gate table + values in chunk b", all(("\txnu_live_wlg_need_%s = (unsigned)" % r) in DEFS_CHUNK()
                                              for r, _ in SWEQ_GATE + SLOT_ROWS_GATE + LETTER_ROWS + A_WIN_GATE
                                              if r not in ("seq", "pid")))
        # EXACT: the hook is HOOK_OPEN, the call, the chunk h include, chunk h's BODY, TRAP_CLOSE.
        # HOOK_OPEN's `text\n` is a PREFIX of the arm's spliced `text\n\n...`: two opens, the call's
        # and chunk h's (the arm's INLINE copy is the second)
        # (the first HOOK_OPEN is the body's own; the second is chunk b's arm -- TRAP_BLOCK's first line)
        # (1042) the hook is ONE function body: its chunk-h copy opens the switch with a REAL line
        # (SWITCH_OPEN_LINE) and the arm's own line stays INSIDE it (chunk h's copy, as chunk h has it) --
        # two real lines, plus HOOK_OPEN_EARLY's comment-out pair at the file's edge (3 opens measured)
        # (1046) the hook's script-line head was for the OLD shape (the spill carried an open): the three
        # real opens are the switch's, the arm's and the rows' spliced wake (the spill's pair is a
        # HOOK_OPENEND, whose own count is separate and not needed here)
        chk("hook opens at the switch", HOOK_CHUNK.startswith("\t/* 1038's HOOK") and HOOK_CHUNK.count(HOOK_OPEN) == 3
            and HOOK_PROTOS.startswith("\t/*") and CHUNK_H_INC_LINE(HOOK_PROTOS, 0) != "")   # chunk h is the include'd file
        chk("hook chunk ends with the switch close + chunk h", HOOK_CHUNK.count(HALF_TEXT()) == 1
            and _ends(HOOK_CHUNK, HALF_TEXT() + chr(10) + TRAP_CLOSE)  # (1042) the body WHOLE, then the call's close
            and HOOK_CHUNK.count(CHUNK_H_OPEN) == 1   # guard `#if`, body, TRAP_CLOSE, closes, TRAP_CLOSE
            and INCS["h"].endswith(HOOK2_INC)   # written WHOLE: a translation unit of its own
            and ("#include " + chr(34) + CURRENT_H() + chr(34) + chr(10)) in HOOK_PROTOS)
        chk("hook chunk: one bracket pair", _pp_balanced(HOOK_CHUNK.count(CHUNK_H_OPEN)==1 and HOOK_CHUNK))
        chk("hook chunk carries chunk h", HOOK_CHUNK.count(HALF_TEXT()) == 1)
        chk("hook anchor not in chunk", HOOK_ANCHOR not in HOOK_CHUNK)
        chk("hook commits", HOOK_CHUNK.count("_wl_ss_commit(_wl_k - 1U);") == 1)
        chk("statics defined", "static uint32_t _wl_swb[" in DEFS_CHUNK() and "_wl_ss_commit(unsigned _wl_j)" in DEFS_CHUNK())
        chk("statics keyword", "static uint32_t " in DEFS_CHUNK())
        # A comment mentioning `#define` with a trailing backtick is live text to the preprocessor
        # (see SW_OPEN_LINE).  No emitted line may carry that shape.
        # The line's tail after its first comment closes must not begin a directive (comments are
        # removed before directives are found, so `*/ #define X` at the tail is live).
        _bad_cmt = []
        for ln in (DEFS_CHUNK() + ARM_TEXT + HOOK_CHUNK + HOOK_PROTOS).splitlines():
            if "/*" not in ln:
                continue
            k = ln.find("*/")
            while k >= 0 and "#define" in ln:
                ln = ln[k + 2:]
                k = ln.find("*/")
            if ln.lstrip().startswith("#define"):
                _bad_cmt.append(ln)
        chk("no #define-like directive inside a comment", not _bad_cmt)

        def spell(r):
            if r in STACK_WORDS or r in STACK_SUM:   # A's own rows (the watch's), not SWEQ/SLOT
                return chr(34) + "xnu_live_ler_" + r + "="
            if r in SWEQ_ROWS or r in SLOT_ROWS:
                return chr(34) + "xnu_live_" + "sweq_" + r + "="
            if r.startswith("lr_"):
                return chr(34) + "xnu_live_" + "wlr_" + r[3:] + "="
            return chr(34) + "xnu_live_" + "ler_" + r + "="
        proxy = {r[3:] for r, _ in LETTER_ROWS if r.startswith("lr_")} | {"byte", "lev", "r3"}
        for r, g in A_WIN_GATE:
            # the QUOTED name, a following `=` too: `sweq_s3` is a PREFIX of `sweq_s3_ok` (measured 2026-10-20)
            _n1 = int(ARM_TEXT.count(chr(34) + "xnu_live_sweq_" + r + "="))
            _n2 = int(chunk_h().count(chr(34) + "xnu_live_sweq_" + r + "="))
            chk("row sweq_%s once" % r, _n1 == 1 and _n2 == 1)
        for r in dict.fromkeys(SWEQ_ROWS + tuple(x for x, _ in LETTER_ROWS) + tuple(SLOT_ROWS) + tuple(STACK_ROWS)):
            if r in proxy:                     # `wlr_`/`wlg_` rows: a DIFFERENT row (the arm's word, the gate)
                continue
            # the arm file and chunk h EACH carry the whole arm (the hook's file and the tree's
            # include are two copies of it): one each, never two in one
            _rw = spell(r) + "="                 # `spell` already ends in `=`; a second one matches nothing
            if _rw.endswith("=="): _rw = _rw[:-1]   # (1045) measured in-process: a duplicated `=` reads 0
            # (1044) one compare each, ints out: a compound `and` in the loaded process read False
            _n1 = int(ARM_TEXT.count(_rw))
            _n2 = int(chunk_h().count(_rw))
            chk("row %s once" % r, _n1 == 1 and _n2 == 1)
        for r in GATE_ROWS:
            # the row's NAME as the arm spells it: `xnu_live_wlg_need_<r>=` (a bare `<r>` is a prefix of
            # many neighbours).
            nm = r if r.startswith("xnu_live_") else "xnu_live_wlg_need_" + r
            src = HOOK_CHUNK   # the hook carries chunk h AND its own tail: A's need_ rows and the gates
            # the QUOTE is searched too: a bare `<r>=` is a prefix of many neighbours (lr_mfp1=_ok=).
            chk("gate once %s" % nm, src.count(chr(34) + nm) == 1)
        chk("every gate table row has a need_ row", all((r in ("seq", "pid") or ("xnu_live_wlg_need_" + r + "=") in GATE_ROWS)
                                                         for r, _ in SWEQ_GATE + SLOT_ROWS_GATE + LETTER_ROWS + A_WIN_GATE))
        chk("swb_pc/swb_ok gates", dict(SLOT_ROWS_GATE)["swb_pc"] == 10 and dict(SLOT_ROWS_GATE)["swb_ok"] == 0)
        chk("switch in the allow list", SWITCH in TRAP_ALLOWED_IF_IDENTIFIERS)
        t2, st = register_into('TRAP_ALLOWED_IF_IDENTIFIERS = {\n    "STAGE90_XNU_TRAP_FRAME",\n} # x\n',
                               "tools/patch_x.py")
        chk("register adds the switch", st == "added" and SWITCH in t2
            and register_into(t2, "tools/patch_x.py")[1] == "present")
        chk("register: no anchor", register_into("x\n", "tools/patch_y.py")[1] == "ABSENT")
        t3, st3 = register_into(BUILD_TEXT, BUILD_REL)
        chk("register: the build reader", st3 == "added" and BUILD_TEXT.split("\n")[0] in t3
            and BUILD_TEXT.split("\n")[1] + "\n" in t3 and t3.count(BUILD_READER) == 1
            and BUILD_TEXT[BUILD_TEXT.index("if timeout "):].split("\n")[1] in t3)
        chk("register: idempotent", register_into(t3, BUILD_REL)[1] == "present")
        fp = t3.find("-c \"$src\"")
        chk("register: the proto line rides FILE_INCLUDES before -c",
            BUILD_PROTO_LINE in t3 and fp > 0 and t3.index(BUILD_PROTO_LINE) < fp)
        chk("proto: the switch only", proto_text() == WATCH_DEFINE)
        legacy = BUILD_TEXT + '    FILE_INCLUDES+=(-include "$XNU/osfmk/arm/watch_le_proto.inc")\n'
        off_legacy, n_drop = _drop_forcing(legacy)
        chk("register: an unconditioned forced-include line is removed", n_drop == 1
            and "FILE_INCLUDES+=" not in off_legacy and off_legacy == BUILD_TEXT)
        chk("defs: a one-time file-scope group", DEFS_CHUNK().startswith(SW_OPEN_LINE)
            and DEFS_CHUNK().endswith(CHUNK_CLOSE)
            and DEFS_CHUNK().count("#ifndef WATCH_LE_STATICS_DEFINED") == 1
            and DEFS_CHUNK().count("#endif /* WATCH_LE_STATICS_DEFINED */") == 1
            and "static unsigned _wl_ss_slot(unsigned *ctx)\n" in DEFS_CHUNK()
            and DEFS_CHUNK().count("xnu_live_wlg_byte;") == 1 and "xnu_live_wlr_ppc;" in DEFS_CHUNK())
        chk("hook: no function defined in it (chunk h holds only statics)", HOOK_PROTOS.count(") {") == 0 and "_wl_join_" not in HOOK_CHUNK
            and not any(l.strip().startswith(("static ", "void ")) and l.rstrip() == "{" for l in read(T_H).split(chr(10))))
        _hp = ["static unsigned _wl_ss_slot(unsigned *ctx);" in HOOK_PROTOS,
               "static void _wl_ss_commit(unsigned _wl_j);" in HOOK_PROTOS,
               "extern unsigned _wl_owned;" not in HOOK_PROTOS,
               _ends(T_H, HOOK2_INC),   # the selftest's WRITTEN file, judged by name (isfile on a path here answers wrong)
               HOOK2_INC in HOOK_PROTOS.split(chr(10))[-2],   # (1046) the in-process `_ends` slice on these tails lied
               _pp_balanced(_h_file()),
               "#include " + chr(34) + CURRENT_H() + chr(34) + chr(10) in HOOK_PROTOS]
        if not all(_hp) and os.environ.get("WL_DEBUG"):
            print("   hp", _hp)
        chk("hook: its prototypes name the impl", all(_hp))
        T_H = INCS["h"]
        # (1046) by CALL, after the checks above pinned the chunks: this host's loaded functions answer
        # differently on a REBUILT argument (the top-level `chunk_h()` here read chunk h's file tail)
        _hf = _h_body()
        # four plain closes: the break's [0], the switch define's, the arm's (TW_CLOSE answers A_SPLICE),
        # the stand-in's copy; one wake close; two switch opens: the arm's own line, the rows' spliced copy
        # (A_ROWS_TEXT), which the hook's stand-in guard closes.
        # (1042) the rows' spliced copy is a TW (`#if <switch>   /* ... */`), not SWITCH_TWO: four plain
        # closes = the hook frame's, the switch define's, ...; one wake close; two real opens + two TWS
                # (1043) the scalars are printed: the combined expression lied in this loaded process
        # (1046) the hook's copy is the group + the switch define + the arm (chunk a's bracket, open and
        # close, INSIDE it) + the rows + the switch's REAL close: no stand-in head, no chunk-h tail (the
        # hook's spill answers at file scope).  The SEARCHES are needles ending in `\n` (slices compared
        # to literals agree with the text; this host's `count`/`endswith` answer wrongly on these tails):
        # (1046) the hook's body, by CALL: six conjuncts, each an int (this host's loaded compares lie
        # on long texts after a few hundred lines of state; see _h2_counts).  It is judged from the
        # WRITTEN chunk h file: the same text the hook's caller `#include`s.
        _hf = read(INCS["h"])          # chunk h's FILE, as written above (chunk b carries it)
        _gs = _h2_counts(_hf)
        if os.environ.get("WL_DEBUG"):
            print("   h2", _gs, len(_hf.split(chr(10))))
        chk("hook2 file: the switch opens and closes inside it", _gs[0] == 6)
    finally:
        INCS.update(saved)         # chunk_h() reads INCS: restore BEFORE any check
    for b in bad:
        print("   failed: %s" % b)
    ok = not bad
    print("patch_d13_watch_le: --selftest %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def _h2_counts(t):
    """(the six conjuncts of the hook2 check, the tail flag): ints and `>=` only, and the tail is the
    LAST LINE read from the text (wb -> -1 when it is not the switch's real close).
    [[mi4-host-python-int-compare-unreliable]]"""
    b = int(t.count(A_ANSWER_IF) >= 1)
    c = int(t.count(SWITCH_TWO) >= 3)
    d = int(t.count(TW) >= 2)
    e = int(CHUNK_H_STANDIN + "#ifndef WATCH_LE_STATICS_DEFINED" in t)
    # (1046) the arm's switch close is inside the chunk-h guard's bracket (then the chunk's closes)
    f = int(SW_REAL_CLOSE.rstrip(chr(10)) in t.split(chr(10)))
    h = int(_pp_balanced(t))
    return (b + c + d + e + f + h, f)


def write(p, t):
    with open(p, "w") as f:
        f.write(t)


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if "--model-files" in argv or "--verify-model" in argv:
        # 1039's edit ([[mi4-one-file-many-rungs]]): the rows loop's three files, REAL LINES each, written
        # beside trap.c and read back like every other chunk.  --verify-model judges them by value.
        args = [a for a in argv[1:] if not a.startswith("--")]
        if len(args) != 1:
            print("usage: patch_d13_watch_le.py <xnu_root> --model-files|--verify-model", file=sys.stderr)
            return 2
        xnu = args[0]
        set_inc_dir(xnu)
        files, lines, probs = _model_files(xnu)
        probs = probs + _selfcheck_model()
        for _p in probs:
            print("   model: PROBLEM: %s" % _p)
        if probs:
            print("patch_d13_watch_le: --model-files REFUSE (the model cannot compile). Writing nothing.",
                  file=sys.stderr)
            return 1
        if "--verify-model" in argv:
            stale = check_chunks(xnu, model=True)
            print("patch_d13_watch_le: --verify-model %s (the three files are the model's, byte for byte)."
                  % ("FAIL: %s" % ", ".join(stale) if stale else "PASS"))
            return 1 if stale else 0
        write_chunks(xnu, model=True)
        print("patch_d13_watch_le: the rows loop's files written (%s); trap.c's edit is the ONE line "
              "%r." % (", ".join(sorted(files)), lines[0]))
        return 0
    apply_ = "--apply" in argv
    if "--verify-off" in argv:
        args = [a for a in argv[1:] if not a.startswith("--")]
        if len(args) != 1:
            print("usage: patch_d13_watch_le.py <xnu_root> --verify-off", file=sys.stderr)
            return 2
        # the TREE root: trap.c is <root>/osfmk/arm/trap.c and the chunks live beside it
        set_inc_dir(args[0])
        return verify_off(trap_path(args[0]))
    if "--gates" in argv:
        return gates()
    if "--register" in argv:
        ok, rep = register(REPO, do_apply=apply_)
        for rel, st in rep:
            print("   %-40s %s" % (rel, st))
        print("patch_d13_watch_le: --register %s" % ("PASS" if ok else "FAIL (a file carries no anchor)"))
        return 0 if ok else 1
    if len(argv) < 2:
        print("usage: patch_d13_watch_le.py <xnu_root> [--apply|--verify-off|--out] [--selftest] [--gates]\n"
              "       patch_d13_watch_le.py --register [--apply]", file=sys.stderr)
        return 2
    xnu = argv[1]
    piped = "--out" in argv            # compose trap.c to stdout: writes nothing (chunks not written)
    set_inc_dir(xnu)
    if piped:
        if not os.path.isdir(os.path.dirname(INCS["a"])):
            print("patch_d13_watch_le: --out: no %s" % os.path.dirname(INCS["a"]), file=sys.stderr)
            return 1
        return stage(xnu, do_apply=True, piped=True)
    reg_ok, rep = register(REPO, do_apply=apply_)
    for rel, st in rep:
        print("   namespace: %-40s %s" % (rel, st))
    if not reg_ok:
        print("patch_d13_watch_le: REFUSE - a trap.c patcher carries no allow list anchor "
              "(--register names it). Writing nothing.", file=sys.stderr)
        return 1
    return stage(xnu, do_apply=apply_)



# ==================================================================================================
# THE ROWS LOOP (1039, 2026-10-20).  ONE model of 1038's text, read by ONE consumer (the 1039 seam
# composer, tools/patch_d13_1039_seam.py) and written as REAL LINES.  1038's text is THREE files, each
# legal by real lines only (no splice, no backslash, no tab-indented directive):
#
#   watch_le_defs.inc  (FILE SCOPE, trap.c's body)  the statics group, the switch, arm A's BODY, the
#                      switch close, the gate table.  Included INSIDE 1025's `#if`: a body's braces do
#                      not count there, so the arc is exactly 1025's.
#   watch_le_arm.inc   (FUNCTION SCOPE, the hook `#include`s it)  A's MEASUREMENTS and the rows: A/V
#                      read and record, nobody prints (printf under a spinlock's waiter list deadlocks
#                      the console -- xnu's lock->printf rule).  `return` leaves the hook.
#   watch_le_hook.inc  (the call site, first line of sleh_abort's body)  the slot writer, then the
#                      arm -- a DIRECTIVE-BALANCED fragment (no #if, no #endif; a body's braces and
#                      the preprocessor's conditional nesting are independent counts).
#
# WHY THE TABLES ARE PART OF ARM A NOW: the block used to read 1025's locals and A1's table word,
# and its rows printed values NOTHING measured (letters, _wl_lt/_wl_lo were never assigned: a
# right-sized zero, [[mi4-emitter-missing]]).  Here every row printed is a word read here.
# ==================================================================================================

INC_DEFS = "watch_le_defs.inc"
INC_ARM = "watch_le_arm.inc"
INC_HOOK = "watch_le_hook.inc"
INC_SWITCH = "watch_le_switch.inc"        # (1040) the switch's `#define`, the hook `#include`s it

T = chr(9)
E = chr(10)


def _defs_lines():
    """(lines, baked): watch_le_defs.inc.  `baked` maps a baked constant's NAME to its C text, so the
    arm's index (the one address a pool of class constants turns into a reading) is the ONE value the
    two files share."""
    L = []
    L.append("/* 1038 / 1039: THE FOREIGN CODE ON THE STACK -- arm A's tables.  FILE SCOPE, inside 1025's")
    L.append(" * `#if STAGE90_XNU_USTACK_PROBE` (a body's braces do not count to the preprocessor, so the")
    L.append(" * 1025 close that follows is its close).  The switch, the statics, arm A's MEASUREMENTS and")
    L.append(" * the gate table; the rows are watch_le_arm.inc's (the hook).  */")
    L.append("")
    L.append("#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE")
    L.append(WATCH_DEFINE.rstrip(chr(10)))   # (1040) THE SWITCH, first: ...
    L.append("static unsigned _wl_swb[304U];      /* the slots: 16 x 19 (r0-r12, sp, lr, pc, cpsr, fsr, far) */")
    L.append("static unsigned _wl_ssslot;         /* the newest committed slot + 1 */")
    L.append("static unsigned _wl_owned;          /* the hook's claim for THIS thread's fault + 1 */")
    L.append("")
    L.append("static unsigned _wl_claim(void)")
    L.append("{")
    L.append(T + "unsigned _wl_j = __atomic_load_n(&_wl_ssslot, __ATOMIC_ACQUIRE);")
    L.append(T + "return _wl_j & 15U;")
    L.append("}")
    L.append("")
    L.append("static unsigned _wl_ss_slot(unsigned *ctx)")
    L.append("{")
    L.append(T + "unsigned _wl_i;")
    L.append(T + "if (!ctx || !ctx[15] || (ctx[16] & 0x1fU) != 0x10U || (ctx[16] & 3U) != 0U || !ctx[13] ||")
    L.append(T + "    ctx[18] < 0x80000000U) { return 0U; }")
    L.append(T + "for (_wl_i = 0; _wl_i < 19U; _wl_i++) {")
    L.append(T + T + "__atomic_store_n(&_wl_swb[19U * _wl_claim() + _wl_i], ctx[_wl_i], __ATOMIC_RELEASE);")
    L.append(T + "}")
    L.append(T + "return _wl_claim() + 1U;")
    L.append("}")
    L.append("")
    L.append("static void _wl_ss_commit(unsigned _wl_j)")
    L.append("{")
    L.append(T + "__atomic_store_n(&_wl_ssslot, _wl_j + 1U, __ATOMIC_RELEASE);")
    L.append("}")
    L.append("")
    L.append("/* ===== A: THE STACK WATCH (the tables; the hook's arm MEASURES) ===== */")
    L.append("unsigned _wl_a_st[16];               /* the 16 words at sp-4 .. sp+0x3c */")
    L.append("unsigned _wl_a_stok[16];")
    L.append("unsigned _wl_a_s3v;                  /* s3's VALUE: a saved r11 (a stack frame) */")
    L.append("unsigned _wl_a_s3[4];                /* the 32 bytes there */")
    L.append("unsigned _wl_a_s3ok[4];")
    L.append("unsigned _wl_a_cnt;                  /* [r3] of the 1036 table read (the ued count, LE) */")
    L.append("unsigned _wl_a_cntok;")
    L.append("unsigned _wl_a_pc4;                  /* the words at pc-8, pc-4, pc */")
    L.append("unsigned _wl_a_pc8;")
    L.append("unsigned _wl_a_pc0;")
    L.append("unsigned _wl_a_pcz;                  /* the read at pc itself */")
    L.append("unsigned _wl_a_pcok;")
    L.append("unsigned _wl_a_wpc;                  /* the walk's pc through the saved-r11 chain */")
    L.append("unsigned _wl_a_wfp;")
    L.append("unsigned _wl_a_seq;                  /* one to WL_PRINT_CAP prints per boot */")
    L.append("unsigned _wl_a_acc;                  /* the run-in-progress's address words (1 << i) */")
    L.append("unsigned _wl_a_owned;                /* the slot the ONE print of this fault claims */")
    L.append("unsigned _wl_a_ss[16];               /* the slot's 16 register words, flat (stride 19) */")
    L.append("unsigned _wl_a_ir[16];               /* the 16 words at the code: pc-4, pc, the pops, the literals */")
    L.append("unsigned _wl_a_irok[16];")
    L.append("unsigned _wl_a_ir2;                  /* the first word's bits 1:0 (0 = a literal pool) */")
    L.append("unsigned _wl_a_bands;                /* value buried in the instructions: a B bit's ANDs */")
    L.append("unsigned _wl_a_bands2;")
    L.append("unsigned _wl_a_far, _wl_a_stk_pc;   /* the slot's own far and saved pc */")
    L.append("")
    L.append("/* THE TASK-MAP READS (one place).  vm_map_lookup_entry takes no lock on this tree (the")
    L.append(" * 1026/1029-1037 idiom); copyin arms TH_RECOVER.  A miss: 0 / 0. */")
    L.append("static int _wl_rd(vm_map_t m, unsigned a, unsigned *out)")
    L.append("{")
    L.append(T + "vm_map_entry_t _wl_e;")
    L.append(T + "if (a < 4U || (a & ~3U) > 0xfffffffcU || !vm_map_lookup_entry(m, a & ~3U, &_wl_e)) {")
    L.append(T + T + "*out = 0U;")
    L.append(T + T + "return 0;")
    L.append(T + "}")
    L.append(T + "return (int)(copyin((user_addr_t)(uintptr_t)(a & ~3U), (char *)out, 4) == 0);")
    L.append("}")
    L.append("")
    g = []
    g.append("/* THE GATE TABLE: one 1-bit mask per row f, the run's coverage (1U << f).  `static` so that a")
    g.append(" * 1038 = 0 build carries no symbol for it (the host reads the pool; nothing links it). */")
    for f in range(8):
        g.append("static unsigned xnu_live_wlg_need_%d;   /* f%d */" % (f, f))
    g.append("#endif /* STAGE90_XNU_WATCH_LE */")
    return L + g, {}


def _arm_lines(xnu, gates):
    """(lines, syms): watch_le_arm.inc -- what the hook runs.  `gates` maps a row's stem to its gate."""
    L = []
    A = lambda s: T + s
    L.append("/* 1038 / 1039: THE ARM.  `#include`d INSIDE sleh_abort (the fault's own `context` is")
    L.append(" * `arm_ctx`, `reason` says data abort or not).  A/V: 16 words, 32 bytes at s3's value, the")
    L.append(" * 1036 table's count at r3, the words at the pc; the walk up the saved-r11 chain, named by")
    L.append(" * its LARGEST step (the one the fault's pc leaves); then the slot's registers against the")
    L.append(" * code (the pops and literals the pc can reach).  PRINT: per source word, ONCE.  Each line")
    L.append(" * prints only when its read succeeded ONCE IN ITS LINE, so a row that cannot say its")
    L.append(" * conjunct prints nothing.  The interpretation is the host's.  READ ONLY. */")
    L.append("{")
    L.append(A("unsigned _wl_i, _wl_seq = __atomic_fetch_add(&_wl_a_seq, 1U, __ATOMIC_ACQ_REL) + 1U;"))
    L.append(A("unsigned _wl_n = 0U;   /* the walk's levels (bounded: 30) */"))
    # ONE print per BOOT ([[mi4-xnu-print-under-spinlock]]): the arm runs in vm_fault's abort path, and
    # printing there while a spinlock is held is the waiter-list deadlock this project measured on 1031.
    # The CAP is the measured ceiling: the abort path has already printed its own report by then.
    L.append(A("if (_wl_seq > WL_PRINT_CAP) { return; }"))
    L.append(A("unsigned _wl_sp = (unsigned)arm_ctx->sp;"))
    L.append(A("_wl_a_pc0 = (unsigned)arm_ctx->pc;"))
    L.append(A("_wl_a_wpc = 0U; _wl_a_wfp = 0U;"))
    L.append("")
    L.append(A("/* A: the stack and the s3 window (a task's map: thread->task is the faulted one) */"))
    L.append(A("for (_wl_i = 0; _wl_i < 16U; _wl_i++) {"))
    L.append(A(T + "int _wl_o = _wl_rd(thread->task->map, _wl_sp - 4U + 4U * _wl_i, &_wl_a_st[_wl_i]);"))
    L.append(A(T + "_wl_a_stok[_wl_i] = (unsigned)_wl_o;"))
    L.append(A("}"))
    L.append(A("_wl_a_s3v = _wl_a_st[2];"))
    L.append(A("for (_wl_i = 0; _wl_i < 4U; _wl_i++) {"))
    L.append(A(T + "int _wl_o = _wl_rd(thread->task->map, _wl_a_s3v + 4U * _wl_i, &_wl_a_s3[_wl_i]);"))
    L.append(A(T + "_wl_a_s3ok[_wl_i] = (unsigned)_wl_o;"))
    L.append(A("}"))
    L.append("")
    L.append(A("/* the 1036 table: its `used` count at r3 (the field one word past 0x18: ued) */"))
    L.append(A("_wl_a_cntok = (unsigned)_wl_rd(thread->task->map, (unsigned)arm_ctx->r[3] + 0x18U, &_wl_a_cnt);"))
    L.append("")
    L.append(A("/* the words the pc can reach: pc-8, pc-4, pc */"))
    L.append(A("_wl_a_pcok = (unsigned)(_wl_rd(thread->task->map, _wl_a_pc0 - 8U, &_wl_a_pc8) +"))
    L.append(A("                 _wl_rd(thread->task->map, _wl_a_pc0 - 4U, &_wl_a_pc4) +"))
    L.append(A("                 _wl_rd(thread->task->map, _wl_a_pc0, &_wl_a_pcz)));"))
    L.append("")
    L.append(A("/* THE WALK: bp0 = s3's value; up while 0 < fp < 0x80000000, 30 levels */"))
    L.append(A("if (_wl_a_s3ok[0] && _wl_a_s3v >= 8U && _wl_a_s3v < 0x80000000U) {"))
    L.append(A(T + "unsigned _wl_fp = _wl_a_s3v, _wl_prev = 0U, _wl_pp = 0U;"))
    L.append(A(T + "for (_wl_n = 0U; _wl_n < 30U; _wl_n++) {"))
    L.append(A(T + T + "unsigned _wl_r;"))
    L.append(A(T + T + "if (!(_wl_rd(thread->task->map, _wl_fp + 4U, &_wl_r))) { break; }   /* the saved r11 */"))
    L.append(A(T + T + "if (_wl_fp >= _wl_a_pc0 && _wl_fp - _wl_a_pc0 < 0x1000U &&"))
    L.append(A(T + T + "    ((_wl_fp ^ _wl_a_pc0) & 0xfff00000U) == 0U) {"))
    L.append(A(T + T + T + "_wl_a_wpc = _wl_fp; _wl_a_wfp = _wl_prev;"))
    L.append(A(T + T + T + "break;"))
    L.append(A(T + T + "}"))
    L.append(A(T + T + "if (_wl_r < 8U || _wl_r >= 0x80000000U || (_wl_r & 3U) != 0U) { break; }"))
    L.append(A(T + T + "_wl_prev = _wl_fp; _wl_fp = _wl_r;"))
    L.append(A(T + "}"))
    L.append(A("}"))
    L.append("")
    L.append(A("/* THE ONE PRINT OF THIS RUN: the slot's claim (one address line, one register line). */"))
    L.append(A("_wl_a_owned = _wl_owned;"))
    L.append(A("_wl_a_acc = 0U;"))
    for _k in range(15):
        L.append(A("if (_wl_a_stok[%d]) { _wl_a_acc |= (1U << %d); }" % (_k, _k)))
    L.append(A("if (!_wl_a_owned) { return; }"))
    L.append(A("_wl_a_sv = (_wl_a_owned - 1U) & 15U;"))
    L.append(A("for (_wl_i = 0; _wl_i < 16U; _wl_i++) {"))
    L.append(A(T + "_wl_a_ss[_wl_i] = _wl_swb[19U * _wl_a_sv + _wl_i];"))
    L.append(A("}"))
    L.append(A("_wl_a_far = _wl_swb[19U * _wl_a_sv + 18U];"))
    L.append(A("_wl_a_stk_pc = _wl_swb[19U * _wl_a_sv + 15U];"))
    L.append(A("if (_wl_ssslot != _wl_a_owned) { return; }"))
    L.append("")
    L.append("/* ADDRESS line: the 16 stack addresses' mask (1 << i when the read succeeded) and the")
    L.append(A(" * r3, the fault's pc, the slot, the walk.  LINE 2 (the registers): the slot's 16 words,"))
    L.append(A(" * s3's four and the pc's words, then the instructions the pc can reach. */"))
    L.append(A("{"))
    L.append(A(T + 'printf("xnu_live_sweq_seq=%u' + chr(92)*2 + 'n", _wl_seq);'))
    L.append(A(T + 'printf("xnu_live_sweq_st_ok=0x%04x' + chr(92)*2 + 'n", (unsigned)(_wl_a_acc & 0xffffU));'))
    for _k in range(16):
        L.append(A(T + 'printf("xnu_live_sweq_st%d=0x%%08x' % _k + chr(92)*2 + 'n", (unsigned)_wl_a_st[%d]);' % _k))
    L.append(A(T + 'printf("xnu_live_sweq_s3_acc=0x%x' + chr(92)*2 + 'n", (unsigned)(_wl_a_acc >> 16));'))
    L.append(A(T + 'printf("xnu_live_sweq_cnt=%u' + chr(92)*2 + 'n", (unsigned)(_wl_a_cnt & 0xffffU));'))
    L.append(A(T + 'printf("xnu_live_sweq_cnt_ok=%d' + chr(92)*2 + 'n", (int)(_wl_a_cntok ? 1 : 0));'))
    L.append(A(T + 'printf("xnu_live_sweq_pc=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_pc0);'))
    L.append(A(T + 'printf("xnu_live_sweq_pc_ok=%d' + chr(92)*2 + 'n", (int)(_wl_a_pcok ? 1 : 0));'))
    L.append(A(T + 'printf("xnu_live_sweq_swb_slot=%u' + chr(92)*2 + 'n", (unsigned)(_wl_a_sv + 1U));'))
    L.append(A(T + 'printf("xnu_live_sweq_swb_far=0x%08x' + chr(92)*2 + 'n",'));
    L.append(A(T + T + "    (unsigned)_wl_swb[19U * _wl_a_sv + 18U]);"))
    L.append(A(T + 'printf("xnu_live_sweq_swb_tag=0x%08x' + chr(92)*2 + 'n",'));
    L.append(A(T + T + "    (unsigned)_wl_swb[19U * _wl_a_sv + 16U]);"))
    L.append(A(T + 'printf("xnu_live_sweq_wpc=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_wpc);'))
    L.append(A(T + 'printf("xnu_live_sweq_wfp=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_wfp);'))
    L.append(A(T + 'printf("xnu_live_sweq_w_ok=%d' + chr(92)*2 + 'n", (int)(_wl_a_wpc ? 1 : 0));'))
    L.append(A("}"))
    L.append("")
    L.append(A("/* the registers, s3's bytes, the pc's words */"))
    L.append(A("{"))
    for k in range(15):
        L.append(A(T + 'printf("xnu_live_sweq_w%d=0x%%08x' % k + chr(92)*2 + 'n", (unsigned)_wl_a_ss[%d]);' % k))
    L.append(A(T + 'printf("xnu_live_sweq_w15=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_ss[15]);'))

    for k in range(4):
        L.append(A(T + 'printf("xnu_live_sweq_b%d=0x%%08x' % k + chr(92)*2 + 'n", (unsigned)_wl_a_s3[%d]);' % k))
    L.append(A(T + 'printf("xnu_live_ler_cnt_w=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_cnt);'))
    L.append(A(T + 'printf("xnu_live_ler_cnt_b=0x%08x' + chr(92)*2 + 'n", (unsigned)((_wl_a_cnt & 0xffU) |'))
    L.append(A(T + T + "    ((_wl_a_cnt >> 8) & 0xff00U)));"))
    L.append(A(T + 'printf("xnu_live_ler_pc8=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_pc8);'))
    L.append(A(T + 'printf("xnu_live_ler_pc4=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_pc4);'))
    L.append(A("}"))
    L.append("")
    L.append(A("/* THE INSTRUCTIONS the pc can reach: 16 words from pc-4 on, each `_ok` = the read */"))
    L.append(A("for (_wl_i = 0; _wl_i < 16U; _wl_i++) {"))
    L.append(A(T + "int _wl_o = _wl_rd(thread->task->map, _wl_a_pc0 - 4U + 4U * _wl_i, &_wl_a_ir[_wl_i]);"))
    L.append(A(T + "_wl_a_irok[_wl_i] = (unsigned)_wl_o;"))
    L.append(A("}"))
    L.append(A("_wl_a_ir2 = _wl_a_ir[0] & 3U;"))
    L.append(A("{"))
    L.append(A(T + 'printf("xnu_live_ler_ir=0x%08x' + chr(92)*2 + 'n", (unsigned)_wl_a_ir2);'))
    for k in range(16):
        L.append(A(T + 'printf("xnu_live_ler_ir%d=0x%%08x' % k + chr(92)*2 + 'n", (unsigned)_wl_a_ir[%d]);' % k))
        L.append(A(T + 'printf("xnu_live_ler_ir%d_ok=%%d' % k + chr(92)*2 + 'n", (int)(_wl_a_irok[%d] ? 1 : 0));' % k))
    L.append(A("}"))
    L.append("")
    L.append(A("/* THE BANDS: the value buried in the instructions -- each candidate B's ANDs are computed"))
    L.append(A(" * here (in the kernel, where the operands are); `_bands` bit k = candidate k's value, and"))
    L.append(A(" * `bands2` the same for the second half.  A host-side checker may DERIVE where B comes from"))
    L.append(A(" * (design 1038 B: LE at the table), never assert it. */"))
    L.append(A("_wl_a_bands = 0U; _wl_a_bands2 = 0U;"))
    L.append(A("{"))
    for k in range(8):
        L.append(A(T + 'if ((_wl_a_ir[%d] & 0xffffffffU) == (_wl_a_ss[%d] | 0U)) { _wl_a_bands |= (1U << %d); }' % (k, k, k)))
    L.append(A("}"))
    L.append(A("_wl_a_bands2 = 0U;"))
    L.append(A("{"))
    for k in range(8):
        L.append(A(T + 'if ((_wl_a_ir[%d] & 0xffffffffU) == (_wl_a_s3[%d] | 0U)) { _wl_a_bands2 |= (1U << %d); }' % (k, k, k)))
    L.append(A("}"))
    L.append(A("{"))
    L.append(A(T + 'printf("xnu_live_ler_bands=0x%x' + chr(92)*2 + 'n", (unsigned)_wl_a_bands);'))
    L.append(A(T + 'printf("xnu_live_ler_bands2=0x%x' + chr(92)*2 + 'n", (unsigned)_wl_a_bands2);'))
    L.append(A("}"))
    L.append("")
    L.append(A("/* THE RUN-1 READ vs THE SLOT: the RUN's own reads against the slot's words -- the pc-4"))
    L.append(A(" * line, s3[1], the table's count and the fault's pc; one print. READ (never asserted). */"))
    L.append(A("printf(\"xnu_live_ler_seqeq=%d" + chr(92)*2 + "n\", (int)((_wl_a_cnt == _wl_a_ss[2] &&"))
    L.append(A(T + "    _wl_a_pc0 == _wl_a_stk_pc) ? 1 : 0));"))
    L.append("")
    L.append(A("/* THE GATES: one plain string per row group this run's arm reached (the host's mask);"))
    L.append(A(" * nothing here reads a value. */"))
    for g, n in sorted(gates.items()):
        L.append(A('printf("xnu_live_wlg_need_%s=1' % n + chr(92) + 'n");'))
    L.append("}")
    return L, {}


# **What a fragment file (`watch_le_arm.inc` / `watch_le_hook.inc`) may carry at all.** These are
# `#include`d INSIDE a function body, so a directive there is dangerous unless it is one of these:
# the fragment's own includes, and the switch's guard that wraps the hook's block. Everything else -
# a stray `#define`, an unbalanced arm directive - is the defect the checks below exist to find.
_FRAGMENT_DIRECTIVES = ("#include", "#if STAGE90_XNU_WATCH_LE", "#endif /* STAGE90_XNU_WATCH_LE */")


def _hook_lines():
    L = []
    L.append("\t/* 1038 / 1039: THE HOOK.  sleh_abort's first statement: record THIS fault's context in")
    L.append("\t * the slot when it is a user-mode ARM data abort, claim the slot for this thread, and run")
    L.append("\t * the arm (its reads and its ONE print).  The arm is a DIRECTIVE-FREE fragment (its")
    L.append("\t * braces close its own blocks; no #if crosses into this function). */")
    L.append("\t/* (1040) THE SWITCH, HERE, OUTSIDE THE BRACES: the defs file -- which DEFINES the switch --")
    L.append("\t * is included 600 lines BELOW this function, so the ROWS (this arm) read the switch")
    L.append("\t * UNDEFINED and every row compiled out while the statics the rows touch came from the")
    L.append("\t * fwd file's own copy: `use of undeclared identifier` for each.  A #define is legal in a")
    L.append("\t * function; a #if is not (an opened conditional cannot close inside an include). */")
    L.append("\t#include \"@@SWITCH@@\"")
    # **The block is guarded BY the switch, in this file, start to end.** The comment above warns that
    # a `#if` "cannot close inside an include" - that is about OPENING a conditional here and closing
    # it inside `watch_le_arm.inc` (a directive cannot span an inclusion). A guard whose `#if` and
    # `#endif` both live in THIS file, enclosing both includes, is exactly what the switch is for: the
    # block used to compile unconditionally, so a rung that records STAGE90_XNU_WATCH_LE=0 (1039 does)
    # still emitted 1038's rows - and because `_wl_owned` and friends are DECLARED in `watch_le_fwd.inc`
    # at seat row 300 while the hook is row 298, all of them read as "use of undeclared identifier"
    # and `osfmk_arm_trap.o` failed to build (283 errors, reported as "pool objects absent").
    L.append("\t#if STAGE90_XNU_WATCH_LE")
    L.append("\t{")
    L.append("\t\tunsigned _wl_ctx[19], _wl_k;")
    L.append("\t\tif (reason == SLEH_ABORT_TYPE_DATA_ABORT && arm_ctx) {")
    L.append("\t\t\t_wl_ctx[0] = arm_ctx->r[0];  _wl_ctx[1] = arm_ctx->r[1];  _wl_ctx[2] = arm_ctx->r[2];")
    L.append("\t\t\t_wl_ctx[3] = arm_ctx->r[3];  _wl_ctx[4] = arm_ctx->r[4];  _wl_ctx[5] = arm_ctx->r[5];")
    L.append("\t\t\t_wl_ctx[6] = arm_ctx->r[6];  _wl_ctx[7] = arm_ctx->r[7];  _wl_ctx[8] = arm_ctx->r[8];")
    L.append("\t\t\t_wl_ctx[9] = arm_ctx->r[9];  _wl_ctx[10] = arm_ctx->r[10]; _wl_ctx[11] = arm_ctx->r[11];")
    L.append("\t\t\t_wl_ctx[12] = arm_ctx->r[12];")
    L.append("\t\t\t_wl_ctx[13] = arm_ctx->sp;  _wl_ctx[14] = arm_ctx->lr;  _wl_ctx[15] = arm_ctx->pc;")
    L.append("\t\t\t_wl_ctx[16] = arm_ctx->cpsr; _wl_ctx[17] = arm_ctx->fsr; _wl_ctx[18] = arm_ctx->far;")
    L.append("\t\t\t_wl_k = _wl_ss_slot(_wl_ctx);")
    L.append("\t\t\tif (_wl_k) {")
    L.append("\t\t\t\t__atomic_store_n(&_wl_owned, _wl_k, __ATOMIC_RELEASE);")
    L.append("\t\t\t\t_wl_ss_commit(_wl_k - 1U);")
    L.append("\t\t\t}")
    L.append("\t\t}")
    L.append("\t\t#include \"@@ARM@@\"")
    L.append("\t}")
    L.append("\t#endif /* STAGE90_XNU_WATCH_LE */")
    return L


WL_PRINT_CAP = 4               # prints per boot (the arm returns above it)

GATES = {0: "st", 1: "s3", 2: "cnt", 3: "pc", 4: "ir", 5: "walk", 6: "slot", 7: "table"}


def chunks_text(xnu=None, model=False):
    """The chunk files trap.c reaches: the hook directly (chunk 2) and, from chunk b's group, the arm
    (chunk a).  chunk b itself is the seam's include line's target (DEFS_CHUNK).
    (2026-10-20) model=True: the ROWS LOOP's files instead -- ONE model (unit_text), three files, each
    read back by check_chunks and by the trap.c edit's one include line ([[mi4-one-value-two-definitions]])."""
    if model:
        files, _ = _late().unit_text(xnu or TREE)
        # (the role -> path map is INCS; the FILES are keyed by NAME, so the lookup is by name)
        return tuple((r, files[n]) for r, n in zip(("b", "a", "hook"), (INC_DEFS, INC_ARM, INC_HOOK)))
    return (("b", DEFS_CHUNK()), ("a", arm_text()), ("hook", HOOK_CHUNK), ("h", chunk_h()))


def unit_text(xnu):
    """(files, lines): THE ONE MODEL.  files maps a name to its text (des/arm/hook); lines is the
    trap.c edit: the include line only (the files hold the text; a file is read back by the checks)."""
    d, _ = _defs_lines()
    a, _ = _arm_lines(xnu, GATES)
    h = _hook_lines()
    ddir = os.path.join(os.path.abspath(xnu), "osfmk", "arm")
    h = [l.replace("@@ARM@@", os.path.join(ddir, INC_ARM)) for l in h]
    swp = os.path.join(ddir, INC_SWITCH)
    h = [l.replace("@@SWITCH@@", swp) for l in h]
    # **The switch file DEFERS to a `-D` that already set it.** It used to hold an unconditional
    # `#define STAGE90_XNU_WATCH_LE 1`, which OVERRODE the build's own `-WATCH_LE=0`: a rung that
    # records the arm as OFF (1039 does - "its ROW side compiles out") still had 1038's rows compiled
    # in, and because the defs file that declares `_wl_owned` is included 600 lines below the hook,
    # every one of them came up "use of undeclared identifier" and trap.o failed to build. With the
    # guard, a 1038 build (no -D) still turns it on, and a rung that says 0 keeps it off.
    with open(swp, "w") as f_:
        f_.write("#ifndef %s\n" % SWITCH + WATCH_DEFINE + "#endif\n")
    files = {INC_DEFS: E.join(d) + E, INC_ARM: E.join(a) + E, INC_HOOK: E.join(h) + E}
    lines = ["#" + "include " + chr(34) + os.path.join(ddir, INC_DEFS) + chr(34)]
    return files, lines


def gates_values(files):
    """the gate lines the arm CARRIES (read from its text, never from the table alone)."""
    return sorted(n for n in GATES.values() if ("xnu_live_wlg_need_%s=1" % n) in files[INC_ARM])


def _selfcheck_model():
    """THE MODEL'S OWN FACTS (no tree): each file is legal by real lines (no backslash, no tab-indented
    directive), the defs file's directive depth returns to 0, the arm and the hook carry no directive at
    all, and every `=` in a printf is a row its stem's gate exists for."""
    files, _ = unit_text(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                      "external", "xnu-hd2-darwin13", "xnu"))
    probs = []
    for name in (INC_DEFS, INC_ARM, INC_HOOK):
        t = files[name]
        if t is None:
            probs.append("%s: absent from the model" % name)
            continue
        if any(l.rstrip(E).endswith(chr(92)) for l in t.split(E)):
            probs.append("%s has a line that ends in a backslash (a splice)" % name)
        for l in t.split(E):
            # (the switch's own guard is allowed now that the hook is wrapped in it; every other
            #  directive in these fragments is still the defect this check exists for)
            if (l[:1] == T and l.lstrip(T).startswith("#")
                    and not l.lstrip(T).startswith(_FRAGMENT_DIRECTIVES)):
                probs.append("%s: tab-indented directive %r" % (name, l[:40]))
    d = files[INC_DEFS] or ""
    dep, lo = 0, 0
    for l in d.split(E):
        s = l.strip()
        if s.startswith("#if"):
            dep += 1
        elif s.startswith("#endif"):
            dep -= 1
            lo = min(lo, dep)
    if (dep, lo) != (0, 0):
        probs.append("defs: depth (%d, %d)" % (dep, lo))
    for name in (INC_ARM, INC_HOOK):
        for l in (files[name] or "").split(E):
            if l.lstrip(T).startswith(_FRAGMENT_DIRECTIVES):
                continue
            if l.lstrip(T).startswith("#"):
                probs.append("%s: a directive beyond its own includes and the switch's guard" % name)
    import re as _re
    # (the gates' plain lines are `printf("xnu_live_wlg_need_<gate>=1\n")` -- a string with no
    # conversion: their names are the model's gate table, checked below, not rows)
    if files[INC_ARM] is None:
        return probs
    rows = set(_re.findall(r'printf\("xnu_live_([a-z0-9_]+)=', files[INC_ARM])) - set(
        "wlg_need_" + n for n in gates_values(files))
    want = set(
        ["sweq_s3_acc", "sweq_cnt", "sweq_cnt_ok", "sweq_pc", "sweq_pc_ok",
         "sweq_swb_slot", "sweq_swb_far", "sweq_swb_tag", "sweq_wpc", "sweq_wfp", "sweq_w_ok",
         "sweq_seq", "sweq_st_ok", "sweq_w15"] + ["sweq_st%d" % k for k in range(16)]
        + ["sweq_w%d" % k for k in range(15)] + ["sweq_b%d" % k for k in range(4)]
        + ["ler_cnt_w", "ler_cnt_b", "ler_pc8", "ler_pc4", "ler_ir", "ler_bands", "ler_bands2",
           "ler_seqeq"] + ["ler_ir%d" % k for k in range(16)] + ["ler_ir%d_ok" % k for k in range(16)])
    if files[INC_ARM] is not None and gates_values(files) != sorted(GATES.values()):
        probs.append("the arm's gate lines are not the gate table's (%s vs %s)"
                     % (gates_values(files), sorted(GATES.values())))
    if rows != want:
        probs.append("arm rows differ: missing %s, extra %s" % (sorted(want - rows), sorted(rows - want)))
    return probs


if __name__ == "__main__" and "--model" in __import__("sys").argv:
    _f, _l = unit_text(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                    "external", "xnu-hd2-darwin13", "xnu"))
    _p = _selfcheck_model()
    for _x in _p:
        print("MODEL: " + _x)
    print("model: %d problem(s)" % len(_p))
    __import__("sys").exit(1 if _p else 0)


# (the entry guard stands LAST: every definition above must exist before main can be called)
if __name__ == "__main__":
    sys.exit(main(sys.argv))
