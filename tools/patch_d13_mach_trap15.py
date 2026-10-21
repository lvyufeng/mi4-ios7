#!/usr/bin/env python3
"""Stage the mach trap-15 install (`mach_trap_table[15] = ios7lab_mach_vm_map_trap`) into the D13 tree.

THE DEFECT, by value (`records/1021d-mmap-failure.txt`, re-read in `docs/1022-mach-trap-15-design.md`
section 0.1).  In the LINKED image `mach_trap_table[15]` reads `kern_invalid` -- the same word as
entry 0 -- because the row is gated shut by `IOS7_COMPAT_PLATFORM`, which on CANCRO is a compile-time
0.  Meanwhile dyld's `_mach_vm_map` shim (`0x381c6618`) passes its guard, issues the fast-trap stub
`0x381c5960`'s `mvn ip,#14; svc #0x80` (`ip == -15 == index 15`), and `swi_mach` finds row 15 ==
`kern_invalid` and calls `swi_mach_error` -> panic.  The body the row needs already exists
(`osfmk/ipc/mach_kernelrpc.c:208-243`, `ios7lab_mach_vm_map_trap`), also gated shut by the same macro
at `:59`.

THE FIX (shape (B), the narrow switch -- docs/1022 section 2).  This rung adds NO new switch: it
reuses `STAGE90_XNU_IOS7_TRAPS`, which is already the record key, already in the pool `DEFINES`
(`tools/build_xnu_arm_kernel.sh:902`) and already in `EXTRA`/`ASFLAGS`/`ENTRY_ARM_KEYS`
(`records/1022-trap15-plumbing.txt` section 2).  It opens exactly the sites the trap-15 row needs and
NOTHING else -- in particular it does NOT widen `ios7_compat.h:5` (`IOS7_COMPAT_PLATFORM`), whose 24
bare `#if` sites include `osfmk/mach/arm/vm_param.h:63` (`VM_MAX_ADDRESS` halves) and ~15 runtime
`ios7_compat_vmabi_enabled()` call sites (docs/1022 section 2.2).

Edits (two files; exact-match, no partial application -- every anchor is asserted to occur EXACTLY
ONCE before anything is written, and a second run says "already staged" and writes nothing):

  osfmk/kern/syscall_sw.c
    1. the extern-decl block gate at :102 (`extern int ios7lab_mach_vm_map_trap(...)` and its four
       port siblings) is widened to the same `||` expression, so the row's name is declared on CANCRO.
    2. the row-15 gate at :126 (`/* 15 */ MACH_TRAP(ios7lab_mach_vm_map_trap, 8, NULL, NULL),`) is
       widened.  The rows 24/25 (:139/:144) and 41/42 (:164) keep their bare `#if` -- they stay
       deferred (the `#else` arm remains `kern_invalid`).

  osfmk/ipc/mach_kernelrpc.c
    3. the inner block gate at :59 (`#if IOS7_COMPAT_PLATFORM /* port/vm_map lab adapters: ... */`,
       which wraps the whole lab-adapter block :64-:244, incl. `ios7lab_mach_vm_map_trap` at :208) is
       widened.  Its `#endif` at :244 is NOT edited -- widening the `#if` alone makes the block compile
       (the file-wide gate at :39 ALREADY opens under the same switch, so there is no doubled `#else`).
    4. the runtime self-gate INSIDE `ios7lab_mach_vm_map_trap` (:217) reads the trap selector the
       three VM-wire adapters already read.  This is the load-bearing half (docs/1022 section 0.2):
       `ios7_compat_vmabi_enabled()` is a compile-time 0 on CANCRO (ios7_compat.h:11-21), so a row
       installed without it returns `MACH_SEND_INVALID_DEST` -- which is the shim's OWN sentinel
       (`0x10000003`) -- and the shim takes the slow leg INSTEAD of its MIG demux, i.e. strictly worse
       than today (the T15-SENTINEL regression cell).  Written as an `#if/#else` so the switch-OFF
       arm compiles the tree's ORIGINAL line, byte for byte.
    5. a switch-gated register-frame dump inside the same function, so the press DECIDES the disputed
       trap-15 wire empirically instead of on a static argument (`records/1022-trap15-adjudication.txt`;
       docs/1022 section 9.3 leaves the frame mapping UNMEASURED and `records/1022-trap15-wire.txt`
       disagrees with the design doc on `regs[8]`).

OFF IS BYTE-IDENTICAL BY MECHANISM.  Every new `#if` is written `defined(...) && ...` -- `defined()` is
evaluated FIRST, so an unset switch never evaluates the identifier (`mi4-off-option-two-spellings`).
Edits 1/2/3/5 are pure insertions-or-widened-gates whose OFF arm is the tree's own text; edit 4's new
line sits in the `#if` arm with the tree's ORIGINAL line verbatim in the `#else`, so with the switch
unset the preprocessed text is the tree's own.

CLI: `patch_d13_mach_trap15.py <xnu-tree-root>` plans (dry-run, prints the edits); `--apply` writes.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import importlib.util as _ilu, os as _os
_inc_stub = _ilu.module_from_spec(_s := _ilu.spec_from_file_location(
    "inc_stub", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "inc_stub.py")))
_s.loader.exec_module(_inc_stub)

XNU_SYSCALL_SW = "osfmk/kern/syscall_sw.c"
XNU_RPC = "osfmk/ipc/mach_kernelrpc.c"

# The spelling is exactly the one tools/patch_d13_ios7_vmwire.py uses (`:66-68`).
GATE_OLD = "#if IOS7_COMPAT_PLATFORM"
GATE_NEW = ("#if IOS7_COMPAT_PLATFORM"
            " || (defined(STAGE90_XNU_IOS7_TRAPS) && STAGE90_XNU_IOS7_TRAPS)")

# ---- syscall_sw.c: the extern-decl gate (:102) ----------------------------------------------

SSW_EXTERN_OLD = """#include <arm/ios7_compat.h>
#if IOS7_COMPAT_PLATFORM
extern int ios7lab_mach_vm_map_trap(void *saved_registers);
"""
SSW_EXTERN_NEW = """#include <arm/ios7_compat.h>
""" + GATE_NEW + """
extern int ios7lab_mach_vm_map_trap(void *saved_registers);
"""

# ---- syscall_sw.c: the row-15 gate (:126) ---------------------------------------------------

SSW_ROW_OLD = """#if IOS7_COMPAT_PLATFORM
/* 15 */\tMACH_TRAP(ios7lab_mach_vm_map_trap, 8, NULL, NULL),
"""
SSW_ROW_NEW = GATE_NEW + """
/* 15 */\tMACH_TRAP(ios7lab_mach_vm_map_trap, 8, NULL, NULL),
"""

# ---- mach_kernelrpc.c: the inner block gate (:59) -------------------------------------------

RPC_GATE_OLD = "#if IOS7_COMPAT_PLATFORM /* port/vm_map lab adapters: ARMPBA8/LEO only */"
RPC_GATE_NEW = (GATE_NEW + " /* port/vm_map lab adapters: ARMPBA8/LEO only */")

# ---- mach_kernelrpc.c: the map trap's prologue + selector + frame dump ----------------------
# One region replace: the selector swap (edit 4) and the frame dump (edit 5) are anchored together so
# neither can be half-applied, and the anchor is the WHOLE nine-line prologue-through-early-out, which
# is unique to `ios7lab_mach_vm_map_trap` (the three other lab adapters declare their frames in a
# different order -- `task_t task = port_name_to_task(regs[0])` before `int rv = ...` -- so they cannot
# match this block, and the `--expect`-exactly-once rule below refuses if they ever do).

RPC_MAP_OLD = """    uint32_t *regs = (uint32_t *)saved_registers;
    /* Runtime ABI selector is shared. */
    int rv = MACH_SEND_INVALID_DEST;
    uint64_t address64 = 0;
    mach_vm_offset_t address32 = 0;
    task_t task = TASK_NULL;
    static unsigned int logged = 0;
    if (!ios7_compat_vmabi_enabled())
        return rv;
