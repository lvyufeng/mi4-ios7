#!/usr/bin/env python3
"""Stage 1020's `udf`-raise fix into the D13 tree's `osfmk/arm/trap.c`.

THE DEFECT THIS ANSWERS, BY VALUE.  1019 root-caused the resident no-return: pid 1's
`udf #254` re-executes forever.  In `sleh_undef`'s user-mode arm the VFP/NEON false-positive
path (`thread->machine.vfp_dirty = 0; if (!vfp_enable) { ...enable... } return;`) takes an
unconditional `return` for EVERY undefined instruction whose encoding is not dyld's own
`0xfedeffe7` - including the `udf #254` that pid 1 keeps re-faulting.  The VFP left arm
re-enables VFP once and returns; the PC is never advanced and the same `udf` faults again, so
the kernel loops instead of raising.  This patch moves the `return;` INSIDE the
`if (!vfp_enable)` block, so that a `udf` arriving with VFP ALREADY enabled FALLS THROUGH to
the existing `printf` + `EXC_BAD_INSTRUCTION` (`sleh_undef`'s own raise path, below this
block) instead of silently looping.

WHAT IS INSERTED.  The `#if` branch is the new behaviour; the `#else` branch is the tree's
ORIGINAL block, byte for byte, so an unset switch leaves the preprocessed text IDENTICAL to
HEAD (`mi4-off-option-two-spellings`: `defined()` is written FIRST in the gate, so an unset
switch never evaluates the identifier).  Everything between the two idempotency markers
`/* IOS7UNDEFRAISE_BEGIN */` / `/* IOS7UNDEFRAISE_END */` is this script's chunk and nothing
else's - independent of the dyld witness's `IOS7WITNESS_*` markers, so the two patches
coexist.

OFF IS BYTE-IDENTICAL, proven with the REAL PREPROCESSOR over the WHOLE FILE before a byte
is written: four `clang -E -P` runs (HEAD, staged with the switch undefined, staged with
`=0`, staged with `=1`) must give three identical outputs and a fourth, different one that
is the only one carrying the ON shape.  Includes resolve through empty placeholder headers,
faithful here because trap.c's OWN conditional directives evaluate only
`BOARD_CONFIG_QSD8250_LEO`, `BOARD_CONFIG_ARMPBA8`, `STAGE90_XNU_DYLD_WITNESS`,
`STAGE90_XNU_GLOBAL_FIX`, `STAGE90_XNU_UNDEF_RAISE` and `STAGE90_XNU_IOS7_TRAPS`; the script
scans them and REFUSES the proof, writing nothing, if that set ever grows, rather than
certifying a property it can no longer see.

THE ON ASSERTION IS STRUCTURAL, NOT LEXICAL.  Both branches carry the SAME code tokens, so
no code word or string literal distinguishes them (and the markers are comments, which
`clang -E` strips - asserting on one would be a check false by construction).  What DOES
move is the `return`: OFF ends the block `vfp_enable = TRUE; } return;`, ON ends it
`vfp_enable = TRUE; return; }` - so the proof asserts that the ON preprocessed text matches
the ON shape and NOT the OFF shape, and that HEAD and both OFF texts match the OFF shape and
NOT the ON shape.  That is exactly the semantic property this patch moves, checked on the
text the compiler sees.

Idempotent, text based: a file already carrying the two markers and the current chunk returns
"already"; a file carrying an OLDER revision (markers present, chunk different) is re-staged
(the marker-bounded region is removed and the current chunk inserted); an anchor that is not
found exactly once REFUSES (exit 3); a partial or double edit REFUSES (exit 4), the file
untouched.  `--dry-run` decides and proves without writing; `--verify-off` runs the proof
alone - which is how this tool can be exercised on a tree it must not edit.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import importlib.util as _ilu, os as _os
_inc_stub = _ilu.module_from_spec(_s := _ilu.spec_from_file_location(
    "inc_stub", _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "inc_stub.py")))
_s.loader.exec_module(_inc_stub)

REL = "osfmk/arm/trap.c"

# The file this patch was written for, by content - not by name.
IDENTITY = "void sleh_undef(arm_saved_state_t * state)"

SWITCH = "STAGE90_XNU_UNDEF_RAISE"
GATE = f"#if defined({SWITCH}) && {SWITCH}"

MARK = "/* IOS7UNDEFRAISE_BEGIN */"
_END = "/* IOS7UNDEFRAISE_END */"

# The anchor line occurs exactly ONCE in the file (the user-mode arm of `sleh_undef`), and the
# ORIGINAL block that follows it - ending at the `return;` that this patch moves - occurs exactly
# once too.  Both counts are asserted before anything is written.
ANCHOR = "            thread->machine.vfp_dirty = 0;\n"

ORIG_BLOCK = """            if (!thread->machine.vfp_enable) {
                /*
                 * Enable VFP.
                 */
                vfp_enable_exception(TRUE);
                vfp_context_load(&thread->machine.vfp_regs);
                /*
                 * Continue user execution.
                 */
                thread->machine.vfp_enable = TRUE;
            }
            return;
