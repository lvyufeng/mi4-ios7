#!/usr/bin/env python3
"""1029 -- READ THE READER.

1028 fixed the H2 "block top flush with the region top" boundary by growing the initial user-stack
region ONE PAGE (mach_vm_allocate rounds `size + 16` up to `size + PAGE_SIZE`).  The reading was
FIX-NOOP, PAGE-EXACT: the launchctl[2] data abort RECURRED but MOVED with the region --
`far - ustack = 0x1000` and `far - sp = 0x1F8C = 0xF8C + 0x1000`, while every prior rung read
`far - sp = 0xF8C` with `far == ustack`.  So the failing write is NOT the block's top word: the
writer derives its store address FROM `p->user_stack` and writes one page above it.  H2 is REFUTED.

This rung is a PROBE (report, do NOT re-fix).  It publishes, in ONE row at the moment of the fault,
the process's own fields beside the fault address so "who derived what" is by-value:
  Site A (osfmk/arm/trap.c, the usermode DATA-abort failure arm): xnu_live_rdr_* rows.
  Site B (bsd/kern/kern_exec.c, a sibling accessor beside 1026's xnu_live_abt_proc_ustack): makes
         p->p_argc / p->p_argslen reachable BY NAME from Site A.

Both sites are ON THE FAILING PATH ONLY and gated on STAGE90_XNU_READER_PROBE; with the switch
undefined both files compile BYTE-IDENTICAL to the 1028 tree (`--verify-off`).

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029 and
kern_exec.c by 1025/1026/1028/1029.  A file's `#if` identifiers are ONE namespace; this script carries
the TRAP and EXEC unions and each OTHER patcher's set must gain STAGE90_XNU_READER_PROBE.

docs/1029-design.md.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_READER_PROBE"

TRAP_REL = "osfmk/arm/trap.c"
EXEC_REL = "bsd/kern/kern_exec.c"

# ---------------------------------------------------------------- trap.c (Site A)

# The block is inserted AFTER the 1026/1027 `#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */` and BEFORE the
# 1025 block's `#endif /* STAGE90_XNU_USTACK_PROBE */` -- i.e. still INSIDE the 1025 failure arm, where
# dfar / dfsr / arm_ctx / thread / map / code are ALL in scope.  The anchor is the exact two-line tail.
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_rdr_far="

# The inserted text: opens its own `#if defined(STAGE90_XNU_READER_PROBE)`, publishes the rows, closes
# with a matching `#endif`.  It is placed BETWEEN the two existing #endif lines, so the anchor above is
# rewritten as: <ABT #endif> <READER block> <USTACK #endif>.
TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */\n"
    "#if defined(STAGE90_XNU_READER_PROBE) && STAGE90_XNU_READER_PROBE\n"
    "\t\t\t\t\t/* 1029: READ THE READER.  1028 grew the stack region a PAGE and the fault MOVED with\n"
    "\t\t\t\t\t * it (far - ustack = 0x1000; far - sp = 0x1F8C), so the failing store is derived FROM\n"
    "\t\t\t\t\t * p->user_stack, not from the block top.  Publish the PROC's own fields beside the\n"
    "\t\t\t\t\t * fault VA so \"who derived what\" is by-value.  READS only; on the failing path only;\n"
    "\t\t\t\t\t * the extra vm_map_lookup_entry takes no lock in this tree (the 1026/1027 idiom).\n"
    "\t\t\t\t\t * docs/1029-design.md 3. */\n"
    "\t\t\t\t\t{\n"
    "\t\t\t\t\t\tvm_map_entry_t _rdr_e = VM_MAP_ENTRY_NULL;\n"
    "\t\t\t\t\t\tboolean_t _rdr_hit =\n"
    "\t\t\t\t\t\t    vm_map_lookup_entry(map, vm_map_trunc_page(dfar), &_rdr_e);\n"
    "\t\t\t\t\t\textern unsigned xnu_live_abt_proc_ustack(void *);\n"
    "\t\t\t\t\t\textern unsigned xnu_live_rdr_proc_argslen(void *);\n"
    "\t\t\t\t\t\textern unsigned xnu_live_rdr_proc_argc(void *);\n"
    "\t\t\t\t\t\tunsigned _rdr_ust = xnu_live_abt_proc_ustack(thread->task->bsd_info);\n"
    "\t\t\t\t\t\tunsigned _rdr_far = (unsigned)vm_map_trunc_page(dfar);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_far=0x%08x\\n\", _rdr_far);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_ustack=0x%08x\\n\", _rdr_ust);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_far_minus_ustack=0x%08x\\n\", (unsigned)(_rdr_far - _rdr_ust));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_blk_hi=0x%08x\\n\", _rdr_ust);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_blk_lo=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)(_rdr_ust - xnu_live_rdr_proc_argslen(thread->task->bsd_info)));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_blk_bytes=%u\\n\",\n"
    "\t\t\t\t\t\t    xnu_live_rdr_proc_argslen(thread->task->bsd_info));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_argc=%u\\n\",\n"
    "\t\t\t\t\t\t    xnu_live_rdr_proc_argc(thread->task->bsd_info));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_entry_at_hit=%d\\n\", (int)(_rdr_hit ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_entry_at_lo=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)((_rdr_hit && _rdr_e) ? _rdr_e->vme_start : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_rdr_entry_at_hi=0x%08x\\n\",\n"
    "\t\t\t\t\t\t    (unsigned)((_rdr_hit && _rdr_e) ? _rdr_e->vme_end : 0));\n"
    "\t\t\t\t\t}\n"
    "#endif /* STAGE90_XNU_READER_PROBE */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# trap.c's `#if` identifiers are the union of what ALL FIVE patchers put there.  A foreign one is a
# hand edit or an unregistered rung; refuse before the anchors, naming the real cause.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",       # 994
    "STAGE90_XNU_GLOBAL_FIX",         # 1015b (fires in pmap.c; allowed for the proof)
    "STAGE90_XNU_UNDEF_RAISE",        # 1020
    "STAGE90_XNU_IOS7_TRAPS",         # 1023
    "STAGE90_XNU_USTACK_PROBE",       # 1025 (Site A's PARENT block)
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026/1027
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (edits kern_exec.c; allowed for the proof)
    "STAGE90_XNU_READER_PROBE",       # 1029 (this rung)
    "STAGE90_XNU_WRITER_PROBE",  # 1030 (tools/patch_d13_writer_probe.py)
    "STAGE90_XNU_CALLER_PROBE",  # 1031 (tools/patch_d13_caller_probe.py)
    "STAGE90_XNU_EVAL_FRAME",  # 1033 (tools/patch_d13_eval_frame.py)
}

# ---------------------------------------------------------------- kern_exec.c (Site B)

# 1026's accessor region ends with `#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */` immediately before the
# `create_unix_stack` comment block.  Insert the sibling accessors there, under their OWN switch.
EXEC_ANCHOR = "#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */\n"
EXEC_DONE_MARK = "xnu_live_rdr_proc_argslen"

EXEC_BLOCK = (
    "#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */\n"
    "#if defined(STAGE90_XNU_READER_PROBE) && STAGE90_XNU_READER_PROBE\n"
    "/*\n"
    " * 1029 (READ THE READER): the initial argv/env block's own recorded bounds.  `p_argslen` is set by\n"
    " * exec_copyout_strings (kern_exec.c ~2804: `p->p_argslen = (int)(*stackp - string_area)`) and\n"
    " * `p_argc` at ~2803, so the block's [sp, user_stack) span and its recorded byte length are\n"
    " * readable from the proc at fault time (the STRING/PTR/ARGC locals are NOT).  READ ONLY; NULL\n"
    " * guard like the 1026 accessor.  docs/1029-design.md 3.3.\n"
    " */\n"
    "unsigned\n"
    "xnu_live_rdr_proc_argslen(void *bsd_info)\n"
    "{\n"
    "\tif (bsd_info == NULL) {\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "\treturn (unsigned)((proc_t)bsd_info)->p_argslen;\n"
    "}\n"
    "\n"
    "unsigned\n"
    "xnu_live_rdr_proc_argc(void *bsd_info)\n"
    "{\n"
    "\tif (bsd_info == NULL) {\n"
    "\t\treturn 0;\n"
    "\t}\n"
    "\treturn (unsigned)((proc_t)bsd_info)->p_argc;\n"
    "}\n"
    "#endif /* STAGE90_XNU_READER_PROBE */\n"
)

# kern_exec.c's STAGE90 namespace is shared by 1025/1026/1028.
EXEC_ALLOWED_STAGE90 = {
    "STAGE90_XNU_USTACK_PROBE",       # 1025
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028
    "STAGE90_XNU_READER_PROBE",       # 1029 (this rung)
    "STAGE90_XNU_CALLER_PROBE",       # 1031 (tools/patch_d13_caller_probe.py)
    "STAGE90_XNU_EVAL_FRAME",         # 1033 (tools/patch_d13_eval_frame.py)
}


def read(p):
    with open(p) as f:
        return f.read()


def write(p, t):
    with open(p, "w") as f:
        f.write(t)


def if_stage90_ids(text):
    ids = set()
    for m in re.finditer(r"^\s*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M):
        for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1)):
            if ident.startswith("STAGE90_"):
                ids.add(ident)
    return ids


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def exec_path(xnu):
    return os.path.join(xnu, EXEC_REL)


def check_trap(xnu):
    p = trap_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", f"no {p} (D13 tree not provisioned?)"
    t = read(p)
    if SWITCH in t:
        return True, p, t, "already staged"
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            f"{TRAP_REL}'s directives also evaluate {', '.join(foreign)}. trap.c is edited by FIVE "
            f"rungs (994/1020/1025/1026/1029) and a file's directive identifiers are a SHARED "
            f"namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other "
            f"patchers' sets. ([[mi4-one-file-many-rungs]])")
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            f"the ABT_ENTRY_PROBE/USTACK_PROBE `#endif` tail occurs {t.count(TRAP_ANCHOR)} time(s), "
            f"expected exactly 1. The tree is not in the state this rung was written against (a "
            f"displaced anchor or a partial edit).")
    return True, p, t, "anchor unique, switch absent"


def check_exec(xnu):
    p = exec_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", f"no {p} (D13 tree not provisioned?)"
    e = read(p)
    if EXEC_DONE_MARK in e:
        return True, p, e, "already staged"
    foreign = sorted(i for i in if_stage90_ids(e) if i not in EXEC_ALLOWED_STAGE90)
    if foreign:
        return False, p, e, (
            f"{EXEC_REL}'s directives also evaluate {', '.join(foreign)}. kern_exec.c's STAGE90 "
            f"identifiers are a SHARED namespace (1025/1026/1028/1029). ([[mi4-one-file-many-rungs]])")
    # The 1026 accessor's `#endif` must be the LAST one before create_unix_stack.  Uniqueness of the
    # bare string is too weak (other blocks close the same way), so require exactly two occurrences
    # (1025's publisher close + 1026's accessor close) and that our EXEC_INSERT_BEFORE target follows.
    if e.count(EXEC_ANCHOR) < 1:
        return False, p, e, (
            f"the ABT_ENTRY_PROBE `#endif` anchor occurs {e.count(EXEC_ANCHOR)} time(s), expected "
            f">=1 (1026's accessor must be staged first).")
    return True, p, e, "anchor present, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    ok_e, ep, e, msg_e = check_exec(xnu)
    if not ok_t:
        print(f"patch_d13_reader_probe: REFUSE (trap.c) - {msg_t}. Writing nothing.", file=sys.stderr)
        return 1
    if not ok_e:
        print(f"patch_d13_reader_probe: REFUSE (kern_exec.c) - {msg_e}. Writing nothing.", file=sys.stderr)
        return 1
    both = (msg_t == "already staged") and (msg_e == "already staged")
    if both:
        print("patch_d13_reader_probe: already staged (both files) - no-op, OK.")
        return 0
    print(f"   trap.c      : {msg_t}.")
    print(f"   kern_exec.c : {msg_e}.")
    if not do_apply:
        print("patch_d13_reader_probe: plan OK (dry run; pass --apply to write).")
        return 0
    if msg_t != "already staged":
        write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
        print(f"   trap.c      : staged Site A (xnu_live_rdr_* rows) inside 1025's failure arm.")
    # kern_exec.c: insert ONCE (the anchor is 1026's #endif; replace the FIRST occurrence that sits
    # immediately before the create_unix_stack comment -- i.e. the accessor region's close).
    if msg_e != "already staged":
        idx = e.find(EXEC_ANCHOR)
        # find the occurrence that is followed (allowing whitespace/comments) by "create_unix_stack"
        best = -1
        start = 0
        while True:
            j = e.find(EXEC_ANCHOR, start)
            if j < 0:
                break
            tail = e[j + len(EXEC_ANCHOR): j + len(EXEC_ANCHOR) + 400]
            if "create_unix_stack" in tail:
                best = j
                break
            start = j + 1
        if best < 0:
            print("patch_d13_reader_probe: REFUSE - the ABT_ENTRY_PROBE #endif before "
                  "create_unix_stack was not found (kern_exec.c not in the expected state). "
                  "Writing nothing.", file=sys.stderr)
            return 1
        e2 = e[:best] + EXEC_BLOCK + e[best + len(EXEC_ANCHOR):]
        write(ep, e2)
        print(f"   kern_exec.c : staged Site B (xnu_live_rdr_proc_argslen/_argc accessors).")
    return 0


def verify_off(xnu):
    """Prove both files compile to the 1028 tree's bytes with 1029's switch unset.  Both blocks are
    wholly inside `#if defined(STAGE90_XNU_READER_PROBE) && STAGE90_XNU_READER_PROBE`, so with the
    switch undefined the preprocessor removes them.  Check by TEXT (the ON block is present, and each
    is bracketed by its own #if/#endif pair)."""
    tp, ep = trap_path(xnu), exec_path(xnu)
    t, e = read(tp), read(ep)
    if SWITCH not in t or SWITCH not in e:
        print("patch_d13_reader_probe: --verify-off: switch ABSENT in one/both files (nothing staged).",
              file=sys.stderr)
        return 1
    have_t = (t.count(TRAP_DONE_MARK) == 1
              and t.count(f"#if defined({SWITCH}) && {SWITCH}\n") >= 1
              and t.count(f"#endif /* {SWITCH} */\n") >= 1)
    have_e = (e.count(EXEC_DONE_MARK) == 1
              and e.count(f"#endif /* {SWITCH} */\n") >= 1)
    # The trap block must sit BETWEEN the two pre-existing #endif lines.
    between = t.count("#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */\n#if defined(STAGE90_XNU_READER_PROBE)") == 1
    print(f"   trap.c      [ON] : xnu_live_rdr_far row present + #if/#endif pair: {have_t}")
    print(f"   trap.c      : the reader block sits inside 1025's publisher, after 1026/1027's block: {between}")
    print(f"   kern_exec.c [ON] : xnu_live_rdr_proc_argslen accessor present + #endif: {have_e}")
    if have_t and have_e and between:
        print("patch_d13_reader_probe: --verify-off PASS (both blocks gated on the switch; OFF removes "
              "them -> 1028 tree bytes).")
        return 0
    print("patch_d13_reader_probe: --verify-off FAIL.", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) < 2:
        print("usage: patch_d13_reader_probe.py <xnu_root> [--apply|--verify-off]", file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))