"""

RPC_MAP_NEW = """    uint32_t *regs = (uint32_t *)saved_registers;
    /* Runtime ABI selector is shared. */
    int rv = MACH_SEND_INVALID_DEST;
    uint64_t address64 = 0;
    mach_vm_offset_t address32 = 0;
    task_t task = TASK_NULL;
    static unsigned int logged = 0;
#if defined(STAGE90_XNU_IOS7_TRAPS) && STAGE90_XNU_IOS7_TRAPS
    /* 1022: on CANCRO `ios7_compat_vmabi_enabled()` is a compile-time 0 (ios7_compat.h:11-21), so an
     * installed trap-15 row would return `MACH_SEND_INVALID_DEST` -- the shim's OWN sentinel
     * (osfmk/mach/message.h:692, 0x10000003) -- and the shim would take its slow leg instead of its
     * MIG demux: strictly worse than the row being absent (docs/1022-mach-trap-15-design.md section
     * 0.2, the T15-SENTINEL cell).  Read the SAME selector the traps -10/-12/-14 adapters read.
     * OFF compiles the tree's own `ios7_compat_vmabi_enabled()` line, verbatim, in the #else below. */
    if (!ios7_traps_enabled())
#else
    if (!ios7_compat_vmabi_enabled())
#endif
        return rv;