"""

# The inserted chunk: the new behaviour in the `#if` branch, the original block VERBATIM in the
# `#else` branch (so OFF is byte-identical), bounded by markers that are this script's alone.
ON_BRANCH = (
    GATE + "\n"
    "            /* 1020: the user-mode VFP/NEON false-positive returned for every undefined\n"
    "             * instruction, so pid 1's udf #254 re-faulted forever.  Only re-enable VFP and\n"
    "             * return when VFP was actually off; otherwise fall through to the printf +\n"
    "             * EXC_BAD_INSTRUCTION below, which is the raise this arm never reached. */\n"
    "            if (!thread->machine.vfp_enable) {\n"
    "                vfp_enable_exception(TRUE);\n"
    "                vfp_context_load(&thread->machine.vfp_regs);\n"
    "                thread->machine.vfp_enable = TRUE;\n"
    "                return;\n"
    "            }\n"
    "            /* VFP was already enabled and the instruction is still undefined: fall through to\n"
    "             * the printf + EXC_BAD_INSTRUCTION below. */\n"
    "#else\n"
)

CHUNK = MARK + "\n" + ON_BRANCH + ORIG_BLOCK + "#endif\n" + _END + "\n"

# The identifiers trap.c's own conditional directives evaluate.  The placeholder-include OFF proof
# is faithful to the real build ONLY while this set holds (a macro invented by a header and tested
# in a directive would be invisible to a placeholder), so the proof refuses if it ever grows.
ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    # 1038 wraps its SECOND copy of the hook in `#if !defined(WATCH_LE_H_STANDIN)`. Same reasoning as
    # the other 1038 entries: OFF drives this identifier to its "not defined" arm, the block that names
    # it compiles out, and the OFF text stays HEAD's. Without it the proof refuses before comparing
    # anything ("those may come from a header"), which is what stopped the whole 1020 rung.
    "WATCH_LE_H_STANDIN",
    "STAGE90_XNU_DYLD_WITNESS",
    "STAGE90_XNU_WATCH_LE",  # 1038 (tools/patch_d13_watch_le.py)
    "WATCH_LE_STATICS_DEFINED", "chunk", "arm",  # 1038's chunk names
    # 1038 also wraps its SECOND copy of the hook in `#if !defined(WATCH_LE_H_STANDIN)`. Same reasoning
    # as the other 1038 entries: OFF drives this identifier to its "not defined" arm, the block that
    # names it is compiled out, and the OFF text is HEAD's. Without it the proof refuses before it has
    # compared anything - "those may come from a header" - which is what stopped the whole 1020 rung.

    "STAGE90_XNU_GLOBAL_FIX",
    "STAGE90_XNU_UNDEF_RAISE",
    "STAGE90_XNU_IOS7_TRAPS",
    # 1025: the failed-fault publisher (tools/patch_d13_ustack_probe.py) edits the SAME file
    # (osfmk/arm/trap.c) and adds a `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE`
    # block in the usermode DATA-abort arm, far below `sleh_undef`.  The identity proof below drives
    # the OFF arm with the OTHER switch still `undefined`, so the probe block stays compiled OUT and
    # the OFF text is still HEAD's - allowing the identifier is what makes the two edits compose
    # ([[mi4-one-value-two-definitions]]: a file's directive identifiers are a shared namespace).
    "STAGE90_XNU_USTACK_PROBE",
    # 1026: the abort-entry discriminator (tools/patch_d13_abt_entry_probe.py) edits the SAME file and
    # adds a `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE` block INSIDE
    # 1025's publisher in the usermode DATA-abort arm, still far below `sleh_undef`.  Same shared
    # namespace rule, same OFF reasoning: the OFF arm drives this identifier `undefined` too, so the
    # 1026 block is compiled OUT and the OFF text remains HEAD's ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_ABT_ENTRY_PROBE",
    # 1028: the H2 stack-headroom FIX (tools/patch_d13_h2_stack_headroom.py) edits bsd/kern/kern_exec.c's
    # `create_unix_stack`, NOT trap.c -- but a file's directive identifiers are a SHARED namespace and
    # kern_exec.c already carries 1025/1026's switches ([[mi4-one-file-many-rungs]]).  The OFF arm below
    # drives this identifier `undefined` too, so the 1028 block is compiled OUT and the OFF text remains
    # HEAD's.
    "STAGE90_XNU_H2_STACK_HEADROOM",
    # 1029: the READER PROBE (tools/patch_d13_reader_probe.py) edits the SAME file (osfmk/arm/trap.c),
    # adding a Site A block in the usermode DATA-abort arm, well below `sleh_undef`.  Same shared
    # namespace rule, same OFF reasoning: the OFF arm drives this identifier `undefined` too, so the
    # 1029 block is compiled OUT and the OFF text remains HEAD's ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_READER_PROBE",
    # 1030's WRITER PROBE (tools/patch_d13_writer_probe.py) edits the SAME file (osfmk/arm/trap.c),
    # adding a Site A block in the usermode DATA-abort arm, far below `sleh_undef` where this witness
    # lives.  Same shared-namespace rule, same OFF reasoning ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_WRITER_PROBE",
    "STAGE90_XNU_CALLER_PROBE",
    # 1033's EVAL FRAME (tools/patch_d13_eval_frame.py) edits the SAME file, adding a block inside
    # 1025's publisher after 1031's.  Same shared-namespace rule, same OFF reasoning
    # ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_EVAL_FRAME",
    # 1035's PC CARRIER (tools/patch_d13_pc_carrier.py) edits the SAME file, adding a block after
    # 1033's inside 1025's publisher.  Same shared-namespace rule, same OFF reasoning
    # ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_PC_CARRIER",
    # 1036's PC-CARRIER CALLER (tools/patch_d13_pc_carrier_caller.py) edits the SAME file, adding a
    # block after 1035's inside 1025's publisher.  Same shared-namespace rule, same OFF reasoning
    # ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_PC_CARRIER_CALLER",
    # 1037's TRAP FRAME (tools/patch_d13_trap_frame.py) edits the SAME file, adding a block after
    # 1036's inside 1025's publisher.  Same shared-namespace rule, same OFF reasoning
    # ([[mi4-one-file-many-rungs]]).
    "STAGE90_XNU_TRAP_FRAME",
    "STAGE90_XNU_FRAME_CARRIER"}  # 1039 (tools/patch_d13_frame_carrier.py)
_DIRECTIVE = re.compile(r"^[ \t]*#[ \t]*(?:if|elif|ifdef|ifndef)\b(.*)$", re.M)
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_WORDS = {"defined", "if", "elif", "ifdef", "ifndef"}
_INCLUDE = re.compile(r"^[ \t]*#[ \t]*include[ \t]*[<\"]([^>\"]+)[>\"]", re.M)

# The semantic discriminator, checked on the PREPROCESSED text (the compiler's own view).  Both
# branches carry the same code tokens, so no word or literal separates them; what moves is the
# `return`: ON ends the block `vfp_enable = TRUE; return; }`, OFF ends it `vfp_enable = TRUE; }
# return;`.  Whitespace spans the comment-stripped lines of the preprocessor's output.
ON_SHAPE = re.compile(r"vfp_enable = TRUE;\s*return;\s*\}")
OFF_SHAPE = re.compile(r"vfp_enable = TRUE;\s*\}\s*return;")


def refuse(msg: str, code: int):
    print(f"patch_d13_undef_raise: REFUSING: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _insert(old: str) -> str:
    """`old` with the ORIGINAL block after ANCHOR replaced by CHUNK; every count asserted."""
    n = old.count(ANCHOR)
    if n != 1:
        refuse(f"{REL} has {n} `thread->machine.vfp_dirty = 0;` anchor line(s), expected exactly 1 "
               f"- this is not the tree state this patch was written for", 3 if n == 0 else 4)
    m = old.count(ORIG_BLOCK)
    if m != 1:
        refuse(f"{REL} has {m} original VFP-return block(s), expected exactly 1 - this is not the "
               f"tree state this patch was written for", 3 if m == 0 else 4)
    i = old.index(ANCHOR) + len(ANCHOR)
    if not old.startswith(ORIG_BLOCK, i):
        refuse(f"{REL}'s anchor is not immediately followed by the exact original block - the block "
               f"was edited by hand or by another script", 3)
    return old[:i] + CHUNK + old[i + len(ORIG_BLOCK):]


def stage(old: str):
    """(text, status, head) with status in {"staged", "already", "restage"} - every gate decided
    before a byte is written; SystemExit on a partial or foreign edit, with the file untouched
    (3 = anchor/block mismatch, 4 = partial/double edit).  `head` is the text the write is proved
    against (the original for "staged", the marker-stripped predecessor for "restage")."""
    marks = old.count(MARK)
    ends = old.count(_END)
    if marks == 0:
        if ends != 0:
            refuse(f"{REL} carries {ends} {_END} marker(s) but no {MARK} - a partial or foreign "
                   f"edit", 4)
        return _insert(old), "staged", old
    if marks != 1 or ends != 1:
        refuse(f"{REL} carries {marks} {MARK} / {ends} {_END} marker(s), expected 0/0 (unstaged) or "
               f"1/1 (staged)", 4)
    if CHUNK in old:
        return old, "already", None
    stripped = strip_marked(old)
    if IDENTITY not in stripped or stripped.count(ANCHOR) != 1 or stripped.count(ORIG_BLOCK) != 1:
        refuse(f"re-staging would remove the file's identity text - the markers do not bound this "
               f"script's chunk", 4)
    new, _status, _head = stage(stripped)
    return new, "restage", stripped


def unstaged(text: str) -> str:
    """`text` with this script's chunk removed - the inverse of stage(), for the proof a staged file
    runs against itself (HEAD itself is not available once the tree is staged).

    **THE INVERSE IS A REPLACEMENT, NOT A DELETION.**  `stage()` substitutes `ORIG_BLOCK` with `CHUNK`,
    and `CHUNK` EMBEDS `ORIG_BLOCK` verbatim (its `#else` arm is the file's pre-existing bytes, so that
    switch-OFF compiles them exactly).  Deleting `CHUNK` would therefore drop the original block too and
    hand the OFF-identity proof a HEAD with a HOLE where the `if (!vfp_enable) { ... } return;` used to be
    - which is why the proof read `DIFFERENT FROM HEAD` (a 237-char shorter HEAD) on a correctly staged
    tree.  Restore `ORIG_BLOCK` so `unstaged(stage(x)) == x`."""
    if text.count(CHUNK) != 1:
        refuse(f"cannot reconstruct the unstaged text: {text.count(CHUNK)} chunk(s)", 4)
    return text.replace(CHUNK, ORIG_BLOCK, 1)


def strip_marked(text: str) -> str:
    """`text` with the IOS7UNDEFRAISE region removed, BEGIN marker through END marker inclusive.

    Version-agnostic on purpose: the markers bound whatever chunk a PREVIOUS revision inserted, so
    this is what a re-stage (tool upgraded, tree still carrying the old chunk) removes before the
    current one goes in.  Called only on a file whose BEGIN count is already exactly 1."""
    out, inside, regions, removed = [], False, 0, 0
    for line in text.splitlines(keepends=True):
        if not inside and MARK in line:
            inside, regions = True, regions + 1
        if inside:
            removed += 1
            if _END in line:
                inside = False
            continue
        out.append(line)
    if inside or regions != 1:
        refuse(f"cannot re-stage: {regions} marker region(s), unterminated={inside}", 4)
    print(f"  re-stage: removed {removed} line(s) in {regions} marker-bounded region(s) - the "
          f"markers bound whatever version's chunk was there")
    return "".join(out)


def if_identifiers(text: str):
    return {w for expr in _DIRECTIVE.findall(text) for w in _IDENT.findall(expr) if w not in _WORDS}


def cpp_probe(text: str, defines, workdir: Path, tag: str) -> str:
    """The REAL preprocessor, over the WHOLE file, every #include resolved to an empty file."""
    inc = workdir / f"inc_{tag}"
    _inc_stub.stub(_INCLUDE.findall(text), inc)
    src = workdir / f"{tag}.c"
    src.write_text(text)
    argv = ["clang", "-E", "-P", "-x", "c", "-nostdinc", f"-I{inc}"] + list(defines) + [str(src)]
    try:
        return subprocess.run(argv, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        refuse("no clang on PATH - the OFF byte-identity proof is the real preprocessor's, and an "
               "unproven write is not made", 5)
    except subprocess.CalledProcessError as exc:
        refuse(f"the preprocessor failed on the {tag} state: {exc.stderr.strip()[:400]}", 5)


def verify_off(head: str, staged: str, workdir: Path) -> bool:
    """True iff the real preprocessor makes OFF (undefined and =0) byte-identical to HEAD, and ON
    (=1) differs and carries the moved-`return` shape that HEAD and both OFF texts do not."""
    idents = if_identifiers(staged)
    print(f"  conditional identifiers in the file: {', '.join(sorted(idents))}")
    extra = sorted(i for i in idents if i not in ALLOWED_IF_IDENTIFIERS)
    if extra:
        print(f"patch_d13_undef_raise: FAIL: {REL}'s directives also evaluate {', '.join(extra)} - "
              f"those may come from a header, which the placeholder-include proof cannot see, so the "
              f"OFF equality is NOT certified", file=sys.stderr)
        return False
    board = ("-DBOARD_CONFIG_MSM8974_CANCRO=1",)
    s_head = cpp_probe(head, board, workdir, "head")
    s_none = cpp_probe(staged, board, workdir, "staged_undefined")
    s_zero = cpp_probe(staged, board + (f"-D{SWITCH}=0",), workdir, "staged_zero")
    s_one = cpp_probe(staged, board + (f"-D{SWITCH}=1",), workdir, "staged_one")
    ok = True
    for tag, got in (("undefined", s_none), ("= 0", s_zero)):
        same = got == s_head
        print(f"  OFF ({SWITCH} {tag}): preprocessed output is "
              f"{'IDENTICAL to HEAD' if same else 'DIFFERENT FROM HEAD'} ({len(got)} chars)")
        ok = ok and same
    # ON: different from HEAD, carries the ON shape, does NOT carry the OFF shape.
    on_shape = bool(ON_SHAPE.search(s_one))
    off_shape = bool(OFF_SHAPE.search(s_one))
    on_clean = on_shape and not off_shape and s_one != s_head
    # OFF (HEAD and both OFF states): carry the OFF shape, NOT the ON shape.
    off_ok = all(bool(OFF_SHAPE.search(s)) and not ON_SHAPE.search(s)
                 for s in (s_head, s_none, s_zero))
    print(f"  shape: ON ({SWITCH} = 1) has `vfp_enable = TRUE; return; }}` = {on_shape}, "
          f"has `vfp_enable = TRUE; }} return;` = {off_shape}, differs from HEAD = {s_one != s_head}"
          f" -> ON correct = {on_clean}")
    print(f"  shape: HEAD and both OFF states have the OFF shape and not the ON shape = {off_ok}")
    if not on_clean:
        print(f"patch_d13_undef_raise: FAIL: the ON branch does not move the `return` inside the "
              f"`if (!vfp_enable)` block on the text the compiler sees", file=sys.stderr)
    if not off_ok:
        print(f"patch_d13_undef_raise: FAIL: an OFF text carries the ON shape - the OFF identity is "
              f"not the tree's original structure", file=sys.stderr)
    return ok and on_clean and off_ok


def main() -> int:
    argv = sys.argv[1:]
    dry = "--dry-run" in argv
    verify_only = "--verify-off" in argv
    argv = [a for a in argv if a not in ("--dry-run", "--verify-off")]
    if len(argv) != 1:
        print("usage: patch_d13_undef_raise.py <xnu-tree-root> [--dry-run|--verify-off]",
              file=sys.stderr)
        return 2
    path = Path(argv[0]) / REL
    if not path.is_file():
        print(f"patch_d13_undef_raise: no {REL} under {argv[0]} (D13 tree not provisioned?)",
              file=sys.stderr)
        return 2
    old = path.read_text()
    if IDENTITY not in old:
        refuse(f"{REL} carries no `{IDENTITY}` - this is not the file this patch was written for", 3)

    new, status, head = stage(old)
    print(f"patch_d13_undef_raise: {path}")
    if status == "already":
        head = unstaged(new)
        print("  already staged: the OFF proof below runs against the text this script's own chunk "
              "is removed from (HEAD itself is not available once the tree is staged)")
    elif status == "restage":
        print("  re-staging over an older revision: the OFF proof below runs against the "
              "marker-stripped text - the previous chunk is removed by marker, not by content, so "
              "that text's provenance is the previous stage's own OFF proof, and its identity string "
              "and both anchors are re-checked before the insert")
    with tempfile.TemporaryDirectory() as td:
        good = verify_off(head, new, Path(td))
    print(f"patch_d13_undef_raise: OFF byte-identity proof {'PASS' if good else 'FAIL'}")
    if verify_only:
        return 0 if good else 1
    if not good:
        print("patch_d13_undef_raise: REFUSING to write - the OFF byte-identity proof did not pass "
              "(the file is untouched)", file=sys.stderr)
        return 1
    if status == "already":
        print("patch_d13_undef_raise: nothing to do")
        return 0
    if dry:
        if status == "restage":
            print(f"  --dry-run: would RE-STAGE (marker-bounded strip of the older chunk, then "
                  f"{len(CHUNK.splitlines())} lines); nothing written")
        else:
            print(f"  --dry-run: would replace the VFP-return block at the anchor with "
                  f"{len(CHUNK.splitlines())} lines; nothing written")
        return 0
    path.write_text(new)
    if status == "restage":
        print(f"patch_d13_undef_raise: re-staged the udf-raise fix into {REL} (marker-bounded strip "
              f"of the older revision, then insert)")
    else:
        print(f"patch_d13_undef_raise: staged the udf-raise fix into {REL}")
    print(f"patch_d13_undef_raise: NOW RE-RUN tools/build_xnu_arm_kernel.sh with "
          f"XNU_KERNEL_EXTRA_DEFINES=-DSTAGE90_XNU_UNDEF_RAISE=1 AND STAGE90_XNU_UNDEF_RAISE=1 "
          f"exported (osfmk/arm/trap.c is a POOL object: the linked image only LINKS "
          f"out/xnu_kernel_obj_d13/osfmk_arm_trap.o)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())