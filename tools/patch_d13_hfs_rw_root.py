#!/usr/bin/env python3
"""Stage 905 B2's read-write-root clear into the D13 tree's `bsd/hfs/hfs_vfsops.c`.

THE RUNG THIS ANSWERS.  905 B2 makes the HFS+ root mount READ-WRITE.  The only blocker is
`vfs_rootmountalloc_internal` hard-coding `mp->mnt_flag = MNT_RDONLY | MNT_ROOTFS`
(`bsd/vfs/vfs_subr.c`), latched ONCE by `hfs_mountfs` from `vfs_isrdonly(mp)`.  This patch inserts a
guarded `vfs_clearflags(mp, (u_int64_t)MNT_RDONLY);` into `hfs_mountroot`, immediately BEFORE its
`hfs_mountfs(rvp, mp, NULL, 0, context)` call - the ONE place between the flag being set and being
read, without touching `vfs_subr.c` (which would move every mount in the image).

THE SWITCH, AND WHY IT IS `STAGE90_HFS_ROOT_RW` AND NOT `STAGE90_XNU_HDD_WRITE`.  This is a POOL
file (`tools/build_xnu_arm_kernel.sh` compiles `bsd/hfs/*.c` into `out/xnu_kernel_obj_d13/`), so the
guard must be a macro THAT BUILD defines.  `STAGE90_XNU_HDD_WRITE` is defined ONLY by
`src/entry/build_entry.sh` for the entry translation units; `tools/build_xnu_arm_kernel.sh` contains
ZERO occurrences of it (measured), so an `#if STAGE90_XNU_HDD_WRITE` here would see an UNDEFINED
identifier -> 0 -> the clear OFF, while the arm's record named HDD_WRITE=1: the root would mount
`MNT_RDONLY`, no `B_WRITE` would ever be issued, and the rung's subject would be absent from the
image its record names (`mi4-off-option-two-spellings`).  `STAGE90_HFS_ROOT_RW` IS the pool switch
(`build_xnu_arm_kernel.sh:720`: `[[ ${HFS_PORT:-0} -eq 1 && ${STAGE90_XNU_HFS_ROOT_RW:-0} -eq 1 ]]
&& DEFINES+=(-DSTAGE90_HFS_ROOT_RW=1)`), and `build_entry.sh`'s write arm already REFUSES
`STAGE90_XNU_HDD_WRITE=1` unless `STAGE90_XNU_HFS_ROOT_RW=1` (build_entry.sh:921) - so gating here on
`STAGE90_HFS_ROOT_RW` makes the rw-clear half automatic exactly when the write half is on.

WHAT IS INSERTED.  An INSERTION, not a mutation: the anchor line itself is left byte-for-byte, and a
guarded clear is placed before it.  An unset / `=0` switch emits NOTHING (the `#if` is false), so the
preprocessed text is IDENTICAL to the un-staged file; `=1` emits the clear.  Everything between the
two idempotency markers `/* IOS7HFSRW_BEGIN */` / `/* IOS7HFSRW_END */` is this script's chunk and
nothing else's.

OFF IS BYTE-IDENTICAL, proven with the REAL PREPROCESSOR over the WHOLE FILE before a byte is
written: four `clang -E -P` runs (HEAD, staged with the switch undefined, staged with `=0`, staged
with `=1`) must give three identical outputs and a fourth, different one that is the only one carrying
the clear.  Includes resolve through empty placeholder headers, faithful here because this file's OWN
conditional directives evaluate only nine pre-existing configuration macros plus `STAGE90_HFS_ROOT_RW`;
the script scans them and REFUSES the proof, writing nothing, if that set grows.

LEGACY NORMALISATION.  The D13 tree has ALREADY carried the clear in a prior, marker-less form
(`tools/stage_d13_root_rw.sh` -> `tools/hfs_patch_root_rw.py`, guarded `#if STAGE90_HFS_ROOT_RW ... #endif`
with no markers).  That form is detected BY ITS EXACT BYTES and re-staged into the marker-bounded
form (the marker lines are added; the guard and the clear are kept).  A guard that is present but is
NOT the exact legacy bytes REFUSES - a hand edit is never silently adopted.

Idempotent, text based: a file already carrying the two markers and the current chunk returns
"already"; a file carrying an OLDER marker-bounded revision is re-staged (the marker region is removed
and the current chunk inserted); an anchor not found exactly once REFUSES (exit 3); a partial or
double edit REFUSES (exit 4), the file untouched.  `--dry-run` decides and proves without writing;
`--verify-off` runs the proof alone, which is how this tool can be exercised on a tree it must not
edit.
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

REL = "bsd/hfs/hfs_vfsops.c"

# The file this patch was written for, by content - not by name.  `hfs_mountroot`'s definition is the
# only `int`-returning one; the identity string occurs exactly once (asserted).
IDENTITY = "int\nhfs_mountroot(mount_t mp, vnode_t rvp, vfs_context_t context)"

# The POOL switch (see the header).  `STAGE90_XNU_HDD_WRITE` is deliberately NOT used: the pool build
# never defines it.
SWITCH = "STAGE90_HFS_ROOT_RW"

MARK = "/* IOS7HFSRW_BEGIN */"
_END = "/* IOS7HFSRW_END */"

# The root `hfs_mountfs` call.  It is unique because of its NULL second argument (the root marker) and
# because it is the only one inside an `if ((error = hfs_mountfs(...)))`.  Anchoring on the WHOLE
# `if (` line keeps the clear BEFORE the call.  Occurs exactly once in the file (asserted).
ANCHOR = "\tif ((error = hfs_mountfs(rvp, mp, NULL, 0, context))) {\n"

# The prior, marker-less staged form still in the D13 tree (produced by hfs_patch_root_rw.py).  Matched
# by its EXACT bytes; anything else that mentions the switch is a foreign edit and is refused.
LEGACY = (
    "#if STAGE90_HFS_ROOT_RW\n"
    "\t/* 905: the root mount is read-only by construction (vfs_subr.c hard-codes MNT_RDONLY |\n"
    "\t * MNT_ROOTFS); clear it here, before hfs_mountfs latches HFS_READ_ONLY from it, so the\n"
    "\t * card unit's write path is reachable. Guarded: the port-off image is byte-identical. */\n"
    "\tvfs_clearflags(mp, (u_int64_t)MNT_RDONLY);\n"
    "#endif\n"
)

# The inserted chunk: the guard and the clear, bounded by this script's markers.  OFF (switch unset or
# 0) emits nothing, so the anchor's original bytes are what the compiler sees.
CHUNK = MARK + "\n" + LEGACY + _END + "\n"

_MARK_LINES = {MARK, _END}


def refuse(msg: str, code: int):
    print(f"patch_d13_hfs_rw_root: REFUSING: {msg}", file=sys.stderr)
    raise SystemExit(code)


def _insert(old: str) -> str:
    """`old` with CHUNK inserted immediately before ANCHOR; every count asserted."""
    n = old.count(ANCHOR)
    if n != 1:
        refuse(f"{REL} has {n} root `hfs_mountfs(rvp, mp, NULL, 0, context)` anchor line(s), expected "
               f"exactly 1 - this is not the tree state this patch was written for", 3 if n == 0 else 4)
    i = old.index(ANCHOR)
    return old[:i] + CHUNK + old[i:]


def _normalise_legacy(old: str) -> str:
    """`old` (exact legacy staged form) with the marker lines added around its guarded clear.

    The anchor is re-asserted here too: the legacy block is ADDED AROUND, so a moved or renamed root
    `hfs_mountfs` call would be silently ratified by a marker insertion that never looked at it.  The
    legacy block must still sit IMMEDIATELY before the (unique) anchor, which is the property the whole
    patch is about - the clear must precede the call."""
    if old.count(LEGACY) != 1:
        refuse(f"{REL} carries STAGE90_HFS_ROOT_RW but not as the exact legacy block this patch knows "
               f"how to normalise - a hand edit is not silently adopted", 3)
    if old.count(ANCHOR) != 1:
        refuse(f"{REL} carries {old.count(ANCHOR)} root `hfs_mountfs(rvp, mp, NULL, 0, context)` "
               f"anchor line(s), expected exactly 1 - the call moved, so normalising would ratify a "
               f"clear that no longer precedes it", 3 if old.count(ANCHOR) == 0 else 4)
    i = old.index(LEGACY) + len(LEGACY)
    if not old.startswith(ANCHOR, i):
        refuse(f"{REL}'s legacy clear is not IMMEDIATELY before the root `hfs_mountfs` call - the "
               f"clear must precede the call that latches HFS_READ_ONLY", 3)
    return old.replace(LEGACY, MARK + "\n" + LEGACY + _END + "\n", 1)


def stage(old: str):
    """(text, status, head) with status in {"staged", "normalise", "already", "restage"} - every gate
    decided before a byte is written.  SystemExit on a partial or foreign edit (3 = anchor/block
    mismatch, 4 = partial/double edit).  `head` is the text the OFF proof is run against."""
    marks = old.count(MARK)
    ends = old.count(_END)
    if marks == 0:
        if ends != 0:
            refuse(f"{REL} carries {ends} {_END} marker(s) but no {MARK} - a partial or foreign edit", 4)
        if LEGACY in old:
            # the prior marker-less staged form: re-stage into the marker-bounded form.
            if old.count(LEGACY) != 1:
                refuse(f"{REL} carries {old.count(LEGACY)} legacy block(s)", 4)
            return _normalise_legacy(old), "normalise", old
        if "STAGE90_HFS_ROOT_RW" in old:
            refuse(f"{REL} mentions STAGE90_HFS_ROOT_RW but carries neither this script's markers nor "
                   f"the exact legacy block - refusing to stage over a foreign edit", 3)
        return _insert(old), "staged", old
    if marks != 1 or ends != 1:
        refuse(f"{REL} carries {marks} {MARK} / {ends} {_END} marker(s), expected 0/0 (un-staged) or "
               f"1/1 (staged)", 4)
    if CHUNK in old:
        return old, "already", None
    stripped = strip_marked(old)
    if IDENTITY not in stripped or stripped.count(ANCHOR) != 1:
        refuse(f"re-staging would remove the file's identity text - the markers do not bound this "
               f"script's chunk", 4)
    new, _status, _head = stage(stripped)
    return new, "restage", stripped


def unstaged(text: str) -> str:
    """`text` with this script's two MARKER LINES removed (the guarded block is kept).

    The proof compares PREPROCESSED text, so removing the marker comment lines is enough to
    reconstruct a text whose OFF preprocessing equals the tree's own: the guard and clear that remain
    are `#if`-false when the switch is unset, exactly as HEAD's absent block is."""
    return "".join(l for l in text.splitlines(keepends=True) if l.rstrip("\n") not in _MARK_LINES)