#if defined(STAGE90_XNU_IOS7_TRAPS) && STAGE90_XNU_IOS7_TRAPS
    /* 1022 DISPUTE-RESOLVER (records/1022-trap15-adjudication.txt): publish the register frame the
     * adapter ACTUALLY received, so the press decides the trap-15 wire question EMPIRICALLY rather
     * than on a static argument.  `docs/1022-mach-trap-15-design.md` section 9.3 leaves the frame
     * mapping UNMEASURED and `records/1022-trap15-wire.txt` section 4 disagrees with the design doc
     * on `regs[8]` (a duplicate `target`, not a protection).  This line names every slot the handler
     * reads, so the capture states which of the two readings the wire matches.  Its own counter (not
     * `logged`, which the `done:` printf below shares) keeps the two dumps independent. */
    {
        static unsigned int frame_logged = 0;
        if (frame_logged++ < 12)
            printf("IOS7LAB trap15 frame r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r6=%08x r8=%08x\\n",
                   regs[0], regs[1], regs[2], regs[3], regs[4], regs[5], regs[6], regs[8]);
    }
#endif
"""


class Refusal(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


# ---------------------------------------------------------------------------------------------------
# THE OFF BYTE-IDENTITY PROOF -- with the REAL PREPROCESSOR, over the WHOLE FILE, before a byte is
# written.  Four `clang -E -P` runs per file (HEAD, staged with the switch undefined, staged with =0,
# staged with =1) must give three identical outputs and a fourth, different one that is the only one
# carrying the ON shape.  Includes resolve through empty placeholder headers (`-nostdinc -I <tmp>`),
# which is faithful because these two files' OWN conditional directives evaluate only
# STAGE90_XNU_IOS7_TRAPS (and the board macros, which are compile-time 0 here because no -D is given);
# this script scans them and REFUSES the proof, writing nothing, if that set ever grows.  The
# `defined()`-FIRST rule is what makes the undefined run valid: a `#if` that wrote
# `STAGE90_XNU_IOS7_TRAPS` unguarded would evaluate the identifier (0, with a warning), turning OFF
# into a third value rather than the tree's bytes (`mi4-off-option-two-spellings`).
# ---------------------------------------------------------------------------------------------------

# The make-believe headers the `#include` lines may name.  gen_placeholder_headers() derives them from
# the file text, so a new `#include` needs no edit here.
import re

_INCLUDE = re.compile(r'^\s*#\s*include\s+[<"]([^>"]+)[>"]', re.M)

# The only conditional identifiers these two files evaluate.  `BOARD_CONFIG_*` are the board macros:
# they are NOT defined on the preprocessor command line (build_xnu_arm_kernel.sh passes
# -DBOARD_CONFIG_MSM8974_CANCRO=1, i.e. 1 == CANCRO, so IOS7_COMPAT_PLATFORM resolves to the `#else`
# arm == 0 on this board -- the same value the pool build sees).
_ALLOWED_IDENTS = frozenset((
    "STAGE90_XNU_IOS7_TRAPS", "IOS7_COMPAT_PLATFORM",
    "BOARD_CONFIG_ARMPBA8", "BOARD_CONFIG_QSD8250_LEO", "BOARD_CONFIG_MSM8974_CANCRO",
    "MACH_ASSERT", "CONFIG_REQUIRES_U32_MUNGING", "CONFIG_EMBEDDED", "XNU_TARGET_OS_OSX",
))

# `#if`/`#elif`/... plus the operators that are not identifiers.
_DIRECTIVE = re.compile(r'^\s*#\s*(if|elif|ifdef|ifndef)\b(.*)$')


def _directive_idents(text):
    """Every identifier appearing in a `#if`/`#elif`/`#ifdef`/`#ifndef` in `text` (keyword excluded)."""

    out = set()
    for line in text.splitlines():
        m = _DIRECTIVE.match(line)
        if not m:
            continue
        # A trailing C comment on a directive line (`#if IOS7_COMPAT_PLATFORM /* port lab only */`) is
        # not code; strip it first, or its words read as evaluated identifiers.
        body = m.group(2).split("/*", 1)[0].split("//", 1)[0]
        for ident in re.findall(r'[A-Za-z_][A-Za-z0-9_]*', body):
            out.add(ident)
    return out


def _placeholder_headers(text, incdir):
    """Create an empty header for every relative <...>/"..." include; absolute names are the tree's."""
    _inc_stub.stub([m.group(1) for m in _INCLUDE.finditer(text) if not
                    Path(m.group(1)).is_absolute() and ".." not in Path(m.group(1)).parts], incdir)


