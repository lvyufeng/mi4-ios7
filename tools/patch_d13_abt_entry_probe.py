#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage 1026's ABORT-ENTRY DISCRIMINATOR into the D13 tree: name WHY the launchctl stack VA has no
vm_map entry (H1 wrong map vs H2 off-the-end), by value, on the ram console.

THE FRONTIER THIS ANSWERS, BY VALUE (docs/1026-design.md; records/1025-press-read.txt).

  1025's press RAN and its own console was recovered: the discarded `vm_fault` return for the
  launchctl[2] abort is `code=1` = **KERN_INVALID_ADDRESS**, on `far=0x2bd35000`, `dfsr=0x807`
  (translation fault, page), `prot=write`, `pc=0x3b4ce756`, `sp=0x2bd34074`, `pid=2`.  By source,
  `vm_fault` returning KERN_INVALID_ADDRESS means `vm_map_lookup_entry(map, VA)` returned FALSE, so
  **no vm_map entry covered the VA when the walk ran** (`osfmk/vm/vm_map.c:8761ff`).

  1025's OWN stack-shape rows falsify the 1025 design's premise: launchctl's region is
  `[0x2bc35000, 0x2bd35000)` and the fault VA is its **EXCLUSIVE TOP** — one byte past the last byte.
  What is TRUE across BOTH arms is `far == p->user_stack` and `far - sp == 0xF8C`.

  So the open question is a WHICH, not a what (docs/1026-design.md section 2):
    (H1) **Wrong map.** `create_unix_stack` allocated into `get_task_map(task)`, but the walk uses
         `thread->map` (trap.c's data-abort arm reads `map = thread->map`).  If they differ for pid 2,
         the entry is invisible to the walk even though `far` is a legal region byte.
    (H2) **Off-the-end.** The entry genuinely ends at `far` (as the numbers show) and a legal word
         sits just below; the cause is upstream (the argv/env block or the initial `sp` is one word
         too high) and the fix is kernel-side.

  These predict DIFFERENT fixes, so 1026 must DISCRIMINATE before building either.

THE EDIT — ONE PUBLISHER, INSERTED **INSIDE** THE EXISTING 1025 BLOCK, PLUS ONE ACCESSOR.

  (A) osfmk/arm/trap.c, INSIDE the `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE`
  block in the usermode DATA-abort arm's `if ((code != KERN_SUCCESS) && (code != KERN_ABORTED))`
  (i.e. immediately before that block's `#endif`), a guarded
  `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE` block publishing, for the
  failing fault only:

      xnu_live_abt_lookup_far=1/0     <- vm_map_lookup_entry(map, dfar, &e)       (H2: 0)
      xnu_live_abt_entry_lo=0x..      <- e->vme_start  (when found)               (names the region)
      xnu_live_abt_entry_hi=0x..      <- e->vme_end
      xnu_live_abt_e2_lo=0x..         <- e2->vme_start (the FAR-4 entry)           (1027; H2 case)
      xnu_live_abt_e2_hi=0x..         <- e2->vme_end   (the FAR-4 entry)           (1027; == far => H2)
      xnu_live_abt_far_in_map=1/0     <- vm_map_lookup_entry(map, dfar-4, &e2)    (H2: 1)
      xnu_live_abt_map=0x..           <- `map` (thread->map)
      xnu_live_abt_taskmap=0x..       <- get_task_map(thread->task)               (H1: map != taskmap)
      xnu_live_abt_ustack=0x..        <- (task->bsd_info) ? p->user_stack : 0

  **1027 AMENDMENT (2026-10-17).**  The 1026 press READ H-OTHER -- but that verdict is a PROBE DEFECT,
  not a third hypothesis.  The pre-registered H2 cell demands `entry_hi == far`, yet the publisher
  wrote entry_lo/entry_hi only when `_abt_hit` is TRUE; in the H2 case `_abt_hit` is exactly FALSE
  (`lookup_far=0`) and the covering entry is `_abt_e2`, so the H2 cell asked for a value the probe was
  built never to emit.  The two `_abt_e2_*` rows above close that: `_abt_e2_hi == far` is now
  READABLE whenever H2 is true, so the H2 cell can fire.  (The 1026 press's 7 keys are unchanged and
  still published; this ADDS two, so 1026's rows and the 1025 re-reading are undisturbed.)

  (B) bsd/kern/kern_exec.c, a guarded accessor `xnu_live_abt_proc_ustack(void *bsd_info)` inserted
  just above `create_unix_stack`, which READS `((proc_t)bsd_info)->user_stack` and returns 0 for a
  NULL.  **WHY A SECOND FILE.**  `struct proc` is only FOWARD-declared in trap.c (`osfmk/arm/trap.c:58`
  `struct proc;`) — trap.c deliberately touches the proc only through externs (`proc_pid`,
  `proc_name_address`).  `p->user_stack` is a FIELD of an INCOMPLETE type there, so it cannot be read
  from trap.c without including `bsd/sys/proc_internal.h` (which no osfmk file includes, and which
  would move trap.c's whole compile).  The accessor lives where the struct IS complete (kern_exec.c
  reads `p->user_stack` at `create_unix_stack`) and trap.c calls it by its extern name, exactly the
  route `proc_pid` already takes.  It is a READ; no behaviour change.

  WHY INSIDE 1025'S BLOCK, NOT A SECOND COMPETING ONE.  The fault path is SHARED: this discriminator
  is only meaningful for a fault that 1025's `code != KERN_SUCCESS` guard already selected, and a
  second top-level `#if` in the same arm would make the two rungs' gates independently removable and
  their OFF/ON proofs no longer compose.  Nesting keeps ONE gate for the shared fault path
  (`docs/1026-design.md` section 3; team-lead instruction).  1026's switch is therefore a CHILD of
  1025's: it prints nothing unless BOTH switches are on.

  THE MAP LOCK (docs/1026-design.md section 7, "the abort path may not be safe to call
  `vm_map_lookup_entry` in").  This tree's `vm_map_lookup_entry` -> `vm_map_store_lookup_entry`
  dispatches to `vm_map_store_lookup_entry_ll` (`VM_MAP_STORE_USE_LL` is defined FIRST in
  `osfmk/vm/vm_map_store.h:35`, so the `#ifdef` chain in `vm_map_store.c:56` picks it): it reads
  `map->hint` and walks `vme_next`/`vme_prev` links and takes **NO LOCK**.  It is a READ of a linked
  list on the FAULTING THREAD'S OWN map, taken on the failure path before this arm mutates anything.
  So it cannot deadlock and it cannot race a writer: the thread is the one that faulted.  The design
  permits reading `map->hint`/the pmap entry alone as a fallback; the `vm_map_lookup_entry` read is
  chosen because it is the SAME call `vm_fault` just made, so H2's "the entry ends at far" is read
  with the very predicate that produced KERN_INVALID_ADDRESS.  All seven values are READ, never
  written: no behaviour change.

  THE CHANNEL is the kernel's own ram-console `printf` (the same one 1025's publishers and IOS7LAB
  use) — NOT the `entry_write_kv` DIRECT channel, which is the ENTRY-side mechanism and is not
  reachable from trap.c.  The design's key NAMES are kept verbatim, so the capture reader reads them.

WHY A PATCH AND NOT A HAND EDIT.  `external/` is a re-provisionable gitignored checkout; every edit a
build makes to it must be a script a re-checkout re-applies (the `stage_d13_*.sh` rule).

THE FOUR-RUNG SHARED NAMESPACE ([[mi4-one-file-many-rungs]]).  FOUR rungs edit `osfmk/arm/trap.c`:
994 (`patch_d13_dyld_witness.py`, STAGE90_XNU_DYLD_WITNESS), 1020 (`patch_d13_undef_raise.py`,
STAGE90_XNU_UNDEF_RAISE), 1025 (`patch_d13_ustack_probe.py`, STAGE90_XNU_USTACK_PROBE) and 1026
(this script, STAGE90_XNU_ABT_ENTRY_PROBE).  A `git checkout -- trap.c` between rungs SILENTLY
reverts the others, and each patcher's OFF proof refuses the file if a sibling's identifier is not in
its allow-list.  THIS SCRIPT therefore carries `TRAP_ALLOWED_IF_IDENTIFIERS` (the union) and the build
script re-stages all four in order.  Every patcher's `--verify-off` drives the OTHER switches as
`undefined`, so the OFF arm compiles each file's ORIGINAL bytes with the block removed
([[mi4-off-option-two-spellings]]).

IDEMPOTENT + REFUSING.  The patcher: (i) checks the DONE-MARK BEFORE THE ANCHORS (a staged file's own
block would otherwise contribute to an anchor's occurrence count — [[mi4-one-file-many-rungs]] step
3); (ii) asserts each anchor's occurrence count EXACTLY (refuses, file untouched, on a partial or
double edit); (iii) a second `--apply` is a no-op that SUCCEEDS (the build script calls it twice);
(iv) `--verify-off` proves with the REAL preprocessor that the block is absent with the switch unset
and present with it set.

CLI:  <xnu_root>             (plan: print what it WOULD do, write nothing)
      <xnu_root> --apply     (write)
      <xnu_root> --verify-off (proof that OFF == the tree's original bytes)
"""
import sys
import os
import re

# ---------------------------------------------------------------------------------------------------
# (A) osfmk/arm/trap.c -- the discriminator, nested INSIDE 1025's publisher.
# ---------------------------------------------------------------------------------------------------
REL = "osfmk/arm/trap.c"
SWITCH = "STAGE90_XNU_ABT_ENTRY_PROBE"
GATE = f"#if defined({SWITCH}) && {SWITCH}"
END = f"#endif /* {SWITCH} */"

# The insertion point: the LAST line of 1025's publisher (the pid printf).  It is unique in the file
# (`xnu_live_abt_vmfkrv_pid=` occurs once), so the block lands INSIDE 1025's `#if` block, immediately
# before its `#endif`.  Inserting after this line and before `#endif /* STAGE90_XNU_USTACK_PROBE */`
# is what makes 1026 a CHILD of 1025's gate (the shared fault path has ONE gate).
INSERT_AFTER = (
    "                    printf(\"xnu_live_abt_vmfkrv_pid=%d\\n\", "
    "(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1));\n"
)
# A line EARLIER in the same arm, unique in the file, proving we are at the right `if` arm (the
# `leo_installd_fault_result=code;` statement that DISCARDS the value — occurs exactly once).
ANCHOR_GUARD = "                    leo_installd_fault_result=code;\n"
# 1025's own gate line: proves the parent block is present (this edit is nested, not standalone).
ANCHOR_PARENT = "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"

BLOCK = (
    "#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE\n"
    "                    /* 1026: WHICH, not what.  1025 named the cause: vm_fault returned\n"
    "                     * KERN_INVALID_ADDRESS, i.e. vm_map_lookup_entry(map, far) returned FALSE.\n"
    "                     * This discriminates H1 (WRONG MAP: create_unix_stack allocated into\n"
    "                     * get_task_map(task) but the walk uses thread->map) from H2 (OFF-THE-END: the\n"
    "                     * entry really ends at far and a legal word sits just below).  All seven are\n"
    "                     * READS on the failing fault only; vm_map_lookup_entry takes NO lock in this\n"
    "                     * tree (VM_MAP_STORE_USE_LL -> reads map->hint + the entry links) and the map\n"
    "                     * is the faulting thread's own, on the failure path before any mutation.\n"
    "                     * docs/1026-design.md sections 3-4. */\n"
    "                    {\n"
    "                        vm_map_entry_t _abt_e = VM_MAP_ENTRY_NULL;\n"
    "                        vm_map_entry_t _abt_e2 = VM_MAP_ENTRY_NULL;\n"
    "                        boolean_t _abt_hit =\n"
    "                            vm_map_lookup_entry(map, vm_map_trunc_page(dfar), &_abt_e);\n"
    "                        boolean_t _abt_hit2 =\n"
    "                            vm_map_lookup_entry(map, vm_map_trunc_page(dfar) - 4, &_abt_e2);\n"
    "                        vm_map_t _abt_taskmap = get_task_map(thread->task);\n"
    "                        extern unsigned xnu_live_abt_proc_ustack(void *);\n"
    "                        unsigned _abt_ustack = xnu_live_abt_proc_ustack(thread->task->bsd_info);\n"
    "                        printf(\"xnu_live_abt_lookup_far=%d\\n\", (int)(_abt_hit ? 1 : 0));\n"
    "                        printf(\"xnu_live_abt_entry_lo=0x%08x\\n\", (unsigned)((_abt_hit && _abt_e) ? _abt_e->vme_start : 0));\n"
    "                        printf(\"xnu_live_abt_entry_hi=0x%08x\\n\", (unsigned)((_abt_hit && _abt_e) ? _abt_e->vme_end : 0));\n"
    "                        /* 1027: the far-4 entry's OWN bounds.  In the H2 case (_abt_hit==FALSE)\n"
    "                         * the covering entry is _abt_e2, NOT _abt_e, so the rows above print 0 /\n"
    "                         * suppressed and the pre-registered `entry_hi==far` conjunct was\n"
    "                         * UNREADABLE BY CONSTRUCTION.  These two rows are what make H2 name its\n"
    "                         * own confirming value.  docs/1027-design.md 3. */\n"
    "                        printf(\"xnu_live_abt_e2_lo=0x%08x\\n\", (unsigned)((_abt_hit2 && _abt_e2) ? _abt_e2->vme_start : 0));\n"
    "                        printf(\"xnu_live_abt_e2_hi=0x%08x\\n\", (unsigned)((_abt_hit2 && _abt_e2) ? _abt_e2->vme_end : 0));\n"
    "                        printf(\"xnu_live_abt_far_in_map=%d\\n\", (int)(_abt_hit2 ? 1 : 0));\n"
    "                        printf(\"xnu_live_abt_map=0x%08x\\n\", (unsigned)(uintptr_t)map);\n"
    "                        printf(\"xnu_live_abt_taskmap=0x%08x\\n\", (unsigned)(uintptr_t)_abt_taskmap);\n"
    "                        printf(\"xnu_live_abt_ustack=0x%08x\\n\", (unsigned)_abt_ustack);\n"
    "                    }\n"
    + END + "\n"
)
DONE_MARK = "xnu_live_abt_lookup_far="

# ---------------------------------------------------------------------------------------------------
# (B) bsd/kern/kern_exec.c -- the proc->user_stack accessor (struct proc is INCOMPLETE in trap.c).
# ---------------------------------------------------------------------------------------------------
EXEC_REL = "bsd/kern/kern_exec.c"
# Insert just ABOVE create_unix_stack's own header comment (unique in the file).  The accessor is a
# READ and is placed at file scope, so its placement does not have to be inside any function.
EXEC_INSERT_BEFORE = "/*\n * create_unix_stack\n *\n"
EXEC_BLOCK = (
    "#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE\n"
    "/* 1026: publish `p->user_stack` for the abort-entry discriminator (osfmk/arm/trap.c's\n"
    " * xnu_live_abt_ustack row).  trap.c carries only `struct proc;` (FOWARD declared,\n"
    " * osfmk/arm/trap.c:58) and touches the proc through externs (proc_pid, proc_name_address), so\n"
    " * the FIELD cannot be read there without including bsd/sys/proc_internal.h (which no osfmk file\n"
    " * includes).  `user_stack` is in scope HERE (create_unix_stack writes it), so the read lives\n"
    " * here and trap.c calls it by name.  READ ONLY; returns 0 for a NULL (the caller already guards\n"
    " * bsd_info, this is belt-and-braces against a race with proc teardown).  docs/1026-design.md 3. */\n"
    "unsigned\n"
    "xnu_live_abt_proc_ustack(void *bsd_info)\n"
    "{\n"
    "\tif (bsd_info == NULL) {\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "\treturn (unsigned)((proc_t)bsd_info)->user_stack;\n"
    "}\n"
    + f"#endif /* {SWITCH} */\n"
    "\n"
)
EXEC_DONE_MARK = "xnu_live_abt_proc_ustack"

# ---------------------------------------------------------------------------------------------------
# THE SHARED DIRECTIVE-IDENTIFIER NAMESPACE OF osfmk/arm/trap.c ([[mi4-one-file-many-rungs]]).
#
# A file's `#if` identifiers are ONE namespace shared by every patcher that edits it.  A new rung
# that edits trap.c MUST add its switch here (and to the other three patchers' sets), or no patcher
# can certify its OFF arm: an unregistered identifier "may come from a header", which the
# placeholder-include proof cannot see.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",     # 994  (tools/patch_d13_dyld_witness.py)
    "STAGE90_XNU_WATCH_LE",         # 1038 (tools/patch_d13_watch_le.py)
    # 1038's own chunk (head-pair spelling): directive identifiers are a SHARED namespace, so the
    # chunk's names are allowed here ([[mi4-one-file-many-rungs]]).
    "WATCH_LE_STATICS_DEFINED", "chunk", "arm",
    "STAGE90_XNU_GLOBAL_FIX",       # 1015b (fires in pmap.c; allowed for the shared proof)
    "STAGE90_XNU_UNDEF_RAISE",      # 1020 (tools/patch_d13_undef_raise.py)
    "STAGE90_XNU_IOS7_TRAPS",       # 1023 (row-24 gate; allowed for the shared proof)
    "STAGE90_XNU_USTACK_PROBE",     # 1025 (tools/patch_d13_ustack_probe.py) - 1026's PARENT block
    "STAGE90_XNU_ABT_ENTRY_PROBE",  # 1026 (this script)
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (tools/patch_d13_h2_stack_headroom.py; edits kern_exec.c)
    "STAGE90_XNU_READER_PROBE",       # 1029 (tools/patch_d13_reader_probe.py)
    "STAGE90_XNU_WRITER_PROBE",  # 1030 (tools/patch_d13_writer_probe.py)
    "STAGE90_XNU_CALLER_PROBE",  # 1031 (tools/patch_d13_caller_probe.py)
    "STAGE90_XNU_EVAL_FRAME",  # 1033 (tools/patch_d13_eval_frame.py)
    "STAGE90_XNU_PC_CARRIER",  # 1035 (tools/patch_d13_pc_carrier.py)
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036 (tools/patch_d13_pc_carrier_caller.py)
    "STAGE90_XNU_TRAP_FRAME",  # 1037 (tools/patch_d13_trap_frame.py)
    "STAGE90_XNU_FRAME_CARRIER"}  # 1039 (tools/patch_d13_frame_carrier.py)
_DIRECTIVE = re.compile(r"^[ \t]*#[ \t]*(?:if|elif|ifdef|ifndef)\b(.*)$", re.M)
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_WORDS = {"defined", "if", "elif", "ifdef", "ifndef"}


def if_identifiers(text):
    # inside quotes -> not an identifier; a prefixed id (X_EVIL) is its own name, never the switch X
    exprs = [re.sub(r'"(?:[^"\\]|\\.)*"', "", e) for e in _DIRECTIVE.findall(text)]
    return {w for expr in exprs for w in _IDENT.findall(expr) if w not in _WORDS}


def read(path):
    with open(path, "r") as f:
        return f.read()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def count(text, needle):
    return text.count(needle)


def plan_file(label, text, anchors, insert_at, done_mark, before):
    """Return (ok, message).  ok False => refuse, write nothing.

    THE DONE-MARK IS CHECKED FIRST, BEFORE THE ANCHORS.  `ANCHOR_PARENT` counts 1025's gate line; a
    file this script already staged carries a `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) ...` line
    that does NOT collide with it, but the discipline is the rule ([[mi4-one-file-many-rungs]] step
    3): an already-staged file must be the IDEMPOTENT case, never an anchor mismatch.
    `before` selects insertion at the START of the matched text (kern_exec.c's function comment)
    versus immediately AFTER it (trap.c's pid printf).
    """
    if count(text, done_mark) != 0:
        return False, f"{label}: the done-mark {done_mark!r} is ALREADY present - already staged."
    for name, a, want in anchors:
        got = count(text, a)
        if got != want:
            return False, (f"{label}: anchor {name!r} occurs {got} time(s), expected exactly {want}. "
                           f"The tree is not in the state this rung was written against (a displaced "
                           f"anchor, a partial edit, or a hand-edited region). Writing nothing.")
    got = count(text, insert_at)
    if got != 1:
        return False, (f"{label}: the insertion point occurs {got} time(s), expected exactly 1; the "
                       f"insertion point is ambiguous. Writing nothing.")
    return True, f"{label}: anchors exact, done-mark absent, insertion point unique."


def strip_old_block(text):
    """Remove a STALE 1026 block so the amended block can be re-inserted.

    1027 AMENDS this same block (adds the two `_abt_e2` rows).  The block is bounded by its own
    one-line gate `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE` and the
    matching `END`.  A tree staged by the PRE-amendment 1026 carries the gate+END and the old
    DONE_MARK (`xnu_live_abt_lookup_far=`) but NOT the new `xnu_live_abt_e2_hi=`; `plan_file` would
    otherwise return "already staged" and `apply_file` would only INSERT (double block).  This returns
    (stripped_text, True) when it removed exactly one bounded region, else (text, False) - never a
    silent partial removal ([[mi4-one-file-many-rungs]]: an amended rung must RE-STAGE the old edit).
    """
    g = text.find(GATE + "\n")
    if g == -1:
        return text, False
    e = text.find(END + "\n", g)
    if e == -1:
        return text, False
    if count(text, GATE + "\n") != 1 or count(text, END + "\n") != 1:
        return text, False  # ambiguous; refuse to guess
    end = e + len(END) + 1
    return text[:g] + text[end:], True


def apply_file(label, path, insert_at, block, before, note, base=None):
    text = read(path) if base is None else base
    idx = text.find(insert_at)
    if idx == -1:
        print(f"patch_d13_abt_entry_probe: {label}: the insertion point vanished between the plan and "
              f"the write", file=sys.stderr)
        return False
    if before:
        new = text[:idx] + block + text[idx:]
    else:
        end = idx + len(insert_at)
        new = text[:end] + block + text[end:]
    write(path, new)
    print(f"   {label}: {note}")
    return True


def stage(xnu, do_apply):
    trap = os.path.join(xnu, REL)
    exe = os.path.join(xnu, EXEC_REL)
    for p in (trap, exe):
        if not os.path.isfile(p):
            print(f"patch_d13_abt_entry_probe: no {p} (D13 tree not provisioned?)", file=sys.stderr)
            return 2
    t = read(trap)
    e = read(exe)

    # 1027 RE-STAGE: a tree staged by the PRE-amendment 1026 carries the OLD block (no e2 rows).
    # Detect it by value - the new DONE_MARK token `xnu_live_abt_e2_hi=` is ABSENT while the old one
    # is present - and strip the bounded block so the AMENDED block can be re-inserted below.
    # Only a plain --apply writes; the strip is applied to the in-memory text and the file is
    # rewritten by apply_file.  On the OFF arm nothing here changes the compiled bytes.
    restaged = False
    if count(t, DONE_MARK) != 0 and count(t, "xnu_live_abt_e2_hi=") == 0:
        stripped, ok = strip_old_block(t)
        if ok:
            t = stripped
            restaged = True

    # THE SHARED-NAMESPACE CHECK.  trap.c's `#if` identifiers are the union of what ALL FOUR patchers
    # put there; a foreign one is a hand edit or an unregistered rung, and either way this script's
    # `--verify-off` cannot certify OFF byte-identity.  Refuse BEFORE the anchors, naming the real
    # cause ([[mi4-one-file-many-rungs]]).
    foreign = sorted(i for i in if_identifiers(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        print(f"patch_d13_abt_entry_probe: REFUSE - {REL}'s directives also evaluate "
              f"{', '.join(foreign)}. trap.c is edited by FOUR rungs (994/1020/1025/1026) and a file's "
              f"directive identifiers are a SHARED namespace: a new rung that edits trap.c must add "
              f"its switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other three patchers' sets. "
              f"Writing nothing. ([[mi4-one-file-many-rungs]])", file=sys.stderr)
        return 1

    ok1, m1 = plan_file("trap.c", t,
                        [("leo_installd_fault_result", ANCHOR_GUARD, 1),
                         ("parent_gate", ANCHOR_PARENT, 1)],
                        INSERT_AFTER, DONE_MARK, before=False)
    ok2, m2 = plan_file("kern_exec.c", e,
                        [("create_unix_stack_comment", EXEC_INSERT_BEFORE, 1)],
                        EXEC_INSERT_BEFORE, EXEC_DONE_MARK, before=True)
    print("   " + m1)
    print("   " + m2)
    if not (ok1 and ok2) and not restaged:
        # Benign idempotent case: BOTH done-marks present means a SECOND `--apply` of this script (the
        # build calls it twice) - a NO-OP that SUCCEEDS.  A PARTIAL staging (one file, not the other)
        # is a refusal, never a half-application.  `restaged` short-circuits this: the strip above
        # removed the OLD block, so trap.c is (correctly) mid-re-stage and must fall through to the
        # insert.  kern_exec.c's accessor is UNCHANGED by 1027, so ok2 is still True there.
        staged = (count(t, DONE_MARK) != 0) and (count(e, EXEC_DONE_MARK) != 0)
        if staged:
            print("patch_d13_abt_entry_probe: already staged (both files) - no-op, OK.")
            return 0
        one, other = count(t, DONE_MARK) != 0, count(e, EXEC_DONE_MARK) != 0
        if one != other:
            print("patch_d13_abt_entry_probe: REFUSE - PARTIAL staging (one file done, one not). "
                  "Revert the staged file (git -C external/... checkout) and re-run. Writing nothing.",
                  file=sys.stderr)
            return 1
        print("patch_d13_abt_entry_probe: REFUSE (writes nothing).", file=sys.stderr)
        return 1
    if not do_apply:
        print("patch_d13_abt_entry_probe: plan OK (dry run; pass --apply to write).")
        return 0
    if not apply_file("trap.c", trap, INSERT_AFTER, BLOCK, before=False,
                      note=("RE-STAGED the 1026 discriminator (amended with the 1027 e2 rows) INSIDE "
                            "1025's publisher block." if restaged else
                            "staged the 1026 discriminator INSIDE 1025's publisher block."),
                      base=(t if restaged else None)):
        return 1
    if count(e, EXEC_DONE_MARK) == 0:
        if not apply_file("kern_exec.c", exe, EXEC_INSERT_BEFORE, EXEC_BLOCK, before=True,
                          note="staged the xnu_live_abt_proc_ustack accessor above create_unix_stack."):
            return 1
    return 0


def verify_off(xnu):
    """Prove trap.c compiles to its ORIGINAL bytes with 1026's switch unset.

    The block is wholly inside `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE`
    (nested inside 1025's), so with the 1026 `-D` absent the preprocessor removes it and the compiled
    bytes are 1025's staged bytes.  We prove it with the REAL preprocessor for BOTH arms and check the
    OFF arm's text contains none of the discriminator tokens and the ON arm's does.  BOTH switches are
    driven together in the ON arm, because 1026's block is a CHILD of 1025's gate: 1026 prints nothing
    unless BOTH are on.
    """
    import subprocess
    trap = os.path.join(xnu, REL)
    exe = os.path.join(xnu, EXEC_REL)
    cc = os.environ.get("STAGE90_CC", "arm-none-eabi-gcc")
    unknown = "xnu_live_abt_lookup_far=99999"   # a token that is never in the source or the preprocessor
    ok = True
    # (label, path, token that must be ABSENT off / PRESENT on)
    for label, path, tok in (("trap.c", trap, "xnu_live_abt_lookup_far="),
                             ("kern_exec.c", exe, "xnu_live_abt_proc_ustack")):
        for arm, extra in (("OFF", []),
                           ("ON", [f"-DSTAGE90_XNU_USTACK_PROBE=1", f"-D{SWITCH}=1"])):
            cmd = [cc, "-E", "-P", "-nostdinc", "-undef"] + extra + [path]
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout
            except Exception as ex:  # noqa: BLE001
                print(f"patch_d13_abt_entry_probe: --verify-off: cannot run {cc}: {ex}", file=sys.stderr)
                return 2
            has = tok in out
            want = (arm == "ON")
            print(f"   {label} [{arm}]: token {'present' if has else 'absent'} "
                  f"(want {'present' if want else 'absent'})")
            if has != want:
                ok = False
            if unknown in out:
                print(f"patch_d13_abt_entry_probe: --verify-off: the control token {unknown!r} is "
                      f"present in the {label} {arm} preprocessed output - the proof itself is wrong",
                      file=sys.stderr)
                ok = False
    if not ok:
        print("patch_d13_abt_entry_probe: --verify-off FAILED (the switch does not gate cleanly).",
              file=sys.stderr)
        return 1
    print("patch_d13_abt_entry_probe: --verify-off PASS (OFF == 1025's staged bytes for BOTH files; "
          "ON carries the discriminator + the accessor).")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    xnu = None
    do_apply = False
    do_verify = False
    for a in argv[1:]:
        if a == "--apply":
            do_apply = True
        elif a == "--verify-off":
            do_verify = True
        elif a.startswith("-"):
            print(f"patch_d13_abt_entry_probe: unknown flag {a!r}", file=sys.stderr)
            return 2
        else:
            xnu = a
    if xnu is None:
        print(__doc__)
        return 2
    if do_verify:
        return verify_off(xnu)
    return stage(xnu, do_apply)


if __name__ == "__main__":
    sys.exit(main(sys.argv))