def strip_marked(text: str) -> str:
    """`text` with the IOS7HFSRW region removed, BEGIN marker line through END marker line inclusive.
    Version-agnostic on purpose, so a re-stage removes whatever chunk a PREVIOUS revision inserted.
    Called only on a file whose marker counts are already exactly 1/1."""
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
    print(f"  re-stage: removed {removed} line(s) in {regions} marker-bounded region(s)")
    return "".join(out)


# ---------------------------------------------------------------------------------------------------
# The OFF byte-identity proof: the REAL preprocessor over the WHOLE file, every #include -> empty.

IF_IDENTIFIERS = {
    "CONFIG_HFS_ALLOC_RBTREE", "CONFIG_HFS_MOUNT_UNMAP", "CONFIG_HFS_STD", "CONFIG_PROTECT",
    "HFS_COMPRESSION", "HFS_DIAGNOSTIC", "HFS_SPARSE_DEV", "NAMEDSTREAMS", "QUOTA",
    "STAGE90_HFS_ROOT_RW",
}
# The clear, as the compiler sees it (comments have been stripped by `-P`).
CLEAR = re.compile(r"vfs_clearflags\s*\(\s*mp\s*,\s*\(u_int64_t\)\s*MNT_RDONLY\s*\)\s*;")

_DIRECTIVE = re.compile(r"^[ \t]*#[ \t]*(?:if|elif|ifdef|ifndef)\b(.*)$", re.M)
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_WORDS = {"defined", "if", "elif", "ifdef", "ifndef"}
_INCLUDE = re.compile(r"^[ \t]*#[ \t]*include[ \t]*[<\"]([^>\"]+)[>\"]", re.M)


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
    """True iff the real preprocessor makes OFF (unset and =0) byte-identical to HEAD, and ON (=1)
    differs and carries the clear that HEAD and both OFF texts do not."""
    idents = if_identifiers(staged)
    print(f"  conditional identifiers in the file: {', '.join(sorted(idents))}")
    extra = sorted(i for i in idents if i not in IF_IDENTIFIERS)
    if extra:
        print(f"patch_d13_hfs_rw_root: FAIL: {REL}'s directives also evaluate {', '.join(extra)} - "
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
    # ON: different from HEAD, carries the clear, and neither HEAD nor the OFF texts carry it.
    on_clear = bool(CLEAR.search(s_one))
    on_diff = s_one != s_head
    off_clean = all(not CLEAR.search(s) for s in (s_head, s_none, s_zero))
    print(f"  shape: ON ({SWITCH} = 1) carries the clear = {on_clear}, differs from HEAD = {on_diff} "
          f"-> ON correct = {on_clear and on_diff}")
    print(f"  shape: HEAD and both OFF states carry NO clear = {off_clean}")
    if not (on_clear and on_diff):
        print(f"patch_d13_hfs_rw_root: FAIL: the ON branch does not emit "
              f"`vfs_clearflags(mp, (u_int64_t)MNT_RDONLY);` on the text the compiler sees",
              file=sys.stderr)
    if not off_clean:
        print(f"patch_d13_hfs_rw_root: FAIL: an OFF text carries the clear - the OFF identity is not "
              f"the tree's original structure", file=sys.stderr)
    return ok and on_clear and on_diff and off_clean


def main() -> int:
    argv = sys.argv[1:]
    dry = "--dry-run" in argv
    verify_only = "--verify-off" in argv
    argv = [a for a in argv if a not in ("--dry-run", "--verify-off")]
    if len(argv) != 1:
        print("usage: patch_d13_hfs_rw_root.py <xnu-tree-root> [--dry-run|--verify-off]", file=sys.stderr)
        return 2
    path = Path(argv[0]) / REL
    if not path.is_file():
        print(f"patch_d13_hfs_rw_root: no {REL} under {argv[0]} (D13 tree not provisioned?)", file=sys.stderr)
        return 2
    old = path.read_text()
    if IDENTITY not in old:
        refuse(f"{REL} carries no `hfs_mountroot` definition - this is not the file this patch was "
               f"written for", 3)

    new, status, head = stage(old)
    print(f"patch_d13_hfs_rw_root: {path}")
    if status == "already":
        head = unstaged(new)
        print("  already staged: the OFF proof below runs against the text this script's own markers "
              "are removed from")
    elif status == "restage":
        print("  re-staging over an older marker-bounded revision: the proof runs against the "
              "marker-stripped text")
    elif status == "normalise":
        print("  normalising the prior marker-less staged form (tools/hfs_patch_root_rw.py) into the "
              "marker-bounded form - the guard and the clear are kept, the markers are added")
    with tempfile.TemporaryDirectory() as td:
        good = verify_off(head, new, Path(td))
    print(f"patch_d13_hfs_rw_root: OFF byte-identity proof {'PASS' if good else 'FAIL'}")
    if verify_only:
        return 0 if good else 1
    if not good:
        print("patch_d13_hfs_rw_root: REFUSING to write - the OFF byte-identity proof did not pass "
              "(the file is untouched)", file=sys.stderr)
        return 1
    if status == "already":
        print("patch_d13_hfs_rw_root: nothing to do")
        return 0
    if dry:
        print(f"  --dry-run: would {status} the guarded clear ({len(CHUNK.splitlines())} lines) "
              f"immediately before the root `hfs_mountfs` call; nothing written")
        return 0
    path.write_text(new)
    print(f"patch_d13_hfs_rw_root: {status} the read-write-root clear into {REL}")
    print(f"patch_d13_hfs_rw_root: NOW RE-RUN tools/build_xnu_arm_kernel.sh with XNU_TREE=<the D13 "
          f"tree>, STAGE90_XNU_HFS=1 and STAGE90_XNU_HFS_ROOT_RW=1 exported (bsd/hfs/hfs_vfsops.c is a "
          f"POOL object: the linked image only LINKS out/xnu_kernel_obj_d13/bsd_hfs_hfs_vfsops.o), "
          f"then rebuild the entry image under the write arm")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())