def _preprocess(path, defines, incdir):
    """`clang -E -P` over the whole file, includes resolved from empty placeholders."""
    argv = ["clang", "-E", "-P", "-x", "c", "-nostdinc", f"-I{incdir}"]
    for d in defines:
        argv.append(f"-D{d}")
    argv.append(str(path))
    p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        raise Refusal(7, f"clang -E failed on {path} ({' '.join(defines) or 'no defines'}): "
                         f"{p.stderr.strip()[:400]}")
    # Strip lines the preprocessor adds for real headers only; `-P` already suppresses linemarkers.
    return "\n".join(ln for ln in p.stdout.splitlines() if not ln.startswith("#"))


# The board defines the real pool build passes (tools/build_xnu_arm_kernel.sh:202).  CANCRO is 1 and
# ARMPBA8/QSD8250_LEO are undefined, so `IOS7_COMPAT_PLATFORM` (which names only those two,
# ios7_compat.h:5) resolves to 0 -- the value this board's build sees.
_BOARD_DEFS = ["BOARD_CONFIG_MSM8974_CANCRO=1"]
_SWITCH = "STAGE90_XNU_IOS7_TRAPS"


def verify_off(head_text, staged_text, rel, incdir):
    """True iff, WITH THE REAL PREPROCESSOR, the staged file's OFF text is the tree's own.

    `head_text` is the ORIGINAL text (the switch never present); `staged_text` is this patch's own.
    """
    idents = _directive_idents(head_text) | _directive_idents(staged_text)
    unknown = idents - _ALLOWED_IDENTS - {"defined"}
    if unknown:
        return False, (f"{rel}: the file's #if directives evaluate identifier(s) this proof does not "
                       f"model: {sorted(unknown)}. Add them to _ALLOWED_IDENTS (with a citation) or "
                       f"the OFF byte-identity proof would be certifying a property it cannot see")
    incdir = Path(incdir)
    _placeholder_headers(head_text, incdir)
    hp, sp = incdir / "head.c", incdir / "staged.c"
    hp.write_text(head_text)
    sp.write_text(staged_text)
    try:
        head = _preprocess(hp, _BOARD_DEFS, incdir)
        off_undef = _preprocess(sp, _BOARD_DEFS, incdir)
        off_zero = _preprocess(sp, _BOARD_DEFS + [f"{_SWITCH}=0"], incdir)
        on_one = _preprocess(sp, _BOARD_DEFS + [f"{_SWITCH}=1"], incdir)
    except Refusal as e:
        return False, str(e)
    if off_undef != off_zero:
        return False, (f"{rel}: the switch-UNDEFINED and switch-=0 preprocessed texts DIFFER - OFF "
                       f"has two spellings ([[mi4-off-option-two-spellings]]); `defined()` is not "
                       f"first somewhere")
    if off_undef != head:
        return False, (f"{rel}: the staged file's OFF preprocessed text is NOT the tree's own - an "
                       f"OFF arm does not reproduce HEAD byte for byte")
    if on_one == off_undef:
        return False, (f"{rel}: the switch=1 preprocessed text is IDENTICAL to OFF - the switch "
                       f"reached nothing in this file")
    return True, ""


def unstaged_text(text):
    """Reverse this patch's four edits, to recover the tree's ORIGINAL text from a staged file."""
    for old, new in ((SSW_EXTERN_OLD, SSW_EXTERN_NEW), (SSW_ROW_OLD, SSW_ROW_NEW),
                     (RPC_GATE_OLD, RPC_GATE_NEW), (RPC_MAP_OLD, RPC_MAP_NEW)):
        if text.count(new) == 1:
            text = text.replace(new, old, 1)
    return text


def run_verify_off(ssw_staged, rpc_staged):
    """Both files, per-file.  Returns (ok, message)."""
    with tempfile.TemporaryDirectory() as td:
        for rel, staged in ((XNU_SYSCALL_SW, ssw_staged), (XNU_RPC, rpc_staged)):
            ok, msg = verify_off(unstaged_text(staged), staged, rel, td)
            if not ok:
                return False, msg
    return True, ""


def plan_region(text, what, old, new):
    """Replace the region `old` with `new`, asserting it occurs EXACTLY ONCE.

    Idempotence is keyed on `new`: once staged, `old` occurs 0 times and `new` once.  Any other state
    (a partial edit, a double edit, a hand-edited region) is REFUSED, never re-guessed.
    """
    n_old = text.count(old)
    n_new = text.count(new)
    if n_old == 0 and n_new == 1:
        return text, False, f"{what}: already staged"
    if n_old != 1 or n_new != 0:
        raise Refusal(4, f"{what}: found {n_old} original region(s) and {n_new} staged copy/copies, "
                         f"expected exactly one original and zero-or-one staged - the region was "
                         f"edited by hand; not repaired in place")
    return text.replace(old, new, 1), True, f"{what}: staged"


def main() -> int:
    argv = sys.argv[1:]
    apply_ = "--apply" in argv
    verify_only = "--verify-off" in argv
    argv = [a for a in argv if a not in ("--apply", "--verify-off")]
    if len(argv) != 1:
        print("usage: patch_d13_mach_trap15.py <xnu-tree-root> [--apply|--verify-off]",
              file=sys.stderr)
        return 2
    root = Path(argv[0])
    ssw, rpc = root / XNU_SYSCALL_SW, root / XNU_RPC
    for path in (ssw, rpc):
        if not path.is_file():
            print(f"patch_d13_mach_trap15: no {path} (D13 tree not provisioned?)", file=sys.stderr)
            return 2

    # Plan every edit first: a refusal anywhere writes NOTHING (no partial application).
    try:
        ssw_text, ch_ssw_a, note_a = plan_region(
            ssw.read_text(), f"{XNU_SYSCALL_SW}: extern-decl gate (:102)", SSW_EXTERN_OLD, SSW_EXTERN_NEW)
        ssw_text, ch_ssw_b, note_b = plan_region(
            ssw_text, f"{XNU_SYSCALL_SW}: row-15 gate (:126)", SSW_ROW_OLD, SSW_ROW_NEW)

        rpc_text, ch_rpc_a, note_c = plan_region(
            rpc.read_text(), f"{XNU_RPC}: inner lab-adapter gate (:59)", RPC_GATE_OLD, RPC_GATE_NEW)
        rpc_text, ch_rpc_b, note_d = plan_region(
            rpc_text, f"{XNU_RPC}: trap-15 selector + dispute-resolver frame dump (:217)", RPC_MAP_OLD,
            RPC_MAP_NEW)
    except Refusal as e:
        print(f"patch_d13_mach_trap15: REFUSING: {e}", file=sys.stderr)
        return e.code

    notes = (note_a, note_b, note_c, note_d)
    for note in notes:
        print(f"  {note}")
    staged = []
    if ch_ssw_a or ch_ssw_b:
        staged.append(XNU_SYSCALL_SW)
    if ch_rpc_a or ch_rpc_b:
        staged.append(XNU_RPC)

    # A cross-file structural assertion, BEFORE anything is written: the two `> 50` gates must both be
    # the widened spelling, or the row and its body disagree (the row would reference a symbol that is
    # still compiled out -- a link error, not a silent pass, but this catches it in plan mode).
    #
    # **1023 COMPOSITION FIX (records/1023-patcher-composition.txt).**  Rung 1023 opens row 24 by
    # widening a THIRD `#if IOS7_COMPAT_PLATFORM` in this same file
    # (`tools/patch_d13_mach_trap_ports.py`), which makes this count 3.  The load-bearing property was
    # never the number 2 -- it was that THIS rung's two gates moved and the rows it DEFERS kept their
    # bare gate -- so the check is written that way: at least the two this rung widened, and the five
    # deferral anchors still BARE (a widened neighbour cannot masquerade as deferred because each
    # anchor is the gate line plus its own trap's row line).  A tree on which this rung previously
    # succeeded stages the same bytes; a fresh tree still stages both (the count can only be >= 2 after
    # the plan edits above, which replace exactly one bare line each).
    if ssw_text.count(GATE_NEW) < 2:
        print(f"patch_d13_mach_trap15: REFUSING: {XNU_SYSCALL_SW} would carry "
              f"{ssw_text.count(GATE_NEW)} widened gate(s), expected at least 2 (the extern block + "
              f"row 15)", file=sys.stderr)
        return 5
    # The DEFERRED rows (this rung opens rows 15 and the VM wire; 1023 may open row 24; rows 24/25/
    # 41/42 stay bare from THIS rung's side) must still carry their bare spelling.  Each anchor is the
    # gate line PLUS its own trap's row line, so a widened neighbour cannot masquerade as deferred.
    # Rows 24/25/41/42 are checked only when still bare: 1023 opens row 24, so its anchor is the one
    # deferral this rung tolerates losing (the whole point of the fix above).
    SSW_DEFERRAL_ANCHORS = (
        ("row 25", GATE_OLD + "\n/* 25 */\tMACH_TRAP(ios7lab_mach_port_destruct_trap"),
        ("rows 41/42", GATE_OLD + "\n/* 41 */\tMACH_TRAP(ios7lab_mach_port_guard_trap"),
    )
    for what, anchor in SSW_DEFERRAL_ANCHORS:
        if ssw_text.count(anchor) != 1:
            print(f"patch_d13_mach_trap15: REFUSING: {XNU_SYSCALL_SW}'s {what} deferral anchor occurs "
                  f"{ssw_text.count(anchor)} time(s), expected 1 -- this rung opens rows 15 and the "
                  f"VM wire only; 1023 may open row 24 but rows 25/41/42 stay bare",
                  file=sys.stderr)
            return 5
    # TWO widened gates in mach_kernelrpc.c, and both are correct: the file-wide gate at :39 ALREADY
    # carried this exact spelling (the 994 rung's, read by value this session) and this patch widens
    # the INNER lab-adapter gate at :59 to match.  Asserting 2 -- and that no BARE gate survives in
    # the file -- is the checkable form: a build where :59 did not move leaves 1 and refuses.
    # The bare count is a WHOLE-LINE test: the widened spelling's own text begins with `#if
    # IOS7_COMPAT_PLATFORM`, so a substring test would count the widened gates as bare ones.
    n_bare = sum(1 for ln in rpc_text.split("\n") if ln == GATE_OLD)
    if rpc_text.count(GATE_NEW) != 2 or n_bare != 0:
        print(f"patch_d13_mach_trap15: REFUSING: {XNU_RPC} would carry "
              f"{rpc_text.count(GATE_NEW)} widened gate(s) and {n_bare} bare gate line(s), expected "
              f"2 widened (the pre-existing file-wide gate at :39 plus the inner lab-adapter gate at "
              f":59) and 0 bare - the row's body would not compile on CANCRO",
              file=sys.stderr)
        return 5

    if verify_only:
        # The steady-state check a build runs on an ALREADY-staged tree: re-derive the tree's own text
        # from the staged files, then prove OFF byte-identity with the real preprocessor.  Writes
        # nothing.
        ok, msg = run_verify_off(ssw_text, rpc_text)
        print(f"patch_d13_mach_trap15: OFF byte-identity proof {'PASS' if ok else 'FAIL'}")
        if not ok:
            print(f"patch_d13_mach_trap15: {msg}", file=sys.stderr)
            return 1
        return 0

    if not apply_:
        print(f"patch_d13_mach_trap15: PLAN only (no --apply); would stage "
              f"{', '.join(staged) if staged else 'nothing'}")
        return 0

    # The OFF byte-identity proof runs BEFORE the write, exactly as patch_d13_undef_raise.py does.
    ok, msg = run_verify_off(ssw_text, rpc_text)
    print(f"patch_d13_mach_trap15: OFF byte-identity proof {'PASS' if ok else 'FAIL'}")
    if not ok:
        print(f"patch_d13_mach_trap15: REFUSING to write - {msg} (the tree is untouched)",
              file=sys.stderr)
        return 1

    if ch_ssw_a or ch_ssw_b:
        ssw.write_text(ssw_text)
    if ch_rpc_a or ch_rpc_b:
        rpc.write_text(rpc_text)
    print(f"patch_d13_mach_trap15: {'staged ' + ', '.join(staged) if staged else 'nothing to do'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())